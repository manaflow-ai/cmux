//! What a page request (a `WKScriptMessage` the agent pane page posts, `{method, params}`) asks the
//! host for: the method's checks on its params, in one place (layer-ownership.md: Rust owns the
//! rules). The Swift host (CmuxNextAgentPane `AgentPaneRequest(body:)`) asks this module through
//! the `page_request` op and only builds its enum case from the answer.
//!
//! The answer is one object:
//! - `{"case": NAME, ...fields}`: the request, named as the Swift case (`missingChat`), with its
//!   checked and trimmed fields under the case's own labels;
//! - `{"case": "unsupported"}`: the method is this module's and its params break a rule (the
//!   host refuses it as `unsupported(method)`); `invalidGit` for the Git method;
//! - `{"case": null}`: the method is not this module's; the host decodes it itself.
//!
//! A length is what the Swift host measured: `utf8` (bytes) or `count` (grapheme clusters,
//! [`graphemes`]), as each rule says. No I/O, no clock, no state.

use serde_json::{Map, Value, json};
use unicode_segmentation::UnicodeSegmentation;

/// The longest text a tab open, a type-ahead or a folder carries (Swift `maximumOpenTabText`).
pub const MAXIMUM_OPEN_TAB_TEXT: usize = 8192;
/// The most frame intervals one `pane.framePacing` keeps (Swift `maximumPacingFrames`).
pub const MAXIMUM_PACING_FRAMES: usize = 640;
/// The longest sandbox task, in grapheme clusters (Swift `maximumSandboxTask`).
pub const MAXIMUM_SANDBOX_TASK: usize = 16_000;
/// The most frames one `transport.send` carries (Swift `maximumSendFrames`).
pub const MAXIMUM_SEND_FRAMES: usize = 4096;
/// The longest shell completion line, in bytes (Swift `AgentPaneShellCompletion.maximumLine`).
pub const MAXIMUM_COMPLETION_LINE: usize = 4096;
/// The largest New Tab warm snapshot, in bytes (Swift `AgentPaneNewTab.maximumWarmBytes`).
pub const MAXIMUM_WARM_BYTES: usize = 512 * 1024;
/// The longest path a folder, an icon or a recording names, in bytes.
pub const MAXIMUM_PATH: usize = 4096;
/// The folder actions that take an `app` (Swift `AgentPaneModel.editorActions`).
pub const EDITOR_ACTIONS: [&str; 2] = ["agentPane.openCwdInEditor", "agentPane.openCwdInApp"];
/// `tab.jump`'s targets (Swift `AgentPaneJumpTarget`).
pub const JUMP_TARGETS: [&str; 4] = ["tab", "workspace", "here", "closed"];
/// `dictation.openSettings`'s permissions (Swift `DictationPermission`).
pub const DICTATION_PERMISSIONS: [&str; 2] = ["microphone", "speechRecognition"];

/// The grapheme clusters of `text`: Swift's `String.count`.
pub fn graphemes(text: &str) -> usize {
    text.graphemes(true).count()
}

/// The first `limit` grapheme clusters of `text`: Swift's `String(text.prefix(limit))`.
pub fn prefix(text: &str, limit: usize) -> String {
    text.graphemes(true).take(limit).collect()
}

/// Empty once Foundation's `whitespacesAndNewlines` are trimmed.
fn is_blank(text: &str) -> bool {
    text.trim().is_empty()
}

/// Foundation's `UUID(uuidString:)`: 8-4-4-4-12 hex digits, either case.
pub fn is_uuid(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(i, b)| match i {
            8 | 13 | 18 | 23 => *b == b'-',
            _ => b.is_ascii_hexdigit(),
        })
}

