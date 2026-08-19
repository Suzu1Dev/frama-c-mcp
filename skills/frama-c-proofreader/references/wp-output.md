# WP Output

Install check:

```text
$ /Users/jserv/.opam/4.14.1/bin/frama-c -version
33.0 (Arsenic)
```

Buggy `abs-int` run, executed in this repo on 2026-08-06:

```text
$ /Users/jserv/.opam/4.14.1/bin/frama-c -wp -wp-rte skills/frama-c-proofreader/examples/abs-int/abs-buggy.c
[wp] 8 goals scheduled
[wp] [Timeout] typed_abs_int_assert_rte_signed_overflow (Qed 0.69ms) (Alt-Ergo) (Cached)
[wp] [Cache] updated:1
[wp] Proved goals:    9 / 10
  Timeout:         1
```

Fixed `abs-int` run, executed in this repo on 2026-08-06:

```text
$ /Users/jserv/.opam/4.14.1/bin/frama-c -wp -wp-rte skills/frama-c-proofreader/examples/abs-int/abs-fixed.c
[wp] 12 goals scheduled
[wp] [Cache] not used
[wp] Proved goals:   14 / 14
```

How to read this:

- `Proved goals: 9 / 10` means one generated obligation was not proved.
- `typed_abs_int_assert_rte_signed_overflow` is an RTE signed-overflow goal, not a postcondition name.
- `Timeout` means the prover did not establish the goal. Check whether the property is false, underspecified, or just hard.
- Cache lines are incidental output here. Do not add `-wp-cache update` to workflows without measured need and a Why3-session plan.
- A fully proved run proves the generated obligations for the ACSL and `-wp-rte` configuration that ran; it does not prove omitted requirements.
