use rmcp::model::{CallToolResult, Content};
use serde_json::json;
use frama_c_mcp::mcp::types::*;
use frama_c_mcp::mcp::server::wpclass::*;

use frama_c_mcp::mcp::server::*;

#[test]
fn parse_plugin_success_wrapped_result() {
    // Simulates the actual OCaml plugin response: {"result": {"success": true},
    // "hash_label": "..."}
    let json = serde_json::json!({
        "result": {"success": true, "error": null},
        "hash_label": "re_12345678"
    });
    let content = Content::text(json.to_string());
    let result = CallToolResult::success(vec![content]);
    assert!(parse_plugin_success(&result));
}

#[test]
fn parse_plugin_success_false_wrapped() {
    let json = serde_json::json!({
        "result": {"success": false, "error": "ACSL syntax error in function contract"},
        "hash_label": "an_12345678"
    });
    let content = Content::text(json.to_string());
    let result = CallToolResult::success(vec![content]);
    assert!(!parse_plugin_success(&result));
}

#[test]
fn parse_plugin_error_wrapped_result() {
    let json = serde_json::json!({
        "result": {"success": false, "error": "unbound logic variable i"},
        "hash_label": "an_12345678"
    });
    let content = Content::text(json.to_string());
    let result = CallToolResult::success(vec![content]);
    assert_eq!(parse_plugin_error(&result), Some("unbound logic variable i".to_string()));
}

#[test]
fn parse_plugin_success_empty_content() {
    let result = CallToolResult::success(vec![]);
    assert!(!parse_plugin_success(&result));
}

#[test]
fn normalize_acsl_adds_semicolon() {
    assert_eq!(normalize_acsl("n >= 0"), "n >= 0;");
}

#[test]
fn normalize_acsl_strips_extra_semicolons() {
    assert_eq!(normalize_acsl("n >= 0;"), "n >= 0;");
    assert_eq!(normalize_acsl("n >= 0;;"), "n >= 0;");
}

#[test]
fn normalize_acsl_trims_whitespace() {
    assert_eq!(normalize_acsl("  n >= 0  ;  "), "n >= 0;");
}

#[test]
fn normalize_acsl_empty_string() {
    assert_eq!(normalize_acsl(""), ";");
    assert_eq!(normalize_acsl("  ;  "), ";");
}

/// WP refuses the AST.Decl form and wants PVDecl. A substring replace, the
/// obvious way to write this, would also rewrite an `#F` further along.
#[test]
fn a_decl_marker_converts_to_the_pvdecl_form() {
    assert_eq!(pvdecl_marker("#F26").unwrap(), "#v26");
    assert_eq!(pvdecl_marker("#F0").unwrap(), "#v0");
    for wrong in ["#v26", "#s4", "#p10", "F26", ""] {
        assert!(pvdecl_marker(wrong).is_err(), "{wrong}");
    }
}

/// Casing is the caller's business, but the tag Frama-C gets has to be
/// exact, and an unknown one is rejected by the server with an error that
/// names nothing. This names them.
#[test]
fn a_wp_cache_mode_is_checked_before_it_is_sent() {
    assert_eq!(validate_wp_cache_mode("Update").unwrap(), "Update");
    assert_eq!(validate_wp_cache_mode(" update ").unwrap(), "Update");
    assert_eq!(validate_wp_cache_mode("NONE").unwrap(), "None");
    let rejected = validate_wp_cache_mode("yes").unwrap_err().to_string();
    assert!(rejected.contains("Update"), "{rejected}");
    assert!(rejected.contains("Cleanup"), "{rejected}");
}

/// The only signal Frama-C gives for a replayed verdict is a word in a
/// free-form summary string, measured as `(Qed 31ms) (Alt-Ergo 37ms)
/// (Cached)`. Lifted onto the goal so nothing downstream has to know that.
#[test]
fn a_replayed_verdict_is_marked_from_cache() {
    let cached = json!({"stats": {"summary": " (Qed 31ms) (Alt-Ergo 37ms) (Cached)"}});
    assert!(goal_is_from_cache(&cached));

    for fresh in [
        json!({"stats": {"summary": " (Qed 39ms) (Alt-Ergo 41ms)"}}),
        json!({"stats": {"summary": " (CFG) (Trivial)"}}),
        json!({"stats": {}}),
        json!({}),
    ] {
        assert!(!goal_is_from_cache(&fresh), "{fresh}");
    }
}

