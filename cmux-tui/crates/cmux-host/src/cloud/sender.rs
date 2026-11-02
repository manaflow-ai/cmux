//! The two senders of the Cloud agent, sans I/O: `cloud.vm.status.report`
//! ([`Reporter`]) and `cloud.vm.event.emit` ([`EventQueue`]).
//!
//! Each holds at most one request in flight and a few one-shot deadlines
//! (absolute monotonic milliseconds). The caller sends what a method
//! returns, reports the answer with `finished`, and calls `fire` once the
//! earliest `next_deadline` has passed. There is no tick.

use crate::json::JsonField;
use std::collections::VecDeque;

use serde_json::{Value, json};

use super::wire::{
    ATTENTION_EMIT_OP, Activity, ActivityChange, DEFAULT_HEARTBEAT_MS, DaemonInfo, EVENT_EMIT_OP,
    REPORT_MIN_INTERVAL_MS, STATUS_REPORT_OP, check_event, retry_after_ms,
};

/// Exponential backoff with +-10% jitter, at least `retry_after_ms`, never
/// above the cap.
#[derive(Clone, Debug)]
pub struct Backoff {
    attempt: u32,
    initial_ms: u64,
    max_ms: u64,
}

#[derive(Clone, Debug, PartialEq)]
struct QueuedAttention {
    event_id: String,
    kind: String,
    session: String,
    title: String,
    occurred_at: u64,
}

/// Durable attention transitions sent through the VM-principal op. The
/// platform performs content/idempotency checks; this queue only handles
/// transport and retryable server failures.
#[derive(Debug)]
pub struct AttentionQueue {
    machine: String,
    queue: VecDeque<QueuedAttention>,
    in_flight: bool,
    retry_at: Option<u64>,
    backoff: Backoff,
}

impl AttentionQueue {
    pub fn new(machine: &str) -> Self {
        Self {
            machine: machine.to_owned(),
            queue: VecDeque::new(),
            in_flight: false,
            retry_at: None,
            backoff: Backoff::new(1_000, 600_000),
        }
    }

    pub fn emit(&mut self, event: &Value) -> Result<Option<OpRequest>, String> {
        let text = |key: &str| event[key].as_str().unwrap_or("");
        let event_id = text("event_id");
        let kind = text("kind");
        let session = text("session");
        let title = text("title");
        let occurred_at = event["occurred_at"].as_u64().unwrap_or(0);
        if event_id.is_empty()
            || event_id.len() > 128
            || !event_id.bytes().all(|b| b.is_ascii_alphanumeric() || b"._:-".contains(&b))
            || !matches!(kind, "question" | "permission" | "done")
            || session.is_empty()
            || session.len() > 128
            || title.is_empty()
            || title.chars().count() > 200
            || occurred_at == 0
        {
            return Err("invalid attention event".to_owned());
        }
        if self.queue.len() >= EVENT_QUEUE_MAX {
            return Err("attention queue full".to_owned());
        }
        self.queue.push_back(QueuedAttention {
            event_id: event_id.to_owned(),
            kind: kind.to_owned(),
            session: session.to_owned(),
            title: title.to_owned(),
            occurred_at,
        });
        Ok(self.pump())
    }

    pub fn finished(
        &mut self,
        answer: &Answer,
        now: u64,
        random: f64,
    ) -> (EventOutcome, Option<OpRequest>) {
        self.in_flight = false;
        let outcome = match answer {
            a if a.ok() => {
                self.queue.pop_front();
                self.backoff.reset();
                EventOutcome::Delivered
            }
            Answer::Http { status, body } => {
                let code = body
                    .field("error")
                    .field("code")
                    .as_str()
                    .or_else(|| body.field("code").as_str())
                    .unwrap_or("");
                if code == "cloud.rate_limited" {
                    self.retry_at = Some(now + retry_after_ms(body).max(1));
                    EventOutcome::Retrying
                } else if *status >= 500 {
                    self.retry_at = Some(now + self.backoff.next(0, random));
                    EventOutcome::Retrying
                } else {
                    let kind = self.queue.pop_front().map(|e| e.kind).unwrap_or_default();
                    EventOutcome::Dropped(format!(
                        "{kind}: {}",
                        if code.is_empty() { format!("HTTP {status}") } else { code.to_owned() }
                    ))
                }
            }
            Answer::Transport => {
                self.retry_at = Some(now + self.backoff.next(0, random));
                EventOutcome::Retrying
            }
        };
        (outcome, self.pump())
    }

