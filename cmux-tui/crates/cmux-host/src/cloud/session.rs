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
}

#[derive(Debug)]
struct AcpDaemon {
    sessions: u64,
    expires_at: u64,
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
}

/// A log line for the journal, if any.
pub type Note = Option<String>;

impl Session {
    pub fn new(machine: &str, daemon: DaemonInfo, heartbeat_ms: u64) -> Session {
        let base = daemon.with_activity(false, false);
        Session {
            reporter: Reporter::new(machine, base.clone()).with_heartbeat_ms(heartbeat_ms),
            events: EventQueue::new(machine),
            attention: AttentionQueue::new(machine),
            base,
            own: Activity::default(),
            acp: AcpActivity::default(),
            stream_live: false,
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
        self.acp.lapsed_busy.remove(&id);
        self.acp.daemons.insert(id, AcpDaemon { sessions, expires_at: now + ACP_ACTIVITY_TTL_MS });
        self.acp_refresh(now)
    }

    /// acpmux's counts changed: the daemon block (`activity-turns` while a count is known) and
    /// the activity change together, so the report that goes carries both (cmux#33331: an
    /// expiry's report never still says the count is known).
    fn acp_refresh(&mut self, now: u64) -> Vec<OpRequest> {
        let daemon = self.base.with_activity(self.stream_live, self.acp.known());
        let block_changed = &daemon != self.reporter.daemon();
        self.reporter.replace_daemon(daemon);
        let mut out = self.acp_changed(now);
        if block_changed && out.is_empty() {
            out.extend(self.reporter.trigger("daemon", now));
        }
        out
    }

    /// A report is due when the number of open sessions changed, or, with none open, when a
    /// time changed (the idle period counts from it). While a session is open the machine is not
    /// idle, so a newer action only rides along with the next report.
    fn acp_changed(&mut self, now: u64) -> Vec<OpRequest> {
        let activity = self.activity();
        let reported = self.reporter.activity();
        let report = activity.active_sessions != reported.active_sessions
            || (activity.active_sessions == 0 && activity != *reported);
        self.reporter.set_activity(activity, report, now).into_iter().collect()
    }

    /// The activity a report carries: the daemon's plus acpmux's.
    fn activity(&self) -> Activity {
        self.own.with_acp(self.acp.sessions(), self.acp.last_action_at)
    }

    /// The activity stream connected or dropped: `activity` is advertised
    /// only while it is live.
    pub fn activity_stream(&mut self, connected: bool, now: u64) -> Vec<OpRequest> {
        self.stream_live = connected;
        self.daemon_block(now)
    }

    /// The daemon block as it stands: `activity` while the stream is live, `activity-turns` with
    /// it while acpmux's count is known.
    fn daemon_block(&mut self, now: u64) -> Vec<OpRequest> {
        let daemon = self.base.with_activity(self.stream_live, self.acp.known());
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
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn socket_attention_becomes_the_vm_principal_op() {
        let mut session = Session::new(
            "vm_m0000000000000000001",
            DaemonInfo { version: "test".into(), capabilities: vec![] },
            60_000,
        );
        let line = json!({
            "attention": {
                "event_id": "attn_1", "kind": "question", "session": "acp_s1",
                "title": "Cloud chat", "occurred_at": 1_790_000_000_000u64
            }
        })
        .to_string();
        let (requests, note) = session.line(&line, 1);
        assert!(note.is_none());
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].op, ATTENTION_EMIT_OP);
        assert_eq!(requests[0].params["event_id"], "attn_1");
        assert!(requests[0].params.get("body").is_none());
        let (next, note) = session.answered(
            &requests[0],
            &Answer::Http { status: 200, body: json!({"ok": true}) },
            2,
            0.5,
        );
        assert!(note.is_none());
        assert!(next.is_empty());
        assert_eq!(session.attention.len(), 0);
    }
    fn session() -> Session {
        Session::new(
            "vm_m0000000000000000001",
            DaemonInfo { version: "test".into(), capabilities: vec![] },
            3_600_000,
        )
    }

    fn ok() -> Answer {
        Answer::Http { status: 200, body: json!({"ok": true, "value": {"applied": true}}) }
    }

    fn acp(turns: u64, at: Option<u64>) -> String {
        let mut a = json!({"turns": turns});
        if let Some(at) = at {
            a["last_agent_action_at"] = json!(at);
        }
        json!({"acp_activity": a}).to_string()
    }

