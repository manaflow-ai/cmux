//! The Swift decoder's pane cases, pinned (AgentPaneRequest+Decoding.swift).

use serde_json::{Value, json};

use super::*;

fn pane(method: &str, params: Value) -> Option<PaneOp> {
    decode(method, params.as_object())
}

#[test]
fn ready_is_a_reconnect_only_for_a_true_flag() {
    assert_eq!(pane("ready", Value::Null), Some(PaneOp::Ready));
    assert_eq!(pane("ready", json!({ "reconnect": 1 })), Some(PaneOp::Ready));
    assert_eq!(pane("ready", json!({ "reconnect": true })), Some(PaneOp::Reconnect));
}

#[test]
fn chat_messages_take_their_text() {
    assert_eq!(
        pane("chat.missing", json!({ "session": "s" })),
        Some(PaneOp::MissingChat { session: "s".into(), reason: "unknown".into() })
    );
    assert_eq!(
        pane("chat.missing", json!({ "session": "s", "reason": "gone" })),
        Some(PaneOp::MissingChat { session: "s".into(), reason: "gone".into() })
    );
    assert_eq!(pane("chat.missing", json!({ "session": "" })), None);
    assert_eq!(
        pane("chat.persistSession", json!({ "sessionId": "x" })),
        Some(PaneOp::PersistSession { id: "x".into() })
    );
    assert_eq!(pane("chat.persistSession", json!({ "sessionId": "" })), None);
    for method in
        ["chat.cloudStartQueue", "chat.unsentDraft", "chat.leftover", "chat.leftoverTaken"]
    {
        assert!(pane(method, json!({ "text": "" })).is_some(), "{method}");
        assert_eq!(pane(method, json!({ "text": 1 })), None, "{method}");
        assert_eq!(pane(method, Value::Null), None, "{method}");
    }
}

#[test]
fn pane_reports_are_checked() {
    assert_eq!(
        pane("pane.checkpointAvailability", json!({ "available": false })),
        Some(PaneOp::CheckpointAvailability { available: false })
    );
    assert_eq!(pane("pane.checkpointAvailability", json!({ "available": "no" })), None);
    assert_eq!(
        pane("pane.commandAvailability", json!({ "commands": [] })),
        Some(PaneOp::CommandAvailability { commands: vec![] })
    );
    assert_eq!(pane("pane.commandAvailability", json!({ "commands": ["a", 1] })), None);

    assert_eq!(pane("pane.framePacing", json!({ "intervals": [] })), None);
    assert_eq!(pane("pane.framePacing", json!({ "intervals": [1, "x"] })), None);
    let many: Vec<f64> = (0..700).map(f64::from).collect();
    let Some(PaneOp::FramePacing { intervals }) =
        pane("pane.framePacing", json!({ "intervals": many }))
    else {
        panic!("pacing");
    };
    assert_eq!(intervals.len(), MAXIMUM_PACING_FRAMES);

    assert_eq!(
        pane("pane.finishSound", json!({ "kind": "ci" })),
        Some(PaneOp::FinishSound { kind: FinishSound::Ci })
    );
    assert_eq!(pane("pane.finishSound", json!({ "kind": "other" })), None);

    assert_eq!(
        pane("pane.showDictation", json!({ "show": true })),
        Some(PaneOp::ComposerSetting { setting: ComposerSwitch::ShowDictation, show: true })
    );
    assert_eq!(
        pane("pane.setScrollToBottomOnSend", json!({ "show": false })),
        Some(PaneOp::ComposerSetting {
            setting: ComposerSwitch::ScrollToBottomOnSend,
            show: false
        })
    );
    assert_eq!(
        pane("pane.showContextUsage", json!({ "show": true })),
        Some(PaneOp::ComposerSetting { setting: ComposerSwitch::ShowContextUsage, show: true })
    );
    assert_eq!(pane("pane.showContextUsage", json!({})), None);

    assert_eq!(
        pane("pane.setRemoteControl", json!({ "on": true })),
        Some(PaneOp::RemoteControl { on: true })
    );
    assert_eq!(pane("pane.setRemoteControl", json!({ "on": true, "x": 1 })), None);
    assert_eq!(
        pane("pane.noticeAction", json!({ "id": "n" })),
        Some(PaneOp::PaneNoticeAction { id: "n".into() })
    );
    assert_eq!(pane("pane.noticeAction", json!({ "id": "n", "x": 1 })), None);
    assert_eq!(
        pane("pane.clientReady", json!({ "ready": true })),
        Some(PaneOp::ClientReady { ready: true })
    );
    assert_eq!(
        pane("pane.renderRate", json!({ "full": false })),
        Some(PaneOp::RenderRate { full: false })
    );
    assert_eq!(pane("pane.renderRate", json!({})), None);
}

