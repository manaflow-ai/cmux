//! App-wide window membership and lifecycle, moved from the app's Swift `WindowRegistry`
//! (`Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Windows/WindowRegistry.swift`): which
//! workspaces each window's sidebar shows, and which windows exist.
//!
//! Invariants: a window exists only while it lists at least one workspace; every workspace is owned
//! by at most one window, and every live workspace by exactly one after [`Registry::reconcile`]. A
//! window lists, besides the workspaces it owns, the workspaces of its current space that another
//! open window owns, as `guests` ([`Registry::set_guests`]); closing the owner's window hands such a
//! workspace to the first open window that lists it. Every transition that takes a window's last
//! workspace removes that window in the same step. Closing a window keeps it registered, closed,
//! still owning its workspaces (one closed group); with `keeps_group` false a non-last window's
//! workspaces move to the most recent other open window instead.
//!
//! Incognito windows are their own kind: no workspace moves between an incognito window and a
//! normal one, closing one discards its workspaces, and orphans go to a window of their kind only.
//!
//! Pure value type: every transition mutates the registry and returns the [`Changes`] the app
//! animates. `schemas/window-registry/vectors.json` has action sequences with the answers the Swift
//! type gave; `window_registry_tests.rs` mirrors its tests.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

/// An AppKit screen frame (bottom-left origin).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Frame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub id: String,
    /// Owned and guest workspace ids, in daemon sidebar order as of the last membership transition.
    /// Never empty for a registered window.
    #[serde(default)]
    pub workspace_ids: Vec<String>,
    /// The listed workspaces another open window owns; always a subset of `workspace_ids`.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub guests: BTreeSet<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame: Option<Frame>,
    /// Display the window was on (`CGDisplayCreateUUIDFromDisplayID`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display: Option<String>,
    /// False after the user closed it: kept so its workspaces stay restorable.
    #[serde(default = "yes")]
    pub is_open: bool,
}

fn yes() -> bool {
    true
}

impl Window {
    pub fn new(id: impl Into<String>, workspace_ids: Vec<String>) -> Self {
        Window {
            id: id.into(),
            workspace_ids,
            guests: BTreeSet::new(),
            frame: None,
            display: None,
            is_open: true,
        }
    }

    /// The workspaces this window owns: `workspace_ids` without its guests.
    pub fn owned_ids(&self) -> Vec<String> {
        if self.guests.is_empty() {
            return self.workspace_ids.clone();
        }
        self.workspace_ids.iter().filter(|id| !self.guests.contains(*id)).cloned().collect()
    }
}

/// What a transition did, for animation and focus.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Changes {
    /// Windows removed because they lost their last workspace.
    #[serde(default)]
    pub emptied: Vec<String>,
    /// Workspaces whose owner changed, by new owner.
    #[serde(default)]
    pub moved: BTreeMap<String, Vec<String>>,
    /// Workspaces of a closed incognito window: no window lists them any more, and the caller
    /// closes them.
    #[serde(default)]
    pub discarded: Vec<String>,
}

