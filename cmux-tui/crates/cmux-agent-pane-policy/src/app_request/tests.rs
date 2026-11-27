use serde_json::{Value, json};

use super::decode;

fn run(method: &str, params: Value) -> Value {
    decode(&json!({"id": "1", "method": method, "params": params}), "/Users/me").into_json()
}

fn field<'a>(out: &'a Value, key: &str) -> &'a Value {
    out.get(key).unwrap_or(&Value::Null)
}

fn case(out: &Value) -> &str {
    field(out, "case").as_str().unwrap_or("")
}

fn rejects(method: &str, params: Value) {
    let out = run(method, params.clone());
    assert_eq!(case(&out), "unsupported", "{method} {params}");
}

fn accepts(method: &str, params: Value, name: &str) -> Value {
    let out = run(method, params.clone());
    assert_eq!(case(&out), name, "{method} {params}");
    out
}

#[test]
fn bad_bodies_are_unsupported_and_unknown_methods_delegate() {
    assert_eq!(case(&decode(&json!([1]), "").into_json()), "unsupported");
    assert_eq!(case(&decode(&json!({"method": 3}), "").into_json()), "unsupported");
    assert_eq!(run("no.such", json!({})), json!({"delegate": true}));
}

#[test]
fn ids_and_texts_keep_their_caps() {
    let uuid = "123e4567-e89b-12d3-a456-426614174000";
    rejects("shell.read", json!({"id": "", "after": 0}));
    accepts("shell.read", json!({"id": "a".repeat(64), "after": 0}), "shellRead");
    rejects("shell.read", json!({"id": "a".repeat(65), "after": 0}));
    rejects("shell.read", json!({"id": "a", "after": -1}));
    rejects("shell.complete", json!({"line": "a".repeat(4097)}));
    accepts("shell.complete", json!({"line": "a".repeat(4096)}), "shellComplete");
    rejects("shell.run", json!({"command": "   "}));
    rejects("shell.run", json!({"command": "a".repeat(8193)}));
    accepts("shell.run", json!({"command": "a".repeat(8192)}), "shellRun");
    rejects("newTab.warm", json!({"warm": "a".repeat(512 * 1024 + 1)}));
    accepts("newTab.warm", json!({"warm": "a".repeat(512 * 1024)}), "newTabWarm");
    rejects("newTab.inputReady", json!({"token": "a".repeat(129)}));
    accepts("newTab.inputReady", json!({"token": "a".repeat(128)}), "newTabInputReady");
    rejects("newTab.setTemplate", json!({"template": "a".repeat(33)}));
    rejects("sandbox.run", json!({"task": "x".repeat(16_001), "key": uuid}));
    accepts("sandbox.run", json!({"task": "x".repeat(16_000), "key": uuid}), "sandboxRun");
    rejects("sandbox.run", json!({"task": "x", "key": "nope"}));
    rejects("sandbox.run", json!({"task": "x", "key": uuid, "agent": ""}));
    rejects("cloud.signIn", json!({"key": "nope"}));
    accepts("cloud.signIn", json!({"key": uuid}), "cloudSignIn");
    rejects("cloud.handoffTurn", json!({"sessionId": "has space"}));
    accepts("cloud.handoffTurn", json!({"sessionId": "abc_1.2:3-4"}), "cloudHandoffTurn");
    rejects("cloud.handoffTurn", json!({"sessionId": "a".repeat(129)}));
    rejects("chat.attention.open", json!({"tabId": "a".repeat(257)}));
    accepts("chat.attention.open", json!({"tabId": "a".repeat(256)}), "attentionOpen");
    rejects("chats.open", json!({"key": "nocolon"}));
    accepts("chats.open", json!({"key": "a:b"}), "openChat");
    rejects("chats.resume", json!({"ref": "a".repeat(4097)}));
    rejects("pane.moveToMachine", json!({"machine": "m", "session": ""}));
    rejects("folder.complete", json!({"path": "/a/../b"}));
    rejects("folder.complete", json!({"path": "rel"}));
    accepts("folder.complete", json!({"path": "/a/b"}), "completeFolder");
    rejects("harness.symbol", json!({"name": "Bad.Name"}));
    accepts("harness.symbol", json!({"name": "a.b1"}), "harnessSymbol");
    rejects("attachment.sourceIcon", json!({"bundleId": "nodot"}));
    accepts(
        "attachment.sourceIcon",
        json!({"bundleId": "com.apple.Notes"}),
        "attachmentSourceIcon",
    );
    rejects("chat.processTerminal", json!({"toolCallId": "-x"}));
    accepts("chat.processTerminal", json!({"toolCallId": "call_1"}), "processTerminal");
}

