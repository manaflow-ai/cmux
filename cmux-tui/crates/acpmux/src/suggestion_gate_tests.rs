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
