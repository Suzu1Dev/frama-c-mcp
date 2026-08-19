# E-ACSL Output

Install probe, executed in this repo on 2026-08-06:

```text
$ command -v e-acsl-gcc.sh || command -v e-acsl-gcc
/Users/jserv/.opam/frama-c-31-check/bin/e-acsl-gcc.sh
```

Runtime instrumentation probe, executed in this repo on 2026-08-06:

```text
$ /Users/jserv/.opam/frama-c-31-check/bin/e-acsl-gcc.sh abs-buggy.c
e-acsl-gcc: fatal error: unexpected output of system getopt
compile-status=1
no a.out.e-acsl
```

How to report this:

- A present `e-acsl-gcc.sh` binary is not enough; instrumentation must compile and the instrumented executable must run.
- In this environment, E-ACSL runtime checking is unavailable until the wrapper/toolchain issue is fixed.
- If instrumentation succeeds elsewhere, run the generated executable and report the concrete input/path that violated a contract.
- E-ACSL explores only the executions you run. It complements WP; it does not replace static proof.
