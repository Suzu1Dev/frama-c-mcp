use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{Mutex, RwLock};

use super::codec::{self, FramaCCommand, FramaCResponse};
use super::transport::Transport;
use crate::error::{FramaCError, FramaCRequestDiagnostics};
use crate::state::SessionState;

struct ClientInner {
    transport: Transport,
    counter: u64,
}

#[derive(Debug)]
pub struct FramaCExecResult {
    pub data: serde_json::Value,
    pub diagnostics: FramaCRequestDiagnostics,
}

fn protocol_trace_enabled() -> bool {
    trace_setting_enables(std::env::var("FRAMA_C_MCP_PROTOCOL_TRACE").ok().as_deref())
}

/// Whether a FRAMA_C_MCP_PROTOCOL_TRACE value turns tracing on, split from the
/// process environment so it can be tested without a global write.
pub fn trace_setting_enables(value: Option<&str>) -> bool {
    value.is_some_and(|value| !matches!(value, "" | "0" | "false" | "FALSE"))
}

/// The trace line, formatted. Whether to emit one is the caller's decision, so
/// this needs no on/off argument and no environment access: emit_protocol_trace
/// asks protocol_trace_enabled once, and the test asks trace_setting_enables
/// directly.
pub fn protocol_trace_line(
    command: &str,
    request: Option<&str>,
    id: Option<&str>,
    elapsed: Option<Duration>,
    payload_bytes: Option<usize>,
    result_kind: Option<&str>,
) -> String {
    serde_json::json!({
        "event": "frama_c_protocol",
        "command": command,
        "request": request,
        "id": id,
        "elapsed_ms": elapsed.map(|duration| duration.as_millis()),
        "payload_bytes": payload_bytes,
        "result_kind": result_kind,
    })
    .to_string()
}

fn emit_protocol_trace(
    command: &str,
    request: Option<&str>,
    id: Option<&str>,
    elapsed: Option<Duration>,
    payload_bytes: Option<usize>,
    result_kind: Option<&str>,
) {
    if !protocol_trace_enabled() {
        return;
    }
    eprintln!(
        "{}",
        protocol_trace_line(command, request, id, elapsed, payload_bytes, result_kind)
    );
}

fn elapsed_millis(started: Instant) -> u64 {
    started.elapsed().as_millis().try_into().unwrap_or(u64::MAX)
}

/// Classify one response to a queued SET/EXEC.
///
/// Returns the terminal result when the response settles `request_id`, or None
/// when it was progress or noise (SIGNAL, CMDLINE, a stale id) and the caller
/// should keep polling. `trace_command` only labels the protocol trace.
fn terminal_outcome(
    resp: FramaCResponse,
    trace_command: &str,
    request: &str,
    request_id: &str,
    started: Instant,
    diagnostics: &mut FramaCRequestDiagnostics,
) -> Option<Result<FramaCExecResult, FramaCError>> {
    enum Settled {
        Data(serde_json::Value),
        Failed { id: String, msg: String },
    }

    // Classify first so the bookkeeping below runs once instead of per arm.
    let (kind, payload_bytes, settled) = match resp {
        FramaCResponse::Data { id, data } if id == request_id => {
            let payload = data.to_string().len();
            ("DATA", Some(payload), Settled::Data(data))
        }
        FramaCResponse::Error { id, msg } if id == request_id => {
            let payload = msg.len();
            ("ERROR", Some(payload), Settled::Failed { id, msg })
        }
        FramaCResponse::Killed { id } if id == request_id => {
            diagnostics.cancellation_result = Some("killed".to_string());
            let msg = format!("killed: {id}");
            ("KILLED", None, Settled::Failed { id, msg })
        }
        FramaCResponse::Rejected { id } if id == request_id => {
            diagnostics.rejected_command_id = Some(id.clone());
            let msg = format!("rejected: {id}");
            ("REJECTED", None, Settled::Failed { id, msg })
        }
        FramaCResponse::Signal { id } => {
            diagnostics.signal_count += 1;
            diagnostics.queued_task_id.get_or_insert(id);
            emit_protocol_trace(
                trace_command,
                Some(request),
                Some(request_id),
                Some(started.elapsed()),
                None,
                Some("SIGNAL"),
            );
            return None;
        }
        FramaCResponse::CmdLineOn | FramaCResponse::CmdLineOff => return None,
        other => {
            tracing::warn!("unexpected response during {}: {:?}", trace_command, other);
            return None;
        }
    };

    diagnostics.final_result = Some(kind.to_string());
    diagnostics.elapsed_ms = Some(elapsed_millis(started));
    emit_protocol_trace(
        trace_command,
        Some(request),
        Some(request_id),
        Some(started.elapsed()),
        payload_bytes,
        Some(kind),
    );

    Some(match settled {
        Settled::Data(data) => Ok(FramaCExecResult {
            data,
            diagnostics: diagnostics.clone(),
        }),
        Settled::Failed { id, msg } => Err(FramaCError::CommandFailed {
            kind: kind.to_string(),
            id,
            msg,
            diagnostics: Box::new(diagnostics.clone()),
        }),
    })
}

