
use frama_c_mcp::topo::*;

fn names(r: &[ReadyFunc]) -> Vec<String> {
    r.iter().map(|x| x.function.clone()).collect()
}

#[test]
fn ready_chain() {
    // a -> b -> c
    let vs: Vec<String> = vec!["a".into(), "b".into(), "c".into()];
    let es = vec![("a".into(), "b".into()), ("b".into(), "c".into())];
    assert_eq!(names(&compute_ready_functions(&vs, &es, &["c".into()], &[])), vec!["b"]);
    assert_eq!(
        names(&compute_ready_functions(&vs, &es, &["b".into(), "c".into()], &[])),
        vec!["a"]
    );
}

// ── VO-completeness fix: flatten_levels_to_vo_scc ──
fn defset(fs: &[&str]) -> std::collections::HashSet<String> {
    fs.iter().map(|s| s.to_string()).collect()
}

#[test]
fn flatten_vo_bottom_up_all_defined() {
    // a→b→c: c is the leaf (level 0), a is the root (high level). VO should be
    // bottom-up (c precedes a).
    let vs: Vec<String> = vec!["a".into(), "b".into(), "c".into()];
    let es = vec![("a".into(), "b".into()), ("b".into(), "c".into())];
    let levels = compute_topological_order(&vs, &es);
    let (vo, scc) = flatten_levels_to_vo_scc(&levels, &defset(&["a", "b", "c"]));
    assert_eq!(vo.len(), 3, "VO includes all defined");
    let pos = |x: &str| vo.iter().position(|v| v == x).unwrap();
    assert!(pos("c") < pos("a"), "VO bottom-up: leaf c precedes root a");
    assert_eq!(scc.len(), 3);
    assert!(scc.iter().all(|g| !g.is_cycle && g.members.len() == 1));
}

#[test]
fn flatten_excludes_declared_only() {
    // a→lib, lib is library declared-only (not in the defined set) → VO does
    // not contain lib (anti-over-complete)
    let vs: Vec<String> = vec!["a".into(), "lib".into()];
    let es = vec![("a".into(), "lib".into())];
    let levels = compute_topological_order(&vs, &es);
    let (vo, scc) = flatten_levels_to_vo_scc(&levels, &defset(&["a"]));
    assert_eq!(vo, vec!["a".to_string()], "VO only contains defined a, not lib");
    assert!(
        scc.iter().all(|g| !g.members.contains(&"lib".to_string())),
        "All declared-only groups are skipped"
    );
}

#[test]
fn flatten_scc_level_carried() {
    // a↔b ring + a→c: scc_groups with correct level + is_cycle, ring group
    // level is higher than leaf c
    let vs: Vec<String> = vec!["a".into(), "b".into(), "c".into()];
    let es = vec![
        ("a".into(), "b".into()),
        ("b".into(), "a".into()),
        ("a".into(), "c".into()),
    ];
    let levels = compute_topological_order(&vs, &es);
    let (vo, scc) = flatten_levels_to_vo_scc(&levels, &defset(&["a", "b", "c"]));
    assert_eq!(vo.len(), 3);
    let cyc = scc.iter().find(|g| g.is_cycle).expect("a↔b should be the is_cycle group");
    let mut m = cyc.members.clone();
    m.sort();
    assert_eq!(m, vec!["a".to_string(), "b".to_string()]);
    let c_lvl = scc
        .iter()
        .find(|g| g.members == vec!["c".to_string()])
        .unwrap()
        .level;
    assert!(cyc.level > c_lvl, "The ring group level is higher than leaf c (the level is carried correctly)");
}

#[test]
fn scc_single_self_loop_is_cycle() {
    // M1 regression: self-recursion f→f is single-member SCC + self-cycle →
    // is_cycle=true (fixed by condensation The self_loop_names of the previous
    // snapshot are directly derived; the old version of the name set will
    // unwrap_or(false) when the names mismatch/duplicate names. Silent omission
    // is judged as false). g→f is a normal call, g has no self-loop → g group
    // is_cycle=false.
    let vs: Vec<String> = vec!["f".into(), "g".into()];
    let es = vec![("f".into(), "f".into()), ("g".into(), "f".into())];
    let levels = compute_topological_order(&vs, &es);
    let (_vo, scc) = flatten_levels_to_vo_scc(&levels, &defset(&["f", "g"]));
    let fg = scc
        .iter()
        .find(|g| g.members == vec!["f".to_string()])
        .expect("f group");
    assert!(fg.is_cycle, "Self-recursive f→f should be_cycle=true");
    let gg = scc
        .iter()
        .find(|g| g.members == vec!["g".to_string()])
        .expect("g group");
    assert!(!gg.is_cycle, "g has no self-loop or non-cycle → is_cycle=false");
}

#[test]
fn ready_scc_not_grouped() {
    // a↔b, both → c (INV3: SCC is not tied to a group, each is independent and
    // ready)
    let vs: Vec<String> = vec!["a".into(), "b".into(), "c".into()];
    let es = vec![
        ("a".into(), "b".into()),
        ("b".into(), "a".into()),
        ("a".into(), "c".into()),
        ("b".into(), "c".into()),
    ];
    let r = compute_ready_functions(&vs, &es, &["c".into()], &[]);
    assert_eq!(names(&r), vec!["a", "b"]); // external callee c done → a,b each ready
    assert!(r.iter().all(|x| x.is_cycle)); // all are marked is_cycle, scc_members contains [a,b]
    assert!(r
        .iter()
        .all(|x| x.scc_members == vec!["a".to_string(), "b".to_string()]));
}

