//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/priority_window`: a client's window over the
//! sessions' lanes (rust-migration A6). The Mac app mirrored every lane of every session
//! (`AgentLaneStore`) and ranked them on the main thread at each change; a client now names a
//! window and gets its rows, then after each lane change a row diff with the next revision: the
//! window's keys in order and only the rows whose value changed (the `_acpmux/chats_window`
//! pattern, `chats/window.rs`).
//!
//! Two kinds of window:
//!
//! - `priority` (the default): the sidebar's Priority view, ranked by `priority.rs` with the
//!   daemon's marks (`priority_marks.rs`, one copy for every window). The spec carries what the
//!   client still owns: the ids with failing pull request checks (`failing`), the ids open in a
//!   tab (`opened`), whether the view shows (`shown`: hidden, only the rows that need the person
//!   are kept, for the bell's dot), how rows name machines (`localMachine`, `peerNames`), the
//!   lanes of chats another owner reports (`lanes`: summaries with `lane`, an optional `machine`
//!   and `archivable` when the client has the owning acpmux's socket; for the Chief home's
//!   acpmux and other machines' daemon trees), and once the app's saved marks (`importMarks`). A lane of this daemon wins over one of `lanes` with the same id.
//!   Each message also carries `needingInput` (Go to Next Agent Needing Input's order),
//!   `attentionCount` and `nextChangeMs` (when a snooze ends or an idle chat ages out with no
//!   other change; the server wakes then).
//! - `links`: the lanes of `keys` (the sessions the session tree shows), each only what links it
//!   to its folder, pull requests and chat, and its state (`Lane::links`): a new step of a
//!   session sends nothing.
//!
//! Pure: the server keeps one [`WindowState`] per window and connection
//! (`server/priority_windows.rs`) and a [`LaneSet`] per connection, changed in place per event.

use std::collections::{HashMap, HashSet};

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::priority::{Lane, Marks, Ranking, needing_input, next_after};
use super::{Hub, HubEvent};

/// What a window shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WindowKind {
    /// Boxed: its sets and lanes dwarf a links window's keys.
    Priority(Box<PrioritySpec>),
    Links {
        keys: Vec<String>,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrioritySpec {
    /// The client's saved marks, handed over once: taken only while acpmux has none
    /// (`priority_marks.rs`). The window shows the daemon's marks, never these.
    import: Option<Marks>,
    /// The tag of this daemon's own lanes (this Mac's name while the app shows it), else none.
    local_machine: Option<String>,
    /// A peer's display name by its acpmux name; a peer without one shows its name.
    peer_names: HashMap<String, String>,
    failing: HashSet<String>,
    opened: HashSet<String>,
    shown: bool,
    /// Lanes another owner reports, in the client's order.
    lanes: Vec<Lane>,
    ranking: Ranking,
}

/// `{window, gen?, kind?, ...}`; see the module notes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WindowSpec {
    pub window: String,
    /// The client's generation of this window's spec (0 from a client that sends none).
    pub generation: u64,
    pub kind: WindowKind,
}

fn ids(params: &Value, name: &str) -> Result<HashSet<String>, String> {
    Ok(strings(params, name)?.into_iter().collect())
}

fn strings(params: &Value, name: &str) -> Result<Vec<String>, String> {
    match params.get(name) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| item.as_str().map(str::to_owned))
            .collect::<Option<Vec<_>>>()
            .ok_or_else(|| format!("{name} must be an array of session ids")),
        Some(_) => Err(format!("{name} must be an array of session ids")),
    }
}

