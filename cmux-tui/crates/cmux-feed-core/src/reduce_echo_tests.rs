use super::*;
use crate::model::Context;

fn notice(id: &str, source: &str, title: &str, body: &str, at_ms: u64) -> Notice {
    Notice {
        id: id.into(),
        dedupe_key: format!("notify:s:{id}"),
        title: title.into(),
        body: body.into(),
        level: "info".into(),
        source: source.into(),
        context: Context { terminal: Some("term_1".into()), ..Context::default() },
        actor: None,
        at_ms,
        read: false,
        coalesce: true,
    }
}

/// Claude Code's own "claude-code is done" (OSC 7501) lands within milliseconds of its
/// Stop hook's "Claude finished": the item keeps the hook's text.
#[test]
fn a_programs_echo_after_its_agents_notice_keeps_the_agents_text() {
    let mut feed = Feed::default();
    feed.post(notice("fi_a", "agent", "Claude finished", "", 1_000)).unwrap();
    let (outcome, _) =
        feed.post(notice("fi_b", "terminal", "claude-code is done", "", 1_004)).unwrap();
    let item = outcome.item();
    assert_eq!(item.id, "fi_a");
    assert_eq!(item.title, "Claude finished");
    assert_eq!(item.source, "agent");
    assert_eq!(item.count, 1, "one event, told twice");
    assert!(item.has_key("notify:s:fi_b"), "the echo's key still dedupes to it");
}

/// The program told it first: the agent's notice, which names the agent, replaces it.
#[test]
fn an_agents_notice_after_its_programs_echo_replaces_it() {
    let mut feed = Feed::default();
    feed.post(notice("fi_b", "terminal", "claude-code is done", "", 1_000)).unwrap();
    let (outcome, _) = feed.post(notice("fi_a", "agent", "Claude finished", "", 1_003)).unwrap();
    let item = outcome.item();
    assert_eq!(item.title, "Claude finished");
    assert_eq!(item.source, "agent");
}

/// A program's notice long after the agent's is news of its own: latest wins, as before.
#[test]
fn a_later_programs_notice_still_coalesces_as_news() {
    let mut feed = Feed::default();
    feed.post(notice("fi_a", "agent", "Claude finished", "", 1_000)).unwrap();
    let (outcome, _) =
        feed.post(notice("fi_b", "terminal", "build is done", "", 1_000 + 10_001)).unwrap();
    let item = outcome.item();
    assert_eq!(item.title, "build is done");
    assert_eq!(item.count, 2);
}