#[test]
fn ready_in_progress_excluded() {
    // INV4: done={c}, inprog={b} → ready={} (callee b of a is not done; b is
    // excluded when running)
    let vs: Vec<String> = vec!["a".into(), "b".into(), "c".into()];
    let es = vec![("a".into(), "b".into()), ("b".into(), "c".into())];
    assert!(compute_ready_functions(&vs, &es, &["c".into()], &["b".into()]).is_empty());
}

#[test]
fn empty_graph() {
    let levels = compute_topological_order(&[], &[]);
    assert!(levels.is_empty());
}

#[test]
fn single_function_no_edges() {
    let levels = compute_topological_order(&["foo".into()], &[]);
    // foo is level 0, single-member group, is_cycle=false
    assert_eq!(levels.len(), 1);
    assert_eq!(levels[0].level, 0);
    assert_eq!(levels[0].groups.len(), 1);
    assert_eq!(levels[0].groups[0].members, vec!["foo".to_string()]);
    assert!(!levels[0].groups[0].is_cycle);
}

#[test]
fn linear_chain() {
    // foo → bar → baz: level 0 = baz, level 1 = bar, level 2 = foo
    let levels = compute_topological_order(
        &["foo".into(), "bar".into(), "baz".into()],
        &[
            ("foo".into(), "bar".into()),
            ("bar".into(), "baz".into()),
        ],
    );
    assert_eq!(levels.len(), 3);
    assert_eq!(levels[0].groups.len(), 1);
    assert_eq!(levels[0].groups[0].members, vec!["baz".to_string()]);
    assert_eq!(levels[1].groups[0].members, vec!["bar".to_string()]);
    assert_eq!(levels[2].groups[0].members, vec!["foo".to_string()]);
}

#[test]
fn two_function_scc() {
    // foo ↔ bar (mutual recursion): same level, same group, is_cycle=true
    let levels = compute_topological_order(
        &["foo".into(), "bar".into()],
        &[
            ("foo".into(), "bar".into()),
            ("bar".into(), "foo".into()),
        ],
    );
    assert_eq!(levels.len(), 1);
    assert_eq!(levels[0].groups.len(), 1);
    let g = &levels[0].groups[0];
    assert_eq!(g.members.len(), 2);
    assert!(g.is_cycle);
    assert!(g.members.contains(&"foo".to_string()));
    assert!(g.members.contains(&"bar".to_string()));
}

#[test]
fn self_recursion() {
    // foo → foo (self-recursive): is_cycle=true, single member SCC
    let levels = compute_topological_order(
        &["foo".into()],
        &[("foo".into(), "foo".into())],
    );
    let g = &levels[0].groups[0];
    assert_eq!(g.members, vec!["foo".to_string()]);
    assert!(g.is_cycle, "size=1 SCC with self-loop must be is_cycle=true");
}

#[test]
fn three_function_scc_plus_caller() {
    // {a, b, c} mutual recursion SCC, add caller d to call them level 0 = {a,
    // b, c} SCC, level 1 = d
    let levels = compute_topological_order(
        &["a".into(), "b".into(), "c".into(), "d".into()],
        &[
            ("a".into(), "b".into()),
            ("b".into(), "c".into()),
            ("c".into(), "a".into()),
            ("d".into(), "a".into()),
        ],
    );
    assert_eq!(levels.len(), 2);
    // SCC is at level 0 (a dependency of d)
    let scc_group = &levels[0].groups[0];
    assert!(scc_group.is_cycle);
    assert_eq!(scc_group.members.len(), 3);
    // d is at level 1
    assert_eq!(levels[1].groups[0].members, vec!["d".to_string()]);
}

#[test]
fn determinism() {
    // The same set of inputs is run twice, and the output is exactly the same
    // (members sorting + groups sorting)
    let input_v = vec!["foo".into(), "bar".into(), "baz".into()];
    let input_e = vec![
        ("foo".into(), "bar".into()),
        ("foo".into(), "baz".into()),
    ];
    let r1 = compute_topological_order(&input_v, &input_e);
    let r2 = compute_topological_order(&input_v, &input_e);
    let s1 = serde_json::to_string(&r1).unwrap();
    let s2 = serde_json::to_string(&r2).unwrap();
    assert_eq!(s1, s2);
}

#[test]
fn isolated_and_chain_mixed() {
    // foo independent, bar → baz: foo and baz are both level 0, bar level 1
    let levels = compute_topological_order(
        &["foo".into(), "bar".into(), "baz".into()],
        &[("bar".into(), "baz".into())],
    );
    assert_eq!(levels.len(), 2);
    // level 0: foo + baz (no outgoing)
    let level_0_members: Vec<String> = levels[0]
        .groups
        .iter()
        .flat_map(|g| g.members.clone())
        .collect();
    assert!(level_0_members.contains(&"foo".to_string()));
    assert!(level_0_members.contains(&"baz".to_string()));
    // level 1: bar
    assert_eq!(levels[1].groups[0].members, vec!["bar".to_string()]);
}
