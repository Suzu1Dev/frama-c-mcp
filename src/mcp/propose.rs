//! Candidate annotations derived from what the AST already says.
//!
//! This proposes only what the analyses determine. A frame condition is a fact
//! about the code: the set of locations a loop body writes is in the AST, and
//! WP will reject any assigns clause that disagrees with it, so proposing one
//! is transcription rather than invention. A loop invariant relating an
//! accumulator to a logic function is not in the AST at all, and no amount of
//! reading the code produces it, so this reports that gap instead of guessing
//! at a predicate that would type-check and mean nothing.
//!
//! It fails closed. A frame that omits a location is worse than no frame at
//! all, because WP proves the function against it happily and every caller
//! then relies on writes the contract denied. So a callee with no finite
//! assigns, or anything else the effects cannot account for, makes the whole
//! proposal unavailable rather than shrinking it to what happened to be
//! visible. Measured, before that rule existed: a function writing through a
//! pointer parameter was proposed an empty frame, assigns nothing.
//!
//! Every proposal is dry-run against the real AST, and one that does not
//! type-check stops being a proposal. That is how a frame naming a loop index
//! leaves, since the write is real and the name is out of scope in a contract.

use super::*;
use crate::mcp::server::analysis::tool_result_json;
use crate::mcp::server::contracts::{acsl_identifiers, assigns_target_leaf};

/// What a frame proposal is allowed to say, or why it may not be made.
///
/// A frame that omits a location is worse than no frame at all: WP proves the
/// function against it happily, and every caller then relies on writes the
/// contract denied. So anything this cannot account for makes the whole
/// proposal unavailable rather than shrinking it.
pub enum Frame {
    Writes(Vec<String>),
    Unknown(String),
}

/// Add a callee's assigns to the frame, or give up on the frame.
///
/// A callee whose assigns is not a finite list writes an unknown set, which
/// the plugin reports as kind "any". That is the uncontracted-callee case, and
/// it is exactly where an eager proposal would invent soundness the code does
/// not have.
fn extend_with_callee_assigns(targets: &mut Vec<String>, effects: &serde_json::Value) -> Option<String> {
    for callee in effects
        .get("callee_assigns")
        .and_then(|value| value.as_array())
        .into_iter()
        .flatten()
    {
        let name = callee
            .get("function")
            .and_then(|value| value.as_str())
            .unwrap_or("a callee");
        let assigns = callee.get("assigns");
        let kind = assigns
            .and_then(|assigns| assigns.get("kind"))
            .and_then(|value| value.as_str())
            .unwrap_or("any");
        if kind != "list" {
            return Some(format!(
                "{name} states no finite assigns, so what this writes through it is unknown.                  Give {name} an assigns clause first, then ask again."
            ));
        }
        targets.extend(
            assigns
                .and_then(|assigns| assigns.get("assigns"))
                .and_then(|list| list.as_array())
                .into_iter()
                .flatten()
                .filter_map(|write| write.get("target").and_then(|value| value.as_str()))
                .map(str::to_string),
        );
    }
    None
}

/// The locations a function writes that its callers can observe.
///
/// A write is caller-visible when it lands on a global, or when it is a
/// dereferenced memory lvalue, which reports an empty base. Filtering on the
/// global flag
/// alone drops every write through a pointer parameter and proposes
/// assigns nothing for a function that writes the caller's memory, which is
/// the one thing this module must never do.
pub fn function_frame(writes: &serde_json::Value) -> Frame {
    let mut targets: Vec<String> = writes
        .get("writes")
        .and_then(|writes| writes.as_array())
        .into_iter()
        .flatten()
        .filter_map(|write| {
            let target = write.get("target").and_then(|value| value.as_str())?;
            let base = write.get("base").and_then(|value| value.as_str())?;
            let global = write.get("global").and_then(|value| value.as_bool()) == Some(true);

            // A Mem lvalue has no base variable, so base comes back empty; it
            // is still caller-visible when it goes through a pointer parameter.
            (global || base.is_empty()).then(|| target.to_string())
        })
        .collect();
    if let Some(reason) = extend_with_callee_assigns(&mut targets, writes) {
        return Frame::Unknown(reason);
    }

    // What the effect visitor could not enumerate. A call through a function
    // pointer names no callee whose assigns could be read, and inline assembly
    // is opaque, so both write an unknown set. Neither leaves a write entry
    // behind, so without this the frame comes out empty and a function that
    // writes the caller's memory is proposed assigns nothing, which WP then
    // proves against happily.
    if let Some(unresolved) = writes
        .get("unresolved")
        .and_then(|value| value.as_array())
        .filter(|entries| !entries.is_empty())
    {
        let kinds: Vec<&str> = unresolved
            .iter()
            .filter_map(|entry| entry.get("kind").and_then(|value| value.as_str()))
            .collect();
        return Frame::Unknown(format!(
            "This function contains {} that the effect analysis cannot enumerate, so what it \
             writes is unknown. Name the frame by hand, or give the indirect target a contract \
             the caller can see.",
            kinds.join(" and ")
        ));
    }

    targets.sort();
    targets.dedup();
    Frame::Writes(targets)
}