    pub fn fire(&mut self, now: u64) -> Option<OpRequest> {
        if self.retry_at.is_some_and(|at| at <= now) {
            self.retry_at = None;
            self.pump()
        } else {
            None
        }
    }
    pub fn next_deadline(&self) -> Option<u64> {
        self.retry_at
    }

    pub fn len(&self) -> usize {
        self.queue.len()
    }

    pub fn is_empty(&self) -> bool {
        self.queue.is_empty()
    }

    fn pump(&mut self) -> Option<OpRequest> {
        if self.in_flight || self.retry_at.is_some() {
            return None;
        }
        let head = self.queue.front()?;
        self.in_flight = true;
        Some(OpRequest {
            op: ATTENTION_EMIT_OP,
            params: json!({ "machine": self.machine, "event_id": head.event_id, "kind": head.kind, "session": head.session, "title": head.title, "occurred_at": head.occurred_at }),
            reason: format!("attention.{}", head.kind),
        })
    }
}

impl Backoff {
    pub fn new(initial_ms: u64, max_ms: u64) -> Backoff {
        Backoff { attempt: 0, initial_ms, max_ms }
    }

    /// `random` in `[0, 1)`.
    pub fn next(&mut self, retry_after_ms: u64, random: f64) -> u64 {
        let factor = 2u64.saturating_pow(self.attempt.min(40));
        let base = self.initial_ms.saturating_mul(factor).min(self.max_ms);
        self.attempt = self.attempt.saturating_add(1);
        let jittered = (base as f64 * (0.9 + 0.2 * random.clamp(0.0, 1.0))).round() as u64;
        jittered.max(retry_after_ms).min(self.max_ms)
    }

    pub fn reset(&mut self) {
        self.attempt = 0;
    }
}

/// One `/v1/ops` request: `{"op": op, "params": params}`.
#[derive(Clone, Debug, PartialEq)]
pub struct OpRequest {
    pub op: &'static str,
    pub params: Value,
    /// Why it is sent: the reasons joined with `+` (reports only).
    pub reason: String,
}

/// What a sent op came back with. `Transport` is a network or token error.
#[derive(Clone, Debug, PartialEq)]
pub enum Answer {
    Http { status: u16, body: Value },
    Transport,
}

impl Answer {
    fn ok(&self) -> bool {
        matches!(self, Answer::Http { status: 200, body } if *body.field("ok") == true)
    }
}

/// The machine state a report names.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MachineState {
    Running,
    Degraded,
    Stopping,
}

impl MachineState {
    fn as_str(self) -> &'static str {
        match self {
            MachineState::Running => "running",
            MachineState::Degraded => "degraded",
            MachineState::Stopping => "stopping",
        }
    }
}

/// `cloud.vm.status.report`: once after bind and after every start, on
/// change at most once per 10 s (latest wins, every reason named), a
/// heartbeat deadline after each accepted report, and on failure a backoff
/// (`retry_after_ms` honored) up to 10 min while the heartbeat waits.
#[derive(Debug)]
pub struct Reporter {
    machine: String,
    daemon: DaemonInfo,
    activity: Activity,
    state: MachineState,
    dirty: bool,
    pending: Vec<String>,
    in_flight: Option<Vec<String>>,
    last_sent_at: Option<u64>,
    window_at: Option<u64>,
    retry_at: Option<u64>,
    heartbeat_at: Option<u64>,
    backoff: Backoff,
    heartbeat_ms: u64,
    min_interval_ms: u64,
}