/// Which marker `getMarkerAt` hands back follows the position, so the two
/// an agent acts on are named and the rest reported as they came.
#[test]
fn marker_kind_names_only_what_was_measured() {
    assert_eq!(marker_kind(Some("#s4")), "statement");
    assert_eq!(marker_kind(Some("#v28")), "declaration");
    assert_eq!(marker_kind(Some("#p10")), "other");
    assert_eq!(marker_kind(None), "none");
}

/// The kind and the id come from one test, so a marker cannot be called a
/// statement and then fail to yield the id that makes it one.
#[test]
fn only_a_digit_marker_yields_a_statement_id() {
    assert_eq!(marker_stmt_id("#s4"), Some(4));
    assert_eq!(marker_stmt_id("#s0"), Some(0));
    for malformed in ["#sabc", "#s", "#s-1", "#s 4", "#v28", "s4", ""] {
        assert_eq!(marker_stmt_id(malformed), None, "{malformed}");
        assert_ne!(marker_kind(Some(malformed)), "statement", "{malformed}");
    }
}

/// Three of `logkind`'s six values are diagnostics. The other three are
/// narration, and the server emits one of them for every request it
/// handles, `getLogs` included, so an unfiltered drain would report its own
/// echo on the next call.
#[test]
fn only_diagnostic_log_kinds_are_reported() {
    for kind in ["ERROR", "WARNING", "FAILURE"] {
        assert!(
            is_diagnostic_message(&json!({"kind": kind, "plugin": "kernel"})),
            "{kind} is a diagnostic"
        );
    }
    for kind in ["FEEDBACK", "RESULT", "DEBUG"] {
        assert!(
            !is_diagnostic_message(&json!({"kind": kind, "plugin": "eva"})),
            "{kind} is narration"
        );
    }
    assert!(!is_diagnostic_message(&json!({
        "kind": "FEEDBACK",
        "plugin": "server",
        "message": "[GET] kernel.services.getLogs",
    })));
    assert!(!is_diagnostic_message(&json!({"plugin": "kernel"})));
}

/// A braced global is complete already, and Frama-C 33.0 rejects all three
/// keywords when the terminator `normalize_acsl` adds is there. The `;`
/// suffix cases pin that a caller who writes one means the same thing.
#[test]
fn normalize_global_acsl_keeps_braced_blocks() {
    for block in [
        "axiomatic Extra { axiom pos: x*x >= 0; }",
        "module M { }",
        "inductive is_even(integer n) { case zero: is_even(0); }",
    ] {
        assert_eq!(normalize_global_acsl(block), block);
        assert_eq!(normalize_global_acsl(&format!("{block};")), block);
    }
    assert_eq!(normalize_global_acsl("  module M { }  "), "module M { }");
}

/// Every other global still gets exactly one semicolon, including the
/// shapes that end in a brace for another reason: `x \in {1, 2, 3}` is why
/// the gate is on the keyword, and `moduleFoo` is why the keyword has to
/// end where the name begins.
#[test]
fn normalize_global_acsl_terminates_everything_else() {
    assert_eq!(normalize_global_acsl("axiom lone: x + 0 == x"), "axiom lone: x + 0 == x;");
    assert_eq!(
        normalize_global_acsl("predicate nonneg(integer x) = x >= 0;;"),
        "predicate nonneg(integer x) = x >= 0;"
    );
    assert_eq!(normalize_global_acsl("x \\in {1, 2, 3}"), "x \\in {1, 2, 3};");
    assert_eq!(normalize_global_acsl("moduleFoo { }"), "moduleFoo { };");
}

