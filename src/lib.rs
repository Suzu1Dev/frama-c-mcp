//! An MCP server for Frama-C.
//!
//! The supported entry points are [`check`] and [`CheckParams`]. Everything
//! else this crate exports is published so the unit tests under `tests/unit/`
//! can reach it, not because it is an interface: the tests are an external
//! crate and can only see `pub`. Treat those items as internal. They carry no
//! stability guarantee, they are renamed and resewn whenever the code moves,
//! and nothing outside this repository should depend on them.
//!
//! Two groups deserve more than that caveat, because calling them out of
//! context does damage rather than returning an error. `mcp::proc` publishes
//! process control, including `kill_sandbox` and `kill_frama_c_group`, which
//! signal a process group and are correct only for a group this server started.
//! `mcp::store` publishes the writers for on-disk conclusion and sandbox
//! metadata, which assume the path checks their callers in `mcp::server` have
//! already run.

pub mod error;

// Hyphenated directory to match the rest of the tree; the module name cannot
// follow, since module paths are identifiers.
#[path = "frama-c/mod.rs"]
pub mod frama_c;
pub mod mcp;
pub mod state;
pub mod topo;

use std::sync::Arc;

use rmcp::ErrorData as McpError;
use serde_json::Value;
use tokio::sync::RwLock;

pub use mcp::types::CheckParams;

use mcp::server::FramaCMcpServer;
use state::SessionState;

/// One-shot check, for the CLI and for callers that are not an MCP session.
///
/// Tears the spawned Frama-C down before returning. Leaving it to Drop is what
/// the MCP path used to do, and it does not reach the provers Frama-C starts:
/// this path ran once per integration test and left one process per run behind,
/// reparented to launchd with its socket still open. The result is returned
/// after the teardown rather than through `?`, so a failing check cleans up on
/// the way out too.
pub async fn check(
    frama_c_path: impl Into<String>,
    max_sandboxes: usize,
    params: CheckParams,
) -> Result<Value, McpError> {
    let state = Arc::new(RwLock::new(SessionState::default()));
    let server = FramaCMcpServer::new_lazy(state, frama_c_path.into(), max_sandboxes);
    let sandboxes = server.sandbox_registry();
    let main_instance = server.main_frama_c_state();

    let result = server.check_payload(params).await;

    FramaCMcpServer::kill_live_sandboxes(&sandboxes).await;
    FramaCMcpServer::kill_main_instance(&main_instance).await;
    result
}
