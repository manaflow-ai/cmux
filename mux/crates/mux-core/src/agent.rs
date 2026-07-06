use std::collections::HashMap;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::SurfaceId;

pub const DEFAULT_AGENTS: [&str; 4] = ["claude", "codex", "opencode", "pi"];
pub const DETECTION_DEBOUNCE: Duration = Duration::from_millis(150);
pub const IDLE_QUIET: Duration = Duration::from_secs(2);

pub fn default_agents() -> Vec<String> {
    DEFAULT_AGENTS.iter().map(|agent| (*agent).to_string()).collect()
}

pub fn normalize_agents(agents: &[String]) -> Vec<String> {
    let mut normalized = agents
        .iter()
        .map(|agent| agent.trim().to_lowercase())
        .filter(|agent| !agent.is_empty())
        .collect::<Vec<_>>();
    if normalized.is_empty() {
        normalized = default_agents();
    }
    normalized
}

/// The first configured agent program appearing as a word in the title.
pub fn identify_agent(title: &str, agents: &[String]) -> Option<String> {
    let lower = title.to_lowercase();
    let words = lower
        .split(|c: char| !c.is_alphanumeric() && c != '-' && c != '_')
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>();
    agents.iter().find(|agent| words.contains(&agent.as_str())).cloned()
}

pub fn title_has_action_required(title: &str) -> bool {
    title.to_lowercase().contains("action required")
}

