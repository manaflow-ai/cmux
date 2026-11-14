//! A bound machine's senders and their inputs, sans I/O: the agent socket
//! lines, the daemon's activity stream, resume and the deadlines. Every
//! method returns the requests to send now; [`Session::answered`] takes
//! each answer back.

use crate::json::JsonField;
use serde_json::Value;
use std::collections::BTreeMap;

use super::sender::{Answer, AttentionQueue, EventOutcome, EventQueue, OpRequest, Reporter};
use super::wire::{
    ACP_ACTIVITY_TTL_MS, ATTENTION_EMIT_OP, Activity, ActivityChange, DaemonInfo, EVENT_EMIT_OP,
    activity_from_daemon,
};
use super::workload::Workload;
use serde_json::json;

pub struct Session {
    pub reporter: Reporter,
    pub events: EventQueue,
    pub attention: AttentionQueue,
    /// The daemon block without `activity` (bind's block).
    base: DaemonInfo,
    /// The daemon's activity stream and the socket's `activity` lines (each replaces it).
    own: Activity,
    /// acpmux's sessions at work (`acp_activity` lines, one count per daemon), added to
    /// [`Self::own`].
    acp: AcpActivity,
    /// The daemon's activity stream is live.
    stream_live: bool,
    /// The workload probe's last reported result (`workload.rs`); None while it is unknown.
    workload: Option<Workload>,
}

/// What the machine's acpmux daemons last said: each one's sessions at work and until when it
/// holds (cmux#33330: a machine may run several, each on its own home, and an idle one's renewal
/// must not replace a busy one's), and their agents' last action. The count is known while any
/// daemon's holds.
#[derive(Debug, Default)]
struct AcpActivity {
    /// By the line's `daemon` (its socket path; "" for a daemon that names none).
    daemons: BTreeMap<String, AcpDaemon>,
    /// Daemons whose count lapsed while it said sessions were at work (cmux#33573): their agent
    /// hosts may still run those turns, so the count stays unknown until each reports again.
    lapsed_busy: std::collections::BTreeSet<String>,
    last_action_at: Option<u64>,
    /// The newest `last_person_prompt_at` any daemon sent (a person's prompt into a chat). Like
    /// `last_action_at`, it outlives a daemon's count and never moves backwards.
    last_person_prompt_at: Option<u64>,
}

#[derive(Debug)]
struct AcpDaemon {
    sessions: u64,
    expires_at: u64,
    /// Its line's `phases` block, if it sent one: whether its model streams are relayed, and
    /// one entry per session at work.
    phases: Option<(bool, Vec<Value>)>,
}

/// The `phases` block of one `acp_activity` line, or None when it has none or it does not read
/// (each turn needs a `phase` string and a `since` time). A block whose turns do not match the
/// line's count is dropped too: the Cloud must never read fewer turns than sessions at work as
/// complete.
fn read_phases(line: &Value, sessions: u64) -> Option<(bool, Vec<Value>)> {
    let block = line.field("phases");
    let turns = block.field("turns").as_array()?;
    let valid = turns.iter().all(|t| {
        t.field("phase").as_str().is_some_and(|p| !p.is_empty() && p.len() <= 32)
            && t.field("since").as_u64().is_some()
    });
    if !valid || turns.len() as u64 != sessions {
        return None;
    }
    Some((block.field("relayed").as_bool() == Some(true), turns.clone()))
}

impl AcpActivity {
    /// Every daemon's sessions at work.
    fn sessions(&self) -> u64 {
        self.daemons.values().map(|d| d.sessions).sum()
    }

    /// Whether the machine's count is known: some daemon's count holds and no daemon lapsed
    /// while busy.
    fn known(&self) -> bool {
        !self.daemons.is_empty() && self.lapsed_busy.is_empty()
    }

    /// Drops the counts that lapsed by `now`, remembering the ones that lapsed while busy.
    fn expire(&mut self, now: u64) {
        let lapsed = &mut self.lapsed_busy;
        self.daemons.retain(|id, d| {
            let holds = d.expires_at > now;
            if !holds && d.sessions > 0 {
                lapsed.insert(id.clone());
            }
            holds
        });
    }

