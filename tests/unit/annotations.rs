use frama_c_mcp::mcp::server::*;
use serde_json::json;
use frama_c_mcp::mcp::types::*;

use frama_c_mcp::mcp::server::annotations::*;

#[test]
fn validation_result_is_valid_accepts_wrapped_plugin_shape() {
    assert!(validation_result_is_valid(&json!({
        "result": {"valid": true, "error": null}
    })));
    assert!(!validation_result_is_valid(&json!({
        "result": {"valid": false, "error": "bad"}
    })));
}

#[test]
fn wrap_assert_clause_accepts_bare_or_keyword() {
    assert_eq!(wrap_assert_clause("x > 0"), "assert x > 0;");
    assert_eq!(wrap_assert_clause("assert x > 0;"), "assert x > 0;");
}



fn params(annotations: serde_json::Value) -> InjectAllAnnotationsParams {
    serde_json::from_value(json!({
        "function": "f",
        "annotations": annotations,
    }))
    .expect("params")
}

#[test]
fn tagged_entries_fan_out_to_their_fields() {
    let mut p = params(json!([
        {"kind": "requires", "acsl": "n >= 0"},
        {"kind": "ensures", "acsl": "\\result >= 0"},
        {"kind": "requires", "acsl": "n < 100"},
        {"kind": "assigns", "acsl": "\\nothing"},
        {"kind": "assert", "stmt_id": 7, "acsl": "n != 0"},
        {"kind": "loop", "stmt_id": 3, "invariants": [{"acsl": "0 <= i"}]},
        {"kind": "terminates", "acsl": "\\false"},
    ]));
    let origin = expand_tagged_annotations(&mut p, &mut Vec::new()).expect("expand");

    assert!(p.annotations.is_none(), "tagged input is consumed");
    let requires = p.proposed_requires.expect("requires");
    assert_eq!(requires.len(), 2);
    assert_eq!(requires[0]["acsl"], "n >= 0");
    assert_eq!(requires[1]["acsl"], "n < 100");
    assert!(requires[0].get("kind").is_none(), "kind is stripped");
    assert_eq!(p.proposed_ensures.expect("ensures").len(), 1);
    assert_eq!(p.proposed_assigns.expect("assigns").len(), 1);
    assert_eq!(p.proposed_asserts.expect("asserts")[0]["stmt_id"], 7);
    assert_eq!(p.proposed_loop_annots.expect("loops")[0]["stmt_id"], 3);
    assert_eq!(p.proposed_terminates.expect("terminates")["acsl"], "\\false");

    // Internal paths map back to the caller's array positions.
    assert_eq!(origin["proposed_requires[0]"], 0);
    assert_eq!(origin["proposed_requires[1]"], 2);
    assert_eq!(origin["proposed_ensures[0]"], 1);
    assert_eq!(origin["proposed_terminates"], 6);
}

#[test]
fn diagnostics_report_the_caller_index() {
    let mut p = params(json!([
        {"kind": "requires", "acsl": "ok"},
        {"kind": "ensures", "acsl": "bad"},
        {"kind": "requires", "acsl": "also bad"},
    ]));
    let origin = expand_tagged_annotations(&mut p, &mut Vec::new()).expect("expand");

    let mut response = json!({
        "failures": [
            {"proposed_path": "proposed_requires[1]", "frama_c_error": "boom"},
            {"proposed_path": "proposed_ensures[0]", "frama_c_error": "boom"},
        ],
        "clauses": [{"derived_from": "proposed_requires[0]"}],
    });
    relabel_origins(&mut response, &origin);

    assert_eq!(response["failures"][0]["proposed_path"], "annotations[2]");
    assert_eq!(response["failures"][1]["proposed_path"], "annotations[1]");
    assert_eq!(response["clauses"][0]["derived_from"], "annotations[0]");
}

/// Loop clauses report through a sub-path, so relabelling has to match the
/// leading segment rather than the whole string.
#[test]
fn nested_loop_paths_relabel_and_keep_their_detail() {
    let mut p = params(json!([
        {"kind": "requires", "acsl": "n >= 0"},
        {"kind": "loop", "stmt_id": 3, "invariants": [{"acsl": "a"}, {"acsl": "b"}]},
    ]));
    let origin = expand_tagged_annotations(&mut p, &mut Vec::new()).expect("expand");

    let mut response = json!({"failures": [
        {"proposed_path": "proposed_loop_annots[0].invariants[1]"},
        {"proposed_path": "proposed_loop_annots[0].assigns[0]"},
        {"proposed_path": "proposed_loop_annots[0].variant"},
        {"proposed_path": "proposed_loop_annots[0]"},
    ]});
    relabel_origins(&mut response, &origin);

    let f = &response["failures"];
    assert_eq!(f[0]["proposed_path"], "annotations[1].invariants[1]");
    assert_eq!(f[1]["proposed_path"], "annotations[1].assigns[0]");
    assert_eq!(f[2]["proposed_path"], "annotations[1].variant");
    assert_eq!(f[3]["proposed_path"], "annotations[1]");
}

