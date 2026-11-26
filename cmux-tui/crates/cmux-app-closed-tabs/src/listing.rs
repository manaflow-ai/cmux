//! Every machine's closed items as one list (`DaemonClosedHistory`, DaemonClosedHistory.swift):
//! newest first across machines, looked up by id or by group, and Cmd-Shift-T's pick with the
//! owner facts it reads.

use crate::item::{ClosedItem, Kind};
use crate::records;
use cmux_window_rules::closed::{self, OwnerFacts};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// One connected machine's daemon as the closed history reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Machine {
    /// Its machine id (`DaemonService.machineID`; this Mac's is `local`).
    pub machine: String,
    /// This Mac's daemon (`DaemonService.isLocal`).
    pub local: bool,
    /// Its store serves the state resources, so it records closed history
    /// (`DaemonStore.servesStateResources`).
    pub serves: bool,
    /// Its mirrored closed items (`DaemonStore.closedItems`), in the daemon's order.
    pub items: Vec<ClosedItem>,
    /// The window of this app that lists each of its live workspaces, by workspace resource id
    /// (`DaemonStore.workspace(resourceID:)` then `WindowRegistry.owner(of:)`). A workspace that is
    /// not live, or that no window lists, is absent.
    pub workspace_windows: BTreeMap<String, String>,
}

/// One item with the machine whose daemon recorded it (`DaemonClosedHistory.Entry`), by place:
/// `machine` indexes the machines, `item` that machine's items.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryRef {
    pub machine: usize,
    pub item: usize,
}

/// An entry resolved against its machines.
#[derive(Clone, Copy, Debug)]
pub struct Entry<'a> {
    pub at: EntryRef,
    pub machine: &'a Machine,
    pub item: &'a ClosedItem,
}

/// Every serving machine's items of `kinds`, newest first; items closed at the same time keep
/// machine order, then the daemon's order (a stable sort, as Swift's `sorted` is).
pub fn entries<'a>(machines: &'a [Machine], kinds: &[Kind]) -> Vec<Entry<'a>> {
    let mut all: Vec<Entry<'a>> =
        machines
            .iter()
            .enumerate()
            .filter(|(_, machine)| machine.serves)
            .flat_map(|(m, machine)| {
                machine.items.iter().enumerate().filter(|(_, item)| kinds.contains(&item.kind)).map(
                    move |(i, item)| Entry { at: EntryRef { machine: m, item: i }, machine, item },
                )
            })
            .collect();
    all.sort_by_key(|entry| std::cmp::Reverse(entry.item.closed_at_ms));
    all
}

/// [`entries`] of every kind.
pub fn all_entries(machines: &[Machine]) -> Vec<Entry<'_>> {
    entries(machines, &Kind::ALL)
}

/// True when some machine records closed history (`isServed`).
pub fn is_served(machines: &[Machine]) -> bool {
    machines.iter().any(|machine| machine.serves)
}

/// The newest entry with item id `id` on any serving machine (`entry(_:in:)`).
pub fn entry<'a>(machines: &'a [Machine], id: &str) -> Option<Entry<'a>> {
    all_entries(machines).into_iter().find(|entry| entry.item.id == id)
}

/// The newest recorded delete of personal workspace group `id` (`groupEntry`): Ungroup and
/// Delete Group record the group as a workspace item.
pub fn group_entry<'a>(machines: &'a [Machine], id: &str) -> Option<Entry<'a>> {
    entries(machines, &[Kind::Workspace])
        .into_iter()
        .find(|entry| entry.item.group.as_ref().is_some_and(|group| group.id == id))
}

/// The app's windows as the registry knows them: whether each is open, by window id.
pub type Registry = BTreeMap<String, bool>;

/// Who owns `entry` for Cmd-Shift-T (`ownerFacts`, decision 1, reopen-closed.md 4): the window
/// record a close left names one of this app's windows (on this Mac's daemon only), as the
/// registry knows it; else the window that lists its workspace. `installs`: this install's ids.
pub fn owner_facts(entry: &Entry<'_>, installs: &[String], registry: &Registry) -> OwnerFacts {
    let recorded = if entry.machine.local {
        entry.item.window.as_deref().and_then(|window| records::window_id(window, installs))
    } else {
        None
    };
    let workspace_window = entry
        .item
        .workspace_id
        .as_deref()
        .and_then(|workspace| entry.machine.workspace_windows.get(workspace))
        .cloned();
    OwnerFacts {
        kind: entry.item.kind.rules_kind(),
        local: entry.machine.local,
        recorded_open: recorded.as_deref().and_then(|window| registry.get(window).copied()),
        recorded_window: recorded,
        workspace_window,
    }
}

/// Cmd-Shift-T's entry for window `window` (`newest(for:in:)`): the newest group of any level
/// that left this window, else the newest one no live window owns (a closed window among
/// them); never a group of another live window (cmux-window-rules `closed::newest`).
pub fn newest<'a>(
    machines: &'a [Machine],
    installs: &[String],
    registry: &Registry,
    window: Option<&str>,
) -> Option<Entry<'a>> {
    let all = all_entries(machines);
    let facts: Vec<OwnerFacts> =
        all.iter().map(|entry| owner_facts(entry, installs, registry)).collect();
    closed::newest(&facts, window).and_then(|index| all.get(index).copied())
}

/// `closed` (newest first, each as its item and machine) with a page closed again once, at its
/// newest close (`newestOnce`): Recently Closed and Search Tabs list a page once. Indices into
/// `closed`.
pub fn newest_once(closed: &[(&ClosedItem, &str)]) -> Vec<usize> {
    let facts: Vec<_> = closed.iter().map(|(item, machine)| item.rules_facts(machine)).collect();
    closed::newest_once(&facts).into_iter().filter(|index| *index < closed.len()).collect()
}

/// Every close the row of `target` stands for among `closed` (`closes(of:among:)`): for a page
/// every close of it, so removing the row leaves none to take its place; else `target` alone.
/// `None` in the answer stands for `target` itself (it is not among `closed`); indices are
/// into `closed`.
pub fn closes(target: (&ClosedItem, &str), closed: &[(&ClosedItem, &str)]) -> Vec<Option<usize>> {
    let mut facts = vec![target.0.rules_facts(target.1)];
    facts.extend(closed.iter().map(|(item, machine)| item.rules_facts(machine)));
    let others: Vec<Option<usize>> = closed::closes(0, &facts)
        .into_iter()
        .filter(|index| *index > 0 && *index <= closed.len())
        .map(|index| Some(index - 1))
        .collect();
    if others.is_empty() { vec![None] } else { others }
}