    /// When the first daemon's count lapses.
    fn next_expiry(&self) -> Option<u64> {
        self.daemons.values().map(|d| d.expires_at).min()
    }

    /// The machine's `phases` block: every daemon's turns, relayed only when every daemon's
    /// are. None unless the count is known and every daemon whose count holds sent phases.
    fn phases(&self) -> Option<Value> {
        if !self.known() {
            return None;
        }
        let mut relayed = true;
        let mut turns = Vec::new();
        for d in self.daemons.values() {
            let (r, t) = d.phases.as_ref()?;
            relayed &= *r;
            turns.extend(t.iter().cloned());
        }
        Some(json!({"relayed": relayed, "turns": turns}))
    }
}

/// What a report's phases say for the sleep decision: relayed, and each turn's phase and since
/// (a process count or an attached flag alone that changes rides along with the next report).
fn phase_key(phases: &Option<Value>) -> Option<(bool, Vec<(String, u64)>)> {
    let phases = phases.as_ref()?;
    let turns = phases.field("turns").as_array()?;
    let key = turns
        .iter()
        .map(|t| {
            (
                t.field("phase").as_str().unwrap_or("").to_owned(),
                t.field("since").as_u64().unwrap_or(0),
            )
        })
        .collect();
    Some((phases.field("relayed").as_bool() == Some(true), key))
}

/// A log line for the journal, if any.
pub type Note = Option<String>;

