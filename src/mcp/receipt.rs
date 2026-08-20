//! Proof receipts: what a run proved, under which environment, in a form two
//! runs can be compared by.
//!
//! A receipt exists because "valid" is not evidence on its own. Frama-C caches
//! prover verdicts, provers and their versions move underneath a project, and
//! a contract edited after a proof leaves the goal list looking unchanged. The
//! receipt pins the source hashes, the environment, the effective WP
//! configuration and the per-goal statuses, and hashes all of it, so two runs
//! are comparable exactly when their hashes match.

use super::*;
use crate::state::sha256_hex;

/// What a receipt calls a source file.
///
/// Its own path, except for the scratch copy of an inline `source`, which is
/// recorded as its bare name. The directory that holds it is chosen fresh on
/// every call and is not part of what was proved, so digesting it would make
/// two runs of the same source incomparable, and comparing two runs is the only
/// thing a receipt is for. The old pid-shaped directory hid this by being
/// constant within a session; a random name does not, which is what surfaced
/// it. The content hash beside this is what tells two different sources apart.
pub fn receipt_source_path(file: &str) -> String {
    let path = std::path::Path::new(file);
    let in_scratch = path.parent().and_then(|dir| dir.file_name()).is_some_and(|dir| {
        dir.to_string_lossy().starts_with(super::analysis::CHECK_SCRATCH_PREFIX)
    });
    match path.file_name().filter(|_| in_scratch) {
        Some(name) => name.to_string_lossy().into_owned(),
        None => file.to_string(),
    }
}

fn proof_receipt_source_files(files: &[String]) -> Vec<serde_json::Value> {
    let mut entries = files
        .iter()
        .map(|file| {
            let path = receipt_source_path(file);
            match std::fs::read(file) {
                Ok(bytes) => json!({
                    "path": path,
                    "sha256": sha256_hex(&bytes),
                }),
                Err(error) => json!({
                    "path": path,
                    "sha256": serde_json::Value::Null,
                    "error": error.to_string(),
                }),
            }
        })
        .collect::<Vec<_>>();
    entries.sort_by(|a, b| {
        a.get("path")
            .and_then(|value| value.as_str())
            .cmp(&b.get("path").and_then(|value| value.as_str()))
    });
    entries
}

/// `properties` is what makes the ids discriminate. `stable_goal_id` digests
/// the goal's `predicate`, which only `enrich_goal_with_property_status`
/// supplies; without it the digest falls through to `name` and receipt ids
/// collided 100 times over 409 corpus goals, against 8 for the same goals seen
/// through `get_wp_goals`. Pass an empty map only when there are no goals.
pub fn proof_receipt_goals(
    goals: &[serde_json::Value],
    stable_scope: Option<&str>,
    properties: &HashMap<String, serde_json::Value>,
) -> Vec<serde_json::Value> {
    let mut receipt_goals = goals
        .iter()
        .map(|goal| {
            let mut goal = goal.clone();
            add_identity_fields(&mut goal);
            enrich_goal_with_property_status(&mut goal, properties);
            let (kind, hash_label) = classify_wp_goal(&goal);

            // `stable_goal_id_for` returns a `hash_label` verbatim when the
            // goal carries one, and only `get_wp_goals` used to attach it, so
            // an injected annotation got its label as an id there and a digest
            // here. Same classification, same field, so the two paths agree.
            if let (Some(label), Some(object)) = (hash_label, goal.as_object_mut()) {
                object
                    .entry("hash_label".to_string())
                    .or_insert_with(|| serde_json::Value::String(label));
            }
            enrich_goal_stable_id(&mut goal, &kind, stable_scope);
            json!({
                "stable_goal_id": goal.get("stable_goal_id").cloned().unwrap_or_else(|| json!(null)),

                // The receipt spells the normalized verdict under "status",
                // which is why a receipt reader is right to read that name
                // directly and must not be routed through the goal accessors.
                "status": own_status(&goal).map(|status| json!(status))
                    .unwrap_or_else(|| json!(null)),

                // Part of the receipt's identity on purpose: two runs whose
                // receipts match are supposed to be comparable, and a replayed
                // verdict was not computed by the run claiming it, so it cannot
                // hash the same as one that was.
                "from_cache": goal.get("from_cache").cloned().unwrap_or_else(|| json!(false)),
            })
        })
        .collect::<Vec<_>>();
    receipt_goals.sort_by(|a, b| {
        let a_key = (
            a.get("stable_goal_id").and_then(|value| value.as_str()),
            a.get("status").and_then(|value| value.as_str()),
        );
        let b_key = (
            b.get("stable_goal_id").and_then(|value| value.as_str()),
            b.get("status").and_then(|value| value.as_str()),
        );
        a_key.cmp(&b_key)
    });
    receipt_goals
}