    /// A Cloud chat mid-turn with no app attached: the daemon sees no session, acpmux one.
    /// The report counts it; once the turn ends the count drops and the end is the last action.
    #[test]
    fn a_running_acpmux_turn_with_no_attached_client_is_active_until_it_ends() {
        let mut s = session();
        let start = s.start(0);
        s.answered(&start[0], &ok(), 0, 0.5);
        let idle = json!({"attached_clients": 0, "live_agents": 0});
        let r = s.daemon_activity(&idle, 100);
        assert!(r.is_empty(), "inside the 10 s window");
        // Past the window: the held report goes with 0 sessions.
        let r = s.fire(20_000);
        assert_eq!(r[0].params["activity"]["active_sessions"], 0);
        s.answered(&r[0], &ok(), 20_000, 0.5);

        let (r, note) = s.line(&acp(1, Some(1_790_000_000_000)), 40_000);
        assert!(note.is_none());
        assert_eq!(r.len(), 1, "a turn that starts is reported at once");
        assert_eq!(r[0].params["activity"]["active_sessions"], 1);
        assert_eq!(r[0].params["activity"]["last_agent_action_at"], 1_790_000_000_000u64);
        s.answered(&r[0], &ok(), 40_000, 0.5);

        // The daemon's own change never overwrites acpmux's count.
        let r = s.daemon_activity(&idle, 60_000);
        assert_eq!(r[0].params["activity"]["active_sessions"], 1);
        s.answered(&r[0], &ok(), 60_000, 0.5);

        // A renewal with a newer action changes no count: no report, the time rides along.
        let (r, _) = s.line(&acp(1, Some(1_790_000_020_000)), 80_000);
        assert!(r.is_empty(), "no report for a renewal while a turn runs");
        assert_eq!(s.reporter.activity().last_agent_action_at, Some(1_790_000_020_000));

        // The turn ends: the count drops and the end time is the last agent action.
        let end = 1_790_000_030_000u64;
        let (r, _) = s.line(&acp(0, Some(end)), 90_000);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].params["activity"]["active_sessions"], 0);
        assert_eq!(r[0].params["activity"]["last_agent_action_at"], end);
        assert_eq!(s.acp.next_expiry(), Some(90_000 + ACP_ACTIVITY_TTL_MS), "known until then");
    }

    /// Counts add up: an attached client and a running turn are two open sessions.
    #[test]
    fn the_daemon_count_and_acpmux_turns_add_up() {
        let mut s = session();
        s.line(&acp(2, None), 0);
        s.daemon_activity(&json!({"attached_clients": 1, "live_agents": 0}), 0);
        assert_eq!(s.reporter.activity().active_sessions, 3);
        s.line(&json!({"activity": {"active_sessions": 0}}).to_string(), 0);
        assert_eq!(
            s.reporter.activity().active_sessions,
            2,
            "a socket activity line keeps acpmux's"
        );
    }

    /// acpmux that stops renewing mid-turn (it died) stops counting after the TTL, so the
    /// machine can go idle again.
    #[test]
    fn an_acpmux_count_not_renewed_expires() {
        let mut s = session();
        let start = s.start(0);
        s.answered(&start[0], &ok(), 0, 0.5);
        let (r, _) = s.line(&acp(1, Some(5)), 20_000);
        s.answered(&r[0], &ok(), 20_000, 0.5);
        assert_eq!(s.next_deadline(), Some(20_000 + ACP_ACTIVITY_TTL_MS));
        assert!(s.fire(20_000 + ACP_ACTIVITY_TTL_MS - 1).is_empty());
        let r = s.fire(20_000 + ACP_ACTIVITY_TTL_MS);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].params["activity"]["active_sessions"], 0);
        assert_eq!(r[0].params["activity"]["last_agent_action_at"], 5);
    }

    /// `activity-turns` travels with `activity`, only while acpmux's count is known: an agent
    /// that just started has not heard from acpmux, so its 0 is not a known 0.
    #[test]
    fn activity_turns_is_advertised_only_while_acpmux_reports() {
        use super::super::wire::{ACTIVITY_CAPABILITY, ACTIVITY_TURNS_CAPABILITY};
        let base = DaemonInfo { version: "v".into(), capabilities: vec!["fs-v1".into()] };
        let both = base.with_activity(true, true);
        assert_eq!(both.capabilities, ["fs-v1", ACTIVITY_CAPABILITY, ACTIVITY_TURNS_CAPABILITY]);
        assert_eq!(both.with_activity(true, true), both, "never twice");
        assert_eq!(both.with_activity(true, false).capabilities, ["fs-v1", ACTIVITY_CAPABILITY]);
        assert_eq!(both.with_activity(false, true), base, "never without `activity`");

        let caps = |s: &Session| s.reporter.daemon().capabilities.clone();
        let mut s = session();
        s.activity_stream(true, 0);
        assert_eq!(caps(&s), [ACTIVITY_CAPABILITY], "a fresh agent: no word from acpmux yet");
        s.line(&acp(0, None), 1_000);
        assert_eq!(caps(&s), [ACTIVITY_CAPABILITY, ACTIVITY_TURNS_CAPABILITY]);
        s.line(&acp(0, None), 21_000);
        s.fire(21_000 + ACP_ACTIVITY_TTL_MS);
        assert_eq!(caps(&s), [ACTIVITY_CAPABILITY], "acpmux went quiet");
    }

    fn acp_from(daemon: &str, turns: u64) -> String {
        json!({"acp_activity": {"turns": turns, "daemon": daemon}}).to_string()
    }

    /// cmux#33330: two acpmux daemons on one machine. The idle one's renewal never replaces the
    /// busy one's count; each lapses on its own.
    #[test]
    fn each_acpmux_daemon_keeps_its_own_count() {
        let mut s = session();
        s.line(&acp_from("/a.sock", 1), 0);
        s.line(&acp_from("/b.sock", 0), 10_000);
        assert_eq!(
            s.reporter.activity().active_sessions,
            1,
            "an idle daemon's line replaced a busy one's"
        );
        s.line(&acp_from("/b.sock", 2), 20_000);
        assert_eq!(s.reporter.activity().active_sessions, 3, "the counts add up");
        // a stops renewing: its count lapses, b's stays.
        s.line(&acp_from("/b.sock", 2), 80_000);
        s.fire(ACP_ACTIVITY_TTL_MS);
        assert_eq!(s.reporter.activity().active_sessions, 2);
        s.fire(80_000 + ACP_ACTIVITY_TTL_MS);
        assert_eq!(s.reporter.activity().active_sessions, 0);
        assert!(!s.acp.known());
    }

    /// cmux#33331: the report an expiry sends already drops `activity-turns`, so it never says
    /// "0 sessions, known" for a count nobody renews.
    #[test]
    fn the_expiry_report_no_longer_advertises_activity_turns() {
        use super::super::wire::ACTIVITY_TURNS_CAPABILITY;
        let mut s = session();
        let start = s.start(0);
        s.answered(&start[0], &ok(), 0, 0.5);
        for r in s.activity_stream(true, 20_000) {
            s.answered(&r, &ok(), 20_000, 0.5);
        }
        let (r, _) = s.line(&acp(1, Some(5)), 40_000);
        assert_eq!(r.len(), 1);
        let caps = |r: &OpRequest| r.params["daemon"]["capabilities"].clone();
        assert!(
            caps(&r[0]).as_array().unwrap().contains(&json!(ACTIVITY_TURNS_CAPABILITY)),
            "the first acpmux line's report already says the count is known: {}",
            caps(&r[0])
        );
        s.answered(&r[0], &ok(), 40_000, 0.5);
        let r = s.fire(40_000 + ACP_ACTIVITY_TTL_MS);
        assert_eq!(r.len(), 1, "one report for the expiry");
        assert_eq!(r[0].params["activity"]["active_sessions"], 0);
        assert!(
            !caps(&r[0]).as_array().unwrap().contains(&json!(ACTIVITY_TURNS_CAPABILITY)),
            "the expiry report still advertises activity-turns: {}",
            caps(&r[0])
        );
    }

    /// cmux#33573: daemon a lapses while it says a turn runs and daemon b keeps renewing 0. a's
    /// agent host may still run that turn, so the report stops advertising `activity-turns`
    /// until a reports again; it never says "0 sessions, known".
    #[test]
    fn a_busy_daemon_that_lapses_beside_an_idle_one_makes_the_count_unknown() {
        use super::super::wire::ACTIVITY_TURNS_CAPABILITY;
        let mut s = session();
        s.activity_stream(true, 0);
        let turns = |s: &Session| {
            s.reporter.daemon().capabilities.iter().any(|c| c == ACTIVITY_TURNS_CAPABILITY)
        };
        s.line(&acp_from("/a.sock", 1), 0);
        s.line(&acp_from("/b.sock", 0), 0);
        s.line(&acp_from("/b.sock", 0), 60_000);
        assert!(turns(&s));
        s.fire(ACP_ACTIVITY_TTL_MS);
        assert_eq!(s.reporter.activity().active_sessions, 0);
        assert!(!turns(&s), "a busy daemon lapsed: 0 sessions must not be known");
        // b's renewals do not make it known again; a's return does.
        s.line(&acp_from("/b.sock", 0), 120_000);
        assert!(!turns(&s));
        s.line(&acp_from("/a.sock", 0), 130_000);
        assert!(turns(&s), "a reported again");
        // An idle daemon that lapses changes nothing.
        s.line(&acp_from("/a.sock", 0), 140_000);
        s.fire(130_000 + ACP_ACTIVITY_TTL_MS);
        s.fire(140_000 + ACP_ACTIVITY_TTL_MS - 1);
        assert!(turns(&s), "an idle daemon's lapse is not a busy one's");
    }
}