#[test]
fn painted_reads_four_flags_defaulting_to_false() {
    assert_eq!(
        pane("pane.painted", Value::Null),
        Some(PaneOp::Painted { from_kept_tail: false, settled: false, copy: false, live: false })
    );
    assert_eq!(
        pane(
            "pane.painted",
            json!({ "drewKeptTail": true, "settled": "yes", "copy": true, "live": true })
        ),
        Some(PaneOp::Painted { from_kept_tail: true, settled: false, copy: true, live: true })
    );
}

#[test]
fn timings_are_finite_and_non_negative() {
    assert_eq!(
        pane("pane.inputEchoed", json!({ "echoedEpochMs": 1500 })),
        Some(PaneOp::InputEchoed { epoch_ms: 1500.0 })
    );
    assert_eq!(pane("pane.inputEchoed", json!({ "echoedEpochMs": "1" })), None);
    assert_eq!(
        pane("pane.launchSettle", json!({ "settledEpochMs": 1, "maxMovePx": 2.5, "shifts": 3.9 })),
        Some(PaneOp::LaunchSettle {
            settled_epoch_ms: 1.0,
            max_move_px: 2.5,
            element: "other".into(),
            shifts: 3
        })
    );
    assert_eq!(
        pane(
            "pane.launchSettle",
            json!({ "settledEpochMs": 1, "maxMovePx": 0, "shifts": 5e9, "element": "row" })
        ),
        Some(PaneOp::LaunchSettle {
            settled_epoch_ms: 1.0,
            max_move_px: 0.0,
            element: "row".into(),
            shifts: 1_000_000
        })
    );
    assert_eq!(
        pane("pane.launchSettle", json!({ "settledEpochMs": 1, "maxMovePx": -1, "shifts": 0 })),
        None
    );
    assert_eq!(pane("pane.launchSettle", json!({ "settledEpochMs": 1, "maxMovePx": 1 })), None);
}

#[test]
fn type_ahead_keeps_the_first_characters() {
    let long = "é".repeat(MAXIMUM_OPEN_TAB_TEXT + 5);
    let Some(PaneOp::TypeAhead { text }) = pane("tab.typeAhead", json!({ "text": long })) else {
        panic!("type-ahead")
    };
    assert_eq!(text.chars().count(), MAXIMUM_OPEN_TAB_TEXT);
    // A flag with its combining marks is one character, as Swift counts it.
    let flags = "\u{1F1FA}\u{1F1F8}".repeat(MAXIMUM_OPEN_TAB_TEXT + 1);
    let Some(PaneOp::TypeAhead { text }) = pane("tab.typeAhead", json!({ "text": flags })) else {
        panic!("type-ahead")
    };
    assert_eq!(characters(&text), MAXIMUM_OPEN_TAB_TEXT);
    assert_eq!(pane("tab.typeAhead", json!({})), None);
}

#[test]
fn harness_update_takes_ids_never_a_command() {
    assert_eq!(
        pane("harness.update", json!({ "id": "claude-code" })),
        Some(PaneOp::HarnessUpdate { ids: vec!["claude-code".into()], each: false })
    );
    assert_eq!(
        pane("harness.update", json!({ "id": "rm -rf", "ids": ["a", "b.c"] })),
        Some(PaneOp::HarnessUpdate { ids: vec!["a".into(), "b.c".into()], each: true })
    );
    assert_eq!(pane("harness.update", json!({ "ids": ["a", "a"] })), None);
    assert_eq!(pane("harness.update", json!({ "ids": ["a", "b c"] })), None);
    assert_eq!(pane("harness.update", json!({ "ids": [] })), None);
    let many: Vec<String> = (0..33).map(|i| format!("h{i}")).collect();
    assert_eq!(pane("harness.update", json!({ "ids": many })), None);
    assert_eq!(pane("harness.update", json!({ "id": "x".repeat(129) })), None);
    assert_eq!(pane("acpmux.restart", Value::Null), Some(PaneOp::RestartAcpmux));
    assert_eq!(pane("harness.restart", Value::Null), Some(PaneOp::HarnessRestart));
}

