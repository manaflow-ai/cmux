//! The sidebar's agent feeds (`sidebar_feeds`), moved from Swift (`CmuxNextAgentLanes`):
//! `AgentPriorityRanking` and `AgentPriorityMarks` (the Priority view's order, the menu bar's
//! lists and the marks' rules), `SidebarLaneStatus` (a row's merged status, chip and now line),
//! `SidebarPriorityMachine` (another machine's chats as lanes), `SidebarSessionTreeFeed` and
//! `+Checks` (the session tree's lineage pass, its pull request badges and the store's staleness),
//! `SidebarTransientItem+Chief` and `String.chiefTaskTitle` (the Chief item's status and subagent
//! rows), `SidebarChatHistoryFeed.Inputs` (the history windows' specs), `SidebarLocalLanes` and
//! `AgentLaneStore.keepsWorkspace`, and `SidebarApprovals.waitingChats`.
//!
//! Each request names one rule (`rule`). Times are seconds since 1970 (`Date`'s
//! `timeIntervalSince1970`); a missing time sorts as `Date.distantPast` does. Localized text,
//! brand marks and colors stay in Swift: the rules give ids, states and order.

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, HashSet};

/// How long an idle chat with nothing unseen stays in the Priority view (`idleHorizon`).
pub const IDLE_HORIZON: f64 = 24.0 * 60.0 * 60.0;
/// The most doublings of the store's freshness a failing read waits (`maximumBackoff`).
pub const MAXIMUM_BACKOFF: u32 = 4;
/// Earlier's window in the chat history (`SidebarChatHistoryFeed.earlierWindow`).
pub const EARLIER_WINDOW: &str = "sidebar.history.earlier";
/// The pinned chats' window (`SidebarChatHistoryFeed.pinnedWindow`).
pub const PINNED_WINDOW: &str = "sidebar.history.pinned";
/// The id prefix of a Chief subagent row after `LayoutItemID.transientPrefix`.
pub const CHIEF_SUBAGENT_PREFIX: &str = "chief-sub:";

// MARK: - Lanes

/// acpmux's state of one session's turn (`AgentActivityLane.State`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LaneState {
    Working,
    Input,
    Failed,
    Lost,
    #[default]
    Idle,
}

impl LaneState {
    /// `rawValue`, as a mark's stamp spells it.
    pub fn raw(self) -> &'static str {
        match self {
            Self::Working => "working",
            Self::Input => "input",
            Self::Failed => "failed",
            Self::Lost => "lost",
            Self::Idle => "idle",
        }
    }

    fn failure(self) -> bool {
        matches!(self, Self::Failed | Self::Lost)
    }

    /// `needsAttention`: a question, or a failed or lost turn.
    pub fn needs_attention(self) -> bool {
        matches!(self, Self::Input | Self::Failed | Self::Lost)
    }
}

/// What the rules read of an `AgentActivityLane` (and of its `AgentLaneLinks`).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Lane {
    pub id: String,
    pub name: String,
    pub title: String,
    pub project: Option<String>,
    pub peer: Option<String>,
    pub parent: Option<String>,
    pub state: LaneState,
    pub since: Option<f64>,
    pub error: Option<String>,
    pub step: Option<String>,
    pub turn_activity: Option<String>,
    pub turn_prompt: Option<String>,
    pub unread: bool,
    pub harness: Option<String>,
    pub mark_key: Option<String>,
    pub spawned_by: Option<String>,
    pub cwd: Option<String>,
    pub pull_requests: Vec<String>,
}

fn since_key(since: Option<f64>) -> f64 {
    since.unwrap_or(f64::NEG_INFINITY)
}

/// Newer first, as `sinceA > sinceB` sorts.
fn newer_first(a: Option<f64>, b: Option<f64>) -> Ordering {
    since_key(b).total_cmp(&since_key(a))
}

// MARK: - Marks

/// A snooze on one state of a chat (`AgentPriorityMarks.State.Snooze`).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Snooze {
    pub stamp: String,
    pub until: f64,
}

/// The person's marks on the Priority view's chats (`AgentPriorityMarks.State`).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Marks {
    pub pinned: BTreeSet<String>,
    pub read: BTreeMap<String, String>,
    pub snoozed: BTreeMap<String, Snooze>,
    pub archived: BTreeSet<String>,
    pub collapsed: bool,
    pub archived_open: bool,
    pub placed: BTreeMap<String, i64>,
}

impl Marks {
    /// `isSnoozed`: a snooze on the chat's current stamp that has not ended.
    pub fn is_snoozed(&self, id: &str, stamp: &str, now: f64) -> bool {
        self.snoozed.get(id).is_some_and(|s| s.stamp == stamp && now < s.until)
    }

    fn is_read(&self, lane: &Lane) -> bool {
        self.read.get(&lane.id).is_some_and(|s| *s == stamp(lane))
    }

    fn hidden(&self, lane: &Lane, now: f64) -> bool {
        self.archived.contains(&lane.id) || self.is_snoozed(&lane.id, &stamp(lane), now)
    }

    /// `place(_:in:)`: the dragged chat, and every chat placed before, take their index in `order`.
    pub fn place(&mut self, id: &str, order: &[String]) {
        for (index, other) in order.iter().enumerate() {
            if other == id || self.placed.contains_key(other) {
                self.placed.insert(other.clone(), index as i64);
            }
        }
    }

    /// `prune(keeping:)`: marks of chats acpmux no longer lists go.
    pub fn prune(&mut self, ids: &BTreeSet<String>) {
        self.pinned.retain(|id| ids.contains(id));
        self.archived.retain(|id| ids.contains(id));
        self.read.retain(|id, _| ids.contains(id));
        self.snoozed.retain(|id, _| ids.contains(id));
        self.placed.retain(|id, _| ids.contains(id));
    }
}

/// A mark's stamp of a lane (`AgentPriorityMarks.stamp`): its state at its notice key, else at
/// its time in whole milliseconds.
pub fn stamp(lane: &Lane) -> String {
    let key = lane
        .mark_key
        .clone()
        .unwrap_or_else(|| lane.since.map_or(0, |s| (s * 1000.0) as i64).to_string());
    format!("{}@{key}", lane.state.raw())
}

// MARK: - Priority ranking

/// A Priority row's chip (`SidebarPriorityEntry.State`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PriorityState {
    NeedsYou,
    Done,
    Failed,
    Lost,
    CiFailing,
    Working,
    Idle,
}

/// `AgentPriorityRanking.tier`.
pub fn tier(state: PriorityState) -> u8 {
    match state {
        PriorityState::NeedsYou => 0,
        PriorityState::Done => 1,
        PriorityState::Failed | PriorityState::Lost => 2,
        PriorityState::CiFailing => 3,
        PriorityState::Working => 4,
        PriorityState::Idle => 5,
    }
}

/// `AgentPriorityRanking.state`: the turn's chip, unless failing checks rank higher.
pub fn priority_state(lane: &Lane, read: bool, failing_checks: bool) -> PriorityState {
    let turn = match lane.state {
        LaneState::Input => PriorityState::NeedsYou,
        LaneState::Working => PriorityState::Working,
        LaneState::Failed if read => PriorityState::Idle,
        LaneState::Failed => PriorityState::Failed,
        LaneState::Lost if read => PriorityState::Idle,
        LaneState::Lost => PriorityState::Lost,
        LaneState::Idle if lane.unread && !read => PriorityState::Done,
        LaneState::Idle => PriorityState::Idle,
    };
    if failing_checks && tier(PriorityState::CiFailing) < tier(turn) {
        PriorityState::CiFailing
    } else {
        turn
    }
}

