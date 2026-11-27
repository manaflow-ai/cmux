//! `HomeChiefTabKey` (CmuxNextHomeEngine/HomeChiefTabKey.swift): the idempotency key of one Chief
//! tab creation as a state machine. The app keeps the state (`pending`), makes fresh keys (a UUID)
//! and sends the request; each step says which key to send.

use super::tree::Workspace;
use serde::{Deserialize, Serialize};

/// The daemon's refusal of a key whose tab was closed.
pub const KEY_CLOSED_CODE: &str = "frontend_browser_key_closed";

/// The key's state: the pending creation key, if any.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct KeyState {
    pub pending: Option<String>,
}

/// One event of `ensure(chiefTabOpen:send:)` and the key's other calls.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum KeyEvent {
    /// A connect: nothing while the Chief tab is open; else the key to send (the pending one, else `fresh`).
    #[serde(rename_all = "camelCase")]
    Begin { chief_tab_open: bool, fresh: String },
    /// The send of `key` succeeded: its creation ended.
    Sent { key: String },
    /// The send of `key` failed with daemon error `code` (none: not a command error). `retried`:
    /// this was already the retry. A key-closed refusal of the first send retries once under a new key.
    #[serde(rename_all = "camelCase")]
    Failed {
        key: String,
        code: Option<String>,
        fresh: String,
        #[serde(default)]
        retried: bool,
    },
    /// The Chief tab is present (`settle()`): the next creation takes a new key.
    Settle,
    /// `settle(key)`: a newer pending key stays.
    SettleKey { key: String },
}

/// What a step does.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyStep {
    pub state: KeyState,
    /// The key to send now (none: send nothing).
    pub send: Option<String>,
    /// The ensure ends with this error (the key stays pending).
    pub fail: bool,
    /// The ensure ends having sent a create (`ensure` returns true).
    pub created: bool,
}

fn for_create(state: &mut KeyState, fresh: String) -> String {
    state.pending.get_or_insert(fresh).clone()
}

fn settle_key(state: &mut KeyState, key: &str) {
    if state.pending.as_deref() == Some(key) {
        state.pending = None;
    }
}

/// One step of the key's state machine.
pub fn step(mut state: KeyState, event: KeyEvent) -> KeyStep {
    let out = |state: KeyState, send: Option<String>, fail: bool, created: bool| KeyStep {
        state,
        send,
        fail,
        created,
    };
    match event {
        KeyEvent::Begin { chief_tab_open: true, .. } | KeyEvent::Settle => {
            state.pending = None;
            out(state, None, false, false)
        }
        KeyEvent::Begin { fresh, .. } => {
            let key = for_create(&mut state, fresh);
            out(state, Some(key), false, false)
        }
        KeyEvent::Sent { key } => {
            settle_key(&mut state, &key);
            out(state, None, false, true)
        }
        KeyEvent::Failed { key, code, fresh, retried } => {
            if !retried && code.as_deref() == Some(KEY_CLOSED_CODE) {
                settle_key(&mut state, &key);
                let key = for_create(&mut state, fresh);
                out(state, Some(key), false, false)
            } else {
                out(state, None, true, false)
            }
        }
        KeyEvent::SettleKey { key } => {
            settle_key(&mut state, &key);
            out(state, None, false, false)
        }
    }
}

/// Whether a conversation tab shows `chief` in any of `workspaces` (`HomeChiefTabKey.isOpen`): a
/// moved tab still counts, so a second Chief tab is never created.
pub fn is_open(chief: &str, workspaces: &[Workspace]) -> bool {
    workspaces
        .iter()
        .flat_map(|workspace| &workspace.screens)
        .flat_map(|screen| &screen.panes)
        .flat_map(|pane| &pane.tabs)
        .any(|tab| tab.kind == "conversation" && tab.conversation.as_deref() == Some(chief))
}
