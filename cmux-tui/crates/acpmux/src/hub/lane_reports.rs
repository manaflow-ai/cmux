//! Part of `Hub`; see `hub/mod.rs`. A lane reports to the session that started it, the way a
//! Claude subagent's parent hears when it stops: at the end of each of the lane's turns its
//! parent gets one short report, without the lane having to remember `acpmux send`.
//!
//! Who a lane reports to is the link the daemon keeps, set from the session its connection
//! proved it runs in (its caller token). The lane's tag `lane.reportsTo` (the parent's exact
//! session id) shows it; removing or changing that tag ends the link, and setting it never
//! makes one.
//!
//! - `session/new` from inside a session: that session is the new one's parent. A run tied to
//!   its connection (`--ephemeral`) or one that asks for no parent (`acpmux new --no-parent`,
//!   `_meta.acpmux.parent: null`) is no lane and gets none.
//! - A lane the person prompts (the app, or a proven person) is theirs from then on: its link
//!   ends, so its turns stop showing in the parent's chat. One started with `--report-to`
//!   (`_meta.acpmux.reportTo`) asked to report, and keeps reporting.
//! - `_acpmux/detach_parent` (`acpmux session detach`) ends a lane's link and removes its tag.
//! - A lane keeps the parent that started it; a session that gives it a later task does not
//!   take it over yet (a follow-up).
//!
//! Lane and parent are sessions of this daemon; a lane or parent on a peer comes later. The
//! daemon keeps each link (its queued report and its last one) in memory.
//!
//! A report is made when the lane's turn ends (`turns.rs`), from that turn's own records and
//! the lane's state then, and queued; delivery and its retries send that report and never read
//! the lane again, so a later turn never leaks into it. One delivery per lane is in flight at a
//! time. A report the parent refused stays queued and goes at the next turn end; a newer turn's
//! report replaces one still queued (keeping the pull requests only that one named).
//!
//! ```text
//! [NAME] BLOCK at SHA12 · 1 P1, 2 P2 · turn N, STATE
//! Whole reply lines, retaining every P1/P2 finding's first sentence
//! Pull requests: URLs its gh pr create calls printed or the reply names, not reported before
//! ```
//!
//! Session and commits live in provenance `details`, collapsed by the pane. Review receipts
//! anywhere in the reply supply the verdict; other replies use their first sentence. The report
//! is automatic, sent at the end of each turn of a session its parent started; answer only if
//! it needs you. Its machine-readable kind, from, to, turn and state remain unchanged.
//!
//! STATE is `idle`, `working on its next prompt`, `waiting on a permission` / `waiting on a
//! question: ...`, or `blocked: ...` (a failed turn and the queue it paused, a stopped agent).
//!
//! - A report the same as the lane's last one (state, reply, pull requests and commits) is not
//!   sent again; the turn still counts as reported.
//! - A turn that ran on lane reports only (a report, or a turn of agent messages, `digest.rs`,
//!   that took in nothing else, and nothing else steered into it, each turn on its own) sends
//!   none, so a parent's turn
//!   on reports never reports upward and a report never answers a report. The hub alone sets a report's provenance
//!   (`prompt_provenance.rs` takes only `agent_message` from a client), so no prompt passes for
//!   one. A report never steers: it waits for the parent's turn to end, so it never becomes part
//!   of a turn that reports.
//! - At most [`MAX_REPORTS`] reports a lane in [`WINDOW_MS`]: past it the newest is held and
//!   goes when the window frees a place (or at a turn end under the cap), whatever the runaway
//!   pair guard (`agent_pairs.rs`) decides.
//! - It goes into the parent as a hub-set prompt with provenance `{kind:
//!   "lane_report", from, fromName, to, turn, state}` (never taken from a client), as another
//!   agent's message (`digest.rs`: the person's prompts go first, a busy parent takes several in
//!   one turn). A lane here counts as its
//!   sender for the runaway guard: a pair that keeps answering reports with no work pauses, and
//!   a report into a paused pair is held for the person to resume.
//! - Prompt id `lane-report-<random>`, the same for every try of one turn's report and sent with
//!   `resend`, so a retry never runs twice and no other prompt takes its id.

use super::*;
use regex::Regex;
use std::collections::{BTreeMap, HashMap};
use std::sync::LazyLock;

/// The lane's tag naming the session it reports to.
pub const TAG: &str = "lane.reportsTo";
/// The provenance kind.
pub(crate) const KIND: &str = "lane_report";
/// Transcript records read per page, newest first, back to the start of the last turn.
const TAIL_RECORDS: usize = 400;
/// Pages read back at most for the last turn (a turn that streamed more records than this
/// holds is read back this far, and its reply marked as cut).
const MAX_TAIL_PAGES: usize = 50;
/// Parents walked up from a session at most. A chain this deep without the session in it is
/// refused too, since a link map that was written wrong could loop past the walk.
const MAX_DEPTH: usize = 16;
/// Reports one lane sends within [`WINDOW_MS`] at most.
pub const MAX_REPORTS: usize = 20;
/// The window of [`MAX_REPORTS`].
pub const WINDOW_MS: u64 = 10 * 60 * 1000;
/// A report's prompt id starts with this.
const PROMPT_PREFIX: &str = "lane-report-";

// Constant patterns; a report only loses its links if one ever failed to build.
static PULL_URL: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+").ok()
});
static FULL_SHA: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r"\b[0-9a-f]{40}\b").ok());

/// Each match of `re` in `text`.
fn matches(re: &Option<Regex>, text: &str) -> Vec<String> {
    re.iter().flat_map(|re| re.find_iter(text)).map(|m| m.as_str().to_owned()).collect()
}

/// One lane's link to its parent.
#[derive(Debug, Clone, Default)]
struct Link {
    parent: String,
    /// It was started with `--report-to`: a person's prompt keeps the link.
    asked: bool,
    /// The last report's content, to leave out the same report again.
    last: Option<String>,
    /// Pull requests a report already named.
    prs: Vec<String>,
    /// When the reports of the last [`WINDOW_MS`] went.
    sent: Vec<u64>,
    /// The newest report not delivered yet, made when its turn ended.
    ready: Option<Report>,
    /// A timer will send `ready`, held at the cap, when the window frees a place.
    wake: bool,
}

/// The links by lane id.
#[derive(Default)]
pub(crate) struct LaneReports {
    links: StdMutex<BTreeMap<String, Link>>,
    /// Lanes with a delivery on its way, and whether a turn ended meanwhile.
    inflight: StdMutex<HashMap<String, bool>>,
    /// What each running turn took in, by session and turn.
    turns: StdMutex<TurnKinds>,
}

/// Which turns ran on lane reports only: a turn that started on reports, with no other prompt
/// steered in while it ran. A steer is aimed at a turn but goes into whichever one the agent runs
/// when it reads it, so steers are counted by session: one on its way when a turn ends makes that
/// turn report, and one answered as gone in makes every turn up to the last started that has not
/// ended yet report.
#[derive(Default)]
struct TurnKinds {
    /// Turns that started on reports only.
    report_only: std::collections::HashSet<(String, u64)>,
    /// Other prompts steered in and not answered yet, by session.
    in_flight: HashMap<String, usize>,
    /// The last turn started when another prompt was answered as gone in, by session: every
    /// turn up to it had one.
    carried: HashMap<String, u64>,
}

impl TurnKinds {
    fn steer_in(&mut self, id: &str) {
        *self.in_flight.entry(id.to_owned()).or_default() += 1;
    }

