use super::*;

#[test]
fn every_event_is_one_complete_row() {
    let mut seen = std::collections::HashSet::new();
    for e in EVENTS {
        assert!(seen.insert(e.name), "{} twice", e.name);
        assert!(e.name.bytes().all(|b| b.is_ascii_lowercase() || b == b'-'), "{}", e.name);
        assert!(e.label.starts_with("When "), "{}", e.label);
        assert!(!e.summary.is_empty() && !e.source.is_empty());
        assert!((1..=crate::MAX_DEBOUNCE_SECONDS).contains(&e.debounce_seconds));
        let sample: serde_json::Value = serde_json::from_str(e.sample).unwrap();
        assert_eq!(sample["event"], e.name, "a sample names its event");
        assert_eq!(find(e.name), Some(e));
    }
    assert_eq!(find("agent-busy"), None);
    assert_eq!(names(), "agent-idle, agent-needs-input, pr-opened");
}

#[test]
fn the_watch_command_quotes_the_program() {
    assert_eq!(
        watch_command("/usr/local/bin/cmux", "pr-opened"),
        "/usr/local/bin/cmux automation events pr-opened"
    );
    assert_eq!(
        watch_command("/Applications/cmux NEXT.app/x/cmux", "agent-idle"),
        "'/Applications/cmux NEXT.app/x/cmux' automation events agent-idle"
    );
    assert_eq!(watch_command("/tmp/it's/cmux", "a"), r"'/tmp/it'\''s/cmux' automation events a");
}
