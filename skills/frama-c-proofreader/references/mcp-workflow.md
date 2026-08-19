# MCP Workflow

Use this order for normal verification:

```text
self_check {}
reload_project {files, rte: true}
check {function?, timeout?}
get_eva_alarms {function?, status?}
investigate_alarm {property_key, depth}
get_wp_goals {function, status?}
get_wp_goals {function, detail: true}
context {function, want: ["current_annotations", "function_ast"]}
inject_all_annotations {function, dry_run: true, annotations: [{kind, acsl, ...}]}
inject_all_annotations {function, annotations: [{kind, acsl, ...}]}
run_wp {functions: [function]}
get_verification_status {}
```

Stop only when the target function has no relevant invalid or unknown EVA alarms and no non-valid WP goals.

Use a sandbox for speculative annotations:

```text
create_sandbox {function, experiment_id?}
context {function: "experiment:function", want: ["function_ast", "current_annotations"]}
inject_all_annotations {sandbox_name: "experiment:function", dry_run: true, ...}
inject_all_annotations {sandbox_name: "experiment:function", ...}
run_wp {functions: ["experiment:function"]}
get_wp_goals {function: "experiment:function", detail: true}
delete_sandbox {sandbox_name: "experiment:function"}
```

Merge only annotations that passed in the sandbox, then rerun WP on the main function.

If markers go stale after reload, refresh them with `get_eva_alarms` or `get_wp_goals` instead of reusing old ids.