/// `AgentPriorityRanking.preview`: a failed turn's error, else the step.
pub fn preview(lane: &Lane) -> Option<String> {
    if lane.state.failure()
        && let Some(error) = &lane.error
    {
        return Some(error.clone());
    }
    lane.step.clone()
}

/// One Priority row (`SidebarPriorityEntry`, less its brand and color).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PriorityEntry {
    pub id: String,
    pub title: String,
    pub project: Option<String>,
    pub machine: Option<String>,
    pub preview: Option<String>,
    pub state: PriorityState,
    /// The turn's start for a working row (`.working(since:)`).
    pub since: Option<f64>,
    pub unread: bool,
    pub pinned: bool,
    pub harness: Option<String>,
}

/// `AgentPriorityRanking.entries`: the rows in rank order. `machines` names a row's machine tag
/// where the caller knows it (else the lane's peer).
pub fn entries(
    lanes: &[Lane],
    marks: &Marks,
    now: f64,
    failing_checks: &BTreeSet<String>,
    machines: &BTreeMap<String, Option<String>>,
    idle_horizon: f64,
) -> Vec<PriorityEntry> {
    let ranked: Vec<(PriorityEntry, u8, Option<f64>)> = lanes
        .iter()
        .filter_map(|lane| {
            let lane_stamp = stamp(lane);
            if marks.archived.contains(&lane.id) || marks.is_snoozed(&lane.id, &lane_stamp, now) {
                return None;
            }
            let read = marks.read.get(&lane.id) == Some(&lane_stamp);
            let pinned = marks.pinned.contains(&lane.id);
            let state = priority_state(lane, read, failing_checks.contains(&lane.id));
            let kept = pinned || marks.placed.contains_key(&lane.id);
            if state == PriorityState::Idle
                && !kept
                && lane.since.is_some_and(|since| now - since > idle_horizon)
            {
                return None;
            }
            let entry = PriorityEntry {
                id: lane.id.clone(),
                title: lane.title.clone(),
                project: lane.project.clone(),
                machine: machines.get(&lane.id).cloned().unwrap_or_else(|| lane.peer.clone()),
                preview: preview(lane),
                state,
                since: (state == PriorityState::Working).then_some(lane.since).flatten(),
                unread: lane.unread && !read,
                pinned,
                harness: lane.harness.clone(),
            };
            Some((entry, tier(state), lane.since))
        })
        .collect();
    let mut loose: Vec<&(PriorityEntry, u8, Option<f64>)> =
        ranked.iter().filter(|row| !marks.placed.contains_key(&row.0.id)).collect();
    loose.sort_by(|a, b| {
        a.1.cmp(&b.1)
            .then_with(|| b.0.pinned.cmp(&a.0.pinned))
            .then_with(|| newer_first(a.2, b.2))
            .then_with(|| a.0.id.cmp(&b.0.id))
    });
    let mut rows: Vec<PriorityEntry> = loose.into_iter().map(|row| row.0.clone()).collect();
    let mut placed: Vec<(&PriorityEntry, i64)> = ranked
        .iter()
        .filter_map(|row| marks.placed.get(&row.0.id).map(|place| (&row.0, *place)))
        .collect();
    placed.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.id.cmp(&b.0.id)));
    for (entry, place) in placed {
        let at = usize::try_from(place.max(0)).unwrap_or(usize::MAX).min(rows.len());
        rows.insert(at, entry.clone());
    }
    rows
}

/// `AgentPriorityRanking.nextChange`: the earliest future snooze end or idle age-out.
pub fn next_change(
    lanes: &[Lane],
    marks: &Marks,
    now: f64,
    failing_checks: &BTreeSet<String>,
    idle_horizon: f64,
) -> Option<f64> {
    lanes
        .iter()
        .filter_map(|lane| {
            if marks.archived.contains(&lane.id) {
                return None;
            }
            let lane_stamp = stamp(lane);
            if let Some(snooze) = marks.snoozed.get(&lane.id)
                && snooze.stamp == lane_stamp
                && snooze.until > now
            {
                return Some(snooze.until);
            }
            let read = marks.read.get(&lane.id) == Some(&lane_stamp);
            let state = priority_state(lane, read, failing_checks.contains(&lane.id));
            if marks.pinned.contains(&lane.id)
                || marks.placed.contains_key(&lane.id)
                || state != PriorityState::Idle
            {
                return None;
            }
            lane.since.map(|since| since + idle_horizon)
        })
        .filter(|change| *change > now)
        .min_by(f64::total_cmp)
}

fn listed(lanes: Vec<&Lane>, marks: &Marks, now: f64) -> Vec<String> {
    let mut kept: Vec<&Lane> = lanes.into_iter().filter(|lane| !marks.hidden(lane, now)).collect();
    kept.sort_by(|a, b| {
        marks
            .pinned
            .contains(&b.id)
            .cmp(&marks.pinned.contains(&a.id))
            .then_with(|| newer_first(a.since, b.since))
            .then_with(|| a.id.cmp(&b.id))
    });
    kept.into_iter().map(|lane| lane.id.clone()).collect()
}

/// `needingInput`: of the waiting lanes, those still at a question, pinned then newest.
pub fn needing_input(waiting: &[Lane], marks: &Marks, now: f64) -> Vec<String> {
    listed(waiting.iter().filter(|lane| lane.state == LaneState::Input).collect(), marks, now)
}

/// `unread`: results the person has not read, not running a turn.
pub fn unread(lanes: &[Lane], marks: &Marks, now: f64) -> Vec<String> {
    listed(
        lanes
            .iter()
            .filter(|lane| lane.unread && lane.state != LaneState::Working && !marks.is_read(lane))
            .collect(),
        marks,
        now,
    )
}

/// `running`: the lanes running a turn.
pub fn running(lanes: &[Lane], marks: &Marks, now: f64) -> Vec<String> {
    listed(lanes.iter().filter(|lane| lane.state == LaneState::Working).collect(), marks, now)
}

/// `next(after:in:)`: the id after `previous`, wrapping; the first when `previous` is gone.
pub fn next_after(previous: Option<&str>, ids: &[String]) -> Option<String> {
    previous
        .and_then(|previous| ids.iter().skip_while(|id| id.as_str() != previous).nth(1))
        .or_else(|| ids.first())
        .cloned()
}

// MARK: - Lane status (a sidebar row)

/// A status indicator's state (`StatusIndicatorState`), with whether it carries progress.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Indicator {
    Error,
    Waiting,
    Busy,
    Working,
    Paused,
    Success,
    #[default]
    Idle,
}

impl Indicator {
    /// `StatusStack.stateRank`.
    pub fn rank(self) -> u8 {
        match self {
            Self::Error => 6,
            Self::Waiting => 5,
            Self::Busy | Self::Working => 4,
            Self::Paused => 3,
            Self::Success => 2,
            Self::Idle => 0,
        }
    }
}

/// `SidebarLaneStatus.indicator`.
pub fn indicator(state: LaneState) -> Indicator {
    match state {
        LaneState::Working => Indicator::Working,
        LaneState::Input => Indicator::Waiting,
        LaneState::Failed | LaneState::Lost => Indicator::Error,
        LaneState::Idle => Indicator::Idle,
    }
}

