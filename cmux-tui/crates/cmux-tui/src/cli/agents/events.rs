//! `cmux agents events` and the `agents_events` MCP tool: a long-poll on
//! what changes in cmux, so an agent reacts to events instead of polling
//! `agents_snapshot`. A call answers `{events, next_after, timed_out}` at
//! once when events newer than `after` exist, else on the first one, else at
//! its timeout; `next_after` continues without gaps or duplicates.
//!
//! Tab, workspace, notification and terminal-agent events come from the
//! daemon's `session.events` journal, resumed from the cursor's revision.
//! Dialogs and agent chat state live only in the app, which publishes no
//! event for them, so they are polled every second (as `agents wait` does)
//! and diffed against the state the cursor carries.
//!
//! Events carry ids, states and short titles only: no terminal text, no
//! chat text, no tool input. A notification's title and body are cut.

use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::super::mcp::{self, Backend, CallFailure, FailureKind};
use super::super::{UsageError, app};
use super::{AgentFailure, compose_snapshot, snapshot_plan};
use cmux_json::JsonSet as _;

pub(in crate::cli) const DEFAULT_TIMEOUT_SECONDS: u64 = 30;
/// One request at a time per MCP connection: a long-poll holds the others.
pub(in crate::cli) const MAX_TIMEOUT_SECONDS: u64 = 60;
pub(in crate::cli) const DEFAULT_LIMIT: usize = 100;
pub(in crate::cli) const MAX_LIMIT: usize = 200;
pub(in crate::cli) const KINDS: [&str; 5] = ["dialog", "notification", "tab", "workspace", "agent"];
/// How often the app's dialogs and chat states are read.
const RECHECK: Duration = Duration::from_secs(1);
/// A read of the daemon's stream that ends without an item.
const TICK: Duration = Duration::from_millis(200);
/// After the first event, how long a burst may add to the answer.
const SETTLE: Duration = Duration::from_millis(200);
/// Even a call with timeout 0 reads the events already pending.
const CATCH_UP: Duration = Duration::from_millis(500);
/// Less time than this left for an app read: skip it.
const MIN_APP_READ: Duration = Duration::from_millis(50);
const TITLE_CHARS: usize = 80;
const BODY_CHARS: usize = 160;
const CURSOR_PREFIX: &str = "evc1_";
const MAX_CURSOR_BYTES: usize = 64 << 10;
/// The largest event number a cursor carries (exact in a JSON double).
const MAX_SEQ: u64 = (1 << 53) - 1;
/// The fields of a dialog an event names (ids; no tool input). Its own
/// `kind` (permissionRequest, question) is the event's `dialog_kind`.
const DIALOG_FIELDS: [&str; 7] = [
    "request_id",
    "source",
    "workstream_id",
    "session_id",
    "agent_session",
    "terminal_id",
    "tab_id",
];

/// What `cmux agents events` reads, and how long it waits.
#[derive(Clone, Debug, PartialEq)]
pub(in crate::cli) struct EventsRequest {
    after: Option<Cursor>,
    kinds: BTreeSet<&'static str>,
    pub timeout: Duration,
    limit: usize,
}

/// Where a caller is: the last event number it got, the daemon journal
/// position, and the app state the next app read is compared with. Opaque
/// to callers (`evc1_` and base64url JSON).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
struct Cursor {
    #[serde(rename = "s", default)]
    seq: u64,
    #[serde(rename = "d", default, skip_serializing_if = "Option::is_none")]
    daemon: Option<DaemonCursor>,
    /// Daemon agent id to state.
    #[serde(rename = "a", default, skip_serializing_if = "BTreeMap::is_empty")]
    agents: BTreeMap<String, String>,
    /// Pending dialog ids; `None` until the app answers once.
    #[serde(rename = "p", default, skip_serializing_if = "Option::is_none")]
    dialogs: Option<BTreeSet<String>>,
    /// Agent chat tab id to state; `None` until the app answers once.
    #[serde(rename = "c", default, skip_serializing_if = "Option::is_none")]
    chats: Option<BTreeMap<String, String>>,
    /// A reset the caller has not got yet (an answer was full).
    #[serde(rename = "x", default, skip_serializing_if = "Option::is_none")]
    reset: Option<String>,
}