impl Changes {
    pub fn is_empty(&self) -> bool {
        self.emptied.is_empty() && self.moved.is_empty() && self.discarded.is_empty()
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Registry {
    /// Creation order.
    #[serde(default)]
    pub windows: Vec<Window>,
    /// Window ids, front first.
    #[serde(default)]
    pub recency: Vec<String>,
    /// Incognito windows, registered or about to be.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub incognito: BTreeSet<String>,
    /// Workspaces of closed incognito windows until the daemons stop reporting them.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub discarding: BTreeSet<String>,
}

/// `ids` plus `adding`, placed by `rank` (unranked entries keep their spot after the ranked ones).
pub fn merged(ids: &[String], adding: &[String], rank: &HashMap<&str, usize>) -> Vec<String> {
    let mut items: Vec<(usize, &String)> = ids.iter().chain(adding).enumerate().collect();
    items.sort_by_key(|(offset, element)| match rank.get(element.as_str()) {
        Some(r) => (0, *r, 0),
        None => (1, 0, *offset),
    });
    items.into_iter().map(|(_, element)| element.clone()).collect()
}

fn rank_of(live: &[String]) -> HashMap<&str, usize> {
    let mut rank = HashMap::with_capacity(live.len());
    for (index, id) in live.iter().enumerate() {
        rank.entry(id.as_str()).or_insert(index);
    }
    rank
}

impl Registry {
    pub fn new(windows: Vec<Window>) -> Self {
        let recency = windows.iter().map(|w| w.id.clone()).collect();
        Registry { windows, recency, ..Default::default() }
    }

    /// Owning window by workspace id: the first window that lists it as its own, never as a guest.
    pub fn owners(&self) -> HashMap<&str, &str> {
        let mut owners = HashMap::new();
        for window in &self.windows {
            for id in &window.workspace_ids {
                if !window.guests.contains(id) {
                    owners.entry(id.as_str()).or_insert(window.id.as_str());
                }
            }
        }
        owners
    }

    // Queries

    pub fn window(&self, id: &str) -> Option<&Window> {
        self.windows.iter().find(|w| w.id == id)
    }

    fn index(&self, id: &str) -> Option<usize> {
        self.windows.iter().position(|w| w.id == id)
    }

    pub fn owner(&self, workspace: &str) -> Option<&str> {
        self.windows
            .iter()
            .find(|w| {
                !w.guests.contains(workspace) && w.workspace_ids.iter().any(|id| id == workspace)
            })
            .map(|w| w.id.as_str())
    }

    /// Whether window `id` lists `workspace`, as its own or as a guest.
    pub fn lists(&self, workspace: &str, id: &str) -> bool {
        self.owner(workspace) == Some(id) || self.is_guest(workspace, id)
    }

    /// Whether window `id` lists `workspace` as a guest.
    pub fn is_guest(&self, workspace: &str, id: &str) -> bool {
        self.window(id).is_some_and(|w| w.guests.contains(workspace))
    }

    pub fn open_windows(&self) -> impl Iterator<Item = &Window> {
        self.windows.iter().filter(|w| w.is_open)
    }

    /// The open windows' ids, front first.
    pub fn open_recency(&self) -> Vec<String> {
        self.recency
            .iter()
            .filter(|id| self.window(id).is_some_and(|w| w.is_open))
            .cloned()
            .collect()
    }

    /// The most recently active open window of the `wanted` kind (normal unless true), excluding
    /// `excluded`.
    pub fn most_recent_open(&self, excluded: &[String], wanted: bool) -> Option<String> {
        let open: HashSet<&str> = self
            .open_windows()
            .filter(|w| self.is_incognito(&w.id) == wanted && !excluded.contains(&w.id))
            .map(|w| w.id.as_str())
            .collect();
        self.recency
            .iter()
            .find(|id| open.contains(id.as_str()))
            .or_else(|| self.windows.iter().map(|w| &w.id).find(|id| open.contains(id.as_str())))
            .cloned()
    }

    /// The most recently active of `ids` (the first such on ties and for unknown ids), None when
    /// empty.
    pub fn most_recent(&self, ids: &[String]) -> Option<String> {
        let place = |id: &String| self.recency.iter().position(|r| r == id).unwrap_or(usize::MAX);
        let mut best = ids.first()?;
        for id in &ids[1..] {
            if place(id) < place(best) {
                best = id;
            }
        }
        Some(best.clone())
    }

    pub fn is_incognito(&self, id: &str) -> bool {
        self.incognito.contains(id)
    }

    /// True when moving `workspace_ids` into window `id` would cross between an incognito window
    /// and a normal one (a workspace no window lists crosses nothing).
    pub fn crosses_incognito(&self, workspace_ids: &[String], id: &str) -> bool {
        let target = self.is_incognito(id);
        let owners = self.owners();
        workspace_ids
            .iter()
            .any(|w| owners.get(w.as_str()).is_some_and(|o| self.is_incognito(o) != target))
    }

    /// Descriptions of broken invariants (empty when consistent).
    pub fn violations(&self) -> Vec<String> {
        let mut seen: HashMap<&str, &str> = HashMap::new();
        let mut problems = Vec::new();
        for window in &self.windows {
            for id in &window.workspace_ids {
                if window.guests.contains(id) {
                    continue;
                }
                if let Some(other) = seen.get(id.as_str()) {
                    problems.push(format!("{id} owned by {other} and {}", window.id));
                }
                seen.insert(id, &window.id);
            }
            if !window.guests.iter().all(|g| window.workspace_ids.contains(g)) {
                problems.push(format!("{} has a guest it does not list", window.id));
            }
        }
        for window in &self.windows {
            for id in &window.guests {
                if seen.get(id.as_str()).is_none_or(|o| *o == window.id) {
                    problems.push(format!("{id} is a guest of {} with no other owner", window.id));
                }
            }
        }
        let ids: HashSet<&str> = self.windows.iter().map(|w| w.id.as_str()).collect();
        if ids.len() != self.windows.len() {
            problems.push("duplicate window ids".to_string());
        }
        let recency: HashSet<&str> = self.recency.iter().map(String::as_str).collect();
        if recency != ids || self.recency.len() != self.windows.len() {
            problems.push("recency out of sync".to_string());
        }
        for window in &self.windows {
            if window.workspace_ids.is_empty() {
                problems.push(format!("{} has no workspaces", window.id));
            }
        }
        problems
    }

    // Lifecycle

    /// Registers a new open window owning `workspace_ids` (taken from their current owners) and
    /// makes it the most recent; one opened `behind` is the least recent instead. A known id moves
    /// them into it. With no workspaces nothing is registered. Workspaces taken from incognito
    /// windows make the new window incognito; a mix of both kinds, or normal workspaces for a
    /// window marked incognito, opens nothing.
    pub fn open_window(
        &mut self,
        id: &str,
        workspace_ids: &[String],
        frame: Option<Frame>,
        display: Option<String>,
        behind: bool,
    ) -> Changes {
        if self.window(id).is_some() {
            return self.move_into(workspace_ids, id, None);
        }
        if workspace_ids.is_empty() {
            return Changes::default();
        }
        let kinds: BTreeSet<bool> = {
            let owners = self.owners();
            workspace_ids
                .iter()
                .filter_map(|w| owners.get(w.as_str()).map(|o| self.is_incognito(o)))
                .collect()
        };
        let only_normal = kinds.len() == 1 && kinds.contains(&false);
        if kinds.len() > 1 || (self.is_incognito(id) && only_normal) {
            return Changes::default();
        }
        if kinds.len() == 1 && kinds.contains(&true) {
            self.incognito.insert(id.to_string());
        }
        let mut changes = Changes::default();
        let taken = self.detach(workspace_ids, None);
        let mut window = Window::new(id, taken.clone());
        window.frame = frame;
        window.display = display;
        self.windows.push(window);
        if behind {
            self.recency.push(id.to_string());
        } else {
            self.recency.insert(0, id.to_string());
        }
        changes.moved.insert(id.to_string(), taken);
        changes.emptied = self.close_emptied();
        changes
    }

    /// The user closed `id`: a normal window stays registered, closed, with its workspaces (one
    /// closed group), after handing what another open window also lists to the first such window.
    /// With `keeps_group` false a non-last window's workspaces move to the most recent other open
    /// window. An incognito window closes for good, and its workspaces are `discarded`.
    pub fn close(&mut self, id: &str, keeps_group: bool) -> Changes {
        let Some(index) = self.index(id) else { return Changes::default() };
        if self.is_incognito(id) {
            let changes = Changes {
                discarded: self.windows[index].workspace_ids.clone(),
                ..Changes::default()
            };
            self.discarding.extend(changes.discarded.iter().cloned());
            self.remove(id);
            return changes;
        }
        if !keeps_group && let Some(heir) = self.most_recent_open(&[id.to_string()], false) {
            return self.merge(id, &heir);
        }
        let mut changes = self.hand_over_shared(id);
        let Some(closing) = self.index(id) else { return changes };
        if self.windows[closing].workspace_ids.is_empty() {
            self.remove(id);
            changes.emptied.push(id.to_string());
            return changes;
        }
        self.windows[closing].is_open = false;
        self.activate(id);
        changes
    }

    /// Closed window `id`'s group was deleted: its workspaces move to the most recent open window
    /// of its kind, else it opens again.
    pub fn release_closed(&mut self, id: &str) -> Changes {
        if self.window(id).is_none_or(|w| w.is_open) {
            return Changes::default();
        }
        match self.most_recent_open(&[id.to_string()], self.is_incognito(id)) {
            Some(heir) => self.merge(id, &heir),
            None => {
                self.reopen_id(id);
                Changes::default()
            }
        }
    }

    /// Window `id` stops being a view: each workspace it owns that another open window lists as a
    /// guest is owned by the first such window from now on, and `id` lists none of its guests.
    fn hand_over_shared(&mut self, id: &str) -> Changes {
        let mut changes = Changes::default();
        let Some(closing) = self.window(id) else { return changes };
        let owned = closing.owned_ids();
        let mut handed = HashSet::new();
        for workspace in owned {
            let Some(heir) = self
                .windows
                .iter()
                .position(|w| w.id != id && w.is_open && w.guests.contains(&workspace))
            else {
                continue;
            };
            self.windows[heir].guests.remove(&workspace);
            changes.moved.entry(self.windows[heir].id.clone()).or_default().push(workspace.clone());
            handed.insert(workspace);
        }
        if let Some(index) = self.index(id) {
            let window = &mut self.windows[index];
            let guests = std::mem::take(&mut window.guests);
            window.workspace_ids.retain(|w| !handed.contains(w) && !guests.contains(w));
        }
        changes
    }

    /// Opens window `id` as a view only: it lists `guests`, workspaces other open normal windows
    /// own, and owns none. Nothing moves. With no such workspace, or for a known id, nothing opens.
    pub fn open_view(&mut self, id: &str, guests: &[String]) {
        if self.window(id).is_some() {
            return;
        }
        let mut seen = BTreeSet::new();
        let shared: Vec<String> = {
            let owners = self.owners();
            guests
                .iter()
                .filter(|workspace| {
                    let Some(owner) = owners.get(workspace.as_str()) else { return false };
                    if self.is_incognito(owner) || !self.window(owner).is_some_and(|w| w.is_open) {
                        return false;
                    }
                    seen.insert((*workspace).clone())
                })
                .cloned()
                .collect()
        };
        if shared.is_empty() {
            return;
        }
        let mut view = Window::new(id, shared);
        view.guests = seen;
        self.windows.push(view);
        self.recency.insert(0, id.to_string());
    }

    /// Makes window `id` list exactly `guests` as its guests, keeping the ones it owns. Ids `id`
    /// owns, that no other window owns, or of a closed or unknown window are skipped. A window
    /// that owns nothing keeps the guests it has when the new set is empty.
    pub fn set_guests(&mut self, guests: &[String], id: &str) {
        let Some(index) = self.index(id) else { return };
        if !self.windows[index].is_open {
            return;
        }
        let wanted: BTreeSet<String> = {
            let owners = self.owners();
            guests
                .iter()
                .filter(|w| owners.get(w.as_str()).is_some_and(|o| *o != id))
                .cloned()
                .collect()
        };
        if wanted == self.windows[index].guests {
            return;
        }
        let mut window = self.windows[index].clone();
        window.workspace_ids.retain(|w| !window.guests.contains(w) || wanted.contains(w));
        let mut listed: HashSet<String> = window.workspace_ids.iter().cloned().collect();
        for workspace in guests {
            if wanted.contains(workspace) && listed.insert(workspace.clone()) {
                window.workspace_ids.push(workspace.clone());
            }
        }
        if window.workspace_ids.is_empty() {
            return;
        }
        window.guests = wanted;
        self.windows[index] = window;
    }

    /// Moves every workspace `id` owns into `heir` and removes `id`.
    fn merge(&mut self, id: &str, heir: &str) -> Changes {
        let mut changes = Changes::default();
        let orphans = self.window(id).map(Window::owned_ids).unwrap_or_default();
        self.detach(&orphans, Some(heir));
        self.remove(id);
        if !orphans.is_empty()
            && let Some(heir_index) = self.index(heir)
        {
            self.windows[heir_index].workspace_ids.extend(orphans.iter().cloned());
            changes.moved.insert(heir.to_string(), orphans);
        }
        changes
    }

    /// Opens the most recent closed normal window again; its id, or None when none is closed.
    pub fn reopen(&mut self) -> Option<String> {
        let id = self
            .recency
            .iter()
            .find(|id| self.window(id).is_some_and(|w| !w.is_open) && !self.is_incognito(id))?
            .clone();
        let index = self.index(&id)?;
        self.windows[index].is_open = true;
        self.activate(&id);
        Some(id)
    }

    /// Marks restored window `id` open or closed.
    pub fn set_restored(&mut self, id: &str, open: bool) {
        if let Some(index) = self.index(id) {
            self.windows[index].is_open = open;
        }
    }

    /// Opens closed window `id` again; false when it is not a closed window.
    pub fn reopen_id(&mut self, id: &str) -> bool {
        let Some(index) = self.index(id) else { return false };
        if self.windows[index].is_open {
            return false;
        }
        self.windows[index].is_open = true;
        self.activate(id);
        true
    }

    pub fn activate(&mut self, id: &str) {
        if self.window(id).is_none() {
            return;
        }
        self.recency.retain(|r| r != id);
        self.recency.insert(0, id.to_string());
    }

    /// Window `id` was ordered in behind the app's other windows.
    pub fn move_to_back(&mut self, id: &str) {
        if self.window(id).is_some() {
            self.recency.retain(|r| r != id);
            self.recency.push(id.to_string());
        }
    }

    pub fn set_geometry(&mut self, id: &str, frame: Option<Frame>, display: Option<String>) {
        let Some(index) = self.index(id) else { return };
        self.windows[index].frame = frame;
        if let Some(display) = display {
            self.windows[index].display = Some(display);
        }
    }

    // Membership

    /// Moves `workspace_ids` into window `id`, before `anchor` when it is already there (else
    /// appended). Windows left empty close. Nothing moves across incognito and normal windows.
    pub fn move_into(
        &mut self,
        workspace_ids: &[String],
        id: &str,
        anchor: Option<&str>,
    ) -> Changes {
        if self.window(id).is_none()
            || workspace_ids.is_empty()
            || self.crosses_incognito(workspace_ids, id)
        {
            return Changes::default();
        }
        let mut changes = Changes::default();
        let taken = self.detach(workspace_ids, Some(id));
        let Some(index) = self.index(id) else { return changes };
        let ids = &mut self.windows[index].workspace_ids;
        let slot = anchor.and_then(|a| ids.iter().position(|w| w == a)).unwrap_or(ids.len());
        ids.splice(slot..slot, taken.iter().cloned());
        changes.moved.insert(id.to_string(), taken);
        changes.emptied = self.close_emptied();
        changes
    }

    /// Brings membership in line with the daemons: drops `dead` workspaces, orders each window like
    /// `live`, and gives orphans to their `placements` window (an open one takes it, an
    /// unregistered one opens with it, behind the others when in `behind`); other orphans go to the
    /// most recent open window, else the most recent normal one, else `fallback_window`. `held`
    /// orphans stay unowned this time. Windows left empty close.
    pub fn reconcile(
        &mut self,
        live: &[String],
        dead: &BTreeSet<String>,
        placements: &BTreeMap<String, String>,
        held: &BTreeSet<String>,
        behind: &BTreeSet<String>,
        fallback_window: &str,
    ) -> Changes {
        let mut changes = Changes::default();
        let rank = rank_of(live);
        for window in &mut self.windows {
            let kept: Vec<String> =
                window.workspace_ids.iter().filter(|w| !dead.contains(*w)).cloned().collect();
            window.workspace_ids = merged(&kept, &[], &rank);
            if !window.guests.is_empty() {
                window.guests.retain(|g| !dead.contains(g));
            }
        }
        let live_set: HashSet<&str> = live.iter().map(String::as_str).collect();
        self.discarding.retain(|d| live_set.contains(d.as_str()) && !dead.contains(d));
        let owned: HashSet<String> = self
            .owners()
            .keys()
            .map(|k| k.to_string())
            .chain(self.discarding.iter().cloned())
            .collect();
        let mut heirs: Vec<String> = Vec::new();
        let mut moved: HashMap<String, Vec<String>> = HashMap::new();
        for orphan in live {
            if owned.contains(orphan) || held.contains(orphan) {
                continue;
            }
            let claimed = placements
                .get(orphan)
                .and_then(|window| self.placement_window(window, behind.contains(window)));
            let heir = match claimed {
                Some(heir) => heir,
                None => match self.most_recent_open(&[], false) {
                    Some(heir) => heir,
                    None => match self.recency.iter().find(|r| !self.is_incognito(r)) {
                        Some(heir) => heir.clone(),
                        None => self.register(fallback_window, false),
                    },
                },
            };
            if self.window(&heir).is_none() {
                continue;
            }
            if !moved.contains_key(&heir) {
                heirs.push(heir.clone());
            }
            moved.entry(heir).or_default().push(orphan.clone());
        }
        for heir in &heirs {
            let (Some(index), Some(orphans)) = (self.index(heir), moved.get(heir)) else {
                continue;
            };
            self.windows[index].workspace_ids =
                merged(&self.windows[index].workspace_ids, orphans, &rank);
        }
        changes.moved = moved.into_iter().collect();
        changes.emptied = self.close_emptied();
        changes
    }

    /// A gather: moves `workspace_ids` into window `id`, then removes those of `givers` that own
    /// no workspace any more. A view that never owned one is no giver and stays.
    pub fn gather(&mut self, workspace_ids: &[String], id: &str, givers: &[String]) -> Changes {
        let mut changes = self.move_into(workspace_ids, id, None);
        let emptied: Vec<String> = givers
            .iter()
            .filter(|g| *g != id && self.window(g).is_some_and(|w| w.owned_ids().is_empty()))
            .cloned()
            .collect();
        for giver in &emptied {
            self.remove(giver);
        }
        changes.emptied.extend(emptied);
        changes
    }

    /// Orders each window's workspaces like `live`; those not in it keep their place after.
    pub fn order(&mut self, live: &[String]) {
        let rank = rank_of(live);
        for window in &mut self.windows {
            window.workspace_ids = merged(&window.workspace_ids, &[], &rank);
        }
    }

    // Internals

    /// Takes `ids` from the windows that own them and from `destination` (which lists them as its
    /// own next); returns them in the given order, without duplicates. Another window that lists
    /// one as a guest keeps it.
    fn detach(&mut self, ids: &[String], destination: Option<&str>) -> Vec<String> {
        let mut unique = Vec::new();
        let mut set = HashSet::new();
        for id in ids {
            if set.insert(id.as_str()) {
                unique.push(id.clone());
            }
        }
        for window in &mut self.windows {
            let is_destination = Some(window.id.as_str()) == destination;
            let guests = &window.guests;
            window
                .workspace_ids
                .retain(|w| !set.contains(w.as_str()) || (!is_destination && guests.contains(w)));
            if is_destination {
                window.guests.retain(|g| !set.contains(g.as_str()));
            }
        }
        unique
    }

    fn remove(&mut self, id: &str) {
        self.windows.retain(|w| w.id != id);
        self.recency.retain(|r| r != id);
        self.incognito.remove(id);
    }

    /// Workspaces of incognito windows from a run that ended without closing them.
    pub fn mark_discarding(&mut self, ids: &[String]) {
        self.discarding.extend(ids.iter().cloned());
    }

    /// Marks window `id` incognito.
    pub fn mark_incognito(&mut self, id: &str) {
        self.incognito.insert(id.to_string());
    }

    /// The window a claimed orphan goes to: its window when open, or a new open window with that
    /// id when none is registered. A claim on a closed window falls through.
    fn placement_window(&mut self, id: &str, behind: bool) -> Option<String> {
        match self.window(id) {
            None => Some(self.register(id, behind)),
            Some(existing) => existing.is_open.then(|| id.to_string()),
        }
    }

    /// Registers open window `id` with no workspace yet; `close_emptied` removes it unless its
    /// caller gives it one in the same transition.
    fn register(&mut self, id: &str, behind: bool) -> String {
        self.windows.push(Window::new(id, Vec::new()));
        if behind {
            self.recency.push(id.to_string());
        } else {
            self.recency.insert(0, id.to_string());
        }
        id.to_string()
    }

    /// Removes every window left with no workspace.
    fn close_emptied(&mut self) -> Vec<String> {
        let closed: Vec<String> = self
            .windows
            .iter()
            .filter(|w| w.workspace_ids.is_empty())
            .map(|w| w.id.clone())
            .collect();
        for id in &closed {
            self.remove(id);
        }
        closed
    }
}

/// One transition or query, as the app asks it over the JSON channel.
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Action {
    OpenWindow {
        id: String,
        #[serde(default)]
        workspace_ids: Vec<String>,
        #[serde(default)]
        frame: Option<Frame>,
        #[serde(default)]
        display: Option<String>,
        #[serde(default)]
        behind: bool,
    },
    Close {
        id: String,
        #[serde(default = "yes")]
        keeps_group: bool,
    },
    ReleaseClosed {
        id: String,
    },
    OpenView {
        id: String,
        #[serde(default)]
        guests: Vec<String>,
    },
    SetGuests {
        id: String,
        #[serde(default)]
        guests: Vec<String>,
    },
    Reopen,
    ReopenId {
        id: String,
    },
    SetRestored {
        id: String,
        open: bool,
    },
    Activate {
        id: String,
    },
    MoveToBack {
        id: String,
    },
    SetGeometry {
        id: String,
        #[serde(default)]
        frame: Option<Frame>,
        #[serde(default)]
        display: Option<String>,
    },
    Move {
        id: String,
        #[serde(default)]
        workspace_ids: Vec<String>,
        #[serde(default)]
        anchor: Option<String>,
    },
    Reconcile {
        #[serde(default)]
        live: Vec<String>,
        #[serde(default)]
        dead: BTreeSet<String>,
        #[serde(default)]
        placements: BTreeMap<String, String>,
        #[serde(default)]
        held: BTreeSet<String>,
        #[serde(default)]
        behind: BTreeSet<String>,
        fallback_window: String,
    },
    Gather {
        id: String,
        #[serde(default)]
        workspace_ids: Vec<String>,
        #[serde(default)]
        givers: Vec<String>,
    },
    Order {
        #[serde(default)]
        live: Vec<String>,
    },
    MarkDiscarding {
        #[serde(default)]
        ids: Vec<String>,
    },
    MarkIncognito {
        id: String,
    },
    Violations,
    MostRecentOpen {
        #[serde(default)]
        excluding: Vec<String>,
        #[serde(default)]
        incognito: bool,
    },
    MostRecent {
        #[serde(default)]
        ids: Vec<String>,
    },
    CrossesIncognito {
        id: String,
        #[serde(default)]
        workspace_ids: Vec<String>,
    },
    Owner {
        workspace: String,
    },
}

/// The answer to one [`Action`]: the registry after it, what it changed, and a query's value
/// (`reopen`'s id, `reopenId`'s bool, a query's answer; null otherwise).
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Applied {
    pub registry: Registry,
    pub changes: Changes,
    pub value: serde_json::Value,
}

impl Registry {
    /// Runs `action` on the registry; its changes and value.
    pub fn apply(&mut self, action: Action) -> (Changes, serde_json::Value) {
        use serde_json::{Value, json};
        let mut value = Value::Null;
        let changes = match action {
            Action::OpenWindow { id, workspace_ids, frame, display, behind } => {
                self.open_window(&id, &workspace_ids, frame, display, behind)
            }
            Action::Close { id, keeps_group } => self.close(&id, keeps_group),
            Action::ReleaseClosed { id } => self.release_closed(&id),
            Action::OpenView { id, guests } => {
                self.open_view(&id, &guests);
                Changes::default()
            }
            Action::SetGuests { id, guests } => {
                self.set_guests(&guests, &id);
                Changes::default()
            }
            Action::Reopen => {
                value = json!(self.reopen());
                Changes::default()
            }
            Action::ReopenId { id } => {
                value = json!(self.reopen_id(&id));
                Changes::default()
            }
            Action::SetRestored { id, open } => {
                self.set_restored(&id, open);
                Changes::default()
            }
            Action::Activate { id } => {
                self.activate(&id);
                Changes::default()
            }
            Action::MoveToBack { id } => {
                self.move_to_back(&id);
                Changes::default()
            }
            Action::SetGeometry { id, frame, display } => {
                self.set_geometry(&id, frame, display);
                Changes::default()
            }
            Action::Move { id, workspace_ids, anchor } => {
                self.move_into(&workspace_ids, &id, anchor.as_deref())
            }
            Action::Reconcile { live, dead, placements, held, behind, fallback_window } => {
                self.reconcile(&live, &dead, &placements, &held, &behind, &fallback_window)
            }
            Action::Gather { id, workspace_ids, givers } => {
                self.gather(&workspace_ids, &id, &givers)
            }
            Action::Order { live } => {
                self.order(&live);
                Changes::default()
            }
            Action::MarkDiscarding { ids } => {
                self.mark_discarding(&ids);
                Changes::default()
            }
            Action::MarkIncognito { id } => {
                self.mark_incognito(&id);
                Changes::default()
            }
            Action::Violations => {
                value = json!(self.violations());
                Changes::default()
            }
            Action::MostRecentOpen { excluding, incognito } => {
                value = json!(self.most_recent_open(&excluding, incognito));
                Changes::default()
            }
            Action::MostRecent { ids } => {
                value = json!(self.most_recent(&ids));
                Changes::default()
            }
            Action::CrossesIncognito { id, workspace_ids } => {
                value = json!(self.crosses_incognito(&workspace_ids, &id));
                Changes::default()
            }
            Action::Owner { workspace } => {
                value = json!(self.owner(&workspace));
                Changes::default()
            }
        };
        (changes, value)
    }
}