impl ClientInner {
    fn next_id(&mut self) -> String {
        let id = format!("RQ.{}", self.counter);
        self.counter += 1;
        id
    }

    async fn send_command(&mut self, cmd: &FramaCCommand) -> Result<(), FramaCError> {
        let json = codec::encode_command(cmd);
        self.transport.send_frame(&json).await
    }

    async fn recv_response(
        &mut self,
        timeout: Duration,
    ) -> Result<Option<FramaCResponse>, FramaCError> {
        match self.transport.recv_frame(timeout).await? {
            Some(s) => Ok(Some(codec::decode_response(&s)?)),
            None => Ok(None),
        }
    }

    /// Read responses until the one matching `request_id` is received.
    /// Skips SIGNAL, CMDLINE, and responses for other request IDs (stale
    /// responses from timed-out operations).
    async fn wait_for_id(
        &mut self,
        request: &str,
        request_id: &str,
        timeout: Duration,
    ) -> Result<serde_json::Value, FramaCError> {
        let started = Instant::now();
        let deadline = Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                emit_protocol_trace(
                    "GET",
                    Some(request),
                    Some(request_id),
                    Some(started.elapsed()),
                    None,
                    Some("TIMEOUT"),
                );
                return Err(FramaCError::Timeout(timeout));
            }
            match self.recv_response(remaining).await? {
                Some(FramaCResponse::Data { id, data }) if id == request_id => {
                    emit_protocol_trace(
                        "GET",
                        Some(request),
                        Some(request_id),
                        Some(started.elapsed()),
                        Some(data.to_string().len()),
                        Some("DATA"),
                    );
                    return Ok(data);
                }
                Some(FramaCResponse::Error { id, msg }) if id == request_id => {
                    emit_protocol_trace(
                        "GET",
                        Some(request),
                        Some(request_id),
                        Some(started.elapsed()),
                        Some(msg.len()),
                        Some("ERROR"),
                    );
                    return Err(FramaCError::ServerError { id, msg });
                }
                Some(FramaCResponse::Rejected { id }) if id == request_id => {
                    emit_protocol_trace(
                        "GET",
                        Some(request),
                        Some(request_id),
                        Some(started.elapsed()),
                        None,
                        Some("REJECTED"),
                    );
                    return Err(FramaCError::Rejected { id });
                }
                // Skip signals and CMDLINE responses
                Some(FramaCResponse::Signal { .. })
                | Some(FramaCResponse::CmdLineOn)
                | Some(FramaCResponse::CmdLineOff) => continue,
                // Skip stale responses from other request IDs
                Some(FramaCResponse::Data { id, .. })
                | Some(FramaCResponse::Error { id, .. })
                | Some(FramaCResponse::Rejected { id })
                | Some(FramaCResponse::Killed { id }) => {
                    tracing::warn!(
                        "discarding stale response for {}, waiting for {}",
                        id,
                        request_id
                    );
                    continue;
                }
                None => return Err(FramaCError::Timeout(timeout)),
            }
        }
    }

    async fn poll_loop(
        &mut self,
        command: &str,
        request_id: &str,
        request: &str,
        timeout: Duration,
    ) -> Result<FramaCExecResult, FramaCError> {
        let started = Instant::now();
        let deadline = Instant::now() + timeout;
        let mut diagnostics = FramaCRequestDiagnostics {
            request_id: request_id.to_string(),
            request: request.to_string(),
            queued_task_id: None,
            signal_count: 0,
            elapsed_ms: None,
            final_result: None,
            cancellation_result: None,
            rejected_command_id: None,
        };

        // A fast request may already have answered before the first POLL.
        if let Some(resp) = self.recv_response(Duration::from_millis(500)).await? {
            if let Some(outcome) =
                terminal_outcome(resp, command, request, request_id, started, &mut diagnostics)
            {
                return outcome;
            }
        }

        loop {
            if Instant::now() >= deadline {
                let kill_result = self
                    .send_command(&FramaCCommand::Kill {
                        id: request_id.to_string(),
                    })
                    .await;
                diagnostics.final_result = Some("TIMEOUT".to_string());
                diagnostics.elapsed_ms = Some(elapsed_millis(started));
                diagnostics.cancellation_result = Some(match kill_result {
                    Ok(()) => match self.recv_response(Duration::from_millis(500)).await {
                        Ok(Some(FramaCResponse::Killed { id })) if id == request_id => {
                            "killed".to_string()
                        }
                        Ok(Some(other)) => format!("kill_sent_then_{other:?}"),
                        Ok(None) => "kill_sent".to_string(),
                        Err(e) => format!("kill_sent_then_error:{e}"),
                    },
                    Err(e) => format!("kill_send_error:{e}"),
                });
                emit_protocol_trace(
                    command,
                    Some(request),
                    Some(request_id),
                    Some(started.elapsed()),
                    None,
                    Some("TIMEOUT"),
                );
                return Err(FramaCError::CommandFailed {
                    kind: "TIMEOUT".to_string(),
                    id: request_id.to_string(),
                    msg: format!("timeout after {timeout:?}"),
                    diagnostics: Box::new(diagnostics),
                });
            }

            tokio::time::sleep(Duration::from_millis(100)).await;

            self.send_command(&FramaCCommand::Poll).await?;
            emit_protocol_trace(
                "POLL",
                Some(request),
                Some(request_id),
                Some(started.elapsed()),
                None,
                None,
            );

            let Some(resp) = self.recv_response(Duration::from_millis(500)).await? else {
                continue;
            };
            if let Some(outcome) =
                terminal_outcome(resp, "POLL", request, request_id, started, &mut diagnostics)
            {
                return outcome;
            }
        }
    }
}

