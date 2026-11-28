//! Pins the `page_request` op to what the Swift host's `AgentPaneRequest(body:)` decoded
//! (AgentPaneRequest+Decoding.swift before the port), case by case.

use cmux_agent_pane_policy::ffi::call;
use cmux_agent_pane_policy::page_request::{self, graphemes, prefix};
use serde_json::{Value, json};

fn ask(method: &str, params: Value) -> Value {
    call("page_request", &json!({"method": method, "params": params}))
        .expect("page_request answers")
}

fn refused(method: &str, params: Value) {
    assert_eq!(ask(method, params.clone()), json!({"case": "unsupported"}), "{method} {params}");
}

#[test]
fn methods_it_does_not_own_go_back_to_the_host() {
    for method in
        ["tab.open", "chat.upload.chunk", "pane.saveFile", "cloud.reserve", "imessage.open", "nope"]
    {
        assert_eq!(ask(method, json!({})), json!({"case": null}), "{method}");
    }
    assert_eq!(
        call("page_request", &json!({"params": {}})),
        Err(cmux_agent_pane_policy::ffi::ERR_INVALID)
    );
    // `params` that is not an object is no params (Swift `as? [String: Any]`).
    assert_eq!(
        call("page_request", &json!({"method": "ready", "params": 3})).unwrap(),
        json!({"case": "ready"})
    );
}

#[test]
fn chat_texts_and_ids() {
    assert_eq!(ask("ready", json!({"reconnect": true})), json!({"case": "reconnect"}));
    assert_eq!(ask("ready", Value::Null), json!({"case": "ready"}));
    assert_eq!(
        ask("chat.missing", json!({"session": "s1"})),
        json!({"case": "missingChat", "session": "s1", "reason": "unknown"})
    );
    assert_eq!(
        ask("chat.missing", json!({"session": "s1", "reason": "gone"})),
        json!({"case": "missingChat", "session": "s1", "reason": "gone"})
    );
    refused("chat.missing", json!({"session": ""}));
    assert_eq!(
        ask("chat.persistSession", json!({"sessionId": "a"})),
        json!({"case": "persistSession", "id": "a"})
    );
    refused("chat.persistSession", json!({}));
    for (method, name) in [
        ("chat.cloudStartQueue", "cloudStartQueue"),
        ("chat.unsentDraft", "unsentDraft"),
        ("chat.leftover", "newChatLeftover"),
        ("chat.leftoverTaken", "newChatLeftoverTaken"),
    ] {
        assert_eq!(ask(method, json!({"text": ""})), json!({"case": name, "text": ""}));
        refused(method, json!({"text": 1}));
    }
}

