//! Part of `Hub`; see `hub/mod.rs`. The sidebar's Priority view and Go to Next Agent Needing
//! Input, ranked here (rust-migration A6; layer-ownership.md rule 1: the order, the filter and
//! the rules of a list a client shows run in Rust). The Mac app ranked every lane it mirrored
//! (`AgentPriorityRanking.swift`) on the main thread at each lane change, many a second while
//! agents work; it now asks for its window (`priority_window.rs`) and applies row diffs.
//!
//! acpmux decides each session's lane (`views.rs` `lane`); this orders the lanes by what needs
//! the person and applies the person's marks:
//!
//! - a permission prompt or question first (`needsYou`), then a result nobody has seen (`done`),
//!   then a failed or lost turn, then Red CI (a pull request of the chat's with failing checks),
//!   then the ones working, then idle;
//! - within a tier pinned chats first, then the most recent change, then the id;
//! - a chat the person dragged shows at the place they dropped it, the others ranked around it;
//! - snoozed and archived chats are left out, and idle ones older than the idle horizon unless
//!   pinned or dragged to a place.
//!
//! A read or snooze mark holds for the lane state it was made on (its [`stamp`]): when the chat
//! moves on (a new question, a new result) it shows again. Times are epoch milliseconds.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// What a session is doing, as acpmux decided it (`lane.state`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LaneState {
    /// A turn runs.
    Working,
    /// A permission or question waits for the person.
    Input,
    /// Nothing runs; waiting for its next prompt.
    Idle,
    /// The last turn failed (`error` says why).
    Failed,
    /// The agent process is gone without an answer.
    Lost,
}

impl LaneState {
    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "working" => Self::Working,
            "input" => Self::Input,
            "idle" => Self::Idle,
            "failed" => Self::Failed,
            "lost" => Self::Lost,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Working => "working",
            Self::Input => "input",
            Self::Idle => "idle",
            Self::Failed => "failed",
            Self::Lost => "lost",
        }
    }

    /// A person should look: it waits on them, failed or was lost.
    pub fn needs_attention(self) -> bool {
        matches!(self, Self::Input | Self::Failed | Self::Lost)
    }
}

/// One session's lane, as the Priority view and the session tree read it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Lane {
    pub id: String,
    /// The lane's masked title, else the session's name.
    pub title: String,
    /// The acpmux peer that owns it; none on this daemon.
    pub peer: Option<String>,
    /// The machine tag a client named for a lane it read from another owner (another machine's
    /// daemon tree); a row shows it instead of `peer`.
    pub machine: Option<String>,
    pub state: LaneState,
    /// Since when it has been in `state`.
    pub since: Option<i64>,
    pub error: Option<String>,
    pub step: Option<String>,
    /// A turn ended while no client showed the chat.
    pub unread: bool,
    /// The session folder's name.
    pub project: Option<String>,
    pub harness: Option<String>,
    /// acpmux classifies agent-started sessions as needing an opened tab before a sidebar row.
    pub requires_open: bool,
    /// A lane a client reported (`archivable` in its summary) that an acpmux whose socket the
    /// client has lists (the Chief home's), so Archive can reach its owner. This daemon's own
    /// lanes are archivable whatever this says.
    pub archivable: bool,
    /// What a mark holds for beside the state when `since` cannot say it (another machine's
    /// chat tab's notice); none: `since`.
    pub mark_key: Option<String>,
    /// Its `mux.parent` tag.
    pub parent: Option<String>,
    /// The session whose agent started this one.
    pub spawned_by: Option<String>,
    pub cwd: Option<String>,
    /// The pull requests its `gh pr create` calls opened.
    pub pull_requests: Vec<String>,
    /// The chat index key (`harness:sessionId`) of the chat it continues.
    pub chat: Option<String>,
}

/// `value[key]` with no panic path: Null when `value` is no object or lacks `key`.
fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
    value.get(key).unwrap_or(&Value::Null)
}