impl Session {
    pub fn new(machine: &str, daemon: DaemonInfo, heartbeat_ms: u64) -> Session {
        let base = daemon.with_activity(false, false, false);
        Session {
            reporter: Reporter::new(machine, base.clone()).with_heartbeat_ms(heartbeat_ms),
            events: EventQueue::new(machine),
            attention: AttentionQueue::new(machine),
            base,
            own: Activity::default(),
            acp: AcpActivity::default(),
            stream_live: false,
            workload: None,
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
        self.own_activity(&activity_from_daemon(activity), now)
    }

    /// The daemon's or the socket's activity changed: every change is reported.
    fn own_activity(&mut self, change: &ActivityChange, now: u64) -> Vec<OpRequest> {
        change.apply(&mut self.own);
        let activity = self.activity();
        self.reporter.set_activity(activity, true, now).into_iter().collect()
    }

    /// One acpmux daemon's `{"turns": n, "last_agent_action_at": ms, "daemon": id}`: its count
    /// holds for [`ACP_ACTIVITY_TTL_MS`] unless renewed, beside every other daemon's.
    fn acp_activity(&mut self, line: &Value, now: u64) -> Vec<OpRequest> {
        let id = line.field("daemon").as_str().unwrap_or("").to_owned();
        let sessions = line.field("turns").as_u64().unwrap_or(0);
        let at = line.field("last_agent_action_at").as_u64().filter(|ms| *ms > 0);
        self.acp.last_action_at = self.acp.last_action_at.max(at);
        let prompt = line.field("last_person_prompt_at").as_u64().filter(|ms| *ms > 0);
        self.acp.last_person_prompt_at = self.acp.last_person_prompt_at.max(prompt);
        self.acp.lapsed_busy.remove(&id);
        let phases = read_phases(line, sessions);
        let expires_at = now + ACP_ACTIVITY_TTL_MS;
        self.acp.daemons.insert(id, AcpDaemon { sessions, expires_at, phases });
        self.acp_refresh(now)
    }

    /// acpmux's counts changed: the daemon block (`activity-turns` while a count is known) and
    /// the activity change together, so the report that goes carries both (cmux#33331: an
    /// expiry's report never still says the count is known).
    fn acp_refresh(&mut self, now: u64) -> Vec<OpRequest> {
        let daemon = self.daemon_now();
        let block_changed = &daemon != self.reporter.daemon();
        self.reporter.replace_daemon(daemon);
        let mut out = self.acp_changed(now);
        if block_changed && out.is_empty() {
            out.extend(self.reporter.trigger("daemon", now));
        }
        out
    }

    /// A report is due when the number of open sessions changed, when what a session waits on
    /// changed (its phase or since; the Cloud sleeps a machine inside a turn from the last
    /// report), or, with none open, when a time changed (the idle period counts from it). While
    /// a session is open the machine is not idle, so a newer action only rides along with the
    /// next report. A person's new prompt is always reported: it opens the Cloud's post-chat warm
    /// window, as a person's terminal input does.
    fn acp_changed(&mut self, now: u64) -> Vec<OpRequest> {
        let activity = self.activity();
        let reported = self.reporter.activity();
        let report = activity.active_sessions != reported.active_sessions
            || phase_key(&activity.phases) != phase_key(&reported.phases)
            || activity.last_person_prompt_at != reported.last_person_prompt_at
            || (activity.active_sessions == 0 && activity != *reported);
        self.reporter.set_activity(activity, report, now).into_iter().collect()
    }

    /// The activity a report carries: the daemon's plus acpmux's, and the workload.
    fn activity(&self) -> Activity {
        let mut activity = self.own.with_acp(
            self.acp.sessions(),
            self.acp.last_action_at,
            self.acp.phases(),
            self.acp.last_person_prompt_at,
        );
        activity.workload = self.workload.as_ref().map(Workload::to_json);
        activity
    }

    /// The daemon block as it stands: `activity` while the stream is live, `activity-turns` with
    /// it while acpmux's count is known, `activity-phases` with that while its phases are, and
    /// `activity-workload` with `activity` while the workload probe reads.
    fn daemon_now(&self) -> DaemonInfo {
        self.base
            .with_activity(self.stream_live, self.acp.known(), self.acp.phases().is_some())
            .with_workload(self.workload.is_some())
    }

    /// One workload probe (`workload.rs`; None: it did not read). A report goes when the machine
    /// turns busy or quiet, when its listening ports or timers change, when a quiet period starts
    /// anew, and when the probe starts or stops reading. Which processes use CPU while it is busy
    /// rides along with the next report.
    pub fn workload(&mut self, seen: Option<Workload>, now: u64) -> Vec<OpRequest> {
        let next = match (seen, &self.workload) {
            (Some(seen), Some(cur)) if seen.key() == cur.key() => return Vec::new(),
            (seen, _) => seen,
        };
        if next.is_none() && self.workload.is_none() {
            return Vec::new();
        }
        self.workload = next;
        self.reporter.replace_daemon(self.daemon_now());
        let activity = self.activity();
        self.reporter.set_activity(activity, true, now).into_iter().collect()
    }

    /// The updater's block the first report carries (no report of its own: `start` makes it).
    pub fn with_updater(mut self, block: Option<Value>) -> Session {
        let _ = self.reporter.set_updater(block, false, 0);
        self
    }

    /// The updater's block as it stands (`updater/look.rs` `report`). A report goes
    /// when its outcome, reason, run or swap changed; a check that only moved its
    /// time rides along with the next report.
    pub fn updater(&mut self, block: Option<Value>, now: u64) -> Vec<OpRequest> {
        let cur = self.reporter.updater().cloned();
        let changed =
            crate::updater::look::report_key(&block) != crate::updater::look::report_key(&cur);
        self.reporter.set_updater(block, changed, now).into_iter().collect()
    }

    /// The activity stream connected or dropped: `activity` is advertised
    /// only while it is live.
    pub fn activity_stream(&mut self, connected: bool, now: u64) -> Vec<OpRequest> {
        self.stream_live = connected;
        self.daemon_block(now)
    }

    /// The session host answered `identify`: its daemon block (version and capabilities, as
    /// `daemon_info_from_identify` reads them) replaces the one this session started with when
    /// they differ, and the next report names it at once.
    ///
    /// The agent reads the block once at its start, and it starts the session host at the same
    /// moment, so on a bound machine its first `identify` finds no session host yet and it takes
    /// the bake's recorded `/etc/cmux/daemon.json`: the image's build, not the one running. After
    /// a self-update's restart every report then named the old build, and the Cloud, which tells
    /// an update's own restart from use by the version changing (cmux-platform `IdlePolicy.ts`
    /// `UpdateSettle`), read each restart's acpmux time as an agent's action: an untouched
    /// machine never paused (staging probe machine-idle-pause, 2026-11-07 and 2026-11-08).
    pub fn daemon_identified(&mut self, daemon: &DaemonInfo, now: u64) -> Vec<OpRequest> {
        let base = daemon.with_activity(false, false, false);
        if base == self.base {
            return Vec::new();
        }
        self.base = base;
        self.daemon_block(now)
    }

    /// The daemon block as it stands: `activity` while the stream is live, `activity-turns` with
    /// it while acpmux's count is known.
    fn daemon_block(&mut self, now: u64) -> Vec<OpRequest> {
        let daemon = self.daemon_now();
        if &daemon == self.reporter.daemon() {
            return Vec::new();
        }
        self.reporter.set_daemon(daemon, now).into_iter().collect()
    }

    /// One JSON line from the agent socket: `{"activity": {...}}`, `{"acp_activity": {...}}`,
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
        if msg.field("activity").is_object() {
            let change = ActivityChange::from_json(msg.field("activity"));
            out.extend(self.own_activity(&change, now));
        }
        if msg.field("acp_activity").is_object() {
            out.extend(self.acp_activity(msg.field("acp_activity"), now));
        }
        if msg.field("event").is_object() {
            let event = msg.field("event");
            let kind = event.field("kind").as_str().unwrap_or("");
            let at = event.field("at").as_u64().unwrap_or(0);
            match self.events.emit(kind, at, event.field("data").clone()) {
                Ok(req) => out.extend(req),
                Err(e) => note = Some(format!("socket line refused: {e}")),
            }
        }
        if msg.field("attention").is_object() {
            match self.attention.emit(msg.field("attention")) {
                Ok(Some(req)) => out.push(req),
                Ok(None) => {}
                Err(e) => note = Some(format!("socket line refused: {e}")),
            }
        }
        if *msg.field("resume") == true {
            out.extend(self.reporter.trigger("resume", now));
        }
        (out, note)
    }

