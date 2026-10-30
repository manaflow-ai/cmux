//! Closed conversation kinds opt in independently of live conversation support.
use super::super::*;

fn writer_with_outbound() -> (MessageWriter, Arc<BoundedOutbound>) {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    (writer, outbound)
}

#[test]
fn closed_conversation_tabs_negotiate_independently_and_keep_plain_browsers() {
    let mux = Mux::new_for_test("closed-kind-capability", crate::SurfaceOptions::default());
    assert!(identify_capabilities(&mux).contains(&"closed-conversation-tabs-v1"));
    let agent = json!({"kind":"conversation","name":null,"cwd":null,"url":"about:blank",
        "browser_profile_id":null,"pinned":false,
        "conversation":{"agent_session":{"host":"install:private","session":"sess-closed","harness":"codex"}}});
    let local = json!({"kind":"conversation","name":"Local chat","cwd":null,"url":"about:blank",
        "browser_profile_id":null,"pinned":false,
        "conversation":{"conversation":"conv-local","owner":"local"}});
    let cloud = json!({"kind":"conversation","name":"Cloud chat","cwd":null,"url":"about:blank",
        "browser_profile_id":null,"pinned":false,
        "conversation":{"conversation":"conv-cloud","owner":"cloud"}});
    let plain = json!({"kind":"browser","name":null,"cwd":null,"url":"https://example.com",
        "browser_profile_id":null,"pinned":false});
    let stored = json!({"id":"closed_1","kind":"tab","members":[{"kind":"tab",
        "screens":[{"name":null,"tabs":[agent,local,cloud,plain]}]}]});
    let closed = crate::state::closed_history_query::public_item(&stored);
    for capabilities in [
        vec![],
        vec!["conversation-tabs-v1", "agent-session-tabs-v1", "page-tabs-v1"],
        vec!["closed-conversation-tabs-v1"],
        vec![
            "conversation-tabs-v1",
            "agent-session-tabs-v1",
            "page-tabs-v1",
            "closed-conversation-tabs-v1",
        ],
    ] {
        let canonical = capabilities.contains(&"closed-conversation-tabs-v1");
        let (writer, outbound) = writer_with_outbound();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        mux.control_clients
            .set_info(
                client,
                None,
                None,
                Some(capabilities.iter().map(|s| s.to_string()).collect()),
            )
            .unwrap();
        let message = json!({"closed":[closed],"entries":[{"kind":"closed","closed_kind":"conversation_tab"}],
            "projection":[{"kind":"conversation","conversation":{"conversation":"opaque"}},
                           {"closed_kind":"conversation_tab"},{"kind":"custom","closed_kind":"conversation_tab"}]});
        writer.send_control(&message).unwrap();
        let read: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        for screens in [&read["closed"][0]["screens"], &read["closed"][0]["members"][0]["screens"]]
        {
            let chat = &screens[0]["tabs"][0];
            assert_eq!(chat["kind"], if canonical { "conversation" } else { "browser" }, "{read}");
            assert_eq!(chat["agent_session"], json!({"session":"sess-closed","harness":"codex"}));
            assert_eq!(
                screens[0]["tabs"][1]["kind"],
                if canonical { "conversation" } else { "browser" }
            );
            assert_eq!(
                screens[0]["tabs"][2]["kind"],
                if canonical { "conversation" } else { "browser" }
            );
            assert_eq!(screens[0]["tabs"][3]["kind"], "browser");
        }
        assert_eq!(
            read["entries"][0]["closed_kind"],
            if canonical { "conversation_tab" } else { "browser_tab" }
        );
        assert_eq!(read["projection"], message["projection"], "opaque projection data changed");
        assert_eq!(writer.project_conversation_tab_item(message), read);
    }
    mux.shutdown();
}
