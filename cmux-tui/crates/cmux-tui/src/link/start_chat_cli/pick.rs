//! Which Cloud machine a Cloud send runs on. A retry of the same send stays on
//! the machine its first try took, preserving its tab key. A new send reuses
//! the person's own machine ([`reuse`]): the user, 2026-11-24, on a machine
//! list of cloud-chats … cloud-chats-7: "i should be making a new machine every
//! time i press enter on the chat?" No: a new machine is made only when the
//! person has none to reuse, or asks for one (New Cloud machine…, `--on
//! vm:new`), which go their own way, not through this pick.

use std::collections::BTreeSet;

use super::ledger::{Ledger, Send};

/// One Cloud machine as the App lists it (`start_chat_plan_entry`): a pin to
/// one is kept while it is listed, a new send reuses the person's own
/// ([`reuse`]), and their titles keep a new machine's name unique.
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Deserialize)]
pub(crate) struct Candidate {
    pub(crate) id: String,
    #[serde(default)]
    pub(crate) title: String,
    /// The machine's disk in MB as the App's list knows it (`disk_mb`); None for a list that names none.
    #[serde(default)]
    pub(crate) disk_mb: Option<i64>,
    #[serde(default)]
    pub(crate) environment: Option<String>,
    #[serde(default)]
    pub(crate) claude_ready: bool,
    #[serde(default)]
    pub(crate) slug: Option<String>,
    /// The person who made it, when the server says.
    #[serde(default)]
    pub(crate) created_by: Option<String>,
    /// The shown status: `running`, `paused`, `starting`, `failed`, ...
    #[serde(default)]
    pub(crate) status: String,
    /// Whether this App's link to its daemon is up.
    #[serde(default)]
    pub(crate) connected: bool,
}

impl Candidate {
    /// Takes work now: connected, or running or on its way up.
    fn is_open(&self) -> bool {
        self.connected || matches!(self.status.as_str(), "running" | "provisioning" | "starting")
    }

    /// Takes work now or after a resume: open, or paused or pausing; never one failed or being
    /// removed, even while a stale link still reads as connected.
    fn is_usable(&self) -> bool {
        !matches!(self.status.as_str(), "failed" | "deleting" | "deleted" | "destroyed" | "stopped")
            && (self.is_open() || matches!(self.status.as_str(), "paused" | "pausing"))
    }

    /// A machine fleet tooling made (lane pool, peers, probes), by name: never a chat's.
    fn is_fleet(&self) -> bool {
        std::iter::once(self.title.as_str()).chain(self.slug.as_deref()).any(|name| {
            let name = name.trim().to_lowercase();
            ["fs-", "sr2-", "lane-vm-"].iter().any(|prefix| name.starts_with(prefix))
        })
    }
}

/// The name a machine made for chats gets.
pub(crate) const CHATS_NAME: &str = "cloud-chats";

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
    EnvironmentMismatch,
}

/// Where `send` goes: the machine its first try took while that machine
/// exists (listed, or `stored`: in the App's store but not yet in its list,
/// one made since; before the App's list is `loaded`, it is kept). Otherwise
/// `New`, which the caller turns into the person's machine to reuse ([`reuse`])
/// before it makes one. Drops a pin to a machine that is gone, which holds no tab of this send.
pub(crate) fn destination(
    send: &Send,
    pins: &mut Ledger,
    candidates: &[Candidate],
    stored: &[String],
    loaded: bool,
    environment: Option<&str>,
) -> Destination {
    if let Some(pinned) = pins.machine(send) {
        if !loaded
            || candidates.iter().any(|machine| machine.id == pinned)
            || stored.contains(&pinned)
        {
            if candidates
                .iter()
                .any(|vm| vm.id == pinned && vm.conflicts_with_environment(environment))
            {
                return Destination::EnvironmentMismatch;
            }
            return Destination::Machine(pinned);
        }
        pins.forget(send);
    }
    candidates
        .iter()
        .filter(|vm| vm.claude_ready && vm.matches_environment(environment))
        .min_by(|left, right| left.id.cmp(&right.id))
        .map_or(Destination::New, |vm| Destination::Machine(vm.id.clone()))
}

impl Candidate {
    pub(super) fn preflight_machine(&self) -> super::preflight::Machine<'_> {
        super::preflight::Machine {
            id: &self.id,
            title: &self.title,
            disk_bytes: self
                .disk_mb
                .and_then(|mb| u64::try_from(mb).ok())
                .map(|mb| mb.saturating_mul(1024 * 1024)),
        }
    }

    /// A pin can predate environment metadata. The app verifies it before copying.
    pub(crate) fn conflicts_with_environment(&self, selected: Option<&str>) -> bool {
        matches!((selected, self.environment.as_deref()), (Some(selected), Some(actual)) if selected != actual)
    }

    pub(crate) fn matches_environment(&self, selected: Option<&str>) -> bool {
        selected.is_none_or(|id| self.environment.as_deref() == Some(id))
    }
}

/// The machine a new send reuses, by id; None: make one ([`CHATS_NAME`]). Only the person's
/// own (`user` made it, or, when the server names no maker, an earlier send of this account
/// ran on it), never a fleet VM, and only one that takes work now or after a resume. Among
/// those, an open one before a paused one (the start resumes it); then the send's Mac
/// workspace's own machine; then the one this account's sends ran on most recently; then a
/// machine named for chats; then the App's order. Two chats in a row share one machine.
pub(crate) fn reuse(
    pins: &Ledger,
    candidates: &[Candidate],
    account: &str,
    workspace: Option<&str>,
    user: Option<&str>,
) -> Option<String> {
    let recent = pins.recent_machines(account);
    let own = workspace.and_then(|workspace| pins.workspace_machine(workspace, account));
    let mine = |machine: &Candidate| match (machine.created_by.as_deref(), user) {
        (Some(maker), Some(user)) => maker == user,
        (Some(_), None) => false,
        (None, _) => recent.contains(&machine.id),
    };
    let named_for_chats = |machine: &Candidate| {
        let title = machine.title.trim().to_lowercase();
        title == CHATS_NAME
            || title
                .strip_prefix(CHATS_NAME)
                .and_then(|rest| rest.strip_prefix('-'))
                .is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
    };
    candidates
        .iter()
        .enumerate()
        .filter(|(_, machine)| machine.is_usable() && !machine.is_fleet() && mine(machine))
        .min_by_key(|(order, machine)| {
            (
                !machine.is_open(),
                own.as_deref() != Some(machine.id.as_str()),
                recent.iter().position(|id| *id == machine.id).unwrap_or(usize::MAX),
                !named_for_chats(machine),
                *order,
            )
        })
        .map(|(_, machine)| machine.id.clone())
}

/// Makes `machine` the workspace `workspace`'s own in `account` when the
/// workspace has none yet and no other workspace of the account has it (a
/// machine serves one workspace). Answers whether it is the
/// workspace's now.
///
/// The first machine a workspace gets stays its own: a retry of an older send
/// never takes the workspace back, and when two first sends of one workspace
/// race (both planned `New` before either pinned), the first pin wins and the
/// later machine keeps only its own send's chat. The binding only records
/// which machine a workspace's first send made (a repick moves it, see
/// `pin`); [`destination`] never hands it to a later send.
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
