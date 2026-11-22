use super::*;
use serde_json::json;

fn gate() -> Gate {
    Gate::default()
}

#[test]
fn a_new_install_starts_at_the_prior_and_shows_suggestions() {
    let tally = Tally::default();
    assert!((tally.estimate() - 0.5).abs() < 1e-9);
    let mut g = gate();
    assert!(g.offer("s", "claude/harness", "Run the tests"));
}

#[test]
fn takes_raise_the_estimate_and_passes_lower_it() {
    let mut tally = Tally::default();
    tally.record(true);
    assert!(tally.estimate() > 0.5);
    let mut tally = Tally::default();
    tally.record(false);
    assert!(tally.estimate() < 0.5);
}

#[test]
fn one_pass_never_withholds_but_a_run_of_them_does() {
    let mut tally = Tally::default();
    tally.record(false);
    assert!(tally.estimate() >= THRESHOLD);
    let mut passes = 1;
    while tally.estimate() >= THRESHOLD {
        tally.record(false);
        passes += 1;
        assert!(passes < 20, "never fell below the threshold");
    }
    // About seven straight passes from the prior.
    assert!((6..=9).contains(&passes), "{passes} passes");
}

#[test]
fn below_the_threshold_suggestions_are_withheld_except_to_explore() {
    let mut tally = Tally { taken: 0.0, passed: 30.0, withheld: 0 };
    assert!(tally.estimate() < THRESHOLD);
    let shown: Vec<bool> = (0..EXPLORE_EVERY * 2).map(|_| tally.admit()).collect();
    assert_eq!(shown.iter().filter(|s| **s).count(), 2);
    assert!(!shown[0]);
    assert!(shown[EXPLORE_EVERY as usize - 1]);
}

#[test]
fn at_or_above_the_threshold_every_suggestion_is_shown() {
    let mut tally = Tally { taken: 1.0, passed: 3.0, withheld: 0 };
    assert!(tally.estimate() >= THRESHOLD);
    assert!((0..20).all(|_| tally.admit()));
}

#[test]
fn old_outcomes_fade_so_a_source_can_recover() {
    let mut tally = Tally::default();
    for _ in 0..40 {
        tally.record(false);
    }
    assert!(tally.estimate() < THRESHOLD);
    for _ in 0..10 {
        tally.record(true);
    }
    assert!(tally.estimate() >= THRESHOLD, "{}", tally.estimate());
}

#[test]
fn the_next_prompt_answers_the_shown_suggestion() {
    let mut g = gate();
    assert!(g.offer("s", "k", "Add a test for the retry backoff"));
    assert_eq!(g.prompted("s", "  Add a test for\nthe retry backoff ", false), Some(true));
    // Answered once: the next prompt has nothing to answer.
    assert_eq!(g.prompted("s", "anything", false), None);
    assert!(g.offer("s", "k", "Ship it"));
    assert_eq!(g.prompted("s", "Do something else", false), Some(false));
    assert!(g.offer("s", "k", "Ship it"));
    assert_eq!(g.prompted("s", "Ship it, then tag", true), Some(true));
    let t = g.tally("k");
    assert!(t.taken > 1.9 && t.passed > 0.9, "{t:?}");
}

#[test]
fn a_withdrawn_or_withheld_suggestion_records_nothing() {
    let mut g = gate();
    g.offer("s", "k", "Ship it");
    g.withdraw("s");
    assert_eq!(g.prompted("s", "Ship it", false), None);
    g.tallies.insert("k".into(), Tally { taken: 0.0, passed: 30.0, withheld: 0 });
    assert!(!g.offer("s", "k", "Ship it"));
    assert_eq!(g.prompted("s", "Ship it", false), None);
    assert_eq!(g.tally("k").passed, 30.0);
}

#[test]
fn tallies_are_kept_per_harness_and_source_and_per_chat() {
    let mut g = gate();
    g.tallies.insert(key("codex", HARNESS_SOURCE), Tally { taken: 0.0, passed: 30.0, withheld: 0 });
    assert!(!g.offer("a", &key("codex", HARNESS_SOURCE), "x"));
    assert!(g.offer("a", &key("codex", "wrap_up"), "x"));
    assert!(g.offer("b", &key("claude", HARNESS_SOURCE), "y"));
    assert_eq!(g.prompted("b", "y", false), Some(true));
    assert_eq!(g.prompted("a", "x", false), Some(true));
    assert_eq!(g.tally(&key("claude", HARNESS_SOURCE)).taken, 1.0);
    assert_eq!(g.tally(&key("codex", "wrap_up")).taken, 1.0);
}

#[test]
fn a_withheld_update_goes_on_with_no_suggestion() {
    let mut g = gate();
    g.tallies
        .insert(key("claude", HARNESS_SOURCE), Tally { taken: 0.0, passed: 30.0, withheld: 0 });
    let mut update = json!({"sessionUpdate": "prompt_suggestion", "suggestion": "Ship it"});
    gate_update(&mut g, "s", "claude", &mut update);
    assert_eq!(update["suggestion"], Value::Null);
    assert_eq!(update["_meta"]["acpmux"]["suggestionWithheld"]["source"], "harness");
    assert!(
        update["_meta"]["acpmux"]["suggestionWithheld"]["estimate"].as_f64().unwrap() < THRESHOLD
    );

    let mut shown = json!({"sessionUpdate": "prompt_suggestion", "suggestion": "Ship it", "_meta": {"acpmux": {"source": "wrap_up"}}});
    gate_update(&mut g, "s", "claude", &mut shown);
    assert_eq!(shown["suggestion"], "Ship it");
    assert!(shown["_meta"]["acpmux"].get("suggestionWithheld").is_none());

    let mut cleared = json!({"sessionUpdate": "prompt_suggestion", "suggestion": null});
    gate_update(&mut g, "s", "claude", &mut cleared);
    assert_eq!(g.prompted("s", "Ship it", false), None);
}