// ─── Schema v2 helpers: wrap_funspec_clause / wrap_loop_clause /
// loop_annots_to_acsl ───
//
// Schema v2 replaced the old per-clause-keyword helpers (requires_to_acsl /
// ensures_to_acsl / assigns_to_acsl) with unified wrap_funspec_clause +
// wrap_loop_clause that resolve behavior references against a name → assumes
// table.

fn make_behaviors(pairs: &[(&str, &[&str])]) -> std::collections::HashMap<String, Vec<String>> {
    pairs.iter()
        .map(|(name, assumes)| {
            (name.to_string(), assumes.iter().map(|s| s.to_string()).collect())
        })
        .collect()
}

#[test]
fn wrap_funspec_clause_top_level() {
    let b = make_behaviors(&[]);
    let r = wrap_funspec_clause("requires", "n >= 0", None, &b, "proposed_requires[0]").unwrap();
    assert_eq!(r, "requires n >= 0;");
}

#[test]
fn wrap_funspec_clause_strips_trailing_semicolon() {
    let b = make_behaviors(&[]);
    let r = wrap_funspec_clause("ensures", "\\result == 0;", None, &b, "p").unwrap();
    assert_eq!(r, "ensures \\result == 0;");
}

#[test]
fn wrap_funspec_clause_with_behavior_no_assumes() {
    // Behavior declared with empty assumes list, still valid (named behavior,
    // always applies).
    let b = make_behaviors(&[("sorted", &[])]);
    let r = wrap_funspec_clause("ensures", "\\result == 0", Some("sorted"), &b, "p").unwrap();
    assert_eq!(r, "behavior sorted: ensures \\result == 0;");
}

#[test]
fn wrap_funspec_clause_with_behavior_and_assumes() {
    let b = make_behaviors(&[("sorted", &["n >= 2", "a != \\null"])]);
    let r = wrap_funspec_clause("assigns", "a[0..n-1]", Some("sorted"), &b, "p").unwrap();
    assert_eq!(r, "behavior sorted: assumes n >= 2; assumes a != \\null; assigns a[0..n-1];");
}

#[test]
fn wrap_funspec_clause_undeclared_behavior_errors() {
    let b = make_behaviors(&[("known", &["n > 0"])]);
    let err = wrap_funspec_clause("requires", "p != \\null", Some("unknown"), &b, "proposed_requires[3]")
        .expect_err("undeclared behavior should error");
    assert!(err.contains("'unknown'"), "got: {}", err);
    assert!(err.contains("proposed_requires[3]"), "got: {}", err);
    assert!(err.contains("not declared in proposed_behaviors"), "got: {}", err);
}

#[test]
fn behavior_group_clauses_emit_and_validate_members() {
    let b = make_behaviors(&[("pos", &["x >= 0"]), ("neg", &["x < 0"])]);
    let mut plan = Vec::new();
    let mut failures = Vec::new();
    push_behavior_group_clauses(
        &mut plan,
        &mut failures,
        "complete",
        "proposed_complete_behaviors",
        Some(&[json!(["pos", "neg"])]),
        &b,
    );
    push_behavior_group_clauses(
        &mut plan,
        &mut failures,
        "disjoint",
        "proposed_disjoint_behaviors",
        Some(&[json!(["pos", "missing"])]),
        &b,
    );
    assert_eq!(plan.len(), 1);
    assert_eq!(plan[0].acsl_text, "complete behaviors pos, neg;");
    assert_eq!(failures.len(), 1);
    assert!(matches!(failures[0].failure_type, FailureType::ProposedError));
    assert_eq!(failures[0].proposed_path, "proposed_disjoint_behaviors[0]");
    assert!(failures[0].frama_c_error.contains("'missing'"));
}

#[test]
fn wrap_loop_clause_top_level() {
    let b = make_behaviors(&[]);
    let r = wrap_loop_clause("loop invariant", "0 <= i", None, &b, "p").unwrap();
    assert_eq!(r, "loop invariant 0 <= i;");
}