fn text(value: &Value) -> Option<String> {
    value.as_str().filter(|s| !s.is_empty()).map(str::to_owned)
}

/// Epoch milliseconds from a JSON number (an integer, or a float a client sent).
fn millis(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| value.as_f64().map(|f| f as i64))
}

/// The last part of a folder path; none for an empty path or the root.
fn folder_name(cwd: &str) -> Option<String> {
    let trimmed = cwd.trim_end_matches('/');
    let name = trimmed.rsplit('/').next().unwrap_or_default();
    (!name.is_empty()).then(|| name.to_owned())
}

/// acpmux's `session_chat_key`: only the claude and codex families are indexed.
fn chat_key(family: Option<&str>, agent_session: Option<String>) -> Option<String> {
    let session = agent_session?;
    match family {
        Some("claude") => Some(format!("claude-code:{session}")),
        Some("codex") => Some(format!("codex:{session}")),
        _ => None,
    }
}

impl Lane {
    /// The lane of one session summary (`_acpmux/watch`, `session_changed`); none when acpmux
    /// decided none (a closed session). `id` names the session when the summary does not.
    pub fn of(summary: &Value, id: Option<&str>) -> Option<Self> {
        let id = text(field(summary, "sessionId")).or_else(|| id.map(str::to_owned))?;
        let lane = summary.get("lane").filter(|lane| lane.is_object())?;
        let state = LaneState::parse(field(lane, "state").as_str()?)?;
        let name = text(field(summary, "name")).unwrap_or_else(|| id.clone());
        let tags = field(summary, "tags");
        Some(Self {
            title: text(field(lane, "title")).unwrap_or(name),
            peer: text(field(summary, "peer")),
            machine: text(field(summary, "machine")),
            state,
            since: millis(field(lane, "since")),
            error: text(field(lane, "error")),
            step: text(field(lane, "step")),
            unread: field(summary, "unread").as_bool().unwrap_or(false),
            project: field(summary, "cwd").as_str().and_then(folder_name),
            harness: text(field(summary, "harness")),
            requires_open: field(lane, "requiresOpen").as_bool().unwrap_or(false),
            archivable: field(summary, "archivable").as_bool().unwrap_or(false),
            mark_key: text(field(summary, "markKey")),
            parent: text(field(tags, "mux.parent")),
            spawned_by: text(field(summary, "spawnedBy")),
            cwd: text(field(summary, "cwd")),
            pull_requests: field(summary, "pullRequests")
                .as_array()
                .map(|urls| urls.iter().filter_map(text).collect())
                .unwrap_or_default(),
            chat: chat_key(
                field(summary, "family").as_str(),
                text(field(summary, "agentSessionId")),
            ),
            id,
        })
    }

    /// What links the session to its folder, its pull requests and the chat it continues, and
    /// its state: all the session tree reads of a lane (a new step leaves it alone).
    pub fn links(&self) -> Value {
        json!({"id": self.id, "state": self.state.as_str(), "needsAttention": self.state.needs_attention(),
               "peer": self.peer, "parent": self.parent, "spawnedBy": self.spawned_by, "cwd": self.cwd,
               "pullRequests": self.pull_requests, "chat": self.chat})
    }
}

/// `ms` as the Mac app's marks wrote it: a `Date` from epoch milliseconds, back to whole
/// milliseconds (`Int64(date.timeIntervalSince1970 * 1000)`). A `Date` keeps seconds since 2001
/// as a double, so the round trip can lose one millisecond; doing the same arithmetic here keeps
/// the marks the app saved before this rule moved.
fn app_millis(ms: i64) -> i64 {
    const SINCE_1970: f64 = 978_307_200.0;
    let reference = ms as f64 / 1000.0 - SINCE_1970;
    ((reference + SINCE_1970) * 1000.0) as i64
}