impl PrioritySpec {
    fn from_params(params: &Value) -> Result<Self, String> {
        let import = match params.get("importMarks") {
            None | Some(Value::Null) => None,
            Some(saved) => Some(super::priority_marks::from_app(saved)?),
        };
        let local_machine = match params.get("localMachine") {
            None | Some(Value::Null) => None,
            Some(Value::String(name)) if !name.is_empty() => Some(name.clone()),
            Some(_) => return Err("localMachine must be a non-empty string".to_owned()),
        };
        let peer_names = match params.get("peerNames") {
            None | Some(Value::Null) => HashMap::new(),
            Some(Value::Object(names)) => names
                .iter()
                .map(|(peer, name)| name.as_str().map(|name| (peer.clone(), name.to_owned())))
                .collect::<Option<_>>()
                .ok_or("peerNames must map peer names to display names")?,
            Some(_) => return Err("peerNames must map peer names to display names".to_owned()),
        };
        let shown = match params.get("shown") {
            None | Some(Value::Null) => true,
            Some(Value::Bool(on)) => *on,
            Some(_) => return Err("shown must be true or false".to_owned()),
        };
        let lanes = match params.get("lanes") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(items)) => {
                items.iter().filter_map(|summary| Lane::of(summary, None)).collect()
            }
            Some(_) => return Err("lanes must be an array of session summaries".to_owned()),
        };
        let mut ranking = Ranking::default();
        match params.get("idleHorizonMs") {
            None | Some(Value::Null) => {}
            Some(value) => {
                ranking.idle_horizon_ms = value.as_i64().ok_or("idleHorizonMs must be a number")?
            }
        }
        Ok(Self {
            import,
            local_machine,
            peer_names,
            failing: ids(params, "failing")?,
            opened: ids(params, "opened")?,
            shown,
            lanes,
            ranking,
        })
    }
}

impl WindowSpec {
    pub fn from_params(params: &Value) -> Result<Self, String> {
        let window = params
            .get("window")
            .and_then(Value::as_str)
            .filter(|w| !w.is_empty())
            .ok_or("window must be a non-empty string")?
            .to_owned();
        let generation = match params.get("gen") {
            None | Some(Value::Null) => 0,
            Some(value) => value.as_u64().ok_or("gen must be a non-negative number")?,
        };
        let kind = match params.get("kind").and_then(Value::as_str) {
            None | Some("priority") => {
                WindowKind::Priority(Box::new(PrioritySpec::from_params(params)?))
            }
            Some("links") => WindowKind::Links { keys: strings(params, "keys")? },
            Some(other) => return Err(format!("kind must be priority or links, not {other:?}")),
        };
        Ok(Self { window, generation, kind })
    }
}

/// Every lane a window may show, by session id: this daemon's sessions and the peers' it mirrors.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LaneSet {
    lanes: HashMap<String, Lane>,
}

impl LaneSet {
    pub fn from_lanes(lanes: impl IntoIterator<Item = Lane>) -> Self {
        let mut set = Self::default();
        for lane in lanes {
            // A local row comes first (`visit_session_summaries`): a peer's row with its id is not it.
            set.lanes.entry(lane.id.clone()).or_insert(lane);
        }
        set
    }

    /// Writes one session's lane (none: it ended). True when the set changed. A peer's row
    /// never replaces or removes this daemon's own lane of the same id (`from_lanes` keeps it).
    pub fn apply(&mut self, change: LaneChange) -> bool {
        let LaneChange { id, lane, from_peer } = change;
        if from_peer && self.lanes.get(&id).is_some_and(|own| own.peer.is_none()) {
            return false;
        }
        match lane {
            Some(lane) if self.lanes.get(&id) == Some(&lane) => false,
            Some(lane) => {
                self.lanes.insert(id, lane);
                true
            }
            None => self.lanes.remove(&id).is_some(),
        }
    }

    pub fn get(&self, id: &str) -> Option<&Lane> {
        self.lanes.get(id)
    }
}

/// `_acpmux/priority_mark {window, op, id?, order?, durationMs?, collapsed?}`: the person marks a
/// chat in a Priority window. The rule of each mark is here (`Marks`); the marks are the
/// daemon's (`priority_marks.rs`), one copy for every window.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MarkOp {
    Read(String),
    TogglePin(String),
    Snooze {
        id: String,
        duration_ms: i64,
    },
    Archive(String),
    Unarchive(String),
    Collapse(bool),
    /// The person dragged `id`; the view now shows `order`.
    Place {
        id: String,
        order: Vec<String>,
    },
    /// Drops the marks of chats the window no longer lists (the client asks once every owner
    /// it reads is live, so a gap never loses marks).
    Prune,
}

