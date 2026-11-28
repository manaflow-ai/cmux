//! Shared terminal sizing reducer.
//!
//! Decides the PTY grid of one shared terminal. Pure and synchronous: the
//! host feeds attach, detach, viewport, activity, counts and policy events and
//! publishes [`TerminalSizingEngine::state`] whenever a mutation returns
//! `true`.
//!
//! This is the Rust twin of `Packages/Shared/CmuxTerminalSizing`
//! (`TerminalSizingEngine.swift`). Both replay
//! `schemas/terminal-sizing/fixtures.json`; `docs/shared-terminal-sizing.md`
//! is the contract. Keep the two implementations identical, including the
//! JSON wire shape.
//!
//! The crate depends on serde only, so every host links it: the daemon
//! (`cmux-tui-core::sizing_policy` re-exports it) and the iOS and Android
//! core (`cmux-mobile-core`, bound by `cmux-mobile-ffi`).

use serde::{Deserialize, Deserializer, Serialize};

pub mod claim;

/// A terminal grid in cells.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TerminalGridSize {
    pub cols: u16,
    pub rows: u16,
}

impl TerminalGridSize {
    pub const fn new(cols: u16, rows: u16) -> Self {
        Self { cols, rows }
    }

    /// The same grid clamped to the smallest size a host applies (2 x 1).
    pub fn clamped(self) -> Self {
        Self { cols: self.cols.max(2), rows: self.rows.max(1) }
    }
}

/// The kind of device behind one attached view.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TerminalDeviceKind {
    Mac,
    Iphone,
    Ipad,
    Tui,
    Browser,
    /// The GPUI desktop app on Linux.
    Linux,
    /// The GPUI desktop app on Windows.
    Windows,
    #[default]
    Unknown,
}

impl TerminalDeviceKind {
    /// Phones and tablets defer to a desktop of the same user.
    pub fn is_handheld(self) -> bool {
        matches!(self, Self::Iphone | Self::Ipad)
    }

    /// A Mac, a TUI, or the desktop app on Linux or Windows: a handheld of
    /// the same user defers to it.
    pub fn is_desktop(self) -> bool {
        matches!(self, Self::Mac | Self::Tui | Self::Linux | Self::Windows)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mac => "mac",
            Self::Iphone => "iphone",
            Self::Ipad => "ipad",
            Self::Tui => "tui",
            Self::Browser => "browser",
            Self::Linux => "linux",
            Self::Windows => "windows",
            Self::Unknown => "unknown",
        }
    }

    /// The kind as a client without `open-device-kinds-v1` reads it. Such a
    /// client decodes only the kinds of the first `shared-sizing-v1`
    /// release, so later kinds read as [`Self::Unknown`].
    pub fn for_closed_clients(self) -> Self {
        match self {
            Self::Linux | Self::Windows => Self::Unknown,
            kind => kind,
        }
    }

    /// Parses a wire value. Unknown values decode as [`Self::Unknown`].
    pub fn parse(raw: &str) -> Self {
        match raw {
            "mac" => Self::Mac,
            "iphone" => Self::Iphone,
            "ipad" => Self::Ipad,
            "tui" => Self::Tui,
            "browser" => Self::Browser,
            "linux" => Self::Linux,
            "windows" => Self::Windows,
            _ => Self::Unknown,
        }
    }
}

impl<'de> Deserialize<'de> for TerminalDeviceKind {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(Self::parse(&String::deserialize(deserializer)?))
    }
}

/// One attached view of a terminal, as the host sees it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TerminalSizingParticipant {
    /// Host-scoped id, unique while attached.
    pub id: String,
    /// Stack user id asserted by the host or relay, never by the viewer.
    #[serde(default)]
    pub user_id: Option<String>,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub device_kind: TerminalDeviceKind,
    #[serde(default)]
    pub device_name: Option<String>,
    /// Stable per-install id of the device (one Mac app install, one phone
    /// install, one cmux-tui host). Tells two Macs of the same user apart.
    #[serde(default)]
    pub device_id: Option<String>,
    /// Participant id of the relay that forwards this view, if any.
    #[serde(default)]
    pub via: Option<String>,
    /// Last reported viewport; `None` until the viewer reports one.
    #[serde(default)]
    pub viewport: Option<TerminalGridSize>,
    /// Explicit counts-toward-size choice; `None` means the automatic rule.
    #[serde(default)]
    pub counts_override: Option<bool>,
}