#[test]
fn pane_flags_and_numbers() {
    assert_eq!(
        ask("pane.checkpointAvailability", json!({"available": false})),
        json!({"case": "checkpointAvailability", "available": false})
    );
    refused("pane.composerFilled", json!({"filled": "yes"}));
    assert_eq!(
        ask("pane.commandAvailability", json!({"commands": ["a", "b"]})),
        json!({"case": "commandAvailability", "commands": ["a", "b"]})
    );
    refused("pane.commandAvailability", json!({"commands": ["a", 1]}));
    let many: Vec<f64> = (0..700).map(f64::from).collect();
    let paced = ask("pane.framePacing", json!({"intervals": many}));
    assert_eq!(paced["intervals"].as_array().unwrap().len(), page_request::MAXIMUM_PACING_FRAMES);
    refused("pane.framePacing", json!({"intervals": []}));
    assert_eq!(
        ask("pane.setRemoteControl", json!({"on": true})),
        json!({"case": "remoteControl", "on": true})
    );
    refused("pane.setRemoteControl", json!({"on": true, "x": 1}));
    assert_eq!(
        ask("pane.noticeAction", json!({"id": "n"})),
        json!({"case": "paneNoticeAction", "id": "n"})
    );
    refused("pane.noticeAction", json!({"id": "n", "extra": true}));
    assert_eq!(
        ask("pane.painted", json!({"settled": true, "drewKeptTail": true})),
        json!({"case": "painted", "fromKeptTail": true, "settled": true, "copy": false, "live": false})
    );
    assert_eq!(
        ask("pane.inputEchoed", json!({"echoedEpochMs": 1500})),
        json!({"case": "inputEchoed", "epochMs": 1500.0})
    );
    refused("pane.inputEchoed", json!({}));
    assert_eq!(
        ask("pane.launchSettle", json!({"settledEpochMs": 10, "maxMovePx": 2.5, "shifts": 3.9})),
        json!({"case": "launchSettle", "epochMs": 10.0, "maxMovePx": 2.5, "element": "other", "shifts": 3})
    );
    assert_eq!(
        ask("pane.launchSettle", json!({"settledEpochMs": 1, "maxMovePx": 0, "shifts": 5e9}))["shifts"],
        1_000_000
    );
    refused("pane.launchSettle", json!({"settledEpochMs": 1, "maxMovePx": -1, "shifts": 0}));
    assert_eq!(
        ask("pane.renderRate", json!({"full": true})),
        json!({"case": "renderRate", "full": true})
    );
    assert_eq!(ask("pane.renderFailed", Value::Null), json!({"case": "renderFailed"}));
    assert_eq!(
        ask("pane.tabState", json!({"refresh": true})),
        json!({"case": "tabState", "refresh": true, "terminalSwitch": false})
    );
    assert_eq!(
        ask("pane.tabRowTools", json!({"width": 300, "need": 3000})),
        json!({"case": "tabRowTools", "width": 300.0, "need": null})
    );
    refused("pane.tabRowTools", json!({"width": 2001}));
    assert_eq!(
        ask("pane.toast", json!({"message": "hi", "tone": "error"})),
        json!({"case": "toast", "message": "hi", "isError": true, "group": null})
    );
    refused("pane.toast", json!({"message": ""}));
    assert_eq!(
        ask("pane.copyText", json!({"text": "x"})),
        json!({"case": "copyText", "text": "x"})
    );
    assert_eq!(
        ask("customizations.menu", json!({"point": {"x": 1, "y": 2.5}})),
        json!({"case": "customizationsMenu", "x": 1.0, "y": 2.5})
    );
    refused("customizations.menu", json!({"point": {"x": 1}}));
    assert_eq!(
        ask("pane.moveToMachine", json!({"machine": "m", "session": "s"})),
        json!({"case": "moveToMachine", "machine": "m", "session": "s"})
    );
    refused("pane.moveToMachine", json!({"machine": "m"}));
}

#[test]
fn tab_row_menu() {
    let menu =
        |item: Value| json!({"case": "tabRowToolsOpenMenu", "id": "chat-menu", "menuItemID": item});
    assert_eq!(ask("pane.tabRowTools.openMenu", json!({"id": "chat-menu"})), menu(Value::Null));
    assert_eq!(
        ask("pane.tabRowTools.openMenu", json!({"id": "chat-menu", "menuItemId": null})),
        menu(Value::Null)
    );
    assert_eq!(
        ask("pane.tabRowTools.openMenu", json!({"id": "chat-menu", "menuItemId": "rename"})),
        menu(json!("rename"))
    );
    refused("pane.tabRowTools.openMenu", json!({"id": "other"}));
    refused("pane.tabRowTools.openMenu", json!({"id": "chat-menu", "menuItemId": ""}));
    refused("pane.tabRowTools.openMenu", json!({"id": "chat-menu", "menuItemId": "x".repeat(65)}));
    refused("pane.tabRowTools.openMenu", json!({"id": "chat-menu", "menuItemId": 3}));
}

