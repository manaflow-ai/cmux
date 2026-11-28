//! The Swift decoder's host cases, pinned (AgentPaneRequest+Decoding.swift).

use serde_json::{Value, json};

use super::*;

fn host(method: &str, params: Value) -> Option<HostCall> {
    decode(method, params.as_object())
}

#[test]
fn every_listed_method_decodes_or_refuses_without_panicking() {
    for method in HOST_METHODS {
        let _ = host(method, Value::Null);
        let _ = host(method, json!({ "x": [1, { "y": null }] }));
    }
    let mut unique = HOST_METHODS.to_vec();
    unique.sort_unstable();
    unique.dedup();
    assert_eq!(unique.len(), HOST_METHODS.len());
}

#[test]
fn asks_with_no_params_take_none() {
    for (method, call) in [
        ("project.browse", HostCall::BrowseProject),
        ("cloud.setupState", HostCall::CloudSetupState),
        ("workspace.chooseFolder", HostCall::ChooseFolder),
        ("chat.folder.choose", HostCall::ChooseChatFolder),
        ("machine.share.self", HostCall::ShareMachineWithMe),
        ("chat.attach.choose", HostCall::ChooseAttachments),
        ("chat.attach.external", HostCall::AttachExternal),
        ("editors.list", HostCall::EditorsList),
        ("quick.dismiss", HostCall::QuickDismiss),
        ("quick.floatingState", HostCall::QuickFloatingState),
        ("quick.context", HostCall::QuickContext),
        ("transport.open", HostCall::TransportOpen),
        ("transport.gesture.release", HostCall::TransportGestureRelease),
        ("dictation.toggle", HostCall::Dictation { command: "toggle" }),
        ("dictation.start", HostCall::Dictation { command: "start" }),
        ("dictation.stop", HostCall::Dictation { command: "stop" }),
        ("dictation.cancel", HostCall::Dictation { command: "cancel" }),
        ("dictation.handoff", HostCall::DictationHandoff),
        ("dictation.sources", HostCall::DictationSources),
        ("sandbox.state", HostCall::SandboxState { wait: false }),
        ("cloud.signInCancel", HostCall::CloudSignInCancel { expired: false }),
        ("pane.tabState", HostCall::TabState { refresh: false, terminal_switch: false }),
        ("composer.capture", HostCall::ComposerCapture { mode: None }),
        ("quick.openInWindow", HostCall::QuickOpenInWindow { session_id: None }),
    ] {
        assert_eq!(host(method, Value::Null), Some(call), "{method}");
    }
}

#[test]
fn flags_count_only_when_true() {
    assert_eq!(
        host("sandbox.state", json!({ "wait": true })),
        Some(HostCall::SandboxState { wait: true })
    );
    assert_eq!(
        host("sandbox.state", json!({ "wait": "true" })),
        Some(HostCall::SandboxState { wait: false })
    );
    assert_eq!(
        host("pane.tabState", json!({ "refresh": true, "terminalSwitch": true })),
        Some(HostCall::TabState { refresh: true, terminal_switch: true })
    );
    assert_eq!(
        host("quick.setOnTop", json!({ "onTop": false })),
        Some(HostCall::QuickSetOnTop { on_top: false })
    );
    assert_eq!(host("quick.setOnTop", json!({})), None);
    assert_eq!(
        host("quick.setCollapsed", json!({ "collapsed": true })),
        Some(HostCall::QuickSetCollapsed { collapsed: true })
    );
    assert_eq!(
        host("dictation.audio", json!({ "enabled": true })),
        Some(HostCall::DictationRecordAudio { enabled: true })
    );
    assert_eq!(host("dictation.audio", json!({ "enabled": 1 })), None);
}

