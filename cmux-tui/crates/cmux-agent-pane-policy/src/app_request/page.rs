//! The page's `{id, method, params}` requests to the app that need no Swift type to decide
//! (`AgentPaneRequest.init(body:)`): each method's caps, ids and defaults. A method not here is
//! the host's own decoder's still (`None`).

use serde_json::{Value, json};

use super::ids::{
    has_text, is_absolute_path, is_bundle_id, is_chief_id, is_cloud_environment_id, is_editor_id,
    is_handoff_token, is_harness_id, is_store_session, is_symbol_name, is_token, is_uuid,
    is_well_formed_folder,
};
use super::url::is_preview_url;
use super::value::{
    Params, Present, as_double, bytes_within, count_within, id_bytes, id_chars, is_blank, prefix,
};
use super::{Decoded, case, case_with, unsupported};

/// Longest `tab.open` text kept; a command or address is far shorter.
pub const MAXIMUM_OPEN_TAB_TEXT: usize = 8192;
/// Longest `sandbox.run` task: the Run API's own cap.
pub const MAXIMUM_SANDBOX_TASK: usize = 16_000;
/// Most frame intervals one `pane.framePacing` keeps.
pub const MAXIMUM_PACING_FRAMES: usize = 640;
/// Most frames one `transport.send` carries.
pub const MAXIMUM_SEND_FRAMES: usize = 4096;
/// Longest `newTab.warm` text, in bytes.
pub const MAXIMUM_WARM_BYTES: usize = 512 * 1024;
/// Longest `shell.complete` line, in bytes.
pub const MAXIMUM_SHELL_LINE: usize = 4096;
/// Longest `chat.attention.open` tab id, in bytes.
pub const MAXIMUM_ATTENTION_TAB_ID: usize = 256;
/// The editor actions that may carry an `app`.
pub const EDITOR_ACTIONS: [&str; 2] = ["agentPane.openCwdInEditor", "agentPane.openCwdInApp"];

