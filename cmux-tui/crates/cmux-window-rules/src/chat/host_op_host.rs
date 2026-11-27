//! The host's own small asks: pickers and menus the native host shows, the
//! quick chat window, dictation's switches, the tab row's tools, toasts and
//! the chat links that open a tab. Each takes a few scalars; the checks are
//! the Swift decoder's (`AgentPaneRequest+Decoding.swift`), pinned in
//! `host_op_host_tests.rs`.

use serde::Serialize;
use serde_json::{Map, Value};

use super::pane::characters;
use super::repository_session;

/// The methods this file decodes.
pub const HOST_METHODS: [&str; 42] = [
    "project.browse",
    "sandbox.state",
    "cloud.handoffTurn",
    "cloud.signInCancel",
    "cloud.signIn",
    "cloud.setupState",
    "workspace.chooseFolder",
    "chat.folder.choose",
    "machine.share.self",
    "chat.attach.choose",
    "chat.attach.external",
    "editors.list",
    "quick.dismiss",
    "quick.openInWindow",
    "quick.setOnTop",
    "quick.setCollapsed",
    "quick.floatingState",
    "quick.context",
    "composer.capture",
    "transport.open",
    "transport.gesture.release",
    "dictation.toggle",
    "dictation.handoff",
    "dictation.sources",
    "dictation.start",
    "dictation.stop",
    "dictation.cancel",
    "dictation.audio",
    "dictation.recording.upload",
    "dictation.recording.cancel",
    "pane.tabState",
    "pane.tabRowTools",
    "pane.toast",
    "pane.copyText",
    "customizations.menu",
    "pane.tabRowTools.openMenu",
    "chat.btw.inline",
    "chat.sideChat",
    "chat.openTab",
    "chat.attention.open",
    "chat.offer.open",
    "tab.jump",
];

/// The longest `chat.btw.inline` question, in bytes.
pub const MAXIMUM_BTW_QUESTION: usize = 32 * 1024;
/// The longest attention tab id, in bytes (`AgentPaneAttentionTabs.maximumTabID`).
pub const MAXIMUM_ATTENTION_TAB_ID: usize = 256;