#[test]
fn the_shell_box_checks_its_command_and_folder() {
    assert_eq!(
        pane("shell.run", json!({ "command": "ls", "cwd": "/tmp" })),
        Some(PaneOp::ShellRun { command: "ls".into(), cwd: Some("/tmp".into()) })
    );
    assert_eq!(
        pane("shell.run", json!({ "command": "ls", "cwd": "relative" })),
        Some(PaneOp::ShellRun { command: "ls".into(), cwd: None })
    );
    assert_eq!(pane("shell.run", json!({ "command": " \n " })), None);
    assert_eq!(
        pane("shell.run", json!({ "command": "x".repeat(MAXIMUM_OPEN_TAB_TEXT + 1) })),
        None
    );
    assert_eq!(
        pane("shell.read", json!({ "id": "a", "after": 2.7 })),
        Some(PaneOp::ShellRead { id: "a".into(), after: 2 })
    );
    assert_eq!(pane("shell.read", json!({ "id": "a", "after": -1 })), None);
    assert_eq!(pane("shell.read", json!({ "id": "", "after": 0 })), None);
    assert_eq!(pane("shell.read", json!({ "id": "x".repeat(65), "after": 0 })), None);
    assert_eq!(
        pane("shell.complete", json!({ "line": "gi", "cwd": "/" })),
        Some(PaneOp::ShellComplete { line: "gi".into(), cwd: Some("/".into()) })
    );
    assert_eq!(pane("shell.complete", json!({ "line": "x".repeat(MAXIMUM_SHELL_LINE + 1) })), None);
    assert_eq!(
        pane("shell.stop", json!({ "id": "a" })),
        Some(PaneOp::ShellStop { id: "a".into() })
    );
}

#[test]
fn the_new_tab_page_messages() {
    assert_eq!(
        pane("newTab.inputReady", json!({ "token": "t" })),
        Some(PaneOp::NewTabInputReady { token: "t".into() })
    );
    assert_eq!(pane("newTab.inputReady", json!({ "token": "t".repeat(129) })), None);
    assert_eq!(pane("newTab.touched", Value::Null), Some(PaneOp::Touched));
    assert_eq!(pane("newTab.context", Value::Null), Some(PaneOp::NewTabContext));
    assert_eq!(pane("newTab.cloudPick", Value::Null), Some(PaneOp::NewTabCloudPick));
    assert_eq!(
        pane("newTab.warm", json!({ "warm": "{}" })),
        Some(PaneOp::NewTabWarm { warm: "{}".into() })
    );
    assert_eq!(pane("newTab.warm", json!({ "warm": "x".repeat(MAXIMUM_WARM_BYTES + 1) })), None);
    assert_eq!(
        pane("newTab.setTemplate", json!({ "template": "grid" })),
        Some(PaneOp::NewTabTemplate { template: "grid".into() })
    );
    assert_eq!(pane("newTab.setTemplate", json!({ "template": "" })), None);
    assert_eq!(pane("newTab.setTemplate", json!({ "template": "x".repeat(33) })), None);
}

#[test]
fn the_answer_names_the_op() {
    assert_eq!(
        serde_json::to_value(super::super::decode(
            &json!({ "method": "pane.painted", "params": { "live": true } })
        ))
        .unwrap(),
        json!({ "case": "pane", "pane": { "op": "painted", "fromKeptTail": false, "settled": false, "copy": false, "live": true } })
    );
    assert_eq!(
        serde_json::to_value(super::super::decode(
            &json!({ "method": "shell.stop", "params": {} })
        ))
        .unwrap(),
        json!({ "case": "unsupported", "method": "shell.stop" })
    );
}