pub fn proof_receipt_with_hash(mut body: serde_json::Value) -> serde_json::Value {
    let digest_input = serde_json::to_vec(&body).unwrap_or_default();
    if let Some(object) = body.as_object_mut() {
        object.insert("sha256".to_string(), json!(sha256_hex(&digest_input)));
    }
    body
}

/// Drop a generated hash label from a clause's text.
///
/// An injected clause reads "an_ffed752e_Req0: x >= 0". The label is fresh per
/// injection, so leaving it in would make two identical contracts compare
/// unequal, which defeats the reason the text is in the receipt at all. The
/// prefixes are the ones generate_hash_label emits.
pub fn strip_generated_label(text: &str) -> String {
    let mut clause = text;
    if let Some((label, rest)) = text.split_once(": ") {
        let mut parts = label.split('_');
        let prefix = parts.next();
        let hex = parts.next();
        if matches!(
            prefix,
            Some("re" | "en" | "as" | "li" | "la" | "lv" | "at" | "an")
        ) && hex.is_some_and(|hex| hex.len() == 8 && hex.chars().all(|c| c.is_ascii_hexdigit()))
        {
            clause = rest;
        }
    }
    clause.trim().to_string()
}

/// What a receipt is a receipt of, as the caller states it.
///
/// Grouped rather than passed loose because the list runs to eight and four of
/// them are strings or Values in a row: "tool" and "goals_status_source" are
/// both string slices, and three of the rest are JSON values, so two
/// transposed arguments would compile and produce a receipt that describes a
/// different run. Named fields make that a build error.
pub struct ProofReceiptRequest<'a> {
    pub tool: &'a str,
    pub source_files: Vec<String>,
    pub wp_config: serde_json::Value,
    pub goals: &'a [serde_json::Value],
    pub stable_scope: Option<&'a str>,
    pub goals_status_source: &'a str,
    pub reported: serde_json::Value,
    pub properties: &'a HashMap<String, serde_json::Value>,
}

/// The same thing once the server has resolved what it alone can: the
/// environment it is running in, the contracts as loaded, and the goals with
/// their stable ids. Separate from ProofReceiptRequest because this is the
/// half a test can build without a live Frama-C.
pub struct ProofReceiptBody<'a> {
    pub tool: &'a str,
    pub source_files: Vec<serde_json::Value>,
    pub contracts: serde_json::Value,
    pub environment: serde_json::Value,
    pub wp_config: serde_json::Value,
    pub goals: Vec<serde_json::Value>,
    pub goals_status_source: &'a str,
    pub reported: serde_json::Value,
}

pub fn proof_receipt_body(body: ProofReceiptBody<'_>) -> serde_json::Value {
    let ProofReceiptBody {
        tool,
        source_files,
        contracts,
        environment,
        wp_config,
        goals,
        goals_status_source,
        reported,
    } = body;
    let source_hash = sha256_hex(&serde_json::to_vec(&source_files).unwrap_or_default());
    json!({
        "schema": "frama-c-mcp.proof-receipt.v3",
        "subject": {
            "tool": tool,
            "source_hash": source_hash,
            "files": source_files,

            // What WP actually proved under, which the file hashes above do not
            // cover for anything injected this session.
            "contracts": contracts,
        },
        "environment": environment,
        "wp": wp_config,
        "goals_status_source": goals_status_source,
        "goals": goals,
        "reported": reported,
    })
}

