//! Which Cloud machine a `cloud.startChat` send runs on (Leo, 2026-10-30:
//! "like the initial 0 to 1 chat auto it sends to cloud"). For now each Mac
//! workspace gets a small machine of its own (Leo, 2026-10-31: "austin/lawrence
//! said indeed we wanted 1 workspace per vm for now / i guess they're
//! relatively smol vms"; leo-workspace `design/cloud.md`, "One workspace per
//! small machine, snapshots, and a Cloud button"): a workspace's first send
//! makes a new machine named for chats ([`CHATS_NAME`]), its later sends go
//! back to it, and a machine already some workspace's is never given to
//! another. An existing machine is never reused for a new workspace, so the
//! team's machines (someone's busy lane VM, a teammate's box) are never
//! taken. A retry of the same send stays on the machine its first try took
//! ([`destination`]), so it never opens a second chat with the prompt
//! elsewhere. The ledger can hold many workspaces on one machine; one per
//! machine is this file's policy, so sharing can come back here alone.

use std::collections::BTreeSet;

use super::ledger::{Ledger, Send};

/// One Cloud machine as the App lists it.
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Deserialize)]
pub(crate) struct Candidate {
    pub(crate) id: String,
    #[serde(default)]
    pub(crate) title: String,
    /// The person who created it, when the server says.
    #[serde(default)]
    pub(crate) created_by: Option<String>,
    /// The server's status: `provisioning`, `running`, `paused`, `failed`, ...
    #[serde(default)]
    pub(crate) status: String,
    /// Whether this app's link to its daemon is up.
    #[serde(default)]
    pub(crate) connected: bool,
}

impl Candidate {
    /// Its daemon can be reached, or soon will be (`CloudMachine.Status.isLive`).
    fn is_live(&self) -> bool {
        matches!(self.status.as_str(), "running" | "provisioning" | "starting")
    }

    /// The server failed it or is removing it, even while a stale link to it
    /// still reads as connected.
    fn is_gone(&self) -> bool {
        matches!(self.status.as_str(), "failed" | "deleting" | "deleted" | "destroyed")
    }

    /// Can take work now or after a resume: connected, live (resuming
    /// included), or paused or pausing (by a person or the idle timer), and
    /// not gone.
    fn is_usable(&self) -> bool {
        !self.is_gone()
            && (self.connected
                || self.is_live()
                || matches!(self.status.as_str(), "paused" | "pausing"))
    }
}

/// The name a machine made for chats gets.
pub(crate) const CHATS_NAME: &str = "cloud-chats";

/// This person's: they created it, or, when the server names no creator, an
/// earlier send of this account ran there (`used`).
fn is_mine(machine: &Candidate, user: &str, used: &BTreeSet<String>) -> bool {
    match &machine.created_by {
        Some(creator) => creator == user,
        None => used.contains(&machine.id),
    }
}

/// The name a new machine for chats gets: [`CHATS_NAME`], else
/// `cloud-chats-N` from 2, unique among `taken` (trimmed, in any case).
pub(crate) fn new_machine_name<'a>(taken: impl IntoIterator<Item = &'a str>) -> String {
    let used: BTreeSet<String> = taken.into_iter().map(|name| name.trim().to_lowercase()).collect();
    if !used.contains(CHATS_NAME) {
        return CHATS_NAME.to_string();
    }
    (2u64..)
        .map(|number| format!("{CHATS_NAME}-{number}"))
        .find(|name| !used.contains(name))
        .unwrap_or_else(|| CHATS_NAME.to_string())
}

/// Where a send goes: a machine by id, or a new one for chats.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Destination {
    Machine(String),
    New,
}

/// Where `send` goes: the machine its first try took while that machine
/// exists (listed, or `stored`: in the App's store but not yet in its list,
/// one made since; before the App's list is `loaded`, it is kept). Then, for
/// a send from the Mac workspace `workspace`, the machine that workspace
/// already has ([`workspace_machine`]). Otherwise a new machine: a workspace
/// with no machine, or a send from no workspace, never reuses an existing
/// one (one workspace per small machine for now; see the module comment).
/// Drops a pin to a machine that is gone, which holds no tab of this send.
#[allow(clippy::too_many_arguments)]
pub(crate) fn destination(
    send: &Send,
    account: &str,
    workspace: Option<&str>,
    pins: &mut Ledger,
    candidates: &[Candidate],
    stored: &[String],
    user: Option<&str>,
    loaded: bool,
) -> Destination {
    if let Some(pinned) = pins.machine(send) {
        if !loaded
            || candidates.iter().any(|machine| machine.id == pinned)
            || stored.contains(&pinned)
        {
            return Destination::Machine(pinned);
        }
        pins.forget(send);
    }
    if let Some(workspace) = workspace
        && let Some(own) =
            workspace_machine(workspace, account, pins, candidates, stored, user, loaded)
    {
        return Destination::Machine(own);
    }
    Destination::New
}

/// Makes `machine` the workspace `workspace`'s own in `account` when the
/// workspace has none yet and no other workspace of the account has it (a
/// machine serves one workspace for now). Answers whether it is the
/// workspace's now.
///
/// The first machine a workspace gets stays its own: a retry of an older send
/// never takes the workspace back, and when two first sends of one workspace
/// race (both planned `New` before either pinned), the first pin wins and the
/// later machine keeps only its own send's chat. A machine that is gone was
/// already dropped by [`destination`], so the workspace's next one binds.
pub(crate) fn claim(pins: &mut Ledger, workspace: &str, account: &str, machine: &str) -> bool {
    if let Some(own) = pins.workspace_machine(workspace, account) {
        return own == machine;
    }
    if pins.held_by_another(machine, workspace, account) {
        return false;
    }
    pins.bind(workspace, account, machine);
    true
}

/// The machine the workspace `workspace` has, while it is listed, this
/// person's and usable (one made since, `stored`, or before the App's list is
/// `loaded`, it is kept). Drops the workspace's machine when it is gone, a
/// teammate's or failed, so its next send makes a new one.
fn workspace_machine(
    workspace: &str,
    account: &str,
    pins: &mut Ledger,
    candidates: &[Candidate],
    stored: &[String],
    user: Option<&str>,
    loaded: bool,
) -> Option<String> {
    let own = pins.workspace_machine(workspace, account)?;
    let keep = match candidates.iter().find(|machine| machine.id == own) {
        Some(machine) => {
            let used = pins.machines_of(account);
            user.is_some_and(|user| is_mine(machine, user, &used)) && machine.is_usable()
        }
        None => !loaded || stored.contains(&own),
    };
    if keep {
        return Some(own);
    }
    pins.unbind(workspace, account);
    None
}