/// The decoded request of `method`, or `None` when the host's own decoder still owns it.
pub fn decode(method: &str, params: Params<'_>, home: &str) -> Option<Decoded> {
    let out = match method {
        "ready" => {
            if params.is_true("reconnect") {
                case("reconnect")
            } else {
                case("ready")
            }
        }
        "chat.missing" => match params.string("session").filter(|session| !session.is_empty()) {
            Some(session) => case_with(
                "missingChat",
                [
                    ("session", json!(session)),
                    ("reason", json!(params.string("reason").unwrap_or("unknown"))),
                ],
            ),
            None => unsupported(method),
        },
        "chat.persistSession" => one_text(
            method,
            "persistSession",
            params.string("sessionId").filter(|id| !id.is_empty()),
        ),
        "chat.unsentDraft" => one_text(method, "unsentDraft", params.string("text")),
        "chat.leftover" => one_text(method, "newChatLeftover", params.string("text")),
        "chat.leftoverTaken" => one_text(method, "newChatLeftoverTaken", params.string("text")),
        "pane.checkpointAvailability" => {
            one_flag(method, "checkpointAvailability", params.boolean("available"))
        }
        "pane.commandAvailability" => match params.strings("commands") {
            Some(commands) => case_with("commandAvailability", [("_0", json!(commands))]),
            None => unsupported(method),
        },
        "pane.framePacing" => frame_pacing(method, params),
        "pane.finishSound" => {
            match params.string("kind").filter(|kind| ["turn", "ci", "merged"].contains(kind)) {
                Some(kind) => case_with("finishSound", [("_0", json!(kind))]),
                None => unsupported(method),
            }
        }
        "pane.showContextUsage" | "pane.showDictation" | "pane.setScrollToBottomOnSend" => {
            match params.boolean("show") {
                Some(show) => case_with(
                    "composerSetting",
                    [("setting", json!(method)), ("show", json!(show))],
                ),
                None => unsupported(method),
            }
        }
        "pane.setRemoteControl" => match params.boolean("on").filter(|_| params.only_key("on")) {
            Some(on) => case_with("remoteControl", [("on", json!(on))]),
            None => unsupported(method),
        },
        "pane.noticeAction" => match params.string("id").filter(|_| params.only_key("id")) {
            Some(id) => case_with("paneNoticeAction", [("id", json!(id))]),
            None => unsupported(method),
        },
        "pane.clientReady" => one_flag(method, "clientReady", params.boolean("ready")),
        "pane.painted" => case_with(
            "painted",
            [
                ("fromKeptTail", json!(params.boolean("drewKeptTail").unwrap_or(false))),
                ("settled", json!(params.boolean("settled").unwrap_or(false))),
            ],
        ),
        "pane.launchSettle" => launch_settle(method, params),
        "pane.renderRate" => one_flag(method, "renderRate", params.boolean("full")),
        "tab.open" => open_tab(method, params),
        "tab.typeAhead" => match params.string("text") {
            Some(text) => {
                case_with("typeAhead", [("_0", json!(prefix(text, MAXIMUM_OPEN_TAB_TEXT)))])
            }
            None => unsupported(method),
        },
        "harness.update" => harness_update(method, params),
        "acpmux.restart" => case("restartAcpmux"),
        "acpmux.restartStuck" => case("restartStuckAcpmux"),
        "harness.restart" => case("harnessRestart"),
        "shell.run" => shell_run(method, params),
        "shell.read" => {
            match (shell_id(params), params.ns_int("after").filter(|after| *after >= 0)) {
                (Some(id), Some(after)) => {
                    case_with("shellRead", [("id", json!(id)), ("after", json!(after))])
                }
                _ => unsupported(method),
            }
        }
        "shell.complete" => {
            match params.string("line").filter(|line| bytes_within(line, MAXIMUM_SHELL_LINE)) {
                Some(line) => case_with(
                    "shellComplete",
                    [("line", json!(line)), ("cwd", json!(absolute_cwd(params)))],
                ),
                None => unsupported(method),
            }
        }
        "shell.stop" => match shell_id(params) {
            Some(id) => case_with("shellStop", [("id", json!(id))]),
            None => unsupported(method),
        },
        "newTab.inputReady" => match id_chars(params.string("token"), 128) {
            Some(token) => case_with("newTabInputReady", [("_0", json!(token))]),
            None => unsupported(method),
        },
        "newTab.touched" => case("touched"),
        "newTab.context" => case("newTabContext"),
        "newTab.warm" => match params
            .string("warm")
            .filter(|text| !text.is_empty() && bytes_within(text, MAXIMUM_WARM_BYTES))
        {
            Some(text) => case_with("newTabWarm", [("_0", json!(text))]),
            None => unsupported(method),
        },
        "newTab.setTemplate" => match id_chars(params.string("template"), 32) {
            Some(template) => case_with("editNewTabTemplate", [("_0", json!(template))]),
            None => unsupported(method),
        },
        "newTab.remember" => remember_new_tab(method, params),
        "tab.jump" => match (
            params
                .string("target")
                .filter(|target| ["tab", "workspace", "here", "closed"].contains(target)),
            id_chars(params.string("id"), 256),
        ) {
            (Some(target), Some(id)) => {
                case_with("jump", [("target", json!(target)), ("id", json!(id))])
            }
            _ => unsupported(method),
        },
        "project.browse" => case("browseProject"),
        "sandbox.state" => case_with("sandboxState", [("wait", json!(params.is_true("wait")))]),
        "cloud.handoffTurn" => {
            match params.string("sessionId").filter(|session| is_store_session(session)) {
                Some(session) => case_with("cloudHandoffTurn", [("sessionId", json!(session))]),
                None => unsupported(method),
            }
        }
        "cloud.signInCancel" => {
            case_with("cloudSignInCancel", [("expired", json!(params.is_true("expired")))])
        }
        "cloud.signIn" => match params.string("key").filter(|key| is_uuid(key)) {
            Some(key) => case_with("cloudSignIn", [("key", json!(key))]),
            None => unsupported(method),
        },
        "sandbox.run" => sandbox_run(method, params),
        "workspace.chooseFolder" => case("chooseFolder"),
        "chat.folder.choose" => case("chooseChatFolder"),
        "machine.share.self" => case("shareMachineWithMe"),
        "chat.attach.choose" => case("chooseAttachments"),
        "chat.attach.external" => case("attachExternal"),
        "attachment.sourceIcon" => match params.string("bundleId").filter(|id| is_bundle_id(id)) {
            Some(id) => case_with("attachmentSourceIcon", [("_0", json!(id))]),
            None => unsupported(method),
        },
        "workspace.useFolder" => {
            match params.string("cwd").filter(|cwd| bytes_within(cwd, MAXIMUM_OPEN_TAB_TEXT)) {
                Some(cwd) => case_with(
                    "useFolder",
                    [("_0", json!(cwd)), ("confirm", json!(params.is_true("confirm")))],
                ),
                None => unsupported(method),
            }
        }
        "project.list" => {
            let query = params.string("query").map(|query| prefix(query, 512));
            case_with("listProjects", [("_0", json!(query))])
        }
        "agent.avatar" | "agent.avatar.set" | "agent.avatar.remove" => {
            match id_bytes(params.string("sessionId"), 256) {
                Some(session) => {
                    let name = match method {
                        "agent.avatar" => "agentAvatar",
                        "agent.avatar.set" => "setAgentAvatar",
                        _ => "removeAgentAvatar",
                    };
                    case_with(name, [("_0", json!(session))])
                }
                None => unsupported(method),
            }
        }
        "agent.mini" => case("miniSubject"),
        "agent.mini.show" => match params.string("sessionId") {
            Some(session) if !session.is_empty() && bytes_within(session, 256) => {
                case_with("showInMini", [("_0", json!(session))])
            }
            Some(_) => unsupported(method),
            None => case_with("showInMini", [("_0", Value::Null)]),
        },
        "chief.face" => match params.string("chief").filter(|chief| is_chief_id(chief)) {
            Some(chief) => case_with("chiefFace", [("_0", json!(chief))]),
            None => unsupported(method),
        },
        "harness.symbol" => match params.string("name").filter(|name| is_symbol_name(name)) {
            Some(name) => case_with("harnessSymbol", [("_0", json!(name))]),
            None => unsupported(method),
        },
        "folder.complete" => match params.string("path").filter(|path| is_well_formed_folder(path))
        {
            Some(path) => case_with("completeFolder", [("_0", json!(path))]),
            None => unsupported(method),
        },
        "project.icon" => match params.string("cwd").filter(|cwd| is_absolute_path(cwd)) {
            Some(cwd) => case_with("projectIcon", [("_0", json!(cwd))]),
            None => unsupported(method),
        },
        "chats.open" | "chats.openInTerminal" | "chats.watch" => {
            match params.string("key").filter(|key| key.contains(':') && count_within(key, 512)) {
                Some(key) => {
                    let name = match method {
                        "chats.open" => "openChat",
                        "chats.openInTerminal" => "openChatInTerminal",
                        _ => "watchChat",
                    };
                    case_with(name, [("_0", json!(key))])
                }
                None => unsupported(method),
            }
        }
        "chats.resume" => {
            match params.string("ref").filter(|text| has_text(text) && bytes_within(text, 4096)) {
                Some(reference) => case_with("resumeChat", [("_0", json!(reference))]),
                None => unsupported(method),
            }
        }
        "app.action" => match id_chars(params.string("id"), 128) {
            Some(id) => case_with("appAction", [("_0", json!(id))]),
            None => unsupported(method),
        },
        "pane.action" => return pane_action(method, params, home),
        "pane.moveToMachine" => {
            match (id_chars(params.string("machine"), 256), id_chars(params.string("session"), 256))
            {
                (Some(machine), Some(session)) => case_with(
                    "moveToMachine",
                    [("_0", json!(machine)), ("session", json!(session))],
                ),
                _ => unsupported(method),
            }
        }
        "pane.tabState" => case_with(
            "tabState",
            [
                ("refresh", json!(params.is_true("refresh"))),
                ("terminalSwitch", json!(params.is_true("terminalSwitch"))),
            ],
        ),
        "pane.tabRowTools" => match params
            .double("width")
            .filter(|width| width.is_finite() && (0.0..=2000.0).contains(width))
        {
            Some(width) => case_with("tabRowTools", [("width", json!(width))]),
            None => unsupported(method),
        },
        "pane.toast" => match params.string("message").filter(|message| !message.is_empty()) {
            Some(message) => case_with(
                "toast",
                [
                    ("message", json!(message)),
                    ("isError", json!(params.string("tone") == Some("error"))),
                    ("group", json!(params.string("group"))),
                ],
            ),
            None => unsupported(method),
        },
        "pane.copyText" => one_text(method, "copyText", params.string("text")),
        "pane.tabRowTools.openMenu" => open_menu(method, params),
        "chat.btw.inline" => match (
            params
                .string("question")
                .filter(|text| has_text(text) && bytes_within(text, 32 * 1024)),
            id_bytes(params.string("sessionId"), 256),
        ) {
            (Some(question), Some(session)) => case_with(
                "btwInline",
                [("question", json!(question)), ("sessionId", json!(session))],
            ),
            _ => unsupported(method),
        },
        "chat.sideChat" => match id_chars(params.string("sessionId"), 256) {
            Some(id) => case_with(
                "sideChat",
                [("_0", json!(id)), ("splitRight", json!(params.string("split") == Some("right")))],
            ),
            None => unsupported(method),
        },
        "chat.processTerminal" => match params.string("toolCallId").filter(|id| is_token(id)) {
            Some(id) => case_with("processTerminal", [("toolCall", json!(id))]),
            None => unsupported(method),
        },
        "chat.newHere" => match params.string("cwd").and_then(|cwd| header_folder(cwd, home)) {
            Some(cwd) => case_with("newChatHere", [("_0", json!(cwd))]),
            None => unsupported(method),
        },
        "chat.openTab" => match id_chars(params.string("sessionId"), 256) {
            Some(id) => case_with(
                "chatTab",
                [("_0", json!(id)), ("placement", json!(params.string("placement")))],
            ),
            None => unsupported(method),
        },
        "chat.attention.open" => match id_bytes(params.string("tabId"), MAXIMUM_ATTENTION_TAB_ID) {
            Some(id) => case_with("attentionOpen", [("_0", json!(id))]),
            None => unsupported(method),
        },
        "chat.offer.open" => match id_chars(params.string("sessionId"), 256) {
            Some(id) => case_with(
                "offerOpen",
                [("_0", json!(id)), ("sender", json!(params.is_true("sender")))],
            ),
            None => unsupported(method),
        },
        "shortcut.edit" => match params
            .string("kind")
            .filter(|kind| ["terminal", "browser", "agent"].contains(kind))
        {
            Some(kind) => case_with("editShortcut", [("_0", json!(kind))]),
            None => unsupported(method),
        },
        "action.run" => run_action(method, params),
        "file.open" => match (
            params.string("path").filter(|path| !path.is_empty()),
            params.string("where").filter(|target| ["tab", "editor", "finder"].contains(target)),
        ) {
            (Some(path), Some(target)) => {
                case_with("openFile", [("path", json!(path)), ("target", json!(target))])
            }
            _ => unsupported(method),
        },
        "browser.open" => match params
            .string("url")
            .filter(|text| count_within(text, MAXIMUM_OPEN_TAB_TEXT) && is_preview_url(text))
        {
            Some(url) => case_with("openPreview", [("_0", json!(url))]),
            None => unsupported(method),
        },
        "cloud.preview.open" => open_cloud_preview(method, params),
        "editors.list" => case("editorsList"),
        "quick.dismiss" => case("quickDismiss"),
        "quick.openInWindow" => {
            let id = params.string("sessionId").filter(|id| !id.is_empty());
            case_with("quickOpenInWindow", [("sessionId", json!(id))])
        }
        "quick.setOnTop" => one_flag(method, "quickSetOnTop", params.boolean("onTop")),
        "quick.setCollapsed" => one_flag(method, "quickSetCollapsed", params.boolean("collapsed")),
        "quick.floatingState" => case("quickFloatingState"),
        "quick.context" => case("quickContext"),
        "composer.capture" => {
            case_with("composerCapture", [("mode", json!(params.string("mode")))])
        }
        "git.githubRepository" => {
            match params.string("cwd").filter(|cwd| cwd.starts_with('/') && !cwd.contains('\0')) {
                Some(cwd) => case_with("githubRepository", [("cwd", json!(cwd))]),
                None => case_with("invalidGit", [("_0", json!(method))]),
            }
        }
        "transport.open" => case("transportOpen"),
        "transport.gesture.release" => case("transportGestureRelease"),
        "transport.send" => match (params.int("connection"), params.strings("frames")) {
            (Some(connection), Some(frames))
                if !frames.is_empty() && frames.len() <= MAXIMUM_SEND_FRAMES =>
            {
                case_with(
                    "transportSend",
                    [("connection", json!(connection)), ("frames", json!(frames))],
                )
            }
            _ => unsupported(method),
        },
        "transport.close" => match params.int("connection") {
            Some(connection) => case_with("transportClose", [("connection", json!(connection))]),
            None => unsupported(method),
        },
        "externalAccess.openSettings" => {
            match params.string("kind").filter(|kind| {
                ["files_and_folders", "full_disk_access"].contains(kind) && params.only_key("kind")
            }) {
                Some(kind) => case_with("externalAccessOpenSettings", [("_0", json!(kind))]),
                None => unsupported(method),
            }
        }
        "dictation.toggle" | "dictation.start" | "dictation.stop" | "dictation.cancel" => {
            let command = method.strip_prefix("dictation.").unwrap_or_default();
            case_with("dictation", [("command", json!(command))])
        }
        "dictation.handoff" => case("dictationHandoff"),
        "dictation.sources" => case("dictationSources"),
        "dictation.audio" => match params.boolean("enabled") {
            Some(enabled) => case_with(
                "dictation",
                [("command", json!("recordAudio")), ("enabled", json!(enabled))],
            ),
            None => unsupported(method),
        },
        "dictation.recording.upload" | "dictation.recording.cancel" => {
            match params.string("path").filter(|path| is_absolute_path(path)) {
                Some(path) => {
                    let name = if method == "dictation.recording.upload" {
                        "dictationRecordingUpload"
                    } else {
                        "dictationRecordingCancel"
                    };
                    case_with(name, [("path", json!(path))])
                }
                None => unsupported(method),
            }
        }
        "dictation.openSettings" => match params
            .string("permission")
            .filter(|raw| ["microphone", "speechRecognition"].contains(raw))
        {
            Some(permission) => case_with(
                "dictation",
                [("command", json!("openSettings")), ("permission", json!(permission))],
            ),
            None => unsupported(method),
        },
        _ => return None,
    };
    Some(Decoded::Case(out))
}