impl TerminalSizingParticipant {
    pub fn new(id: impl Into<String>, device_kind: TerminalDeviceKind) -> Self {
        Self { id: id.into(), device_kind, ..Self::default() }
    }

    /// Stable key used by priority lists:
    /// `<user_id or anon:id>/<device_kind>/<device_id>`, or the legacy
    /// `<user_id or anon:id>/<device_kind>` when the device has no id.
    pub fn priority_key(&self) -> String {
        match self.device_id.as_deref().filter(|id| !id.is_empty()) {
            Some(device) => format!("{}/{device}", self.legacy_priority_key()),
            None => self.legacy_priority_key(),
        }
    }

    /// The two-segment key older policies stored. A policy entry in this form
    /// matches every device of that kind for that user.
    pub fn legacy_priority_key(&self) -> String {
        match &self.user_id {
            Some(user) => format!("{user}/{}", self.device_kind.as_str()),
            None => format!("anon:{}/{}", self.id, self.device_kind.as_str()),
        }
    }

    /// Whether a priority list entry names this participant: its own key, or
    /// the legacy key of its user and device kind.
    pub fn matches_priority_key(&self, key: &str) -> bool {
        key == self.priority_key() || key == self.legacy_priority_key()
    }
}

/// How the host picks the grid.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TerminalSizingMode {
    /// "Last active": the default. The grid follows the counting view that last
    /// typed, pasted, clicked or took over (plans/cmux-next/sync-ux/DESIGN.md
    /// part 2). A phone or tablet that only attaches never takes it.
    #[default]
    Latest,
    /// "Fit everyone": every attached device sees the whole grid.
    Smallest,
    Largest,
    Priority,
    Fixed,
}

/// A sizing policy for one terminal or a workspace default.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize)]
pub struct TerminalSizingPolicy {
    pub mode: TerminalSizingMode,
    /// Priority keys, highest first. Used by [`TerminalSizingMode::Priority`].
    pub priority: Vec<String>,
    /// Grid used by [`TerminalSizingMode::Fixed`].
    pub fixed: Option<TerminalGridSize>,
}

impl TerminalSizingPolicy {
    pub fn new(
        mode: TerminalSizingMode,
        priority: Vec<String>,
        fixed: Option<TerminalGridSize>,
    ) -> Self {
        Self { mode, priority, fixed: fixed.map(TerminalGridSize::clamped) }
    }
}

impl<'de> Deserialize<'de> for TerminalSizingPolicy {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Wire {
            #[serde(default)]
            mode: Option<TerminalSizingMode>,
            #[serde(default)]
            priority: Option<Vec<String>>,
            #[serde(default)]
            fixed: Option<TerminalGridSize>,
        }
        let wire = Wire::deserialize(deserializer)?;
        Ok(Self::new(wire.mode.unwrap_or_default(), wire.priority.unwrap_or_default(), wire.fixed))
    }
}

/// Why the grid has its current size.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TerminalSizingReason {
    Latest,
    Smallest,
    Largest,
    Priority,
    Fixed,
    Held,
    PriorityFallback,
}

/// One participant row of a published size state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalSizingParticipantState {
    #[serde(flatten)]
    pub participant: TerminalSizingParticipant,
    /// Whether the participant counts toward size right now.
    pub counts: bool,
    pub priority_key: String,
}

/// The state a host publishes to every viewer. Same JSON on every host.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalSizingState {
    pub generation: u64,
    pub cols: u16,
    pub rows: u16,
    pub reason: TerminalSizingReason,
    /// Participants that set a dimension, in attach order.
    pub owners: Vec<String>,
    pub policy: TerminalSizingPolicy,
    pub participants: Vec<TerminalSizingParticipantState>,
}

impl TerminalSizingState {
    pub fn size(&self) -> TerminalGridSize {
        TerminalGridSize::new(self.cols, self.rows)
    }

    pub fn participant(&self, id: &str) -> Option<&TerminalSizingParticipantState> {
        self.participants.iter().find(|row| row.participant.id == id)
    }