#[test]
fn harness_and_shell() {
    assert_eq!(
        ask("harness.update", json!({"id": "claude"})),
        json!({"case": "harnessUpdate", "ids": ["claude"], "each": false})
    );
    assert_eq!(
        ask("harness.update", json!({"id": "bad id", "ids": ["a", "b.c"]})),
        json!({"case": "harnessUpdate", "ids": ["a", "b.c"], "each": true})
    );
    refused("harness.update", json!({"ids": ["a", "a"]}));
    refused("harness.update", json!({"ids": ["a", "rm -rf"]}));
    refused("harness.update", json!({"ids": []}));
    assert_eq!(ask("acpmux.restart", Value::Null), json!({"case": "restartAcpmux"}));
    assert_eq!(ask("harness.restart", Value::Null), json!({"case": "harnessRestart"}));
    assert_eq!(
        ask("shell.run", json!({"command": "ls", "cwd": "relative"})),
        json!({"case": "shellRun", "command": "ls", "cwd": null})
    );
    assert_eq!(ask("shell.run", json!({"command": "ls", "cwd": "/tmp"}))["cwd"], "/tmp");
    refused("shell.run", json!({"command": " \n"}));
    refused("shell.run", json!({"command": "x".repeat(8193)}));
    assert_eq!(
        ask("shell.complete", json!({"line": ""})),
        json!({"case": "shellComplete", "line": "", "cwd": null})
    );
    refused("shell.complete", json!({"line": "x".repeat(4097)}));
}

#[test]
fn new_tab_and_jump() {
    assert_eq!(
        ask("newTab.inputReady", json!({"token": "t"})),
        json!({"case": "newTabInputReady", "token": "t"})
    );
    refused("newTab.inputReady", json!({"token": "t".repeat(129)}));
    for (method, name) in [
        ("newTab.touched", "touched"),
        ("newTab.context", "newTabContext"),
        ("newTab.cloudPick", "newTabCloudPick"),
        ("project.browse", "browseProject"),
        ("workspace.chooseFolder", "chooseFolder"),
        ("chat.folder.choose", "chooseChatFolder"),
        ("machine.share.self", "shareMachineWithMe"),
        ("chat.attach.choose", "chooseAttachments"),
        ("chat.attach.external", "attachExternal"),
        ("agent.mini", "miniSubject"),
        ("editors.list", "editorsList"),
        ("quick.dismiss", "quickDismiss"),
        ("quick.floatingState", "quickFloatingState"),
        ("quick.context", "quickContext"),
        ("transport.open", "transportOpen"),
        ("transport.gesture.release", "transportGestureRelease"),
        ("dictation.handoff", "dictationHandoff"),
        ("dictation.sources", "dictationSources"),
    ] {
        assert_eq!(ask(method, Value::Null), json!({"case": name}), "{method}");
    }
    assert_eq!(
        ask("newTab.warm", json!({"warm": "{}"})),
        json!({"case": "newTabWarm", "warm": "{}"})
    );
    refused("newTab.warm", json!({"warm": ""}));
    assert_eq!(
        ask("newTab.setTemplate", json!({"template": "t"})),
        json!({"case": "editNewTabTemplate", "template": "t"})
    );
    refused("newTab.setTemplate", json!({"template": "t".repeat(33)}));
    assert_eq!(
        ask("tab.jump", json!({"target": "here", "id": "x"})),
        json!({"case": "jump", "target": "here", "id": "x"})
    );
    refused("tab.jump", json!({"target": "there", "id": "x"}));
    let typed = ask("tab.typeAhead", json!({"text": "é".repeat(9000)}));
    assert_eq!(graphemes(typed["text"].as_str().unwrap()), 8192);
}

