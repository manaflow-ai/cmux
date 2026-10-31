//! Which Cloud machine a `cloud.startChat` send runs on (Leo, 2026-10-30:
//! "like the initial 0 to 1 chat auto it sends to cloud"). Never the team's
//! first connected machine, which on a shared account is often someone's busy
//! lane VM: a machine this person owns that is free (no chat open on it, or
//! one named for chats, [`CHATS_NAME`]), else a new one named for chats.
//! Lane-pool VMs (`fs-lane-N`, `lane-vm-N`) are never picked. A retry of the
//! same send stays on the machine its first try took ([`destination`]), so it
//! never opens a second chat with the prompt elsewhere.

use std::collections::BTreeSet;

use super::ledger::{Ledger, Send};

/// One Cloud machine as the App lists it.
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Deserialize)]
pub(crate) struct Candidate {
    pub(crate) id: String,
    #[serde(default)]
    pub(crate) title: String,
    #[serde(default)]
    pub(crate) slug: Option<String>,
    /// The person who created it, when the server says.
    #[serde(default)]
    pub(crate) created_by: Option<String>,
    /// The server's status: `provisioning`, `running`, `paused`, `failed`, ...
    #[serde(default)]
    pub(crate) status: String,
    /// Why a paused machine is paused: `idle` (the idle timer) or `user`.
    #[serde(default)]
    pub(crate) pause_reason: Option<String>,
    /// Whether this app's link to its daemon is up.
    #[serde(default)]
    pub(crate) connected: bool,
    /// Chat tabs open on it; None when its store is not read (not connected).
    #[serde(default)]
    pub(crate) chats: Option<u64>,
}

impl Candidate {
    /// Its daemon can be reached, or soon will be (`CloudMachine.Status.isLive`).
    fn is_live(&self) -> bool {
        matches!(self.status.as_str(), "running" | "provisioning" | "starting")
    }

    /// A pause, resume or delete the server accepted is on its way
    /// (`CloudMachine.Status.isChanging`).
    fn is_changing(&self) -> bool {
        matches!(self.status.as_str(), "pausing" | "starting" | "deleting")
    }

    /// Paused by the idle timer, which pauses only an idle machine.
    fn is_idle_paused(&self) -> bool {
        self.status == "paused" && self.pause_reason.as_deref() == Some("idle")
    }

    /// Can take work now or after a resume: connected, live (resuming
    /// included), or paused or pausing (by a person or the idle timer). Never
    /// one the server failed or is removing, even while a stale link to it
    /// still reads as connected.
    fn is_usable(&self) -> bool {
        !matches!(self.status.as_str(), "failed" | "deleting" | "deleted" | "destroyed")
            && (self.connected
                || self.is_live()
                || matches!(self.status.as_str(), "paused" | "pausing"))
    }

    fn names(&self) -> impl Iterator<Item = &str> {
        std::iter::once(self.title.as_str()).chain(self.slug.as_deref())
    }
}

/// The name a machine made for chats gets, and how a machine is marked as one.
pub(crate) const CHATS_NAME: &str = "cloud-chats";

/// `cloud-chats`, or `cloud-chats-N`, in any case.
pub(crate) fn is_marked_for_chats(name: &str) -> bool {
    let name = name.to_lowercase();
    name == CHATS_NAME
        || name
            .strip_prefix(CHATS_NAME)
            .and_then(|rest| rest.strip_prefix('-'))
            .is_some_and(|number| number.chars().all(char::is_numeric))
}

/// A lane-pool VM's name: `fs-lane-N` or `lane-vm-N` (leo-workspace machines/lane-vms.md).
pub(crate) fn is_lane_pool(name: &str) -> bool {
    let name = name.to_lowercase();
    ["fs-lane-", "lane-vm-"].iter().any(|prefix| {
        name.strip_prefix(prefix)
            .is_some_and(|number| !number.is_empty() && number.chars().all(char::is_numeric))
    })
}

/// The machine a first send takes, by id; None: make one ([`CHATS_NAME`]).
/// Only this person's (`user`; a machine the server names no creator for
/// counts when an earlier send ran on it, `used`), never a lane-pool VM, and
/// only one that can take work now or after an idle resume, with no pause,
/// resume or delete on its way. Among those: one
/// marked for chats first, then a free one (connected with no chat open, or
/// paused by the idle timer); connected first, then in the App's order.
pub(crate) fn pick(
    candidates: &[Candidate],
    user: Option<&str>,
    used: &BTreeSet<String>,
) -> Option<String> {
    let user = user?;
    let mine = |machine: &Candidate| is_mine(machine, user, used);
    let free = |machine: &Candidate| {
        if machine.connected { machine.chats == Some(0) } else { machine.is_idle_paused() }
    };
    let marked = |machine: &Candidate| machine.names().any(is_marked_for_chats);
    let mut ranked: Vec<&Candidate> = candidates
        .iter()
        .filter(|machine| {
            !machine.is_changing()
                && mine(machine)
                && !machine.names().any(is_lane_pool)
                && (machine.connected || machine.is_live() || machine.is_idle_paused())
                && (marked(machine) || free(machine))
        })
        .collect();
    // A stable sort: ties keep the App's order.
    ranked.sort_by_key(|machine| (!marked(machine), !machine.connected));
    ranked.first().map(|machine| machine.id.clone())
}

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
/// a send from the Mac workspace `workspace`, [`workspace_destination`]; for
/// one from no workspace, [`pick`] among the machines no workspace of the
/// account owns, which this account's sends count as the person's.
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
    let used = pins.machines_of(account);
    if let Some(workspace) = workspace {
        return workspace_destination(
            workspace, account, pins, candidates, stored, user, &used, loaded,
        );
    }
    // A workspace's own machine is never shared with a send from no workspace.
    let owned = pins.workspace_machines(account);
    let shared: Vec<Candidate> =
        candidates.iter().filter(|machine| !owned.contains(&machine.id)).cloned().collect();
    pick(&shared, user, &used).map_or(Destination::New, Destination::Machine)
}

/// The workspace `workspace`'s own machine while it is listed, this person's
/// and usable (one made since, `stored`, or before the App's list is `loaded`,
/// it is kept), else a new one. Drops the workspace's machine when it is gone,
/// a teammate's or failed, so the new one becomes the workspace's.
#[allow(clippy::too_many_arguments)]
fn workspace_destination(
    workspace: &str,
    account: &str,
    pins: &mut Ledger,
    candidates: &[Candidate],
    stored: &[String],
    user: Option<&str>,
    used: &BTreeSet<String>,
    loaded: bool,
) -> Destination {
    let Some(own) = pins.workspace_machine(workspace, account) else { return Destination::New };
    let keep = match candidates.iter().find(|machine| machine.id == own) {
        Some(machine) => {
            user.is_some_and(|user| is_mine(machine, user, used)) && machine.is_usable()
        }
        None => !loaded || stored.contains(&own),
    };
    if keep {
        return Destination::Machine(own);
    }
    pins.unbind(workspace, account);
    Destination::New
}
