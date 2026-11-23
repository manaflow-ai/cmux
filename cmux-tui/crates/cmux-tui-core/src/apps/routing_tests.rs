use super::*;

#[test]
fn every_stream_the_daemon_publishes_is_in_the_sdks_event_table() {
    let table: Value =
        serde_json::from_str(include_str!("../../../cmux-app-host/schema/v2/events.json")).unwrap();
    let declared = table["events"].as_object().unwrap();
    assert_eq!(streams(&MuxEvent::TreeChanged), TREE_STREAMS);
    for stream in TREE_STREAMS
        .iter()
        .chain(AGENT_STREAMS)
        .chain(CHAT_STREAMS)
        .chain(SETTINGS_STREAMS)
        .chain(SETTINGS_AND_THEME_STREAMS)
        .chain(GITHUB_STREAMS)
    {
        assert!(
            declared.contains_key(*stream),
            "{stream} is published to apps but not declared in schema/v2/events.json"
        );
    }
}

fn settings_changed(keys: &[&str]) -> MuxEvent {
    MuxEvent::SettingsChanged(cmux_config::store::Change {
        revision: 1,
        keys: keys.iter().map(|key| (*key).to_string()).collect(),
        origin: cmux_config::store::Origin::User,
    })
}

/// Every settings change invalidates `settings.changed`; one that touches a key the theme is
/// made from also invalidates `theme.changed`. Both are declared with `settings.get`, so an app
/// hears them with `settings:read`.
#[test]
fn settings_changes_publish_settings_changed_and_theme_keys_also_theme_changed() {
    assert_eq!(streams(&settings_changed(&["terminal.fontSize"])), ["settings.changed"]);
    for key in ["appearance.theme", "appearance.themeFile", "appearance.accent"] {
        assert_eq!(
            streams(&settings_changed(&["terminal.fontSize", key])),
            ["settings.changed", "theme.changed"],
            "{key}"
        );
    }
    assert_eq!(
        streams(&settings_changed(&["appearance.themeEdits.dark.background"])),
        ["settings.changed", "theme.changed"]
    );
    assert_eq!(streams(&settings_changed(&["appearance.themeful"])), ["settings.changed"]);
    for stream in ["settings.changed", "theme.changed"] {
        assert_eq!(super::super::subscriptions::declared_reads(stream), Some("settings.get"));
    }
    assert_eq!(super::super::subscriptions::declared_reads("made.changed"), None);
}

/// A Cloud-pushed GitHub change is `github.changed` with an empty body; a move of the push
/// channel is the same stream with `{"live": bool}`. It reads `integration.request` as a GET
/// to GitHub, so only `integration:github:read` (or `integration:github`) hears it.
#[test]
fn github_changes_publish_github_changed_with_liveness_in_the_body() {
    let change = MuxEvent::GitHubChanged { live: None };
    assert_eq!(streams(&change), ["github.changed"]);
    assert_eq!(body(&change), json!({}));
    assert_eq!(body(&MuxEvent::GitHubChanged { live: Some(false) }), json!({"live": false}));
    let (reads, params) = super::super::subscriptions::declared("github.changed").unwrap();
    assert_eq!(
        (reads, params),
        ("integration.request", &json!({"provider": "github", "method": "GET"}))
    );
    let table = super::super::grants::ScopeTable::get();
    let grant = |scopes: &[&str]| super::super::grants::Grant {
        scopes: scopes.iter().map(|s| (*s).to_string()).collect(),
        ..Default::default()
    };
    let hears = |scopes: &[&str]| {
        matches!(
            table.check(reads, params, &grant(scopes)),
            super::super::grants::Decision::Allow(_)
        )
    };
    assert!(hears(&["integration:github:read"]));
    assert!(hears(&["integration:github"]));
    assert!(!hears(&["integration:slack:read"]), "another provider's grant hears nothing");
    assert!(!hears(&["net:api.github.com"]));
}

#[test]
fn requests_fill_current_selectors_only_where_the_op_takes_them() {
    let message: Value =
        serde_json::from_str(&request("workspace.list", json!({}), None).unwrap()).unwrap();
    assert_eq!(message["params"], json!({ "machine": "current", "session": "current" }));
    assert!(message.get("idempotency_key").is_none());
    let focus: Value = serde_json::from_str(
        &request("tab.focus", json!({ "tab": "tab_1" }), Some("k".into())).unwrap(),
    )
    .unwrap();
    assert_eq!(focus["idempotency_key"], "k");
    assert_eq!(request("made.up", json!({}), None).unwrap_err()["code"], "operation.unsupported");
}

#[test]
fn answers_wrap_reads_and_pass_mutation_results_through() {
    assert_eq!(
        answer("workspace.list", json!({ "ok": true, "result": [1] })).unwrap(),
        json!({ "value": [1] })
    );
    let mutation = json!({ "value": {}, "revision": "3", "replayed": false, "generation": "g" });
    assert_eq!(
        answer("tab.focus", json!({ "ok": true, "result": mutation.clone() })).unwrap(),
        mutation
    );
    let err = answer("tab.focus", json!({ "ok": false, "error": { "code": "selector.not_found", "message": "no tab", "retryable": false } })).unwrap_err();
    assert_eq!(err["code"], "selector.not_found");
}

/// `chat.list` and its older name `agent_chat.list` answer the same chats from the daemon's
/// chat index (no Mac provider), and a chat change invalidates both app streams.
#[test]
fn chat_list_and_agent_chat_list_answer_the_same_chats() {
    let mux = Mux::new_for_test("apps-chat-list", crate::SurfaceOptions::default());
    mux.change_chats(|chats| {
        chats.page(&[json!({
            "sessionId": "s1", "name": "fix", "harness": "codex", "status": "idle",
            "cwd": "/src/cmux", "unread": true, "unreadTurns": 1, "tags": {"pinned": "true"},
            "updatedAt": 2_000, "createdAt": 1_000, "pullRequests": [],
            "lane": {"state": "idle", "title": "Fix upload", "since": 1_500},
        })])
    });
    let router = MuxRouter::new(&mux);
    assert!(router.owns("chat.list") && router.owns("agent_chat.list"));
    let list = router.route("a/b", "chat.list", json!({}), None, Origin::Script).unwrap();
    let row = &list["value"][0];
    assert_eq!(
        (row["id"].clone(), row["pinned"].clone(), row["since_ms"].clone()),
        (json!("s1"), json!(true), json!("1500"))
    );
    let old = router.route("a/b", "agent_chat.list", json!({}), None, Origin::Script).unwrap();
    let chat = &old["value"]["chats"][0];
    assert_eq!(
        (chat["id"].clone(), chat["unread"].clone(), chat["since_ms"].clone()),
        (json!("s1"), json!(true), json!(1500))
    );
    assert_eq!(
        router.route("a/b", "agent_chat.list", json!({"x": 1}), None, Origin::Script).unwrap_err()
            ["code"],
        "validation.invalid"
    );
    assert_eq!(
        streams(&MuxEvent::ChatsChanged { revision: 1 }),
        ["chat.changed", "agent_chat.changed"]
    );
}
