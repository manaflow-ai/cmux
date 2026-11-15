//! The outbound projection (`project_conversation_tabs`) parses a whole message into a JSON value,
//! rewrites the conversation tab kinds a connection must not read, and serializes it again. Only
//! the string values `"conversation"` (a tab's `kind` or `content_kind`, a closed tab's `kind`) and
//! `"conversation_tab"` (a closed history row's `closed_kind`) are rewritten, so a message without
//! one of them is sent as it is, unparsed.
//!
//! Final bench rows `daemon scale list-workspaces` (2.4 ms at 50 workspaces and 200 terminals) and
//! `c10-list-workspaces` (10.8 ms): the reply of `list-workspaces` holds a raw tab for each
//! terminal, and each raw tab has the key `"conversation"` (`null` for a terminal). The pre-check
//! looked for the text `"conversation` anywhere, keys included, so every tree reply to a
//! connection that did not declare `closed-conversation-tabs-v1` (the iPhone app, an older app or
//! script) was parsed and dropped again: 18% of the reply time in a sample of the daemon.
//!
//! A wrong pre-check would send an older client (the iPhone app) a message that needed the rewrite
//! without it. The property test generates trees, lists, closed history and responses with zero,
//! one and many tabs of each kind and shape, whose titles, paths and commands hold the rewritten
//! value strings, quoted, as keys and inside other text, and checks that for every capability set
//! the bytes sent equal those of the path that parses and rewrites every message.

use super::super::*;
use super::may_hold_a_conversation_kind;

fn compact(value: &Value) -> String {
    serde_json::to_string(value).unwrap()
}

fn pretty(value: &Value) -> String {
    serde_json::to_string_pretty(value).unwrap()
}

/// A `list-workspaces` reply of a session of terminals names no conversation kind: it is not
/// parsed again.
#[test]
fn a_tree_of_terminals_is_sent_without_a_parse() {
    let mux = Mux::new_for_test("conversation-precheck-tree", crate::SurfaceOptions::default());
    for _ in 0..3 {
        mux.new_workspace(None, Some((80, 24))).unwrap();
    }
    let tree = list_workspaces_reply(&mux).unwrap();
    let text = compact(&tree);
    assert!(
        text.contains("\"conversation\":null"),
        "each raw tab has the conversation key: {text}"
    );
    assert!(
        !may_hold_a_conversation_kind(&text),
        "a tree with no conversation tab holds no conversation kind, but the pre-check asks for \
         a parse of the whole reply"
    );
    assert!(!may_hold_a_conversation_kind(&pretty(&tree)), "the same tree, pretty printed");
    mux.shutdown();
}

/// Each value the projection rewrites makes the pre-check hold, in compact and in pretty text.
#[test]
fn each_rewritten_kind_holds() {
    let rewritten = [
        json!({"tabs": [{"content_kind": "conversation", "extra": {}}]}),
        json!({"raw": [{"kind": "conversation", "browser_renderer": "frontend"}]}),
        json!({"closed": [{"kind": "tab", "screens": [{"tabs": [{"kind": "conversation"}]}]}]}),
        json!({"entries": [{"kind": "closed", "closed_kind": "conversation_tab"}]}),
        json!({"result": {"kind": "closed", "closed_kind": "conversation_tab"}}),
        json!(["conversation"]),
        json!({"conversation": {"kind": "conversation"}}),
    ];
    for value in rewritten {
        assert!(may_hold_a_conversation_kind(&compact(&value)), "{value}");
        assert!(may_hold_a_conversation_kind(&pretty(&value)), "{value} (pretty)");
    }
}

/// Keys named `conversation`, other values that start with it, and the word inside a longer
/// string do not make it hold.
#[test]
fn keys_and_other_strings_do_not_hold() {
    let plain = [
        json!({"conversation": null}),
        json!({"conversation": {"conversation": "conv_1", "owner": "local"}}),
        json!({"conversation_tabs": [], "conversation_id": "conversation-1"}),
        json!({"title": "a conversation about tabs"}),
        json!({"kind": "conversations"}),
        json!({"closed_kind": "conversation_tabs"}),
    ];
    for value in plain {
        assert!(!may_hold_a_conversation_kind(&compact(&value)), "{value}");
        assert!(!may_hold_a_conversation_kind(&pretty(&value)), "{value} (pretty)");
    }
}

/// A connection with no tab capability reads the same bytes as before for a tree with a
/// conversation tab (rewritten) and for one without (sent as it is).
#[test]
fn the_projected_bytes_do_not_change() {
    crate::state::conversation_tabs_store::mark_conversation_tabs_present();
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let with_tab = json!({"workspaces": [{"tabs": [
        {"kind": "conversation", "browser_renderer": "frontend", "conversation": null},
        {"kind": "terminal", "conversation": null}]}]});
    writer.send_control(&with_tab).unwrap();
    assert_eq!(
        outbound.try_pop().unwrap().trim_end(),
        "{\"workspaces\":[{\"tabs\":[{\"browser_renderer\":\"frontend\",\"conversation\":null,\
         \"kind\":\"browser\"},{\"conversation\":null,\"kind\":\"terminal\"}]}]}"
    );
    let without = json!({"workspaces": [{"tabs": [{"kind": "terminal", "conversation": null}]}]});
    writer.send_control(&without).unwrap();
    assert_eq!(outbound.try_pop().unwrap().trim_end(), compact(&without));
}