/// The journal batch after `revision` in `generation`, of which the first
/// `skip` changes were already answered (a full answer stops mid-batch).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct DaemonCursor {
    #[serde(rename = "g")]
    generation: String,
    #[serde(rename = "r")]
    revision: u64,
    #[serde(rename = "k", default, skip_serializing_if = "is_zero")]
    skip: usize,
}

fn is_zero(value: &usize) -> bool {
    *value == 0
}

impl Cursor {
    fn encode(&self) -> String {
        let bytes = serde_json::to_vec(self).unwrap_or_default();
        format!("{CURSOR_PREFIX}{}", URL_SAFE_NO_PAD.encode(bytes))
    }

    fn decode(text: &str) -> Option<Self> {
        let body = text.strip_prefix(CURSOR_PREFIX)?;
        if body.len() > MAX_CURSOR_BYTES {
            return None;
        }
        let cursor: Self = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(body).ok()?).ok()?;
        // A client may edit it: an event number this high is not one we gave.
        (cursor.seq <= MAX_SEQ).then_some(cursor)
    }

    fn daemon_param(&self) -> Option<Value> {
        let daemon = self.daemon.as_ref()?;
        Some(json!({"generation": daemon.generation, "revision": daemon.revision.to_string()}))
    }
}

/// Parses the words after `cmux agents events`.
pub(super) fn parse(args: &[&str]) -> Result<EventsRequest, UsageError> {
    let usage = |message: String| UsageError::new(format!("agents events: {message}"));
    let (mut after, mut timeout, mut limit) = (None, None, None);
    let mut kinds = BTreeSet::new();
    let mut index = 0;
    while index < args.len() {
        let (flag, inline) = match args[index].split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value)),
            _ => (args[index], None),
        };
        if !matches!(flag, "--after" | "--kind" | "--timeout" | "--limit") {
            return Err(usage(format!("unexpected argument {flag:?}")));
        }
        let value = match inline {
            Some(value) => value,
            None => {
                index += 1;
                args.get(index)
                    .copied()
                    .filter(|value| !value.starts_with('-'))
                    .ok_or_else(|| usage(format!("{flag} needs a value")))?
            }
        };
        if value.is_empty() {
            return Err(usage(format!("{flag} needs a value")));
        }
        index += 1;
        if flag == "--kind" {
            for kind in value.split(',') {
                let known = KINDS.iter().find(|known| **known == kind).ok_or_else(|| {
                    usage(format!("--kind is one of {}, not {kind:?}", KINDS.join(", ")))
                })?;
                kinds.insert(*known);
            }
            continue;
        }
        let slot = match flag {
            "--after" => &mut after,
            "--timeout" => &mut timeout,
            _ => &mut limit,
        };
        if slot.is_some() {
            return Err(usage(format!("{flag} comes once")));
        }
        *slot = Some(value);
    }
    let after = after
        .map(|text| {
            Cursor::decode(text).ok_or_else(|| {
                usage("--after is not a cursor from a previous agents events call".into())
            })
        })
        .transpose()?;
    let timeout = match timeout {
        None => Duration::from_secs(DEFAULT_TIMEOUT_SECONDS),
        Some(value) => match value.parse::<f64>() {
            Ok(seconds)
                if seconds.is_finite() && (0.0..=MAX_TIMEOUT_SECONDS as f64).contains(&seconds) =>
            {
                Duration::from_secs_f64(seconds)
            }
            _ => {
                return Err(usage(format!(
                    "--timeout is a number of seconds from 0 to {MAX_TIMEOUT_SECONDS}"
                )));
            }
        },
    };
    let limit = match limit {
        None => DEFAULT_LIMIT,
        Some(value) => match value.parse::<usize>() {
            Ok(limit) if (1..=MAX_LIMIT).contains(&limit) => limit,
            _ => return Err(usage(format!("--limit is a number from 1 to {MAX_LIMIT}"))),
        },
    };
    if kinds.is_empty() {
        kinds.extend(KINDS);
    }
    Ok(EventsRequest { after, kinds, timeout, limit })
}

