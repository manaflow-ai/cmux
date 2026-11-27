//! The pane's own host ops: the page's lifecycle, paint and pacing reports,
//! the composer's switches, the shell box and the New Tab page's small
//! messages. Each takes a few scalars; the checks are the Swift decoder's
//! (`AgentPaneRequest+Decoding.swift`), pinned in `host_op_pane_tests.rs`.

use serde::Serialize;
use serde_json::{Map, Value};
use unicode_segmentation::UnicodeSegmentation;

/// The longest text a tab, a type-ahead or a shell command carries (`AgentPaneRequest.maximumOpenTabText`).
pub const MAXIMUM_OPEN_TAB_TEXT: usize = 8192;
/// The most frame intervals one pacing report keeps (`AgentPaneRequest.maximumPacingFrames`).
pub const MAXIMUM_PACING_FRAMES: usize = 640;
/// The longest line the shell box completes (`AgentPaneShellCompletion.maximumLine`).
pub const MAXIMUM_SHELL_LINE: usize = 4096;
/// The largest New Tab warm snapshot, in bytes (`AgentPaneNewTab.maximumWarmBytes`).
pub const MAXIMUM_WARM_BYTES: usize = 512 * 1024;

/// The methods this file decodes.
pub const PANE_METHODS: [&str; 35] = [
    "ready",
    "chat.missing",
    "chat.persistSession",
    "chat.cloudStartQueue",
    "chat.unsentDraft",
    "chat.leftover",
    "chat.leftoverTaken",
    "pane.checkpointAvailability",
    "pane.commandAvailability",
    "pane.framePacing",
    "pane.finishSound",
    "pane.showContextUsage",
    "pane.showDictation",
    "pane.setScrollToBottomOnSend",
    "pane.setRemoteControl",
    "pane.noticeAction",
    "pane.clientReady",
    "pane.painted",
    "pane.inputEchoed",
    "pane.launchSettle",
    "pane.renderRate",
    "tab.typeAhead",
    "harness.update",
    "acpmux.restart",
    "harness.restart",
    "shell.run",
    "shell.read",
    "shell.complete",
    "shell.stop",
    "newTab.inputReady",
    "newTab.touched",
    "newTab.context",
    "newTab.cloudPick",
    "newTab.warm",
    "newTab.setTemplate",
];

/// What the finish sound marks.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum FinishSound {
    Turn,
    Ci,
    Merged,
}

/// The composer's switches the page writes with one Bool.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ComposerSwitch {
    ShowContextUsage,
    ShowDictation,
    ScrollToBottomOnSend,
}

/// One pane message, checked.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum PaneOp {
    Ready,
    Reconnect,
    MissingChat {
        session: String,
        reason: String,
    },
    PersistSession {
        id: String,
    },
    CloudStartQueue {
        text: String,
    },
    UnsentDraft {
        text: String,
    },
    NewChatLeftover {
        text: String,
    },
    NewChatLeftoverTaken {
        text: String,
    },
    CheckpointAvailability {
        available: bool,
    },
    CommandAvailability {
        commands: Vec<String>,
    },
    FramePacing {
        intervals: Vec<f64>,
    },
    FinishSound {
        kind: FinishSound,
    },
    ComposerSetting {
        setting: ComposerSwitch,
        show: bool,
    },
    RemoteControl {
        on: bool,
    },
    PaneNoticeAction {
        id: String,
    },
    ClientReady {
        ready: bool,
    },
    #[serde(rename_all = "camelCase")]
    Painted {
        from_kept_tail: bool,
        settled: bool,
        copy: bool,
        live: bool,
    },
    #[serde(rename_all = "camelCase")]
    InputEchoed {
        epoch_ms: f64,
    },
    #[serde(rename_all = "camelCase")]
    LaunchSettle {
        settled_epoch_ms: f64,
        max_move_px: f64,
        element: String,
        shifts: i64,
    },
    RenderRate {
        full: bool,
    },
    TypeAhead {
        text: String,
    },
    HarnessUpdate {
        ids: Vec<String>,
        each: bool,
    },
    RestartAcpmux,
    HarnessRestart,
    ShellRun {
        command: String,
        cwd: Option<String>,
    },
    ShellRead {
        id: String,
        after: i64,
    },
    ShellComplete {
        line: String,
        cwd: Option<String>,
    },
    ShellStop {
        id: String,
    },
    NewTabInputReady {
        token: String,
    },
    Touched,
    NewTabContext,
    NewTabCloudPick,
    NewTabWarm {
        warm: String,
    },
    NewTabTemplate {
        template: String,
    },
}