impl MarkOp {
    pub fn from_params(params: &Value) -> Result<Self, String> {
        let id = || -> Result<String, String> {
            let id = params.get("id").and_then(Value::as_str).filter(|id| !id.is_empty());
            id.map(str::to_owned).ok_or_else(|| "id must be a session id".to_owned())
        };
        let op = params.get("op").and_then(Value::as_str).unwrap_or_default();
        Ok(match op {
            "read" => Self::Read(id()?),
            "pin" => Self::TogglePin(id()?),
            "snooze" => {
                let duration_ms = match params.get("durationMs") {
                    None | Some(Value::Null) => super::priority::SNOOZE_MS,
                    Some(value) => value
                        .as_i64()
                        .filter(|ms| *ms > 0)
                        .ok_or("durationMs must be a positive number")?,
                };
                Self::Snooze { id: id()?, duration_ms }
            }
            "archive" => Self::Archive(id()?),
            "unarchive" => Self::Unarchive(id()?),
            "collapse" => {
                let collapsed = params.get("collapsed").and_then(Value::as_bool);
                Self::Collapse(collapsed.ok_or("collapsed must be true or false")?)
            }
            "place" => Self::Place { id: id()?, order: strings(params, "order")? },
            "prune" => Self::Prune,
            other => {
                return Err(format!(
                    "op must be read, pin, snooze, archive, unarchive, collapse, place or prune, \
                     not {other:?}"
                ));
            }
        })
    }
}

/// The lane `id` shows in a window: this daemon's, else one the client reported.
fn listed(set: &LaneSet, reported: &[Lane], id: &str) -> Result<Lane, String> {
    let lane = set.get(id).or_else(|| reported.iter().find(|lane| lane.id == id));
    lane.cloned().ok_or_else(|| format!("no chat {id:?} in this window"))
}

/// A mark checked against a window's lanes, ready to apply to the daemon's marks.
#[derive(Clone, Debug)]
pub struct Mark {
    op: MarkOp,
    /// The lane the mark is on (its stamp), for read and snooze.
    lane: Option<Lane>,
    /// Every chat the window lists, for prune.
    keeping: HashSet<String>,
}

impl Mark {
    /// Applies the mark to `marks` at `now`.
    pub fn apply(&self, marks: &mut Marks, now: i64) {
        match (&self.op, &self.lane) {
            (MarkOp::Read(_), Some(lane)) => marks.mark_read(lane),
            (MarkOp::Snooze { duration_ms, .. }, Some(lane)) => {
                marks.snooze(lane, *duration_ms, now)
            }
            (MarkOp::TogglePin(id), _) => marks.toggle_pin(id),
            (MarkOp::Archive(id), _) => marks.archive(id),
            (MarkOp::Unarchive(id), _) => marks.unarchive(id),
            (MarkOp::Collapse(collapsed), _) => marks.collapsed = *collapsed,
            (MarkOp::Place { id, order }, _) => marks.place(id, order),
            (MarkOp::Prune, _) => marks.prune(&self.keeping),
            (MarkOp::Read(_) | MarkOp::Snooze { .. }, None) => {}
        }
    }
}

impl PrioritySpec {
    /// `op` checked against this window's lanes. A mark on a chat the window does not list is
    /// refused, as the app's row actions were (unarchive, collapse, place and prune name none).
    pub fn mark(&self, op: MarkOp, set: &LaneSet) -> Result<Mark, String> {
        let lane = match &op {
            MarkOp::Read(id) | MarkOp::Snooze { id, .. } => Some(listed(set, &self.lanes, id)?),
            MarkOp::TogglePin(id) => {
                listed(set, &self.lanes, id)?;
                None
            }
            // Archive reaches the chat's owning acpmux: this daemon, or one whose socket the
            // client has. Another machine's chat has none (`AgentPriorityChats.archive`).
            MarkOp::Archive(id) => {
                let lane = listed(set, &self.lanes, id)?;
                if set.get(id).is_none() && !lane.archivable {
                    return Err(format!(
                        "no acpmux of this client lists chat {id:?} to archive it"
                    ));
                }
                None
            }
            _ => None,
        };
        let keeping = if op == MarkOp::Prune {
            set.lanes.keys().cloned().chain(self.lanes.iter().map(|lane| lane.id.clone())).collect()
        } else {
            HashSet::new()
        };
        Ok(Mark { op, lane, keeping })
    }