#[test]
fn cloud_ids_are_checked() {
    assert_eq!(
        host("cloud.handoffTurn", json!({ "sessionId": "a_b.c:d-1" })),
        Some(HostCall::CloudHandoffTurn { session_id: "a_b.c:d-1".into() })
    );
    assert_eq!(host("cloud.handoffTurn", json!({ "sessionId": "a b" })), None);
    assert_eq!(host("cloud.handoffTurn", json!({ "sessionId": "x".repeat(129) })), None);
    let key = "123E4567-e89b-12d3-a456-426614174000";
    assert_eq!(
        host("cloud.signIn", json!({ "key": key })),
        Some(HostCall::CloudSignIn { key: key.into() })
    );
    for bad in [
        "123e4567e89b12d3a456426614174000",
        "{123e4567-e89b-12d3-a456-426614174000}",
        "123e4567-e89b-12d3-a456-42661417400g",
        "",
    ] {
        assert_eq!(host("cloud.signIn", json!({ "key": bad })), None, "{bad}");
    }
}

#[test]
fn dictation_recordings_take_an_absolute_path() {
    assert_eq!(
        host("dictation.recording.upload", json!({ "path": "/tmp/a.wav" })),
        Some(HostCall::DictationRecordingUpload { path: "/tmp/a.wav".into() })
    );
    assert_eq!(
        host("dictation.recording.cancel", json!({ "path": "/tmp/a.wav" })),
        Some(HostCall::DictationRecordingCancel { path: "/tmp/a.wav".into() })
    );
    assert_eq!(host("dictation.recording.upload", json!({ "path": "a.wav" })), None);
    assert_eq!(
        host("dictation.recording.upload", json!({ "path": format!("/{}", "a".repeat(4096)) })),
        None
    );
}

#[test]
fn the_tab_row_and_menus() {
    assert_eq!(
        host("pane.tabRowTools", json!({ "width": 300, "need": 5000 })),
        Some(HostCall::TabRowTools { width: 300.0, need: None })
    );
    assert_eq!(
        host("pane.tabRowTools", json!({ "width": 0, "need": 12.5 })),
        Some(HostCall::TabRowTools { width: 0.0, need: Some(12.5) })
    );
    assert_eq!(host("pane.tabRowTools", json!({ "width": 2001 })), None);
    assert_eq!(host("pane.tabRowTools", json!({ "width": "1" })), None);

    assert_eq!(
        host("customizations.menu", json!({ "point": { "x": 1, "y": -2.5 } })),
        Some(HostCall::CustomizationsMenu { x: 1.0, y: -2.5 })
    );
    assert_eq!(host("customizations.menu", json!({ "point": { "x": 1 } })), None);

    assert_eq!(
        host("pane.tabRowTools.openMenu", json!({ "id": "chat-menu" })),
        Some(HostCall::TabRowToolsOpenMenu { id: "chat-menu".into(), menu_item_id: None })
    );
    assert_eq!(
        host("pane.tabRowTools.openMenu", json!({ "id": "chat-menu", "menuItemId": null })),
        Some(HostCall::TabRowToolsOpenMenu { id: "chat-menu".into(), menu_item_id: None })
    );
    assert_eq!(
        host("pane.tabRowTools.openMenu", json!({ "id": "chat-menu", "menuItemId": "rename" })),
        Some(HostCall::TabRowToolsOpenMenu {
            id: "chat-menu".into(),
            menu_item_id: Some("rename".into())
        })
    );
    assert_eq!(host("pane.tabRowTools.openMenu", json!({ "id": "other" })), None);
    assert_eq!(
        host("pane.tabRowTools.openMenu", json!({ "id": "chat-menu", "menuItemId": "" })),
        None
    );
    assert_eq!(
        host(
            "pane.tabRowTools.openMenu",
            json!({ "id": "chat-menu", "menuItemId": "m".repeat(65) })
        ),
        None
    );
    assert_eq!(
        host("pane.tabRowTools.openMenu", json!({ "id": "chat-menu", "menuItemId": 3 })),
        None
    );
}