#[test]
fn cloud_and_sandbox() {
    let key = "0F3C2B1A-1234-4ABC-9DEF-0123456789ab";
    assert_eq!(
        ask("cloud.signIn", json!({"key": key})),
        json!({"case": "cloudSignIn", "key": key})
    );
    refused("cloud.signIn", json!({"key": "not-a-uuid"}));
    assert_eq!(
        ask("cloud.signInCancel", Value::Null),
        json!({"case": "cloudSignInCancel", "expired": false})
    );
    assert_eq!(
        ask("sandbox.state", json!({"wait": true})),
        json!({"case": "sandboxState", "wait": true})
    );
    assert_eq!(
        ask("cloud.handoffTurn", json!({"sessionId": "a_b.c:d-1"})),
        json!({"case": "cloudHandoffTurn", "sessionId": "a_b.c:d-1"})
    );
    refused("cloud.handoffTurn", json!({"sessionId": "a/b"}));
    assert_eq!(
        ask("sandbox.run", json!({"task": "do it", "key": key})),
        json!({"case": "sandboxRun", "task": "do it", "agent": null, "key": key})
    );
    refused("sandbox.run", json!({"task": "do it", "key": key, "agent": ""}));
    refused("sandbox.run", json!({"task": "  ", "key": key}));
    assert_eq!(
        ask("cloud.preview.open", json!({"port": 3000})),
        json!({"case": "openCloudPreview", "port": 3000})
    );
    for bad in [
        json!({"port": true}),
        json!({"port": 3000.5}),
        json!({"port": 0}),
        json!({"port": 80, "x": 1}),
        Value::Null,
    ] {
        refused("cloud.preview.open", bad);
    }
}

#[test]
fn folders_avatars_and_chats() {
    assert_eq!(
        ask("workspace.useFolder", json!({"cwd": "x", "confirm": true})),
        json!({"case": "useFolder", "cwd": "x", "confirm": true})
    );
    assert_eq!(ask("project.list", Value::Null), json!({"case": "listProjects", "query": null}));
    assert_eq!(
        ask("project.list", json!({"query": "q".repeat(600)}))["query"].as_str().unwrap().len(),
        512
    );
    for (method, name) in [
        ("agent.avatar", "agentAvatar"),
        ("agent.avatar.set", "setAgentAvatar"),
        ("agent.avatar.remove", "removeAgentAvatar"),
    ] {
        assert_eq!(ask(method, json!({"sessionId": "s"})), json!({"case": name, "sessionId": "s"}));
        refused(method, json!({"sessionId": ""}));
    }
    assert_eq!(ask("agent.mini.show", json!({})), json!({"case": "showInMini", "sessionId": null}));
    assert_eq!(
        ask("agent.mini.show", json!({"sessionId": "s"})),
        json!({"case": "showInMini", "sessionId": "s"})
    );
    refused("agent.mini.show", json!({"sessionId": ""}));
    assert_eq!(
        ask("chief.face", json!({"chief": "agent_x1"})),
        json!({"case": "chiefFace", "chief": "agent_x1"})
    );
    refused("chief.face", json!({"chief": "agent_"}));
    refused("chief.face", json!({"chief": "agent_a b"}));
    assert_eq!(
        ask("project.icon", json!({"cwd": "/a"})),
        json!({"case": "projectIcon", "cwd": "/a"})
    );
    refused("project.icon", json!({"cwd": "a"}));
    for (method, name) in [
        ("chats.open", "openChat"),
        ("chats.openInTerminal", "openChatInTerminal"),
        ("chats.watch", "watchChat"),
    ] {
        assert_eq!(ask(method, json!({"key": "a:b"})), json!({"case": name, "key": "a:b"}));
        refused(method, json!({"key": "ab"}));
    }
    assert_eq!(ask("chats.resume", json!({"ref": "r"})), json!({"case": "resumeChat", "ref": "r"}));
    refused("chats.resume", json!({"ref": " "}));
    assert_eq!(ask("app.action", json!({"id": "a"})), json!({"case": "appAction", "id": "a"}));
    assert_eq!(
        ask("chat.btw.inline", json!({"question": "q", "sessionId": "s"})),
        json!({"case": "btwInline", "question": "q", "sessionId": "s"})
    );
    refused("chat.btw.inline", json!({"question": "q"}));
    assert_eq!(
        ask("chat.sideChat", json!({"sessionId": "s", "split": "right"})),
        json!({"case": "sideChat", "sessionId": "s", "splitRight": true})
    );
    assert_eq!(
        ask("chat.offer.open", json!({"sessionId": "s"})),
        json!({"case": "offerOpen", "sessionId": "s", "sender": false})
    );
}

