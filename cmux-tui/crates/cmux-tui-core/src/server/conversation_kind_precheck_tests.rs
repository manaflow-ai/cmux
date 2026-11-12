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