/// The row's activity before the lanes merge in.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct RowActivity {
    pub activity: Indicator,
    /// `activity.progress != nil`.
    pub progress: bool,
    pub agent_working: bool,
}

/// `merge(_:into:)`'s answer: `replaced` clears the row's style and sets `activitySince`.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Merged {
    pub activity: Indicator,
    pub progress: bool,
    pub agent_working: bool,
    pub replaced: bool,
    pub activity_since: Option<f64>,
}

/// `SidebarLaneStatus.merge`: a lane's state replaces the row's when it asks and the row does
/// not, or when `StatusStack.precedes` ranks the lane's report (source agent) over the row's
/// (source explicit, same time).
pub fn merge(lanes: &[Lane], row: &RowActivity) -> Merged {
    let mut merged = Merged {
        activity: row.activity,
        progress: row.progress,
        agent_working: row.agent_working,
        replaced: false,
        activity_since: None,
    };
    for lane in lanes {
        let state = indicator(lane.state);
        if state == Indicator::Working {
            merged.agent_working = true;
        }
        let asks = |s: Indicator| s == Indicator::Waiting;
        let precedes = match (asks(state), asks(merged.activity)) {
            (true, false) => true,
            (false, true) => false,
            // Same time; the lane has no progress and the agent source ranks under explicit, so
            // only a higher state rank wins.
            _ => state.rank() > merged.activity.rank(),
        };
        if !precedes {
            continue;
        }
        merged.activity = state;
        merged.progress = false;
        merged.replaced = true;
        merged.activity_since = lane.since;
    }
    merged
}

/// `withoutSupersededFailures`: a failure another chat went on past (one working or asking, or
/// one that came to rest after it) goes; a lone failure, or every lane failing, stays.
pub fn without_superseded_failures(lanes: &[Lane]) -> Vec<Lane> {
    let failures = lanes.iter().filter(|lane| lane.state.failure()).count();
    if failures == 0 || failures >= lanes.len() {
        return lanes.to_vec();
    }
    let active =
        lanes.iter().any(|lane| matches!(lane.state, LaneState::Working | LaneState::Input));
    let last_rest = lanes
        .iter()
        .filter(|lane| lane.state == LaneState::Idle)
        .filter_map(|lane| lane.since)
        .max_by(f64::total_cmp);
    lanes
        .iter()
        .filter(|lane| {
            if !lane.state.failure() {
                return true;
            }
            if active {
                return false;
            }
            match (last_rest, lane.since) {
                (Some(rest), Some(failed_at)) => failed_at >= rest,
                _ => true,
            }
        })
        .cloned()
        .collect()
}

/// `SidebarLaneStatus.chip`: the highest-tier chip of a row's lanes; done, working and idle say
/// nothing but their failing checks.
pub fn chip(
    lanes: &[Lane],
    marks: &Marks,
    failing_checks: &BTreeSet<String>,
    superseded: &BTreeSet<String>,
) -> Option<PriorityState> {
    lanes
        .iter()
        .filter_map(|lane| {
            let failing = failing_checks.contains(&lane.id);
            if superseded.contains(&lane.id) {
                return failing.then_some(PriorityState::CiFailing);
            }
            match priority_state(lane, marks.is_read(lane), failing) {
                PriorityState::Done => failing.then_some(PriorityState::CiFailing),
                PriorityState::Working | PriorityState::Idle => None,
                state => Some(state),
            }
        })
        .min_by_key(|state| tier(*state))
}

fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// `CharacterSet.whitespaces`: blanks, not line breaks.
fn is_blank(c: char) -> bool {
    c.is_whitespace() && !is_newline(c)
}

fn first_line(text: Option<&str>) -> Option<String> {
    let line = text?.split(is_newline).find(|part| !part.is_empty())?;
    let trimmed = line.trim_matches(is_blank);
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

/// `SidebarLaneStatus.step`: the newest working lane's first line of what it does.
pub fn step(lanes: &[Lane]) -> Option<String> {
    let mut best: Option<(f64, String)> = None;
    for lane in lanes.iter().filter(|lane| lane.state == LaneState::Working) {
        let text = first_line(lane.turn_activity.as_deref()).or_else(|| {
            if lane.turn_prompt.is_none() { first_line(lane.step.as_deref()) } else { None }
        });
        let Some(text) = text else { continue };
        let since = since_key(lane.since);
        // `max(by:)` keeps the first of equals.
        if best.as_ref().is_none_or(|(held, _)| *held < since) {
            best = Some((since, text));
        }
    }
    best.map(|(_, text)| text)
}

/// The Done pill (`row.agentDone`): a finished turn nobody has seen.
pub fn agent_done(lanes: &[Lane], marks: &Marks) -> bool {
    lanes.iter().any(|lane| priority_state(lane, marks.is_read(lane), false) == PriorityState::Done)
}

/// One local lane's tab facts for a workspace's row (`SidebarLocalLanes.lanes`).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SessionRef {
    pub host: String,
    pub session: Option<String>,
    pub harness: Option<String>,
}

/// `SidebarLocalLanes.lanes`: the lanes of the tabs on this Mac's acpmux, not mirrored.
pub fn local_lanes(
    tabs: &[Option<SessionRef>],
    lanes: &BTreeMap<String, Lane>,
    local_host: Option<&str>,
) -> Vec<Lane> {
    let Some(host) = local_host else { return Vec::new() };
    tabs.iter()
        .flatten()
        .filter(|tab| tab.host == host)
        .filter_map(|tab| tab.session.as_ref().and_then(|s| lanes.get(s)))
        .filter(|lane| lane.peer.is_none())
        .cloned()
        .collect()
}

/// `AgentLaneStore.keepsWorkspace`: whether a workspace's row stays while acpmux's lanes are live
/// or within a gap (`before_gap`, the sessions listed before it). `live_sessions` are the
/// sessions acpmux lists live.
pub fn keeps_workspace(
    tabs: &[Option<SessionRef>],
    local_host: Option<&str>,
    live: bool,
    before_gap: Option<&BTreeSet<String>>,
    live_sessions: &BTreeSet<String>,
) -> bool {
    let gap = if live { None } else { before_gap };
    let Some(host) = local_host else { return true };
    if !live && gap.is_none() {
        return true;
    }
    let local: Vec<&String> = tabs
        .iter()
        .flatten()
        .filter(|tab| tab.host == host)
        .filter_map(|tab| tab.session.as_ref())
        .collect();
    if local.is_empty() {
        return true;
    }
    let mixed =
        tabs.iter().any(|tab| !matches!(tab, Some(r) if r.host == host && r.session.is_some()));
    if mixed {
        return true;
    }
    match gap {
        Some(gap) => local.iter().any(|s| gap.contains(*s)),
        None => local.iter().any(|s| live_sessions.contains(*s)),
    }
}

/// `SidebarApprovals.Wait`: a chat waiting on a permission prompt.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Wait {
    pub since: Option<f64>,
    pub step: Option<String>,
}

/// `SidebarApprovals.waitingChats`: this Mac's waiting sessions still at a question.
pub fn waiting_chats(
    waiting: &[String],
    lanes: &BTreeMap<String, Lane>,
    enabled: bool,
) -> BTreeMap<String, Wait> {
    if !enabled {
        return BTreeMap::new();
    }
    waiting
        .iter()
        .filter_map(|id| {
            let lane = lanes.get(id)?;
            (lane.state == LaneState::Input && lane.peer.is_none())
                .then(|| (id.clone(), Wait { since: lane.since, step: lane.step.clone() }))
        })
        .collect()
}