#[test]
fn tallies_survive_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let path = file_in(dir.path());
    let mut g = Gate::load(path.clone());
    g.offer("s", "k", "Ship it");
    g.prompted("s", "nope", false);
    let again = Gate::load(path.clone());
    assert_eq!(again.tally("k").passed, 1.0);
    std::fs::write(&path, b"not json").unwrap();
    assert_eq!(Gate::load(path).tally("k"), Tally::default());
}

#[test]
fn a_prompt_reads_its_text_and_taken_mark() {
    let blocks =
        vec![json!({"type": "text", "text": "Ship it"}), json!({"type": "image", "data": ""})];
    assert_eq!(prompt_text(&blocks), "Ship it");
    assert!(marked_taken(&json!({"_meta": {"acpmux": {"promptSuggestion": "taken"}}})));
    assert!(!marked_taken(&json!({"_meta": {"acpmux": {}}})));
}

fn relayed(text: Option<&str>) -> Value {
    json!({"sessionUpdate": "prompt_suggestion", "suggestion": text})
}

#[test]
fn a_relayed_suggestion_is_gated_by_the_persons_own_tally() {
    let g = Mutex::new(gate());
    lock(&g)
        .tallies
        .insert(key("claude", HARNESS_SOURCE), Tally { taken: 0.0, passed: 30.0, withheld: 0 });
    let mut update = relayed(Some("Ship it"));
    regate_relayed(&g, "box", "s1", "claude", &mut update, true);
    assert_eq!(update["suggestion"], Value::Null);
    assert_eq!(update["_meta"]["acpmux"]["suggestionWithheld"]["text"], "Ship it");
}

#[test]
fn a_suggestion_the_peer_withheld_is_shown_when_the_persons_tally_takes_it() {
    let g = Mutex::new(gate());
    let mut peer = gate();
    peer.tallies
        .insert(key("claude", HARNESS_SOURCE), Tally { taken: 0.0, passed: 30.0, withheld: 0 });
    let mut update = relayed(Some("Ship it"));
    gate_update(&mut peer, "s1", "claude", &mut update);
    assert_eq!(update["suggestion"], Value::Null);
    regate_relayed(&g, "box", "s1", "claude", &mut update, true);
    assert_eq!(update["suggestion"], "Ship it");
    assert!(update["_meta"]["acpmux"].get("suggestionWithheld").is_none(), "{update}");
    // A peer from before the text: its verdict stands, and nothing is counted.
    let mut old = json!({"sessionUpdate": "prompt_suggestion", "suggestion": null,
        "_meta": {"acpmux": {"suggestionWithheld": {"source": "harness", "estimate": 0.1}}}});
    regate_relayed(&g, "box", "s2", "claude", &mut old, true);
    assert_eq!(old["suggestion"], Value::Null);
}

#[test]
fn the_persons_switch_off_withholds_a_relayed_suggestion_and_counts_nothing() {
    let g = Mutex::new(gate());
    let mut update = relayed(Some("Ship it"));
    regate_relayed(&g, "box", "s1", "claude", &mut update, false);
    assert_eq!(update["suggestion"], Value::Null);
    assert_eq!(update["_meta"]["acpmux"]["suggestionWithheld"]["setting"], "off");
    note_relayed_prompt(&g, "box", "s1", &json!({"prompt": [{"type": "text", "text": "x"}]}), true);
    assert_eq!(lock(&g).tally(&key("claude", HARNESS_SOURCE)), Tally::default());
}

#[test]
fn a_forwarded_prompt_answers_the_relayed_suggestion_in_the_persons_tally() {
    let g = Mutex::new(gate());
    let k = key("claude", HARNESS_SOURCE);
    let mut update = relayed(Some("Ship it"));
    regate_relayed(&g, "box", "s1", "claude", &mut update, true);
    note_relayed_prompt(
        &g,
        "box",
        "s1",
        &json!({"prompt": [{"type": "text", "text": "No"}]}),
        true,
    );
    assert_eq!(lock(&g).tally(&k).passed, 1.0);
    regate_relayed(&g, "box", "s1", "claude", &mut relayed(Some("Ship it")), true);
    let marked = json!({"prompt": [{"type": "text", "text": "Ship it now"}],
        "_meta": {"acpmux": {"promptSuggestion": "taken"}}});
    note_relayed_prompt(&g, "box", "s1", &marked, true);
    assert_eq!(lock(&g).tally(&k).taken, 1.0);
    // Another agent's message answers nothing.
    regate_relayed(&g, "box", "s1", "claude", &mut relayed(Some("Ship it")), true);
    note_relayed_prompt(
        &g,
        "box",
        "s1",
        &json!({"prompt": [{"type": "text", "text": "No"}]}),
        false,
    );
    assert_eq!(lock(&g).tally(&k).passed, 0.97);
    // A peer's chat and a local chat of the same id stay apart.
    regate_relayed(&g, "box", "s1", "claude", &mut relayed(Some("Ship it")), true);
    assert_eq!(lock(&g).prompted("s1", "Ship it", false), None);
}
