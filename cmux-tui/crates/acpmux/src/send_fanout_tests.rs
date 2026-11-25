use super::*;

fn send_to(ring: &mut Ring, n: usize, caller: &str, hash: &str, at: u64) -> Vec<Fanout> {
    (0..n)
        .filter_map(|i| {
            let machine = if i % 3 == 0 { "local" } else { "far" };
            ring.note(caller, hash, &format!("s-{i}"), machine, at + i as u64)
        })
        .collect()
}

#[test]
fn warns_once_at_the_threshold_and_not_below_it() {
    let mut ring = Ring::default();
    assert!(send_to(&mut ring, THRESHOLD - 1, "hook", "h1", 1_000).is_empty());
    let mut ring = Ring::default();
    let warned = send_to(&mut ring, THRESHOLD + 5, "hook", "h1", 1_000);
    assert_eq!(
        warned,
        [Fanout { sessions: THRESHOLD, machines: vec!["far".into(), "local".into()] }]
    );
}

#[test]
fn the_same_session_twice_another_prompt_or_caller_and_old_sends_do_not_count() {
    let mut ring = Ring::default();
    for i in 0..THRESHOLD * 2 {
        assert_eq!(ring.note("hook", "h1", "same", "local", 1_000 + i as u64), None);
    }
    for i in 0..THRESHOLD - 1 {
        ring.note("a", "h2", &format!("s-{i}"), "local", 2_000);
        ring.note("b", "h2", &format!("t-{i}"), "local", 2_000);
        ring.note("a", &format!("h-{i}"), &format!("u-{i}"), "local", 2_000);
    }
    // Nine sends a minute and more ago, then one now: the window holds one.
    let mut ring = Ring::default();
    assert!(send_to(&mut ring, THRESHOLD - 1, "hook", "h1", 1_000).is_empty());
    assert_eq!(ring.note("hook", "h1", "late", "local", 1_000 + WINDOW_MS + 100), None);
}

#[test]
fn the_ring_stays_bounded() {
    let mut ring = Ring::default();
    for i in 0..RING * 4 {
        ring.note(&format!("c-{i}"), "h", &format!("s-{i}"), "local", 5_000);
    }
    assert!(ring.sent.len() <= RING);
}

#[test]
fn handle_keys_by_the_proven_caller_else_from_and_the_warning_names_count_and_machines() {
    let params = |i: usize| {
        json!({"hash": "abc", "session": format!("far/s-{i}"), "machine": "far",
            "from": "boot-hook"})
    };
    let replies: Vec<Value> =
        (0..THRESHOLD).map(|i| handle(Some("handle-test-caller"), &params(i), 7_000)).collect();
    assert!(replies[..THRESHOLD - 1].iter().all(|r| r["fanout"].is_null()));
    let line = warning(&replies[THRESHOLD - 1]).unwrap();
    assert_eq!(
        line,
        "send: this prompt went to 10 sessions in 60s, on 1 machine (far); `acpmux ls` lists \
             every machine's sessions, `--machine local` only this one's"
    );
    assert_eq!(warning(&json!({"fanout": null})), None);
    assert_eq!(handle(None, &json!({"session": "x"}), 7_000), json!({"fanout": null}));
}

#[test]
fn machine_and_hash() {
    assert_eq!(machine_of("hb/review-1"), "hb");
    assert_eq!(machine_of("review-1"), "local");
    assert_eq!(machine_of("/x"), "local");
    assert_eq!(prompt_hash("a"), prompt_hash("a"));
    assert_ne!(prompt_hash("a"), prompt_hash("b"));
    assert_eq!(prompt_hash("a").len(), 32);
}