impl Reporter {
    pub fn new(machine: &str, daemon: DaemonInfo) -> Reporter {
        Reporter {
            machine: machine.to_owned(),
            daemon,
            activity: Activity::default(),
            state: MachineState::Running,
            dirty: false,
            pending: Vec::new(),
            in_flight: None,
            last_sent_at: None,
            window_at: None,
            retry_at: None,
            heartbeat_at: None,
            backoff: Backoff::new(5_000, 600_000),
            heartbeat_ms: DEFAULT_HEARTBEAT_MS,
            min_interval_ms: REPORT_MIN_INTERVAL_MS,
        }
    }

    pub fn with_heartbeat_ms(mut self, ms: u64) -> Reporter {
        self.heartbeat_ms = ms;
        self
    }

    pub fn heartbeat_ms(&self) -> u64 {
        self.heartbeat_ms
    }

    pub fn daemon(&self) -> &DaemonInfo {
        &self.daemon
    }

    /// Marks a report due (`start`, `resume`, `heartbeat`, ...).
    pub fn trigger(&mut self, reason: &str, now: u64) -> Option<OpRequest> {
        if !self.pending.iter().any(|r| r == reason) {
            self.pending.push(reason.to_owned());
        }
        self.dirty = true;
        self.schedule(now)
    }

    pub fn update(&mut self, change: &ActivityChange, now: u64) -> Option<OpRequest> {
        change.apply(&mut self.activity);
        self.trigger("change", now)
    }

    /// The daemon block changed (`activity` on while the stream is live).
    pub fn set_daemon(&mut self, daemon: DaemonInfo, now: u64) -> Option<OpRequest> {
        self.daemon = daemon;
        self.trigger("daemon", now)
    }

    pub fn set_state(&mut self, state: MachineState, now: u64) -> Option<OpRequest> {
        self.state = state;
        self.trigger("state", now)
    }

    /// The answer to the request in flight. Returns the next request when
    /// one is due at once.
    pub fn finished(&mut self, answer: &Answer, now: u64, random: f64) -> Option<OpRequest> {
        let reasons = self.in_flight.take().unwrap_or_default();
        if answer.ok() {
            self.backoff.reset();
            // The server counts its 10 s from when it received this report, which is
            // after the send and before `now` (the answer): count from the answer, so
            // the next report never lands inside the server's window and is held.
            self.last_sent_at = Some(now);
            // Held: the server applies it at the end of its window, up to one window
            // after this answer, and its window restarts then. Count from there.
            let held = matches!(answer, Answer::Http { body, .. } if *body.field("value").field("applied") == false);
            if held {
                self.last_sent_at = Some(now + self.min_interval_ms);
            }
            self.heartbeat_at = Some(now + self.heartbeat_ms);
        } else {
            for r in reasons {
                if !self.pending.contains(&r) {
                    self.pending.push(r);
                }
            }
            let after = match answer {
                Answer::Http { body, .. } => retry_after_ms(body),
                Answer::Transport => 0,
            };
            self.dirty = true;
            self.heartbeat_at = None;
            self.retry_at = Some(now + self.backoff.next(after, random));
        }
        self.schedule(now)
    }

    /// Runs the deadlines that are due at `now`; at most one request.
    pub fn fire(&mut self, now: u64) -> Option<OpRequest> {
        if self.retry_at.is_some_and(|at| at <= now) && self.in_flight.is_none() {
            self.retry_at = None;
            return Some(self.send(now));
        }
        if self.window_at.is_some_and(|at| at <= now) {
            self.window_at = None;
            if let Some(req) = self.schedule(now) {
                return Some(req);
            }
        }
        if self.heartbeat_at.is_some_and(|at| at <= now) {
            self.heartbeat_at = None;
            return self.trigger("heartbeat", now);
        }
        None
    }

    pub fn next_deadline(&self) -> Option<u64> {
        [self.window_at, self.retry_at, self.heartbeat_at].into_iter().flatten().min()
    }

    /// Every armed deadline (tests: "at most these timers").
    pub fn deadlines(&self) -> Vec<u64> {
        let mut out: Vec<u64> =
            [self.window_at, self.retry_at, self.heartbeat_at].into_iter().flatten().collect();
        out.sort_unstable();
        out
    }