/// One host ask, checked.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum HostCall {
    BrowseProject,
    SandboxState {
        wait: bool,
    },
    #[serde(rename_all = "camelCase")]
    CloudHandoffTurn {
        session_id: String,
    },
    CloudSignInCancel {
        expired: bool,
    },
    CloudSignIn {
        key: String,
    },
    CloudSetupState,
    ChooseFolder,
    ChooseChatFolder,
    ShareMachineWithMe,
    ChooseAttachments,
    AttachExternal,
    EditorsList,
    QuickDismiss,
    #[serde(rename_all = "camelCase")]
    QuickOpenInWindow {
        session_id: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    QuickSetOnTop {
        on_top: bool,
    },
    QuickSetCollapsed {
        collapsed: bool,
    },
    QuickFloatingState,
    QuickContext,
    ComposerCapture {
        mode: Option<String>,
    },
    TransportOpen,
    TransportGestureRelease,
    /// `dictation.toggle|start|stop|cancel`: `command` names it.
    Dictation {
        command: &'static str,
    },
    DictationHandoff,
    DictationSources,
    DictationRecordAudio {
        enabled: bool,
    },
    DictationRecordingUpload {
        path: String,
    },
    DictationRecordingCancel {
        path: String,
    },
    #[serde(rename_all = "camelCase")]
    TabState {
        refresh: bool,
        terminal_switch: bool,
    },
    TabRowTools {
        width: f64,
        need: Option<f64>,
    },
    #[serde(rename_all = "camelCase")]
    Toast {
        message: String,
        is_error: bool,
        group: Option<String>,
    },
    CopyText {
        text: String,
    },
    CustomizationsMenu {
        x: f64,
        y: f64,
    },
    #[serde(rename_all = "camelCase")]
    TabRowToolsOpenMenu {
        id: String,
        menu_item_id: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    BtwInline {
        question: String,
        session_id: String,
    },
    #[serde(rename_all = "camelCase")]
    SideChat {
        session_id: String,
        split_right: bool,
    },
    /// `placement`: the page's word, which the host reads as a fork destination.
    #[serde(rename_all = "camelCase")]
    ChatTab {
        session_id: String,
        placement: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    AttentionOpen {
        tab_id: String,
    },
    #[serde(rename_all = "camelCase")]
    OfferOpen {
        session_id: String,
        sender: bool,
    },
    /// `target`: `tab`, `workspace`, `here` or `closed`.
    Jump {
        target: String,
        id: String,
    },
}

/// Decodes one host method; `None` refuses it (or names no host method).
pub fn decode(method: &str, params: Option<&Map<String, Value>>) -> Option<HostCall> {
    let get = |key: &str| params.and_then(|object| object.get(key));
    let string = |key: &str| get(key).and_then(Value::as_str);
    let flag = |key: &str| get(key).and_then(Value::as_bool);
    let set = |key: &str| flag(key) == Some(true);
    let chat_id = |key: &str| {
        string(key).filter(|id| !id.is_empty() && characters(id) <= 256).map(str::to_owned)
    };
    let absolute_path = |key: &str| {
        string(key).filter(|path| path.starts_with('/') && path.len() <= 4096).map(str::to_owned)
    };
    Some(match method {
        "project.browse" => HostCall::BrowseProject,
        "sandbox.state" => HostCall::SandboxState { wait: set("wait") },
        "cloud.handoffTurn" => HostCall::CloudHandoffTurn {
            session_id: get("sessionId").and_then(repository_session)?.to_owned(),
        },
        "cloud.signInCancel" => HostCall::CloudSignInCancel { expired: set("expired") },
        "cloud.signIn" => {
            HostCall::CloudSignIn { key: string("key").filter(|key| is_uuid(key))?.to_owned() }
        }
        "cloud.setupState" => HostCall::CloudSetupState,
        "workspace.chooseFolder" => HostCall::ChooseFolder,
        "chat.folder.choose" => HostCall::ChooseChatFolder,
        "machine.share.self" => HostCall::ShareMachineWithMe,
        "chat.attach.choose" => HostCall::ChooseAttachments,
        "chat.attach.external" => HostCall::AttachExternal,
        "editors.list" => HostCall::EditorsList,
        "quick.dismiss" => HostCall::QuickDismiss,
        "quick.openInWindow" => HostCall::QuickOpenInWindow {
            session_id: string("sessionId").filter(|id| !id.is_empty()).map(str::to_owned),
        },
        "quick.setOnTop" => HostCall::QuickSetOnTop { on_top: flag("onTop")? },
        "quick.setCollapsed" => HostCall::QuickSetCollapsed { collapsed: flag("collapsed")? },
        "quick.floatingState" => HostCall::QuickFloatingState,
        "quick.context" => HostCall::QuickContext,
        "composer.capture" => HostCall::ComposerCapture { mode: string("mode").map(str::to_owned) },
        "transport.open" => HostCall::TransportOpen,
        "transport.gesture.release" => HostCall::TransportGestureRelease,
        "dictation.toggle" => HostCall::Dictation { command: "toggle" },
        "dictation.start" => HostCall::Dictation { command: "start" },
        "dictation.stop" => HostCall::Dictation { command: "stop" },
        "dictation.cancel" => HostCall::Dictation { command: "cancel" },
        "dictation.handoff" => HostCall::DictationHandoff,
        "dictation.sources" => HostCall::DictationSources,
        "dictation.audio" => HostCall::DictationRecordAudio { enabled: flag("enabled")? },
        "dictation.recording.upload" => {
            HostCall::DictationRecordingUpload { path: absolute_path("path")? }
        }
        "dictation.recording.cancel" => {
            HostCall::DictationRecordingCancel { path: absolute_path("path")? }
        }
        "pane.tabState" => {
            HostCall::TabState { refresh: set("refresh"), terminal_switch: set("terminalSwitch") }
        }
        "pane.tabRowTools" => {
            let in_row = |value: Option<&Value>| {
                number(value).filter(|width| (0.0..=2000.0).contains(width))
            };
            HostCall::TabRowTools { width: in_row(get("width"))?, need: in_row(get("need")) }
        }
        "pane.toast" => HostCall::Toast {
            message: string("message").filter(|message| !message.is_empty())?.to_owned(),
            is_error: string("tone") == Some("error"),
            group: string("group").map(str::to_owned),
        },
        "pane.copyText" => HostCall::CopyText { text: string("text")?.to_owned() },
        "customizations.menu" => {
            let point = get("point")?.as_object()?;
            HostCall::CustomizationsMenu { x: number(point.get("x"))?, y: number(point.get("y"))? }
        }
        "pane.tabRowTools.openMenu" => {
            if string("id") != Some("chat-menu") {
                return None;
            }
            let menu_item_id = match get("menuItemId") {
                None | Some(Value::Null) => None,
                Some(Value::String(item))
                    if !item.is_empty() && item.len() <= 256 && characters(item) <= 64 =>
                {
                    Some(item.clone())
                }
                Some(_) => return None,
            };
            HostCall::TabRowToolsOpenMenu { id: "chat-menu".to_owned(), menu_item_id }
        }
        "chat.btw.inline" => HostCall::BtwInline {
            question: string("question")
                .filter(|question| {
                    !question.trim().is_empty() && question.len() <= MAXIMUM_BTW_QUESTION
                })?
                .to_owned(),
            session_id: string("sessionId")
                .filter(|id| !id.is_empty() && id.len() <= 256)?
                .to_owned(),
        },
        "chat.sideChat" => HostCall::SideChat {
            session_id: chat_id("sessionId")?,
            split_right: string("split") == Some("right"),
        },
        "chat.openTab" => HostCall::ChatTab {
            session_id: chat_id("sessionId")?,
            placement: string("placement").map(str::to_owned),
        },
        "chat.attention.open" => HostCall::AttentionOpen {
            tab_id: string("tabId")
                .filter(|id| !id.is_empty() && id.len() <= MAXIMUM_ATTENTION_TAB_ID)?
                .to_owned(),
        },
        "chat.offer.open" => {
            HostCall::OfferOpen { session_id: chat_id("sessionId")?, sender: set("sender") }
        }
        "tab.jump" => HostCall::Jump {
            target: string("target")
                .filter(|target| matches!(*target, "tab" | "workspace" | "here" | "closed"))?
                .to_owned(),
            id: chat_id("id")?,
        },
        _ => return None,
    })
}

/// A finite JSON number (Swift's `(x as? NSNumber)?.doubleValue`, finite).
fn number(value: Option<&Value>) -> Option<f64> {
    value?.as_f64().filter(|number| number.is_finite())
}

/// A UUID as Foundation's `UUID(uuidString:)` reads one: 8-4-4-4-12 hex digits.
pub fn is_uuid(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => *byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

#[cfg(test)]
#[path = "host_op_host_tests.rs"]
mod tests;