    /// A steer [`TurnKinds::steer_in`] counted was answered with `last` the last turn started:
    /// `entered`, it went into a turn up to that one. A session forgotten meanwhile keeps nothing.
    fn steer_done(&mut self, id: &str, entered: bool, last: u64) {
        let Some(n) = self.in_flight.get_mut(id) else { return };
        *n -= 1;
        if *n == 0 {
            self.in_flight.remove(id);
        }
        if entered {
            let t = self.carried.entry(id.to_owned()).or_default();
            *t = (*t).max(last);
        }
    }

    /// Turn `turn` of `id` ended: whether it ran on reports only. Forgets it.
    fn end(&mut self, id: &str, turn: u64) -> bool {
        // Kept, not taken: turns' ends may run out of order, and a later turn is never under it.
        let carried =
            self.carried.get(id).is_some_and(|&t| t >= turn) || self.in_flight.contains_key(id);
        self.report_only.remove(&(id.to_owned(), turn)) && !carried
    }

    fn forget(&mut self, id: &str) {
        self.report_only.retain(|(s, _)| s != id);
        self.in_flight.remove(id);
        self.carried.remove(id);
    }
}

/// One steer [`TurnKinds::steer_in`] counted, until its answer: [`SteerCount::done`] takes it
/// back. Dropped first (its request was dropped), it may be with the agent still, to be read in
/// the turn running or the next, so it counts as gone into both. `last` reads the last turn
/// started.
pub(super) struct SteerCount<'a, F: Fn() -> u64> {
    turns: &'a StdMutex<TurnKinds>,
    id: String,
    last: F,
    entered: Option<bool>,
}

impl<'a, F: Fn() -> u64> SteerCount<'a, F> {
    fn new(turns: &'a StdMutex<TurnKinds>, id: &str, last: F) -> Self {
        turns.lock().unwrap_or_else(|e| e.into_inner()).steer_in(id);
        Self { turns, id: id.to_owned(), last, entered: None }
    }

    /// The steer was answered: `entered`, it went into a turn, which reports.
    pub(super) fn done(mut self, entered: bool) {
        self.entered = Some(entered);
    }
}

impl<F: Fn() -> u64> Drop for SteerCount<'_, F> {
    fn drop(&mut self) {
        let last = (self.last)();
        let (entered, last) = match self.entered {
            Some(entered) => (entered, last),
            None => (true, last + 1),
        };
        self.turns.lock().unwrap_or_else(|e| e.into_inner()).steer_done(&self.id, entered, last);
    }
}

/// One report, before it is written out.
#[derive(Debug, Clone, PartialEq)]
struct Report {
    /// Its state and whole reply; with its pull requests, what makes two reports the same
    /// ([`Report::key`]).
    content: String,
    /// The same for every try of this report.
    prompt_id: String,
    name: String,
    session: String,
    turn: u64,
    state: String,
    reply: String,
    prs: Vec<String>,
    shas: Vec<String>,
}

impl Report {
    /// What makes two reports the same: the state, the reply and every pull request it names.
    fn key(&self) -> String {
        format!("{}\n{}", self.content, self.prs.join(" "))
    }

    fn text(&self) -> String {
        let mut t = format!(
            "[{}] {} · turn {}, {}\n{}",
            self.name,
            super::lane_report_text::headline(&self.reply),
            self.turn,
            self.state,
            super::lane_report_text::excerpt(&self.reply),
        );
        if !self.prs.is_empty() {
            t.push_str(&format!("\nPull requests: {}", self.prs.join(" ")));
        }
        t
    }
}

/// Whether a turn's provenance is lane reports only: a report, or a turn of agent messages that
/// took in nothing else.
pub(super) fn reports_only(provenance: Option<&Value>) -> bool {
    let Some(p) = provenance else { return false };
    match p.get("kind").and_then(Value::as_str) {
        Some(KIND) => true,
        Some(super::digest::DIGEST_KIND) => p["messages"].as_array().is_some_and(|m| {
            !m.is_empty() && m.iter().all(|m| m.pointer("/provenance/kind") == Some(&json!(KIND)))
        }),
        _ => false,
    }
}

/// STATE of a report, from the lane's summary.
fn state(summary: &Value) -> String {
    let s = |k: &str| summary.get(k).and_then(Value::as_str).unwrap_or_default();
    if summary.get("turn").is_some_and(|t| !t.is_null()) || s("status") == "running" {
        return "working on its next prompt".into();
    }
    match summary.get("waitingOn").and_then(Value::as_str) {
        Some("question") => {
            let ask = s("waitingPrompt");
            return if ask.is_empty() {
                "waiting on a question".into()
            } else {
                format!("waiting on a question: {ask}")
            };
        }
        Some(_) => return "waiting on a permission".into(),
        None => {}
    }
    if summary.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0 {
        return "waiting on a permission".into();
    }
    let last = summary.get("lastTurn").unwrap_or(&Value::Null);
    if last.get("status").and_then(Value::as_str) == Some("failed") {
        let error = last.get("errorText").and_then(Value::as_str).unwrap_or("the turn failed");
        let paused = if summary["queuePaused"] == true { "; its queue is paused" } else { "" };
        return format!("blocked: {}{paused}", short_text(error, 160));
    }
    if summary["queuePaused"] == true {
        return "blocked: its queue is paused".into();
    }
    match s("status") {
        "disconnected" => "blocked: its agent stopped".into(),
        "closed" => "closed".into(),
        // Between two turns, its next prompt already queued.
        _ if summary["queued"].as_u64().unwrap_or(0) > 0 => "working on its next prompt".into(),
        _ => "idle".into(),
    }
}

/// The last agent message among transcript events, oldest first.
fn last_reply(events: &[Value]) -> Option<String> {
    let mut t = crate::transcript::Transcript::default();
    for e in events {
        t.apply_event(e);
    }
    t.items.iter().rev().find_map(|i| match i {
        crate::transcript::Item::Assistant { text } if !text.trim().is_empty() => {
            Some(text.trim().to_owned())
        }
        _ => None,
    })
}

/// A report's reply from its transcript read.
fn reply_of(read: Result<Option<String>>) -> String {
    match read {
        Ok(reply) => reply.unwrap_or_default(),
        Err(e) => format!("(its transcript did not read: {e})"),
    }
}

/// `found` without what `seen` has, each once, in order.
fn new_items(found: impl IntoIterator<Item = String>, seen: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for f in found {
        if !seen.contains(&f) && !out.contains(&f) {
            out.push(f);
        }
    }
    out
}

impl Hub {
    /// The authenticated starter a lane reports to, independent of mutable display tags.
    pub(crate) fn lane_report_parent(&self, lane: &str) -> Option<String> {
        self.lane_links(|links| links.get(lane).map(|link| link.parent.clone()))
    }

    fn lane_links<R>(&self, f: impl FnOnce(&mut BTreeMap<String, Link>) -> R) -> R {
        f(&mut self.lane_reports.links.lock().unwrap_or_else(|e| e.into_inner()))
    }

    fn lane_inflight(&self) -> std::sync::MutexGuard<'_, HashMap<String, bool>> {
        self.lane_reports.inflight.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn lane_turns(&self) -> std::sync::MutexGuard<'_, TurnKinds> {
        self.lane_reports.turns.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Takes `lane`'s one delivery; when another has it, that one goes again once done.
    fn lane_claim(&self, lane: &str) -> bool {
        let mut inflight = self.lane_inflight();
        match inflight.get_mut(lane) {
            Some(again) => {
                *again = true;
                false
            }
            None => {
                inflight.insert(lane.to_owned(), false);
                true
            }
        }
    }