/// What a mark on `lane` holds for: its state and since when, or the notice the lane names.
pub fn stamp(lane: &Lane) -> String {
    let at =
        lane.mark_key.clone().unwrap_or_else(|| app_millis(lane.since.unwrap_or(0)).to_string());
    format!("{}@{at}", lane.state.as_str())
}

/// The person's marks on the Priority view's chats: pinned, read, snoozed, archived and dragged
/// to a place, and whether the view is folded. Each may be missing: older marks still load.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Marks {
    pub pinned: BTreeSet<String>,
    /// Session id to the stamp of the state the person marked read.
    pub read: BTreeMap<String, String>,
    /// Session id to the stamp it was snoozed on and until when.
    pub snoozed: BTreeMap<String, Snooze>,
    pub archived: BTreeSet<String>,
    pub collapsed: bool,
    /// Session id to the place (0 is the top) the person dragged it to.
    pub placed: BTreeMap<String, usize>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snooze {
    pub stamp: String,
    pub until_ms: i64,
}

/// How long a snooze lasts by default.
pub const SNOOZE_MS: i64 = 60 * 60 * 1000;

impl Marks {
    pub fn is_snoozed(&self, id: &str, stamp: &str, now: i64) -> bool {
        self.snoozed.get(id).is_some_and(|s| s.stamp == stamp && now < s.until_ms)
    }

    pub fn mark_read(&mut self, lane: &Lane) {
        self.read.insert(lane.id.clone(), stamp(lane));
    }

    pub fn toggle_pin(&mut self, id: &str) {
        if !self.pinned.remove(id) {
            self.pinned.insert(id.to_owned());
        }
    }

    pub fn snooze(&mut self, lane: &Lane, duration_ms: i64, now: i64) {
        let snooze = Snooze { stamp: stamp(lane), until_ms: now.saturating_add(duration_ms) };
        self.snoozed.insert(lane.id.clone(), snooze);
    }

    /// Hides the chat; its pin stays until acpmux stops listing it.
    pub fn archive(&mut self, id: &str) {
        self.archived.insert(id.to_owned());
    }

    /// Undoes `archive` when acpmux refused it.
    pub fn unarchive(&mut self, id: &str) {
        self.archived.remove(id);
    }

    /// The person dragged `id` in the view, which now shows `order`: it keeps that place, and
    /// each chat dragged before keeps the place it shows at now.
    pub fn place(&mut self, id: &str, order: &[String]) {
        for (index, other) in order.iter().enumerate() {
            if other == id || self.placed.contains_key(other) {
                self.placed.insert(other.clone(), index);
            }
        }
    }

    /// Drops the marks of sessions no longer listed, so the saved marks stay small.
    pub fn prune(&mut self, keeping: &HashSet<String>) {
        self.pinned.retain(|id| keeping.contains(id));
        self.archived.retain(|id| keeping.contains(id));
        self.read.retain(|id, _| keeping.contains(id));
        self.snoozed.retain(|id, _| keeping.contains(id));
        self.placed.retain(|id, _| keeping.contains(id));
    }
}

/// The chip a Priority row shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RowState {
    NeedsYou,
    Done,
    Failed,
    Lost,
    CiFailing,
    Working,
    Idle,
}

impl RowState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NeedsYou => "needsYou",
            Self::Done => "done",
            Self::Failed => "failed",
            Self::Lost => "lost",
            Self::CiFailing => "ciFailing",
            Self::Working => "working",
            Self::Idle => "idle",
        }
    }

    pub fn tier(self) -> u8 {
        match self {
            Self::NeedsYou => 0,
            Self::Done => 1,
            Self::Failed | Self::Lost => 2,
            Self::CiFailing => 3,
            Self::Working => 4,
            Self::Idle => 5,
        }
    }

    /// The row counts toward the view's attention count and the bell's dot.
    pub fn needs_attention(self) -> bool {
        !matches!(self, Self::Working | Self::Idle)
    }

    /// The row offers Mark as Read.
    pub fn can_mark_read(self) -> bool {
        self.needs_attention() && self != Self::NeedsYou && self != Self::CiFailing
    }
}

