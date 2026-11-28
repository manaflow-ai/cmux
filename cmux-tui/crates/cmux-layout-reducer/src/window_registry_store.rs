//! The app's window registry holder and its launch memories, moved from the Swift files beside
//! `WindowRegistry.swift` in `Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Windows/`:
//!
//! - [`Store`] (`WindowRegistryStore.swift`): the registry, the launch snapshot's provisional
//!   membership, each workspace's answered window kind and owner (written only where the answer
//!   changed, counted in [`MembershipWork`]), the gather sources, and what closes read of it
//!   ([`CloseWork`], `WorkspaceCloseWork.swift`).
//! - [`Store::repaired_selection_kept`] and [`Store::settle_owner`] (`WindowRegistry+Selection.swift`):
//!   the selection a membership change keeps with no pick, and the owner a close's settle reads.
//! - [`RestoreClosed`] (`RestoreClosedWindows.swift`): the windows the person closed while the
//!   launch's restore ran.
//! - [`Claims`] (`WorkspaceClaims.swift`): new workspaces windows asked for before the daemon
//!   reported them.
//!
//! Pure values: the app's observed maps become plain maps here, and each write the Swift store made
//! to one is a write here, counted the same. `schemas/window-registry-store/vectors.json` has
//! action sequences with the answers the Swift types gave; `window_registry_store_tests.rs` mirrors
//! their tests.

use crate::window_registry::{Action, Changes, Registry, Window};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fmt;

/// What a Close Workspace reads of the window registry (`WorkspaceCloseWork`): one close of a shown
/// workspace does work O(shown + changed), in a large session as in a small one.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloseWork {
    /// Windows a selection repair visited ([`Store::repairs`]).
    #[serde(default)]
    pub repaired_windows: u64,
    /// The workspaces those windows list.
    #[serde(default)]
    pub repaired_ids: u64,
    /// Runs of a window's `showWorkspace` ([`Store::unlisted`]).
    #[serde(default)]
    pub show_calls: u64,
    /// The workspace ids those runs read.
    #[serde(default)]
    pub shown_ids: u64,
}

impl fmt::Display for CloseWork {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "repaired windows {}, repaired ids {}, show calls {}, shown ids {}",
            self.repaired_windows, self.repaired_ids, self.show_calls, self.shown_ids
        )
    }
}

/// What membership turns did (`WindowMembershipWork`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MembershipWork {
    /// Builds of a daemon's workspace order ([`Store::order_build`]).
    #[serde(default)]
    pub order_builds: u64,
    /// Writes of an observed per-workspace answer.
    #[serde(default)]
    pub answer_writes: u64,
}

impl fmt::Display for MembershipWork {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "order builds {}, answer writes {}", self.order_builds, self.answer_writes)
    }
}

/// A workspace's window kind and owner, as last written.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Answer {
    pub incognito: bool,
    #[serde(default)]
    pub owner: Option<String>,
}

/// The holder of the app's registry (`WindowRegistryStore`), owned by its `WindowManager`, the
/// only writer.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Store {
    #[serde(default)]
    pub value: Registry,
    /// Membership of windows drawn from the daemon's launch snapshot before the live registry is
    /// restored; cleared by the restore ([`Store::clear_provisional`]).
    #[serde(default)]
    pub provisional: BTreeMap<String, Vec<String>>,
    /// True from the launch window until the saved windows are restored from the live tree.
    #[serde(default)]
    pub is_launching: bool,
    /// Each workspace's window kind: true while an incognito window lists it or it is discarded,
    /// false while a normal window lists it, absent while no window does.
    #[serde(default)]
    pub incognito_by_workspace: BTreeMap<String, bool>,
    /// The window that lists each workspace (`Registry::owner`), absent while none does.
    #[serde(default)]
    pub owner_by_workspace: BTreeMap<String, String>,
    /// The kind and owner last written for each workspace they answer for.
    #[serde(default)]
    pub answered: BTreeMap<String, Answer>,
    /// Windows that list no guests until they next enter a space outside a gather.
    #[serde(default)]
    pub gather_sources: BTreeSet<String>,
    #[serde(default)]
    pub gathering: bool,
    #[serde(default)]
    pub close_work: CloseWork,
    #[serde(default)]
    pub membership_work: MembershipWork,
}

/// Whether `old` and `new` give every workspace the same window kind and owner.
fn same_answers(old: &Registry, new: &Registry) -> bool {
    old.incognito == new.incognito
        && old.discarding == new.discarding
        && old.windows.len() == new.windows.len()
        && old.windows.iter().zip(&new.windows).all(|(a, b)| {
            a.id == b.id && a.workspace_ids == b.workspace_ids && a.guests == b.guests
        })
}