#[test]
fn quick_git_transport_dictation() {
    assert_eq!(
        ask("quick.openInWindow", json!({"sessionId": ""})),
        json!({"case": "quickOpenInWindow", "sessionId": null})
    );
    assert_eq!(
        ask("quick.setOnTop", json!({"onTop": true})),
        json!({"case": "quickSetOnTop", "onTop": true})
    );
    refused("quick.setCollapsed", json!({}));
    assert_eq!(
        ask("composer.capture", json!({"mode": "m"})),
        json!({"case": "composerCapture", "mode": "m"})
    );
    assert_eq!(
        ask("git.githubRepository", json!({"cwd": "/r"})),
        json!({"case": "githubRepository", "cwd": "/r"})
    );
    assert_eq!(ask("git.githubRepository", json!({"cwd": "r"})), json!({"case": "invalidGit"}));
    assert_eq!(
        ask("transport.send", json!({"connection": 4, "frames": ["a"]})),
        json!({"case": "transportSend", "connection": 4, "frames": ["a"]})
    );
    refused("transport.send", json!({"connection": 4, "frames": []}));
    refused("transport.send", json!({"connection": 4.5, "frames": ["a"]}));
    assert_eq!(
        ask("transport.close", json!({"connection": 2})),
        json!({"case": "transportClose", "connection": 2})
    );
    assert_eq!(
        ask("transport.ack", json!({"connection": 2, "seq": 9})),
        json!({"case": "transportAck", "connection": 2, "seq": 9, "inputPending": false})
    );
    for command in ["toggle", "start", "stop", "cancel"] {
        assert_eq!(
            ask(&format!("dictation.{command}"), Value::Null),
            json!({"case": "dictation", "command": command})
        );
    }
    assert_eq!(
        ask("dictation.audio", json!({"enabled": true})),
        json!({"case": "dictationRecordAudio", "enabled": true})
    );
    assert_eq!(
        ask("dictation.recording.cancel", json!({"path": "/p"})),
        json!({"case": "dictationRecordingCancel", "path": "/p"})
    );
    refused("dictation.recording.upload", json!({"path": "p"}));
    assert_eq!(
        ask("dictation.openSettings", json!({"permission": "microphone"})),
        json!({"case": "dictationOpenSettings", "permission": "microphone"})
    );
    refused("dictation.openSettings", json!({"permission": "camera"}));
}