#[test]
fn toasts_and_copies() {
    assert_eq!(
        host("pane.toast", json!({ "message": "m", "tone": "error", "group": "g" })),
        Some(HostCall::Toast { message: "m".into(), is_error: true, group: Some("g".into()) })
    );
    assert_eq!(
        host("pane.toast", json!({ "message": "m", "tone": "info" })),
        Some(HostCall::Toast { message: "m".into(), is_error: false, group: None })
    );
    assert_eq!(host("pane.toast", json!({ "message": "" })), None);
    assert_eq!(
        host("pane.copyText", json!({ "text": "" })),
        Some(HostCall::CopyText { text: String::new() })
    );
    assert_eq!(host("pane.copyText", json!({})), None);
    assert_eq!(
        host("composer.capture", json!({ "mode": "area" })),
        Some(HostCall::ComposerCapture { mode: Some("area".into()) })
    );
    assert_eq!(
        host("quick.openInWindow", json!({ "sessionId": "s" })),
        Some(HostCall::QuickOpenInWindow { session_id: Some("s".into()) })
    );
    assert_eq!(
        host("quick.openInWindow", json!({ "sessionId": "" })),
        Some(HostCall::QuickOpenInWindow { session_id: None })
    );
}

#[test]
fn chat_links_take_a_chat_id() {
    assert_eq!(
        host("chat.btw.inline", json!({ "question": "why?", "sessionId": "s" })),
        Some(HostCall::BtwInline { question: "why?".into(), session_id: "s".into() })
    );
    assert_eq!(host("chat.btw.inline", json!({ "question": "  \n", "sessionId": "s" })), None);
    assert_eq!(
        host(
            "chat.btw.inline",
            json!({ "question": "q".repeat(MAXIMUM_BTW_QUESTION + 1), "sessionId": "s" })
        ),
        None
    );
    assert_eq!(
        host("chat.btw.inline", json!({ "question": "q", "sessionId": "s".repeat(257) })),
        None
    );

    assert_eq!(
        host("chat.sideChat", json!({ "sessionId": "s", "split": "right" })),
        Some(HostCall::SideChat { session_id: "s".into(), split_right: true })
    );
    assert_eq!(
        host("chat.sideChat", json!({ "sessionId": "s", "split": "down" })),
        Some(HostCall::SideChat { session_id: "s".into(), split_right: false })
    );
    assert_eq!(host("chat.sideChat", json!({ "sessionId": "" })), None);
    assert_eq!(
        host("chat.openTab", json!({ "sessionId": "s", "placement": "right" })),
        Some(HostCall::ChatTab { session_id: "s".into(), placement: Some("right".into()) })
    );
    assert_eq!(host("chat.openTab", json!({ "sessionId": "s".repeat(257) })), None);
    assert_eq!(
        host("chat.attention.open", json!({ "tabId": "t" })),
        Some(HostCall::AttentionOpen { tab_id: "t".into() })
    );
    assert_eq!(
        host("chat.attention.open", json!({ "tabId": "t".repeat(MAXIMUM_ATTENTION_TAB_ID + 1) })),
        None
    );
    assert_eq!(
        host("chat.offer.open", json!({ "sessionId": "s", "sender": true })),
        Some(HostCall::OfferOpen { session_id: "s".into(), sender: true })
    );
    assert_eq!(
        host("tab.jump", json!({ "target": "closed", "id": "x" })),
        Some(HostCall::Jump { target: "closed".into(), id: "x".into() })
    );
    assert_eq!(host("tab.jump", json!({ "target": "window", "id": "x" })), None);
    assert_eq!(host("tab.jump", json!({ "target": "tab", "id": "" })), None);
}

#[test]
fn the_answer_names_the_op() {
    assert_eq!(
        serde_json::to_value(super::super::decode(
            &json!({ "method": "pane.toast", "params": { "message": "m" } })
        ))
        .unwrap(),
        json!({ "case": "host", "host": { "op": "toast", "message": "m", "isError": false, "group": null } })
    );
}