/// Reads the events after `request.after` (from now without it) and
/// answers `{schema_version, events, next_after, timed_out, sources}`. Only
/// a call that no owner answers fails.
pub(in crate::cli) fn run<B: Backend>(
    backend: &B,
    session: Option<&str>,
    request: &EventsRequest,
) -> Result<Value, AgentFailure> {
    let started = Instant::now();
    let deadline = started + request.timeout;
    // No read outlasts this: the timeout, or a short catch-up for timeout 0.
    let mut poll = Poll::new(request, deadline.max(started + CATCH_UP));
    match &request.after {
        Some(after) => {
            poll.cursor = after.clone();
            // A call that never reached the daemon: what changed since is
            // unknown, so its first snapshot says so.
            poll.unanchored = after.daemon.is_none();
            poll.flush_reset();
            poll.check_app(backend, session, None);
        }
        // From now: the daemon's journal position and agents, and the app's
        // dialogs and chats, with no event for what is already there.
        None => {
            // One daemon read is the baseline and scopes the app's, so a
            // daemon that answered is known before the app is diffed.
            let daemon = backend.resource(session, snapshot_plan(), &[]);
            if let Ok(snapshot) = &daemon {
                poll.cursor.daemon = daemon_cursor(&snapshot["cursor"], 0);
                poll.cursor.agents = agent_states(snapshot);
                poll.daemon_seen = true;
            }
            let app_answered = poll.check_app(backend, session, Some(&daemon));
            if let Err(failure) = daemon
                && !app_answered
            {
                return Err(AgentFailure::Owner(failure));
            }
        }
    }
    poll.stream(backend, session, deadline);
    let next_after = poll.fit_cursor();
    Ok(json!({
        "schema_version": 1,
        "events": poll.events,
        "next_after": next_after,
        "timed_out": poll.events.is_empty(),
        "sources": {"daemon": poll.daemon_seen, "app": poll.app_seen},
    }))
}

struct Poll<'a> {
    request: &'a EventsRequest,
    cursor: Cursor,
    events: Vec<Value>,
    first_event: Option<Instant>,
    last_app: Instant,
    daemon_seen: bool,
    app_seen: bool,
    /// When the call's reads must end.
    bound: Instant,
    /// The cursor had no daemon position: the first snapshot is a reset.
    unanchored: bool,
}

impl<'a> Poll<'a> {
    fn new(request: &'a EventsRequest, bound: Instant) -> Self {
        Self {
            request,
            cursor: Cursor::default(),
            events: Vec::new(),
            first_event: None,
            last_app: Instant::now(),
            daemon_seen: false,
            app_seen: false,
            bound,
            unanchored: false,
        }
    }

    /// Adds the reset the cursor holds, unless the answer is full. Answers
    /// whether none is left.
    fn flush_reset(&mut self) -> bool {
        let Some(reason) = self.cursor.reset.clone() else { return true };
        let source = if reason == "cursor_too_large" { "cursor" } else { "daemon" };
        if !self.push("reset", None, json!({"source": source, "reason": reason})) {
            return false;
        }
        self.cursor.reset = None;
        true
    }

    /// The cursor as `next_after`, within [`MAX_CURSOR_BYTES`]: past it,
    /// the app's diff state (then the agents' states) is dropped and a
    /// reset says so, since the next read starts from a new baseline.
    fn fit_cursor(&mut self) -> String {
        let fits =
            |cursor: &Cursor| cursor.encode().len() - CURSOR_PREFIX.len() <= MAX_CURSOR_BYTES;
        if fits(&self.cursor) {
            return self.cursor.encode();
        }
        self.cursor.dialogs = None;
        self.cursor.chats = None;
        if !fits(&self.cursor) {
            self.cursor.agents.clear();
        }
        self.cursor.reset = Some("cursor_too_large".into());
        self.flush_reset();
        self.cursor.encode()
    }