#[test]
fn wrap_loop_clause_with_behavior() {
    // Loop clauses use "for X: ..." syntax, not "behavior X: assumes ...; loop
    // ...": the behavior's assumes live in the funspec, and the loop just
    // references the name.
    let b = make_behaviors(&[("pos", &["n > 0"])]);
    let r = wrap_loop_clause("loop assigns", "a, i", Some("pos"), &b, "p").unwrap();
    assert_eq!(r, "for pos: loop assigns a, i;");
}

#[test]
fn wrap_loop_clause_undeclared_behavior_errors() {
    let b = make_behaviors(&[]);
    let err = wrap_loop_clause(
        "loop variant", "n - i", Some("missing"), &b, "proposed_loop_annots[0].variant"
    ).expect_err("undeclared should error");
    assert!(err.contains("'missing'"));
    assert!(err.contains("proposed_loop_annots[0].variant"));
}

// double-keyword normalization

/// v-f-fsm stores requires/ensures acsl WITH the keyword (type marker).
/// wrap
/// must strip the leading dup, not produce "requires requires …".
#[test]
fn wrap_funspec_clause_strips_leading_keyword() {
    let b = make_behaviors(&[]);
    // keyword-bearing input (as stored in conclusion) → single keyword
    let r = wrap_funspec_clause("requires", "requires x < 2147483647;", None, &b, "p").unwrap();
    assert_eq!(r, "requires x < 2147483647;");
    let e = wrap_funspec_clause("ensures", "ensures \\result == x + 1;", None, &b, "p").unwrap();
    assert_eq!(e, "ensures \\result == x + 1;");
}

/// bare input (no keyword) still wraps normally, no regression for assigns
/// / sandbox path.
#[test]
fn wrap_funspec_clause_bare_unchanged() {
    let b = make_behaviors(&[]);
    let r = wrap_funspec_clause("requires", "x < 2147483647", None, &b, "p").unwrap();
    assert_eq!(r, "requires x < 2147483647;");
    let a = wrap_funspec_clause("assigns", "\\nothing", None, &b, "p").unwrap();
    assert_eq!(a, "assigns \\nothing;");
}

/// word-boundary: a variable named `requires_foo` must NOT be mis-stripped.
#[test]
fn wrap_funspec_clause_keyword_prefix_variable_not_stripped() {
    let b = make_behaviors(&[]);
    let r = wrap_funspec_clause("requires", "requires_foo > 0", None, &b, "p").unwrap();
    assert_eq!(r, "requires requires_foo > 0;");
}

/// idempotent: stripping an already-bare body is a no-op.
#[test]
fn strip_leading_keyword_idempotent() {
    let once = strip_leading_keyword("requires x < 2;", "requires");
    assert_eq!(once, "x < 2;");
    let twice = strip_leading_keyword(&once, "requires");
    assert_eq!(twice, "x < 2;");
}

/// loop clause multi-word keyword also normalized.
#[test]
fn wrap_loop_clause_strips_leading_keyword() {
    let b = make_behaviors(&[]);
    let r = wrap_loop_clause("loop invariant", "loop invariant 0 <= i", None, &b, "p").unwrap();
    assert_eq!(r, "loop invariant 0 <= i;");
}

#[test]
fn loop_annots_to_acsl_basic() {
    let b = make_behaviors(&[]);
    let annot = json!({
        "stmt_id": 2,
        "loop_label": "outer loop",
        "invariants": [
            {"acsl": "0 <= i <= n"},
            {"acsl": "\\forall k; 0 <= k <= j ==> a[k] <= a[j]"}
        ],
        "assigns": [
            {"acsl": "a, i, j, tmp"}
        ],
        "variant": {"acsl": "(n - 1) - i"}
    });
    let outcomes = loop_annots_to_acsl(&annot, 0, &b);
    // 2 invariants + 1 assigns + 1 variant = 4
    assert_eq!(outcomes.len(), 4);
    let entries: Vec<_> = outcomes.into_iter().map(|o| o.unwrap()).collect();

    assert_eq!(entries[0].0, "loop invariant 0 <= i <= n;");
    assert_eq!(entries[0].2, "proposed_loop_annots[0].invariants[0]");
    assert_eq!(entries[0].3, Some(2i64));
    assert_eq!(entries[0].5.as_deref(), Some("Inv0"));

    assert_eq!(entries[1].0, "loop invariant \\forall k; 0 <= k <= j ==> a[k] <= a[j];");
    assert_eq!(entries[1].2, "proposed_loop_annots[0].invariants[1]");
    assert_eq!(entries[1].5.as_deref(), Some("Inv1"));

    assert_eq!(entries[2].0, "loop assigns a, i, j, tmp;");
    assert_eq!(entries[2].2, "proposed_loop_annots[0].assigns[0]");

    assert_eq!(entries[3].0, "loop variant (n - 1) - i;");
    assert_eq!(entries[3].2, "proposed_loop_annots[0].variant");
}