/// A Cloud environment id as the platform makes them (`env_` and up to 64 letters, digits, `_`
/// or `-`): the only `environment` `action.run` passes on.
pub fn is_cloud_environment_id(id: &str) -> bool {
    id.starts_with("env_")
        && (5..=68).contains(&graphemes(id))
        && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// An editor id of cmux-window-rules' table (`vscode`, `rustrover`): 1 to 32 lowercase ASCII
/// letters, digits or dashes, so it names a table row and carries nothing itself.
pub fn is_editor_id(id: &str) -> bool {
    (1..=32).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// A page's one-time hand-off token (webviews commandPlace.ts: a UUID): 16 to 64 ASCII letters,
/// digits and dashes, so it names a stored entry and carries nothing itself.
pub fn is_handoff_token(token: &str) -> bool {
    (16..=64).contains(&graphemes(token))
        && token.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// `action.run`'s `sessions`: Evacuate and Bring Back name 1...500 chats; a chat-list row's place
/// pick, Cancel or Retry names exactly one, and never with `session` (the tab's own chat). Each id
/// is usable and has no comma (the app's handlers read the list comma-joined).
pub fn are_session_targets(sessions: &[&str], id: &str, alongside: Option<&str>) -> bool {
    let usable = sessions.iter().all(|s| !s.is_empty() && graphemes(s) <= 256 && !s.contains(','));
    match id {
        "cloudEvacuate" | "cloudBringBackAll" => usable && (1..=500).contains(&sessions.len()),
        "chatPlace.set" | "chatPriority.set" | "chatMove.cancel" | "chatMove.retry" => {
            usable && sessions.len() == 1 && alongside.is_none()
        }
        _ => false,
    }
}

/// A GitHub account or org name: 1 to 39 letters, digits and inner dashes (webviews
/// githubConnect.ts `isGitHubOwner`, acpmux `settings_ask`).
pub fn is_github_owner(value: &str) -> bool {
    let bytes = value.as_bytes();
    (1..=39).contains(&bytes.len())
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'-')
        && bytes.first() != Some(&b'-')
        && bytes.last() != Some(&b'-')
}

/// A GitHub repository's full name (webviews githubConnect.ts `isGitHubRepo`): an owner as
/// [`is_github_owner`], a name of 1 to 100 letters, digits, `.`, `_` and `-`, never `.` or `..`.
pub fn is_github_repo(value: &str) -> bool {
    if value.len() > 140 {
        return false;
    }
    let Some((owner, name)) = value.split_once('/') else { return false };
    is_github_owner(owner)
        && (1..=100).contains(&name.len())
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        && name != "."
        && name != ".."
}

/// A Chief's participant id (acpmux `fromChief`): `agent_` and a short token.
fn is_chief_id(chief: &str) -> bool {
    chief.starts_with("agent_")
        && (7..=64).contains(&chief.len())
        && chief.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// A harness id (a profile file name), never a command.
fn is_harness_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
}

/// One of the store's session ids (`SESSION` in backend handoffs/routes.ts).
fn is_store_session(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
}

/// A folder the app may run in: absolute and at most [`MAXIMUM_PATH`] bytes, else none.
fn absolute_folder(value: Option<&Value>) -> Value {
    match value.and_then(Value::as_str) {
        Some(cwd) if cwd.starts_with('/') && cwd.len() <= MAXIMUM_PATH => json!(cwd),
        _ => Value::Null,
    }
}

/// The params of one request, read as the Swift host read Foundation's bridged values.
struct Params<'a>(Option<&'a Map<String, Value>>);

impl<'a> Params<'a> {
    fn get(&self, key: &str) -> Option<&'a Value> {
        self.0.and_then(|p| p.get(key))
    }
    fn text(&self, key: &str) -> Option<&'a str> {
        self.get(key).and_then(Value::as_str)
    }
    fn flag(&self, key: &str) -> Option<bool> {
        self.get(key).and_then(Value::as_bool)
    }
    /// `params?[key] as? Bool == true`.
    fn on(&self, key: &str) -> bool {
        self.flag(key) == Some(true)
    }
    fn number(&self, key: &str) -> Option<f64> {
        self.get(key).and_then(Value::as_f64)
    }
    fn int(&self, key: &str) -> Option<i64> {
        self.get(key).and_then(Value::as_i64)
    }
    fn texts(&self, key: &str) -> Option<Vec<&'a str>> {
        self.get(key)?.as_array()?.iter().map(Value::as_str).collect()
    }
    /// The keys are exactly `keys`.
    fn only(&self, keys: &[&str]) -> bool {
        let p = self.0.map_or(0, Map::len);
        p == keys.len() && keys.iter().all(|k| self.get(k).is_some())
    }
    /// `params?[key] as? String` that, when there, passes `rule`: `Some(None)` when absent,
    /// `Some(Some(text))` when it passes, `None` (refuse) when it is there and fails.
    fn optional(&self, key: &str, rule: impl Fn(&str) -> bool) -> Option<Option<&'a str>> {
        match self.get(key) {
            None => Some(None),
            Some(value) => value.as_str().filter(|t| rule(t)).map(Some),
        }
    }
}