/// Does this function already carry a clause of the given kind?
///
/// Keyed on the loop marker when there is one, so a loop that states assigns
/// does not suppress the proposal for the loop next to it.
fn already_annotated(
    annotations: &serde_json::Value,
    kind: &str,
    kinstr_marker: Option<&str>,
) -> bool {
    annotations
        .as_array()
        .into_iter()
        .flatten()
        .any(|annotation| {
            annotation.get("kind").and_then(|value| value.as_str()) == Some(kind)
                && annotation.get("kinstr_marker").and_then(|value| value.as_str())
                    == kinstr_marker
        })
}

/// The identifiers a postcondition mentions, so a written location with no
/// postcondition about it can be told from one that is constrained.
fn ensures_text(annotations: &serde_json::Value) -> String {
    annotations
        .as_array()
        .into_iter()
        .flatten()
        .filter(|annotation| {
            annotation.get("kind").and_then(|value| value.as_str()) == Some("ensures")
        })
        .filter_map(|annotation| annotation.get("predicate").and_then(|value| value.as_str()))
        .collect::<Vec<_>>()
        .join(" ")
}

/// One frame per loop that does not state one, and a note naming the invariant
/// this will not invent.
fn loop_frames(
    loops: &serde_json::Value,
    annotations: &serde_json::Value,
    proposals: &mut Vec<serde_json::Value>,
    not_proposed: &mut Vec<serde_json::Value>,
) {
    // A loop frame is a fact about the body, so this is transcription. Both
    // halves matter: a location written and not listed loses every fact about
    // it across the loop, and one listed but not written weakens the proof for
    // nothing.
    for loop_effect in loops.as_array().into_iter().flatten() {
        let Some(stmt_id) = loop_effect.get("stmt_id").and_then(|value| value.as_i64()) else {
            continue;
        };
        let marker = format!("#k{stmt_id}");
        let mut targets = loop_effect
            .get("modified_vars")
            .and_then(|vars| vars.as_array())
            .map(|vars| {
                vars.iter()
                    .filter_map(|var| var.as_str())
                    .map(str::to_string)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        if let Some(reason) = extend_with_callee_assigns(&mut targets, loop_effect) {
            not_proposed.push(json!({
                "kind": "loop_assigns",
                "stmt_id": stmt_id,
                "reason": reason,
            }));
            continue;
        }
        targets.sort();
        targets.dedup();

        if targets.is_empty() {
            continue;
        }
        if already_annotated(annotations, "assigns", Some(marker.as_str())) {
            continue;
        }
        proposals.push(json!({
            "kind": "loop",
            "stmt_id": stmt_id,

            // The array-of-objects shape the loop planner reads. A bare string
            // parses as JSON and plans nothing, which is the one failure mode a
            // proposal must not have: it reads as accepted.
            "assigns": [{"acsl": targets.join(", ")}],
            "invariants": [],
            "confidence": "derived",
            "derived_from": "getLoopEffects.modified_vars and callee_assigns",
            "rationale": "Every location this loop body writes, and nothing else. WP loses \
                          each fact it holds about a location the loop writes without \
                          listing.",
        }));

        // Said rather than guessed. The bound is usually derivable by eye and
        // the relation never is, and a predicate that type-checks without being
        // true is worse than an absent one: it proves nothing and reads as
        // progress.
        if !already_annotated(annotations, "loop_invariant", Some(marker.as_str())) {
            not_proposed.push(json!({
                "kind": "loop_invariant",
                "stmt_id": stmt_id,
                "reason": "A loop invariant states what the body maintains, which the AST \
                           does not determine. Two are usually needed: the bound on the \
                           induction variable, readable off the loop guard, and the relation \
                           between the accumulator and what it accumulates.",
            }));
        }
    }
}

/// Every location the contract says it writes that no postcondition mentions.
fn ensures_gaps(annotations: &serde_json::Value, not_proposed: &mut Vec<serde_json::Value>) {
    // A location written with no postcondition about it: the proof says the
    // write happened and nothing about what it wrote. A set of identifiers, not
    // a joined string: "contains" over the concatenation reports a gap as
    // constrained whenever some other clause happens to mention a name
    // containing it, so "g" was covered by an ensures about "gg".
    let constrained: std::collections::BTreeSet<String> =
        acsl_identifiers(&ensures_text(annotations)).into_iter().collect();
    for annotation in annotations.as_array().into_iter().flatten() {
        if annotation.get("kind").and_then(|value| value.as_str()) != Some("assigns") {
            continue;
        }
        if annotation.get("kinstr_marker").is_some() {
            continue;
        }
        let Some(predicate) = annotation.get("predicate").and_then(|value| value.as_str())
        else {
            continue;
        };

        // Each assigns target, reduced to the location it names. The whole
        // clause tokenized would report the range bound of "a[0 .. n-1]" as a
        // written location, which is what assigns_target_leaf exists to
        // prevent.
        for target in predicate
            .trim_start_matches("assigns")
            .trim_end_matches(';')
            .split(',')
            .filter_map(assigns_target_leaf)
        {
            if target == "nothing" || constrained.contains(&target) {
                continue;
            }
            not_proposed.push(json!({
                "kind": "ensures",
                "about": target,
                "reason": format!(
                    "The contract assigns {target} and no postcondition mentions it, so \
                     proving this function says nothing about the value written there. What \
                     it should say is a property of the code, not of the AST."
                ),
            }));
        }
    }
}

impl FramaCMcpServer {
    /// Type-check the proposals the way the caller would, and report per
    /// proposal whether a clause came out the other side.
    ///
    /// None when the dry run could not be made at all, which is different from
    /// a proposal that failed: the first says nothing was checked.
    async fn dry_run_proposals(
        &self,
        function: &str,
        proposals: &[serde_json::Value],
    ) -> Option<Vec<serde_json::Value>> {
        if proposals.is_empty() {
            return None;
        }
        let result = self
            .inject_all_annotations(Parameters(InjectAllAnnotationsParams {
                function: Some(function.to_string()),
                annotations: Some(proposals.to_vec()),
                dry_run: true,
                ..Default::default()
            }))
            .await
            .ok()?;
        let payload = tool_result_json(&result);
        let clauses = payload.get("clauses")?.as_array()?.clone();

        // Paired on the clause text, not on position. The planner emits by
        // clause kind rather than in the order the caller wrote, so zipping the
        // two lists hands each proposal its neighbour's verdict, which is worse
        // than no verdict: it reads as checked. Each clause is consumed by the
        // first proposal that claims it, so two loops with identical writes get
        // one verdict each rather than sharing the first. Text alone is not a
        // unique key: the same frame written twice is exactly what a two-loop
        // function produces.
        let mut unclaimed: Vec<Option<&serde_json::Value>> = clauses.iter().map(Some).collect();
        let mut claim = |wanted: &str| -> Option<&serde_json::Value> {
            let position = unclaimed.iter().position(|clause| {
                clause.is_some_and(|clause| {
                    clause
                        .get("acsl_text")
                        .and_then(|value| value.as_str())
                        .is_some_and(|text| normalize_clause_text(text) == wanted)
                })
            })?;
            unclaimed[position].take()
        };

        Some(
            proposals
                .iter()
                .map(|proposal| match expected_clause_text(proposal)
                    .and_then(|text| claim(&text))
                {
                    Some(clause) => json!({
                        "type_checks": clause.get("valid").cloned().unwrap_or(json!(null)),
                        "as_written": clause.get("acsl_text").cloned().unwrap_or(json!(null)),
                        "error": clause.get("frama_c_error").cloned().unwrap_or(json!(null)),
                    }),
                    None => json!({
                        "type_checks": false,
                        "as_written": serde_json::Value::Null,
                        "error": "this proposal planned no clause at all",
                    }),
                })
                .collect(),
        )
    }
}

/// Whitespace-insensitive form, so a clause the planner reformatted still
/// matches the proposal it came from.
pub fn normalize_clause_text(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The clause a proposal is expected to produce, which is what pairs it with
/// the dry run's verdict.
pub fn expected_clause_text(proposal: &serde_json::Value) -> Option<String> {
    match proposal.get("kind").and_then(|value| value.as_str())? {
        "assigns" => proposal
            .get("acsl")
            .and_then(|value| value.as_str())
            .map(normalize_clause_text),
        "loop" => {
            let targets = proposal
                .get("assigns")?
                .as_array()?
                .first()?
                .get("acsl")?
                .as_str()?;
            Some(normalize_clause_text(&format!("loop assigns {targets};")))
        }
        _ => None,
    }
}

impl FramaCMcpServer {
    /// Propose the annotations the code determines, and name the ones it does
    /// not.
    pub async fn propose_annotations_payload(
        &self,
        function: &str,
    ) -> Result<serde_json::Value, McpError> {
        let loops = self.loop_effects_payload(function).await?;
        let writes = self.write_effects_payload(function).await?;
        let annotations = self.current_annotations_payload(function).await?;

        let mut proposals: Vec<serde_json::Value> = Vec::new();
        let mut not_proposed = Vec::new();

        loop_frames(&loops, &annotations, &mut proposals, &mut not_proposed);

        // The function frame, from the same evidence. Locals are not part of an
        // assigns clause, so only what escapes the frame is proposed.
        if !already_annotated(&annotations, "assigns", None) {
            match function_frame(&writes) {
                Frame::Writes(targets) => {
                    let clause = if targets.is_empty() {
                        "\\nothing".to_string()
                    } else {
                        targets.join(", ")
                    };
                    proposals.push(json!({
                        "kind": "assigns",
                        "acsl": format!("assigns {clause};"),
                        "confidence": "derived",
                        "derived_from": "getWriteEffects: globals, writes through parameters, and \
                                         callee assigns",
                        "rationale": "The locations this function writes that its callers can \
                                      observe. A function with no assigns clause is taken to write \
                                      anything, so every caller loses what it knew.",
                    }));
                }
                Frame::Unknown(reason) => {
                    not_proposed.push(json!({
                        "kind": "assigns",
                        "reason": reason,
                    }));
                }
            }
        }

        ensures_gaps(&annotations, &mut not_proposed);

        // Proved rather than asserted, and authoritative. A proposal in the
        // wrong shape plans no clause and would otherwise come back a success
        // with nothing attempted, and one naming a name the contract cannot see
        // type-checks nowhere. Either way it stops being a proposal.
        match self.dry_run_proposals(function, &proposals).await {
            Some(clauses) => {
                for (proposal, clause) in proposals.iter_mut().zip(clauses) {
                    if let Some(object) = proposal.as_object_mut() {
                        object.insert("validated".to_string(), clause);
                    }
                }
                let (kept, rejected): (Vec<_>, Vec<_>) = proposals
                    .into_iter()
                    .partition(|proposal| proposal["validated"]["type_checks"] == json!(true));
                proposals = kept;
                not_proposed.extend(rejected.into_iter().map(|proposal| {
                    json!({
                        "kind": proposal.get("kind").cloned().unwrap_or_else(|| json!(null)),
                        "would_have_been": proposal.get("acsl").cloned().unwrap_or_else(|| {
                            proposal.get("assigns").cloned().unwrap_or_else(|| json!(null))
                        }),
                        "reason": format!(
                            "The locations are right and the clause does not type-check here: {}. \
                             A frame naming something the contract cannot see, a loop index for \
                             instance, has to be restated as a range over what the caller can \
                             name.",
                            proposal["validated"]["error"]
                        ),
                    })
                }));
            }
            None => {
                // Nothing was checked, so nothing is offered. Leaving these
                // under proposals with a null verdict reads as checked.
                not_proposed.extend(proposals.drain(..).map(|proposal| {
                    json!({
                        "kind": proposal.get("kind").cloned().unwrap_or_else(|| json!(null)),
                        "would_have_been": proposal.get("acsl").cloned().unwrap_or_else(|| {
                            proposal.get("assigns").cloned().unwrap_or_else(|| json!(null))
                        }),
                        "reason": "The dry run could not be made, so nothing here is checked. \
                                   The injector remaps loop ids by position and refuses a count \
                                   that does not match, which is what a partly annotated set of \
                                   loops produces.",
                    })
                }));
            }
        }

        Ok(json!({
            "function": function,
            "proposals": proposals,
            "not_proposed": not_proposed,
            "how_to_apply": {
                "tool": "inject_all_annotations",
                "args": {"function": function, "dry_run": true, "annotations": "the proposals array"},
                "note": "Dry-run first. Every proposal here is derived from the AST rather than \
                         from the proof, so it is a starting frame, not a contract: the clauses \
                         that make a proof go through are the ones under not_proposed.",
            },
        }))
    }
}