#[test]
fn lists_and_numbers_keep_their_bounds() {
    rejects("transport.send", json!({"connection": 1, "frames": []}));
    accepts("transport.send", json!({"connection": 1, "frames": ["a"]}), "transportSend");
    rejects("transport.send", json!({"connection": 1, "frames": vec!["a"; 4097]}));
    accepts("transport.send", json!({"connection": 1, "frames": vec!["a"; 4096]}), "transportSend");
    let out = accepts("pane.framePacing", json!({"intervals": vec![1.0; 700]}), "framePacing");
    assert_eq!(field(&out, "_0").as_array().map(Vec::len), Some(640));
    rejects("pane.framePacing", json!({"intervals": []}));
    rejects("harness.update", json!({"ids": []}));
    rejects("harness.update", json!({"ids": ["a", "a"]}));
    rejects("harness.update", json!({"ids": vec!["a"; 33]}));
    accepts("harness.update", json!({"ids": ["a", "b"]}), "harnessUpdate");
    rejects("pane.tabRowTools", json!({"width": 2001}));
    let out = accepts("pane.tabRowTools", json!({"width": 2000, "need": 1500}), "tabRowTools");
    assert_eq!(*field(&out, "need"), json!(1500.0));
    let out = accepts("pane.tabRowTools", json!({"width": 2000, "need": 2001}), "tabRowTools");
    assert_eq!(*field(&out, "need"), Value::Null);
    let out = accepts("pane.painted", json!({"copy": true, "live": true}), "painted");
    assert_eq!(*field(&out, "copy"), json!(true));
    assert_eq!(*field(&out, "live"), json!(true));
    rejects("pane.launchSettle", json!({"settledEpochMs": 1, "maxMovePx": -1, "shifts": 0}));
    rejects("cloud.preview.open", json!({"port": 0}));
    rejects("cloud.preview.open", json!({"port": 65536}));
    rejects("cloud.preview.open", json!({"port": true}));
    accepts("cloud.preview.open", json!({"port": 65535}), "openCloudPreview");
}

#[test]
fn open_tab_cuts_and_gates() {
    let out = accepts(
        "tab.open",
        json!({"kind": "terminal", "text": "a".repeat(9000), "cwd": "/x"}),
        "openTab",
    );
    assert_eq!(field(&out, "text").as_str().map(str::len), Some(8192));
    assert_eq!(*field(&out, "cwd"), json!("/x"));
    let out = accepts(
        "tab.open",
        json!({"kind": "browser", "cwd": "/x", "newProfile": true, "profileName": "  Work  "}),
        "openTab",
    );
    assert_eq!(*field(&out, "cwd"), Value::Null);
    assert_eq!(*field(&out, "profile"), json!({"new": "Work"}));
    rejects("tab.open", json!({"kind": "agent"}));
    rejects("tab.jump", json!({"target": "elsewhere", "id": "x"}));
    rejects("file.open", json!({"path": "", "where": "tab"}));
    rejects("file.open", json!({"path": "/a", "where": "nowhere"}));
}

#[test]
fn previews_stay_local() {
    accepts("browser.open", json!({"url": "http://localhost:3000/x"}), "openPreview");
    rejects("browser.open", json!({"url": "https://example.com"}));
    rejects("browser.open", json!({"url": "http://user@localhost/"}));
    rejects("browser.open", json!({"url": "https://user@example.com/"}));
    rejects("browser.open", json!({"url": "file:///etc/passwd"}));
    rejects("browser.open", json!({"url": format!("http://localhost/{}", "a".repeat(8200))}));
}