impl Store {
    pub fn new() -> Self {
        Store::default()
    }

    /// A Move Space into window `id` that takes workspaces from `givers` begins: the givers stop
    /// viewing shared spaces, `id` views them again ([`Store::gather`]).
    pub fn gather_begin(&mut self, id: &str, givers: &[String]) {
        self.gather_sources.remove(id);
        self.gather_sources.extend(givers.iter().cloned());
        self.gathering = true;
    }

    /// The gather ended: sources no longer registered are dropped.
    pub fn gather_end(&mut self) {
        self.gathering = false;
        let value = &self.value;
        self.gather_sources.retain(|id| value.window(id).is_some());
    }

    /// Runs `body`, a Move Space into window `id` that takes workspaces from `givers`; a space the
    /// gather's own repairs give a window does not end its entry.
    pub fn gather<T>(
        &mut self,
        id: &str,
        givers: &[String],
        body: impl FnOnce(&mut Self) -> T,
    ) -> T {
        self.gather_begin(id, givers);
        let result = body(self);
        self.gather_end();
        result
    }

    /// Window `id` entered a space: outside a gather it views shared spaces again.
    pub fn space_entered(&mut self, id: &str) {
        if !self.gathering {
            self.gather_sources.remove(id);
        }
    }

    /// Window `id`, opened for moved content, lists only its own workspaces until it enters a space.
    pub fn hold_own_space(&mut self, id: &str) {
        self.gather_sources.insert(id.to_string());
    }

    /// Whether window `id` is one the launch brings back (the launch window, or one of the `saved`
    /// windows) while the launch runs.
    pub fn restores_session(
        &self,
        id: &str,
        launch_window: Option<&str>,
        saved: Option<&[String]>,
    ) -> bool {
        self.is_launching
            && (Some(id) == launch_window || saved.is_some_and(|s| s.iter().any(|w| w == id)))
    }

    /// Runs one transition on a copy of the registry; when the registry changed, takes it and
    /// writes the answers that changed. Returns what the transition returned.
    pub fn apply<T>(&mut self, transition: impl FnOnce(&mut Registry) -> T) -> T {
        let mut next = self.value.clone();
        let result = transition(&mut next);
        if next != self.value {
            let before = std::mem::replace(&mut self.value, next);
            if !same_answers(&before, &self.value) {
                self.refresh_workspace_answers();
            }
        }
        result
    }

    /// Drops every launch-snapshot membership.
    pub fn clear_provisional(&mut self) {
        self.provisional.clear();
    }

    /// Workspaces window `id` lists, in order.
    pub fn members(&self, id: &str) -> Vec<String> {
        match self.value.window(id) {
            Some(window) => window.workspace_ids.clone(),
            None => self.provisional.get(id).cloned().unwrap_or_default(),
        }
    }

    /// The close counts since the last call; counts from zero again.
    pub fn take_close_work(&mut self) -> CloseWork {
        std::mem::take(&mut self.close_work)
    }

    /// The membership counts since the last call; counts from zero again.
    pub fn take_membership_work(&mut self) -> MembershipWork {
        std::mem::take(&mut self.membership_work)
    }

    /// Runs one build of a daemon's workspace order, counted in `membership_work`.
    pub fn order_build<T>(&mut self, build: impl FnOnce() -> T) -> T {
        self.membership_work.order_builds += 1;
        build()
    }

    /// The windows a selection repair visits, counted in `close_work`: every window, or window
    /// `only` alone.
    pub fn repairs(&mut self, only: Option<&str>) -> Vec<Window> {
        let windows: Vec<Window> = match only {
            Some(id) => self.value.windows.iter().filter(|w| w.id == id).cloned().collect(),
            None => self.value.windows.clone(),
        };
        self.close_work.repaired_windows += windows.len() as u64;
        self.close_work.repaired_ids +=
            windows.iter().map(|w| w.workspace_ids.len() as u64).sum::<u64>();
        windows
    }

