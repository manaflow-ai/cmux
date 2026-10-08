//! A bound machine's senders and their inputs, sans I/O: the agent socket
//! lines, the daemon's activity stream, resume and the deadlines. Every
//! method returns the requests to send now; [`Session::answered`] takes
//! each answer back.

use serde_json::Value;

use super::sender::{Answer, EventOutcome, EventQueue, OpRequest, Reporter};
use super::wire::{ActivityChange, DaemonInfo, EVENT_EMIT_OP, activity_from_daemon};

pub struct Session {
    pub reporter: Reporter,
    pub events: EventQueue,
    /// The daemon block without `activity` (bind's block).
    base: DaemonInfo,
}

/// A log line for the journal, if any.
pub type Note = Option<String>;

impl Session {
    pub fn new(machine: &str, daemon: DaemonInfo, heartbeat_ms: u64) -> Session {
        let base = daemon.with_activity(false);
        Session {
            reporter: Reporter::new(machine, base.clone()).with_heartbeat_ms(heartbeat_ms),
            events: EventQueue::new(machine),
            base,
        }
    }

    /// After bind and after every start of the agent: one report.
    pub fn start(&mut self, now: u64) -> Vec<OpRequest> {
        self.reporter.trigger("start", now).into_iter().collect()
    }

    /// The guest resumed (the supervisor's clock-set wake, a confirmed
    /// unchanged instance id): one report named `resume`.
    pub fn resume(&mut self, now: u64) -> Vec<OpRequest> {
        self.reporter.trigger("resume", now).into_iter().collect()
    }

    /// One `subscribe-activity` snapshot or `activity-changed` event.
    pub fn daemon_activity(&mut self, activity: &Value, now: u64) -> Vec<OpRequest> {
        self.reporter.update(&activity_from_daemon(activity), now).into_iter().collect()
    }

    /// The activity stream connected or dropped: `activity` is advertised
    /// only while it is live.
    pub fn activity_stream(&mut self, connected: bool, now: u64) -> Vec<OpRequest> {
        let daemon = self.base.with_activity(connected);
        if &daemon == self.reporter.daemon() {
            return Vec::new();
        }
        self.reporter.set_daemon(daemon, now).into_iter().collect()
    }

    /// One JSON line from the agent socket: `{"activity": {...}}`,
    /// `{"event": {"kind", "at", "data"}}` or `{"resume": true}`.
    pub fn line(&mut self, line: &str, now: u64) -> (Vec<OpRequest>, Note) {
        if line.trim().is_empty() {
            return (Vec::new(), None);
        }
        let msg: Value = match serde_json::from_str(line) {
            Ok(msg) => msg,
            Err(e) => return (Vec::new(), Some(format!("socket line refused: {e}"))),
        };
        let mut out = Vec::new();
        let mut note = None;
        if msg["activity"].is_object() {
            let change = ActivityChange::from_json(&msg["activity"]);
            out.extend(self.reporter.update(&change, now));
        }
        if msg["event"].is_object() {
            let event = &msg["event"];
            let kind = event["kind"].as_str().unwrap_or("");
            let at = event["at"].as_u64().unwrap_or(0);
            match self.events.emit(kind, at, event["data"].clone()) {
                Ok(req) => out.extend(req),
                Err(e) => note = Some(format!("socket line refused: {e}")),
            }
        }
        if msg["resume"] == true {
            out.extend(self.reporter.trigger("resume", now));
        }
        (out, note)
    }

    /// Runs the due deadlines of both senders.
    pub fn fire(&mut self, now: u64) -> Vec<OpRequest> {
        let mut out: Vec<OpRequest> = self.reporter.fire(now).into_iter().collect();
        out.extend(self.events.fire(now));
        out
    }

    /// The answer to `request`; returns what to send next and a log line.
    pub fn answered(
        &mut self,
        request: &OpRequest,
        answer: &Answer,
        now: u64,
        random: f64,
    ) -> (Vec<OpRequest>, Note) {
        if request.op == EVENT_EMIT_OP {
            let (outcome, next) = self.events.finished(answer, now, random);
            let note = match outcome {
                EventOutcome::Dropped(why) => Some(format!("event dropped: {why}")),
                _ => None,
            };
            return (next.into_iter().collect(), note);
        }
        let note = Some(report_note(&request.reason, answer));
        (self.reporter.finished(answer, now, random).into_iter().collect(), note)
    }

    pub fn next_deadline(&self) -> Option<u64> {
        [self.reporter.next_deadline(), self.events.next_deadline()].into_iter().flatten().min()
    }
}

/// `report <reason> applied|held|failed[ HTTP n]` (the smoke greps it).
pub fn report_note(reason: &str, answer: &Answer) -> String {
    match answer {
        Answer::Http { status: 200, body } if body["ok"] == true => {
            let applied = body["value"]["applied"] == true;
            format!("report {reason} {}", if applied { "applied" } else { "held" })
        }
        Answer::Http { status, .. } => format!("report {reason} failed HTTP {status}"),
        Answer::Transport => format!("report {reason} failed"),
    }
}
