use std::time::Duration;

use frama_c_mcp::frama_c::client::*;

/// The gate and the payload are asked separately, because they are now
/// separate functions. Neither writes the process environment: that is a
/// process-wide change and this binary runs its tests on many threads.
#[test]
fn protocol_trace_line_is_env_gated_and_metadata_only() {
    assert!(!trace_setting_enables(None));
    for off in ["", "0", "false", "FALSE"] {
        assert!(!trace_setting_enables(Some(off)), "{off} should not enable");
    }
    assert!(trace_setting_enables(Some("1")));

    let line = protocol_trace_line(
        "GET",
        Some("kernel.ast.getFiles"),
        Some("RQ.1"),
        Some(Duration::from_millis(12)),
        Some(42),
        Some("DATA"),
    );

    let value: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(value["event"], "frama_c_protocol");
    assert_eq!(value["command"], "GET");
    assert_eq!(value["request"], "kernel.ast.getFiles");
    assert_eq!(value["id"], "RQ.1");
    assert_eq!(value["elapsed_ms"], 12);
    assert_eq!(value["payload_bytes"], 42);
    assert_eq!(value["result_kind"], "DATA");
    assert!(value.get("data").is_none());
}