    /// The client's saved marks to hand over, if it sent them.
    pub fn import(&self) -> Option<&Marks> {
        self.import.as_ref()
    }
}

/// What a window shows now: its rows in order and the window-wide values beside them.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct WindowView {
    pub rows: Vec<(String, Value)>,
    /// `needingInput`, `attentionCount` for a Priority window; null for a links window.
    pub extra: Value,
    /// When the rows next change with no lane or mark change (epoch ms).
    pub next_change: Option<i64>,
}

/// The view of `spec` over `set` with the daemon's `marks` at `now` (epoch ms).
pub fn view(spec: &WindowSpec, set: &LaneSet, marks: &Marks, now: i64) -> WindowView {
    match &spec.kind {
        WindowKind::Links { keys } => WindowView {
            rows: keys
                .iter()
                .filter_map(|key| set.lanes.get(key).map(|lane| (key.clone(), lane.links())))
                .collect(),
            extra: Value::Null,
            next_change: None,
        },
        WindowKind::Priority(priority) => priority_view(priority, set, marks, now),
    }
}

/// Every lane a Priority window ranks: this daemon's, then the client's whose id it lacks, each
/// with the machine its row names, as the app named it: the client's tag for a lane it reported
/// from another machine, else the peer's display name (or its name), else this Mac's tag.
fn window_lanes(spec: &PrioritySpec, set: &LaneSet) -> Vec<Lane> {
    let mut lanes: Vec<Lane> = set.lanes.values().cloned().collect();
    lanes.extend(spec.lanes.iter().filter(|lane| !set.lanes.contains_key(&lane.id)).cloned());
    // The client's lanes may repeat an id: the first is it.
    let mut seen = HashSet::new();
    lanes.retain(|lane| seen.insert(lane.id.clone()));
    for lane in &mut lanes {
        if lane.machine.is_none() {
            lane.machine = match &lane.peer {
                Some(peer) => Some(spec.peer_names.get(peer).unwrap_or(peer).clone()),
                None => spec.local_machine.clone(),
            };
        }
    }
    lanes
}

/// Go to Next Agent Needing Input from a Priority window: the chat after `after` in its
/// needs-input order, wrapping; the first when `after` is none or no longer waits; none when no
/// chat waits.
pub fn next_needing_input(
    spec: &WindowSpec,
    set: &LaneSet,
    marks: &Marks,
    now: i64,
    after: Option<&str>,
) -> Option<String> {
    let WindowKind::Priority(priority) = &spec.kind else { return None };
    let lanes = window_lanes(priority, set);
    let order: Vec<String> =
        needing_input(&lanes, marks, now).into_iter().map(|lane| lane.id.clone()).collect();
    next_after(after, &order)
}

fn priority_view(spec: &PrioritySpec, set: &LaneSet, marks: &Marks, now: i64) -> WindowView {
    let lanes = window_lanes(spec, set);
    // An agent-started chat shows only once a tab opened it, or while pinned.
    let visible: HashSet<&str> = lanes
        .iter()
        .filter(|l| !l.requires_open || spec.opened.contains(&l.id) || marks.pinned.contains(&l.id))
        .map(|l| l.id.as_str())
        .collect();
    let rows: Vec<_> = spec
        .ranking
        .entries(&lanes, marks, now, &spec.failing)
        .into_iter()
        .filter(|row| {
            visible.contains(row.id.as_str()) && (spec.shown || row.state.needs_attention())
        })
        .collect();
    let waiting: Vec<&str> =
        needing_input(&lanes, marks, now).into_iter().map(|lane| lane.id.as_str()).collect();
    let attention = rows.iter().filter(|row| row.state.needs_attention()).count();
    WindowView {
        extra: json!({"needingInput": waiting, "attentionCount": attention}),
        rows: rows.into_iter().map(|row| (row.id.clone(), row.value())).collect(),
        next_change: spec.ranking.next_change(&lanes, marks, now, &spec.failing),
    }
}

/// What a window last sent its client, so the next message is a diff against it.
#[derive(Debug)]
pub struct WindowState {
    pub spec: WindowSpec,
    revision: u64,
    /// None until the window's first message: that one sends every row.
    sent: Option<WindowView>,
}