#[test]
fn run_action_checks_each_optional_field() {
    accepts("action.run", json!({"id": "x"}), "runAction");
    rejects("action.run", json!({"id": "x", "session": 5}));
    rejects("action.run", json!({"id": "x", "environment": "e"}));
    rejects("action.run", json!({"id": "x", "app": "a"}));
    // Swift's `isEditorID`: 1 to 32 of a-z, 0-9 and "-", so a bundle id is refused.
    rejects("action.run", json!({"id": "agentPane.openCwdInApp", "app": "com.apple.Terminal"}));
    rejects("action.run", json!({"id": "agentPane.openCwdInApp", "app": "a".repeat(33)}));
    accepts("action.run", json!({"id": "agentPane.openCwdInApp", "app": "vs-code"}), "runAction");
    let out = accepts(
        "action.run",
        json!({
            "id": "chatPlace.set",
            "mode": "cloud",
            "queued": 7,
            "hasDraft": true,
            "sessions": ["chat-1"]
        }),
        "runAction",
    );
    assert_eq!(*field(&out, "mode"), json!("cloud"));
    assert_eq!(*field(&out, "queued"), json!(7));
    assert_eq!(*field(&out, "hasDraft"), json!(true));
    assert_eq!(*field(&out, "sessions"), json!(["chat-1"]));
    let out = accepts(
        "action.run",
        json!({"id": "chatPriority.set", "priority": "high", "sessions": ["chat-1"]}),
        "runAction",
    );
    assert_eq!(*field(&out, "priority"), json!("high"));
    rejects("action.run", json!({"id": "chatPlace.set", "mode": "remote"}));
    rejects("action.run", json!({"id": "chatPlace.set", "sessions": ["chat-1"], "session": "tab"}));
    rejects("action.run", json!({"id": "x", "queued": 1}));
    rejects("action.run", json!({"id": "cloudEvacuate", "sessions": []}));
    let out = accepts(
        "action.run",
        json!({
            "id": "accounts.githubConnect",
            "repo": "owner/repo",
            "org": "owner",
            "returnTo": "https://example.com/return"
        }),
        "runAction",
    );
    assert_eq!(*field(&out, "repo"), json!("owner/repo"));
    assert_eq!(*field(&out, "org"), json!("owner"));
    assert_eq!(*field(&out, "returnTo"), json!("https://example.com/return"));
    let out = accepts(
        "action.run",
        json!({"id": "accounts.githubConnect", "repo": "bad repo", "org": "-bad"}),
        "runAction",
    );
    assert_eq!(*field(&out, "repo"), Value::Null);
    assert_eq!(*field(&out, "org"), Value::Null);
}

#[test]
fn header_folder_expands_home() {
    let out = accepts("chat.newHere", json!({"cwd": "~/code"}), "newChatHere");
    assert_eq!(*field(&out, "_0"), json!("/Users/me/code"));
    rejects("chat.newHere", json!({"cwd": "relative"}));
}