// MARK: - Another machine's chats (SidebarPriorityMachine)

/// A tab's notice level.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum NoticeLevel {
    Info,
    Warning,
    Error,
}

/// The tab's last notice (`TabModel.notification`).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Notice {
    pub id: String,
    pub level: Option<NoticeLevel>,
    pub created_at_ms: Option<u64>,
    /// The ledger's time for this notice when the tab's has none.
    pub ledger_ms: Option<u64>,
    /// `store.notificationText(for:)`.
    pub text: Option<String>,
}

/// One tab of another machine's daemon.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct MachineTab {
    pub session: Option<String>,
    pub harness: Option<String>,
    pub display_title: String,
    pub has_unread: bool,
    pub notice: Option<Notice>,
}

fn machine_lane(
    tab: &MachineTab,
    session: &str,
    machine: Option<&str>,
    generation: Option<&str>,
    first_seen: &BTreeMap<String, f64>,
    now: f64,
) -> Lane {
    let marker = tab.notice.as_ref();
    let notice = if tab.has_unread { marker } else { None };
    let state = match notice.and_then(|n| n.level) {
        Some(NoticeLevel::Warning) => LaneState::Input,
        Some(NoticeLevel::Error) => LaneState::Failed,
        _ => LaneState::Idle,
    };
    let text = notice.and_then(|n| n.text.clone());
    let created = marker.and_then(|m| m.created_at_ms.or(m.ledger_ms));
    let boot = format!("g{}", generation.unwrap_or("-"));
    let key = marker.map_or_else(
        || "none".to_owned(),
        |m| format!("n{}@{}", m.id, created.map_or(boot, |ms| ms.to_string())),
    );
    let since = created.map_or_else(
        || first_seen.get(&format!("{session}#{key}")).copied().unwrap_or(now),
        |ms| ms as f64 / 1000.0,
    );
    let title = tab.display_title.trim();
    Lane {
        id: session.to_owned(),
        name: session.to_owned(),
        title: if title.is_empty() {
            tab.harness.clone().unwrap_or_else(|| session.to_owned())
        } else {
            title.to_owned()
        },
        peer: machine.map(str::to_owned),
        state,
        since: Some(since),
        error: if state == LaneState::Failed { text.clone() } else { None },
        step: if state == LaneState::Failed { None } else { text },
        unread: notice.is_some() && state == LaneState::Idle,
        harness: tab.harness.clone(),
        mark_key: Some(key),
        ..Lane::default()
    }
}

fn strength(lane: &Lane) -> u8 {
    match lane.state {
        LaneState::Input => 3,
        LaneState::Failed | LaneState::Lost => 2,
        LaneState::Idle | LaneState::Working => u8::from(lane.unread),
    }
}

/// `SidebarPriorityMachine.lanes`: one lane per session in first-seen order, the strongest tab's.
/// `first_seen` holds the times the app first saw a notice with no time (`"<session>#<key>"`);
/// a key missing there counts from `now`.
pub fn machine_lanes(
    tabs: &[MachineTab],
    machine: Option<&str>,
    generation: Option<&str>,
    first_seen: &BTreeMap<String, f64>,
    now: f64,
) -> Vec<Lane> {
    let mut order: Vec<String> = Vec::new();
    let mut lanes: BTreeMap<String, Lane> = BTreeMap::new();
    for tab in tabs {
        let Some(session) = tab.session.as_deref().filter(|s| !s.is_empty()) else { continue };
        let lane = machine_lane(tab, session, machine, generation, first_seen, now);
        match lanes.get(session) {
            Some(held) => {
                if strength(&lane) > strength(held) {
                    lanes.insert(session.to_owned(), lane);
                }
            }
            None => {
                order.push(session.to_owned());
                lanes.insert(session.to_owned(), lane);
            }
        }
    }
    order.into_iter().filter_map(|s| lanes.remove(&s)).collect()
}

/// `SidebarPriorityMachine.waitingLanes`: the first unread warning tab of each session.
pub fn machine_waiting_lanes(
    tabs: &[MachineTab],
    machine: Option<&str>,
    generation: Option<&str>,
    first_seen: &BTreeMap<String, f64>,
    now: f64,
) -> Vec<Lane> {
    let mut seen = HashSet::new();
    tabs.iter()
        .filter_map(|tab| {
            let warning = tab.notice.as_ref().and_then(|n| n.level) == Some(NoticeLevel::Warning);
            let session = tab.session.as_deref().filter(|s| !s.is_empty())?;
            (tab.has_unread && warning && seen.insert(session.to_owned()))
                .then(|| machine_lane(tab, session, machine, generation, first_seen, now))
        })
        .collect()
}

// MARK: - Session tree

/// A workspace's state in the tree (`SidebarAgentState`), weakest first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentState {
    Idle,
    FinishedUnread,
    Running,
    Failed,
    Blocked,
}

/// `SidebarSessionTreeFeed.state`: a lane's state in the tree's terms.
pub fn tree_state(state: LaneState) -> AgentState {
    match state {
        LaneState::Input => AgentState::Blocked,
        LaneState::Failed | LaneState::Lost => AgentState::Failed,
        LaneState::Working => AgentState::Running,
        LaneState::Idle => AgentState::Idle,
    }
}

/// A pull request as the chat header's reader answers (`AgentPanePullRequest`).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct PullRequest {
    pub url: String,
    pub number: i64,
    pub title: String,
    pub state: String,
    pub mergeable: Option<String>,
    /// `checks.state`.
    pub checks: Option<String>,
    pub additions: i64,
    pub deletions: i64,
    pub created_at: String,
}

/// A pull request's line in the hover card (`SidebarPullRequestItem.State`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ItemState {
    Conflict,
    Failing,
    Passing,
    Draft,
    Merged,
    Closed,
}

/// A badge's color, mildest first (`SidebarPullRequestBadge.Status`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BadgeStatus {
    Merged,
    Passing,
    Attention,
    Failing,
}

impl ItemState {
    /// `badgeStatus`: a closed one leaves the badge.
    pub fn badge_status(self) -> Option<BadgeStatus> {
        match self {
            Self::Conflict | Self::Draft => Some(BadgeStatus::Attention),
            Self::Failing => Some(BadgeStatus::Failing),
            Self::Passing => Some(BadgeStatus::Passing),
            Self::Merged => Some(BadgeStatus::Merged),
            Self::Closed => None,
        }
    }
}

/// `SidebarPullRequestItem`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub url: String,
    pub repository: String,
    pub number: i64,
    pub title: String,
    pub state: ItemState,
    pub additions: i64,
    pub deletions: i64,
    pub created_at: String,
}

/// `SidebarPullRequestBadge`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Badge {
    pub count: usize,
    pub status: BadgeStatus,
    pub items: Vec<Item>,
}

/// `SidebarPullRequestItem.repository(of:)`: `owner/repo` of a pull request page, else empty.
pub fn repository(url: &str) -> String {
    let parts: Vec<&str> = url.split('/').filter(|p| !p.is_empty()).collect();
    match parts.as_slice() {
        ["https:", _, owner, repo, "pull", _, ..] => format!("{owner}/{repo}"),
        _ => String::new(),
    }
}