impl WindowState {
    /// A new window, or a window whose spec changed: its next message sends every row. The
    /// revision goes on from `revision`, so a client never takes an older message for a newer.
    pub fn new(spec: WindowSpec, revision: u64) -> Self {
        Self { spec, revision, sent: None }
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// When the window's rows next change by the clock alone.
    pub fn next_change(&self) -> Option<i64> {
        self.sent.as_ref().and_then(|sent| sent.next_change)
    }

    /// The `_acpmux/priority_window_changed` params that bring the client from what it was sent
    /// to `next`, or None when it shows nothing new.
    pub fn next(&mut self, next: WindowView) -> Option<Value> {
        let unchanged = self
            .sent
            .as_ref()
            .is_some_and(|sent| sent.rows == next.rows && sent.extra == next.extra);
        if unchanged {
            // The rows are the same; only the wake time may have moved.
            self.sent = Some(next);
            return None;
        }
        let keys: Vec<&str> = next.rows.iter().map(|(key, _)| key.as_str()).collect();
        let full = self.sent.is_none();
        let rows: Vec<&Value> = match &self.sent {
            None => next.rows.iter().map(|(_, value)| value).collect(),
            Some(sent) => {
                let before: HashMap<&str, &Value> =
                    sent.rows.iter().map(|(k, v)| (k.as_str(), v)).collect();
                next.rows
                    .iter()
                    .filter(|(k, v)| before.get(k.as_str()) != Some(&v))
                    .map(|(_, v)| v)
                    .collect()
            }
        };
        self.revision = self.revision.saturating_add(1);
        let mut message = json!({"window": self.spec.window, "gen": self.spec.generation, "revision": self.revision,
                                 "full": full, "keys": keys, "rows": rows});
        if let (Some(object), Some(extra)) = (message.as_object_mut(), next.extra.as_object()) {
            object.extend(extra.clone());
            object.insert("nextChangeMs".into(), json!(next.next_change));
        }
        self.sent = Some(next);
        Some(message)
    }
}

impl Hub {
    /// Every session's lane: this daemon's, then the peers' it mirrors. Reads every summary, so
    /// the server calls it once per connection and after a missed change, never per change.
    pub(crate) fn lane_set(&self) -> LaneSet {
        let mut lanes = Vec::new();
        self.visit_session_summaries(false, |summary| lanes.extend(Lane::of(&summary, None)));
        LaneSet::from_lanes(lanes)
    }

    /// The session `ev` changed and its lane now (none: it closed, was purged or went), read
    /// from that session's summary alone. `ev` is a record that changes a lane (`changes_lane`).
    pub(crate) fn lane_after(&self, ev: &HubEvent) -> LaneChange {
        let purged = ev.record.kind == "purged";
        if let Some(remote) = &ev.remote {
            let id = remote
                .summary
                .get("sessionId")
                .and_then(Value::as_str)
                .map_or_else(|| ev.session_id.clone(), str::to_owned);
            // A purge carries the row it removed, lane and all: the lane is gone.
            let lane = (!purged)
                .then(|| {
                    let mut summary = remote.summary.clone();
                    if summary.get("peer").is_none_or(Value::is_null) {
                        summary.set("peer", json!(remote.peer));
                    }
                    Lane::of(&summary, Some(&id))
                })
                .flatten();
            return LaneChange { id, lane, from_peer: true };
        }
        // By its exact id: a prefix of a gone session's id may name another session.
        let session = (!purged)
            .then(|| {
                self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(&ev.session_id).cloned()
            })
            .flatten();
        let lane = session.and_then(|session| {
            Lane::of(&self.session_list_summary(&session), Some(&ev.session_id))
        });
        LaneChange { id: ev.session_id.clone(), lane, from_peer: false }
    }
}

/// One session's lane after a change (`Hub::lane_after`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LaneChange {
    pub id: String,
    pub lane: Option<Lane>,
    /// It came from a peer's row: it never replaces or removes this daemon's own lane.
    pub from_peer: bool,
}

#[cfg(test)]
#[path = "priority_window_tests.rs"]
mod tests;