/// What a connection reads from the projection with no pre-check: the message parsed, rewritten
/// for the connection, and serialized again when it changed (the reference path).
fn always_rewritten(writer: &MessageWriter, text: &str) -> String {
    let mut value: Value = serde_json::from_str(text).unwrap();
    if writer.project_tab_kinds(&mut value) {
        serde_json::to_string(&value).unwrap()
    } else {
        text.to_string()
    }
}

/// Text that a tab's title, path or command may hold: the rewritten values, keys, quotes, colons
/// and the word in other text.
fn tricky_text() -> impl proptest::strategy::Strategy<Value = String> {
    use proptest::prelude::*;
    prop::sample::select(vec![
        "conversation",
        "conversation_tab",
        "\"conversation\"",
        "\"conversation\":",
        "\"conversation_tab\" :",
        "a conversation about tabs",
        "conversations",
        "~/src/conversation/tab",
        "echo '\"conversation\"' | jq",
        "kind:conversation",
        "\\\"conversation\\\"",
        "",
        "plain",
    ])
    .prop_map(str::to_string)
}

/// A raw tree tab, a v2 tab or a closed record, each with free text in its title, path and command.
fn tab() -> impl proptest::strategy::Strategy<Value = Value> {
    use proptest::prelude::*;
    let kind = prop::sample::select(vec!["terminal", "browser", "conversation"]);
    let record = prop::sample::select(vec![0_u8, 1, 2, 3]).prop_map(|choice| match choice {
        0 => Value::Null,
        1 => json!({"conversation": "conv_1", "owner": "local"}),
        2 => json!({"agent_session": {"host": "install:a", "session": "s1"}}),
        _ => json!({"page": "settings"}),
    });
    (kind, record, tricky_text(), tricky_text(), tricky_text(), 0_u8..4).prop_map(
        |(kind, record, title, path, command, shape)| match shape {
            0 => json!({"surface": 1, "kind": kind, "browser_renderer": "frontend",
                        "conversation": record, "title": title, "cwd": path,
                        "command": command}),
            1 => json!({"id": "tab_1", "content_kind": kind, "title": title,
                        "extra": {"conversation": record, "cwd": path, "command": command}}),
            2 => json!({"kind": "closed", "closed_kind":
                            if kind == "conversation" { "conversation_tab" } else { "browser_tab" },
                        "title": title, "path": path, "command": command}),
            _ => json!({"surface": 2, "kind": "terminal", "conversation": null,
                        "title": title, "cwd": path, "command": command}),
        },
    )
}

/// A message holding `tabs` the way the daemon sends them: a raw tree, a v2 list, closed history,
/// a resource response or a closed group.
fn message() -> impl proptest::strategy::Strategy<Value = Value> {
    use proptest::prelude::*;
    (prop::collection::vec(tab(), 0..12), 0_u8..5, tricky_text()).prop_map(
        |(tabs, envelope, name)| match envelope {
            0 => json!({"workspaces": [{"name": name, "screens": [{"panes": [{"tabs": tabs}]}]}]}),
            1 => json!({"ok": true, "data": {"tabs": tabs, "name": name}}),
            2 => json!({"entries": tabs}),
            3 => json!({"type": "response", "result": tabs}),
            _ => json!({"closed": [{"kind": "tab", "screens": [{"name": name, "tabs": tabs}]}]}),
        },
    )
}

proptest::proptest! {
    #![proptest_config(proptest::prelude::ProptestConfig::with_cases(512))]

    /// For every generated message and every capability set, the bytes sent with the pre-check
    /// equal the bytes of the path that parses and rewrites every message.
    #[test]
    fn the_precheck_sends_the_bytes_of_the_always_rewrite_path(
        value in message(),
        capabilities in proptest::sample::subsequence(
            vec![
                crate::state::conversation_tabs_store::CONVERSATION_TABS_CAPABILITY,
                crate::state::conversation_tabs_store::AGENT_SESSION_TABS_CAPABILITY,
                crate::state::conversation_tabs_store::PAGE_TABS_CAPABILITY,
                crate::state::conversation_tabs_store::CLOSED_CONVERSATION_TABS_CAPABILITY,
            ],
            0..=4,
        ),
    ) {
        crate::state::conversation_tabs_store::mark_conversation_tabs_present();
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let names = capabilities.iter().map(|name| name.to_string()).collect::<Vec<_>>();
        writer.negotiate_conversation_tabs(names.iter());
        let text = compact(&value);
        writer.send_control(&value).unwrap();
        let sent = outbound.try_pop().unwrap();
        let expected = if capabilities.len() == 4 { text } else {
            always_rewritten(&writer, &text)
        };
        proptest::prop_assert_eq!(sent.trim_end(), expected.as_str());
    }
}