/// `SidebarSessionTreeFeed.item`: failed checks before a conflict; pending reads as passing.
pub fn item(pull_request: &PullRequest) -> Item {
    let state = match pull_request.state.as_str() {
        "merged" => ItemState::Merged,
        "closed" => ItemState::Closed,
        "draft" => ItemState::Draft,
        _ if pull_request.checks.as_deref() == Some("failing") => ItemState::Failing,
        _ if pull_request.mergeable.as_deref() == Some("conflicting") => ItemState::Conflict,
        _ => ItemState::Passing,
    };
    Item {
        url: pull_request.url.clone(),
        repository: repository(&pull_request.url),
        number: pull_request.number,
        title: pull_request.title.clone(),
        state,
        additions: pull_request.additions,
        deletions: pull_request.deletions,
        created_at: pull_request.created_at.clone(),
    }
}

/// `SidebarPullRequestBadge.combining(_:)`: the count and the worst color.
pub fn combining(statuses: &[BadgeStatus]) -> Option<(usize, BadgeStatus)> {
    statuses.iter().max().map(|worst| (statuses.len(), *worst))
}

/// `SidebarPullRequestBadge.combining(items:)`: the items newest first.
pub fn combining_items(items: Vec<Item>) -> Option<Badge> {
    let statuses: Vec<BadgeStatus> = items.iter().filter_map(|i| i.state.badge_status()).collect();
    let (count, status) = combining(&statuses)?;
    let mut items = items;
    items.sort_by(|a, b| (&b.created_at, b.number, &b.url).cmp(&(&a.created_at, a.number, &a.url)));
    Some(Badge { count, status, items })
}

/// `SidebarSessionTreeFeed.asks`: the sessions' folders, sorted, then the pull request URLs they
/// opened, each once in order.
pub fn asks<'a>(lanes: impl IntoIterator<Item = &'a Lane> + Clone) -> Vec<String> {
    let folders: BTreeSet<&String> =
        lanes.clone().into_iter().filter_map(|l| l.cwd.as_ref()).collect();
    let mut opened: Vec<String> = Vec::new();
    for url in lanes.into_iter().flat_map(|l| l.pull_requests.iter()) {
        if !opened.contains(url) {
            opened.push(url.clone());
        }
    }
    folders.into_iter().cloned().chain(opened).collect()
}

/// `SidebarSessionTreeFeed.badge`: each pull request once.
pub fn badge(asks: &[String], answers: &BTreeMap<String, PullRequest>) -> Option<Badge> {
    let mut seen = HashSet::new();
    let items: Vec<Item> = asks
        .iter()
        .filter_map(|ask| answers.get(ask))
        .filter(|pr| seen.insert(pr.url.clone()))
        .map(item)
        .collect();
    combining_items(items)
}

/// `SidebarSessionTreeFeed.checksFailing`: a pull request of the lane's has failing checks, while
/// the sidebar reads them at all (`reads`: the session tree or the Priority view is on).
pub fn checks_failing(lane: &Lane, answers: &BTreeMap<String, PullRequest>, reads: bool) -> bool {
    reads
        && asks([lane])
            .iter()
            .any(|ask| answers.get(ask).is_some_and(|pr| item(pr).state == ItemState::Failing))
}

/// `SidebarSessionTreeFeed.reaches`: following `parents` up from `start` reaches `target`.
pub fn reaches(start: &str, target: &str, parents: &BTreeMap<String, String>) -> bool {
    let mut seen = HashSet::new();
    let mut next = Some(start);
    while let Some(node) = next {
        if !seen.insert(node) {
            break;
        }
        if node == target {
            return true;
        }
        next = parents.get(node).map(String::as_str);
    }
    false
}

/// A session on one daemon (`AgentSessionParents.Identity`).
#[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Identity {
    pub host: String,
    pub session: Option<String>,
}

/// One recorded caller (`AgentSessionParents.parents`' entry).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Recorded {
    pub child: Identity,
    pub parent: Identity,
}

/// One workspace's agent chat tabs, in model order.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct WorkspaceChats {
    pub id: String,
    pub refs: Vec<SessionRef>,
}

/// The tree pass's inputs.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct TreeInputs {
    pub chats: Vec<WorkspaceChats>,
    /// This Mac's acpmux lanes by session.
    pub lanes: BTreeMap<String, Lane>,
    /// Each other daemon's links (child session to parent session) by host.
    pub remote_parents_by_host: BTreeMap<String, BTreeMap<String, String>>,
    pub host_aliases: BTreeMap<String, BTreeSet<String>>,
    pub recorded_parents: Vec<Recorded>,
    pub local_host: Option<String>,
    pub pull_requests: BTreeMap<String, PullRequest>,
}

/// `SidebarSessionTreeFeed.Pass` (its state's parents, states and badges, and the asks).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TreePass {
    pub parents: BTreeMap<String, String>,
    pub states: BTreeMap<String, AgentState>,
    pub pull_requests: BTreeMap<String, Badge>,
    /// Sorted.
    pub asks: Vec<String>,
    pub shows_tree: bool,
    pub reads_pull_requests: bool,
}

/// `SidebarSessionTreeFeed.pass`: the lineage (remote daemons' links, this Mac's `spawnedBy`, then
/// the recorded callers where no daemon lists one), each workspace's strongest agent state and its
/// pull request badge. Workspaces go in model order (Swift walked its dictionaries).
pub fn tree_pass(inputs: &TreeInputs) -> TreePass {
    let local_host = inputs.local_host.as_deref();
    let mut sessions: Vec<(&str, Vec<&SessionRef>)> = Vec::new();
    let mut remote: Vec<(&str, Vec<&SessionRef>)> = Vec::new();
    let mut owner: BTreeMap<(&str, &str), &str> = BTreeMap::new();
    fn bucket<'a>(list: &mut Vec<(&'a str, Vec<&'a SessionRef>)>, id: &'a str, r: &'a SessionRef) {
        match list.iter_mut().find(|(held, _)| *held == id) {
            Some((_, refs)) => refs.push(r),
            None => list.push((id, vec![r])),
        }
    }
    for chats in &inputs.chats {
        for r in &chats.refs {
            let Some(session) = r.session.as_deref() else { continue };
            if Some(r.host.as_str()) == local_host {
                bucket(&mut sessions, &chats.id, r);
            } else {
                bucket(&mut remote, &chats.id, r);
            }
            owner.entry((r.host.as_str(), session)).or_insert(&chats.id);
        }
    }
    let keys = |host: &str| -> Vec<String> {
        let mut keys = vec![host.to_owned()];
        if let Some(aliases) = inputs.host_aliases.get(host) {
            keys.extend(aliases.iter().cloned());
        }
        keys
    };
    let owning = |host: &str, session: &str| -> Option<String> {
        keys(host)
            .iter()
            .find_map(|key| owner.get(&(key.as_str(), session)).map(|id| (*id).to_owned()))
    };
    let empty = BTreeMap::new();
    let daemon_links = |host: &str| -> &BTreeMap<String, String> {
        keys(host).iter().find_map(|key| inputs.remote_parents_by_host.get(key)).unwrap_or(&empty)
    };
    let recorded_parent = |host: &str, session: &str| -> Option<&Identity> {
        keys(host).iter().find_map(|key| {
            inputs
                .recorded_parents
                .iter()
                .find(|r| r.child.host == *key && r.child.session.as_deref() == Some(session))
                .map(|r| &r.parent)
        })
    };
    let mut pass = TreePass::default();
    let mut asks_all: BTreeSet<String> = BTreeSet::new();
    for (id, refs) in &remote {
        let parent = refs
            .iter()
            .filter_map(|child| {
                let session = child.session.as_deref()?;
                let parent = daemon_links(&child.host).get(session)?;
                owning(&child.host, parent)
            })
            .find(|p| p != id && !reaches(p, id, &pass.parents));
        if let Some(parent) = parent {
            pass.parents.insert((*id).to_owned(), parent);
        }
    }
    for (id, refs) in &sessions {
        let shown: Vec<&Lane> = refs
            .iter()
            .filter_map(|r| r.session.as_ref().and_then(|s| inputs.lanes.get(s)))
            .collect();
        let parent = shown
            .iter()
            .filter_map(|lane| {
                let parent = lane.spawned_by.as_deref()?;
                owner.get(&(local_host?, parent)).map(|p| (*p).to_owned())
            })
            .find(|p| p != id && !reaches(p, id, &pass.parents));
        if let Some(parent) = parent {
            pass.parents.insert((*id).to_owned(), parent);
        }
        if let Some(state) = shown.iter().map(|lane| tree_state(lane.state)).max() {
            pass.states.insert((*id).to_owned(), state);
        }
        let wanted = asks(shown.iter().copied());
        if let Some(badge) = badge(&wanted, &inputs.pull_requests) {
            pass.pull_requests.insert((*id).to_owned(), badge);
        }
        asks_all.extend(wanted);
    }
    for chats in &inputs.chats {
        if pass.parents.contains_key(&chats.id) {
            continue;
        }
        let parent = chats
            .refs
            .iter()
            .filter_map(|r| {
                let session = r.session.as_deref()?;
                let daemon = if Some(r.host.as_str()) == local_host {
                    inputs.lanes.get(session).and_then(|l| l.spawned_by.clone())
                } else {
                    daemon_links(&r.host).get(session).cloned()
                };
                if daemon.is_some() {
                    return None;
                }
                let parent = recorded_parent(&r.host, session)?;
                owning(&parent.host, parent.session.as_deref()?)
            })
            .find(|p| *p != chats.id && !reaches(p, &chats.id, &pass.parents));
        if let Some(parent) = parent {
            pass.parents.insert(chats.id.clone(), parent);
        }
    }
    pass.asks = asks_all.into_iter().collect();
    pass.shows_tree = true;
    pass.reads_pull_requests = true;
    pass
}

