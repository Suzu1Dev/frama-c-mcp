
use frama_c_mcp::mcp::status::*;
use serde_json::json;

#[test]
fn own_status_prefers_the_normalized_spelling() {
    let goal = json!({"status": "TIMEOUT", "raw_status": "TIMEOUT",
                      "normalized_status": "timeout"});
    assert_eq!(own_status(&goal), Some("timeout"));
}

#[test]
fn own_status_answers_a_raw_wire_goal() {
    let goal = json!({"status": "VALID"});
    assert_eq!(own_status(&goal), Some("VALID"));
    assert!(own_status_is_proved(&goal));
}

#[test]
fn own_status_ignores_the_property_verdict() {
    // The abs-int-buggy.c shape: WP proved the goal, the property it hangs off
    // did not consolidate to valid. Asking what WP decided must not return the
    // property's answer.
    let goal = json!({"normalized_status": "valid",
                      "normalized_property_status": "unknown"});
    assert_eq!(own_status(&goal), Some("valid"));
    assert!(own_status_is_proved(&goal));
}

#[test]
fn consolidated_status_falls_back_to_the_property() {
    let goal = json!({"normalized_property_status": "valid_but_dead"});
    assert_eq!(consolidated_status(&goal), Some("valid_but_dead"));
    assert_eq!(own_status(&goal), None);
}

#[test]
fn a_row_with_no_status_is_not_proved() {
    assert!(!own_status_is_proved(&json!({})));
    assert_eq!(own_status(&json!({})), None);
}

#[test]
fn is_proved_accepts_either_spelling_and_nothing_else() {
    assert!(is_proved("valid"));
    assert!(is_proved("VALID"));
    assert!(!is_proved("valid_under_hyp"));
    assert!(!is_proved("considered_valid"));
    assert!(!is_proved(""));
}