#[test]
fn loop_annots_to_acsl_with_behavior() {
    let b = make_behaviors(&[("pos", &["n > 0"])]);
    let annot = json!({
        "stmt_id": 5,
        "loop_label": "outer",
        "invariants": [
            {"acsl": "0 <= i <= n"},                            // top-level
            {"acsl": "a[0] >= 0", "behavior": "pos"}            // for pos: ...
        ],
        "assigns": [{"acsl": "a, i", "behavior": "pos"}],
        "variant": null
    });
    let outcomes = loop_annots_to_acsl(&annot, 0, &b);
    assert_eq!(outcomes.len(), 3);
    let entries: Vec<_> = outcomes.into_iter().map(|o| o.unwrap()).collect();
    assert_eq!(entries[0].0, "loop invariant 0 <= i <= n;");
    assert_eq!(entries[0].5.as_deref(), Some("Inv0"));
    assert_eq!(entries[1].0, "for pos: loop invariant a[0] >= 0;");
    assert_eq!(entries[1].5.as_deref(), Some("Inv1"));
    assert_eq!(entries[2].0, "for pos: loop assigns a, i;");
}

#[test]
fn loop_annots_to_acsl_empty_arrays() {
    let b = make_behaviors(&[]);
    let annot = json!({
        "stmt_id": 8,
        "loop_label": "inner",
        "invariants": [],
        "assigns": [],
        "variant": null
    });
    let entries = loop_annots_to_acsl(&annot, 1, &b);
    assert_eq!(entries.len(), 0);
}

#[test]
fn loop_annots_to_acsl_undeclared_behavior_errors() {
    let b = make_behaviors(&[]);
    let annot = json!({
        "stmt_id": 3,
        "loop_label": "outer",
        "invariants": [{"acsl": "i >= 0", "behavior": "ghost"}],
        "assigns": [],
        "variant": null
    });
    let outcomes = loop_annots_to_acsl(&annot, 0, &b);
    assert_eq!(outcomes.len(), 1);
    let (path, msg) = outcomes[0].as_ref().expect_err("should error");
    assert!(path.contains("invariants[0]"));
    assert!(msg.contains("'ghost'"));
}

#[test]
fn classify_failure_syntax_error() {
    assert!(matches!(classify_failure("syntax error in ACSL"), FailureType::SyntaxError));
    assert!(matches!(classify_failure("parse error: unexpected token"), FailureType::SyntaxError));
    assert!(matches!(classify_failure("unexpected identifier 'foo'"), FailureType::SyntaxError));
}