/// `SidebarSessionTreeFeed.holding`: while acpmux's lanes are not live the saved lineage wins, and
/// a parent found since is added where it closes no loop.
pub fn holding(
    parents: &BTreeMap<String, String>,
    saved: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    if saved.is_empty() {
        return parents.clone();
    }
    let mut held = BTreeMap::new();
    for (child, parent) in saved {
        if child != parent && !reaches(parent, child, &held) {
            held.insert(child.clone(), parent.clone());
        }
    }
    for (child, parent) in parents {
        if !held.contains_key(child) && child != parent && !reaches(parent, child, &held) {
            held.insert(child.clone(), parent.clone());
        }
    }
    held
}

/// `SidebarSessionTreeFeed.shaped`: the pass as the settings shape it.
pub fn shaped(mut pass: TreePass, session_tree: bool, nests: bool, reads: bool) -> TreePass {
    pass.shows_tree = session_tree || (nests && !pass.parents.is_empty());
    pass.reads_pull_requests = reads;
    if !nests {
        pass.parents.clear();
    }
    pass
}

/// `SidebarSessionTreeFeed.workspaces(showing:in:localHost:)`: the workspaces whose tab on this
/// Mac shows one of `sessions`, with that session.
pub fn workspaces_showing(
    sessions: &BTreeSet<String>,
    chats: &[WorkspaceChats],
    local_host: &str,
) -> BTreeMap<String, String> {
    chats
        .iter()
        .filter_map(|chats| {
            chats
                .refs
                .iter()
                .filter(|r| r.host == local_host)
                .filter_map(|r| r.session.as_ref())
                .find(|s| sessions.contains(*s))
                .map(|s| (chats.id.clone(), s.clone()))
        })
        .collect()
}

/// What the pull request store holds of one key.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct StoreKey {
    /// The answer's `state` (`open`, `draft`, `merged`, `closed`), none without one.
    pub answer: Option<String>,
    /// Seconds since the key was last asked; none when never.
    pub elapsed: Option<f64>,
    pub failures: u32,
    pub asking: bool,
}

/// The keys the store asks again: folders one by one, URLs in one batch, each sorted.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Stale {
    pub folders: Vec<String>,
    pub urls: Vec<String>,
}

/// `SidebarPullRequestStore.refresh`'s choice: a key is stale unless it is being asked, settled
/// (a merged URL), out of flight on a recheck, or asked within its wait (`freshness`, doubled per
/// failure up to `MAXIMUM_BACKOFF`).
pub fn stale(
    asks: &BTreeSet<String>,
    store: &BTreeMap<String, StoreKey>,
    freshness: f64,
    only_in_flight: bool,
) -> Stale {
    let blank = StoreKey::default();
    let mut out = Stale::default();
    for key in asks {
        let held = store.get(key).unwrap_or(&blank);
        let url = key.starts_with("https://");
        let settled = url && held.answer.as_deref() == Some("merged");
        let in_flight = held.answer.as_deref().is_some_and(|s| s != "merged" && s != "closed");
        let wait = freshness * f64::from(1u32 << held.failures.min(MAXIMUM_BACKOFF));
        let due = held.elapsed.is_none_or(|elapsed| elapsed >= wait);
        if !held.asking && !settled && (!only_in_flight || in_flight) && due {
            if url { out.urls.push(key.clone()) } else { out.folders.push(key.clone()) }
        }
    }
    out
}

// MARK: - Chief

/// `ChiefSessionRole`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ChiefRole {
    Turn,
    Subagent,
    Other,
}

fn swift_int(text: &str) -> Option<i64> {
    text.parse().ok()
}

/// `ChiefSessionRole(name:)`: `optchat-<home>-<n>[-<m>]` is a turn, `optchat-sub-…` a subagent.
pub fn chief_role(name: &str) -> ChiefRole {
    let parts: Vec<&str> = name.split('-').collect();
    match parts.as_slice() {
        ["optchat", "sub", _, ..] => ChiefRole::Subagent,
        ["optchat", kind, numbers @ ..]
            if *kind != "compact"
                && !numbers.is_empty()
                && numbers.len() <= 2
                && numbers.iter().all(|n| swift_int(n).is_some()) =>
        {
            ChiefRole::Turn
        }
        _ => ChiefRole::Other,
    }
}

fn name_parts(name: &str) -> Vec<&str> {
    name.split('-').filter(|p| !p.is_empty()).collect()
}

/// `AgentActivityLane.turnNumber`.
pub fn turn_number(name: &str) -> Option<i64> {
    name_parts(name).get(2).and_then(|p| swift_int(p))
}

/// `AgentActivityLane.subagentNumber`: `a<n>` in the fourth part.
pub fn subagent_number(name: &str) -> Option<i64> {
    let parts = name_parts(name);
    parts.get(3).and_then(|p| p.strip_prefix('a')).and_then(swift_int)
}

/// `String.chiefTaskTitle`: the title less a leading `a<digits> · ` id; none when empty.
pub fn chief_task_title(title: &str) -> Option<String> {
    let mut rest = title.trim_start_matches(char::is_whitespace);
    if let Some((prefix, title)) = rest.split_once(" · ")
        && let Some(number) = prefix.strip_prefix('a')
        && !number.is_empty()
        && number.chars().all(char::is_numeric)
    {
        rest = title;
    }
    let trimmed = rest.trim_matches(is_blank);
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

/// `AgentActivityLane.subagentTitle`: the task title, empty when it is only the name.
pub fn subagent_title(lane: &Lane) -> String {
    if lane.title == lane.name {
        return String::new();
    }
    chief_task_title(&lane.title).unwrap_or_default()
}

/// The Chief item's status (`chiefStatus`): its turns' activity, and how many subagents need you.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChiefStatus {
    pub activity: Indicator,
    pub badge: Option<usize>,
}