#[test]
fn replies_keep_their_keys_and_caps() {
    rejects("link.inspect", json!({"other": 1}));
    rejects("link.inspect", json!({"paths": vec!["/a"; 65]}));
    let out = accepts("link.inspect", json!({"paths": ["/a", "/a"]}), "reply");
    assert_eq!(*field(&out, "paths"), json!(["/a"]));
    rejects("link.inspect", json!({"urls": ["a".repeat(2049)]}));
    rejects("link.openPath", json!({"path": "/a", "line": 0}));
    rejects("link.openPath", json!({"path": "/a", "line": 10_000_001}));
    rejects("link.openPath", json!({"path": "/a", "line": true}));
    accepts("link.openPath", json!({"path": "/a", "line": 10_000_000}), "reply");
    rejects("link.openPath", json!({"path": "a".repeat(4097)}));
    rejects("link.openPath", json!({"path": "a\u{0}"}));
    rejects("media.load", json!({"src": "a".repeat(2049)}));
    rejects("video.frames", json!({"src": "/v", "times": []}));
    rejects("video.frames", json!({"src": "/v", "times": vec![1; 17]}));
    rejects("video.frames", json!({"src": "/v", "times": [86_400_001]}));
    rejects("video.frames", json!({"src": "/v", "times": [1.5]}));
    accepts("video.frames", json!({"src": "/v", "times": [86_400_000]}), "reply");
    rejects("browser.openIn", json!({"url": "javascript:alert(1)", "browserId": "b"}));
    rejects("browser.openIn", json!({"url": "https://a.com", "browserId": "b".repeat(65)}));
    accepts("browser.openIn", json!({"url": "https://a.com", "browserId": "b"}), "reply");
    rejects("image.copy", json!({"src": "http://x", "name": "n"}));
    let out = accepts(
        "image.copy",
        json!({"src": "data:image/png;base64,AA", "name": "é".repeat(400)}),
        "reply",
    );
    assert_eq!(field(&out, "name").as_str().map(str::len), Some(512));
    let combining = format!("{}e\u{301}tail", "a".repeat(511));
    let out = accepts(
        "image.copy",
        json!({"src": "data:image/png;base64,AA", "name": combining}),
        "reply",
    );
    let expected = "a".repeat(511);
    assert_eq!(field(&out, "name").as_str(), Some(expected.as_str()));
    rejects("image.reveal", json!({"src": "data:x", "name": "n", "path": ""}));
    rejects("pr.inspect", json!({"url": "https://github.com/a/b/commit/1"}));
    rejects("pr.inspect", json!({"url": "https://github.com/-a/b/pull/1"}));
    rejects("pr.inspect", json!({"url": "https://github.com/a/b/pull/01"}));
    rejects("pr.inspect", json!({"url": "https://github.com/a/b/pull/1?x=1"}));
    rejects("pr.inspect", json!({"url": "https://github.com/a/b/issues/1/files"}));
    let out = accepts("pr.inspect", json!({"url": "https://github.com/a/b/pull/1/files"}), "reply");
    assert_eq!(*field(&out, "_0"), json!("https://github.com/a/b/pull/1"));
    rejects("environment.remove", json!({"id": "nope"}));
    accepts(
        "environment.remove",
        json!({"id": "123e4567-e89b-12d3-a456-426614174000"}),
        "environment",
    );
    rejects("environment.list", json!({"x": 1}));
    assert_eq!(run("environment.save", json!({})), json!({"delegate": true}));
}

#[test]
fn new_tab_remembers_cloud_picks() {
    let out =
        accepts("newTab.remember", json!({"cloudStarted": "github:owner/repo"}), "rememberNewTab");
    assert_eq!(*field(&out, "cloudStarted"), json!("github:owner/repo"));
    rejects("newTab.remember", json!({"cloudStarted": "github:owner/repo\n"}));
    rejects("newTab.remember", json!({"cloudStarted": "github:owner/re po"}));
}

#[test]
fn pane_action_routes_the_diff_viewer_and_previews() {
    let out = accepts(
        "pane.action",
        json!({"id": "openDiffViewer", "cwd": "~/x", "mode": "toggle"}),
        "paneDiff",
    );
    assert_eq!(*field(&out, "cwd"), json!("/Users/me/x"));
    assert_eq!(*field(&out, "toggle"), json!(true));
    accepts("pane.action", json!({"id": "other"}), "paneAction");
    rejects("pane.action", json!({"id": ""}));
    rejects("pane.action", json!({"id": "a".repeat(129)}));
    accepts("pane.action", json!({"id": "preview"}), "preview");
    accepts("pane.action", json!({"id": "preview", "url": "http://localhost:1/"}), "preview");
    rejects("pane.action", json!({"id": "preview", "url": "https://example.com"}));
}