/// Decodes one pane method; `None` refuses it (or names no pane method).
pub fn decode(method: &str, params: Option<&Map<String, Value>>) -> Option<PaneOp> {
    let get = |key: &str| params.and_then(|object| object.get(key));
    let string = |key: &str| get(key).and_then(Value::as_str);
    let flag = |key: &str| get(key).and_then(Value::as_bool);
    let text = |key: &str| string(key).map(str::to_owned);
    let only =
        |key: &str| params.is_some_and(|object| object.len() == 1 && object.contains_key(key));
    Some(match method {
        "ready" => {
            if flag("reconnect") == Some(true) {
                PaneOp::Reconnect
            } else {
                PaneOp::Ready
            }
        }
        "chat.missing" => PaneOp::MissingChat {
            session: string("session").filter(|session| !session.is_empty())?.to_owned(),
            reason: string("reason").unwrap_or("unknown").to_owned(),
        },
        "chat.persistSession" => PaneOp::PersistSession {
            id: string("sessionId").filter(|id| !id.is_empty())?.to_owned(),
        },
        "chat.cloudStartQueue" => PaneOp::CloudStartQueue { text: text("text")? },
        "chat.unsentDraft" => PaneOp::UnsentDraft { text: text("text")? },
        "chat.leftover" => PaneOp::NewChatLeftover { text: text("text")? },
        "chat.leftoverTaken" => PaneOp::NewChatLeftoverTaken { text: text("text")? },
        "pane.checkpointAvailability" => {
            PaneOp::CheckpointAvailability { available: flag("available")? }
        }
        "pane.commandAvailability" => PaneOp::CommandAvailability {
            commands: get("commands")?
                .as_array()?
                .iter()
                .map(|command| command.as_str().map(str::to_owned))
                .collect::<Option<_>>()?,
        },
        "pane.framePacing" => {
            let intervals: Vec<f64> =
                get("intervals")?.as_array()?.iter().map(Value::as_f64).collect::<Option<_>>()?;
            if intervals.is_empty() {
                return None;
            }
            PaneOp::FramePacing {
                intervals: intervals.into_iter().take(MAXIMUM_PACING_FRAMES).collect(),
            }
        }
        "pane.finishSound" => PaneOp::FinishSound {
            kind: match string("kind")? {
                "turn" => FinishSound::Turn,
                "ci" => FinishSound::Ci,
                "merged" => FinishSound::Merged,
                _ => return None,
            },
        },
        "pane.showContextUsage" | "pane.showDictation" | "pane.setScrollToBottomOnSend" => {
            PaneOp::ComposerSetting {
                setting: match method {
                    "pane.showDictation" => ComposerSwitch::ShowDictation,
                    "pane.setScrollToBottomOnSend" => ComposerSwitch::ScrollToBottomOnSend,
                    _ => ComposerSwitch::ShowContextUsage,
                },
                show: flag("show")?,
            }
        }
        "pane.setRemoteControl" => {
            let on = flag("on")?;
            if !only("on") {
                return None;
            }
            PaneOp::RemoteControl { on }
        }
        "pane.noticeAction" => {
            let id = text("id")?;
            if !only("id") {
                return None;
            }
            PaneOp::PaneNoticeAction { id }
        }
        "pane.clientReady" => PaneOp::ClientReady { ready: flag("ready")? },
        "pane.painted" => PaneOp::Painted {
            from_kept_tail: flag("drewKeptTail").unwrap_or(false),
            settled: flag("settled").unwrap_or(false),
            copy: flag("copy").unwrap_or(false),
            live: flag("live").unwrap_or(false),
        },
        "pane.inputEchoed" => PaneOp::InputEchoed {
            epoch_ms: get("echoedEpochMs")?.as_f64().filter(|ms| ms.is_finite())?,
        },
        "pane.launchSettle" => {
            let settled_epoch_ms = get("settledEpochMs")?.as_f64().filter(|ms| ms.is_finite())?;
            let max_move_px =
                get("maxMovePx")?.as_f64().filter(|px| px.is_finite() && *px >= 0.0)?;
            let shifts =
                get("shifts")?.as_f64().filter(|shifts| shifts.is_finite() && *shifts >= 0.0)?;
            PaneOp::LaunchSettle {
                settled_epoch_ms,
                max_move_px,
                element: string("element").unwrap_or("other").to_owned(),
                shifts: shifts.min(1_000_000.0) as i64,
            }
        }
        "pane.renderRate" => PaneOp::RenderRate { full: flag("full")? },
        "tab.typeAhead" => {
            PaneOp::TypeAhead { text: prefix(string("text")?, MAXIMUM_OPEN_TAB_TEXT) }
        }
        "harness.update" => {
            if let Some(id) = get("id").and_then(harness_id) {
                PaneOp::HarnessUpdate { ids: vec![id], each: false }
            } else {
                let list = get("ids")?.as_array().filter(|list| (1..=32).contains(&list.len()))?;
                let ids: Vec<String> = list.iter().filter_map(harness_id).collect();
                let mut unique = ids.clone();
                unique.sort_unstable();
                unique.dedup();
                if ids.len() != list.len() || unique.len() != ids.len() {
                    return None;
                }
                PaneOp::HarnessUpdate { ids, each: true }
            }
        }
        "acpmux.restart" => PaneOp::RestartAcpmux,
        "harness.restart" => PaneOp::HarnessRestart,
        "shell.run" => {
            let command = string("command").filter(|command| {
                !command.trim().is_empty() && command.len() <= MAXIMUM_OPEN_TAB_TEXT
            })?;
            PaneOp::ShellRun { command: command.to_owned(), cwd: absolute_folder(get("cwd")) }
        }
        "shell.read" => {
            let id = shell_id(get("id"))?;
            let after =
                get("after")?.as_f64().map(f64::trunc).filter(|after| *after >= 0.0)? as i64;
            PaneOp::ShellRead { id, after }
        }
        "shell.complete" => {
            let line = string("line").filter(|line| line.len() <= MAXIMUM_SHELL_LINE)?;
            PaneOp::ShellComplete { line: line.to_owned(), cwd: absolute_folder(get("cwd")) }
        }
        "shell.stop" => PaneOp::ShellStop { id: shell_id(get("id"))? },
        "newTab.inputReady" => PaneOp::NewTabInputReady {
            token: string("token")
                .filter(|token| !token.is_empty() && characters(token) <= 128)?
                .to_owned(),
        },
        "newTab.touched" => PaneOp::Touched,
        "newTab.context" => PaneOp::NewTabContext,
        "newTab.cloudPick" => PaneOp::NewTabCloudPick,
        "newTab.warm" => PaneOp::NewTabWarm {
            warm: string("warm")
                .filter(|warm| !warm.is_empty() && warm.len() <= MAXIMUM_WARM_BYTES)?
                .to_owned(),
        },
        "newTab.setTemplate" => PaneOp::NewTabTemplate {
            template: string("template")
                .filter(|template| !template.is_empty() && characters(template) <= 32)?
                .to_owned(),
        },
        _ => return None,
    })
}