/// `chiefActivity`: a turn asking, else one working, else the newest turn's.
pub fn chief_activity(turns: &[&Lane]) -> Indicator {
    if turns.iter().any(|l| l.state == LaneState::Input) {
        return Indicator::Waiting;
    }
    if turns.iter().any(|l| l.state == LaneState::Working) {
        return Indicator::Working;
    }
    let mut newest: Option<&Lane> = None;
    for lane in turns {
        let number = turn_number(&lane.name).unwrap_or(-1);
        if newest.is_none_or(|held| turn_number(&held.name).unwrap_or(-1) < number) {
            newest = Some(lane);
        }
    }
    newest.map_or(Indicator::Idle, |lane| indicator(lane.state))
}

/// `SidebarTransientItem.chiefStatus`.
pub fn chief_status(lanes: &[Lane]) -> ChiefStatus {
    let turns: Vec<&Lane> =
        lanes.iter().filter(|l| chief_role(&l.name) == ChiefRole::Turn).collect();
    let attention = lanes
        .iter()
        .filter(|l| chief_role(&l.name) == ChiefRole::Subagent && l.state.needs_attention())
        .count();
    ChiefStatus { activity: chief_activity(&turns), badge: (attention > 0).then_some(attention) }
}

/// One Chief subagent row (`chiefSubagents`' item, less its brand and color).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChiefSubagent {
    /// `chief-sub:<lane id>`, after the transient prefix.
    pub id: String,
    pub session: String,
    pub title: String,
    pub activity: Indicator,
    pub harness: Option<String>,
}

/// `SidebarTransientItem.chiefSubagents`: subagents in number order (then name); idle ones only
/// when `shows_idle`. Each row draws after the one before it.
pub fn chief_subagents(lanes: &[Lane], shows_idle: bool) -> Vec<ChiefSubagent> {
    let mut subagents: Vec<&Lane> =
        lanes.iter().filter(|l| chief_role(&l.name) == ChiefRole::Subagent).collect();
    subagents.sort_by(|a, b| {
        (subagent_number(&a.name).unwrap_or(i64::MAX), &a.name)
            .cmp(&(subagent_number(&b.name).unwrap_or(i64::MAX), &b.name))
    });
    subagents
        .into_iter()
        .filter(|lane| shows_idle || lane.state != LaneState::Idle)
        .map(|lane| ChiefSubagent {
            id: format!("{CHIEF_SUBAGENT_PREFIX}{}", lane.id),
            session: lane.id.clone(),
            title: subagent_title(lane),
            activity: indicator(lane.state),
            harness: lane.harness.clone(),
        })
        .collect()
}

// MARK: - Chat history

/// An acpmux chat window's spec (`AcpmuxChatWindows.Spec`).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowSpec {
    pub window: String,
    pub limit: i64,
    pub top_level: bool,
    pub exclude: Vec<String>,
    pub keys: Vec<String>,
}

/// `Inputs.earlierSpec`: the page (one row while folded), less the live and pinned chats.
pub fn earlier_spec(
    live: &BTreeSet<String>,
    pinned: &[String],
    limit: i64,
    folded: bool,
) -> WindowSpec {
    let exclude: BTreeSet<&String> = live.iter().chain(pinned).collect();
    WindowSpec {
        window: EARLIER_WINDOW.to_owned(),
        limit: if folded { 1 } else { limit.max(1) },
        top_level: true,
        exclude: exclude.into_iter().cloned().collect(),
        keys: Vec::new(),
    }
}

/// `Inputs.pinnedSpec`: the pinned chats by key.
pub fn pinned_spec(pinned: &[String]) -> WindowSpec {
    WindowSpec {
        window: PINNED_WINDOW.to_owned(),
        limit: (pinned.len() as i64).max(1),
        top_level: false,
        exclude: Vec::new(),
        keys: pinned.to_vec(),
    }
}

/// `historyChat`'s title: the chat's title, else its folder's name, else its harness.
pub fn history_title(title: Option<&str>, cwd: Option<&str>, harness: &str) -> String {
    if let Some(title) = title {
        return title.to_owned();
    }
    // `NSString.lastPathComponent`: trailing slashes go; "/" stays "/".
    let folder = cwd.map(|cwd| {
        let trimmed = cwd.trim_end_matches('/');
        if trimmed.is_empty() && !cwd.is_empty() {
            "/".to_owned()
        } else {
            trimmed.rsplit('/').next().unwrap_or_default().to_owned()
        }
    });
    folder.filter(|f| !f.is_empty()).unwrap_or_else(|| harness.to_owned())
}

// MARK: - JSON

fn idle_horizon() -> f64 {
    IDLE_HORIZON
}

/// One rule's request.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(tag = "rule", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Request {
    Entries {
        lanes: Vec<Lane>,
        #[serde(default)]
        marks: Marks,
        now: f64,
        #[serde(default)]
        failing_checks: BTreeSet<String>,
        #[serde(default)]
        machines: BTreeMap<String, Option<String>>,
        #[serde(default = "idle_horizon")]
        idle_horizon: f64,
    },
    NextChange {
        lanes: Vec<Lane>,
        #[serde(default)]
        marks: Marks,
        now: f64,
        #[serde(default)]
        failing_checks: BTreeSet<String>,
        #[serde(default = "idle_horizon")]
        idle_horizon: f64,
    },
    NeedingInput {
        lanes: Vec<Lane>,
        #[serde(default)]
        marks: Marks,
        now: f64,
    },
    Unread {
        lanes: Vec<Lane>,
        #[serde(default)]
        marks: Marks,
        now: f64,
    },
    Running {
        lanes: Vec<Lane>,
        #[serde(default)]
        marks: Marks,
        now: f64,
    },
    NextAfter {
        previous: Option<String>,
        ids: Vec<String>,
    },
    Stamp {
        lane: Lane,
    },
    Place {
        #[serde(default)]
        marks: Marks,
        id: String,
        order: Vec<String>,
    },
    Prune {
        #[serde(default)]
        marks: Marks,
        keeping: BTreeSet<String>,
    },
    /// A row's lane status: the merge, chip, now line and Done pill.
    RowStatus {
        lanes: Vec<Lane>,
        #[serde(default)]
        row: RowActivity,
        #[serde(default)]
        marks: Marks,
        #[serde(default)]
        failing_checks: BTreeSet<String>,
    },
    LocalLanes {
        tabs: Vec<Option<SessionRef>>,
        lanes: BTreeMap<String, Lane>,
        local_host: Option<String>,
    },
    KeepsWorkspace {
        tabs: Vec<Option<SessionRef>>,
        local_host: Option<String>,
        live: bool,
        before_gap: Option<BTreeSet<String>>,
        #[serde(default)]
        live_sessions: BTreeSet<String>,
    },
    WaitingChats {
        waiting: Vec<String>,
        lanes: BTreeMap<String, Lane>,
        enabled: bool,
    },
    MachineLanes {
        tabs: Vec<MachineTab>,
        machine: Option<String>,
        generation: Option<String>,
        #[serde(default)]
        first_seen: BTreeMap<String, f64>,
        now: f64,
        #[serde(default)]
        waiting: bool,
    },
    TreePass {
        #[serde(flatten)]
        inputs: TreeInputs,
        #[serde(default = "yes")]
        session_tree: bool,
        #[serde(default)]
        nests: bool,
        #[serde(default = "yes")]
        reads: bool,
    },
    Holding {
        parents: BTreeMap<String, String>,
        saved: BTreeMap<String, String>,
    },
    Badge {
        asks: Vec<String>,
        answers: BTreeMap<String, PullRequest>,
    },
    ChecksFailing {
        lanes: Vec<Lane>,
        answers: BTreeMap<String, PullRequest>,
        reads: bool,
    },
    WorkspacesShowing {
        sessions: BTreeSet<String>,
        chats: Vec<WorkspaceChats>,
        local_host: String,
    },
    Stale {
        asks: BTreeSet<String>,
        #[serde(default)]
        store: BTreeMap<String, StoreKey>,
        freshness: f64,
        #[serde(default)]
        only_in_flight: bool,
    },
    Chief {
        lanes: Vec<Lane>,
        #[serde(default)]
        shows_idle: bool,
    },
    ChiefTaskTitle {
        title: String,
    },
    History {
        #[serde(default)]
        live: BTreeSet<String>,
        #[serde(default)]
        pinned: Vec<String>,
        limit: i64,
        #[serde(default)]
        folded: bool,
    },
    HistoryTitle {
        title: Option<String>,
        cwd: Option<String>,
        harness: String,
    },
}

