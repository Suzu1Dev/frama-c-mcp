# abs-int Example

This pair demonstrates a missing precondition around `INT_MIN`.

`abs-buggy.c` allows `x == INT_MIN`, so `return -x` can overflow. With `-wp-rte`, WP leaves the signed-overflow goal unproved:

```text
[wp] [Timeout] typed_abs_int_assert_rte_signed_overflow (Qed 0.69ms) (Alt-Ergo) (Cached)
[wp] Proved goals:    9 / 10
```

`abs-fixed.c` adds `requires x > INT_MIN;` and uses a caller that satisfies it:

```text
[wp] Proved goals:   14 / 14
```

On this machine, E-ACSL instrumentation was probed but did not compile:

```text
e-acsl-gcc: fatal error: unexpected output of system getopt
compile-status=1
no a.out.e-acsl
```

That is an environment failure, not a runtime proof or a runtime counterexample.
