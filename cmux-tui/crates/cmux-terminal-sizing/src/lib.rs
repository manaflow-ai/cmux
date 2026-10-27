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

/// An entry that counts, with the viewport that lets it count.
struct Counted<'a> {
    entry: &'a Entry,
    viewport: TerminalGridSize,
}

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
        match self.entry_mut(&entry.participant.id) {
            Some(current) => *current = entry,
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
        let Some(entry) = self.entry_mut(id) else { return false };
        entry.participant.viewport = Some(viewport.clamped());
        self.publish()
    }

    /// Explicit focus-click or keyboard, paste or mouse input. Never hover.
    pub fn note_activity(&mut self, id: &str) -> bool {
        let Some(entry) = self.entries.iter_mut().find(|entry| entry.participant.id == id) else {
            return false;
        };
        self.activity_clock += 1;
        entry.activity = self.activity_clock;
        self.publish()
    }

    pub fn set_counts_override(&mut self, id: &str, value: Option<bool>) -> bool {
        let Some(entry) = self.entry_mut(id) else { return false };
        entry.participant.counts_override = value;
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
        let Some(entry) = self.entry_mut(id) else { return false };
        entry.participant.viewport = None;
        self.publish()
    }

    /// Replaces identity fields of an attached view, keeping its activity,
    /// viewport and counts override.
    pub fn update_identity(&mut self, identity: &TerminalSizingParticipant) -> bool {
        let Some(entry) = self.entry_mut(&identity.id) else { return false };
        let participant = &mut entry.participant;
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

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    // Rules

    fn index(&self, id: &str) -> Option<usize> {
        self.entries.iter().position(|entry| entry.participant.id == id)
    }

    fn entry_mut(&mut self, id: &str) -> Option<&mut Entry> {
        self.entries.iter_mut().find(|entry| entry.participant.id == id)
    }

    /// The entry with its viewport when it counts.
    fn counted<'a>(&self, entry: &'a Entry) -> Option<Counted<'a>> {
        let viewport = entry.participant.viewport?;
        self.entry_counts(entry).then_some(Counted { entry, viewport })
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

    fn decide(
        &self,
        counting: &[Counted],
    ) -> (TerminalGridSize, Vec<String>, TerminalSizingReason) {
        if self.policy.mode == TerminalSizingMode::Fixed
            && let Some(fixed) = self.policy.fixed
        {
            return (fixed, Vec::new(), TerminalSizingReason::Fixed);
        }
        let Some(first) = counting.first() else {
            return (self.held, Vec::new(), TerminalSizingReason::Held);
        };
        // Ties happen only between handhelds whose attach was not activity
        // (activity 0): the later entry wins (`>=`, as `max_by_key` keeps the
        // last maximum); an attach again replaces its entry in place, so it
        // keeps its place. The Swift twin breaks ties the same way.
        fn newest<'a, 'b>(
            first: &'b Counted<'a>,
            rest: impl Iterator<Item = &'b Counted<'a>>,
        ) -> &'b Counted<'a> {
            rest.fold(
                first,
                |best, next| {
                    if next.entry.activity >= best.entry.activity { next } else { best }
                },
            )
        }
        let single = |owner: &Counted, reason| {
            (owner.viewport, vec![owner.entry.participant.id.clone()], reason)
        };
        match self.policy.mode {
            TerminalSizingMode::Latest | TerminalSizingMode::Fixed => {
                single(newest(first, counting.iter().skip(1)), TerminalSizingReason::Latest)
            }
            TerminalSizingMode::Priority => {
                for key in &self.policy.priority {
                    let mut matches = counting
                        .iter()
                        .filter(|counted| counted.entry.participant.matches_priority_key(key));
                    if let Some(first_match) = matches.next() {
                        return single(
                            newest(first_match, matches),
                            TerminalSizingReason::Priority,
                        );
                    }
                }
                single(
                    newest(first, counting.iter().skip(1)),
                    TerminalSizingReason::PriorityFallback,
                )
            }
            TerminalSizingMode::Smallest | TerminalSizingMode::Largest => {
                let smallest = self.policy.mode == TerminalSizingMode::Smallest;
                let pick = |field: fn(&TerminalGridSize) -> u16| {
                    let values = counting.iter().map(|counted| field(&counted.viewport));
                    let seed = field(&first.viewport);
                    if smallest { values.fold(seed, u16::min) } else { values.fold(seed, u16::max) }
                };
                let cols = pick(|size| size.cols);
                let rows = pick(|size| size.rows);
                let owners = counting
                    .iter()
                    .filter(|counted| {
                        counted.viewport.cols == cols || counted.viewport.rows == rows
                    })
                    .map(|counted| counted.entry.participant.id.clone())
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
            self.entries.iter().filter_map(|entry| self.counted(entry)).collect::<Vec<_>>();
        let (size, owners, reason) = self.decide(&counting);
        if reason != TerminalSizingReason::Held && reason != TerminalSizingReason::Fixed {
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
mod tests {
    use super::*;
    use serde_json::Value;

    const FIXTURES: &str = include_str!("../../../../schemas/terminal-sizing/fixtures.json");

    fn size(value: &Value) -> TerminalGridSize {
        TerminalGridSize::new(
            value["cols"].as_u64().unwrap() as u16,
            value["rows"].as_u64().unwrap() as u16,
        )
    }

    #[test]
    fn sizing_policy_replays_shared_fixture_corpus() {
        let corpus: Value = serde_json::from_str(FIXTURES).unwrap();
        let cases = corpus["cases"].as_array().unwrap();
        assert!(!cases.is_empty());
        for case in cases {
            let name = case["name"].as_str().unwrap();
            let mut engine =
                TerminalSizingEngine::new(size(&case["initial"]), TerminalSizingPolicy::default());
            for (index, step) in case["steps"].as_array().unwrap().iter().enumerate() {
                let at = format!("{name} step {index}");
                let id = step["id"].as_str().unwrap_or_default();
                match step["op"].as_str().unwrap() {
                    "attach" => {
                        let participant: TerminalSizingParticipant =
                            serde_json::from_value(step["participant"].clone()).unwrap();
                        engine.attach(participant);
                    }
                    "detach" => {
                        engine.detach(id);
                    }
                    "report" => {
                        engine.report(id, size(step));
                    }
                    "activity" => {
                        engine.note_activity(id);
                    }
                    "clear_viewport" => {
                        engine.clear_viewport(id);
                    }
                    "set_counts" => {
                        engine.set_counts_override(id, step["counts_override"].as_bool());
                    }
                    "set_policy" => {
                        let policy: TerminalSizingPolicy =
                            serde_json::from_value(step["policy"].clone()).unwrap();
                        engine.set_policy(policy);
                    }
                    "expect" => {
                        let state = engine.state();
                        if let Some(cols) = step.get("cols") {
                            assert_eq!(u64::from(state.cols), cols.as_u64().unwrap(), "{at} cols");
                        }
                        if let Some(rows) = step.get("rows") {
                            assert_eq!(u64::from(state.rows), rows.as_u64().unwrap(), "{at} rows");
                        }
                        if let Some(owners) = step.get("owners") {
                            let owners: Vec<String> =
                                serde_json::from_value(owners.clone()).unwrap();
                            assert_eq!(state.owners, owners, "{at} owners");
                        }
                        if let Some(reason) = step.get("reason") {
                            assert_eq!(
                                serde_json::to_value(state.reason).unwrap(),
                                *reason,
                                "{at} reason"
                            );
                        }
                        if let Some(generation) = step.get("generation") {
                            assert_eq!(
                                state.generation,
                                generation.as_u64().unwrap(),
                                "{at} generation"
                            );
                        }
                        if let Some(keys) = step.get("priority_keys").and_then(Value::as_object) {
                            for (participant, expected) in keys {
                                assert_eq!(
                                    state
                                        .participant(participant)
                                        .map(|row| row.priority_key.as_str()),
                                    expected.as_str(),
                                    "{at} priority_key {participant}"
                                );
                            }
                        }
                        if let Some(counts) = step.get("counts").and_then(Value::as_object) {
                            for (participant, expected) in counts {
                                assert_eq!(
                                    engine.counts(participant),
                                    expected.as_bool().unwrap(),
                                    "{at} counts {participant}"
                                );
                                assert_eq!(
                                    state.participant(participant).map(|row| row.counts),
                                    expected.as_bool(),
                                    "{at} published counts {participant}"
                                );
                            }
                        }
                    }
                    other => panic!("{at}: unknown op {other}"),
                }
            }
        }
    }

    #[test]
    fn sizing_policy_state_matches_contract_wire_shape() {
        // Mirrors the `latest` example in docs/shared-terminal-sizing.md.
        let mut engine = TerminalSizingEngine::new(
            TerminalGridSize::new(80, 24),
            TerminalSizingPolicy::new(TerminalSizingMode::Latest, Vec::new(), None),
        );
        engine.attach(TerminalSizingParticipant {
            id: "c3".into(),
            user_id: Some("u_maya".into()),
            display_name: Some("Maya Ortiz".into()),
            device_kind: TerminalDeviceKind::Mac,
            device_name: Some("Mac Studio".into()),
            viewport: Some(TerminalGridSize::new(118, 38)),
            ..TerminalSizingParticipant::default()
        });
        let wire = serde_json::to_value(engine.state()).unwrap();
        assert_eq!(
            wire,
            serde_json::json!({
                "generation": 1, "cols": 118, "rows": 38, "reason": "latest", "owners": ["c3"],
                "policy": {"mode": "latest", "priority": [], "fixed": null},
                "participants": [{
                    "id": "c3", "user_id": "u_maya", "display_name": "Maya Ortiz",
                    "device_kind": "mac", "device_name": "Mac Studio", "device_id": null,
                    "via": null,
                    "viewport": {"cols": 118, "rows": 38}, "counts_override": null,
                    "counts": true, "priority_key": "u_maya/mac"
                }]
            })
        );
        let decoded: TerminalSizingState = serde_json::from_value(wire).unwrap();
        assert_eq!(&decoded, engine.state());
    }
}