/// A one-text-argument case.
fn one_text(method: &str, name: &str, text: Option<&str>) -> Value {
    match text {
        Some(text) => case_with(name, [("_0", json!(text))]),
        None => unsupported(method),
    }
}

/// A one-flag-argument case.
fn one_flag(method: &str, name: &str, flag: Option<bool>) -> Value {
    match flag {
        Some(flag) => case_with(name, [("_0", json!(flag))]),
        None => unsupported(method),
    }
}

/// `pane.framePacing {intervals}`: the first ``MAXIMUM_PACING_FRAMES`` numbers.
fn frame_pacing(method: &str, params: Params<'_>) -> Value {
    let list = params.get("intervals").and_then(Value::as_array);
    let intervals: Option<Vec<f64>> = list.and_then(|list| list.iter().map(as_double).collect());
    match intervals {
        Some(intervals) if !intervals.is_empty() => {
            let kept: Vec<f64> = intervals.into_iter().take(MAXIMUM_PACING_FRAMES).collect();
            case_with("framePacing", [("_0", json!(kept))])
        }
        _ => unsupported(method),
    }
}

/// `pane.launchSettle {settledEpochMs, maxMovePx, shifts, element?}`.
fn launch_settle(method: &str, params: Params<'_>) -> Value {
    let finite = |key: &str| params.double(key).filter(|value| value.is_finite());
    let settled = finite("settledEpochMs");
    let moved = finite("maxMovePx").filter(|value| *value >= 0.0);
    let shifts = finite("shifts").filter(|value| *value >= 0.0);
    match (settled, moved, shifts) {
        (Some(settled), Some(moved), Some(shifts)) => {
            let kept = shifts.min(1_000_000.0).trunc();
            case_with(
                "launchSettle",
                [
                    ("settledAtSeconds", json!(settled / 1_000.0)),
                    ("maxMovePx", json!(moved)),
                    ("element", json!(params.string("element").unwrap_or("other"))),
                    ("shifts", json!(format!("{kept:.0}").parse::<i64>().unwrap_or(0))),
                ],
            )
        }
        _ => unsupported(method),
    }
}