    /// Gives `lane`'s delivery back: whether a turn ended meanwhile.
    fn lane_release(&self, lane: &str) -> bool {
        self.lane_inflight().remove(lane).unwrap_or(false)
    }

    /// Whether `ancestor` is `id`'s parent, or its parent's, up the links.
    fn lane_below(&self, id: &str, ancestor: &str) -> bool {
        let mut at = id.to_owned();
        for _ in 0..MAX_DEPTH {
            let Some(parent) = self.lane_links(|links| links.get(&at).map(|l| l.parent.clone()))
            else {
                return false;
            };
            if parent == ancestor {
                return true;
            }
            at = parent;
        }
        tracing::warn!(
            id,
            ancestor,
            "lane link refused: its parents are more than {MAX_DEPTH} deep"
        );
        true
    }

    /// From now on `parent` hears the end of each of `child`'s turns (both exact ids): tags the
    /// child and keeps the link. Turns done now are not reported. `asked`: it was started with
    /// `--report-to`, so a person's prompt does not end the link.
    pub(crate) fn lane_link(&self, parent: &str, child: &str, asked: bool) {
        // A session never becomes the child of itself or of its own descendant.
        if parent == child || self.lane_below(parent, child) {
            return;
        }
        let Some(s) = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(child).cloned()
        else {
            return;
        };
        // A close sets the status before `lane_retire` takes this lock: read under it, a parent
        // or child that closed meanwhile is never linked, and one that closes after has its link
        // retired.
        let linked = self.lane_links(|links| {
            if !self.lane_open(parent) || !self.lane_open(child) {
                return false;
            }
            let link = Link { parent: parent.to_owned(), asked, ..Link::default() };
            links.insert(child.to_owned(), link);
            true
        });
        if !linked {
            return;
        }
        let set = serde_json::Map::from_iter([(TAG.to_owned(), json!(parent))]);
        self.set_tags(&s, Some(&set), &[], None);
    }

    /// Ends `lane`'s link, if it has one: no report of it is queued or sent from now on. Its tag
    /// is left to the caller. Whether it had one.
    fn lane_unlink(&self, lane: &str) -> bool {
        let had = self.lane_links(|links| links.remove(lane).is_some());
        if had {
            self.lane_report_unlinked(lane);
        }
        had
    }

    /// Ends `session`'s link and removes its tag (`acpmux session detach`): whether it had a
    /// link.
    pub(crate) fn lane_detach(&self, session: &Session) -> Result<bool, RpcError> {
        let had = self.lane_unlink(&session.id);
        if session.meta().tags.contains_key(TAG) {
            self.set_tags_answered(session, None, &[TAG.to_owned()], None)?;
        }
        Ok(had)
    }

    /// The person prompted `session` directly: a lane that did not ask to report (`--report-to`)
    /// is theirs now and reports to its parent no more.
    pub(crate) fn lane_person_prompted(&self, session: &Session) {
        let asked = self.lane_links(|links| links.get(&session.id).map(|l| l.asked));
        if asked == Some(false) {
            let _ = self.lane_detach(session);
        }
    }

    /// `session`'s tags changed: a removed tag, or one that no longer names its parent, ends its
    /// link. The tag is shown, never trusted, so setting it never makes a link.
    pub(super) fn lane_tags_changed(&self, session: &Session) {
        let Some(parent) = self.lane_report_parent(&session.id) else { return };
        let tagged = session.meta().tags.get(TAG).map(|t| t.value.clone());
        if tagged.as_deref() != Some(parent.as_str()) {
            self.lane_unlink(&session.id);
        }
    }

    /// `session`'s turn started (its turn count counts it), with `provenance` for the whole turn
    /// (`digest.rs`).
    pub(super) fn lane_turn_started(&self, session: &Session, provenance: Option<&Value>) {
        self.lane_turn_on(session, reports_only(provenance));
    }

    /// `session`'s turn started (its turn count counts it); `reports`: on lane reports only (a
    /// carried turn's steers, `carried_turn.rs`).
    pub(super) fn lane_turn_on(&self, session: &Session, reports: bool) {
        if reports {
            let turn = session.meta().turn_count;
            self.lane_turns().report_only.insert((session.id.clone(), turn));
        }
    }

    /// Whether turn `turn` of session `id` is counted as one on lane reports only.
    #[cfg(test)]
    pub(super) fn lane_turn_reports_only(&self, id: &str, turn: u64) -> bool {
        self.lane_turns().report_only.contains(&(id.to_owned(), turn))
    }

