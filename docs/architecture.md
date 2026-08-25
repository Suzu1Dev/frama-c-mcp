# Frama-C MCP Server architecture

## Current architecture: Rust MCP server + Frama-C server (Unix socket) + ast-utils plugin

```text
LLM agent
  |
  | MCP JSON-RPC over stdio
  v
frama-c-mcp (Rust)
  |-- MCP layer and tool router
  |-- session state, conclusions, project state, and project lock
  `-- Frama-C client: GET/SET/EXEC/POLL over Unix sockets
        |-- main Frama-C process + ast-utils plugin
        `-- sandbox Frama-C processes + ast-utils plugin
              `-- standalone temporary C files for isolated CEGIS

Run: frama-c-mcp --frama-c /path/to/frama-c
The first reload_project starts the main Frama-C process.
```

## Components

### 1. Rust MCP server (`src/`)

| Modules | Responsibilities |
|---|---|
| `mcp/*.rs` | 14 tool implementations, one `#[tool_router]` per module, split by domain below |
| `mcp/server.rs` | Server state, sandbox registry, conclusion persistence, and helpers shared by the tool modules |
| `mcp/project.rs`, `mcp/analysis.rs`, `mcp/annotations.rs`, `mcp/sandbox.rs`, `mcp/conclusions.rs` | The tool handlers themselves |
| `mcp/wpcli.rs` | The four paths that run Frama-C as a command line rather than through the socket, because WP settings are process state |
| `mcp/eacsl.rs` | E-ACSL instrumentation, compilation, and execution: the only code here that runs the program under analysis |
| `mcp/receipt.rs` | Proof receipts: source hashes, environment, effective WP configuration, per-goal statuses, and the digest over them |
| `mcp/selfcheck.rs` | Request probe tables and capability reporting |
| `mcp/wpclass.rs` | WP failure classification and proofread findings |
| `mcp/types.rs` | Tool parameter types |
| `frama-c/client.rs` | Frama-C client: GET/SET/EXEC/POLL semantics and response classification |
| `frama-c/codec.rs`, `frama-c/transport.rs` | Protocol codec (`S`+3 hex / `L`+7 hex framing) + Unix socket transmission |
| `state.rs` | Session state, per-function verification conclusion, project-level orchestration status, project lock |
| `topo.rs` | Tarjan SCC + Kahn layering for bottom-up verification order |

### 2. ast-utils Frama-C plugin (`ast-utils/`, **required**)

Frama-C's built-in server registers 200+ requests, but they are not enough for the annotation-driven verification cycle. `ast-utils` adds custom requests for MCP-backed workflows:

- AST export and context: `getFunctionAst`, `getCilContext`, `getContractContext`, `getWriteEffects`, `getLoopEffects`, `getLogicDeps`, `getRteObligations`, `getMarkerFunction`
- ACSL validation and injection: `getAcslValidation`, `execAddAnnotation`, removal helpers, and ghost-code helpers
- WP support: `execSetWpConfig`, `getVcDetails`
- Sandbox lifecycle and extraction: `execCreateSandbox`, `execDeleteSandbox`, `extractFunctionWithDeps`
- Internal equivalence checks: `execExtractAnnotations`
- Source/debug output: `printSource`

Two registered plugin requests are intentionally not exposed as MCP tools:
`execExtractAnnotations` is internal to annotation equivalence checks, and
`dumpProject` remains CLI-only for full F-CIL JSON export.

`getSallstmts` and `extractMultipleFunctions` were removed rather than left
unexposed. Neither had a caller, and the second was worse than unused: its own
comment recorded that its output has known ordering and typedef bugs, while it
stayed callable by any agent reading the request list. A verification tool that
hands back subtly wrong C is the failure mode with the highest cost.

**Plugin not installed means the tools above fail.** Install it on the same opam switch as `frama-c`.

`run_e_acsl` needs no plugin request: it shells out to `e-acsl-gcc`, which ships with Frama-C. `self_check` runs the binary rather than just looking for it, since an installed wrapper can still be unable to compile anything, and reports it as unavailable with the tool's own error under `tool_probe` rather than failing at call time.

### 3. Sandbox model

`create_sandbox` extracts the target function **together with all dependencies** into a separate temporary C file, and starts **another** Frama-C process on it instead of copying the AST in the main project:

- The agent repeatedly tries ACSL, runs WP, and reads VC details in the sandbox without affecting the main project.
- When the sandbox fails or becomes contaminated, call `delete_sandbox`, then `create_sandbox` with the same function and experiment id.
- After passing verification, merge verified structured annotations into the main project and run `run_wp`.
- Namespace `experiment_id:function_name`, supports multi-sandbox concurrency (`--max-sandboxes` default 32)

**Why use an independent process instead of in-process replication**: copying the function AST in the main project can trip Frama-C state dependencies (`AbortFatal`) and can change WP VC quality. A separate process gives a clean, discardable, concurrent isolation boundary.

### 4. Bottom-up full program orchestration

`verify_program_step` computes the callee-before-caller verification order, persists orchestration state, and can lock `reload_project` plus main-instance `run_wp` during batch work. It answers with one `next_action` rather than a batch, plus the unverified `frontier` and any `blocked_functions`, all under a hard `payload_budget` cap that truncates lists and reports the dropped count instead of omitting them silently. Ready functions are verified through the public sandbox tools: `create_sandbox`, `inject_all_annotations {dry_run: true}`, `inject_all_annotations`, `run_wp`, and `get_wp_goals`.

### 5. Fail-closed accounting

Verdict and completeness are separate axes. `check` reports `verdict: "proved"` only when `incomplete[]` is empty, so a step that did not run cannot read as a clean result; the CLI's `--require-complete` turns any `incomplete[]` entry into a non-zero exit.

Evidence travels with the result. `check`, `run_wp`, and stored conclusions carry a `proof_receipt` (`frama-c-mcp.proof-receipt.v4`) holding the source hash, AST digest, environment, effective WP configuration, per-goal statuses, and a sha256 over all of it, so two runs are comparable exactly when their receipts match. `run_wp` additionally flags callees whose contracts it assumed rather than proved, and conclusions record `stale_dependencies` and `stale_proof_environment` when a callee conclusion or the prover environment moves under them.

## Design Decisions

### Why Rust + Frama-C Server

Four options were evaluated:

| Solution | MCP Protocol | Frama-C Capability | Engineering Difficulty | Performance |
|------|---------|-------------|---------|------|
| A: Rust + Frama-C Server | ★★★★★ | ★★★☆☆→★★★★★ | Medium | ms level |
| B: Pure OCaml plugin | ★★☆☆☆ | ★★★★★ | Medium to high | ns level |
| C: Mixed (superset of A) | ★★★★★ | ★★★★★ | High | ms level |
| D: Rust + CLI subprocess | ★★★★★ | ★☆☆☆☆ | Low | Seconds |

Core reasons for choosing A:

1. **MCP ecosystem maturity**: rmcp is the official Rust MCP SDK; there is no MCP SDK available on the OCaml side (`ocaml-mcp` requires OCaml 5.0+, this project environment is 4.14.2)
2. **Frama-C Server already exists**: The built-in Server plugin (the backend of Ivette GUI) supports Unix Socket and has registered 200+ requests. There is no need to build an interaction layer from scratch.
3. **Asynchronous capability**: EVA/WP may run for several minutes, Rust (tokio) has natural support; OCaml 4.14 lacks asynchronous means
4. **Progressive enhancement**: First use the built-in request to cover the basic tools, and then write OCaml plugin extensions when needed

**Point 4 has already happened**: The annotation-driven verification cycle requires capabilities that the built-in requests cannot provide, so `ast-utils` implements the originally reserved "Phase 3 evolution to plan C". **The current form is solution C (Rust server + custom OCaml plugin)**, not pure A.

### Decision History

| Date | Decision | Status |
|------|------|------|
| 2026-02-17 | v2.2 design: Rust + ZMQ | [Deprecated transport layer] ZMQ is not available, change to Unix Socket; Tool definition and type system retained |
| 2026-02-18 | Pure OCaml plugin (Approach 5) | [Abandoned] MCP ecology is insufficient and asynchronous is limited. The Rust/OCaml FFI spikes behind this are in git history at 32438cb, under `experiments/`; they were removed once the socket transport landed. |
| 2026-02-19 | Rust + Frama-C Server (Unix Socket) | Selected (Option A) |
| 2026-02 | Manual server + `--socket` connection | [Deprecated] Changed to MCP server lazy spawn (`--frama-c`) |
| 2026 | Add `ast-utils` plugin + sandbox + bottom-up orchestration | **current** (actually fell to plan C) |

## Key technical details

**Frama-C Server Protocol** (not JSON-RPC):
- Commands: `GET(id,request,data)`, `SET(id,request,data)`, `EXEC(id,request,data)`, `POLL`, `SHUTDOWN`
- Reply: `DATA(id,data)`, `ERROR(id,msg)`, `SIGNAL(id)`, `REJECTED(id)`
- Transmission: Unix Socket, custom framing (`S`+3 hex / `L`+7 hex length prefix)
- `SET`/`EXEC` queued asynchronous - POLL is required to get the intermediate SIGNAL and the final result

The framing and command set above are unchanged between Frama-C 31.0 and 33.0.
Request names are not: 33.0 rejects the `plugins.eva.general.*` group that 31.0
used, and drops `plugins.wp.setProvers`. The client tries the 33.0 name first
and falls back where a fallback exists. See
[reference/frama-c-server-protocol-guide.md](reference/frama-c-server-protocol-guide.md)
for the full list and how to regenerate it.

**AST reload**: `setFiles([])` → `setFiles(files)` → `compute` is required; direct `setFiles(same value)` is a no-op (due to Frama-C's state dependency system). Same as Ivette's `reparseFiles()`.

**fetch API is incremental**: `fetchFunctions` only returns the full amount for the first time, and only changes after that; `reloadFunctions` resets the cursor before the full amount is needed.

**WP Configuration**: Memory model `Typed+nocast` - a cast makes the VC fail instead of silently letting it go, except when the cast reaches the goal: on Frama-C 33 with Why3 1.8.2 that aborts Why3 and WP stamps the goals `FAILED` without any prover having answered, and the same contract proves under `Typed+cast`. `check` reports that through `wp_backend_diagnosis` and the `WP_BACKEND_ANOMALY` code, read off the message stream rather than off the goals, and attributed to goals by their `FAILED` status because the abort text names a goal kind and never a goal. The default `assigns \nothing` of an uncontracted callee is unsound (WP Manual §2.1), so sandbox extraction generates an empty stub for a callee that lacks explicit `assigns`.

**Published schema versus accepted input**: `tools/list` carries only what the
JSON schema declares, and `#[schemars(skip)]` removes a field from that schema
without touching serde. The eleven per-kind `proposed_*` parameters and the
analysis tuning knobs on `check` are hidden that way: still accepted, no longer
advertised. That is what let `inject_all_annotations` move to a single tagged
`annotations` array without breaking a caller.

**JSON key order**: `serde_json` turns on `preserve_order` to preserve the source code order of the plugin emit (otherwise alphabetical traversal will reverse structures such as `then_body`/`else_body`).