/// The answer for a method this module owns.
fn case(name: &str, fields: Value) -> Value {
    let mut out = match fields {
        Value::Object(map) => map,
        _ => Map::new(),
    };
    out.insert("case".into(), json!(name));
    Value::Object(out)
}

fn bare(name: &str) -> Option<Value> {
    Some(case(name, Value::Null))
}

/// The answer to one page request; `None` refuses it (`unsupported`).
fn decode(method: &str, p: &Params) -> Option<Option<Value>> {
    let session_id =
        |key: &str, limit: usize| p.text(key).filter(|s| !s.is_empty() && graphemes(s) <= limit);
    let chat_key = |key: &str| p.text(key).filter(|k| k.contains(':') && graphemes(k) <= 512);
    let answer = match method {
        "ready" => bare(if p.on("reconnect") { "reconnect" } else { "ready" }),
        "chat.missing" => p
            .text("session")
            .filter(|s| !s.is_empty())
            .map(|s| case("missingChat", json!({"session": s, "reason": p.text("reason").unwrap_or("unknown")}))),
        "chat.persistSession" => {
            p.text("sessionId").filter(|s| !s.is_empty()).map(|s| case("persistSession", json!({"id": s})))
        }
        "chat.cloudStartQueue" | "chat.unsentDraft" | "chat.leftover" | "chat.leftoverTaken" => {
            let name = match method {
                "chat.cloudStartQueue" => "cloudStartQueue",
                "chat.unsentDraft" => "unsentDraft",
                "chat.leftover" => "newChatLeftover",
                _ => "newChatLeftoverTaken",
            };
            p.text("text").map(|t| case(name, json!({"text": t})))
        }
        "pane.checkpointAvailability" => {
            p.flag("available").map(|v| case("checkpointAvailability", json!({"available": v})))
        }
        "pane.composerFilled" => p.flag("filled").map(|v| case("composerFilled", json!({"filled": v}))),
        "pane.commandAvailability" => p.texts("commands").map(|c| case("commandAvailability", json!({"commands": c}))),
        "pane.framePacing" => {
            let intervals: Option<Vec<f64>> = p.get("intervals").and_then(Value::as_array).and_then(|list| list.iter().map(Value::as_f64).collect());
            intervals.filter(|list| !list.is_empty()).map(|mut list| {
                list.truncate(MAXIMUM_PACING_FRAMES);
                case("framePacing", json!({"intervals": list}))
            })
        }
        "pane.setRemoteControl" => p
            .flag("on")
            .filter(|_| p.only(&["on"]))
            .map(|on| case("remoteControl", json!({"on": on}))),
        "pane.noticeAction" => p
            .text("id")
            .filter(|_| p.only(&["id"]))
            .map(|id| case("paneNoticeAction", json!({"id": id}))),
        "pane.clientReady" => p.flag("ready").map(|v| case("clientReady", json!({"ready": v}))),
        "pane.painted" => Some(case(
            "painted",
            json!({
                "fromKeptTail": p.flag("drewKeptTail").unwrap_or(false),
                "settled": p.flag("settled").unwrap_or(false),
                "copy": p.flag("copy").unwrap_or(false),
                "live": p.flag("live").unwrap_or(false),
            }),
        )),
        "pane.renderFailed" => bare("renderFailed"),
        "pane.inputEchoed" => p
            .number("echoedEpochMs")
            .filter(|ms| ms.is_finite())
            .map(|ms| case("inputEchoed", json!({"epochMs": ms}))),
        "pane.launchSettle" => {
            let at = p.number("settledEpochMs").filter(|v| v.is_finite());
            let px = p.number("maxMovePx").filter(|v| v.is_finite() && *v >= 0.0);
            let shifts = p.number("shifts").filter(|v| v.is_finite() && *v >= 0.0);
            match (at, px, shifts) {
                (Some(at), Some(px), Some(shifts)) => Some(case(
                    "launchSettle",
                    json!({
                        "epochMs": at,
                        "maxMovePx": px,
                        "element": p.text("element").unwrap_or("other"),
                        // Swift `Int(min(shifts, 1_000_000))`: toward zero.
                        "shifts": shifts.min(1_000_000.0).trunc() as i64,
                    }),
                )),
                _ => None,
            }
        }
        "pane.renderRate" => p.flag("full").map(|v| case("renderRate", json!({"full": v}))),
        "tab.typeAhead" => p.text("text").map(|t| case("typeAhead", json!({"text": prefix(t, MAXIMUM_OPEN_TAB_TEXT)}))),
        "harness.update" => {
            if let Some(id) = p.text("id").filter(|id| is_harness_id(id)) {
                Some(case("harnessUpdate", json!({"ids": [id], "each": false})))
            } else if let Some(list) = p.get("ids").and_then(Value::as_array).filter(|l| (1..=32).contains(&l.len())) {
                let ids: Vec<&str> = list.iter().filter_map(Value::as_str).filter(|id| is_harness_id(id)).collect();
                let unique: std::collections::BTreeSet<&&str> = ids.iter().collect();
                (ids.len() == list.len() && unique.len() == ids.len()).then(|| case("harnessUpdate", json!({"ids": ids, "each": true})))
            } else {
                None
            }
        }
        "acpmux.restart" => bare("restartAcpmux"),
        "harness.restart" => bare("harnessRestart"),
        "shell.run" => p
            .text("command")
            .filter(|c| !is_blank(c) && c.len() <= MAXIMUM_OPEN_TAB_TEXT)
            .map(|c| case("shellRun", json!({"command": c, "cwd": absolute_folder(p.get("cwd"))}))),
        "shell.complete" => p
            .text("line")
            .filter(|l| l.len() <= MAXIMUM_COMPLETION_LINE)
            .map(|l| case("shellComplete", json!({"line": l, "cwd": absolute_folder(p.get("cwd"))}))),
        "newTab.inputReady" => p
            .text("token")
            .filter(|t| !t.is_empty() && graphemes(t) <= 128)
            .map(|t| case("newTabInputReady", json!({"token": t}))),
        "newTab.touched" => bare("touched"),
        "newTab.context" => bare("newTabContext"),
        "newTab.cloudPick" => bare("newTabCloudPick"),
        "newTab.warm" => p
            .text("warm")
            .filter(|t| !t.is_empty() && t.len() <= MAXIMUM_WARM_BYTES)
            .map(|t| case("newTabWarm", json!({"warm": t}))),
        "newTab.setTemplate" => p
            .text("template")
            .filter(|t| !t.is_empty() && graphemes(t) <= 32)
            .map(|t| case("editNewTabTemplate", json!({"template": t}))),
        "tab.jump" => match (p.text("target").filter(|t| JUMP_TARGETS.contains(t)), session_id("id", 256)) {
            (Some(target), Some(id)) => Some(case("jump", json!({"target": target, "id": id}))),
            _ => None,
        },
        "project.browse" => bare("browseProject"),
        "sandbox.state" => Some(case("sandboxState", json!({"wait": p.on("wait")}))),
        "cloud.handoffTurn" => p
            .text("sessionId")
            .filter(|s| is_store_session(s))
            .map(|s| case("cloudHandoffTurn", json!({"sessionId": s}))),
        "cloud.signInCancel" => Some(case("cloudSignInCancel", json!({"expired": p.on("expired")}))),
        "cloud.signIn" => p.text("key").filter(|k| is_uuid(k)).map(|k| case("cloudSignIn", json!({"key": k}))),
        "sandbox.run" => {
            // The task is the person's prompt (never logged); the server checks the agent by name.
            let agent = p.text("agent");
            let task = p.text("task").filter(|t| !is_blank(t) && graphemes(t) <= MAXIMUM_SANDBOX_TASK);
            let key = p.text("key").filter(|k| is_uuid(k));
            match (task, key) {
                (Some(task), Some(key)) if agent.is_none_or(|a| !a.is_empty() && graphemes(a) <= 32) => {
                    Some(case("sandboxRun", json!({"task": task, "agent": agent, "key": key})))
                }
                _ => None,
            }
        }
        "workspace.chooseFolder" => bare("chooseFolder"),
        "chat.folder.choose" => bare("chooseChatFolder"),
        "machine.share.self" => bare("shareMachineWithMe"),
        "chat.attach.choose" => bare("chooseAttachments"),
        "chat.attach.external" => bare("attachExternal"),
        "workspace.useFolder" => p
            .text("cwd")
            .filter(|c| c.len() <= MAXIMUM_OPEN_TAB_TEXT)
            .map(|c| case("useFolder", json!({"cwd": c, "confirm": p.on("confirm")}))),
        "project.list" => Some(case("listProjects", json!({"query": p.text("query").map(|q| prefix(q, 512))}))),
        "agent.avatar" | "agent.avatar.set" | "agent.avatar.remove" => {
            let name = match method {
                "agent.avatar" => "agentAvatar",
                "agent.avatar.set" => "setAgentAvatar",
                _ => "removeAgentAvatar",
            };
            p.text("sessionId")
                .filter(|s| !s.is_empty() && s.len() <= 256)
                .map(|s| case(name, json!({"sessionId": s})))
        }
        "agent.mini" => bare("miniSubject"),
        // A session id is short; null (or absent) is the Chief.
        "agent.mini.show" => match p.text("sessionId") {
            Some(s) if s.is_empty() || s.len() > 256 => None,
            session => Some(case("showInMini", json!({"sessionId": session}))),
        },
        "chief.face" => p.text("chief").filter(|c| is_chief_id(c)).map(|c| case("chiefFace", json!({"chief": c}))),
        "project.icon" => p
            .text("cwd")
            .filter(|c| c.starts_with('/') && c.len() <= MAXIMUM_PATH)
            .map(|c| case("projectIcon", json!({"cwd": c}))),
        "chats.open" => chat_key("key").map(|k| case("openChat", json!({"key": k}))),
        "chats.openInTerminal" => chat_key("key").map(|k| case("openChatInTerminal", json!({"key": k}))),
        "chats.watch" => chat_key("key").map(|k| case("watchChat", json!({"key": k}))),
        "chats.resume" => p
            .text("ref")
            .filter(|r| !is_blank(r) && r.len() <= MAXIMUM_PATH)
            .map(|r| case("resumeChat", json!({"ref": r}))),
        "app.action" => session_id("id", 128).map(|id| case("appAction", json!({"id": id}))),
        "pane.moveToMachine" => match (session_id("machine", 256), session_id("session", 256)) {
            (Some(machine), Some(session)) => Some(case("moveToMachine", json!({"machine": machine, "session": session}))),
            _ => None,
        },
        "pane.tabState" => Some(case("tabState", json!({"refresh": p.on("refresh"), "terminalSwitch": p.on("terminalSwitch")}))),
        "pane.tabRowTools" => {
            let within = |v: &f64| v.is_finite() && (0.0..=2000.0).contains(v);
            p.number("width").filter(within).map(|width| {
                case("tabRowTools", json!({"width": width, "need": p.number("need").filter(within)}))
            })
        }
        "pane.toast" => p.text("message").filter(|m| !m.is_empty()).map(|m| {
            case("toast", json!({"message": m, "isError": p.text("tone") == Some("error"), "group": p.text("group")}))
        }),
        "pane.copyText" => p.text("text").map(|t| case("copyText", json!({"text": t}))),
        "customizations.menu" => {
            let point = p.get("point").and_then(Value::as_object);
            let coord = |k: &str| point.and_then(|o| o.get(k)).and_then(Value::as_f64).filter(|v| v.is_finite());
            match (coord("x"), coord("y")) {
                (Some(x), Some(y)) => Some(case("customizationsMenu", json!({"x": x, "y": y}))),
                _ => None,
            }
        }
        "pane.tabRowTools.openMenu" => {
            let chat_menu = p.text("id") == Some("chat-menu");
            match p.get("menuItemId") {
                None | Some(Value::Null) => {
                    chat_menu.then(|| case("tabRowToolsOpenMenu", json!({"id": "chat-menu", "menuItemID": null})))
                }
                Some(item) => item
                    .as_str()
                    .filter(|i| chat_menu && !i.is_empty() && i.len() <= 256 && graphemes(i) <= 64)
                    .map(|i| case("tabRowToolsOpenMenu", json!({"id": "chat-menu", "menuItemID": i}))),
            }
        }
        "chat.btw.inline" => {
            let question = p.text("question").filter(|q| !is_blank(q) && q.len() <= 32 * 1024);
            let session = p.text("sessionId").filter(|s| !s.is_empty() && s.len() <= 256);
            match (question, session) {
                (Some(q), Some(s)) => Some(case("btwInline", json!({"question": q, "sessionId": s}))),
                _ => None,
            }
        }
        "chat.sideChat" => session_id("sessionId", 256)
            .map(|id| case("sideChat", json!({"sessionId": id, "splitRight": p.text("split") == Some("right")}))),
        "chat.offer.open" => {
            session_id("sessionId", 256).map(|id| case("offerOpen", json!({"sessionId": id, "sender": p.on("sender")})))
        }
        "cloud.preview.open" => {
            let port = p.get("port").filter(|v| v.is_number()).and_then(Value::as_f64);
            port.filter(|v| p.only(&["port"]) && v.fract() == 0.0 && (1.0..=65535.0).contains(v))
                .map(|v| case("openCloudPreview", json!({"port": v as i64})))
        }
        "editors.list" => bare("editorsList"),
        "quick.dismiss" => bare("quickDismiss"),
        "quick.openInWindow" => {
            Some(case("quickOpenInWindow", json!({"sessionId": p.text("sessionId").filter(|s| !s.is_empty())})))
        }
        "quick.setOnTop" => p.flag("onTop").map(|v| case("quickSetOnTop", json!({"onTop": v}))),
        "quick.setCollapsed" => p.flag("collapsed").map(|v| case("quickSetCollapsed", json!({"collapsed": v}))),
        "quick.floatingState" => bare("quickFloatingState"),
        "quick.context" => bare("quickContext"),
        "composer.capture" => Some(case("composerCapture", json!({"mode": p.text("mode")}))),
        "git.githubRepository" => match p.text("cwd").filter(|c| c.starts_with('/') && !c.contains('\0')) {
            Some(cwd) => Some(case("githubRepository", json!({"cwd": cwd}))),
            None => return Some(Some(case("invalidGit", Value::Null))),
        },
        "transport.open" => bare("transportOpen"),
        "transport.gesture.release" => bare("transportGestureRelease"),
        "transport.send" => match (p.int("connection"), p.texts("frames")) {
            (Some(connection), Some(frames)) if (1..=MAXIMUM_SEND_FRAMES).contains(&frames.len()) => {
                Some(case("transportSend", json!({"connection": connection, "frames": frames})))
            }
            _ => None,
        },
        "transport.close" => p.int("connection").map(|c| case("transportClose", json!({"connection": c}))),
        "transport.ack" => match (p.int("connection"), p.int("seq")) {
            (Some(connection), Some(seq)) => Some(case(
                "transportAck",
                json!({"connection": connection, "seq": seq, "inputPending": p.flag("inputPending").unwrap_or(false)}),
            )),
            _ => None,
        },
        "dictation.toggle" | "dictation.start" | "dictation.stop" | "dictation.cancel" => {
            method.strip_prefix("dictation.").map(|command| case("dictation", json!({"command": command})))
        }
        "dictation.handoff" => bare("dictationHandoff"),
        "dictation.sources" => bare("dictationSources"),
        "dictation.audio" => p.flag("enabled").map(|v| case("dictationRecordAudio", json!({"enabled": v}))),
        "dictation.recording.upload" | "dictation.recording.cancel" => {
            let name = if method == "dictation.recording.upload" { "dictationRecordingUpload" } else { "dictationRecordingCancel" };
            p.text("path")
                .filter(|path| path.starts_with('/') && path.len() <= MAXIMUM_PATH)
                .map(|path| case(name, json!({"path": path})))
        }
        "dictation.openSettings" => p
            .text("permission")
            .filter(|v| DICTATION_PERMISSIONS.contains(v))
            .map(|v| case("dictationOpenSettings", json!({"permission": v}))),
        "action.run" => run_action(p),
        _ => return None,
    };
    Some(answer)
}