impl FramaCMcpServer {
    /// The contracts the run proved under, per function in scope.
    ///
    /// The receipt hashes every source file's contents, so a contract edited
    /// on disk moves it. Annotations injected this session never touch a file,
    /// which is the whole point of the sandbox loop, so the contract WP
    /// actually worked under is invisible to a receipt that only hashes the
    /// disk. Measured: one function proved under "x >= 0", then under
    /// "x >= 0 && x <= 1", a domain of two values instead of every
    /// non-negative int, and the two receipts had a byte-identical
    /// source_hash. The artifact claiming two runs are comparable could not
    /// see the proof shrink.
    ///
    /// Scope comes from the effective function list the receipt already
    /// records, so this snapshots what WP was actually pointed at rather than
    /// every annotated function in the project.
    ///
    /// Generated labels are stripped before storing. An injected clause's text
    /// carries a per-injection label like "an_ffed752e_Req0:", so two
    /// identical contracts injected twice would otherwise never compare equal,
    /// which is the opposite of what this is for.
    pub async fn proof_receipt_contracts(
        &self,
        wp_config: &serde_json::Value,
        goals_status_source: &str,
    ) -> serde_json::Value {
        // The isolated CLI retry proves the files on disk in a separate
        // process. The live AST here carries whatever was injected this
        // session, which that run never saw, so snapshotting it would put a
        // contract in the receipt that is not the one proved. The same reason
        // that path already reports its goals source as unavailable.
        if goals_status_source == "unavailable_isolated_cli_retry" {
            return json!("unavailable_isolated_cli_retry");
        }

        let functions = wp_config
            .get("functions")
            .and_then(|value| value.as_array())
            .into_iter()
            .flatten()
            .filter_map(|value| value.as_str());

        let mut contracts = serde_json::Map::new();
        for function in functions {
            let Ok(context) = self.contract_context_payload(function).await else {
                continue;
            };
            let Some(contract) = context.pointer("/function/contract") else {
                continue;
            };

            // Grouped by each entry's own kind rather than by the array it came
            // from. getContractContext returns the exits clause inside the
            // ensures array, tagged "exits", so reading the array name would
            // file "exits \false" as a postcondition: wrong, and wrong in the
            // direction that matters for an audit artifact. Requires entries
            // carry no kind at all, hence the fall back to the array's name.
            let mut by_kind: BTreeMap<String, Vec<String>> = BTreeMap::new();
            for array in ["requires", "ensures"] {
                let entries = contract
                    .get(array)
                    .and_then(|value| value.as_array())
                    .into_iter()
                    .flatten();
                for entry in entries {
                    let Some(text) = entry
                        .pointer("/predicate/text")
                        .and_then(|value| value.as_str())
                    else {
                        continue;
                    };
                    let kind = entry
                        .get("kind")
                        .and_then(|kind| kind.as_str())
                        .unwrap_or(array);
                    by_kind
                        .entry(kind.to_string())
                        .or_default()
                        .push(strip_generated_label(text));
                }
            }

            // Behavior groupings live in their own arrays and are reachable
            // from neither of the two above, so they need naming. A contract
            // that stops being complete proves less, which is the whole point
            // of recording any of this. Each entry is one group, kept whole and
            // written the way ACSL writes it, because "complete behaviors a, b"
            // and two one-name groups say different things.
            //
            // Not covered, and no way to cover it here: terminates and
            // decreases. getContractContext does not emit them at all, so a
            // change to either is invisible to this snapshot. Extending the
            // plug-in is the fix; recording the gap is the honest interim.
            for group in ["complete", "disjoint"] {
                let names = contract
                    .get(group)
                    .and_then(|value| value.as_array())
                    .into_iter()
                    .flatten()
                    .filter_map(|entry| {
                        let names = entry
                            .as_array()?
                            .iter()
                            .filter_map(|name| name.as_str())
                            .collect::<Vec<_>>();
                        (!names.is_empty()).then(|| names.join(", "))
                    })
                    .collect::<Vec<_>>();
                if !names.is_empty() {
                    by_kind.insert(group.to_string(), names);
                }
            }
            if by_kind.is_empty() {
                continue;
            }
            for texts in by_kind.values_mut() {
                texts.sort();
                texts.dedup();
            }
            contracts.insert(function.to_string(), json!(by_kind));
        }
        serde_json::Value::Object(contracts)
    }

    pub async fn proof_receipt(&self, request: ProofReceiptRequest<'_>) -> serde_json::Value {
        let ProofReceiptRequest {
            tool,
            source_files,
            wp_config,
            goals,
            stable_scope,
            goals_status_source,
            reported,
            properties,
        } = request;

        // Three independent probes, so they run together rather than in
        // sequence. Every check builds two receipts, one for itself and one for
        // the run_wp it calls, and the why3 probe is the slow one.
        let (frama_c_version, why3_provers, opam_switch) = tokio::join!(
            run_command_json(&self.frama_c_path, &["-version"], TOOL_PROBE_BUDGET),
            run_command_json("why3", &["config", "list-provers"], TOOL_PROBE_BUDGET),
            run_command_json("opam", &["var", "switch"], TOOL_PROBE_BUDGET),
        );
        let environment = json!({
            "frama_c_version": frama_c_version,
            "why3_provers": why3_provers,
            "opam_switch": opam_switch,
        });
        let contracts = self
            .proof_receipt_contracts(&wp_config, goals_status_source)
            .await;
        let receipt = proof_receipt_with_hash(proof_receipt_body(ProofReceiptBody {
            tool,
            source_files: proof_receipt_source_files(&source_files),
            contracts,
            environment,
            wp_config,
            goals: proof_receipt_goals(goals, stable_scope, properties),
            goals_status_source,
            reported,
        }));

        // Remembered here rather than at each call site, so every receipt a
        // caller is handed is one they can later pass as `since`.
        if let (Some(sha256), Some(receipt_goals)) =
            (receipt["sha256"].as_str(), receipt["goals"].as_array())
        {
            self.state
                .write()
                .await
                .remember_receipt_goals(sha256, receipt_goals);
        }
        receipt
    }
}