    /// The ones of `ids` (a window's parked workspaces) that window `id` does not list, counted in
    /// `close_work`. A window not registered yet answers from its launch snapshot.
    pub fn unlisted<'a>(
        &mut self,
        ids: impl IntoIterator<Item = &'a String>,
        id: &str,
    ) -> BTreeSet<String> {
        let registry = &self.value;
        let window = registry.window(id);
        let launch: HashSet<&str> = match window {
            None => self
                .provisional
                .get(id)
                .map(|ids| ids.iter().map(String::as_str).collect())
                .unwrap_or_default(),
            Some(_) => HashSet::new(),
        };
        let mut unlisted = BTreeSet::new();
        self.close_work.show_calls += 1;
        for workspace in ids {
            self.close_work.shown_ids += 1;
            let owner = registry.owner(workspace);
            if owner == Some(id) || window.is_some_and(|w| w.guests.contains(workspace)) {
                continue;
            }
            let mut listed = launch.contains(workspace.as_str());
            if let Some(window) = window
                && owner.is_some()
            {
                self.close_work.shown_ids += window.workspace_ids.len() as u64;
                listed = window.workspace_ids.contains(workspace);
            }
            if !listed {
                unlisted.insert(workspace.clone());
            }
        }
        unlisted
    }

    /// The window that lists `workspace`, as last answered.
    pub fn owner_of_workspace(&self, workspace: &str) -> Option<&str> {
        self.owner_by_workspace.get(workspace).map(String::as_str)
    }

    /// The window kind of `workspace`, as last answered.
    pub fn incognito_of_workspace(&self, workspace: &str) -> Option<bool> {
        self.incognito_by_workspace.get(workspace).copied()
    }

    /// The selection a membership change keeps with no pick (`WindowRegistry.repairedSelection`'s
    /// first step): the first of `preferred` that is a member, else `current` when it is a member;
    /// None means the close-selection rule picks.
    pub fn repaired_selection_kept(
        current: Option<&str>,
        members: &[String],
        preferred: &[String],
    ) -> Option<String> {
        preferred
            .iter()
            .find(|id| members.contains(id))
            .map(String::as_str)
            .or_else(|| current.filter(|id| members.iter().any(|m| m == id)))
            .map(str::to_string)
    }

    /// The owner a selection repair's settle reads for `workspace` after a change in `window`:
    /// `window` when it lists it (as its own or as a guest), else its owner.
    pub fn settle_owner(&self, window: &str, workspace: &str) -> Option<String> {
        if self.value.lists(workspace, window) {
            Some(window.to_string())
        } else {
            self.value.owner(workspace).map(str::to_string)
        }
    }

    /// Writes the window kind and owner of each workspace whose answer changed, and of no other.
    fn refresh_workspace_answers(&mut self) {
        let mut next: BTreeMap<String, Answer> = BTreeMap::new();
        for window in &self.value.windows {
            let incognito = self.value.is_incognito(&window.id);
            for id in &window.workspace_ids {
                if !next.contains_key(id) && !window.guests.contains(id) {
                    next.insert(id.clone(), Answer { incognito, owner: Some(window.id.clone()) });
                }
            }
        }
        for id in &self.value.discarding {
            let owner = next.get(id).and_then(|a| a.owner.clone());
            next.insert(id.clone(), Answer { incognito: true, owner });
        }
        for (id, old) in &self.answered {
            if next.contains_key(id) {
                continue;
            }
            self.incognito_by_workspace.remove(id);
            self.membership_work.answer_writes += 1;
            if old.owner.is_some() {
                self.owner_by_workspace.remove(id);
                self.membership_work.answer_writes += 1;
            }
        }
        for (id, answer) in &next {
            let old = self.answered.get(id);
            if old.map(|o| o.incognito) != Some(answer.incognito) {
                self.incognito_by_workspace.insert(id.clone(), answer.incognito);
                self.membership_work.answer_writes += 1;
            }
            // Swift's `old?.owner` flattens: a new workspace with no owner writes none.
            if old.and_then(|o| o.owner.as_ref()) != answer.owner.as_ref() {
                match &answer.owner {
                    Some(owner) => self.owner_by_workspace.insert(id.clone(), owner.clone()),
                    None => self.owner_by_workspace.remove(id),
                };
                self.membership_work.answer_writes += 1;
            }
        }
        self.answered = next;
    }
}

/// One store step, as the app asks it over the JSON channel (`registry_store_apply`).
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum StoreAction {
    /// One registry transition through [`Store::apply`].
    Apply {
        action: Action,
    },
    /// A transition that sets the whole registry.
    Replace {
        registry: Registry,
    },
    GatherBegin {
        id: String,
        #[serde(default)]
        givers: Vec<String>,
    },
    GatherEnd,
    SpaceEntered {
        id: String,
    },
    HoldOwnSpace {
        id: String,
    },
    SetLaunching {
        launching: bool,
    },
    /// Sets (or with no `ids`, drops) window `id`'s launch-snapshot membership.
    SetProvisional {
        id: String,
        #[serde(default)]
        ids: Option<Vec<String>>,
    },
    ClearProvisional,
    RestoresSession {
        id: String,
        #[serde(default)]
        launch_window: Option<String>,
        #[serde(default)]
        saved: Option<Vec<String>>,
    },
    Members {
        id: String,
    },
    TakeCloseWork,
    TakeMembershipWork,
    OrderBuild,
    Repairs {
        #[serde(default)]
        only: Option<String>,
    },
    Unlisted {
        id: String,
        #[serde(default)]
        ids: Vec<String>,
    },
    OwnerOfWorkspace {
        workspace: String,
    },
    IncognitoOfWorkspace {
        workspace: String,
    },
    RepairedSelectionKept {
        #[serde(default)]
        current: Option<String>,
        #[serde(default)]
        members: Vec<String>,
        #[serde(default)]
        preferred: Vec<String>,
    },
    SettleOwner {
        window: String,
        workspace: String,
    },
}