pub fn title_has_braille_spinner(title: &str) -> bool {
    title.trim_start().chars().next().is_some_and(|ch| ('\u{2800}'..='\u{28ff}').contains(&ch))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AgentState {
    Working,
    Blocked,
    Idle,
    Done,
    Unknown,
}

impl AgentState {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentState::Working => "working",
            AgentState::Blocked => "blocked",
            AgentState::Idle => "idle",
            AgentState::Done => "done",
            AgentState::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AgentSource {
    Detection,
    Hook,
}

impl AgentSource {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentSource::Detection => "detection",
            AgentSource::Hook => "hook",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentInfo {
    pub agent: Option<String>,
    pub state: AgentState,
    pub source: AgentSource,
    pub custom_status: Option<String>,
    pub session_ref: Option<String>,
    pub last_change: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentEntry {
    pub surface: SurfaceId,
    pub agent: String,
    pub state: AgentState,
    pub source: AgentSource,
    pub custom_status: Option<String>,
    pub session_ref: Option<String>,
    pub last_change: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentStateChange {
    pub surface: SurfaceId,
    pub agent: String,
    pub state: AgentState,
    pub source: AgentSource,
    pub custom_status: Option<String>,
}

#[derive(Debug, Default)]
pub(crate) struct AgentStore {
    detection: HashMap<SurfaceId, AgentInfo>,
    hook: HashMap<SurfaceId, AgentInfo>,
    effective: HashMap<SurfaceId, AgentInfo>,
    sessions: HashMap<SurfaceId, AgentSession>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct AgentSession {
    agent: String,
    session_ref: String,
}

impl AgentStore {
    pub(crate) fn list(&self) -> Vec<AgentEntry> {
        let mut entries = self
            .effective
            .iter()
            .filter_map(|(surface, info)| {
                let info = self.with_session(*surface, info.clone());
                let agent = info.agent.clone()?;
                Some(AgentEntry {
                    surface: *surface,
                    agent,
                    state: info.state,
                    source: info.source,
                    custom_status: info.custom_status.clone(),
                    session_ref: info.session_ref.clone(),
                    last_change: info.last_change,
                })
            })
            .collect::<Vec<_>>();
        entries.sort_by_key(|entry| entry.surface);
        entries
    }

    pub(crate) fn effective(&self, surface: SurfaceId) -> Option<AgentInfo> {
        self.effective.get(&surface).cloned().map(|info| self.with_session(surface, info))
    }

    pub(crate) fn record_session(
        &mut self,
        surface: SurfaceId,
        agent: String,
        session_ref: Option<String>,
    ) {
        let Some(session_ref) = session_ref else { return };
        self.sessions.insert(surface, AgentSession { agent, session_ref });
    }

    pub(crate) fn apply_detection(
        &mut self,
        surface: SurfaceId,
        mut info: AgentInfo,
    ) -> Option<AgentStateChange> {
        info.source = AgentSource::Detection;
        preserve_last_change(self.detection.get(&surface), &mut info);
        self.detection.insert(surface, info.clone());
        if self.hook.contains_key(&surface) {
            return None;
        }
        self.set_effective(surface, Some(info))
    }

    pub(crate) fn apply_hook(
        &mut self,
        surface: SurfaceId,
        mut info: AgentInfo,
    ) -> Option<AgentStateChange> {
        preserve_last_change(self.hook.get(&surface), &mut info);
        self.hook.insert(surface, info.clone());
        self.set_effective(surface, Some(info))
    }

    pub(crate) fn clear_detection(&mut self, surface: SurfaceId) -> Option<AgentStateChange> {
        self.detection.remove(&surface);
        if self.hook.contains_key(&surface) {
            return None;
        }
        self.effective.remove(&surface);
        None
    }

    pub(crate) fn clear_hook(
        &mut self,
        surface: SurfaceId,
        last_change: u64,
    ) -> Option<AgentStateChange> {
        if let Some(next) = self.detection.get(&surface).cloned() {
            self.hook.remove(&surface);
            self.set_effective(surface, Some(next))
        } else {
            self.finish_and_clear(surface, AgentSource::Hook, last_change)
        }
    }

    pub(crate) fn finish_and_clear(
        &mut self,
        surface: SurfaceId,
        source: AgentSource,
        last_change: u64,
    ) -> Option<AgentStateChange> {
        let current = self
            .effective
            .get(&surface)
            .or_else(|| self.hook.get(&surface))
            .or_else(|| self.detection.get(&surface))
            .cloned();
        self.effective.remove(&surface);
        self.hook.remove(&surface);
        self.detection.remove(&surface);
        self.sessions.remove(&surface);

        let mut current = current?;
        let agent = current.agent.take()?;
        if current.state == AgentState::Done {
            return None;
        }
        let done = AgentInfo {
            agent: Some(agent),
            state: AgentState::Done,
            source,
            custom_status: None,
            session_ref: current.session_ref,
            last_change,
        };
        AgentStore::change_from(surface, &done)
    }

    fn set_effective(
        &mut self,
        surface: SurfaceId,
        next: Option<AgentInfo>,
    ) -> Option<AgentStateChange> {
        let changed = match (self.effective.get(&surface), next.as_ref()) {
            (Some(prev), Some(next)) => !same_visible_agent_info(prev, next),
            (None, Some(_)) => true,
            (Some(_), None) => true,
            (None, None) => false,
        };
        match next {
            Some(next) => {
                let next = match self.effective.get(&surface) {
                    Some(prev) if same_visible_agent_info(prev, &next) => {
                        let mut next = next;
                        next.last_change = prev.last_change;
                        next
                    }
                    _ => next,
                };
                self.effective.insert(surface, next.clone());
                changed.then(|| AgentStore::change_from(surface, &next)).flatten()
            }
            None => {
                self.effective.remove(&surface);
                None
            }
        }
    }

    fn change_from(surface: SurfaceId, info: &AgentInfo) -> Option<AgentStateChange> {
        Some(AgentStateChange {
            surface,
            agent: info.agent.clone()?,
            state: info.state,
            source: info.source,
            custom_status: info.custom_status.clone(),
        })
    }

    fn with_session(&self, surface: SurfaceId, mut info: AgentInfo) -> AgentInfo {
        if info.session_ref.is_none() {
            if let Some(session) = self.sessions.get(&surface) {
                if info.agent.as_deref() == Some(session.agent.as_str()) {
                    info.session_ref = Some(session.session_ref.clone());
                }
            }
        }
        info
    }
}

fn same_visible_agent_info(a: &AgentInfo, b: &AgentInfo) -> bool {
    a.agent == b.agent
        && a.state == b.state
        && a.source == b.source
        && a.custom_status == b.custom_status
}

fn preserve_last_change(prev: Option<&AgentInfo>, next: &mut AgentInfo) {
    if let Some(prev) = prev {
        if same_visible_agent_info(prev, next) {
            next.last_change = prev.last_change;
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum DetectorEvent {
    Activity { surface: SurfaceId, title: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum DetectorAction {
    Active { surface: SurfaceId, title: String },
    Quiet { surface: SurfaceId, title: String },
}

#[derive(Debug)]
struct PendingDetection {
    title: String,
    active_due: Instant,
    idle_due: Instant,
    active_reported: bool,
}

#[derive(Debug)]
pub(crate) struct AgentDetector {
    debounce: Duration,
    idle_quiet: Duration,
    pending: HashMap<SurfaceId, PendingDetection>,
}

impl Default for AgentDetector {
    fn default() -> Self {
        AgentDetector::new(DETECTION_DEBOUNCE, IDLE_QUIET)
    }
}

impl AgentDetector {
    fn new(debounce: Duration, idle_quiet: Duration) -> Self {
        AgentDetector { debounce, idle_quiet, pending: HashMap::new() }
    }

    pub(crate) fn ingest(&mut self, now: Instant, event: DetectorEvent) {
        match event {
            DetectorEvent::Activity { surface, title } => {
                self.pending.insert(
                    surface,
                    PendingDetection {
                        title,
                        active_due: now + self.debounce,
                        idle_due: now + self.idle_quiet,
                        active_reported: false,
                    },
                );
            }
        }
    }

    pub(crate) fn next_deadline(&self) -> Option<Instant> {
        self.pending
            .values()
            .flat_map(|pending| {
                let active = (!pending.active_reported).then_some(pending.active_due);
                [active, Some(pending.idle_due)]
            })
            .flatten()
            .min()
    }

    pub(crate) fn drain_due(&mut self, now: Instant) -> Vec<DetectorAction> {
        let mut actions = Vec::new();
        let surfaces = self.pending.keys().copied().collect::<Vec<_>>();
        for surface in surfaces {
            let Some(pending) = self.pending.get_mut(&surface) else { continue };
            if !pending.active_reported && pending.active_due <= now {
                pending.active_reported = true;
                actions.push(DetectorAction::Active { surface, title: pending.title.clone() });
            }
            if pending.idle_due <= now {
                let pending = self.pending.remove(&surface).expect("pending key existed");
                actions.push(DetectorAction::Quiet { surface, title: pending.title });
            }
        }
        actions
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info(agent: &str, state: AgentState, source: AgentSource, last_change: u64) -> AgentInfo {
        AgentInfo {
            agent: Some(agent.to_string()),
            state,
            source,
            custom_status: None,
            session_ref: None,
            last_change,
        }
    }

    #[test]
    fn detection_then_hook_override_then_clear_returns_to_detection() {
        let mut store = AgentStore::default();
        let changed =
            store.apply_detection(7, info("codex", AgentState::Working, AgentSource::Detection, 1));
        assert_eq!(changed.as_ref().map(|c| c.state), Some(AgentState::Working));
        assert_eq!(store.effective(7).unwrap().source, AgentSource::Detection);

        let changed = store.apply_hook(7, info("codex", AgentState::Blocked, AgentSource::Hook, 2));
        assert_eq!(changed.as_ref().map(|c| c.state), Some(AgentState::Blocked));
        assert_eq!(store.effective(7).unwrap().source, AgentSource::Hook);

        let changed =
            store.apply_detection(7, info("codex", AgentState::Idle, AgentSource::Detection, 3));
        assert!(changed.is_none());
        assert_eq!(store.effective(7).unwrap().state, AgentState::Blocked);

        let changed = store.clear_hook(7, 4).expect("clear should reveal detection state");
        assert_eq!(changed.state, AgentState::Idle);
        assert_eq!(changed.source, AgentSource::Detection);
        assert_eq!(store.effective(7).unwrap().state, AgentState::Idle);

        let changed =
            store.apply_hook(8, info("claude", AgentState::Blocked, AgentSource::Hook, 5));
        assert_eq!(changed.as_ref().map(|c| c.state), Some(AgentState::Blocked));
        let changed =
            store.clear_hook(8, 6).expect("clear without fallback should emit terminal state");
        assert_eq!(changed.agent, "claude");
        assert_eq!(changed.state, AgentState::Done);
        assert_eq!(changed.source, AgentSource::Hook);
        assert!(store.effective(8).is_none());
    }

    #[test]
    fn no_agent_detection_pass_does_not_clear_hook_authority() {
        let mut store = AgentStore::default();
        store.apply_detection(3, info("claude", AgentState::Working, AgentSource::Detection, 1));
        store.apply_hook(3, info("claude", AgentState::Blocked, AgentSource::Hook, 2));

        let changed = store.clear_detection(3);
        assert!(changed.is_none());
        let effective = store.effective(3).expect("hook state should remain effective");
        assert_eq!(effective.agent.as_deref(), Some("claude"));
        assert_eq!(effective.state, AgentState::Blocked);
        assert_eq!(effective.source, AgentSource::Hook);
    }

    #[test]
    fn done_transition_on_exit_clears_agent() {
        let mut store = AgentStore::default();
        store.apply_detection(9, info("claude", AgentState::Working, AgentSource::Detection, 1));

        let changed =
            store.finish_and_clear(9, AgentSource::Detection, 2).expect("done transition");
        assert_eq!(changed.agent, "claude");
        assert_eq!(changed.state, AgentState::Done);
        assert_eq!(changed.source, AgentSource::Detection);
        assert!(store.effective(9).is_none());
        assert!(store.list().is_empty());
    }

    #[test]
    fn unknown_is_a_real_classification() {
        let mut store = AgentStore::default();
        let changed = store
            .apply_detection(11, info("opencode", AgentState::Unknown, AgentSource::Detection, 1));
        assert_eq!(changed.as_ref().map(|c| c.state), Some(AgentState::Unknown));
        assert_eq!(store.list()[0].state, AgentState::Unknown);
    }

    #[test]
    fn identical_re_report_preserves_last_change() {
        let mut store = AgentStore::default();
        store.apply_detection(12, info("codex", AgentState::Working, AgentSource::Detection, 10));
        assert_eq!(store.effective(12).unwrap().last_change, 10);

        let changed = store
            .apply_detection(12, info("codex", AgentState::Working, AgentSource::Detection, 99));
        assert!(changed.is_none());
        assert_eq!(store.effective(12).unwrap().last_change, 10);
    }

    #[test]
    fn detector_holds_idle_until_quiet_window_after_latest_activity() {
        let mut detector = AgentDetector::new(Duration::from_millis(150), Duration::from_secs(2));
        let start = Instant::now();
        detector.ingest(start, DetectorEvent::Activity { surface: 1, title: "codex".to_string() });

        assert!(detector.drain_due(start + Duration::from_millis(149)).is_empty());
        assert_eq!(
            detector.drain_due(start + Duration::from_millis(150)),
            vec![DetectorAction::Active { surface: 1, title: "codex".to_string() }]
        );

        detector.ingest(
            start + Duration::from_millis(1900),
            DetectorEvent::Activity { surface: 1, title: "codex".to_string() },
        );
        let actions = detector.drain_due(start + Duration::from_millis(2050));
        assert_eq!(
            actions,
            vec![DetectorAction::Active { surface: 1, title: "codex".to_string() }]
        );
        assert!(detector.drain_due(start + Duration::from_millis(3899)).is_empty());
        assert_eq!(
            detector.drain_due(start + Duration::from_millis(3900)),
            vec![DetectorAction::Quiet { surface: 1, title: "codex".to_string() }]
        );
    }
}