/// `tab.open {kind, text?, cwd?, search?, run?, keep?, profile?, inPlace?, beside?}`.
fn open_tab(method: &str, params: Params<'_>) -> Value {
    let Some(kind) = params.string("kind").filter(|kind| *kind == "terminal" || *kind == "browser")
    else {
        return unsupported(method);
    };
    let terminal = kind == "terminal";
    let browser = kind == "browser";
    let text = prefix(params.string("text").unwrap_or(""), MAXIMUM_OPEN_TAB_TEXT);
    let cwd = params
        .string("cwd")
        .filter(|cwd| !cwd.is_empty())
        .map(|cwd| prefix(cwd, MAXIMUM_OPEN_TAB_TEXT))
        .filter(|_| terminal);
    let profile = if browser { open_tab_profile(params) } else { Value::Null };
    case_with(
        "openTab",
        [
            ("kind", json!(kind)),
            ("text", json!(text)),
            ("cwd", json!(cwd)),
            ("search", json!(browser && params.is_true("search"))),
            ("run", json!(!terminal || params.boolean("run") != Some(false))),
            ("keep", json!(params.is_true("keep"))),
            ("profile", profile),
            ("inPlace", json!(params.is_true("inPlace"))),
            ("beside", json!(browser && params.is_true("beside"))),
        ],
    )
}