/// The chip a lane shows: its turn's, unless `failing_checks` ranks higher, which it does over
/// working and idle. Marking a finished, failed or lost chat read drops it to idle, or to Red CI
/// while the checks still fail.
pub fn row_state(lane: &Lane, read: bool, failing_checks: bool) -> RowState {
    let turn = match lane.state {
        LaneState::Input => RowState::NeedsYou,
        LaneState::Working => RowState::Working,
        LaneState::Failed if read => RowState::Idle,
        LaneState::Failed => RowState::Failed,
        LaneState::Lost if read => RowState::Idle,
        LaneState::Lost => RowState::Lost,
        LaneState::Idle if lane.unread && !read => RowState::Done,
        LaneState::Idle => RowState::Idle,
    };
    if failing_checks && RowState::CiFailing.tier() < turn.tier() {
        RowState::CiFailing
    } else {
        turn
    }
}

/// The failed turn's error, else what the chat is doing or last said (both masked by acpmux).
pub fn preview(lane: &Lane) -> Option<String> {
    match (lane.state, &lane.error) {
        (LaneState::Failed | LaneState::Lost, Some(error)) => Some(error.clone()),
        _ => lane.step.clone(),
    }
}

/// One Priority row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub id: String,
    pub title: String,
    pub project: Option<String>,
    /// The client's machine tag for the lane, else its acpmux peer.
    pub machine: Option<String>,
    pub preview: Option<String>,
    pub state: RowState,
    pub since: Option<i64>,
    pub unread: bool,
    pub pinned: bool,
    pub harness: Option<String>,
}

impl Row {
    pub fn value(&self) -> Value {
        json!({"id": self.id, "title": self.title, "project": self.project, "machine": self.machine,
               "preview": self.preview, "state": self.state.as_str(), "since": self.since,
               "unread": self.unread, "pinned": self.pinned, "harness": self.harness,
               "needsAttention": self.state.needs_attention(), "canMarkRead": self.state.can_mark_read()})
    }
}

/// The Priority view's order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ranking {
    /// An idle chat with nothing unseen leaves the view after this long, unless pinned.
    pub idle_horizon_ms: i64,
}

impl Default for Ranking {
    fn default() -> Self {
        Self { idle_horizon_ms: 24 * 60 * 60 * 1000 }
    }
}

/// A row with what it sorts by.
struct Ranked {
    row: Row,
    tier: u8,
    since: i64,
}