impl Store {
    /// Runs `action` on the store; the registry changes and the action's value (null for most).
    pub fn run(&mut self, action: StoreAction) -> (Changes, serde_json::Value) {
        use serde_json::{Value, json};
        let mut value = Value::Null;
        let mut changes = Changes::default();
        match action {
            StoreAction::Apply { action } => {
                (changes, value) = self.apply(|registry| registry.apply(action));
            }
            StoreAction::Replace { registry } => self.apply(|r| *r = registry),
            StoreAction::GatherBegin { id, givers } => self.gather_begin(&id, &givers),
            StoreAction::GatherEnd => self.gather_end(),
            StoreAction::SpaceEntered { id } => self.space_entered(&id),
            StoreAction::HoldOwnSpace { id } => self.hold_own_space(&id),
            StoreAction::SetLaunching { launching } => self.is_launching = launching,
            StoreAction::SetProvisional { id, ids } => match ids {
                Some(ids) => {
                    self.provisional.insert(id, ids);
                }
                None => {
                    self.provisional.remove(&id);
                }
            },
            StoreAction::ClearProvisional => self.clear_provisional(),
            StoreAction::RestoresSession { id, launch_window, saved } => {
                value =
                    json!(self.restores_session(&id, launch_window.as_deref(), saved.as_deref()));
            }
            StoreAction::Members { id } => value = json!(self.members(&id)),
            StoreAction::TakeCloseWork => value = json!(self.take_close_work()),
            StoreAction::TakeMembershipWork => value = json!(self.take_membership_work()),
            StoreAction::OrderBuild => self.order_build(|| ()),
            StoreAction::Repairs { only } => value = json!(self.repairs(only.as_deref())),
            StoreAction::Unlisted { id, ids } => value = json!(self.unlisted(&ids, &id)),
            StoreAction::OwnerOfWorkspace { workspace } => {
                value = json!(self.owner_of_workspace(&workspace));
            }
            StoreAction::IncognitoOfWorkspace { workspace } => {
                value = json!(self.incognito_of_workspace(&workspace));
            }
            StoreAction::RepairedSelectionKept { current, members, preferred } => {
                value =
                    json!(Self::repaired_selection_kept(current.as_deref(), &members, &preferred));
            }
            StoreAction::SettleOwner { window, workspace } => {
                value = json!(self.settle_owner(&window, &workspace));
            }
        }
        (changes, value)
    }
}

/// The windows the person closed while the launch's restore ran, which the restore must not open
/// again (`RestoreClosedWindows`). The closed launch window is remembered, as the closed window the
/// restore's late workspaces go to, until each is in a window or is known gone ([`Self::settle`]).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RestoreClosed {
    /// The windows the person closed before the restore finished.
    #[serde(default)]
    pub windows: BTreeSet<String>,
    /// The launch window the person closed before the restore finished.
    #[serde(default)]
    pub launch_window_id: Option<String>,
    /// The workspaces the restore asked for that its store did not list when it ended.
    #[serde(default)]
    pub awaited: BTreeSet<String>,
    /// The store's event sequence taken after their creates replied: once the store applied this
    /// far, one it does not list is gone.
    #[serde(default)]
    pub barrier: u64,
}

impl RestoreClosed {
    /// The person closed window `id` during the restore; `launch` when it is the launch window.
    pub fn closed(&mut self, id: &str, launch: bool) {
        self.windows.insert(id.to_string());
        if launch {
            self.launch_window_id = Some(id.to_string());
        }
    }

    /// The person opened window `id` again on purpose: the restore keeps it open.
    pub fn reopened(&mut self, id: &str) {
        self.windows.remove(id);
    }

    /// The restore asked for `ids`, which its store did not list after the creates replied.
    pub fn awaiting(&mut self, ids: BTreeSet<String>, barrier: u64) {
        self.awaited = ids;
        self.barrier = barrier;
    }