/// The browser profile `tab.open` names: `{"new": name|null}`, `{"existing": id}`, or null.
fn open_tab_profile(params: Params<'_>) -> Value {
    if params.is_true("newProfile") {
        let name = params
            .string("profileName")
            .map(|name| name.trim_matches(char::is_whitespace))
            .filter(|name| !name.is_empty())
            .map(|name| prefix(name, 128));
        return json!({ "new": name });
    }
    match id_chars(params.string("profile"), 128) {
        Some(id) => json!({ "existing": id }),
        None => Value::Null,
    }
}

/// `harness.update {id}` or `{ids}` (1 to 32 distinct ids, for Update all).
fn harness_update(method: &str, params: Params<'_>) -> Value {
    if let Some(id) = params.string("id").filter(|id| is_harness_id(id)) {
        return case_with("harnessUpdate", [("ids", json!([id])), ("each", json!(false))]);
    }
    let Some(list) =
        params.get("ids").and_then(Value::as_array).filter(|list| (1..=32).contains(&list.len()))
    else {
        return unsupported(method);
    };
    let ids: Vec<&str> =
        list.iter().filter_map(Value::as_str).filter(|id| is_harness_id(id)).collect();
    let mut distinct = ids.clone();
    distinct.sort_unstable();
    distinct.dedup();
    if ids.len() == list.len() && distinct.len() == ids.len() {
        case_with("harnessUpdate", [("ids", json!(ids)), ("each", json!(true))])
    } else {
        unsupported(method)
    }
}