#[test]
fn classify_failure_self_referential() {
    // Logic_typing "unbound" family
    assert!(matches!(
        classify_failure("unbound logic variable 'factorial'"),
        FailureType::ProposedSelfReferential
    ));
    assert!(matches!(
        classify_failure("unbound logic predicate unknown_pred"),
        FailureType::ProposedSelfReferential
    ));
    assert!(matches!(
        classify_failure("unbound logic function f"),
        FailureType::ProposedSelfReferential
    ));
    // Our ast-utils find_enum_tag fallback (truly unbound, not local)
    assert!(matches!(
        classify_failure("Unbound variable foo"),
        FailureType::ProposedSelfReferential
    ));
    // Logic_typing "no such" family
    assert!(matches!(
        classify_failure("no such enum E"),
        FailureType::ProposedSelfReferential
    ));
    assert!(matches!(
        classify_failure("no such predicate or logic function P(int)"),
        FailureType::ProposedSelfReferential
    ));
    // Misc unresolved-name
    assert!(matches!(
        classify_failure("logic label `L' not found"),
        FailureType::ProposedSelfReferential
    ));
    assert!(matches!(
        classify_failure("cannot find field x"),
        FailureType::ProposedSelfReferential
    ));
    assert!(matches!(
        classify_failure("reference to unknown behavior b"),
        FailureType::ProposedSelfReferential
    ));
    assert!(matches!(
        classify_failure("unknown identifier '\\permutation'"),
        FailureType::ProposedSelfReferential
    ));
    assert!(matches!(
        classify_failure("undeclared type 'my_type'"),
        FailureType::ProposedSelfReferential
    ));
}

#[test]
fn classify_failure_local_var_in_funspec() {
    // The actionable message emitted by our ast-utils find_enum_tag wrapper
    // when funspec references a function local.
    assert!(matches!(
        classify_failure(
            "Variable 'i' is a function local; ACSL function-level contracts \
             may only reference caller-visible state (formals, globals, \
             \\result, \\old(formal)). Replace with the caller-visible state \
             being modified."
        ),
        FailureType::ProposedLocalVarInFunspec
    ));
}

#[test]
fn classify_failure_proposed_error() {
    // Type / semantic / duplicate errors → catchall
    assert!(matches!(
        classify_failure("comparison of incompatible types: int * and ℤ"),
        FailureType::ProposedError
    ));
    assert!(matches!(
        classify_failure("behavior b already defined"),
        FailureType::ProposedError
    ));
    assert!(matches!(
        classify_failure("not an assignable left value: n + 1"),
        FailureType::ProposedError
    ));
    assert!(matches!(
        classify_failure("type mismatch in expression"),
        FailureType::ProposedError
    ));
    assert!(matches!(
        classify_failure("some other error"),
        FailureType::ProposedError
    ));
}

#[test]
fn compute_status_no_failures() {
    assert_eq!(compute_status(&[]), "success");
}

#[test]
fn compute_status_all_syntax_errors() {
    let failures = vec![
        InjectionFailure {
            failure_type: FailureType::SyntaxError,
            proposed_path: "proposed_requires[0]".into(),
            acsl_text: "requires \\bad;".into(),
            frama_c_error: "syntax error".into(),
        },
        InjectionFailure {
            failure_type: FailureType::SyntaxError,
            proposed_path: "proposed_ensures[0]".into(),
            acsl_text: "ensures \\bad;".into(),
            frama_c_error: "parse error".into(),
        },
    ];
    assert_eq!(compute_status(&failures), "partial");
}

#[test]
fn compute_status_with_proposed_error() {
    let failures = vec![
        InjectionFailure {
            failure_type: FailureType::SyntaxError,
            proposed_path: "proposed_requires[0]".into(),
            acsl_text: "requires \\bad;".into(),
            frama_c_error: "syntax error".into(),
        },
        InjectionFailure {
            failure_type: FailureType::ProposedError,
            proposed_path: "proposed_assigns".into(),
            acsl_text: "assigns bogus;".into(),
            frama_c_error: "type error".into(),
        },
    ];
    assert_eq!(compute_status(&failures), "proposed_error");
}

#[test]
fn compute_status_self_referential() {
    let failures = vec![InjectionFailure {
        failure_type: FailureType::ProposedSelfReferential,
        proposed_path: "proposed_ensures[0]".into(),
        acsl_text: "ensures \\permutation{a}{\\old(a)};".into(),
        frama_c_error: "unknown identifier".into(),
    }];
    assert_eq!(compute_status(&failures), "proposed_error");
}

#[test]
fn normalize_for_comparison_strips_hash_label() {
    let with_label = "requires \\valid(a + (0 .. n - 1)), re_a3f2b1c8";
    let result = normalize_for_comparison(with_label);
    assert!(result.contains("\\valid"));
    assert!(!result.contains("re_a3f2b1c8"));
}