    /// This state for one client: unchanged for a client that sent
    /// `open-device-kinds-v1`, else with every device kind that client
    /// cannot decode replaced by `unknown`. Priority keys keep the real kind.
    pub fn for_client(&self, open_device_kinds: bool) -> std::borrow::Cow<'_, Self> {
        let closed = |row: &TerminalSizingParticipantState| {
            row.participant.device_kind.for_closed_clients() != row.participant.device_kind
        };
        if open_device_kinds || !self.participants.iter().any(closed) {
            return std::borrow::Cow::Borrowed(self);
        }
        let mut state = self.clone();
        for row in &mut state.participants {
            row.participant.device_kind = row.participant.device_kind.for_closed_clients();
        }
        std::borrow::Cow::Owned(state)
    }
}

/// Who disconnected a view.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalDetachActor {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
}

impl TerminalDetachActor {
    pub fn is_empty(&self) -> bool {
        self.user_id.is_none() && self.display_name.is_none() && self.device_name.is_none()
    }
}

/// Wire values of the `reason` field on a `detached` event.
pub mod detach_reason {
    pub const NETWORK: &str = "network";
    pub const DISCONNECTED_BY: &str = "disconnected-by";
    pub const HOST_SHUTDOWN: &str = "host-shutdown";
    pub const SUPERSEDED: &str = "superseded";
}

#[derive(Clone, Debug)]
struct Entry {
    participant: TerminalSizingParticipant,
    activity: u64,
}

/// The narrowest grid a shared terminal takes while some counting view is at
/// least this wide: an iPhone's portrait terminal page. A narrower view (a
/// split pane, another device) gets the wider grid instead of squeezing every
/// view below a phone (Leo, 2026-11-15: "i dont see the point of a
/// narrower-than-iphone terminal"). `fixed` and `held` keep their grid.
pub const MIN_SHARED_COLS: u16 = 40;

/// Decides the PTY grid of one shared terminal.
#[derive(Clone, Debug)]
pub struct TerminalSizingEngine {
    entries: Vec<Entry>,
    activity_clock: u64,
    policy: TerminalSizingPolicy,
    held: TerminalGridSize,
    state: TerminalSizingState,
}

impl TerminalSizingEngine {
    /// `initial_size` is the grid before anyone reports, usually the PTY's
    /// current size. `policy` is the effective policy (workspace default or
    /// terminal override).
    pub fn new(initial_size: TerminalGridSize, policy: TerminalSizingPolicy) -> Self {
        let held = initial_size.clamped();
        Self {
            entries: Vec::new(),
            activity_clock: 0,
            state: TerminalSizingState {
                generation: 0,
                cols: held.cols,
                rows: held.rows,
                reason: TerminalSizingReason::Held,
                owners: Vec::new(),
                policy: policy.clone(),
                participants: Vec::new(),
            },
            policy,
            held,
        }
    }

    pub fn state(&self) -> &TerminalSizingState {
        &self.state
    }

    pub fn policy(&self) -> &TerminalSizingPolicy {
        &self.policy
    }

    // Mutations. Each returns true when the published state changed.

    /// Adds a view, or replaces one with the same id. A desktop's attach
    /// counts as activity; a phone's or tablet's does not (activity 0), so a
    /// glance from a phone never takes the grid from a desktop in use. A
    /// handheld that is the only counting view still sets the grid.
    pub fn attach(&mut self, participant: TerminalSizingParticipant) -> bool {
        self.activity_clock += 1;
        let mut participant = participant;
        participant.viewport = participant.viewport.map(TerminalGridSize::clamped);
        let activity = if participant.device_kind.is_handheld() { 0 } else { self.activity_clock };
        let entry = Entry { participant, activity };
        match self.index(&entry.participant.id) {
            Some(index) => self.entries[index] = entry,
            None => self.entries.push(entry),
        }
        self.publish()
    }

    pub fn detach(&mut self, id: &str) -> bool {
        let Some(index) = self.index(id) else { return false };
        self.entries.remove(index);
        self.publish()
    }

    pub fn report(&mut self, id: &str, viewport: TerminalGridSize) -> bool {
        let Some(index) = self.index(id) else { return false };
        self.entries[index].participant.viewport = Some(viewport.clamped());
        self.publish()
    }

    /// Explicit focus-click or keyboard, paste or mouse input. Never hover.
    pub fn note_activity(&mut self, id: &str) -> bool {
        let Some(index) = self.index(id) else { return false };
        self.activity_clock += 1;
        self.entries[index].activity = self.activity_clock;
        self.publish()
    }

    pub fn set_counts_override(&mut self, id: &str, value: Option<bool>) -> bool {
        let Some(index) = self.index(id) else { return false };
        self.entries[index].participant.counts_override = value;
        self.publish()
    }