    /// Holds the daemon's stream from the cursor until an answer is ready;
    /// with no stream, reads the app every [`RECHECK`] until the deadline.
    fn stream<B: Backend>(&mut self, backend: &B, session: Option<&str>, deadline: Instant) {
        let stream_until = self.bound;
        for _attempt in 0..2 {
            let from = self.cursor.daemon_param();
            let mut done = false;
            let mut wake = |item: Option<&Value>| {
                done = self.wake(backend, session, item, deadline);
                done
            };
            match backend.session_events(session, from.as_ref(), stream_until, TICK, &mut wake) {
                Ok(()) if done => return,
                Ok(()) => break,
                // A cursor ahead of the daemon (another daemon's journal):
                // start again from its snapshot, and say so.
                Err(failure)
                    if failure.error["code"] == "cursor.invalid"
                        && self.cursor.daemon.is_some() =>
                {
                    self.cursor.daemon = None;
                    self.cursor.reset.get_or_insert_with(|| "cursor_invalid".into());
                }
                Err(_) => break,
            }
        }
        // The stream did not open or ended early: read the app on a timer.
        while !self.answered(true, deadline) {
            let left = deadline.saturating_duration_since(Instant::now());
            std::thread::sleep(left.min(RECHECK));
            self.check_app(backend, session, None);
        }
    }

    /// One stream wake: an item, or `None` after a quiet [`TICK`]. Answers
    /// whether the call has its answer.
    fn wake<B: Backend>(
        &mut self,
        backend: &B,
        session: Option<&str>,
        item: Option<&Value>,
        deadline: Instant,
    ) -> bool {
        self.daemon_seen = true;
        if let Some(item) = item
            && !self.item(item)
        {
            return true;
        }
        if self.last_app.elapsed() >= RECHECK {
            self.check_app(backend, session, None);
        }
        self.answered(item.is_none(), deadline)
    }

    fn full(&self) -> bool {
        self.events.len() >= self.request.limit
    }

    fn answered(&self, quiet: bool, deadline: Instant) -> bool {
        self.full()
            || self.first_event.is_some_and(|first| quiet || first.elapsed() >= SETTLE)
            || (quiet && Instant::now() >= deadline)
    }

    /// Adds an event of `kind` unless the call is full. Answers whether the
    /// change it states is taken (answered, or of a kind not asked for).
    fn push(&mut self, kind: &'static str, at: Option<u64>, fields: Value) -> bool {
        if kind != "reset" && !self.request.kinds.contains(kind) {
            return true;
        }
        if self.full() {
            return false;
        }
        self.cursor.seq = self.cursor.seq.saturating_add(1).min(MAX_SEQ);
        let mut event = Map::new();
        event.insert("seq".into(), json!(self.cursor.seq));
        event.insert("kind".into(), json!(kind));
        event.insert("at".into(), json!(at.unwrap_or_else(now_ms)));
        if let Value::Object(fields) = fields {
            event.extend(fields.into_iter().filter(|(_, value)| !value.is_null()));
        }
        self.events.push(Value::Object(event));
        self.first_event.get_or_insert_with(Instant::now);
        true
    }

