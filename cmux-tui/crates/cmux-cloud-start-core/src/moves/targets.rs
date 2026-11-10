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
            id: machine.id.clone(),
            label: if machine.title.is_empty() {
                machine.names.first().cloned().unwrap_or_default()
            } else {
                machine.title.clone()
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
    let named = peers.iter().find(|peer| names.contains(&normalized(&peer.name)));
    named
        .or_else(|| {
            peers.iter().find(|peer| {
                url_host(&peer.url).is_some_and(|host| names.contains(&normalized(host)))
            })
        })
        .map(|peer| peer.name.as_str())
}

/// One Move to… an SSH machine (or back here from one), as the app asks it.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshMove {
    pub chat: Chat,
    /// The target's id ([`Target::id`]); none takes the first SSH machine listed.
    #[serde(default)]
    pub target: Option<String>,
    /// This Mac's acpmux peers, read when the move starts.
    #[serde(default)]
    pub peers: Vec<Peer>,
}

/// What the app runs for an [`SshMove`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SshMoveCall {
    /// `acpmux` arguments: `--json session move SESSION --machine TO [--from PEER]`.
    pub args: Vec<String>,
    /// The chat's session as this Mac's tab names it once moved: `PEER/ID` on a peer, `ID` here.
    pub moved: String,
}

/// The `acpmux session move` call of `request`, or why it cannot run: `not_offered` (the list does
/// not offer that target now), `unknown_peer` (no acpmux peer of this Mac is that machine) or
/// `not_started` (the chat has no session yet).
pub fn ssh_move(request: &SshMove) -> Result<SshMoveCall, &'static str> {
    let chat = &request.chat;
    let offered = targets(chat);
    let target = match request.target.as_deref() {
        Some(id) => offered.iter().find(|t| t.id == id && t.action == action::SSH_MOVE),
        None => offered.iter().find(|t| t.kind == "ssh"),
    }
    .ok_or("not_offered")?;
    let unknown = "unknown_peer";
    let peer =
        |id: &str| chat.ssh.iter().find(|m| m.id == id).and_then(|m| peer_of(m, &request.peers));
    let from = match chat.source() {
        None => None,
        Some(Source::Peer(name)) => Some(name),
        Some(Source::Machine(id)) => Some(peer(id).ok_or(unknown)?),
    };
    let to = if target.kind == "local" { LOCAL } else { peer(&target.id).ok_or(unknown)? };
    let session = chat.session.as_deref().filter(|s| !s.is_empty()).ok_or("not_started")?;
    // A peer's chat shown here is `PEER/ID`; acpmux moves it by its id on that peer.
    let id = match from {
        Some(from) => {
            session.strip_prefix(from).and_then(|s| s.strip_prefix('/')).unwrap_or(session)
        }
        None => session,
    };
    let mut args: Vec<String> = ["--json", "session", "move", id, "--machine", to]
        .iter()
        .map(|s| (*s).to_owned())
        .collect();
    if let Some(from) = from {
        args.extend(["--from".to_owned(), from.to_owned()]);
    }
    let moved = if to == LOCAL { id.to_owned() } else { format!("{to}/{id}") };
    Ok(SshMoveCall { args, moved })
}

/// What `acpmux --json session move` printed: Ok once the chat moved, else why not, in acpmux's
/// words (the row's `error`, else its error line on stderr), else the fallback `""` (the app says
/// it in the person's words). acpmux prints its answer pretty, over many lines.
pub fn ssh_move_outcome(stdout: &str, stderr: &str, status: i32) -> Result<(), String> {
    let answer = serde_json::from_str::<serde_json::Value>(stdout.trim()).ok().or_else(|| {
        stdout
            .lines()
            .rev()
            .find_map(|line| serde_json::from_str::<serde_json::Value>(line.trim()).ok())
    });
    let row = answer.as_ref().and_then(|answer| answer.get("moves")?.as_array()?.first().cloned());
    if let Some(row) = &row {
        if let Some(error) = row.get("error").and_then(|e| e.as_str()).filter(|e| !e.is_empty()) {
            return Err(error.to_owned());
        }
        if status == 0 && row.get("moved").and_then(|m| m.as_bool()) == Some(true) {
            return Ok(());
        }
    }
    let last =
        stderr.lines().rev().map(str::trim).find(|line| !line.is_empty()).unwrap_or_default();
    // `--json`'s error envelope (`acpmux/src/cli/errors.rs`): `{"error": {"message", "detail"}}`.
    let envelope = serde_json::from_str::<serde_json::Value>(last).ok();
    let error = envelope.as_ref().and_then(|e| e.get("error"));
    let said = error
        .and_then(|e| {
            e.get("message")
                .or_else(|| e.get("detail"))
                .and_then(|m| m.as_str())
                .or_else(|| e.as_str())
        })
        .unwrap_or_else(|| last.strip_prefix("Error: ").unwrap_or(last));
    Err(said.to_owned())
}

#[cfg(test)]
mod tests;