    pub fn set_policy(&mut self, policy: TerminalSizingPolicy) -> bool {
        self.policy = policy;
        self.publish()
    }

    // Host extensions. They never change activity, so they cannot promote a
    // participant by themselves.

    /// Forgets a viewport while keeping the view attached, for a viewer that
    /// hid the terminal but keeps its stream cached (an iPhone app in the
    /// background, a terminal off screen). The viewer stops counting until
    /// its next report. Shared fixture op `clear_viewport`.
    pub fn clear_viewport(&mut self, id: &str) -> bool {
        let Some(index) = self.index(id) else { return false };
        self.entries[index].participant.viewport = None;
        self.publish()
    }

    /// Replaces identity fields of an attached view, keeping its activity,
    /// viewport and counts override.
    pub fn update_identity(&mut self, identity: &TerminalSizingParticipant) -> bool {
        let Some(index) = self.index(&identity.id) else { return false };
        let participant = &mut self.entries[index].participant;
        participant.user_id = identity.user_id.clone();
        participant.display_name = identity.display_name.clone();
        participant.device_kind = identity.device_kind;
        participant.device_name = identity.device_name.clone();
        participant.device_id = identity.device_id.clone();
        participant.via = identity.via.clone();
        self.publish()
    }

    // Queries

    pub fn contains(&self, id: &str) -> bool {
        self.index(id).is_some()
    }

    pub fn participant(&self, id: &str) -> Option<&TerminalSizingParticipant> {
        self.entries.iter().find(|entry| entry.participant.id == id).map(|entry| &entry.participant)
    }

    pub fn counts(&self, id: &str) -> bool {
        self.entries
            .iter()
            .find(|entry| entry.participant.id == id)
            .is_some_and(|entry| self.entry_counts(entry))
    }

    pub fn participant_ids(&self) -> impl Iterator<Item = &str> {
        self.entries.iter().map(|entry| entry.participant.id.as_str())
    }

