use serde_json::json;

use frama_c_mcp::mcp::server::propose::{function_frame, Frame};

#[test]
fn function_frame_keeps_pointer_writes_and_callee_assigns() {
    let frame = function_frame(&json!({
        "writes": [{"target": "*p", "base": "", "global": false}],
        "callee_assigns": [{
            "function": "leaf",
            "assigns": {"kind": "list", "assigns": [{"target": "*q"}]}
        }]
    }));

    assert!(matches!(frame, Frame::Writes(targets)
        if targets == vec!["*p".to_string(), "*q".to_string()]));
}

#[test]
fn function_frame_omits_local_scalar_writes() {
    let frame = function_frame(&json!({
        "writes": [{"target": "local", "base": "local", "global": false}],
        "callee_assigns": []
    }));

    assert!(matches!(frame, Frame::Writes(targets) if targets.is_empty()));
}
