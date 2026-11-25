//! The local pins of a Cloud first send. Every new Cloud start gets a new
//! machine of its own: a second chat from the same Mac workspace, a paused
//! machine, a free one of the person's or one an earlier Cloud chat made is
//! never reused (one machine per Cloud workspace or session). Only a retry of
//! the same send stays on the machine its first try took, preserving its tab
//! key and never paying for a second machine.

use std::collections::BTreeSet;

use super::ledger::{Ledger, Send};

/// One Cloud machine as the App lists it. A new send takes none of them: a
/// pin to one is kept while it is listed, and their titles keep a new
/// machine's name unique. The App's other fields (creator, status, tags) are
/// ignored.
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
/// one made since; before the App's list is `loaded`, it is kept). Otherwise a
/// new machine, whatever the send's Mac workspace already has: every new
/// Cloud start is a machine of its own, never one listed, paused or made by an
/// earlier chat. The caller asks the platform to resolve the project before
/// creating. Drops a pin to a machine that is gone, which holds no tab of this send.
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

    /// An explicit or pinned destination can predate environment metadata in the app FFI.
    pub(crate) fn conflicts_with_environment(&self, selected: Option<&str>) -> bool {
        matches!((selected, self.environment.as_deref()), (Some(selected), Some(actual)) if selected != actual)
    }

    pub(crate) fn matches_environment(&self, selected: Option<&str>) -> bool {
        selected.is_none_or(|id| self.environment.as_deref() == Some(id))
    }
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