    /// The participant whose last activity is later than every other participant's, if one is. Noting activity
    /// for it changes no decision: under every policy the newest of any set of views that holds it is still it,
    /// and the newest of a set without it does not move. `None` while two views tie (handheld attaches, activity 0).
    pub fn sole_latest(&self) -> Option<&str> {
        let mut latest: Option<&Entry> = None;
        let mut tied = false;
        for entry in &self.entries {
            match latest {
                Some(current) if entry.activity < current.activity => {}
                Some(current) if entry.activity == current.activity => tied = true,
                _ => {
                    latest = Some(entry);
                    tied = false;
                }
            }
        }
        latest
            .filter(|entry| !tied && entry.activity > 0)
            .map(|entry| entry.participant.id.as_str())
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    // Rules

    fn index(&self, id: &str) -> Option<usize> {
        self.entries.iter().position(|entry| entry.participant.id == id)
    }

    fn entry_counts(&self, entry: &Entry) -> bool {
        let participant = &entry.participant;
        if participant.viewport.is_none() {
            return false;
        }
        if let Some(explicit) = participant.counts_override {
            return explicit;
        }
        // Only `priority` defers a phone to its user's desktop. Fit-everyone
        // modes count every view, and `latest` lets a phone take the grid by
        // input (its attach alone never does).
        if self.policy.mode != TerminalSizingMode::Priority {
            return true;
        }
        let (true, Some(user)) = (participant.device_kind.is_handheld(), &participant.user_id)
        else {
            return true;
        };
        // Defer only to a desktop of the same user that itself counts: a
        // viewer-only or viewport-less Mac leaves the phone in charge.
        !self.entries.iter().any(|other| {
            let other = &other.participant;
            other.user_id.as_ref() == Some(user)
                && other.device_kind.is_desktop()
                && other.viewport.is_some()
                && other.counts_override != Some(false)
        })
    }

    fn decide(&self, counting: &[&Entry]) -> (TerminalGridSize, Vec<String>, TerminalSizingReason) {
        if self.policy.mode == TerminalSizingMode::Fixed
            && let Some(fixed) = self.policy.fixed
        {
            return (fixed, Vec::new(), TerminalSizingReason::Fixed);
        }
        if counting.is_empty() {
            return (self.held, Vec::new(), TerminalSizingReason::Held);
        }
        // Ties happen only between handhelds whose attach was not activity
        // (activity 0): the later entry wins. `max_by_key` keeps the last
        // maximum; an attach again replaces its entry in place, so it keeps its
        // place. The Swift twin breaks ties the same way.
        fn newest<'a>(list: impl Iterator<Item = &'a &'a Entry>) -> &'a Entry {
            // crash-allow: callers pass a non-empty list
            list.max_by_key(|entry| entry.activity).expect("non-empty")
        }
        let single = |owner: &Entry, reason| {
            (
                // crash-allow: counting entries have a viewport
                owner.participant.viewport.expect("counting"),
                vec![owner.participant.id.clone()],
                reason,
            )
        };
        match self.policy.mode {
            TerminalSizingMode::Latest | TerminalSizingMode::Fixed => {
                single(newest(counting.iter()), TerminalSizingReason::Latest)
            }
            TerminalSizingMode::Priority => {
                for key in &self.policy.priority {
                    let mut matches = counting
                        .iter()
                        .filter(|entry| entry.participant.matches_priority_key(key))
                        .peekable();
                    if matches.peek().is_some() {
                        return single(newest(matches), TerminalSizingReason::Priority);
                    }
                }
                single(newest(counting.iter()), TerminalSizingReason::PriorityFallback)
            }
            TerminalSizingMode::Smallest | TerminalSizingMode::Largest => {
                let smallest = self.policy.mode == TerminalSizingMode::Smallest;
                let viewports = counting
                    .iter()
                    // crash-allow: counting entries have a viewport
                    .map(|entry| entry.participant.viewport.expect("counting"))
                    .collect::<Vec<_>>();
                let pick = |values: Vec<u16>| {
                    if smallest {
                        // crash-allow: counting is non-empty here
                        values.into_iter().min().expect("non-empty")
                    } else {
                        // crash-allow: counting is non-empty here
                        values.into_iter().max().expect("non-empty")
                    }
                };
                let mut cols = pick(viewports.iter().map(|size| size.cols).collect());
                let rows = pick(viewports.iter().map(|size| size.rows).collect());
                if smallest {
                    // The phone floor: a counting phone or tablet (one that
                    // shows the terminal now) never gets a grid narrower than
                    // itself; a narrower desktop view clips instead. Columns
                    // only: a shorter desktop pane cut at the bottom would
                    // hide the prompt and cursor rows, and a phone's rows
                    // swing with its keyboard (docs/shared-terminal-sizing.md).
                    if let Some(floor) = counting
                        .iter()
                        .filter(|entry| entry.participant.device_kind.is_handheld())
                        .filter_map(|entry| {
                            entry.participant.viewport.map(|viewport| viewport.cols)
                        })
                        .min()
                    {
                        cols = cols.max(floor);
                    }
                }
                let owners = counting
                    .iter()
                    .filter(|entry| {
                        // crash-allow: counting entries have a viewport
                        let viewport = entry.participant.viewport.expect("counting");
                        viewport.cols == cols || viewport.rows == rows
                    })
                    .map(|entry| entry.participant.id.clone())
                    .collect();
                let reason = if smallest {
                    TerminalSizingReason::Smallest
                } else {
                    TerminalSizingReason::Largest
                };
                (TerminalGridSize::new(cols, rows), owners, reason)
            }
        }
    }

    fn publish(&mut self) -> bool {
        let counting =
            self.entries.iter().filter(|entry| self.entry_counts(entry)).collect::<Vec<_>>();
        let (mut size, owners, reason) = self.decide(&counting);
        if reason != TerminalSizingReason::Held && reason != TerminalSizingReason::Fixed {
            let phone_wide = counting.iter().any(|entry| {
                entry.participant.viewport.is_some_and(|viewport| viewport.cols >= MIN_SHARED_COLS)
            });
            if phone_wide {
                size.cols = size.cols.max(MIN_SHARED_COLS);
            }
            self.held = size;
        }
        let participants = self
            .entries
            .iter()
            .map(|entry| TerminalSizingParticipantState {
                participant: entry.participant.clone(),
                counts: self.entry_counts(entry),
                priority_key: entry.participant.priority_key(),
            })
            .collect();
        let next = TerminalSizingState {
            generation: self.state.generation,
            cols: size.cols,
            rows: size.rows,
            reason,
            owners,
            policy: self.policy.clone(),
            participants,
        };
        if next == self.state {
            return false;
        }
        self.state = TerminalSizingState { generation: self.state.generation + 1, ..next };
        true
    }
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