    /// One `session.events` item. Answers `false` when the call filled up
    /// before the item's end; the cursor then points inside it.
    fn item(&mut self, item: &Value) -> bool {
        match item["kind"].as_str() {
            Some("snapshot") => {
                // The reset is kept in the cursor until an answer has room.
                let reason = item["reset_reason"].as_str().unwrap_or("initial");
                if self.cursor.daemon.is_some() && reason != "initial" {
                    self.cursor.reset.get_or_insert_with(|| reason.to_owned());
                } else if std::mem::take(&mut self.unanchored) {
                    self.cursor.reset.get_or_insert_with(|| "daemon_unavailable".to_owned());
                }
                self.cursor.agents = agent_states(&item["snapshot"]);
                self.cursor.daemon =
                    daemon_cursor(&item["cursor"], 0).or(self.cursor.daemon.take());
                self.flush_reset()
            }
            Some("delta") => {
                let Some(next) = daemon_cursor(&item["cursor"], 0) else { return true };
                let previous =
                    item["previous_revision"].as_str().and_then(|text| text.parse().ok());
                let skip = match &self.cursor.daemon {
                    Some(from) if Some(from.revision) == previous => from.skip,
                    _ => 0,
                };
                let changes = item["changes"].as_array().map(Vec::as_slice).unwrap_or_default();
                for (index, change) in changes.iter().enumerate().skip(skip) {
                    if !self.change(change) {
                        self.cursor.daemon = Some(DaemonCursor {
                            generation: next.generation,
                            revision: previous.unwrap_or(next.revision.saturating_sub(1)),
                            skip: index,
                        });
                        return false;
                    }
                }
                self.cursor.daemon = Some(next);
                true
            }
            _ => true,
        }
    }

    /// One journal change as an event; changes of other resources are
    /// taken without one.
    fn change(&mut self, change: &Value) -> bool {
        let (Some(resource), Some(id)) = (change["resource"].as_str(), change["id"].as_str())
        else {
            return true;
        };
        let value = &change["value"];
        let upsert = change["kind"] == "upsert";
        let change_kind = change["kind"].as_str();
        match (resource, change_kind) {
            ("workspace", Some("upsert" | "delete")) => self.push(
                "workspace",
                None,
                json!({
                    "change": if upsert { "changed" } else { "closed" },
                    "id": id,
                    "name": short(&value["name"], TITLE_CHARS).0,
                    "focused": value["focused"],
                }),
            ),
            ("tab", Some("upsert" | "delete")) => self.push(
                "tab",
                None,
                json!({
                    "change": if upsert { "changed" } else { "closed" },
                    "id": id,
                    "name": short(&value["name"], TITLE_CHARS).0,
                    "content_kind": value["content_kind"],
                    "pane_id": value["pane_id"],
                    "focused": value["focused"],
                }),
            ),
            ("notification", Some("upsert")) => {
                let read = value["read_by"].as_array().is_some_and(|readers| !readers.is_empty());
                let (title, title_cut) = short(&value["title"], TITLE_CHARS);
                let (subtitle, subtitle_cut) = short(&value["subtitle"], TITLE_CHARS);
                let (body, body_cut) = short(&value["body"], BODY_CHARS);
                let mut fields = json!({
                    "change": if read { "read" } else { "created" },
                    "id": id,
                    "title": title,
                    "subtitle": subtitle,
                    "body": body,
                    "level": value["level"],
                    "terminal_id": value["terminal_id"],
                });
                if title_cut || subtitle_cut || body_cut {
                    fields.set("truncated", json!(true));
                    fields.set("hint", json!("notification_list has the full text"));
                }
                self.push("notification", millis(&value["created_at_ms"]), fields)
            }
            ("notification", Some("delete")) => {
                self.push("notification", None, json!({"change": "cleared", "id": id}))
            }
            ("agent", Some("upsert")) => {
                let Some(state) = value["state"].as_str() else { return true };
                if self.cursor.agents.get(id).map(String::as_str) == Some(state) {
                    return true;
                }
                let taken = self.push(
                    "agent",
                    millis(&value["updated_at_ms"]),
                    json!({
                        "change": "state",
                        "id": id,
                        "source": "terminal",
                        "state": state,
                        "terminal_id": value["terminal_id"],
                    }),
                );
                if taken {
                    self.cursor.agents.insert(id.to_owned(), state.to_owned());
                }
                taken
            }
            ("agent", Some("delete")) => {
                let taken = self.push(
                    "agent",
                    None,
                    json!({"change": "state", "id": id, "source": "terminal", "state": "ended"}),
                );
                if taken {
                    self.cursor.agents.remove(id);
                }
                taken
            }
            _ => true,
        }
    }