    /// Closes every remembered window `registry` has open.
    pub fn keep_closed(&self, registry: &mut Registry) {
        for id in &self.windows {
            if registry.window(id).is_some_and(|w| w.is_open) {
                registry.set_restored(id, false);
            }
        }
    }

    /// The restore ended: only the closed launch window stays remembered, and only while a
    /// workspace the restore asked for can still arrive.
    pub fn restore_ended(
        &mut self,
        registry: &Registry,
        applied: u64,
        listed: impl Fn(&str) -> bool,
    ) {
        let launch = match &self.launch_window_id {
            Some(launch) if self.windows.contains(launch) && !self.awaited.is_empty() => {
                launch.clone()
            }
            _ => {
                *self = RestoreClosed::default();
                return;
            }
        };
        self.windows = BTreeSet::from([launch]);
        self.settle(registry, applied, listed);
    }

    /// After the restore, drops each awaited workspace a window of `registry` holds, and each the
    /// store applied past `barrier` without listing; with none left, everything is forgotten.
    pub fn settle(&mut self, registry: &Registry, applied: u64, listed: impl Fn(&str) -> bool) {
        if self.awaited.is_empty() {
            return;
        }
        let barrier = self.barrier;
        self.awaited.retain(|id| registry.owner(id).is_none() && (applied < barrier || listed(id)));
        if self.awaited.is_empty() {
            *self = RestoreClosed::default();
        }
    }
}

/// One step of [`RestoreClosed`] over the JSON channel (`registry_store_restore_closed`); `listed`
/// is the set of workspaces the store lists.
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum RestoreClosedAction {
    Closed {
        id: String,
        #[serde(default)]
        launch: bool,
    },
    Reopened {
        id: String,
    },
    Awaiting {
        #[serde(default)]
        ids: BTreeSet<String>,
        barrier: u64,
    },
    KeepClosed,
    RestoreEnded {
        applied: u64,
        #[serde(default)]
        listed: BTreeSet<String>,
    },
    Settle {
        applied: u64,
        #[serde(default)]
        listed: BTreeSet<String>,
    },
}

impl RestoreClosed {
    /// Runs `action`, which may close windows of `registry` (`keepClosed`).
    pub fn run(&mut self, registry: &mut Registry, action: RestoreClosedAction) {
        match action {
            RestoreClosedAction::Closed { id, launch } => self.closed(&id, launch),
            RestoreClosedAction::Reopened { id } => self.reopened(&id),
            RestoreClosedAction::Awaiting { ids, barrier } => self.awaiting(ids, barrier),
            RestoreClosedAction::KeepClosed => self.keep_closed(registry),
            RestoreClosedAction::RestoreEnded { applied, listed } => {
                self.restore_ended(registry, applied, |id| listed.contains(id));
            }
            RestoreClosedAction::Settle { applied, listed } => {
                self.settle(registry, applied, |id| listed.contains(id));
            }
        }
    }
}

/// New workspaces windows asked for before the daemon reported them (`WorkspaceClaims`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Claims {
    /// Workspace id -> the window that asked for it.
    #[serde(default)]
    pub pending: BTreeMap<String, String>,
    /// Pending claims not to show on arrival.
    #[serde(default)]
    pub quiet: BTreeSet<String>,
    /// Pending claims from runs without view-change permission.
    #[serde(default)]
    pub background: BTreeSet<String>,
}

impl Claims {
    /// Whether window `window` asked for workspace `id` and waits for it.
    pub fn awaits(&self, id: &str, window: &str) -> bool {
        self.pending.get(id).is_some_and(|w| w == window)
    }

    /// The create of workspace `id` failed, or a close cancelled it: its claim goes, unless the
    /// workspace is `listed`. Returns whether a window waited for it.
    pub fn release(&mut self, id: &str, listed: bool) -> bool {
        if listed || self.pending.remove(id).is_none() {
            return false;
        }
        self.quiet.remove(id);
        self.background.remove(id);
        true
    }
}

/// One step of [`Claims`] over the JSON channel (`registry_store_claims`).
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum ClaimsAction {
    Awaits {
        id: String,
        window: String,
    },
    Release {
        id: String,
        #[serde(default)]
        listed: bool,
    },
}

impl Claims {
    /// Runs `action`; its boolean answer.
    pub fn run(&mut self, action: ClaimsAction) -> bool {
        match action {
            ClaimsAction::Awaits { id, window } => self.awaits(&id, &window),
            ClaimsAction::Release { id, listed } => self.release(&id, listed),
        }
    }
}
