use super::*;

#[test]
fn closed_chat_keeps_conversation_kind_in_merged_history() {
    for (kind, expected) in
        [("conversation", ClosedKind::ConversationTab), ("browser", ClosedKind::BrowserTab)]
    {
        let item = serde_json::json!({"id":"closed_chat","kind":"tab","closed_at_ms":1,
                "screens":[{"tabs":[{"kind":kind,"url":"about:blank","agent_session":{"session":"sess-closed","harness":"codex"}}]}]});
        let entry = closed_entry(&item).unwrap();
        assert_eq!(entry.closed_kind, Some(expected));
        assert_eq!(entry.id, "closed:daemon:closed_chat");
    }
}

/// A closed tab item (`closed.list` shape) that holds the one tab `tab`.
fn closed_tab(id: &str, at_ms: i64, tab: Value) -> Value {
    serde_json::json!({"id": id, "kind": "tab", "closed_at_ms": at_ms,
            "screens": [{"tabs": [tab]}]})
}

/// Port of the Swift `ClosedAgentIdentityTests.daemonClosedSearchFiltersAfterEnrichmentAndBeforeLimit`:
/// a closed chat is found by its agent session id and harness, even when newer unrelated
/// closes outnumber the result limit. The app no longer enriches closed rows; the merged
/// history carries the chat's identity itself.
#[test]
fn closed_chat_search_matches_session_and_harness_before_limit() {
    let chat = serde_json::json!({"kind": "conversation", "url": "about:blank",
            "agent_session": {"session": "same-session", "harness": "codex"}});
    let mut items = vec![closed_tab("closed_1", 1, chat)];
    for index in 2..=60 {
        let tab = serde_json::json!({"kind": "browser", "name": "Other",
                "url": format!("https://other.example/{index}")});
        items.push(closed_tab(&format!("closed_{index}"), index, tab));
    }
    let entries = closed_entries(&items);
    for (text, found) in [("same-session", true), ("codex", true), ("no-such-chat", false)] {
        let query = cmux_history::HistoryQuery {
            kinds: vec![HistoryKind::Closed],
            text: text.to_owned(),
            limit: Some(1),
            ..Default::default()
        };
        let matched = query.apply(&entries, 100, 0, |_| false);
        let ids: Vec<&str> = matched.iter().map(|entry| entry.id.as_str()).collect();
        assert_eq!(ids, if found { vec!["closed:daemon:closed_1"] } else { vec![] }, "{text}");
        if let Some(entry) = matched.first() {
            assert_eq!(entry.session_id.as_deref(), Some("same-session"));
            assert_eq!(entry.provider.as_deref(), Some("codex"));
            assert_eq!(entry.closed_kind, Some(ClosedKind::ConversationTab));
        }
    }
}

/// Port of the Swift `ClosedAgentIdentityTests.closedContainersRetainTheirOwnKind`: only a
/// closed tab is a chat. A screen, workspace or window keeps its container kind and carries
/// no agent identity, even when the first tab it would reopen is a chat.
#[test]
fn closed_containers_carry_no_agent_identity() {
    let chat = serde_json::json!({"kind": "conversation", "name": "Fix the flaky upload test",
            "url": "about:blank", "agent_session": {"session": "sess-closed", "harness": "codex"}});
    let tab = closed_entry(&closed_tab("closed_1", 1, chat.clone())).unwrap();
    assert_eq!(tab.session_id.as_deref(), Some("sess-closed"));
    assert_eq!(tab.provider.as_deref(), Some("codex"));
    for kind in ["screen", "workspace", "window"] {
        let mut item = closed_tab("closed_1", 1, chat.clone());
        item["kind"] = serde_json::json!(kind);
        let entry = closed_entry(&item).unwrap();
        assert_eq!((entry.session_id, entry.provider), (None, None), "{kind}");
    }
}

/// A plain browser tab and a chat with no session yet carry no session id; a chat's harness
/// alone still names its brand.
#[test]
fn closed_tab_without_session_carries_no_session_id() {
    let browser =
        serde_json::json!({"kind": "browser", "name": "Docs", "url": "https://docs.example/"});
    let entry = closed_entry(&closed_tab("closed_1", 1, browser)).unwrap();
    assert_eq!((entry.session_id, entry.provider), (None, None));
    let pending = serde_json::json!({"kind": "conversation", "name": "Chat", "url": "about:blank",
            "agent_session": {"session": null, "harness": "claude"}});
    let entry = closed_entry(&closed_tab("closed_2", 1, pending)).unwrap();
    assert_eq!(entry.session_id, None);
    assert_eq!(entry.provider.as_deref(), Some("claude"));
}
