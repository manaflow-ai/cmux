use super::*;

#[test]
fn the_triage_answer_is_rush_wait_or_neither() {
    assert_eq!(parse_triage("RUSH"), Some(true));
    assert_eq!(parse_triage(" wait.\n"), Some(false));
    assert_eq!(parse_triage("Rush"), Some(true));
    assert_eq!(parse_triage(""), None);
    assert_eq!(parse_triage("RUSH or WAIT"), None);
    assert_eq!(parse_triage("maybe"), None);
}

#[test]
fn only_the_chats_the_config_names_hold_and_for_its_time() {
    let mut cfg = crate::config::Config::default();
    assert_eq!(hold_ms(&cfg, "coord"), None, "nothing holds by default");
    cfg.person_hold = Some(crate::config::PersonHoldConfig {
        sessions: vec!["coord".into(), "other".into()],
        ms: None,
    });
    assert_eq!(hold_ms(&cfg, "coord"), Some(DEFAULT_HOLD_MS));
    assert_eq!(hold_ms(&cfg, "coord-old"), None);
    assert_eq!(hold_ms(&cfg, ""), None);
    cfg.person_hold.as_mut().unwrap().ms = Some(5_000);
    assert_eq!(hold_ms(&cfg, "other"), Some(5_000));
    cfg.person_hold.as_mut().unwrap().ms = Some(0);
    assert_eq!(hold_ms(&cfg, "other"), None, "0 turns it off");
}

#[test]
fn the_triage_prompt_carries_the_words_cut() {
    let p = triage_prompt("the build is broken");
    assert!(p.contains("the build is broken"), "{p}");
    assert!(p.contains("RUSH or WAIT"), "{p}");
    let long = "x".repeat(10_000);
    assert!(triage_prompt(&long).len() < 4096);
}