    /// A prompt that is not a lane report is about to be steered into `session`: counted before
    /// it reaches the agent, so any turn that ends while it is on its way reports.
    pub(super) fn lane_steer_in<'a>(
        &'a self,
        session: &'a Session,
        provenance: Option<&Value>,
    ) -> Option<SteerCount<'a, impl Fn() -> u64 + 'a>> {
        let last = move || session.meta().turn_count;
        (!reports_only(provenance))
            .then(|| SteerCount::new(&self.lane_reports.turns, &session.id, last))
    }

    /// A local session's turn ended, or failed before its agent started (`turns.rs`): a lane's
    /// report of it is made now, from this turn's own records and state, and queued; delivery
    /// and its retries send that report and never read the lane again.
    /// `turn` is its own number, read before its end let the next turn start.
    pub(super) fn lane_turn_ended(
        self: &Arc<Self>,
        session: &Arc<Session>,
        started: bool,
        turn: u64,
    ) {
        // One that failed to start left the lane stuck, so it reports whatever it took in.
        let on_reports = self.lane_turns().end(&session.id, turn) && started;
        if !self.lane_links(|links| links.contains_key(&session.id)) {
            return;
        }
        self.lane_report_ended(&session.id, turn);
        // A turn on reports only makes none, and leaves one still queued to go now.
        if !on_reports {
            let report = self.lane_capture(session, turn, started);
            self.lane_links(|links| {
                if let Some(l) = links.get_mut(&session.id) {
                    l.ready = Some(replace_ready(report, l.ready.take()));
                }
            });
        }
        self.lane_send(&session.id);
    }

    /// Sends `lane`'s queued report, one delivery at a time; a turn that ended meanwhile sends
    /// after it.
    fn lane_send(self: &Arc<Self>, lane: &str) {
        if !self.lane_claim(lane) {
            return;
        }
        let (hub, lane) = (self.clone(), lane.to_owned());
        tokio::spawn(async move {
            hub.lane_deliver_ready(&lane).await;
            if hub.lane_release(&lane) {
                hub.lane_send(&lane);
            }
        });
    }

    /// Delivers `lane`'s queued report. One the same as the last is dropped; past the cap it is
    /// held (a newer turn's replaces it) and goes when the window frees a place; one the parent
    /// refused stays queued and goes at the next turn end.
    async fn lane_deliver_ready(self: &Arc<Self>, lane: &str) {
        let now = now_ms();
        let Some(due) = self.lane_take_due(lane, now) else {
            self.lane_wake_held(lane, now);
            return;
        };
        self.lane_hand_over(lane, due).await;
    }

    /// A report held at the cap goes when the window frees a place, though the lane may end no
    /// other turn. One timer a lane; it stops after its one send (a retired link sends nothing).
    fn lane_wake_held(self: &Arc<Self>, lane: &str, now: u64) {
        let wait = self.lane_links(|links| {
            let l = links.get_mut(lane).filter(|l| !l.wake)?;
            let wait = held_for(l, now)?;
            l.wake = true;
            Some(wait)
        });
        let Some(wait) = wait else { return };
        let (hub, lane) = (self.clone(), lane.to_owned());
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(wait)).await;
            hub.lane_links(|links| links.get_mut(&lane).map(|l| l.wake = false));
            hub.lane_send(&lane);
        });
    }

    /// `lane`'s parent and the report due to it now, with its key ([`due_report`]).
    fn lane_take_due(&self, lane: &str, now: u64) -> Option<(String, Report, String)> {
        self.lane_links(|links| {
            let l = links.get_mut(lane)?;
            let (report, key) = due_report(l, now)?;
            Some((l.parent.clone(), report, key))
        })
    }

    /// Hands the report [`Hub::lane_take_due`] took to the parent, and records it once taken.
    async fn lane_hand_over(
        self: &Arc<Self>,
        lane: &str,
        (parent, report, key): (String, Report, String),
    ) {
        if let Err(e) = self.lane_deliver(&parent, lane, &report).await {
            tracing::warn!(lane, %parent, "lane report not delivered: {}", e.message);
            return;
        }
        self.lane_report_reconcile_read(&parent, lane, report.turn);
        // Counted from when the parent took it, not when it was taken: its admission may wait.
        let took = now_ms();
        self.lane_links(|links| {
            let Some(l) = links.get_mut(lane).filter(|l| l.parent == parent) else { return };
            delivered(l, &report, key, took);
        });
    }

    /// The report of turn `turn` of `session`, which just ended.
    /// `started`: its agent ran it. A turn that failed before its agent started has no reply
    /// of its own, so none is read (the last one is the turn before's).
    fn lane_capture(&self, session: &Session, turn: u64, started: bool) -> Report {
        let summary = self.session_summary(session);
        let read = if started { self.lane_last_reply(&session.id, &summary) } else { Ok(None) };
        if let Err(e) = &read {
            tracing::warn!(lane = %session.id, "lane report: its transcript did not read: {e}");
        }
        let reply = reply_of(read);
        let opened = summary
            .get("pullRequests")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_owned);
        let prs = new_items(opened.chain(matches(&PULL_URL, &reply)), &[]);
        let shas = new_items(matches(&FULL_SHA, &reply), &[]);
        let name = summary.get("name").and_then(Value::as_str).unwrap_or(&session.id);
        let state = state(&summary);
        Report {
            content: format!("{state}\n{reply}"),
            prompt_id: format!("{PROMPT_PREFIX}{}", uuid::Uuid::new_v4()),
            name: name.to_owned(),
            session: session.id.clone(),
            turn,
            state,
            reply: if reply.is_empty() { "(no reply)".into() } else { reply },
            prs,
            shas,
        }
    }

    /// The lane's last reply, read from its last turn's transcript records; an error when they
    /// cannot be read.
    fn lane_last_reply(&self, lane: &str, summary: &Value) -> Result<Option<String>> {
        let last_seq = summary.get("lastSeq").and_then(Value::as_u64).unwrap_or(0);
        let filter = EventFilter::parse(Some(&json!(["transcript"])))
            .map_err(|e| anyhow::anyhow!("transcript filter: {e:?}"))?;
        let (records, whole) = last_turn_records(last_seq, |before| {
            self.events_page(lane, 0, Some(before), TAIL_RECORDS, None, true, &filter)
        })?;
        let events: Vec<Value> = records
            .into_iter()
            .map(|r| json!({"seq": r.seq, "at": r.at, "dir": r.dir, "kind": r.kind, "msg": r.msg}))
            .collect();
        Ok(last_reply(&events).map(|r| cut_reply(r, whole)))
    }

    /// Whether session `id` is here and not closed.
    fn lane_open(&self, id: &str) -> bool {
        let s = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
        s.is_some_and(|s| s.status() != SessionStatus::Closed)
    }

    /// `id` was closed or purged: a link it is either end of is retired, so a lane no longer
    /// reports to a closed parent and nothing of a closed lane stays here.
    pub(super) fn lane_retire(&self, id: &str) {
        self.lane_links(|links| links.retain(|lane, l| lane != id && l.parent != id));
        self.lane_turns().forget(id);
        self.lane_report_forget(id);
    }

    /// Hands the report to the parent: accepted (queued, started, steered or held for the
    /// person).
    async fn lane_deliver(
        self: &Arc<Self>,
        parent: &str,
        lane: &str,
        report: &Report,
    ) -> Result<(), RpcError> {
        let prompt_id = report.prompt_id.clone();
        let blocks = vec![json!({"type": "text", "text": report.text()})];
        let local = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(parent).cloned();
        let Some(p) = local else {
            // The parent is gone: nobody to report to.
            self.lane_links(|links| {
                links.remove(lane);
            });
            return Ok(());
        };
        let provenance = json!({
            "kind": KIND, "from": lane, "fromName": report.name, "to": parent,
            "turn": report.turn, "state": report.state,
            "details": {"session": report.session, "commits": report.shas},
        });
        // The lane's id and harness, for the parent's queue list (`prompt_provenance.rs`).
        let lane_session =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(lane).cloned();
        let sender = lane_session
            .map(|l| crate::prompt_provenance::BoundSender::of_session(&l.id, &l.meta()));
        let provenance = crate::prompt_provenance::stamp_sender(provenance, sender.as_ref());
        let (tx, rx) = oneshot::channel();
        let opts = PromptOptions {
            prompt_id: Some(prompt_id),
            resend: true,
            provenance: Some(provenance.clone()),
            agent: Some(report.name.clone()),
            // A lane's report says what its turn did (`prompt_class.rs`).
            class: Some(crate::prompt_class::PromptClass::Result),
            on_accepted: Some(Box::new(move |v| {
                let _ = tx.send(v);
            })),
            ..PromptOptions::default()
        };
        // A lane that closed (or a parent that changed) since its report was taken has its link
        // retired, and sends nothing. A parent's close that begins after this is refused at its
        // queue (`queue.rs`, by the report's provenance kind). A lane closing after this check still sends this one report,
        // of a turn that ended before its close.
        if !self.lane_links(|links| links.get(lane).is_some_and(|l| l.parent == parent)) {
            return Ok(());
        }
        if self.lane_report_was_read(lane, report.turn) {
            if !super::queue::closing(&p) {
                self.lane_report_delivered_read(
                    &p,
                    lane,
                    &report.prompt_id,
                    &report.text(),
                    &provenance,
                );
            }
            return Ok(());
        }
        // The answer comes when the parent's turn ends; the report is in once it is accepted.
        let hub = self.clone();
        // Never steered in: a report waits for the parent's turn to end (see above).
        let run =
            tokio::spawn(async move { hub.prompt_with(&p, blocks, "acpmux", false, opts).await });
        if rx.await.is_ok() {
            return Ok(());
        }
        match run.await {
            Ok(Ok(_)) => Ok(()),
            // Held for the person to resume the pair: it goes in then.
            Ok(Err(e)) if e.data.as_ref().is_some_and(|d| d["held"] == true) => Ok(()),
            Ok(Err(e)) => Err(e),
            Err(e) => Err(RpcError::internal(e.to_string())),
        }
    }
}

