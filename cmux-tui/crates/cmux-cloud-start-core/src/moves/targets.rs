//! Where a started chat's Move to… can take it, and which action takes it there. Pure: the app
//! reads its live machine lists, the chat's record and its Bring Back Local entry, asks here, and
//! draws the answer (the page's Move to… rows, `EnvironmentPicker.tsx`). Leo, 2026-11-10: "the
//! whole \"move to cloud\" deserves a proper \"move to other cloud\" ... and \"move to local\"
//! or \"move to remote\"".
//!
//! A machine added over SSH is an acpmux peer of this Mac: its chats move with acpmux's own
//! transfer, the one `acpmux session move` runs (`acpmux/src/cli/run/session_move.rs`), to it,
//! from it to another, and back here (`--from PEER --machine local`). [`ssh_move`] is that call.

use serde::{Deserialize, Serialize};

/// The id the app and the page name this Mac by.
pub const LOCAL: &str = "local";

/// The app's actions a target runs (the catalog's ids).
pub mod action {
    /// Move to Cloud: a chat of this Mac to a Cloud machine.
    pub const MOVE_TO_CLOUD: &str = "cloudMove";
    /// Bring Back Local: a Cloud chat a move from here put there, back here.
    pub const BRING_BACK: &str = "cloudBringBack";
    /// Move to Another Machine: that Cloud chat on to another Cloud machine.
    pub const TO_MACHINE: &str = "cloudMoveToMachine";
    /// Move to SSH Machine: a chat to a machine added over SSH, between two, or back here.
    pub const SSH_MOVE: &str = "agent.moveToMachine";
}

/// One machine the app reaches over SSH: an SSH machine of its sidebar (Add Machine), or an
/// acpmux peer of this Mac's (`cmux setup machine` adds only the peer). One machine listed both
/// ways is one target: the first entry of a name wins.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshMachine {
    /// The app's id for it.
    pub id: String,
    /// Its sidebar name.
    #[serde(default)]
    pub title: String,
    /// Its link is up now: a machine that is down takes no chat.
    #[serde(default)]
    pub online: bool,
    /// What acpmux may call it: its ssh host, short host and sidebar name ([`peer_of`]).
    #[serde(default)]
    pub names: Vec<String>,
}

/// One acpmux peer as this Mac's daemon lists it (`_acpmux/peers`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
pub struct Peer {
    pub name: String,
    /// Where the daemon reaches it (`ssh://[user@]host`).
    #[serde(default)]
    pub url: String,
}

/// One Cloud machine of the account, as the app's machine list has it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Machine {
    pub id: String,
    #[serde(default)]
    pub title: String,
    /// The machine's status word (`running`, `stopped`, `failed`, ...).
    #[serde(default)]
    pub status: String,
}

/// What the app knows about the chat and the account.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Chat {
    /// Signed in, with the machine list loaded for the account signed in now.
    #[serde(default)]
    pub offered: bool,
    /// The chat has an acpmux session (a started chat).
    #[serde(default)]
    pub started: bool,
    /// The chat is Chief's home chat, which never moves.
    #[serde(default)]
    pub chief: bool,
    /// The Cloud machine the chat runs on; None for a chat of this Mac or another machine.
    #[serde(default)]
    pub running: Option<String>,
    /// The chat runs on a machine that is neither this Mac nor a Cloud machine (an SSH peer).
    #[serde(default)]
    pub elsewhere: bool,
    /// A move from this Mac put the Cloud chat where it runs: only then has it a folder to take.
    #[serde(default)]
    pub moved_here: bool,
    /// The chat's acpmux session as its tab names it (`PEER/ID` for a peer's chat shown here).
    #[serde(default)]
    pub session: Option<String>,
    /// The SSH machine whose daemon lists the chat's tab: the chat runs there.
    #[serde(default)]
    pub on_ssh: Option<String>,
    /// The acpmux peer that runs the chat this Mac's tab shows (a peer's chat opened here).
    #[serde(default)]
    pub peer: Option<String>,
    /// The machines the app reaches over SSH.
    #[serde(default)]
    pub ssh: Vec<SshMachine>,
    /// Bring Back Local can take the chat back now (a move from this Mac put it there).
    #[serde(default)]
    pub back_home: bool,
    #[serde(default)]
    pub machines: Vec<Machine>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    pub id: String,
    /// Empty for this Mac: the page names it.
    pub label: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub status: String,
    /// `local`, `cloud` or `ssh`.
    pub kind: &'static str,
    /// The app action that moves the chat there ([`action`]).
    pub action: &'static str,
}

/// Machines that are going away or never came up take no chat.
const GONE: [&str; 3] = ["failed", "destroyed", "deleting"];

/// Where the chat runs when that is a machine added over SSH.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Source<'a> {
    /// The SSH machine whose daemon lists the tab (its id).
    Machine(&'a str),
    /// The acpmux peer this Mac's tab reaches the chat through (its name).
    Peer(&'a str),
}

impl Chat {
    /// The SSH machine or peer the chat runs on; None for this Mac's or a Cloud machine's.
    fn source(&self) -> Option<Source<'_>> {
        if self.running.is_some() {
            return None;
        }
        if let Some(id) = self.on_ssh.as_deref().filter(|id| self.ssh.iter().any(|m| m.id == *id)) {
            return Some(Source::Machine(id));
        }
        // Another machine's tab that is no SSH machine's (a Cloud chat whose machine is not listed
        // yet): no peer route from here names it.
        if self.elsewhere {
            return None;
        }
        let routed = self.session.as_deref().and_then(|s| s.split_once('/')).map(|(peer, _)| peer);
        self.peer
            .as_deref()
            .or(routed)
            .filter(|peer| !peer.is_empty() && *peer != LOCAL)
            .map(Source::Peer)
    }
}