    fn schedule(&mut self, now: u64) -> Option<OpRequest> {
        if self.in_flight.is_some()
            || self.retry_at.is_some()
            || self.window_at.is_some()
            || !self.dirty
        {
            return None;
        }
        let due = self.last_sent_at.map_or(now, |last| last + self.min_interval_ms);
        if due <= now {
            return Some(self.send(now));
        }
        self.window_at = Some(due);
        None
    }

    fn send(&mut self, now: u64) -> OpRequest {
        self.dirty = false;
        self.last_sent_at = Some(now);
        let reasons = std::mem::take(&mut self.pending);
        let reason = if reasons.is_empty() { "retry".to_owned() } else { reasons.join("+") };
        self.in_flight = Some(reasons);
        OpRequest {
            op: STATUS_REPORT_OP,
            params: json!({
                "machine": self.machine,
                "state": self.state.as_str(),
                "daemon": self.daemon.to_json(),
                "activity": self.activity.to_json(),
            }),
            reason,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
struct QueuedEvent {
    kind: String,
    at: u64,
    data: Value,
}

/// What became of an event answer (for the log).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EventOutcome {
    Delivered,
    Retrying,
    Dropped(String),
}

/// Events a backed-off queue holds before it refuses more (each is at most
/// 4 KB of data, so about 1 MB).
pub const EVENT_QUEUE_MAX: usize = 256;

/// `cloud.vm.event.emit` in order: a rate limit waits `retry_after_ms`, a
/// server error backs off, any other refusal drops the event.
#[derive(Debug)]
pub struct EventQueue {
    machine: String,
    queue: VecDeque<QueuedEvent>,
    in_flight: bool,
    retry_at: Option<u64>,
    backoff: Backoff,
}

impl EventQueue {
    pub fn new(machine: &str) -> EventQueue {
        EventQueue {
            machine: machine.to_owned(),
            queue: VecDeque::new(),
            in_flight: false,
            retry_at: None,
            backoff: Backoff::new(1_000, 600_000),
        }
    }

    /// Queues one event; refuses an unknown kind, more than 4 KB of data, or
    /// a queue already holding `EVENT_QUEUE_MAX` events.
    pub fn emit(&mut self, kind: &str, at: u64, data: Value) -> Result<Option<OpRequest>, String> {
        check_event(kind, &data)?;
        if self.queue.len() >= EVENT_QUEUE_MAX {
            return Err(format!("event queue full ({EVENT_QUEUE_MAX} waiting)"));
        }
        self.queue.push_back(QueuedEvent { kind: kind.to_owned(), at, data });
        Ok(self.pump())
    }

    pub fn finished(
        &mut self,
        answer: &Answer,
        now: u64,
        random: f64,
    ) -> (EventOutcome, Option<OpRequest>) {
        self.in_flight = false;
        let outcome = match answer {
            a if a.ok() => {
                self.queue.pop_front();
                self.backoff.reset();
                EventOutcome::Delivered
            }
            Answer::Http { status, body } => {
                let code = body
                    .field("error")
                    .field("code")
                    .as_str()
                    .or_else(|| body.field("code").as_str())
                    .unwrap_or("")
                    .to_owned();
                if code == "cloud.rate_limited" {
                    self.retry_at = Some(now + retry_after_ms(body).max(1));
                    EventOutcome::Retrying
                } else if *status >= 500 {
                    self.retry_at = Some(now + self.backoff.next(0, random));
                    EventOutcome::Retrying
                } else {
                    let kind = self.queue.pop_front().map(|e| e.kind).unwrap_or_default();
                    let why = if code.is_empty() { format!("HTTP {status}") } else { code };
                    EventOutcome::Dropped(format!("{kind}: {why}"))
                }
            }
            Answer::Transport => {
                self.retry_at = Some(now + self.backoff.next(0, random));
                EventOutcome::Retrying
            }
        };
        (outcome, self.pump())
    }

    pub fn fire(&mut self, now: u64) -> Option<OpRequest> {
        if self.retry_at.is_some_and(|at| at <= now) {
            self.retry_at = None;
            return self.pump();
        }
        None
    }

    pub fn next_deadline(&self) -> Option<u64> {
        self.retry_at
    }

    pub fn len(&self) -> usize {
        self.queue.len()
    }

    pub fn is_empty(&self) -> bool {
        self.queue.is_empty()
    }

    fn pump(&mut self) -> Option<OpRequest> {
        if self.in_flight || self.retry_at.is_some() {
            return None;
        }
        let head = self.queue.front()?;
        self.in_flight = true;
        Some(OpRequest {
            op: EVENT_EMIT_OP,
            params: json!({
                "machine": self.machine,
                "kind": head.kind,
                "at": head.at,
                "data": head.data,
            }),
            reason: head.kind.clone(),
        })
    }
}

#[cfg(test)]
mod event_queue_tests {
    use super::{Answer, AttentionQueue, EventQueue};
    use serde_json::json;

    /// HQ#5351 item 2: nothing drains the queue while it backs off (up to 600 s), so
    /// socket clients could grow the agent's memory without bound. Past its cap the
    /// queue refuses new events and keeps the ones it holds, in order.
    #[test]
    fn a_backed_off_queue_refuses_events_past_its_cap() {
        let mut queue = EventQueue::new("vm-1");
        let first = queue.emit("agent.started", 1, json!({})).unwrap();
        assert!(first.is_some());
        let (_, next) = queue.finished(&Answer::Transport, 0, 0.5);
        assert!(next.is_none());
        let mut refused = 0;
        for at in 2..1_000 {
            if queue.emit("agent.started", at, json!({})).is_err() {
                refused += 1;
            }
        }
        assert_eq!(queue.len(), super::EVENT_QUEUE_MAX);
        assert!(refused > 0);
        let retry = queue.fire(u64::MAX).expect("the head retries");
        assert_eq!(retry.params["at"], 1);
    }

    fn attention(id: &str, kind: &str) -> serde_json::Value {
        serde_json::json!({
            "event_id": id, "kind": kind, "session": "acp_s1", "title": "Cloud chat",
            "occurred_at": 1_790_000_000_000u64
        })
    }

    #[test]
    fn attention_retry_preserves_payload_and_success_drains() {
        let mut queue = AttentionQueue::new("vm-1");
        let first = queue.emit(&attention("attn_1", "question")).unwrap().unwrap();
        let (_, next) = queue.finished(&Answer::Transport, 10, 0.5);
        assert!(next.is_none());
        let retry = queue.fire(1_010).unwrap();
        assert_eq!(retry.params, first.params);
        let (_, next) = queue.finished(
            &Answer::Http { status: 200, body: serde_json::json!({"ok": true}) },
            1_011,
            0.5,
        );
        assert!(next.is_none());
        assert_eq!(queue.len(), 0);
    }

    #[test]
    fn attention_rate_limit_waits_and_denial_drops() {
        let mut queue = AttentionQueue::new("vm-1");
        queue.emit(&attention("attn_2", "permission")).unwrap();
        let answer = Answer::Http {
            status: 429,
            body: serde_json::json!({"error": {"code": "cloud.rate_limited", "details": {"retry_after_ms": 20}}}),
        };
        let (outcome, next) = queue.finished(&answer, 100, 0.5);
        assert_eq!(outcome, super::EventOutcome::Retrying);
        assert!(next.is_none());
        assert!(queue.fire(119).is_none());
        assert!(queue.fire(120).is_some());
        let (outcome, next) = queue.finished(
            &Answer::Http {
                status: 400,
                body: serde_json::json!({"error": {"code": "policy.denied"}}),
            },
            121,
            0.5,
        );
        assert!(matches!(outcome, super::EventOutcome::Dropped(_)));
        assert!(next.is_none());
        assert!(queue.is_empty());
    }

    #[test]
    fn attention_queue_is_bounded() {
        let mut queue = AttentionQueue::new("vm-1");
        queue.emit(&attention("attn_0", "done")).unwrap();
        for i in 1..super::EVENT_QUEUE_MAX {
            queue.emit(&attention(&format!("attn_{i}"), "done")).unwrap();
        }
        assert_eq!(queue.len(), super::EVENT_QUEUE_MAX);
        assert!(queue.emit(&attention("attn_overflow", "done")).is_err());
    }
}