    /// Runs the due deadlines of both senders.
    pub fn fire(&mut self, now: u64) -> Vec<OpRequest> {
        let mut out = Vec::new();
        if self.acp.next_expiry().is_some_and(|at| at <= now) {
            // A daemon went quiet (it stopped or died): its sessions no longer count, and the
            // report no longer says it knows them while none is left or one lapsed busy.
            self.acp.expire(now);
            out.extend(self.acp_refresh(now));
        }
        out.extend(self.reporter.fire(now));
        out.extend(self.events.fire(now));
        if let Some(req) = self.attention.fire(now) {
            out.push(req);
        }
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
        if request.op == ATTENTION_EMIT_OP {
            let (outcome, next) = self.attention.finished(answer, now, random);
            let note = match outcome {
                EventOutcome::Dropped(why) => Some(format!("attention dropped: {why}")),
                _ => None,
            };
            return (next.into_iter().collect(), note);
        }
        let note = Some(report_note(&request.reason, answer));
        (self.reporter.finished(answer, now, random).into_iter().collect(), note)
    }

    pub fn next_deadline(&self) -> Option<u64> {
        [
            self.reporter.next_deadline(),
            self.events.next_deadline(),
            self.attention.next_deadline(),
            self.acp.next_expiry(),
        ]
        .into_iter()
        .flatten()
        .min()
    }
}

/// `report <reason> applied|held|failed[ HTTP n]` (the smoke greps it).
pub fn report_note(reason: &str, answer: &Answer) -> String {
    match answer {
        Answer::Http { status: 200, body } if *body.field("ok") == true => {
            let applied = *body.field("value").field("applied") == true;
            format!("report {reason} {}", if applied { "applied" } else { "held" })
        }
        Answer::Http { status, .. } => format!("report {reason} failed HTTP {status}"),
        Answer::Transport => format!("report {reason} failed"),
    }
}

#[cfg(test)]
mod tests;