/// The records of the last turn, from its `turn_started` on (or as far back as
/// [`MAX_TAIL_PAGES`] pages go), oldest first, and whether they are the whole turn (false: its
/// start lies further back); `page(before)` reads the newest page below seq `before`.
fn last_turn_records(
    last_seq: u64,
    mut page: impl FnMut(u64) -> Result<EventPage>,
) -> Result<(Vec<crate::store::EventRecord>, bool)> {
    let mut out = Vec::new();
    let mut before = last_seq.saturating_add(1);
    for _ in 0..MAX_TAIL_PAGES {
        let got = page(before)?;
        let start = got.events.iter().rposition(|r| r.kind == "turn_started");
        let more = got.has_more && start.is_none();
        let Some(first) = got.events.first().map(|r| r.seq) else { break };
        let mut events = got.events;
        events.drain(..start.unwrap_or(0));
        events.append(&mut out);
        out = events;
        if !more {
            return Ok((out, true));
        }
        before = first;
    }
    // Empty, or stopped at the page limit with more before it.
    let whole = out.is_empty();
    Ok((out, whole))
}

/// What a report's reply starts with when its turn's start lay past the pages read.
const CUT_NOTE: &str = "(its reply began before the records read; this is how it ends) ";

/// `reply`, marked as cut when it is not the whole turn's.
fn cut_reply(reply: String, whole: bool) -> String {
    if whole { reply } else { format!("{CUT_NOTE}{reply}") }
}

/// `l`'s queued report to deliver now, without the pull requests reported before, and its key
/// as queued (what `delivered` records as the last): none when it is the same as the last
/// (dropped) or past the cap (held).
fn due_report(l: &mut Link, now: u64) -> Option<(Report, String)> {
    l.sent.retain(|t| now.saturating_sub(*t) < WINDOW_MS);
    let ready = l.ready.as_ref()?;
    if l.last.as_deref() == Some(ready.key().as_str()) {
        l.ready = None;
        return None;
    }
    if l.sent.len() >= MAX_REPORTS {
        tracing::warn!(lane = %ready.session, "lane report held: {MAX_REPORTS} in the last 10 minutes");
        return None;
    }
    let mut report = ready.clone();
    report.prs = new_items(report.prs, &l.prs);
    Some((report, ready.key()))
}

/// How long `l`'s queued report waits for the cap to free a place: none when nothing is held.
fn held_for(l: &Link, now: u64) -> Option<u64> {
    l.ready.as_ref()?;
    if l.sent.len() < MAX_REPORTS {
        return None;
    }
    let oldest = l.sent.iter().min()?;
    Some((oldest + WINDOW_MS).saturating_sub(now).max(1))
}

/// Records on `l` that `report` (from `due_report`, queued with `key`) reached the parent at `now`.
/// The last is the queued key, so a repeat still naming a reported pull request is dropped.
fn delivered(l: &mut Link, report: &Report, key: String, now: u64) {
    if l.ready.as_ref().is_some_and(|r| r.prompt_id == report.prompt_id) {
        l.ready = None;
    }
    l.last = Some(key);
    l.prs.extend(report.prs.iter().cloned());
    l.sent.push(now);
}

/// A newer turn's report replaces one still queued, keeping the pull requests only that one
/// named.
fn replace_ready(mut newer: Report, queued: Option<Report>) -> Report {
    for pr in queued.into_iter().flat_map(|q| q.prs) {
        if !newer.prs.contains(&pr) {
            newer.prs.push(pr);
        }
    }
    newer
}

#[cfg(test)]
mod tests {
    fn report(turn: u64, prs: &[&str]) -> Report {
        Report {
            content: format!("turn {turn}"),
            prompt_id: format!("p{turn}"),
            name: "lane".into(),
            session: "s".into(),
            turn,
            state: "idle".into(),
            reply: "r".into(),
            prs: prs.iter().map(|p| (*p).to_owned()).collect(),
            shas: vec![],
        }
    }

    #[test]
    fn a_held_reports_pull_request_goes_with_a_newer_report_the_same_as_the_last() {
        let (now, x) = (WINDOW_MS * 2, "https://github.com/o/r/pull/1");
        // Turn 2's report went; turn 3's, naming X, is held at the cap.
        let mut l = Link { last: Some(report(2, &[]).key()), ..Link::default() };
        l.sent = vec![now; MAX_REPORTS];
        l.ready = Some(report(3, &[x]));
        assert_eq!(due_report(&mut l, now), None);
        // Past the window, turn 4 repeats turn 2's report without X: X still goes.
        let later = now + WINDOW_MS;
        let mut same = report(4, &[]);
        same.content = report(2, &[]).content;
        l.ready = Some(replace_ready(same, l.ready.take()));
        let (got, _) = due_report(&mut l, later).unwrap();
        assert_eq!((got.turn, got.prs), (4, vec![x.to_owned()]));
        // The very same report is dropped.
        let mut l = Link { last: Some(report(2, &[]).key()), ..Link::default() };
        l.ready = Some(report(2, &[]));
        assert_eq!(due_report(&mut l, now), None);
        assert!(l.ready.is_none());
    }

    #[test]
    fn a_repeated_report_naming_a_reported_pull_request_is_dropped() {
        let (now, x) = (WINDOW_MS * 2, "https://github.com/o/r/pull/1");
        let mut l = Link::default();
        // Turn 2 names X; turn 3 says something new and still names X: both go.
        for turn in [2, 3] {
            l.ready = Some(report(turn, &[x]));
            let (got, key) = due_report(&mut l, now).unwrap();
            delivered(&mut l, &got, key, now);
        }
        // Turn 4 repeats turn 3 word for word: nothing new, so nothing goes.
        let mut same = report(4, &[x]);
        same.content = report(3, &[x]).content;
        l.ready = Some(same);
        assert_eq!(due_report(&mut l, now + 1), None);
        assert_eq!(l.sent.len(), 2);
    }

    #[test]
    fn a_newer_report_replaces_a_queued_one_and_keeps_its_pull_requests() {
        let got = replace_ready(report(2, &["pr/2"]), Some(report(1, &["pr/1", "pr/2"])));
        assert_eq!((got.turn, got.prs), (2, vec!["pr/2".to_owned(), "pr/1".to_owned()]));
        assert_eq!(replace_ready(report(1, &[]), None), report(1, &[]));
    }

    #[test]
    fn each_turn_on_reports_only_is_known_on_its_own() {
        let mut k = TurnKinds::default();
        // Two report turns back to back: the second never hides the first.
        k.report_only.insert(("c".into(), 1));
        k.report_only.insert(("c".into(), 2));
        assert!(k.end("c", 1));
        assert!(k.end("c", 2));
        // A task steered in before the turn ends: counted before the end, whenever its own
        // answer comes, so the turn reports.
        k.report_only.insert(("c".into(), 3));
        k.steer_in("c");
        assert!(!k.end("c", 3));
        k.steer_done("c", true, 3);
        assert!(k.in_flight.is_empty());
        // (answered once turn 3, which reported for it, ended: turn 4 does not)
        k.report_only.insert(("c".into(), 4));
        assert!(k.end("c", 4));
        // A steer withdrawn (or that found no turn) is taken back: still reports only.
        k.report_only.insert(("c".into(), 5));
        k.steer_in("c");
        k.steer_done("c", false, 5);
        assert!(k.end("c", 5));
        // A turn not on reports.
        assert!(!k.end("c", 6));
        k.steer_in("c");
        k.forget("c");
        assert!(k.in_flight.is_empty() && k.carried.is_empty() && k.report_only.is_empty());
    }