/// A shell run's id: 1 to 64 bytes.
fn shell_id<'a>(params: Params<'a>) -> Option<&'a str> {
    id_bytes(params.string("id"), 64)
}

/// A `cwd` that is absolute and at most 4096 bytes; a relative one would resolve against the app's.
fn absolute_cwd<'a>(params: Params<'a>) -> Option<&'a str> {
    params.string("cwd").filter(|cwd| cwd.starts_with('/') && cwd.len() <= 4096)
}

/// `shell.run {command, cwd?}`.
fn shell_run(method: &str, params: Params<'_>) -> Value {
    match params
        .string("command")
        .filter(|command| !is_blank(command) && bytes_within(command, MAXIMUM_OPEN_TAB_TEXT))
    {
        Some(command) => case_with(
            "shellRun",
            [("command", json!(command)), ("cwd", json!(absolute_cwd(params)))],
        ),
        None => unsupported(method),
    }
}

/// `newTab.remember {agent, model?, folder?}`, `{started}` or `{harnessHint: "dismissed"}`.
fn remember_new_tab(method: &str, params: Params<'_>) -> Value {
    if let Some(agent) = id_chars(params.string("agent"), 128) {
        let model = id_chars(params.string("model"), 256);
        let folder = id_chars(params.string("folder"), 4096);
        return case_with(
            "rememberNewTab",
            [
                ("agent", json!(agent)),
                ("model", json!(model)),
                ("folder", json!(folder)),
                ("started", Value::Null),
                ("dismissesHarnessHint", json!(false)),
            ],
        );
    }
    if let Some(started) = params
        .string("started")
        .filter(|started| started.starts_with('/') && count_within(started, 4096))
    {
        return case_with(
            "rememberNewTab",
            [
                ("agent", json!("")),
                ("model", Value::Null),
                ("folder", Value::Null),
                ("started", json!(started)),
                ("dismissesHarnessHint", json!(false)),
            ],
        );
    }
    if params.string("harnessHint") == Some("dismissed") {
        return case_with(
            "rememberNewTab",
            [
                ("agent", json!("")),
                ("model", Value::Null),
                ("folder", Value::Null),
                ("started", Value::Null),
                ("dismissesHarnessHint", json!(true)),
            ],
        );
    }
    unsupported(method)
}

