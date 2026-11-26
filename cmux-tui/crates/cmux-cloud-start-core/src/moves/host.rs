//! The app's side of the chat place controls (`CloudPlaceHost` in the app): which chats the place
//! actions may move, the chats they list, what a chat carries into a move, the own-VM facts and
//! how a run that started no work reads. The app reads its tabs, turn states, drafts, ledgers and
//! machines; here is what they mean (ops `cloud_move_host_*`).

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

use super::ledger::Moved;
use super::place::{Cargo, Machine};

/// A tab record's host on a Cloud machine's acpmux (`MachineRegistry.registryHostPrefix`).
pub const REGISTRY_HOST_PREFIX: &str = "registry:";
/// A tab record's host on the Chief's acpmux (`ChiefHomeAcpmux.hostPrefix`).
pub const CHIEF_HOST_PREFIX: &str = "chief:";

/// The chat runs on a Cloud machine.
pub fn on_cloud(host: &str) -> bool {
    host.starts_with(REGISTRY_HOST_PREFIX)
}

/// Whether the place actions can move this chat: one on this Mac's own acpmux (`local`; not an
/// SSH machine's, not the Chief's), or a Cloud chat a move took there (its ledger entry is what
/// Bring Back reads). `moved` is the moved-chat ledger's entries (`MovedChats::all`).
pub fn eligible(host: &str, session: &str, local: bool, moved: &[Moved]) -> bool {
    if on_cloud(host) {
        return moved.iter().any(|m| m.host == host && m.session == session);
    }
    local && !host.starts_with(CHIEF_HOST_PREFIX)
}

/// One agent tab as the app reads it, in its window order.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Tab {
    pub id: String,
    /// The tab record's host.
    pub host: String,
    /// The chat's session: the record's, else the agent tabs' (none: no chat yet, left out).
    pub session: Option<String>,
    /// The tab's daemon is this Mac's own.
    pub local: bool,
    pub title: String,
    pub turn_running: bool,
    pub turn_started_at_ms: Option<f64>,
    /// A move of the chat runs, or Bring Back Local is taking the tab back.
    pub moving: bool,
    pub queued: u32,
}

/// A chat the place controls list (`CloudPlaceChat`).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Chat {
    pub id: String,
    pub session: String,
    pub title: String,
    pub on_cloud: bool,
    pub turn_running: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_started_at_ms: Option<f64>,
    pub moving: bool,
    pub queued: u32,
}

/// The chats the place controls offer: each eligible tab's, once per session. Eligible first,
/// then once per session: a tab that may not move never hides a later one of the same chat that may.
pub fn chats(tabs: &[Tab], moved: &[Moved]) -> Vec<Chat> {
    let mut seen = BTreeSet::new();
    tabs.iter()
        .filter_map(|tab| {
            let session = tab.session.as_deref()?;
            if !eligible(&tab.host, session, tab.local, moved) || !seen.insert(session) {
                return None;
            }
            Some(Chat {
                id: tab.id.clone(),
                session: session.to_owned(),
                title: tab.title.clone(),
                on_cloud: on_cloud(&tab.host),
                turn_running: tab.turn_running,
                turn_started_at_ms: tab.turn_started_at_ms,
                moving: tab.moving,
                queued: tab.queued,
            })
        })
        .collect()
}

/// The sessions of the chats a move took to Cloud and no Bring Back took home.
pub fn cloud_sessions(moved: &[Moved]) -> Vec<String> {
    moved.iter().filter(|m| m.brought_back.is_none()).map(|m| m.session.clone()).collect()
}

/// A Cloud machine as the app lists it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MachineStatus {
    pub id: String,
    /// The Cloud API's status (`running`, `paused`, `deleting`, `destroyed`, …).
    pub status: String,
}

/// What the own-VM pick reads for one chat.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OwnFacts {
    /// The machine it ran on before.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub before: Option<String>,
    pub machines: Vec<Machine>,
}

