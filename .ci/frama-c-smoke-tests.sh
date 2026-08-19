#!/usr/bin/env bash

# One test per thing this server asks of a Frama-C it has never met, run before
# the full suites so a version incompatibility is reported as the request that
# failed rather than as forty tests going red at once.
#
# The release build comes first and is not optional: test-mcp-stdio spawns
# target/release/frama-c-mcp from disk rather than the harness cargo just built.

set -eu

cargo build --release

# request compatibility and explicit capability probing
cargo test --test unit self_check_live_reports_frama_c_when_available -- --nocapture
# AST export and sandbox extraction
cargo test --test test-mcp-stdio create_sandbox_keeps_unused_static_target_function -- --nocapture
# EVA compute plus alarm fetch
cargo test --test test-mcp-stdio check_running_eva_alone_accepts_ilevel_and_echoes_options -- --nocapture
# WP run and model request compatibility
cargo test --test test-mcp-stdio run_wp_accepts_installed_model_modifiers -- --nocapture
# WP goal fetch
cargo test --test test-mcp-stdio wp_goals_surface_vacuous_call_precondition_status -- --nocapture
# ACSL validation and injection
cargo test --test test-mcp-stdio inject_all_accepts_global_acsl_first -- --nocapture
