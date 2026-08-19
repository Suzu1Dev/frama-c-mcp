# Tutorial corpus

Frama-C / ACSL sample code lifted from `framac.md` (the tutorial article), kept
here as the coverage target for the MCP server. Each file is self-contained and
parses with no extra include paths, except the `mod-*` group, which is
deliberately multi-file.

Provenance is recorded in each file header. `linked-n.c` is adapted: the
kernel `struct sched_domain` is replaced by a local `struct node` so it parses
without kernel headers; the ACSL shape is unchanged.

## Measured baselines

Taken with Frama-C **31.0 (Gallium)** and **33.0 (Arsenic)**, Alt-Ergo only,
`frama-c -wp -wp-rte -wp-prover alt-ergo -wp-timeout 5 <file>` (10 s for
`triangle-behaviors.c`). They are recorded as expected-shape baselines, not as
targets to chase upward: several are intentionally incomplete.

| File | Proved | Note |
|---|---|---|
| `swap-frame.c` | 57 / 57 | |
| `abs-behaviors.c` | 15 / 16 | Unproved goal is the point: `my_abs(INT_MIN)` violates its precondition, and the *next* call is then proved vacuously. |
| `triangle-behaviors.c` | 43 / 43 | Only after `requires b*b + c*c <= INT_MAX`; without it one RTE goal fails. |
| `loops.c` | 46 / 46 | |
| `bsearch.c` | 27 / 27 | Matches the figure `framac.md` reports. |
| `ghost-code.c` | 20 / 20 | |
| `count-logic.c` | 13 / 15 | The two `Count_*` lemmas need induction; SMT alone does not close them. |
| `sort-permutation.c` | 24 / 33 | Inductive `permutation` does not close with defaults. |
| `verker-string.c` | 25 / 42 | Known negative. `framac.md` records 17/24 for `memset` alone across Typed / Typed+cast / Bytes. |
| `linked-n.c` | 8 / 20 | The upstream project also leaves assertions unproved here. |
| `mod-max-abs.c` + `mod-abs.c` + `mod-max.c` | 28 / 28 | Contracts live on the header prototypes, not the definitions. |
| `mod-e2e.c` | workflow fixture | Used by MCP whole-program scheduling and sandbox E2E coverage. |

`eva-rotate.c` is an EVA fixture, not a WP one: run it with entry point
`eva_main`.

## What each file is for

Feature coverage, and the current MCP coverage status:

| File | ACSL / Frama-C feature | MCP coverage status |
|---|---|---|
| `swap-frame.c` | `\valid`, `\valid_read`, `\old`, `\at` + labels, `assigns` frame, `\separated`, aliasing | Baseline WP fixture; no known server gap. |
| `abs-behaviors.c` | behaviors, `complete`/`disjoint`, vacuous-proof trap | Behavior injection and vacuity reporting are supported. |
| `triangle-behaviors.c` | struct + enum in contracts, named behavior groups | Named behavior groups are supported. |
| `loops.c` | loop invariant/assigns/variant, named invariants, `terminates`, `exits` | Covered by `tutorial_loops_expose_named_invariants_and_termination_clauses`. |
| `bsearch.c` | full combined example | Covered by `tutorial_bsearch_rte_obligations_close_under_wp`. |
| `count-logic.c` | overloaded predicates, labelled predicate, recursive logic functions, lemmas | Global ACSL injection is supported. |
| `sort-permutation.c` | two-label predicate, inductive predicate, ghost label statement | Global ACSL injection and ghost labels are supported. |
| `ghost-code.c` | ghost global/local/else-block/loop, nested `/@ @/`, lemma function with `decreases` | Ghost globals, formals, lemma functions, loops, labels, and statements are exposed. |
| `verker-string.c` | axiomatic block, ghost variable, `void *` pointer arithmetic | Global ACSL injection and WP memory model selection are supported. |
| `linked-n.c` | inductive predicate over pointers, uninterpreted logic functions, ghost function parameters | Global ACSL injection and ghost parameters are supported. |
| `mod-*` | modular WP, contracts on header prototypes | Multi-file sandbox extraction is covered by `tutorial_modular_sandbox_uses_header_contracts`. |
| `mod-e2e.c` | whole-program fixture with global state, loop, recursive SCC, and weak callee contract | Whole-program scheduling, sandbox verify/merge, and conclusion persistence are covered. |
| `eva-rotate.c` | non-`main` entry, `Frama_C_*_interval`, slevel/ilevel | EVA entry-point and precision options are supported. |