/// The chat's machine before (the ledger's entry while it is on Cloud or coming back; after a
/// Bring Back ended it, `last_machine`, the one it ran on) and each Cloud machine with the chats
/// it holds now and whether it is gone (deleting or destroyed).
pub fn own_facts(
    session: &str,
    ledger: &[Moved],
    last_machine: Option<&str>,
    machines: &[MachineStatus],
) -> OwnFacts {
    let before = ledger
        .iter()
        .find(|m| {
            m.session == session || m.brought_back.as_ref().is_some_and(|b| b.session == session)
        })
        .map(|m| m.machine_id.clone())
        .or_else(|| last_machine.map(str::to_owned));
    let machines = machines
        .iter()
        .map(|machine| Machine {
            id: machine.id.clone(),
            sessions: ledger
                .iter()
                .filter(|m| m.machine_id == machine.id && m.brought_back.is_none())
                .map(|m| m.session.clone())
                .collect(),
            gone: matches!(machine.status.as_str(), "deleting" | "destroyed"),
        })
        .collect();
    OwnFacts { before, machines }
}

/// What the page claimed when it started the move (`CloudPlaceClaims`): it wins over the app's read.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Claims {
    pub queued: Option<u32>,
    pub has_draft: Option<bool>,
}

/// What the app reads of a chat before a move.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CargoFacts {
    /// The agent's turn state is `working`.
    pub turn_running: bool,
    pub branch: Option<String>,
    pub has_draft: bool,
    /// acpmux's count of prompts waiting, from the chat's summary.
    pub queued: Option<i64>,
    /// The page's claims, when a person's move from the page sent them.
    pub claims: Option<Claims>,
}

/// What the chat carries into a move. Both moves run the agent move with a FrozenSync, which
/// carries a running turn to where it lands (no turn, no carry). `queued` is acpmux's count only
/// when it names prompts waiting (a 0 may be an older acpmux's silence: left out); the page's
/// claims win over the app's read.
pub fn cargo(facts: &CargoFacts) -> Cargo {
    let mut cargo = Cargo {
        turn_running: facts.turn_running,
        continues_turn: facts.turn_running,
        branch: facts.branch.clone(),
        has_draft: facts.has_draft,
        ..Cargo::default()
    };
    if let Some(queued) = facts.queued.filter(|q| *q > 0) {
        cargo.queued = u32::try_from(queued).unwrap_or(u32::MAX);
    }
    if let Some(claims) = &facts.claims {
        cargo.queued = claims.queued.unwrap_or(cargo.queued);
        cargo.has_draft = claims.has_draft.unwrap_or(cargo.has_draft);
    }
    cargo
}

/// How a place run's perform went, when it started no work.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RunFacts {
    /// The perform started work (a move runs): no refusal.
    pub started: bool,
    /// The move's own check refused before it started (no chat there, no first message, no folder).
    pub refusal: Option<String>,
    /// The registry ran the action.
    pub ran: bool,
    /// Why the action is unavailable, when it is.
    pub unavailable: Option<String>,
    /// The app's "move failed" text, the last resort.
    pub failed: String,
}

/// Swift's `.whitespaces`: spaces and tabs, not line breaks.
fn trim_spaces(text: &str) -> &str {
    text.trim_matches(|c: char| {
        c.is_whitespace()
            && !matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
    })
}

/// The run's refusal, trimmed: none when work started; else the move's own refusal, else (when
/// the registry did not run it) why the action is unavailable or that the move failed.
pub fn run_refusal(facts: &RunFacts) -> Option<String> {
    if facts.started {
        return None;
    }
    let reason = match &facts.refusal {
        Some(refusal) => refusal.as_str(),
        None if facts.ran => return None,
        None => facts.unavailable.as_deref().unwrap_or(&facts.failed),
    };
    Some(trim_spaces(reason).to_owned())
}

#[cfg(test)]
#[path = "host_tests.rs"]
mod tests;