    /// Reads the app's pending dialogs and its agent chats' states, in this
    /// session's scope, and adds an event for each change since the
    /// cursor's. Answers whether the app answered.
    /// `known` is a daemon snapshot this call just read, to scope with.
    fn check_app<B: Backend>(
        &mut self,
        backend: &B,
        session: Option<&str>,
        known: Option<&Result<Value, CallFailure>>,
    ) -> bool {
        self.last_app = Instant::now();
        let feed = self.app_read(backend, "feed.list", json!({"pending_only": true}));
        let topology = self.app_read(backend, "snapshot.get", json!({}));
        if feed.is_none() && topology.is_none() {
            return false;
        }
        self.app_seen = true;
        // The daemon's view of this session scopes what the app shows. When
        // a daemon there was does not answer, nothing is diffed this time:
        // an unscoped read would show other sessions' chats and dialogs.
        let daemon = match known {
            Some(known) => known.clone(),
            // A read that may not finish in time is not started.
            None if self.bound.saturating_duration_since(Instant::now()) < MIN_APP_READ => {
                Err(CallFailure {
                    kind: FailureKind::NotRun,
                    error: json!({"code": "timeout", "message": "no time left"}),
                    idempotency_key: None,
                })
            }
            None => backend.resource(session, snapshot_plan(), &[]),
        };
        if daemon.is_err()
            && (session.is_some() || self.daemon_seen || self.cursor.daemon.is_some())
        {
            return true;
        }
        let snapshot = compose_snapshot(
            daemon.map_err(mcp::agent_failure_value),
            topology.clone().ok_or(Value::Null),
        );
        if let Some(feed) = &feed {
            self.diff_dialogs(&scoped_dialogs(feed, &snapshot));
        }
        if topology.is_some() {
            self.diff_chats(chat_states(&snapshot));
        }
        true
    }

    /// One app read, bounded by the time the call has left; `None` when it
    /// fails or no time is left.
    fn app_read<B: Backend>(&self, backend: &B, method: &str, params: Value) -> Option<Value> {
        let left = self.bound.saturating_duration_since(Instant::now()).min(app::READ_TIMEOUT);
        if left < MIN_APP_READ {
            return None;
        }
        backend.app(method, params, left, None, false).ok()
    }

    fn diff_dialogs(&mut self, now: &[(String, &Value)]) {
        let Some(mut known) = self.cursor.dialogs.take() else {
            self.cursor.dialogs = Some(now.iter().map(|(id, _)| id.clone()).collect());
            return;
        };
        for (id, item) in now {
            if known.contains(id) {
                continue;
            }
            let mut fields = json!({"change": "opened", "id": id});
            for field in DIALOG_FIELDS {
                if let Some(text) = item[field].as_str() {
                    fields[field] = json!(short_str(text, TITLE_CHARS).0);
                }
            }
            if let Some(kind) = item["kind"].as_str() {
                fields.set("dialog_kind", json!(short_str(kind, TITLE_CHARS).0));
            }
            if let Some(title) = item["title"].as_str() {
                fields.set("title", json!(short_str(title, TITLE_CHARS).0));
            }
            if !self.push("dialog", None, fields) {
                self.cursor.dialogs = Some(known);
                return;
            }
            known.insert(id.clone());
        }
        let gone = known
            .iter()
            .filter(|id| !now.iter().any(|(pending, _)| pending == *id))
            .cloned()
            .collect::<Vec<_>>();
        for id in gone {
            if !self.push("dialog", None, json!({"change": "closed", "id": id})) {
                break;
            }
            known.remove(&id);
        }
        self.cursor.dialogs = Some(known);
    }

    fn diff_chats(&mut self, now: Vec<(String, String, Value)>) {
        let Some(mut known) = self.cursor.chats.take() else {
            self.cursor.chats = Some(now.into_iter().map(|(tab, state, _)| (tab, state)).collect());
            return;
        };
        known.retain(|tab, _| now.iter().any(|(shown, _, _)| shown == tab));
        for (tab, state, agent_session) in now {
            if known.get(&tab) == Some(&state) {
                continue;
            }
            let fields = json!({
                "change": "state",
                "id": tab,
                "source": "chat",
                "state": state,
                "agent_session": agent_session,
            });
            if !self.push("agent", None, fields) {
                break;
            }
            known.insert(tab, state);
        }
        self.cursor.chats = Some(known);
    }
}

