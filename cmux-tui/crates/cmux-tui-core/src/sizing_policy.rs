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
    #[default]
    Unknown,
}

impl TerminalDeviceKind {
    /// Phones and tablets defer to a Mac or TUI of the same user.
    pub fn is_handheld(self) -> bool {
        matches!(self, Self::Iphone | Self::Ipad)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mac => "mac",
            Self::Iphone => "iphone",
            Self::Ipad => "ipad",
            Self::Tui => "tui",
            Self::Browser => "browser",
            Self::Unknown => "unknown",
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

    /// Stable key used by priority lists: `<user_id or anon:id>/<device_kind>`.
    pub fn priority_key(&self) -> String {
        match &self.user_id {
            Some(user) => format!("{user}/{}", self.device_kind.as_str()),
            None => format!("anon:{}/{}", self.id, self.device_kind.as_str()),
        }
    }
}

/// How the host picks the grid.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TerminalSizingMode {
    #[default]
    Latest,
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

    /// Adds a view, or replaces one with the same id. Attach counts as activity.
    pub fn attach(&mut self, participant: TerminalSizingParticipant) -> bool {
        self.activity_clock += 1;
        let mut participant = participant;
        participant.viewport = participant.viewport.map(TerminalGridSize::clamped);
        let entry = Entry { participant, activity: self.activity_clock };
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

    // Host extensions outside the shared fixture corpus. They never change
    // activity, so they cannot promote a participant by themselves.

    /// Forgets a viewport while keeping the view attached, for a viewer that
    /// hid the terminal but keeps its stream cached.
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

    fn entry_counts(&self, entry: &Entry) -> bool {
        let participant = &entry.participant;
        if participant.viewport.is_none() {
            return false;
        }
        if let Some(explicit) = participant.counts_override {
            return explicit;
        }
        let (true, Some(user)) = (participant.device_kind.is_handheld(), &participant.user_id)
        else {
            return true;
        };
        !self.entries.iter().any(|other| {
            other.participant.user_id.as_ref() == Some(user)
                && matches!(
                    other.participant.device_kind,
                    TerminalDeviceKind::Mac | TerminalDeviceKind::Tui
                )
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
        // Ties cannot occur: every attach and activity takes a fresh clock
        // value. `max_by_key` keeps the last maximum, matching Swift's `max`.
        fn newest<'a>(list: impl Iterator<Item = &'a &'a Entry>) -> &'a Entry {
            list.max_by_key(|entry| entry.activity).expect("non-empty")
        }
        let single = |owner: &Entry, reason| {
            (
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
                        .filter(|entry| entry.participant.priority_key() == *key)
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
                    .map(|entry| entry.participant.viewport.expect("counting"))
                    .collect::<Vec<_>>();
                let pick = |values: Vec<u16>| {
                    if smallest {
                        values.into_iter().min().expect("non-empty")
                    } else {
                        values.into_iter().max().expect("non-empty")
                    }
                };
                let cols = pick(viewports.iter().map(|size| size.cols).collect());
                let rows = pick(viewports.iter().map(|size| size.rows).collect());
                let owners = counting
                    .iter()
                    .filter(|entry| {
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
        let mut engine = TerminalSizingEngine::new(
            TerminalGridSize::new(80, 24),
            TerminalSizingPolicy::default(),
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
                    "device_kind": "mac", "device_name": "Mac Studio", "via": null,
                    "viewport": {"cols": 118, "rows": 38}, "counts_override": null,
                    "counts": true, "priority_key": "u_maya/mac"
                }]
            })
        );
        let decoded: TerminalSizingState = serde_json::from_value(wire).unwrap();
        assert_eq!(&decoded, engine.state());
    }

    #[test]
    fn sizing_policy_host_extensions_do_not_count_as_activity() {
        let mut engine = TerminalSizingEngine::new(
            TerminalGridSize::new(80, 24),
            TerminalSizingPolicy::default(),
        );
        let mut a = TerminalSizingParticipant::new("a", TerminalDeviceKind::Mac);
        a.viewport = Some(TerminalGridSize::new(100, 30));
        let mut b = TerminalSizingParticipant::new("b", TerminalDeviceKind::Tui);
        b.viewport = Some(TerminalGridSize::new(90, 20));
        engine.attach(a.clone());
        engine.attach(b);
        assert_eq!(engine.state().owners, ["b"]);
        a.display_name = Some("renamed".into());
        assert!(engine.update_identity(&a));
        assert_eq!(engine.state().owners, ["b"]);
        assert!(engine.clear_viewport("b"));
        assert_eq!(engine.state().owners, ["a"]);
        assert_eq!(engine.state().size(), TerminalGridSize::new(100, 30));
    }
}