/// The wrapping errors name the internal path inside prose, and `index` is
/// derived from that path, so both have to follow the relabel.
#[test]
fn error_text_and_index_follow_the_relabel() {
    let mut p = params(json!([
        {"kind": "requires", "acsl": "a"},
        {"kind": "requires", "acsl": "b", "behavior": "typo"},
    ]));
    let origin = expand_tagged_annotations(&mut p, &mut Vec::new()).expect("expand");

    let mut response = json!({"failures": [{
        "proposed_path": "proposed_requires[1]",
        "index": 1,
        "frama_c_error": "behavior 'typo' referenced at proposed_requires[1] \
                          but not declared in proposed_behaviors",
    }]});
    relabel_origins(&mut response, &origin);

    let f = &response["failures"][0];
    assert_eq!(f["proposed_path"], "annotations[1]");
    assert_eq!(f["index"], 1, "index tracks the caller array, not the kind");
    let text = f["frama_c_error"].as_str().expect("error text");
    assert!(!text.contains("proposed_"), "internal names leaked: {text}");
    assert!(text.contains("annotations[1]"), "got: {text}");
}

#[test]
fn legacy_fields_still_work_and_are_not_relabeled() {
    let mut p: InjectAllAnnotationsParams = serde_json::from_value(json!({
        "function": "f",
        "proposed_requires": [{"acsl": "n >= 0"}],
    }))
    .expect("params");
    let origin = expand_tagged_annotations(&mut p, &mut Vec::new()).expect("expand");

    assert!(origin.is_empty(), "no tagged entries means no remapping");
    assert_eq!(p.proposed_requires.expect("requires").len(), 1);

    let mut response = json!({"failures": [{"proposed_path": "proposed_requires[0]"}]});
    relabel_origins(&mut response, &origin);
    assert_eq!(
        response["failures"][0]["proposed_path"], "proposed_requires[0]",
        "legacy callers keep the paths they know"
    );
}

/// `successful` is pasted straight into store_function_conclusion, whose
/// gate matches derived_from against the internal form. Relabelling it
/// would fail every conclusion a tagged caller writes.
#[test]
fn successful_entries_keep_their_internal_provenance() {
    let mut p = params(json!([{"kind": "requires", "acsl": "n >= 0"}]));
    let origin = expand_tagged_annotations(&mut p, &mut Vec::new()).expect("expand");

    let mut response = json!({
        "successful": [{"derived_from": "proposed_requires[0]"}],
        "failures": [{"proposed_path": "proposed_requires[0]"}],
    });
    relabel_origins(&mut response, &origin);

    assert_eq!(
        response["successful"][0]["derived_from"], "proposed_requires[0]",
        "provenance must survive for the conclusion gate"
    );
    assert_eq!(response["failures"][0]["proposed_path"], "annotations[0]");
}

/// Expansion consumes `annotations`, so a second call yields an empty map
/// and silently turns every relabel into a no-op. inject_all_annotations
/// therefore expands once and threads the map into inject_all_impl.
#[test]
fn expanding_twice_would_discard_the_origin_map() {
    let mut p = params(json!([{"kind": "requires", "acsl": "n >= 0"}]));
    assert!(!expand_tagged_annotations(&mut p, &mut Vec::new()).expect("expand").is_empty());
    assert!(expand_tagged_annotations(&mut p, &mut Vec::new()).expect("expand").is_empty());
}

#[test]
fn malformed_entries_are_rejected() {
    for bad in [
        json!([{"acsl": "n >= 0"}]),
        json!([{"kind": "nonsense", "acsl": "x"}]),
        json!(["not an object"]),
        json!([{"kind": "terminates", "acsl": "a"}, {"kind": "terminates", "acsl": "b"}]),
    ] {
        let mut p = params(bad.clone());
        assert!(
            expand_tagged_annotations(&mut p, &mut Vec::new()).is_err(),
            "should reject {bad}"
        );
    }
}