pub struct FramaCClient {
    inner: Mutex<ClientInner>,
}

impl FramaCClient {
    pub async fn connect(
        path: &str,
        state: Arc<RwLock<SessionState>>,
    ) -> Result<Self, FramaCError> {
        let transport = Transport::connect(path).await?;
        let mut inner = ClientInner {
            transport,
            counter: 0,
        };

        // Handshake: Frama-C Server doesn't push data until the client sends a
        // command. Send a probe GET to trigger the server to flush queued
        // signals (CMDLINEON/CMDLINEOFF) along with the response.
        let probe_id = inner.next_id();
        inner
            .send_command(&FramaCCommand::Get {
                id: probe_id.clone(),
                request: "kernel.ast.getFiles".to_string(),
                data: serde_json::Value::Null,
            })
            .await?;

        // Read responses until we see CMDLINEOFF (max 30 seconds). The server
        // batches CMDLINEOFF with request responses, so we may receive DATA for
        // our probe GET interleaved with CMDLINE signals.
        let mut cmdlineoff_seen = false;
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(FramaCError::ConnectTimeout);
            }
            match inner.recv_response(remaining).await? {
                Some(FramaCResponse::CmdLineOff) => {
                    cmdlineoff_seen = true;
                    break;
                }
                Some(FramaCResponse::CmdLineOn) => continue,
                Some(FramaCResponse::Data { .. }) => {
                    // Probe GET response: consume it and keep waiting.
                    // CMDLINEOFF may arrive in the same batch.
                    continue;
                }
                Some(other) => {
                    tracing::warn!("unexpected during handshake: {:?}", other);
                    continue;
                }
                None => {
                    // Timeout reading: if we already got a Data response but no
                    // CMDLINEOFF, the server may have sent CMDLINEOFF before
                    // the command line phase (already past it). Treat as ready.
                    break;
                }
            }
        }
        if !cmdlineoff_seen {
            tracing::warn!("CMDLINEOFF not received, proceeding anyway");
        }

        let client = FramaCClient {
            inner: Mutex::new(inner),
        };

        // Auto-fetch function info to populate marker cache
        let entries = client.fetch_all("kernel.ast.fetchFunctions").await?;
        {
            let mut st = state.write().await;
            st.update_functions(&entries);
            st.project_loaded = true;
        }

        Ok(client)
    }

    pub async fn get(
        &self,
        request: &str,
        data: serde_json::Value,
    ) -> Result<serde_json::Value, FramaCError> {
        let mut inner = self.inner.lock().await;
        let id = inner.next_id();
        let payload_bytes = data.to_string().len();
        emit_protocol_trace(
            "GET",
            Some(request),
            Some(&id),
            None,
            Some(payload_bytes),
            None,
        );
        inner
            .send_command(&FramaCCommand::Get {
                id: id.clone(),
                request: request.to_string(),
                data,
            })
            .await?;
        inner
            .wait_for_id(request, &id, Duration::from_secs(10))
            .await
    }

    pub async fn set(
        &self,
        request: &str,
        data: serde_json::Value,
    ) -> Result<serde_json::Value, FramaCError> {
        let mut inner = self.inner.lock().await;
        let id = inner.next_id();
        let payload_bytes = data.to_string().len();
        emit_protocol_trace(
            "SET",
            Some(request),
            Some(&id),
            None,
            Some(payload_bytes),
            None,
        );
        inner
            .send_command(&FramaCCommand::Set {
                id: id.clone(),
                request: request.to_string(),
                data,
            })
            .await?;

        // SET is queued (like EXEC), not processed immediately (like GET). Use
        // poll_loop to repeatedly send POLL until the server processes the
        // queue and responds with DATA.
        inner
            .poll_loop("SET", &id, request, Duration::from_secs(30))
            .await
            .map(|result| result.data)
    }

    pub async fn exec(
        &self,
        request: &str,
        data: serde_json::Value,
        timeout: Duration,
    ) -> Result<serde_json::Value, FramaCError> {
        self.exec_with_diagnostics(request, data, timeout)
            .await
            .map(|result| result.data)
    }

    pub async fn exec_with_diagnostics(
        &self,
        request: &str,
        data: serde_json::Value,
        timeout: Duration,
    ) -> Result<FramaCExecResult, FramaCError> {
        let mut inner = self.inner.lock().await;
        let id = inner.next_id();
        let payload_bytes = data.to_string().len();
        emit_protocol_trace(
            "EXEC",
            Some(request),
            Some(&id),
            None,
            Some(payload_bytes),
            None,
        );
        inner
            .send_command(&FramaCCommand::Exec {
                id: id.clone(),
                request: request.to_string(),
                data,
            })
            .await?;
        inner.poll_loop("EXEC", &id, request, timeout).await
    }

    pub async fn fetch_all(&self, request: &str) -> Result<Vec<serde_json::Value>, FramaCError> {
        let mut all_entries = Vec::new();
        loop {
            let data = self.get(request, serde_json::json!(20000)).await?;

            // Check reload flag before extending (clear stale accumulated
            // entries)
            if data
                .get("reload")
                .and_then(|v| v.as_bool())
                .unwrap_or(false)
            {
                all_entries.clear();
            }
            if let Some(updated) = data.get("updated").and_then(|v| v.as_array()) {
                all_entries.extend(updated.iter().cloned());
            }
            let pending = data.get("pending").and_then(|v| v.as_u64()).unwrap_or(0);
            if pending == 0 {
                break;
            }
        }
        Ok(all_entries)
    }

    pub async fn shutdown(&self) -> Result<(), FramaCError> {
        let mut inner = self.inner.lock().await;
        inner.send_command(&FramaCCommand::Shutdown).await?;
        inner.transport.close().await
    }
}