    #[test]
    fn a_steer_dropped_before_its_answer_is_not_counted_forever() {
        let turns = StdMutex::new(TurnKinds::default());
        // The steer's request is dropped (its client went away) before the agent answers, in
        // turn 1. It may already be with the agent, to be read in turn 1 or the next: both
        // report, and no later one.
        let count = SteerCount::new(&turns, "c", || 1);
        for turn in [1, 2, 3] {
            turns.lock().unwrap().report_only.insert(("c".into(), turn));
        }
        drop(count);
        let mut k = turns.lock().unwrap();
        assert!(k.in_flight.is_empty(), "a dropped steer stays on its way");
        assert!(!k.end("c", 1));
        assert!(!k.end("c", 2), "the next turn, which may have read it, did not report");
        assert!(k.end("c", 3), "every later report turn reports");
        drop(k);
        // Answered, it counts as the answer says.
        SteerCount::new(&turns, "c", || 4).done(false);
        let mut k = turns.lock().unwrap();
        k.report_only.insert(("c".into(), 4));
        assert!(k.end("c", 4));
    }

    #[test]
    fn a_turn_whose_end_runs_after_the_next_turn_ended_keeps_its_steer() {
        let mut k = TurnKinds::default();
        // A task is steered into report turn 1; turn 1's end is held up behind the next turn,
        // which ends first.
        k.report_only.insert(("c".into(), 1));
        k.report_only.insert(("c".into(), 2));
        k.steer_in("c");
        k.steer_done("c", true, 1);
        assert!(k.end("c", 2));
        assert!(!k.end("c", 1), "turn 1's task was lost when turn 2 ended first");
    }

    #[test]
    fn a_steer_answered_after_its_session_was_forgotten_leaves_nothing() {
        let turns = StdMutex::new(TurnKinds::default());
        let answered = SteerCount::new(&turns, "c", || 1);
        let dropped = SteerCount::new(&turns, "c", || 1);
        turns.lock().unwrap().forget("c");
        answered.done(true);
        drop(dropped);
        let k = turns.lock().unwrap();
        assert!(k.in_flight.is_empty() && k.carried.is_empty(), "a retired lane left state");
    }

    #[test]
    fn a_steer_counted_before_a_report_turn_started_still_makes_it_report() {
        let mut k = TurnKinds::default();
        // A task's steer is counted while turn 1 is the count, then the agent takes it into turn
        // 2, a report turn that started meanwhile: turn 2 did a task, so it reports.
        k.steer_in("c");
        k.report_only.insert(("c".into(), 2));
        assert!(!k.end("c", 2), "the task's turn was taken for reports only");
        // Answered after that turn ended, with none running since: the turn it went into
        // already reported, so the next one does not.
        k.steer_done("c", true, 2);
        k.report_only.insert(("c".into(), 3));
        assert!(k.end("c", 3));
    }

    #[test]
    fn a_late_steer_answer_does_not_make_a_later_report_turn_report() {
        let mut k = TurnKinds::default();
        k.steer_in("c");
        // Two report turns end while the steer is on its way: both report, one had it.
        for turn in [1, 2] {
            k.report_only.insert(("c".into(), turn));
            assert!(!k.end("c", turn));
        }
        // Its answer comes after, with turn 2 the last to start: no later report turn is put
        // down to it.
        k.steer_done("c", true, 2);
        k.report_only.insert(("c".into(), 3));
        assert!(k.end("c", 3), "a later report turn reported for a steer it never had");
        // Answered while turn 4 runs, it went into turn 4: that one reports.
        k.steer_in("c");
        k.steer_done("c", true, 4);
        k.report_only.insert(("c".into(), 4));
        assert!(!k.end("c", 4));
    }

    #[test]
    fn a_steer_taken_by_the_next_report_turn_makes_that_turn_report() {
        let mut k = TurnKinds::default();
        // Sent in report turn 1, which ends before the agent reads it (that turn reports, as
        // it may have had it); report turn 2 starts and takes it, answered while it runs.
        k.steer_in("c");
        k.report_only.insert(("c".into(), 1));
        assert!(!k.end("c", 1));
        k.report_only.insert(("c".into(), 2));
        k.steer_done("c", true, 2);
        assert!(!k.end("c", 2), "the turn that did the task was taken for reports only");
        // Answered with turn 2 just started and turn 1 not yet ended: both report.
        k.steer_in("c");
        k.report_only.insert(("c".into(), 3));
        k.report_only.insert(("c".into(), 4));
        k.steer_done("c", true, 4);
        assert!(!k.end("c", 3));
        assert!(!k.end("c", 4));
        k.report_only.insert(("c".into(), 5));
        assert!(k.end("c", 5));
    }

    #[tokio::test]
    async fn a_turn_ending_after_the_next_one_started_ends_its_own_turn() {
        let hub = test_hub();
        let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let lane = hub.new_session(start()).await.unwrap();
        let report = json!({"kind": KIND, "from": "s1"});
        for turn in [1, 2] {
            lane.meta.lock().unwrap().turn_count = turn;
            hub.lane_turn_started(&lane, Some(&report));
        }
        // Report turn 1's end runs after report turn 2 started (its queue woke turn 2 first).
        hub.lane_turn_ended(&lane, true, 1);
        assert!(
            hub.lane_turns().report_only.contains(&(lane.id.clone(), 2)),
            "turn 1's end took turn 2's mark: turn 2 will report"
        );
        hub.lane_turn_ended(&lane, true, 2);
        assert!(hub.lane_turns().report_only.is_empty());
        hub.kill(&lane, true).await.unwrap();
    }