#[test]
fn acsl_kind_to_ast_kind_mapping() {
    // Function-level → "spec"
    assert_eq!(acsl_kind_to_ast_kind("requires P;"), "spec");
    assert_eq!(acsl_kind_to_ast_kind("ensures Q;"), "spec");
    assert_eq!(acsl_kind_to_ast_kind("assigns \\nothing;"), "spec");
    assert_eq!(acsl_kind_to_ast_kind("behavior foo:"), "spec");
    // Statement-level → "annot"
    assert_eq!(acsl_kind_to_ast_kind("loop invariant P;"), "annot");
    assert_eq!(acsl_kind_to_ast_kind("loop assigns a;"), "annot");
    assert_eq!(acsl_kind_to_ast_kind("loop variant e;"), "annot");
    assert_eq!(acsl_kind_to_ast_kind("assert x > 0;"), "annot");
}

// full_label helper tests

#[test]
fn full_label_without_user_label() {
    assert_eq!(full_label("re_a3f2b1c8", None), "re_a3f2b1c8");
}

#[test]
fn full_label_with_user_label() {
    assert_eq!(full_label("as_af0e6de7", Some("assigns")), "as_af0e6de7_assigns");
}

#[test]
fn full_label_matches_add_annotation_impl_construction() {
    // Verify that the helper produces the same result as the inline logic in
    // add_annotation_impl (the original source of truth).
    let hash_label = "li_44f10e5e";
    // Without user_label
    let inline = match None as Option<&str> {
        Some(ul) => format!("{}_{}", hash_label, ul),
        None => hash_label.to_string(),
    };
    assert_eq!(full_label(hash_label, None), inline);
    // With user_label
    let inline = match Some("assigns") as Option<&str> {
        Some(ul) => format!("{}_{}", hash_label, ul),
        None => hash_label.to_string(),
    };
    assert_eq!(full_label(hash_label, Some("assigns")), inline);
}

#[test]
fn full_label_rollback_would_find_assigns_behavior() {
    // Simulate the exact bug scenario: proposed_assigns has
    // user_label="assigns". add_annotation_impl creates behavior named
    // "{full_label}__spec". rollback must search for the same full_label.
    let hash_label = "as_af0e6de7";
    let user_label = "assigns";
    // The behavior name created by add_annotation_impl:
    let behavior_name = format!("{hash_label}_{user_label}__spec");
    assert_eq!(behavior_name, "as_af0e6de7_assigns__spec");
    // The rollback label (must match the full_label, not just hash_label):
    let rollback_label = full_label(hash_label, Some(user_label));
    assert_eq!(rollback_label, "as_af0e6de7_assigns");
    // OCaml remove_annotation_by_label looks for: label ^ "__spec"
    let search_name = format!("{}__spec", rollback_label);
    assert_eq!(search_name, behavior_name);
    // The old buggy code used just hash_label for rollback:
    let buggy_search = format!("{}__spec", hash_label);
    assert_ne!(buggy_search, behavior_name);
}

/// The sandbox id used to be the nanosecond field of the clock, which gave
/// roughly 30 correlated bits: two create_sandbox calls close together could
/// land on the same id, and the second was then rejected as already in use.
#[test]
fn random_hex_does_not_collide_across_rapid_calls() {
    use std::collections::HashSet;

    let ids = (0..2000).map(|_| random_hex(12)).collect::<HashSet<_>>();
    assert_eq!(ids.len(), 2000, "generated ids collided");
    assert!(ids.iter().all(|id| id.len() == 12));
    assert!(ids
        .iter()
        .all(|id| id.chars().all(|c| c.is_ascii_hexdigit())));

    // The value it feeds must survive the path-segment rule that create_sandbox
    // applies to caller-supplied ids.
    assert!(ids.iter().all(|id| is_safe_path_segment(id)));

    // Widths other than a multiple of the 16-hex block still come out exact.
    for width in [1, 8, 12, 17, 33] {
        assert_eq!(random_hex(width).len(), width);
    }
}