#[test]
fn run_action_refuses_a_present_key_it_cannot_pass_on() {
    let base = json!({
        "case": "runAction", "id": "x", "session": null, "environment": null, "handoff": null, "app": null,
        "repo": null, "returnTo": null, "org": null, "mode": null, "queued": null, "hasDraft": null,
        "sessions": null, "priority": null,
    });
    assert_eq!(ask("action.run", json!({"id": "x"})), base);
    refused("action.run", json!({}));
    refused("action.run", json!({"id": "x", "session": ""}));
    refused("action.run", json!({"id": "x", "session": null}));
    refused("action.run", json!({"id": "x", "environment": "env_abc"}));
    assert_eq!(
        ask("action.run", json!({"id": "newCloudMachine", "environment": "env_abc"}))["environment"],
        "env_abc"
    );
    refused("action.run", json!({"id": "newCloudMachine", "environment": "abc"}));
    let token = "0123456789abcdef-";
    assert_eq!(
        ask("action.run", json!({"id": "palette.newCloudChat", "handoff": token}))["handoff"],
        token
    );
    refused("action.run", json!({"id": "palette.newCloudChat", "handoff": "short"}));
    assert_eq!(
        ask("action.run", json!({"id": "agentPane.openCwdInEditor", "app": "vscode"}))["app"],
        "vscode"
    );
    refused("action.run", json!({"id": "agentPane.openCwdInEditor", "app": "VSCode"}));
    refused("action.run", json!({"id": "x", "app": "vscode"}));
    let place = ask(
        "action.run",
        json!({"id": "chatPlace.set", "mode": "auto", "queued": 3, "hasDraft": true, "sessions": ["s"]}),
    );
    assert_eq!(
        (place["mode"].clone(), place["queued"].clone(), place["hasDraft"].clone()),
        (json!("auto"), json!(3), json!(true))
    );
    assert_eq!(place["sessions"], json!(["s"]));
    refused("action.run", json!({"id": "chatPlace.set", "sessions": ["s"], "session": "t"}));
    refused("action.run", json!({"id": "chatPlace.set", "sessions": ["a,b"]}));
    refused("action.run", json!({"id": "chatPlace.set", "queued": 100_001}));
    refused("action.run", json!({"id": "x", "hasDraft": true}));
    assert_eq!(
        ask("action.run", json!({"id": "chatPriority.set", "priority": "high"}))["priority"],
        "high"
    );
    refused("action.run", json!({"id": "chatPriority.set", "priority": "low"}));
    let all: Vec<String> = (0..500).map(|i| format!("s{i}")).collect();
    assert_eq!(
        ask("action.run", json!({"id": "cloudEvacuate", "sessions": all}))["sessions"]
            .as_array()
            .unwrap()
            .len(),
        500
    );
    refused("action.run", json!({"id": "cloudEvacuate", "sessions": []}));
    // Connect GitHub's extras are dropped when malformed, never refused.
    let github = ask(
        "action.run",
        json!({"id": "accounts.githubConnect", "repo": "manaflow-ai/cmux", "org": "-bad", "returnTo": "cmux://x"}),
    );
    assert_eq!(
        (github["repo"].clone(), github["org"].clone(), github["returnTo"].clone()),
        (json!("manaflow-ai/cmux"), Value::Null, json!("cmux://x"))
    );
    assert_eq!(ask("action.run", json!({"id": "x", "repo": "a/b"}))["repo"], Value::Null);
}

#[test]
fn validators_match_the_swift_ones() {
    use page_request::{is_editor_id, is_github_owner, is_github_repo, is_handoff_token, is_uuid};
    // AgentPaneEditorRequestTests' cases.
    for good in ["vscode", "rustrover", "sublime-text", "a1"] {
        assert!(is_editor_id(good), "{good}");
    }
    for bad in ["", "VSCode", "vs code", "vs_code", "é", &"a".repeat(33)] {
        assert!(!is_editor_id(bad), "{bad}");
    }
    assert!(
        is_github_owner("a")
            && is_github_owner("a-b")
            && !is_github_owner("a-")
            && !is_github_owner(&"a".repeat(40))
    );
    assert!(
        is_github_repo("a/b.c_d-e")
            && !is_github_repo("a/.")
            && !is_github_repo("a/..")
            && !is_github_repo("a/b/c")
    );
    assert!(
        !is_github_repo("a/")
            && !is_github_repo("/b")
            && !is_github_repo(&format!("a/{}", "b".repeat(101)))
    );
    assert!(
        is_handoff_token(&"a".repeat(16))
            && !is_handoff_token(&"a".repeat(15))
            && !is_handoff_token("aaaaaaaaaaaaaaa_")
    );
    assert!(
        is_uuid("00000000-0000-0000-0000-000000000000")
            && !is_uuid("00000000-0000-0000-0000-00000000000")
    );
    assert_eq!(prefix("e\u{301}x", 1), "e\u{301}");
}