/// A harness id (a profile file name), never a command: 1 to 128 ASCII
/// letters, digits, `-`, `_` or `.`.
fn harness_id(value: &Value) -> Option<String> {
    let id = value.as_str()?;
    let ok = !id.is_empty()
        && id.len() <= 128
        && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte));
    ok.then(|| id.to_owned())
}

/// A shell box's id: 1 to 64 bytes.
fn shell_id(value: Option<&Value>) -> Option<String> {
    value?.as_str().filter(|id| !id.is_empty() && id.len() <= 64).map(str::to_owned)
}

/// A folder the shell runs in: an absolute path of at most 4096 bytes (a
/// relative one would resolve against the app's folder), else none.
fn absolute_folder(value: Option<&Value>) -> Option<String> {
    value?.as_str().filter(|cwd| cwd.starts_with('/') && cwd.len() <= 4096).map(str::to_owned)
}

/// Swift's `String.count`: extended grapheme clusters.
pub(crate) fn characters(text: &str) -> usize {
    text.graphemes(true).count()
}

/// Swift's `String.prefix(n)`: the first `n` grapheme clusters.
pub(crate) fn prefix(text: &str, count: usize) -> String {
    text.graphemes(true).take(count).collect()
}

#[cfg(test)]
#[path = "host_op_pane_tests.rs"]
mod tests;
