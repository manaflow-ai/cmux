use super::*;

#[test]
fn the_readout_names_counts_never_more() {
    let mut rollup = Rollup::default();
    rollup.add("command", "new-tab", 3, 1_000);
    rollup.add("layout", "split-right", 2, 1_000);
    rollup.add("agent-chat", "claude", 1, 1_000);
    rollup.peak("connections.open", 4, 1_000);
    let readout = Readout { enabled: true, rollup, ..Readout::default() };
    let text = render(&readout, 10);
    assert!(text.contains("counting is on"));
    assert!(text.contains("Commands (1 distinct, 3 total)"));
    assert!(text.contains("split-right"));
    assert!(text.contains("Agent chats started, by harness"));
    assert!(text.contains("connections.open"));
}

#[test]
fn an_empty_readout_says_how_to_turn_it_on() {
    let text = render(&Readout::default(), 10);
    assert!(text.contains("counting is off"));
    assert!(text.contains("cmux settings set diagnostics.usagePatterns true"));
}