/// `{generation, revision}` as the daemon writes it.
fn daemon_cursor(cursor: &Value, skip: usize) -> Option<DaemonCursor> {
    let generation = cursor["generation"].as_str()?.to_owned();
    let revision = match &cursor["revision"] {
        Value::String(text) => text.parse().ok()?,
        other => other.as_u64()?,
    };
    Some(DaemonCursor { generation, revision, skip })
}

/// The state of each daemon agent record in a session snapshot.
fn agent_states(snapshot: &Value) -> BTreeMap<String, String> {
    snapshot["agents"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|agent| {
            Some((agent["id"].as_str()?.to_owned(), agent["state"].as_str()?.to_owned()))
        })
        .collect()
}

/// The pending dialogs, by id, in the feed's order, without those of a
/// terminal or tab outside this session (when the daemon answered).
fn scoped_dialogs<'a>(feed: &'a Value, snapshot: &Value) -> Vec<(String, &'a Value)> {
    let items = feed.get("items").unwrap_or(feed).as_array().map(Vec::as_slice);
    let daemon = snapshot["sources"]["daemon"]["available"] == true;
    let known = |list: &str, id: &Value| {
        snapshot[list].as_array().into_iter().flatten().any(|object| object["id"] == *id)
    };
    items
        .unwrap_or_default()
        .iter()
        .filter(|item| item["status"].as_str().is_none_or(|status| status == "pending"))
        .filter(|item| {
            let (terminal, tab) = (&item["terminal_id"], &item["tab_id"]);
            !daemon
                || (terminal.is_null() && tab.is_null())
                || (!terminal.is_null() && known("terminals", terminal))
                || (!tab.is_null() && known("tabs", tab))
        })
        .filter_map(|item| {
            let id = item["id"].as_str().or(item["request_id"].as_str())?;
            Some((id.to_owned(), item))
        })
        .collect()
}

/// `(tab, state, agent_session)` for each agent chat tab in this session.
fn chat_states(snapshot: &Value) -> Vec<(String, String, Value)> {
    snapshot["tabs"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|tab| {
            Some((
                tab["id"].as_str()?.to_owned(),
                tab["agent_state"].as_str()?.to_owned(),
                tab["agent_session"].clone(),
            ))
        })
        .collect()
}

/// A string cut to `chars` characters, and whether it was cut.
fn short(value: &Value, chars: usize) -> (Value, bool) {
    match value.as_str() {
        Some(text) => {
            let (text, cut) = short_str(text, chars);
            (Value::String(text), cut)
        }
        None => (Value::Null, false),
    }
}

fn short_str(text: &str, chars: usize) -> (String, bool) {
    match text.char_indices().nth(chars) {
        Some((end, _)) => (format!("{}…", &text[..end]), true),
        None => (text.to_owned(), false),
    }
}

fn millis(value: &Value) -> Option<u64> {
    match value {
        Value::String(text) => text.parse().ok(),
        other => other.as_u64(),
    }
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|since| since.as_millis() as u64).unwrap_or(0)
}

/// One line per event for `cmux agents events` without `--json`:
/// `seq kind change id detail`.
pub(in crate::cli) fn human_lines(answer: &Value) -> String {
    let mut out = String::new();
    for event in answer["events"].as_array().into_iter().flatten() {
        let text = |name: &str| event[name].as_str().unwrap_or("").to_owned();
        let detail = match event["kind"].as_str() {
            Some("agent") => text("state"),
            Some("notification") => text("title"),
            Some("dialog") => text("dialog_kind"),
            Some("reset") => text("reason"),
            _ => text("name"),
        };
        let line = format!(
            "{}\t{}\t{}\t{}\t{}",
            event["seq"],
            text("kind"),
            text("change"),
            text("id"),
            detail.replace(['\t', '\n', '\r'], " "),
        );
        out.push_str(line.trim_end());
        out.push('\n');
    }
    out
}
