//! Linearizable canonical topology snapshots and revisioned delta delivery.

use std::collections::VecDeque;
use std::sync::mpsc::{RecvError, RecvTimeoutError, TryRecvError};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::{Value, json};

use crate::model::{Node, State};
use crate::{
    DaemonInstanceId, PaneId, PaneUuid, ScreenId, ScreenUuid, SessionId, SurfaceId, SurfaceUuid,
    WorkspaceId, WorkspaceUuid,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum TopologyOperation {
    WorkspaceCreated,
    ScreenCreated,
    PaneSplit,
    SurfaceAttached,
    SurfaceReplaced,
    SurfaceClosed,
    PaneClosed,
    ScreenClosed,
    WorkspaceClosed,
    WorkspaceRenamed,
    ScreenRenamed,
    PaneRenamed,
    SurfaceRenamed,
    SplitRatioChanged,
    PanesSwapped,
    LayoutApplied,
    TabMoved,
    WorkspaceMoved,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct TopologyTargets {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub workspaces: Vec<WorkspaceUuid>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub screens: Vec<ScreenUuid>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub panes: Vec<PaneUuid>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub surfaces: Vec<SurfaceUuid>,
}

impl TopologyTargets {
    pub(crate) fn from_legacy(
        state: &State,
        workspaces: impl IntoIterator<Item = WorkspaceId>,
        screens: impl IntoIterator<Item = ScreenId>,
        panes: impl IntoIterator<Item = PaneId>,
        surfaces: impl IntoIterator<Item = SurfaceId>,
    ) -> Self {
        let mut workspace_ids = workspaces.into_iter().collect::<Vec<_>>();
        let mut screen_ids = screens.into_iter().collect::<Vec<_>>();
        let mut pane_ids = panes.into_iter().collect::<Vec<_>>();
        let surface_ids = surfaces.into_iter().collect::<Vec<_>>();

        for surface in &surface_ids {
            if let Some(pane) = state.pane_of(*surface) {
                push_unique(&mut pane_ids, pane);
            }
        }
        for pane in &pane_ids {
            if let Some((workspace_index, screen_index)) = state.screen_of(*pane) {
                push_unique(&mut workspace_ids, state.workspaces[workspace_index].id);
                push_unique(
                    &mut screen_ids,
                    state.workspaces[workspace_index].screens[screen_index].id,
                );
            }
        }
        for screen in &screen_ids {
            if let Some(workspace) = state
                .workspaces
                .iter()
                .find(|workspace| workspace.screens.iter().any(|item| item.id == *screen))
            {
                push_unique(&mut workspace_ids, workspace.id);
            }
        }

        let mut targets = Self::default();
        for id in workspace_ids {
            if let Some(uuid) = state.workspace_uuid(id) {
                push_unique(&mut targets.workspaces, uuid);
            }
        }
        for id in screen_ids {
            if let Some(uuid) = state.screen_uuid(id) {
                push_unique(&mut targets.screens, uuid);
            }
        }
        for id in pane_ids {
            if let Some(uuid) = state.pane_uuid(id) {
                push_unique(&mut targets.panes, uuid);
            }
        }
        for id in surface_ids {
            if let Some(uuid) = state.surface_uuid(id) {
                push_unique(&mut targets.surfaces, uuid);
            }
        }
        targets
    }

    pub(crate) fn merge(&mut self, other: Self) {
        for uuid in other.workspaces {
            push_unique(&mut self.workspaces, uuid);
        }
        for uuid in other.screens {
            push_unique(&mut self.screens, uuid);
        }
        for uuid in other.panes {
            push_unique(&mut self.panes, uuid);
        }
        for uuid in other.surfaces {
            push_unique(&mut self.surfaces, uuid);
        }
    }
}

fn push_unique<T: PartialEq>(values: &mut Vec<T>, value: T) {
    if !values.contains(&value) {
        values.push(value);
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TopologySnapshot {
    pub daemon_instance_id: DaemonInstanceId,
    pub session_id: SessionId,
    pub revision: u64,
    pub topology: Value,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TopologyDelta {
    pub daemon_instance_id: DaemonInstanceId,
    pub session_id: SessionId,
    pub base_revision: u64,
    pub revision: u64,
    pub operation: TopologyOperation,
    pub targets: TopologyTargets,
    /// A complete canonical topology replacement after this transaction.
    /// Full replacements make deterministic application possible while the
    /// first protocol version establishes the journal and recovery contract.
    pub replacement: Value,
    #[serde(skip)]
    accounted_bytes: usize,
}

impl TopologyDelta {
    fn new(
        daemon_instance_id: DaemonInstanceId,
        session_id: SessionId,
        base_revision: u64,
        revision: u64,
        operation: TopologyOperation,
        targets: TopologyTargets,
        replacement: Value,
    ) -> Self {
        let mut delta = Self {
            daemon_instance_id,
            session_id,
            base_revision,
            revision,
            operation,
            targets,
            replacement,
            accounted_bytes: 0,
        };
        delta.accounted_bytes =
            serde_json::to_vec(&delta).expect("canonical topology delta serializes").len();
        delta
    }

    fn retained_bytes(&self) -> usize {
        self.accounted_bytes
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TopologyLimits {
    pub history_count: usize,
    pub history_bytes: usize,
    pub subscriber_count: usize,
    pub subscriber_bytes: usize,
}

impl Default for TopologyLimits {
    fn default() -> Self {
        Self {
            history_count: 512,
            history_bytes: 16 * 1024 * 1024,
            subscriber_count: 256,
            subscriber_bytes: 8 * 1024 * 1024,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ResnapshotReason {
    StaleDaemon,
    StaleSession,
    RevisionAhead,
    HistoryGap,
    ReplayTooLarge,
}

impl ResnapshotReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::StaleDaemon => "stale-daemon",
            Self::StaleSession => "stale-session",
            Self::RevisionAhead => "revision-ahead",
            Self::HistoryGap => "history-gap",
            Self::ReplayTooLarge => "replay-too-large",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ResnapshotRequired {
    pub daemon_instance_id: DaemonInstanceId,
    pub session_id: SessionId,
    pub current_revision: u64,
    pub reason: ResnapshotReason,
}

pub enum TopologyResume {
    Subscribed(TopologySubscription),
    ResnapshotRequired(ResnapshotRequired),
}

pub struct TopologySubscription {
    pub daemon_instance_id: DaemonInstanceId,
    pub session_id: SessionId,
    pub from_revision: u64,
    pub current_revision: u64,
    pub replayed: usize,
    pub receiver: TopologyDeltaReceiver,
}

pub struct TopologyDeltaReceiver {
    mailbox: Arc<TopologyMailbox>,
}

#[derive(Default)]
struct TopologyMailbox {
    state: Mutex<TopologyMailboxState>,
    changed: Condvar,
}

#[derive(Default)]
struct TopologyMailboxState {
    deltas: VecDeque<Arc<TopologyDelta>>,
    bytes: usize,
    closed: bool,
    overflowed: bool,
}

impl TopologyMailbox {
    fn seed(deltas: &[Arc<TopologyDelta>], limits: TopologyLimits) -> Option<Arc<TopologyMailbox>> {
        let bytes = deltas.iter().map(|delta| delta.retained_bytes()).sum::<usize>();
        if deltas.len() > limits.subscriber_count || bytes > limits.subscriber_bytes {
            return None;
        }
        Some(Arc::new(Self {
            state: Mutex::new(TopologyMailboxState {
                deltas: deltas.iter().cloned().collect(),
                bytes,
                closed: false,
                overflowed: false,
            }),
            changed: Condvar::new(),
        }))
    }

    fn push(&self, delta: Arc<TopologyDelta>, limits: TopologyLimits) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return false;
        }
        let bytes = delta.retained_bytes();
        if state.deltas.len() >= limits.subscriber_count
            || bytes > limits.subscriber_bytes.saturating_sub(state.bytes)
        {
            state.closed = true;
            state.overflowed = true;
            self.changed.notify_all();
            return false;
        }
        state.bytes += bytes;
        state.deltas.push_back(delta);
        self.changed.notify_one();
        true
    }
}

impl TopologyDeltaReceiver {
    pub fn overflowed(&self) -> bool {
        self.mailbox.state.lock().unwrap().overflowed
    }

    pub fn recv(&self) -> Result<Arc<TopologyDelta>, RecvError> {
        let mut state = self.mailbox.state.lock().unwrap();
        loop {
            if let Some(delta) = pop_delta(&mut state) {
                return Ok(delta);
            }
            if state.closed {
                return Err(RecvError);
            }
            state = self.mailbox.changed.wait(state).unwrap();
        }
    }

    pub fn try_recv(&self) -> Result<Arc<TopologyDelta>, TryRecvError> {
        let mut state = self.mailbox.state.lock().unwrap();
        if let Some(delta) = pop_delta(&mut state) {
            Ok(delta)
        } else if state.closed {
            Err(TryRecvError::Disconnected)
        } else {
            Err(TryRecvError::Empty)
        }
    }

    pub fn recv_timeout(&self, timeout: Duration) -> Result<Arc<TopologyDelta>, RecvTimeoutError> {
        let started = Instant::now();
        let mut remaining = timeout;
        let mut state = self.mailbox.state.lock().unwrap();
        loop {
            if let Some(delta) = pop_delta(&mut state) {
                return Ok(delta);
            }
            if state.closed {
                return Err(RecvTimeoutError::Disconnected);
            }
            let (next, waited) = self.mailbox.changed.wait_timeout(state, remaining).unwrap();
            state = next;
            if waited.timed_out() {
                if let Some(delta) = pop_delta(&mut state) {
                    return Ok(delta);
                }
                if state.closed {
                    return Err(RecvTimeoutError::Disconnected);
                }
                return Err(RecvTimeoutError::Timeout);
            }
            remaining = timeout.saturating_sub(started.elapsed());
        }
    }
}

fn pop_delta(state: &mut TopologyMailboxState) -> Option<Arc<TopologyDelta>> {
    let delta = state.deltas.pop_front()?;
    state.bytes = state.bytes.saturating_sub(delta.retained_bytes());
    Some(delta)
}

pub(crate) struct TopologyJournal {
    daemon_instance_id: DaemonInstanceId,
    session_id: SessionId,
    revision: u64,
    history: VecDeque<(Arc<TopologyDelta>, usize)>,
    history_bytes: usize,
    subscribers: Vec<Weak<TopologyMailbox>>,
    limits: TopologyLimits,
    #[cfg(test)]
    size_computations: usize,
}

impl TopologyJournal {
    pub(crate) fn new(
        daemon_instance_id: DaemonInstanceId,
        session_id: SessionId,
        limits: TopologyLimits,
    ) -> Self {
        Self::new_at_revision(daemon_instance_id, session_id, limits, 0)
    }

    /// Restore the authoritative revision from a validated durable snapshot.
    /// A restarted daemon intentionally starts with empty in-memory delta
    /// history, so clients behind this revision receive `HistoryGap` and
    /// resnapshot under the new daemon-instance fence.
    pub(crate) fn new_at_revision(
        daemon_instance_id: DaemonInstanceId,
        session_id: SessionId,
        limits: TopologyLimits,
        revision: u64,
    ) -> Self {
        Self {
            daemon_instance_id,
            session_id,
            revision,
            history: VecDeque::new(),
            history_bytes: 0,
            subscribers: Vec::new(),
            limits,
            #[cfg(test)]
            size_computations: 0,
        }
    }

    pub(crate) fn revision(&self) -> u64 {
        self.revision
    }

    pub(crate) fn session_id(&self) -> SessionId {
        self.session_id
    }

    pub(crate) fn snapshot(&self, state: &State) -> TopologySnapshot {
        TopologySnapshot {
            daemon_instance_id: self.daemon_instance_id,
            session_id: self.session_id,
            revision: self.revision,
            topology: topology_json(state),
        }
    }

    pub(crate) fn commit(
        &mut self,
        replacement: Value,
        operation: TopologyOperation,
        targets: TopologyTargets,
    ) -> Arc<TopologyDelta> {
        let base_revision = self.revision;
        self.revision =
            self.revision.checked_add(1).expect("canonical topology revision exhausted");
        let delta = Arc::new(TopologyDelta::new(
            self.daemon_instance_id,
            self.session_id,
            base_revision,
            self.revision,
            operation,
            targets,
            replacement,
        ));
        #[cfg(test)]
        {
            self.size_computations += 1;
        }
        self.retain(delta.clone());
        self.subscribers.retain(|subscriber| {
            subscriber.upgrade().is_some_and(|mailbox| mailbox.push(delta.clone(), self.limits))
        });
        delta
    }

    pub(crate) fn subscribe(
        &mut self,
        daemon_instance_id: DaemonInstanceId,
        session_id: SessionId,
        revision: u64,
    ) -> TopologyResume {
        if daemon_instance_id != self.daemon_instance_id {
            return self.resnapshot(ResnapshotReason::StaleDaemon);
        }
        if session_id != self.session_id {
            return self.resnapshot(ResnapshotReason::StaleSession);
        }
        if revision > self.revision {
            return self.resnapshot(ResnapshotReason::RevisionAhead);
        }
        let replay = self
            .history
            .iter()
            .filter(|(delta, _)| delta.revision > revision)
            .map(|(delta, _)| delta.clone())
            .collect::<Vec<_>>();
        if revision < self.revision && !is_contiguous(revision, self.revision, &replay) {
            return self.resnapshot(ResnapshotReason::HistoryGap);
        }
        let Some(mailbox) = TopologyMailbox::seed(&replay, self.limits) else {
            return self.resnapshot(ResnapshotReason::ReplayTooLarge);
        };
        self.subscribers.push(Arc::downgrade(&mailbox));
        TopologyResume::Subscribed(TopologySubscription {
            daemon_instance_id: self.daemon_instance_id,
            session_id: self.session_id,
            from_revision: revision,
            current_revision: self.revision,
            replayed: replay.len(),
            receiver: TopologyDeltaReceiver { mailbox },
        })
    }

    fn resnapshot(&self, reason: ResnapshotReason) -> TopologyResume {
        TopologyResume::ResnapshotRequired(ResnapshotRequired {
            daemon_instance_id: self.daemon_instance_id,
            session_id: self.session_id,
            current_revision: self.revision,
            reason,
        })
    }

    #[cfg(test)]
    pub(crate) fn size_computations(&self) -> usize {
        self.size_computations
    }

    #[cfg(test)]
    pub(crate) fn subscriber_slots(&self) -> usize {
        self.subscribers.len()
    }

    fn retain(&mut self, delta: Arc<TopologyDelta>) {
        let bytes = delta.retained_bytes();
        if self.limits.history_count == 0 || bytes > self.limits.history_bytes {
            self.history.clear();
            self.history_bytes = 0;
            return;
        }
        self.history.push_back((delta, bytes));
        self.history_bytes += bytes;
        while self.history.len() > self.limits.history_count
            || self.history_bytes > self.limits.history_bytes
        {
            let Some((_, removed_bytes)) = self.history.pop_front() else { break };
            self.history_bytes = self.history_bytes.saturating_sub(removed_bytes);
        }
    }
}

fn is_contiguous(from_revision: u64, current_revision: u64, replay: &[Arc<TopologyDelta>]) -> bool {
    let mut expected = from_revision;
    for delta in replay {
        if delta.base_revision != expected || delta.revision != expected.saturating_add(1) {
            return false;
        }
        expected = delta.revision;
    }
    expected == current_revision
}

pub(crate) fn topology_json(state: &State) -> Value {
    json!({
        "workspaces": state.workspaces.iter().map(|workspace| {
            json!({
                "id": workspace.id,
                "uuid": workspace.uuid,
                "name": workspace.name,
                "screens": workspace.screens.iter().map(|screen| {
                    let mut pane_ids = Vec::new();
                    screen.root.pane_ids(&mut pane_ids);
                    json!({
                        "id": screen.id,
                        "uuid": screen.uuid,
                        "name": screen.name,
                        "layout": node_json(state, &screen.root),
                        "panes": pane_ids.into_iter().filter_map(|pane_id| {
                            let pane = state.panes.get(&pane_id)?;
                            Some(json!({
                                "id": pane.id,
                                "uuid": pane.uuid,
                                "name": pane.name,
                                "tabs": pane.tabs.iter().filter_map(|surface_id| {
                                    let surface = state.surfaces.get(surface_id)?;
                                    Some(surface_json(surface))
                                }).collect::<Vec<_>>(),
                            }))
                        }).collect::<Vec<_>>(),
                    })
                }).collect::<Vec<_>>(),
            })
        }).collect::<Vec<_>>(),
    })
}

fn surface_json(surface: &crate::Surface) -> Value {
    let mut value = json!({
        "id": surface.id,
        "uuid": surface.uuid,
        "kind": surface.kind().as_str(),
        "name": surface.name(),
    });
    if surface.kind() == crate::SurfaceKind::Browser {
        value["browser_endpoint"] = json!({
            "transport": "cmuxd-png-frame-stream-v1",
            "source": surface.browser_source().map(|source| source.as_str()),
            // The endpoint remains daemon-owned. Frontends that do not consume
            // this transport may omit only this surface from their local
            // presentation graph while continuing to project sibling PTYs.
            "frontend_projection": "frontend-optional",
        });
    }
    value
}

fn node_json(state: &State, node: &Node) -> Value {
    match node {
        Node::Leaf(pane) => json!({
            "type": "leaf",
            "pane": pane,
            "pane_uuid": state.pane_uuid(*pane),
        }),
        Node::Split { dir, ratio, a, b } => json!({
            "type": "split",
            "dir": match dir {
                crate::SplitDir::Right => "right",
                crate::SplitDir::Down => "down",
            },
            "ratio": ratio,
            "a": node_json(state, a),
            "b": node_json(state, b),
        }),
    }
}
