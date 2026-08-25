//! Regression tests for two `reload_project` bugs, both driven over raw stdio
//! JSON-RPC so the wire-level payload is under test control.
//!
//! Stringified array parameters: some MCP clients serialize an array argument
//! as a JSON string (`files="[\"...\"]"`), which the server used to reject with
//! `invalid type: string, expected sequence`. `deserialize_vec_or_string`
//! accepts both shapes.
//!
//! Empty functions list after a lazy spawn: `fetchFunctions` is cursor-based,
//! so without a preceding `reloadFunctions` the first `reload_project` returns
//! `functions: []`. Leaving the agent to call `list {kind: "functions"}`
//! afterwards would break the documented response contract.

#[path = "harness/mod.rs"]
mod harness;

use harness::{tool_payload, tool_text, workspace_path, McpHandle};

// ─────────────────────────────────────────────────────────────────────────
// Bug 1: stringified array deser
// ─────────────────────────────────────────────────────────────────────────

#[test]
fn stringified_files_array_is_accepted() {
    let test_c = workspace_path("tests/fixtures/test_abs.c");
    assert!(test_c.exists());

    // Use binary's own dir as cwd (does not affect absolute path testing) A
    let (_mcp_dir, mut mcp) = McpHandle::spawn_in_temp_dir();

    // Key wire payload: files are of string type and the content is JSON array
    // This is Claude Code MCP client occasional serialization form
    let stringified_args = format!(r#"{{"files": "[\"{}\"]"}}"#, test_c.display());
    let resp = mcp.call_tool("reload_project", &stringified_args);
    eprintln!(
        "[test1] response: {}",
        serde_json::to_string_pretty(&resp).unwrap()
    );

    // Must succeed (not deser error)
    assert!(
        resp.get("error").is_none(),
        "stringified array should be accepted by deserialize_vec_or_string, got: {:?}",
        resp.get("error")
    );

    let body = tool_text(&resp);
    assert!(
        body.contains(&test_c.display().to_string()),
        "response should echo the file path, got: {}",
        body
    );

    // After fixing #2, there should also be non-empty functions here (test by
    // the way)
    assert!(
        body.contains("\"name\": \"abs_val\""),
        "functions should be non-empty after first spawn (cursor fix), got: {}",
        body
    );
}

// ─────────────────────────────────────────────────────────────────────────
// Bug 2: fetchFunctions cursor. The first spawn returns functions that are not
// empty
// ─────────────────────────────────────────────────────────────────────────

#[test]
fn first_reload_returns_non_empty_functions() {
    let test_c = workspace_path("tests/fixtures/test_abs.c");
    assert!(test_c.exists());

    let (_mcp_dir, mut mcp) = McpHandle::spawn_in_temp_dir();

    // Ordinary JSON array form (**first** reload, triggering lazy spawn)
    let args = format!(r#"{{"files": ["{}"]}}"#, test_c.display());
    let resp = mcp.call_tool("reload_project", &args);
    eprintln!(
        "[test2] response: {}",
        serde_json::to_string_pretty(&resp).unwrap()
    );

    assert!(resp.get("error").is_none(), "no error expected");

    let body = tool_text(&resp);

    // You should be able to see functions after the first spawn (it was an
    // empty array before fixing #2) test_abs.c contains `abs_val` / `square` /
    // `main` functions
    assert!(
        body.contains("\"name\": \"abs_val\""),
        "First time reload_project should return functions (before fix #2 cursor returned null in 'now'), got: {}",
        body
    );
    let payload = tool_payload(&resp);
    assert_eq!(payload["ast_reload_health"]["checked"], true);
    assert_eq!(
        payload["ast_reload_health"]["requests"]["get_files"],
        "kernel.ast.getFiles"
    );
    assert_eq!(
        payload["ast_reload_health"]["requests"]["fetch_functions"],
        "kernel.ast.fetchFunctions"
    );
    assert_eq!(
        payload["ast_reload_health"]["requests"]["fetch_globals"],
        "kernel.ast.fetchGlobals"
    );
    assert_eq!(
        payload["ast_reload_health"]["requests"]["reload_globals"],
        "kernel.ast.reloadGlobals"
    );
    assert_eq!(
        payload["ast_reload_health"]["requests"]["fetch_properties"],
        "kernel.properties.fetchStatus"
    );
    assert!(
        payload["ast_reload_health"]["files_count"]
            .as_u64()
            .unwrap()
            >= 1
    );
    assert!(
        payload["ast_reload_health"]["functions_count"]
            .as_u64()
            .unwrap()
            >= 1
    );
}

// ─────────────────────────────────────────────────────────────────────────
// Bug 1 + 2 combination: stringified array + first spawn are all normal
// ─────────────────────────────────────────────────────────────────────────

#[test]
fn stringified_array_first_spawn_returns_functions() {
    let test_c = workspace_path("tests/fixtures/test_abs.c");
    assert!(test_c.exists());

    let (_mcp_dir, mut mcp) = McpHandle::spawn_in_temp_dir();

    let stringified_args = format!(r#"{{"files": "[\"{}\"]"}}"#, test_c.display());
    let resp = mcp.call_tool("reload_project", &stringified_args);
    eprintln!(
        "[test3] response: {}",
        serde_json::to_string_pretty(&resp).unwrap()
    );

    assert!(resp.get("error").is_none());
    let body = tool_text(&resp);
    assert!(
        body.contains("\"name\": \"abs_val\""),
        "Two fixes must work in series"
    );
}

// ─────────────────────────────────────────────────────────────────────────
// Gap 1 follow-up: other tool params also accept stringified array
// RunWpParams.functions uses the same helper to prevent Bug 1 type reports from
// recurring in other tools.
// ─────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────
// Gap 2 (PR #108 follow-up): in-place reload functions reflect new file content
// (After reloadFunctions is moved to the main function, the branch 1 in-place
// path still refreshes the cursor correctly)
// ─────────────────────────────────────────────────────────────────────────

#[test]
fn in_place_reload_refreshes_functions_to_new_file() {
    let test_abs = workspace_path("tests/fixtures/test_abs.c");
    let factorial = workspace_path("tests/fixtures/factorial.c");
    assert!(test_abs.exists());
    assert!(factorial.exists());

    let (_mcp_dir, mut mcp) = McpHandle::spawn_in_temp_dir();

    // 1st reload (branch 3: first spawn): test_abs.c contains
    // abs_val/square/main
    let r1 = mcp.call_tool(
        "reload_project",
        &format!(r#"{{"files": ["{}"]}}"#, test_abs.display()),
    );
    let body1 = tool_text(&r1);
    eprintln!(
        "[in-place] reload #1 (spawn): {}",
        &body1[..body1.len().min(200)]
    );
    assert!(
        body1.contains("\"name\": \"abs_val\""),
        "The first spawn contains abs_val"
    );
    assert!(
        !body1.contains("\"name\": \"factorial\""),
        "The first spawn should not contain factorial"
    );

    // 2nd reload (branch 1: in-place reload, same rte=false): factorial.c
    // contains factorial function
    let r2 = mcp.call_tool(
        "reload_project",
        &format!(r#"{{"files": ["{}"]}}"#, factorial.display()),
    );
    let body2 = tool_text(&r2);
    eprintln!(
        "[in-place] reload #2 (in-place): {}",
        &body2[..body2.len().min(200)]
    );

    // Key assertion: factorial function (new file content) must be seen after
    // in-place reload can't see abs_val (old file is no longer loaded) If
    // reloadFunctions does not take effect in the in-place path, the cursor is
    // not reset → returns old or empty
    assert!(
        body2.contains("\"name\": \"factorial\""),
        "in-place reload functions should reflect factorial.c (Gap 2 fixes ensure main reloadFunctions cover this path), got: {}",
        body2
    );
    assert!(
        !body2.contains("\"name\": \"abs_val\""),
        "abs_val (old file) should not remain after in-place reload, got: {}",
        body2
    );
}

#[test]
fn run_wp_functions_accepts_stringified_array() {
    let test_c = workspace_path("tests/fixtures/test_abs.c");

    let (_mcp_dir, mut mcp) = McpHandle::spawn_in_temp_dir();

    // First reload to get the project in place
    let reload_args = format!(r#"{{"files": ["{}"]}}"#, test_c.display());
    let r = mcp.call_tool("reload_project", &reload_args);
    assert!(r.get("error").is_none(), "reload pre-step failed");

    // Key: run_wp(functions=...) passes stringified array
    let stringified_args = r#"{"functions": "[\"abs_val\"]"}"#;
    let resp = mcp.call_tool("run_wp", stringified_args);
    eprintln!(
        "[test4] response: {}",
        serde_json::to_string_pretty(&resp).unwrap()
    );

    // Must **not** deser error (business errors such as "no annotations" are
    // OK)
    if let Some(err) = resp.get("error") {
        let msg = err.get("message").and_then(|m| m.as_str()).unwrap_or("");
        assert!(
            !msg.contains("invalid type") && !msg.contains("expected a sequence"),
            "stringified functions array should be accepted by helper and should not be deser error: {}",
            msg
        );
    }

    // No assert success body (abs_val has no annotation, run_wp may return a
    // business error; Only care about the deser layer not exploding)
}

#[test]
fn reload_project_accepts_include_paths() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let include_dir = tmp.path().join("include");
    let source_dir = tmp.path().join("src");
    std::fs::create_dir_all(&include_dir).unwrap();
    std::fs::create_dir_all(&source_dir).unwrap();
    let header = include_dir.join("project-header.h");
    let source = source_dir.join("real-project-main.c");
    std::fs::write(&header, "int project_value(void);\n").unwrap();
    std::fs::write(
        &source,
        r#"#include "project-header.h"
int project_value(void) { return 7; }
"#,
    )
    .unwrap();

    let (_missing_include_dir, mut missing_include) = McpHandle::spawn_in_temp_dir();
    let failed = missing_include.call_tool(
        "reload_project",
        &format!(r#"{{"files": ["{}"]}}"#, source.display()),
    );
    assert!(
        failed.get("error").is_some(),
        "reload without include path should fail"
    );
    drop(missing_include);

    let (_mcp_dir, mut mcp) = McpHandle::spawn_in_temp_dir();
    let resp = mcp.call_tool(
        "reload_project",
        &format!(
            r#"{{"files": ["{}"], "include_paths": ["{}"]}}"#,
            source.display(),
            include_dir.display()
        ),
    );
    assert!(resp.get("error").is_none(), "reload failed: {:?}", resp);
    let body = tool_text(&resp);
    assert!(
        body.contains("\"name\": \"project_value\""),
        "include path reload should list project_value, got: {}",
        body
    );
    assert!(
        body.contains("\"include_paths\""),
        "reload response should echo include paths, got: {}",
        body
    );
}

#[test]
fn reload_project_accepts_compile_database_without_files() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let include_dir = tmp.path().join("include");
    let source_dir = tmp.path().join("src");
    std::fs::create_dir_all(&include_dir).unwrap();
    std::fs::create_dir_all(&source_dir).unwrap();
    let header = include_dir.join("project-header.h");
    let source = source_dir.join("real-project-main.c");
    let database = tmp.path().join("compile-commands.json");
    std::fs::write(&header, "int compile_database_value(void);\n").unwrap();
    std::fs::write(
        &source,
        r#"#include "project-header.h"
int compile_database_value(void) { return 11; }
"#,
    )
    .unwrap();
    std::fs::write(
        &database,
        format!(
            r#"[{{"directory":"{}","file":"{}","arguments":["cc","-I{}","-c","{}"]}}]"#,
            source_dir.display(),
            source.display(),
            include_dir.display(),
            source.display()
        ),
    )
    .unwrap();

    let (_mcp_dir, mut mcp) = McpHandle::spawn_in_temp_dir();
    let resp = mcp.call_tool(
        "reload_project",
        &format!(r#"{{"compilation_database": "{}"}}"#, database.display()),
    );
    assert!(resp.get("error").is_none(), "reload failed: {:?}", resp);
    let body = tool_text(&resp);
    assert!(
        body.contains("\"name\": \"compile_database_value\""),
        "compilation database reload should list compile_database_value, got: {}",
        body
    );
    assert!(
        body.contains(&source.display().to_string()),
        "reload should derive files from compilation database, got: {}",
        body
    );
}

#[test]
fn reload_project_respawns_when_machdep_changes() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let source = tmp.path().join("needs-32-bit.c");
    std::fs::write(
        &source,
        r#"_Static_assert(sizeof(void*) == 4, "requires 32-bit machdep");
int pointer_width_probe(void) { return sizeof(void*); }
"#,
    )
    .unwrap();

    let test_c = workspace_path("tests/fixtures/test_abs.c");

    let (_mcp_dir, mut mcp) = McpHandle::spawn_in_temp_dir();
    let first = mcp.call_tool(
        "reload_project",
        &format!(
            r#"{{"files": ["{}"], "machdep": "x86_64"}}"#,
            test_c.display()
        ),
    );
    assert!(
        first.get("error").is_none(),
        "first reload failed: {:?}",
        first
    );

    let second = mcp.call_tool(
        "reload_project",
        &format!(
            r#"{{"files": ["{}"], "machdep": "x86_32"}}"#,
            source.display()
        ),
    );
    assert!(
        second.get("error").is_none(),
        "machdep reload failed: {:?}",
        second
    );
    let body = tool_text(&second);
    assert!(
        body.contains("\"name\": \"pointer_width_probe\""),
        "machdep reload should list pointer_width_probe, got: {}",
        body
    );
    assert!(
        body.contains("\"machdep\": \"x86_32\""),
        "reload response should echo machdep, got: {}",
        body
    );
}

/// A file Frama-C rejects must not take the session down with it.
///
/// A failed kernel.ast.compute leaves the AST half-initialized, and every later
/// compute on that process answers AbortFatal("kernel"): attempting to get the
/// AST during its initialization. The respawn decision used to look only at rte
/// and the project options, so once that happened every call took the in-place
/// path back into the dead process and even reload_project could not recover.
///
/// Reproduced with a comment nested inside an ACSL annotation, which is
/// ordinary
/// bad input rather than anything exotic.
#[test]
fn reload_project_recovers_after_a_rejected_file() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let bad = tmp.path().join("nested-acsl-comment.c");
    std::fs::write(
        &bad,
        "/*@ requires x > 0; /* nested */\n    assigns \\nothing;\n */\nint f(int x) { return x; }\n",
    )
    .unwrap();

    let good = workspace_path("tests/fixtures/test_abs.c");

    let (_mcp_dir, mut mcp) = McpHandle::spawn_in_temp_dir();

    let first = mcp.call_tool(
        "reload_project",
        &format!(r#"{{"files": ["{}"]}}"#, good.display()),
    );
    assert!(first.get("error").is_none(), "first reload failed: {first:?}");

    // Expected to fail: the point is that it fails without being terminal.
    let _rejected = mcp.call_tool(
        "reload_project",
        &format!(r#"{{"files": ["{}"]}}"#, bad.display()),
    );

    let recovered = mcp.call_tool(
        "reload_project",
        &format!(r#"{{"files": ["{}"]}}"#, good.display()),
    );
    assert!(
        recovered.get("error").is_none(),
        "a rejected file left the session unusable: {recovered:?}"
    );
}

/// `detail` decides how big a reload response is, and summary is the default.
///
/// Untested when it landed, and the shape it changes is the one every reload
/// returns: entries dropped from Frama-C's full function record to name and
/// defined. The suites kept passing because they index by `name`, which the
/// change preserved deliberately, so nothing was holding that decision in
/// place. This does.
#[test]
fn reload_project_detail_governs_the_function_list() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let source = tmp.path().join("detail.c");
    std::fs::write(
        &source,
        "int helper(int x) { return x + 1; }\nint main(void) { return helper(1); }\n",
    )
    .unwrap();


    let (_dir, mut mcp) = McpHandle::spawn_in_temp_dir();

    let summary = mcp.call_tool(
        "reload_project",
        &format!(r#"{{"files": ["{}"]}}"#, source.display()),
    );
    assert!(summary.get("error").is_none(), "reload failed: {summary:?}");
    let summary_payload = tool_payload(&summary);
    let summary_entries = summary_payload["functions"]
        .as_array()
        .expect("functions array")
        .clone();

    assert_eq!(
        summary_payload["detail"], "summary",
        "the response must say which shape it chose: {summary_payload}"
    );

    // The two keys a caller picks a target with, and nothing else. Asserted as
    // an exact key set rather than "contains name", because the point of the
    // default is what it leaves out.
    for entry in &summary_entries {
        let mut keys: Vec<&String> = entry.as_object().expect("entry object").keys().collect();
        keys.sort();
        assert_eq!(
            keys,
            vec!["defined", "name"],
            "summary entry carries more than it should: {entry}"
        );
    }
    assert!(
        summary_entries
            .iter()
            .any(|entry| entry["name"] == "helper"),
        "summary must still name every function: {summary_payload}"
    );

    let full = mcp.call_tool(
        "reload_project",
        &format!(r#"{{"files": ["{}"], "detail": "full"}}"#, source.display()),
    );
    assert!(full.get("error").is_none(), "full reload failed: {full:?}");
    let full_payload = tool_payload(&full);
    let full_entries = full_payload["functions"]
        .as_array()
        .expect("functions array")
        .clone();

    assert_eq!(
        full_payload["detail"], "full",
        "the response must say which shape it chose: {full_payload}"
    );
    assert_eq!(
        full_entries.len(),
        summary_entries.len(),
        "the two shapes must describe the same functions"
    );

    // Full is a superset. Not a fixed key list, because these come from
    // Frama-C's own fetchFunctions record and move with it; what must hold is
    // that asking for more returns more.
    let summary_keys = summary_entries[0].as_object().unwrap().len();
    let full_keys = full_entries[0].as_object().unwrap().len();
    assert!(
        full_keys > summary_keys,
        "full must carry more per entry than summary: {full_keys} vs {summary_keys}"
    );
    for entry in &full_entries {
        assert!(
            entry.get("name").is_some(),
            "full must keep the key callers index by: {entry}"
        );
    }

    // An unrecognised value is refused, not silently downgraded. It used to
    // mean summary, so "Full" and "verbose" both quietly returned less than was
    // asked for and the only hint was the echoed detail field coming back as a
    // value the caller never sent. detail is an enum now, so serde rejects and
    // names the two spellings that work.
    let odd = mcp.call_tool(
        "reload_project",
        &format!(r#"{{"files": ["{}"], "detail": "Full"}}"#, source.display()),
    );

    // Either wire shape counts as a refusal. rmcp 3 reports a parameter it
    // cannot deserialize as a tool result carrying isError, which is what this
    // asserts against today, but a JSON-RPC error object is the other way a
    // server may answer and every other failure test in this suite reads that
    // one. Accepting both keeps the test about the refusal rather than about
    // which envelope carried it.
    let refused_as_tool_error = odd["result"]["isError"] == true;
    let refused_as_rpc_error = odd.get("error").is_some();
    assert!(
        refused_as_tool_error || refused_as_rpc_error,
        "an unrecognised detail must be refused, not downgraded: {odd:?}"
    );
    let refusal = if refused_as_rpc_error {
        odd["error"].to_string()
    } else {
        tool_text(&odd)
    };
    assert!(
        refusal.contains("summary") && refusal.contains("full"),
        "the refusal must name the spellings that work: {refusal}"
    );
}