/// `sandbox.run {task, agent?, key}`.
fn sandbox_run(method: &str, params: Params<'_>) -> Value {
    let agent = params.string("agent");
    let task = params
        .string("task")
        .filter(|task| !is_blank(task) && count_within(task, MAXIMUM_SANDBOX_TASK));
    let agent_ok = agent.is_none_or(|agent| !agent.is_empty() && count_within(agent, 32));
    let key = params.string("key").filter(|key| is_uuid(key));
    match (task, key) {
        (Some(task), Some(key)) if agent_ok => case_with(
            "sandboxRun",
            [("task", json!(task)), ("agent", json!(agent)), ("key", json!(key))],
        ),
        _ => unsupported(method),
    }
}

/// The chat folder a header action names: absolute, or written from the home folder (`~/code`).
fn header_folder(text: &str, home: &str) -> Option<String> {
    if text.contains('\0') {
        return None;
    }
    let path = match text.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => format!("{home}{rest}"),
        _ => text.to_owned(),
    };
    path.starts_with('/').then(|| prefix(&path, MAXIMUM_OPEN_TAB_TEXT))
}

/// `pane.action {id, cwd?, mode?, url?}`; the diff viewer's turn and patch are the host's (`paneDiff`).
fn pane_action(method: &str, params: Params<'_>, home: &str) -> Option<Decoded> {
    let toggle = params.string("mode") == Some("toggle");
    if params.string("id") == Some("preview") {
        let out = match params.get("url") {
            None => case_with("preview", [("url", Value::Null), ("toggle", json!(toggle))]),
            Some(raw) => match raw
                .as_str()
                .filter(|text| count_within(text, MAXIMUM_OPEN_TAB_TEXT) && is_preview_url(text))
            {
                Some(text) => {
                    case_with("preview", [("url", json!(text)), ("toggle", json!(toggle))])
                }
                None => unsupported(method),
            },
        };
        return Some(Decoded::Case(out));
    }
    let Some(id) = id_chars(params.string("id"), 128) else {
        return Some(Decoded::Case(unsupported(method)));
    };
    let cwd = params.string("cwd").and_then(|cwd| header_folder(cwd, home));
    if id == "openDiffViewer" {
        // The diff's turn or patch is a host type: the host builds it from the body.
        return Some(Decoded::Case(case_with(
            "paneDiff",
            [("cwd", json!(cwd)), ("toggle", json!(toggle))],
        )));
    }
    Some(Decoded::Case(case_with(
        "paneAction",
        [("_0", json!(id)), ("cwd", json!(cwd)), ("toggle", json!(toggle))],
    )))
}