fn here(action: &'static str) -> Target {
    Target { id: LOCAL.into(), label: String::new(), status: String::new(), kind: "local", action }
}

fn normalized(name: &str) -> String {
    let name = name.trim().to_lowercase();
    name.strip_suffix('.').map(str::to_owned).unwrap_or(name)
}

/// Whether `machine` is the one `source` names.
fn is_source(machine: &SshMachine, source: Option<&Source<'_>>) -> bool {
    match source {
        None => false,
        Some(Source::Machine(id)) => machine.id == *id,
        Some(Source::Peer(peer)) => machine.names.iter().any(|n| normalized(n) == normalized(peer)),
    }
}

/// Every place the chat can move now, in order: this Mac first when the chat can come back, then
/// every other live Cloud machine in the list's order, then every SSH machine that is up. A chat
/// on an SSH machine lists this Mac and the other SSH machines (acpmux moves it); a Cloud chat
/// lists no SSH machine, and a chat of a machine the app knows neither way moves nowhere here.
pub fn targets(chat: &Chat) -> Vec<Target> {
    if !chat.started || chat.chief {
        return Vec::new();
    }
    if let Some(running) = chat.running.as_deref() {
        // A Cloud chat no move from here put there has no folder to take yet (cmux#40122).
        if !chat.offered || !chat.moved_here {
            return Vec::new();
        }
        let mut targets = Vec::new();
        if chat.back_home {
            targets.push(here(action::BRING_BACK));
        }
        targets.extend(cloud(chat, Some(running), action::TO_MACHINE));
        return targets;
    }
    if let Some(source) = chat.source() {
        let mut targets = vec![here(action::SSH_MOVE)];
        targets.extend(ssh(chat, Some(&source)));
        return targets;
    }
    if chat.elsewhere {
        return Vec::new();
    }
    let mut targets =
        if chat.offered { cloud(chat, None, action::MOVE_TO_CLOUD) } else { Vec::new() };
    targets.extend(ssh(chat, None));
    targets
}

fn cloud(chat: &Chat, running: Option<&str>, action: &'static str) -> Vec<Target> {
    chat.machines
        .iter()
        .filter(|machine| {
            running != Some(machine.id.as_str())
                && !GONE.contains(&machine.status.as_str())
                && !machine.id.is_empty()
                && machine.id != LOCAL
        })
        .map(|machine| Target {
            id: machine.id.clone(),
            label: machine.title.clone(),
            status: machine.status.clone(),
            kind: "cloud",
            action,
        })
        .collect()
}

/// The SSH machines, each once: a later entry sharing a name with an earlier one is that machine,
/// and the machine is up when either says so (the sidebar's link may be down while acpmux's is up).
fn distinct(machines: &[SshMachine]) -> Vec<SshMachine> {
    let mut kept: Vec<(Vec<String>, SshMachine)> = Vec::new();
    for machine in machines {
        let names: Vec<String> =
            machine.names.iter().map(|n| normalized(n)).filter(|n| !n.is_empty()).collect();
        if let Some((seen, first)) =
            kept.iter_mut().find(|(seen, _)| names.iter().any(|name| seen.contains(name)))
        {
            first.online |= machine.online;
            seen.extend(names);
            continue;
        }
        kept.push((names, machine.clone()));
    }
    kept.into_iter().map(|(_, machine)| machine).collect()
}

fn ssh(chat: &Chat, source: Option<&Source<'_>>) -> Vec<Target> {
    distinct(&chat.ssh)
        .into_iter()
        .filter(|machine| {
            machine.online
                && !machine.id.is_empty()
                && machine.id != LOCAL
                && !chat.machines.iter().any(|cloud| cloud.id == machine.id)
                && !is_source(machine, source)
        })
        .map(|machine| Target {
            id: machine.id,
            label: if machine.title.is_empty() {
                machine.names.first().cloned().unwrap_or_default()
            } else {
                machine.title
            },
            status: String::new(),
            kind: "ssh",
            action: action::SSH_MOVE,
        })
        .collect()
}

/// The host of a peer's `ssh://[user@]host[:port][/...]`.
fn url_host(url: &str) -> Option<&str> {
    let rest = url.strip_prefix("ssh://")?;
    let rest = rest.split('/').next()?;
    let host = rest.rsplit_once('@').map_or(rest, |(_, host)| host);
    let host = host.split(':').next()?;
    (!host.is_empty()).then_some(host)
}

/// The acpmux peer that is `machine`: the one named as the machine is (its ssh host, short host
/// or sidebar name, any case), else the one reached at its ssh host.
pub fn peer_of<'a>(machine: &SshMachine, peers: &'a [Peer]) -> Option<&'a str> {
    let names: Vec<String> =
        machine.names.iter().map(|n| normalized(n)).filter(|n| !n.is_empty()).collect();
    let named = peers
        .iter()
        .find(|peer| peer.url.starts_with("ssh://") && names.contains(&normalized(&peer.name)));
    named
        .or_else(|| {
            peers.iter().find(|peer| {
                url_host(&peer.url).is_some_and(|host| names.contains(&normalized(host)))
            })
        })
        .map(|peer| peer.name.as_str())
}

// CLI planning and output decoding are separate from the legacy Cloud target model.
#[path = "targets/ssh_move.rs"]
mod ssh_move;
pub use ssh_move::{
    SshMove, SshMoveCall, SshMoveResult, SshMoveRun, ssh_move, ssh_move_result, ssh_move_run,
};

#[cfg(test)]
mod tests;