    #[tokio::test]
    async fn a_report_turn_that_failed_to_start_still_reports() {
        let hub = test_hub();
        let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let parent = hub.new_session(start()).await.unwrap();
        let lane = hub.new_session(start()).await.unwrap();
        hub.lane_link(&parent.id, &lane.id, false);
        // A worker's report starts the lane's turn 1, whose agent then fails to start: the lane
        // is stuck, and its parent must hear it.
        lane.meta.lock().unwrap().turn_count = 1;
        hub.lane_turn_started(&lane, Some(&json!({"kind": KIND, "from": "s1"})));
        hub.lane_turn_ended(&lane, false, 1);
        for _ in 0..150 {
            if parent.meta().turn_count > 0 {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert_eq!(parent.meta().turn_count, 1, "the failed start never reached the parent");
        for s in [&lane, &parent] {
            hub.kill(s, true).await.unwrap();
        }
    }

    #[test]
    fn the_last_reply_is_read_from_the_start_of_its_turn_however_many_records_it_streamed() {
        let rec = |seq: u64, kind: &str| crate::store::EventRecord {
            seq,
            at: 0,
            dir: "in".into(),
            kind: kind.into(),
            msg: json!({}),
            host_seq: None,
        };
        // An older turn, then the last turn's start at 10 and 1,000 chunks after it.
        let log: Vec<_> = (1..=1010)
            .map(|s| rec(s, if s == 3 || s == 10 { "turn_started" } else { "chunk" }))
            .collect();
        let page = |before: u64| -> Result<EventPage> {
            let below: Vec<_> = log.iter().filter(|r| r.seq < before).cloned().collect();
            let from = below.len().saturating_sub(TAIL_RECORDS);
            Ok(EventPage { has_more: from > 0, events: below[from..].to_vec() })
        };
        let (got, whole) = last_turn_records(1010, page).unwrap();
        assert!(whole);
        assert_eq!(got.first().map(|r| r.seq), Some(10));
        assert_eq!(got.len(), 1001);
        assert!(got.windows(2).all(|w| w[0].seq + 1 == w[1].seq));
    }

    #[test]
    fn a_turn_longer_than_the_pages_read_says_its_reply_is_cut() {
        let rec = |seq: u64, kind: &str| crate::store::EventRecord {
            seq,
            at: 0,
            dir: "in".into(),
            kind: kind.into(),
            msg: json!({}),
            host_seq: None,
        };
        // The turn's start lies further back than every page read.
        let n = (TAIL_RECORDS * MAX_TAIL_PAGES) as u64 + 100;
        let log: Vec<_> =
            (1..=n).map(|s| rec(s, if s == 1 { "turn_started" } else { "chunk" })).collect();
        let page = |before: u64| -> Result<EventPage> {
            let below: Vec<_> = log.iter().filter(|r| r.seq < before).cloned().collect();
            let from = below.len().saturating_sub(TAIL_RECORDS);
            Ok(EventPage { has_more: from > 0, events: below[from..].to_vec() })
        };
        let (got, whole) = last_turn_records(n, page).unwrap();
        assert!(!whole, "a scan that stopped short of turn_started reads as the whole turn");
        assert_eq!(got.len(), TAIL_RECORDS * MAX_TAIL_PAGES);
        assert_eq!(cut_reply("its end".into(), whole), format!("{CUT_NOTE}its end"));
        assert_eq!(cut_reply("all of it".into(), true), "all of it");
    }

    #[test]
    fn a_turn_with_no_reply_never_reads_the_turn_befores_through_the_transcript_filter() {
        let mux = |seq: u64, kind: &str| crate::store::EventRecord {
            seq,
            at: 0,
            dir: "mux".into(),
            kind: kind.into(),
            msg: json!({}),
            host_seq: None,
        };
        let reply = |seq: u64, text: &str| crate::store::EventRecord {
            seq,
            at: 0,
            dir: "in".into(),
            kind: "agent_message_chunk".into(),
            msg: json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a",
                "update": {"sessionUpdate": "agent_message_chunk",
                           "content": {"type": "text", "text": text}}}}),
            host_seq: None,
        };
        // Turn 1 replies; turn 2 ends with no reply of its own.
        let log = [
            mux(1, "turn_started"),
            reply(2, "turn one's reply"),
            mux(3, "turn_result"),
            mux(4, "turn_started"),
            mux(5, "turn_result"),
        ];
        // What `lane_last_reply` reads: the transcript filter, newest pages first.
        let filter = EventFilter::parse(Some(&json!(["transcript"]))).unwrap();
        let read = |last_seq: u64| {
            let page = |before: u64| -> Result<EventPage> {
                let events: Vec<_> =
                    log.iter().filter(|r| r.seq < before && filter.matches(r)).cloned().collect();
                Ok(EventPage { has_more: false, events })
            };
            let (records, _) = last_turn_records(last_seq, page).unwrap();
            let events: Vec<Value> = records
                .into_iter()
                .map(|r| json!({"seq": r.seq, "dir": r.dir, "kind": r.kind, "msg": r.msg}))
                .collect();
            last_reply(&events)
        };
        assert_eq!(read(3).as_deref(), Some("turn one's reply"));
        assert_eq!(read(5), None);
    }

    fn test_hub() -> Arc<Hub> {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut cfg: crate::config::Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        Hub::new(cfg, store)
    }

    fn queued_report(lane: &str) -> Report {
        Report {
            content: "idle\nlast words".into(),
            prompt_id: format!("{PROMPT_PREFIX}test"),
            name: "lane".into(),
            session: lane.to_owned(),
            turn: 1,
            state: "idle".into(),
            reply: "last words".into(),
            prs: vec![],
            shas: vec![],
        }
    }

    #[test]
    fn a_transcript_that_does_not_read_says_so_instead_of_no_reply() {
        assert_eq!(reply_of(Ok(Some("done".into()))), "done");
        assert_eq!(reply_of(Ok(None)), "");
        let got = reply_of(Err(anyhow::anyhow!("page 3 failed")));
        assert!(got.contains("did not read") && got.contains("page 3 failed"), "{got}");
    }

    #[tokio::test]
    async fn a_report_held_at_the_cap_goes_when_the_window_frees_a_place() {
        let hub = test_hub();
        let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let parent = hub.new_session(start()).await.unwrap();
        let lane = hub.new_session(start()).await.unwrap();
        hub.lane_link(&parent.id, &lane.id, false);
        // The cap is full, its oldest report leaving the window in 300 ms; the lane never ends
        // another turn.
        let oldest = now_ms() - WINDOW_MS + 300;
        hub.lane_links(|l| {
            let l = l.get_mut(&lane.id).unwrap();
            l.sent = vec![oldest; MAX_REPORTS];
            l.ready = Some(queued_report(&lane.id));
        });
        hub.lane_deliver_ready(&lane.id).await;
        assert_eq!(parent.meta().turn_count, 0, "the report went past the cap");
        for _ in 0..150 {
            if parent.meta().turn_count > 0 {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert_eq!(parent.meta().turn_count, 1, "the held report never went");
        for s in [&lane, &parent] {
            hub.kill(s, true).await.unwrap();
        }
    }

    #[tokio::test]
    async fn a_report_counts_toward_the_cap_from_when_the_parent_took_it() {
        let hub = test_hub();
        let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let parent = hub.new_session(start()).await.unwrap();
        let lane = hub.new_session(start()).await.unwrap();
        hub.lane_link(&parent.id, &lane.id, false);
        hub.lane_links(|l| l.get_mut(&lane.id).unwrap().ready = Some(queued_report(&lane.id)));
        // Taken a minute before the parent accepts it (its admission waited).
        let taken = now_ms() - 60_000;
        let due = hub.lane_take_due(&lane.id, taken).unwrap();
        let before = now_ms();
        hub.lane_hand_over(&lane.id, due).await;
        let sent = hub.lane_links(|l| l.get(&lane.id).map(|l| l.sent.clone())).unwrap();
        assert_eq!(sent.len(), 1);
        assert!(sent[0] >= before, "counted from when it was taken, not accepted: {sent:?}");
        for s in [&lane, &parent] {
            hub.kill(s, true).await.unwrap();
        }
    }

    #[tokio::test]
    async fn a_parent_that_starts_closing_after_the_link_check_takes_no_report() {
        let hub = test_hub();
        let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let parent = hub.new_session(start()).await.unwrap();
        let lane = hub.new_session(start()).await.unwrap();
        hub.lane_link(&parent.id, &lane.id, false);
        hub.lane_links(|l| l.get_mut(&lane.id).unwrap().ready = Some(queued_report(&lane.id)));
        let now = now_ms();
        let due = hub.lane_take_due(&lane.id, now).unwrap();
        // The parent's close has begun (`kill` marks it closing, then closes it) but has not
        // retired its links yet: the link check passes, the parent must still refuse it.
        parent.closing.store(true, Ordering::SeqCst);
        hub.set_status(&parent, SessionStatus::Closed);
        hub.lane_hand_over(&lane.id, due).await;
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert_eq!(parent.meta().turn_count, 0, "the closing parent took the report");
        assert_eq!(parent.status(), SessionStatus::Closed, "the report reopened the parent");
        for s in [&lane, &parent] {
            hub.kill(s, true).await.unwrap();
        }
    }

    #[tokio::test]
    async fn a_report_queued_behind_a_busy_parent_that_then_closes_never_runs() {
        let hub = test_hub();
        let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let parent = hub.new_session(start()).await.unwrap();
        let lane = hub.new_session(start()).await.unwrap();
        hub.lane_link(&parent.id, &lane.id, false);
        let (h, p) = (hub.clone(), parent.clone());
        let blocks = vec![json!({"type": "text", "text": "until-cancel"})];
        let busy = tokio::spawn(async move {
            h.prompt_with(&p, blocks, "test", false, PromptOptions::default()).await
        });
        for _ in 0..100 {
            if parent.turn().is_some() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert!(parent.turn().is_some(), "the parent's turn never started");
        // The report queues behind the parent's turn; then the parent closes.
        hub.lane_links(|l| l.get_mut(&lane.id).unwrap().ready = Some(queued_report(&lane.id)));
        let now = now_ms();
        let due = hub.lane_take_due(&lane.id, now).unwrap();
        hub.lane_hand_over(&lane.id, due).await;
        for _ in 0..100 {
            if parent.queued() > 0 {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert_eq!(parent.queued(), 1, "the report never queued behind the parent's turn");
        // A lane's report is a result (`prompt_class.rs`): it never wakes a coordinator by itself.
        let class = parent.queue().first().and_then(|q| q.run.class);
        assert_eq!(class, Some(crate::prompt_class::PromptClass::Result));
        let turns = parent.meta().turn_count;
        hub.kill(&parent, false).await.unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(5), busy).await;
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        assert_eq!(parent.meta().turn_count, turns, "the queued report ran after the close");
        assert!(parent.child.lock().await.is_none(), "the report started the parent's agent again");
        for s in [&lane, &parent] {
            hub.kill(s, true).await.unwrap();
        }
    }

    /// Quit Everything (`_acpmux/shutdown endAgents`) ends the parent with its lanes, and no
    /// agent may start once the shutdown has begun: a lane's turn it cancels reports nothing.
    #[tokio::test]
    async fn a_lane_turn_quit_everything_cancels_reports_nothing() {
        let hub = test_hub();
        let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let parent = hub.new_session(start()).await.unwrap();
        let lane = hub.new_session(start()).await.unwrap();
        hub.lane_link(&parent.id, &lane.id, false);
        let (h, l) = (hub.clone(), lane.clone());
        let blocks = vec![json!({"type": "text", "text": "until-cancel"})];
        let run = tokio::spawn(async move {
            h.prompt_with(&l, blocks, "test", false, PromptOptions::default()).await
        });
        for _ in 0..100 {
            if lane.turn().is_some() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert!(lane.turn().is_some(), "the lane's turn never started");
        hub.end_agents_at_shutdown(Default::default()).unwrap();
        hub.shutdown_all().await;
        let _ = tokio::time::timeout(std::time::Duration::from_secs(5), run).await;
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert_eq!(parent.meta().turn_count, 0, "a report went in during the shutdown");
        assert!(hub.lane_links(|l| l.get(&lane.id).is_none_or(|l| l.ready.is_none())));
    }

    #[tokio::test]
    async fn a_report_taken_for_a_lane_that_closes_before_it_goes_never_reaches_the_parent() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut cfg: crate::config::Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let parent = hub.new_session(start()).await.unwrap();
        let lane = hub.new_session(start()).await.unwrap();
        hub.lane_link(&parent.id, &lane.id, false);
        let queued = Report {
            content: "idle\nlast words".into(),
            prompt_id: format!("{PROMPT_PREFIX}test"),
            name: "lane".into(),
            session: lane.id.clone(),
            turn: 1,
            state: "idle".into(),
            reply: "last words".into(),
            prs: vec![],
            shas: vec![],
        };
        hub.lane_links(|l| l.get_mut(&lane.id).unwrap().ready = Some(queued));
        // The report is taken; the lane closes (its link retired) before it is handed over.
        let now = now_ms();
        let due = hub.lane_take_due(&lane.id, now).unwrap();
        hub.kill(&lane, true).await.unwrap();
        hub.lane_hand_over(&lane.id, due).await;
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert_eq!(parent.meta().turn_count, 0, "the closed lane's report went in");
        hub.kill(&parent, true).await.unwrap();
    }

    #[tokio::test]
    async fn a_parent_that_closed_while_its_lane_started_is_never_linked() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut cfg: crate::config::Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let parent = hub.new_session(start()).await.unwrap();
        let child = hub.new_session(start()).await.unwrap();
        // The parent closes after `session/new` read it and before the link goes in.
        hub.kill(&parent, false).await.unwrap();
        hub.lane_link(&parent.id, &child.id, false);
        assert!(!hub.lane_links(|l| l.contains_key(&child.id)));
        // A child that closed after `lane_link` read it and before the link went in is not
        // linked again: its close retired its links already.
        let closing = hub.new_session(start()).await.unwrap();
        let open_parent = hub.new_session(start()).await.unwrap();
        hub.kill(&closing, false).await.unwrap();
        hub.lane_link(&open_parent.id, &closing.id, false);
        assert!(!hub.lane_links(|l| l.contains_key(&closing.id)));
        hub.kill(&closing, true).await.unwrap();
        hub.kill(&open_parent, true).await.unwrap();
        // An open parent is linked.
        let open = hub.new_session(start()).await.unwrap();
        hub.lane_link(&open.id, &child.id, false);
        assert!(hub.lane_links(|l| l.get(&child.id).is_some_and(|l| l.parent == open.id)));
        // Its parent closing retires it; a child is never linked under its own descendant.
        hub.kill(&open, false).await.unwrap();
        assert!(!hub.lane_links(|l| l.contains_key(&child.id)));
        let grandchild = hub.new_session(start()).await.unwrap();
        hub.lane_link(&child.id, &grandchild.id, false);
        hub.lane_link(&grandchild.id, &child.id, false);
        assert!(!hub.lane_links(|l| l.contains_key(&child.id)));
        hub.kill(&grandchild, true).await.unwrap();
        for s in [&child, &open] {
            hub.kill(s, true).await.unwrap();
        }
        hub.kill(&parent, true).await.unwrap();
    }

    use super::*;

    #[test]
    fn a_turn_on_reports_only_is_known_by_its_provenance() {
        let report = json!({"kind": "lane_report", "from": "s1"});
        let task = json!({"kind": "session_message", "from": "s2"});
        assert!(reports_only(Some(&report)));
        assert!(!reports_only(Some(&task)));
        assert!(!reports_only(None));
        let digest = |kinds: &[&Value]| {
            let m: Vec<Value> = kinds.iter().map(|p| json!({"provenance": p})).collect();
            json!({"kind": "agent_digest", "messages": m})
        };
        assert!(reports_only(Some(&digest(&[&report, &report]))));
        assert!(!reports_only(Some(&digest(&[&report, &task]))));
    }

    #[test]
    fn the_state_names_what_the_lane_waits_on() {
        assert_eq!(state(&json!({"status": "ready"})), "idle");
        assert_eq!(state(&json!({"status": "running"})), "working on its next prompt");
        assert_eq!(
            state(
                &json!({"status": "waiting", "waitingOn": "question", "waitingPrompt": "Which base?"})
            ),
            "waiting on a question: Which base?"
        );
        assert_eq!(
            state(&json!({"status": "waiting", "waitingOn": "permission"})),
            "waiting on a permission"
        );
        assert_eq!(
            state(
                &json!({"status": "ready", "queuePaused": true, "lastTurn": {"status": "failed", "errorText": "agent process closed"}})
            ),
            "blocked: agent process closed; its queue is paused"
        );
        assert_eq!(state(&json!({"status": "disconnected"})), "blocked: its agent stopped");
    }

    #[test]
    fn a_lane_with_a_prompt_queued_is_working_not_idle() {
        let between = json!({"status": "ready", "queued": 1});
        assert_eq!(state(&between), "working on its next prompt");
        // A paused queue holds its prompts: blocked, not working.
        let paused = json!({"status": "ready", "queued": 1, "queuePaused": true});
        assert_eq!(state(&paused), "blocked: its queue is paused");
    }
}
