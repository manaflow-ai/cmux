use super::*;

fn c(path: &str, likelihood: f32, size: u64) -> Candidate {
    Candidate { path: path.into(), likelihood, size }
}

#[test]
fn ranks_by_likelihood_per_byte_then_expected_bytes() {
    let r = rank(
        &[
            c("asset.bin", 0.9, 200 << 20),
            c("src/lib.rs", 0.6, 8 << 10),
            c("AGENTS.md", 0.95, 4 << 10),
            c("big-twin.rs", 0.6, 16 << 10),
            c("rare.rs", 0.01, 4 << 10),
        ],
        &HashSet::new(),
        0.0,
    );
    let order: Vec<_> = r.iter().map(|c| c.path.as_str()).collect();
    assert_eq!(order, ["AGENTS.md", "src/lib.rs", "big-twin.rs", "rare.rs", "asset.bin"]);

    // Equal value per byte: the bigger file (more bytes saved) first.
    let r = rank(&[c("a", 0.25, 1536), c("b", 0.5, 3584)], &HashSet::new(), 0.0);
    assert_eq!(r[0].path, "b");
}

#[test]
fn held_paths_and_unlikely_files_are_skipped() {
    let held: HashSet<String> = ["src/lib.rs".to_string()].into();
    let r = rank(
        &[c("src/lib.rs", 0.9, 100), c("a.rs", 0.5, 100), c("a.rs", 0.7, 100), c("z", 0.001, 1)],
        &held,
        0.01,
    );
    assert_eq!(r, vec![c("a.rs", 0.7, 100)]);
}

#[test]
fn the_plan_stays_in_budget_and_window_and_skips_what_does_not_fit() {
    let ranked = vec![c("a", 0.9, 400), c("big", 0.8, 900), c("b", 0.7, 500), c("c", 0.6, 200)];
    let p = plan(&ranked, 1000.0, 1.0, 10_000);
    assert_eq!(p.iter().map(|c| c.path.as_str()).collect::<Vec<_>>(), ["a", "b"]);
    let p = plan(&ranked, 1e9, 10.0, 1100);
    assert_eq!(p.iter().map(|c| c.path.as_str()).collect::<Vec<_>>(), ["a", "b", "c"]);
    assert!(p.iter().map(|c| c.size).sum::<u64>() <= 1100);
    assert!(plan(&ranked, 0.0, 10.0, 1 << 30).is_empty());
}

#[test]
fn the_fill_never_displaces_a_fault() {
    let mut s = Scheduler::new(8);
    let planned = plan(
        &rank(
            &(0..50).map(|i| c(&format!("f{i}"), 0.5, 100)).collect::<Vec<_>>(),
            &HashSet::new(),
            0.0,
        ),
        1e9,
        1.0,
        u64::MAX,
    );
    enqueue(planned, &mut s);
    for i in 0..5 {
        s.push(Lane::Fault, c(&format!("fault{i}"), 1.0, 10));
    }
    s.push(Lane::Manifest, c("manifest", 1.0, 10));
    let out: Vec<_> = std::iter::from_fn(|| s.pop()).collect();
    assert_eq!(out[0].0, Lane::Manifest);
    // Every fault goes before all but the fill's one-in-eight anti-starvation slot.
    let last_fault = out.iter().rposition(|(l, _)| *l == Lane::Fault).unwrap();
    assert!(out[..last_fault].iter().filter(|(l, _)| *l == Lane::Fill).count() <= 1);
    assert_eq!(out.iter().filter(|(l, _)| *l == Lane::Fill).count(), 50);
    // A read of a planned file jumps to the fault lane.
    let mut s = Scheduler::new(8);
    enqueue(vec![c("x", 0.5, 1), c("y", 0.5, 1)], &mut s);
    assert!(s.promote(Lane::Fill, |c| c.path == "y"));
    assert_eq!(s.pop().unwrap(), (Lane::Fault, c("y", 0.5, 1)));
}

#[test]
fn hit_stats_on_a_small_fixture() {
    let held: HashMap<String, u64> =
        [("AGENTS.md", 1000), ("src/lib.rs", 3000), ("unused.bin", 5000)]
            .into_iter()
            .map(|(p, s)| (p.to_string(), s))
            .collect();
    let first = vec![("AGENTS.md".to_string(), 1000), ("src/main.rs".to_string(), 1000)];
    let all = vec![("src/lib.rs".to_string(), 3000)];
    let h = hit_stats(&held, &first, &all);
    assert_eq!(h.first_turn_hit_rate, 0.5);
    assert_eq!(h.first_turn_hit_bytes_rate, 0.5);
    assert_eq!(h.held_never_read_bytes, 5000);
    assert_eq!(h.held_bytes, 9000);
    assert_eq!(hit_stats(&HashMap::new(), &[], &[]).first_turn_hit_rate, 1.0);
}