fn yes() -> bool {
    true
}

/// A row's lane status (`SidebarLaneStatus.applying`'s rules).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RowStatus {
    pub merged: Merged,
    pub chip: Option<PriorityState>,
    pub step: Option<String>,
    pub agent_done: bool,
    /// The lanes whose failure another went on past.
    pub superseded: Vec<String>,
}

/// One rule's answer.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(untagged, rename_all_fields = "camelCase")]
pub enum Response {
    Entries { entries: Vec<PriorityEntry> },
    NextChange { next_change: Option<f64> },
    Ids { ids: Vec<String> },
    Next { next: Option<String> },
    Stamp { stamp: String },
    Marks { marks: Marks },
    RowStatus(RowStatus),
    Lanes { lanes: Vec<Lane> },
    Keeps { keeps: bool },
    Waiting { waiting: BTreeMap<String, Wait> },
    Tree(TreePass),
    Parents { parents: BTreeMap<String, String> },
    Badge { badge: Option<Badge> },
    Failing { failing: Vec<String> },
    Workspaces { workspaces: BTreeMap<String, String> },
    Stale(Stale),
    Chief { status: ChiefStatus, subagents: Vec<ChiefSubagent> },
    Title { title: Option<String> },
    History { earlier: WindowSpec, pinned: WindowSpec },
}

/// Answers one request.
pub fn respond(request: &Request) -> Response {
    match request {
        Request::Entries { lanes, marks, now, failing_checks, machines, idle_horizon } => {
            Response::Entries {
                entries: entries(lanes, marks, *now, failing_checks, machines, *idle_horizon),
            }
        }
        Request::NextChange { lanes, marks, now, failing_checks, idle_horizon } => {
            Response::NextChange {
                next_change: next_change(lanes, marks, *now, failing_checks, *idle_horizon),
            }
        }
        Request::NeedingInput { lanes, marks, now } => {
            Response::Ids { ids: needing_input(lanes, marks, *now) }
        }
        Request::Unread { lanes, marks, now } => Response::Ids { ids: unread(lanes, marks, *now) },
        Request::Running { lanes, marks, now } => {
            Response::Ids { ids: running(lanes, marks, *now) }
        }
        Request::NextAfter { previous, ids } => {
            Response::Next { next: next_after(previous.as_deref(), ids) }
        }
        Request::Stamp { lane } => Response::Stamp { stamp: stamp(lane) },
        Request::Place { marks, id, order } => {
            let mut marks = marks.clone();
            marks.place(id, order);
            Response::Marks { marks }
        }
        Request::Prune { marks, keeping } => {
            let mut marks = marks.clone();
            marks.prune(keeping);
            Response::Marks { marks }
        }
        Request::RowStatus { lanes, row, marks, failing_checks } => {
            let standing = without_superseded_failures(lanes);
            let kept: HashSet<&str> = standing.iter().map(|l| l.id.as_str()).collect();
            let superseded: BTreeSet<String> = lanes
                .iter()
                .filter(|l| !kept.contains(l.id.as_str()))
                .map(|l| l.id.clone())
                .collect();
            Response::RowStatus(RowStatus {
                merged: merge(&standing, row),
                chip: chip(lanes, marks, failing_checks, &superseded),
                step: step(lanes),
                agent_done: agent_done(lanes, marks),
                superseded: superseded.into_iter().collect(),
            })
        }
        Request::LocalLanes { tabs, lanes, local_host } => {
            Response::Lanes { lanes: local_lanes(tabs, lanes, local_host.as_deref()) }
        }
        Request::KeepsWorkspace { tabs, local_host, live, before_gap, live_sessions } => {
            Response::Keeps {
                keeps: keeps_workspace(
                    tabs,
                    local_host.as_deref(),
                    *live,
                    before_gap.as_ref(),
                    live_sessions,
                ),
            }
        }
        Request::WaitingChats { waiting, lanes, enabled } => {
            Response::Waiting { waiting: waiting_chats(waiting, lanes, *enabled) }
        }
        Request::MachineLanes { tabs, machine, generation, first_seen, now, waiting } => {
            let read = if *waiting { machine_waiting_lanes } else { machine_lanes };
            Response::Lanes {
                lanes: read(tabs, machine.as_deref(), generation.as_deref(), first_seen, *now),
            }
        }
        Request::TreePass { inputs, session_tree, nests, reads } => {
            Response::Tree(shaped(tree_pass(inputs), *session_tree, *nests, *reads))
        }
        Request::Holding { parents, saved } => {
            Response::Parents { parents: holding(parents, saved) }
        }
        Request::Badge { asks, answers } => Response::Badge { badge: badge(asks, answers) },
        Request::ChecksFailing { lanes, answers, reads } => Response::Failing {
            failing: lanes
                .iter()
                .filter(|lane| checks_failing(lane, answers, *reads))
                .map(|lane| lane.id.clone())
                .collect(),
        },
        Request::WorkspacesShowing { sessions, chats, local_host } => {
            Response::Workspaces { workspaces: workspaces_showing(sessions, chats, local_host) }
        }
        Request::Stale { asks, store, freshness, only_in_flight } => {
            Response::Stale(stale(asks, store, *freshness, *only_in_flight))
        }
        Request::Chief { lanes, shows_idle } => Response::Chief {
            status: chief_status(lanes),
            subagents: chief_subagents(lanes, *shows_idle),
        },
        Request::ChiefTaskTitle { title } => Response::Title { title: chief_task_title(title) },
        Request::History { live, pinned, limit, folded } => Response::History {
            earlier: earlier_spec(live, pinned, *limit, *folded),
            pinned: pinned_spec(pinned),
        },
        Request::HistoryTitle { title, cwd, harness } => Response::Title {
            title: Some(history_title(title.as_deref(), cwd.as_deref(), harness)),
        },
    }
}

#[cfg(test)]
#[path = "sidebar_feeds_tests.rs"]
mod tests;