/// `action.run`: each optional key that is there must pass its rule, never be dropped (a dropped
/// `session` would run the action on whatever the tab shows; a dropped `environment` would make a
/// machine in another one).
fn run_action(p: &Params) -> Option<Value> {
    let id = p.text("id").filter(|id| !id.is_empty() && graphemes(id) <= 128)?;
    let session = p.optional("session", |s| !s.is_empty() && graphemes(s) <= 256)?;
    let environment =
        p.optional("environment", |e| id == "newCloudMachine" && is_cloud_environment_id(e))?;
    let handoff = p.optional("handoff", |h| id == "palette.newCloudChat" && is_handoff_token(h))?;
    let app = p.optional("app", |a| EDITOR_ACTIONS.contains(&id) && is_editor_id(a))?;
    let mode =
        p.optional("mode", |m| id == "chatPlace.set" && ["local", "cloud", "auto"].contains(&m))?;
    let priority =
        p.optional("priority", |m| id == "chatPriority.set" && ["high", "normal"].contains(&m))?;
    let cargo = ["chatPlace.set", "chatMove.retry"].contains(&id);
    let queued = match p.get("queued") {
        None => None,
        Some(v) => Some(v.as_i64().filter(|q| cargo && (0..=100_000).contains(q))?),
    };
    let has_draft = match p.get("hasDraft") {
        None => None,
        Some(v) => Some(v.as_bool().filter(|_| cargo)?),
    };
    let sessions = match p.get("sessions") {
        None => None,
        Some(_) => Some(p.texts("sessions").filter(|list| are_session_targets(list, id, session))?),
    };
    // Connect GitHub's card names the failed call's repository and the chat's link: a malformed
    // one is dropped (Connect still runs, as from the palette).
    let github = id == "accounts.githubConnect";
    let repo = p.text("repo").filter(|r| github && is_github_repo(r));
    let return_to = p.text("returnTo").filter(|r| github && r.len() <= 512);
    let org = p.text("org").filter(|o| github && is_github_owner(o));
    Some(case(
        "runAction",
        json!({
            "id": id, "session": session, "environment": environment, "handoff": handoff, "app": app,
            "repo": repo, "returnTo": return_to, "org": org, "mode": mode, "queued": queued,
            "hasDraft": has_draft, "sessions": sessions, "priority": priority,
        }),
    ))
}

/// The `page_request` op: `{method, params}` to the answer (module docs); `None` when the request
/// is not `{method: string, params?: object|null}`.
pub fn call(request: &Value) -> Option<Value> {
    let method = request.get("method")?.as_str()?;
    let params = match request.get("params") {
        None | Some(Value::Null) => None,
        Some(Value::Object(map)) => Some(map),
        // Swift `object["params"] as? [String: Any]`: any other value is no params.
        Some(_) => None,
    };
    Some(match decode(method, &Params(params)) {
        None => json!({"case": null}),
        Some(None) => json!({"case": "unsupported"}),
        Some(Some(answer)) => answer,
    })
}
