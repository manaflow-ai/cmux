use super::*;

#[test]
fn conversation_tab_downgrade_touches_only_tab_kinds() {
    let mut value = json!({
        "event": "conversation-changed",
        "change": {"kind": "conversation"},
        "tabs": [
            {"content_kind": "conversation", "extra": {"conversation": {"owner": "local"}}},
            {"kind": "conversation", "browser_renderer": "frontend"},
            {"content_kind": "terminal"}
        ]
    });
    assert!(downgrade_conversation_tabs(&mut value, ConversationTabDowngrade::All));
    assert_eq!(value["change"]["kind"], "conversation", "a conversation event is not a tab");
    assert_eq!(value["tabs"][0]["content_kind"], "browser");
    assert_eq!(value["tabs"][0]["extra"]["conversation"]["owner"], "local");
    assert_eq!(value["tabs"][1]["kind"], "browser");
    assert_eq!(value["tabs"][2]["content_kind"], "terminal");
    assert!(!downgrade_conversation_tabs(&mut value, ConversationTabDowngrade::All));
}

#[test]
fn conversation_tab_record_validates_its_id_and_owner() {
    let ok = ConversationTabRecord::Conversation {
        conversation: "conv_01ABC".into(),
        owner: "local".into(),
    };
    assert!(ok.validate().is_ok());
    for (conversation, owner) in
        [("chat_1", "local"), ("conv_1", "elsewhere"), ("conv_a b", "cloud")]
    {
        let record = ConversationTabRecord::Conversation {
            conversation: conversation.into(),
            owner: owner.into(),
        };
        assert!(record.validate().is_err(), "{conversation} {owner}");
    }
}

#[test]
fn agent_session_record_validates_and_round_trips_its_wire_form() {
    let record = ConversationTabRecord::AgentSession {
        host: "install:mac-1".into(),
        session: None,
        harness: Some("claude".into()),
        host_name: Some("Build Mac".into()),
    };
    assert!(record.validate().is_ok());
    let wire = record.wire();
    assert_eq!(
        wire,
        json!({"agent_session":{"host":"install:mac-1","session":null,"harness":"claude",
                                    "host_name":"Build Mac"}})
    );
    assert_eq!(ConversationTabRecord::from_wire(&wire), Some(record));
    for (host, session) in [("mac-1", None), ("install:", None), ("install:a", Some("a b"))] {
        let record = ConversationTabRecord::AgentSession {
            host: host.into(),
            session: session.map(str::to_string),
            harness: None,
            host_name: None,
        };
        assert!(record.validate().is_err(), "{host} {session:?}");
    }
}

/// A Chief subagent's tab names the Chief home whose acpmux runs it
/// (`chief:<home id>`, 8 lowercase hex), so the app attaches it there.
#[test]
fn an_agent_session_host_may_be_a_chief_home() {
    let record = |host: &str| ConversationTabRecord::AgentSession {
        host: host.into(),
        session: Some("s1".into()),
        harness: None,
        host_name: None,
    };
    assert!(record("chief:0a1b2c3d").validate().is_ok());
    for host in ["chief:", "chief:0A1B2C3D", "chief:0a1b2c3", "chief:0a1b2c3d4", "chief:zzzzzzzz"] {
        assert!(record(host).validate().is_err(), "{host}");
    }
}

#[test]
fn agent_session_tabs_downgrade_without_their_record() {
    let agent = json!({"agent_session":{"host":"install:a","session":null,"harness":null}});
    let original = json!({
        "tabs": [
            {"content_kind": "conversation", "extra": {"conversation": agent, "pinned": true}},
            {"content_kind": "conversation",
             "extra": {"conversation": {"conversation": "conv_1", "owner": "local"}}}
        ],
        "raw": [{"kind": "conversation", "browser_renderer": "frontend", "conversation": agent}]
    });
    let mut value = original.clone();
    assert!(downgrade_conversation_tabs(&mut value, ConversationTabDowngrade::AgentSessions));
    assert_eq!(value["tabs"][0]["content_kind"], "browser");
    assert_eq!(value["tabs"][0]["extra"], json!({"pinned": true}));
    assert_eq!(value["tabs"][1], original["tabs"][1], "a conversation source stays");
    assert_eq!(value["raw"][0]["kind"], "browser");
    assert_eq!(value["raw"][0]["conversation"], Value::Null);
    let mut all = original;
    assert!(downgrade_conversation_tabs(&mut all, ConversationTabDowngrade::All));
    assert_eq!(all["tabs"][1]["content_kind"], "browser");
    assert_eq!(all["tabs"][1]["extra"]["conversation"]["owner"], "local");
    assert_eq!(all["tabs"][0]["extra"], json!({"pinned": true}));
}