impl Ranking {
    /// The rows in rank order (see the module notes). `failing` are the ids of the chats with a
    /// pull request whose checks fail.
    pub fn entries(
        &self,
        lanes: &[Lane],
        marks: &Marks,
        now: i64,
        failing: &HashSet<String>,
    ) -> Vec<Row> {
        let ranked: Vec<Ranked> =
            lanes.iter().filter_map(|lane| self.ranked(lane, marks, now, failing)).collect();
        let (placed, mut free): (Vec<Ranked>, Vec<Ranked>) =
            ranked.into_iter().partition(|r| marks.placed.contains_key(&r.row.id));
        free.sort_by(|a, b| {
            a.tier
                .cmp(&b.tier)
                .then(b.row.pinned.cmp(&a.row.pinned))
                .then(b.since.cmp(&a.since))
                .then(a.row.id.cmp(&b.row.id))
        });
        let mut rows: Vec<Row> = free.into_iter().map(|r| r.row).collect();
        // The dragged chats go back in where the person put them, the top place first.
        let mut placed: Vec<(usize, Row)> = placed
            .into_iter()
            .map(|r| (marks.placed.get(&r.row.id).copied().unwrap_or(0), r.row))
            .collect();
        placed.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.id.cmp(&b.1.id)));
        for (place, row) in placed {
            rows.insert(place.min(rows.len()), row);
        }
        rows
    }

    fn ranked(
        &self,
        lane: &Lane,
        marks: &Marks,
        now: i64,
        failing: &HashSet<String>,
    ) -> Option<Ranked> {
        let stamp = stamp(lane);
        if marks.archived.contains(&lane.id) || marks.is_snoozed(&lane.id, &stamp, now) {
            return None;
        }
        let read = marks.read.get(&lane.id) == Some(&stamp);
        let pinned = marks.pinned.contains(&lane.id);
        let state = row_state(lane, read, failing.contains(&lane.id));
        let kept = pinned || marks.placed.contains_key(&lane.id);
        if state == RowState::Idle
            && !kept
            && lane.since.is_some_and(|since| now.saturating_sub(since) > self.idle_horizon_ms)
        {
            return None;
        }
        let row = Row {
            id: lane.id.clone(),
            title: lane.title.clone(),
            project: lane.project.clone(),
            machine: lane.machine.clone().or_else(|| lane.peer.clone()),
            preview: preview(lane),
            state,
            since: lane.since,
            unread: lane.unread && !read,
            pinned,
            harness: lane.harness.clone(),
        };
        Some(Ranked { row, tier: state.tier(), since: lane.since.unwrap_or(i64::MIN) })
    }

    /// When the rows next change with no lane or mark change: a snooze ends, or an idle chat
    /// passes the idle horizon and leaves. None when nothing is pending.
    pub fn next_change(
        &self,
        lanes: &[Lane],
        marks: &Marks,
        now: i64,
        failing: &HashSet<String>,
    ) -> Option<i64> {
        lanes
            .iter()
            .filter_map(|lane| {
                if marks.archived.contains(&lane.id) {
                    return None;
                }
                let stamp = stamp(lane);
                // A snooze on the chat's current state ends; one on an older state no longer applies.
                if let Some(snooze) = marks.snoozed.get(&lane.id)
                    && snooze.stamp == stamp
                    && snooze.until_ms > now
                {
                    return Some(snooze.until_ms);
                }
                let read = marks.read.get(&lane.id) == Some(&stamp);
                let state = row_state(lane, read, failing.contains(&lane.id));
                let kept = marks.pinned.contains(&lane.id) || marks.placed.contains_key(&lane.id);
                if kept || state != RowState::Idle {
                    return None;
                }
                lane.since.map(|since| since.saturating_add(self.idle_horizon_ms))
            })
            .filter(|at| *at > now)
            .min()
    }
}

/// The chats Go to Next Agent Needing Input visits, in its order: the ones at a permission
/// prompt or question and neither archived nor snoozed, pinned first, then the newest ask, then
/// the id. Unseen results and failed chats never count.
pub fn needing_input<'a>(lanes: &'a [Lane], marks: &Marks, now: i64) -> Vec<&'a Lane> {
    let mut waiting: Vec<&Lane> = lanes
        .iter()
        .filter(|lane| {
            lane.state == LaneState::Input
                && !marks.archived.contains(&lane.id)
                && !marks.is_snoozed(&lane.id, &stamp(lane), now)
        })
        .collect();
    waiting.sort_by(|a, b| {
        let pinned = |lane: &Lane| marks.pinned.contains(&lane.id);
        pinned(b)
            .cmp(&pinned(a))
            .then(b.since.unwrap_or(i64::MIN).cmp(&a.since.unwrap_or(i64::MIN)))
            .then(a.id.cmp(&b.id))
    });
    waiting
}

/// The chat after `previous` in `ids`, wrapping; the first when `previous` is none or no longer
/// waits; none when none waits.
pub fn next_after(previous: Option<&str>, ids: &[String]) -> Option<String> {
    let first = ids.first()?;
    let Some(index) = previous.and_then(|p| ids.iter().position(|id| id == p)) else {
        return Some(first.clone());
    };
    ids.get((index + 1) % ids.len()).cloned()
}

#[cfg(test)]
#[path = "priority_tests.rs"]
mod tests;