/// `pane.tabRowTools.openMenu {id: "chat-menu", menuItemId?}`.
fn open_menu(method: &str, params: Params<'_>) -> Value {
    if params.string("id") != Some("chat-menu") {
        return unsupported(method);
    }
    match params.get("menuItemId") {
        None | Some(Value::Null) => case_with(
            "tabRowToolsOpenMenu",
            [("id", json!("chat-menu")), ("menuItemID", Value::Null)],
        ),
        Some(raw) => match raw
            .as_str()
            .filter(|item| !item.is_empty() && bytes_within(item, 256) && count_within(item, 64))
        {
            Some(item) => case_with(
                "tabRowToolsOpenMenu",
                [("id", json!("chat-menu")), ("menuItemID", json!(item))],
            ),
            None => unsupported(method),
        },
    }
}

/// `action.run {id, session?, environment?, handoff?, app?}`: an optional field that is there must
/// be usable, never dropped.
fn run_action(method: &str, params: Params<'_>) -> Value {
    let Some(id) = id_chars(params.string("id"), 128) else { return unsupported(method) };
    let optional = |key: &str, usable: &dyn Fn(&str) -> bool| -> Option<Option<String>> {
        match params.present_string(key) {
            Present::Absent => Some(None),
            Present::Is(Some(text)) if usable(text) => Some(Some(text.to_owned())),
            Present::Is(_) => None,
        }
    };
    let session = optional("session", &|text| !text.is_empty() && count_within(text, 256));
    let environment =
        optional("environment", &|text| id == "newCloudMachine" && is_cloud_environment_id(text));
    let handoff =
        optional("handoff", &|text| id == "palette.newCloudChat" && is_handoff_token(text));
    let app = optional("app", &|text| EDITOR_ACTIONS.contains(&id) && is_editor_id(text));
    match (session, environment, handoff, app) {
        (Some(session), Some(environment), Some(handoff), Some(app)) => case_with(
            "runAction",
            [
                ("_0", json!(id)),
                ("session", json!(session)),
                ("environment", json!(environment)),
                ("handoff", json!(handoff)),
                ("app", json!(app)),
            ],
        ),
        _ => unsupported(method),
    }
}

/// `cloud.preview.open {port}`: the one key, a whole number from 1 to 65535 (not a boolean).
fn open_cloud_preview(method: &str, params: Params<'_>) -> Value {
    let port = params
        .get("port")
        .filter(|_| params.only_key("port"))
        .and_then(super::value::plain_number)
        .and_then(|number| {
            number.as_i64().or_else(|| {
                number
                    .as_f64()
                    .filter(|float| float.fract() == 0.0)
                    .and_then(|float| format!("{float:.0}").parse().ok())
            })
        })
        .filter(|port| (1..=65535).contains(port));
    match port {
        Some(port) => case_with("openCloudPreview", [("port", json!(port))]),
        None => unsupported(method),
    }
}
