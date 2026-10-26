//! Part of `Hub`; see `hub/mod.rs`. A lane reports to the session that started it, the way a
//! Claude subagent's parent hears when it stops: at the end of each of the lane's turns its
//! parent gets one short report, without the lane having to remember `acpmux send`.
//!
//! Who a lane reports to is the link the daemon keeps, set from the session its connection
//! proved it runs in (its caller token). The lane's tag `lane.reportsTo` (the parent's exact
//! session id) shows it; changing or removing that tag changes nothing.
//!
//! - `session/new` from inside a session: that session is the new one's parent. A run tied to
//!   its connection (`--ephemeral`) is no lane and gets none.
//! - A lane keeps the parent that started it; a session that gives it a later task does not
//!   take it over yet (a follow-up).
//!
//! Lane and parent are sessions of this daemon; a lane or parent on a peer comes later. The
//! daemon keeps each link (the lane's turn last reported and its last report) in memory.
//!
//! A report goes when the lane's turn count passes the one last reported, at the lane's turn
//! end (`turns.rs`). One delivery per lane is in flight at a time, and the turn counts as
//! reported only once the parent accepted it, so a refusal sends it at the next turn end and
//! two turn ends close together send once. Several turns that ended meanwhile are one report,
//! of the last.
//!
//! ```text
//! [NAME] lane report: turn N ended, STATE.
//! Session: HOST/ID
//! Last message: the first 400 characters of its last reply
//! Pull requests: URLs its gh pr create calls printed or the reply names, not reported before
//! Commits named: full SHAs in the reply
//! ```
//!
//! STATE is `idle`, `working on its next prompt`, `waiting on a permission` / `waiting on a
//! question: ...`, or `blocked: ...` (a failed turn and the queue it paused, a stopped agent).
//!
//! - A report the same as the lane's last one (state, reply, pull requests and commits) is not
//!   sent again; the turn still counts as reported.
//! - A turn that ran on lane reports only (a report, or a turn of agent messages, `digest.rs`,
//!   that took in nothing else, and nothing else steered into it) sends none, so a parent's turn
//!   on reports never reports upward and a report never answers a report. The hub alone sets a report's provenance
//!   (`prompt_provenance.rs` takes only `agent_message` from a client), so no prompt passes for
//!   one. A report never steers: it waits for the parent's turn to end, so it never becomes part
//!   of a turn that reports.
//! - At most [`MAX_REPORTS`] reports a lane in [`WINDOW_MS`]; the rest are counted as reported
//!   and not sent, whatever the runaway pair guard (`agent_pairs.rs`) decides.
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
/// The reply's first characters a report carries.
const REPLY_CHARS: usize = 400;
/// The newest transcript records read for the last reply.
const TAIL_RECORDS: usize = 400;
/// Parents walked up before a link is refused as a loop.
const MAX_DEPTH: usize = 16;
/// Reports one lane sends within [`WINDOW_MS`] at most.
pub const MAX_REPORTS: usize = 20;
/// The window of [`MAX_REPORTS`].
pub const WINDOW_MS: u64 = 10 * 60 * 1000;
/// The words after `[NAME] ` that start a report (`prompt_line.rs` reads the name).
const HEAD: &str = "lane report: turn ";
/// A report's prompt id starts with this.
const PROMPT_PREFIX: &str = "lane-report-";

static PULL_URL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+").unwrap() // crash-allow: constant pattern
});
static FULL_SHA: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b[0-9a-f]{40}\b").unwrap() // crash-allow: constant pattern
});

/// One lane's link to its parent.
#[derive(Debug, Clone, Default)]
struct Link {
    parent: String,
    /// The lane's turn count when it was linked or last reported.
    reported: u64,
    /// The last report's content, to leave out the same report again.
    last: Option<String>,
    /// Pull requests a report already named.
    prs: Vec<String>,
    /// When the reports of the last [`WINDOW_MS`] went.
    sent: Vec<u64>,
    /// The turn a report is being sent for and its prompt id, for every try of it.
    pending: Option<(u64, String)>,
    /// A report its parent did not take: it goes with a later turn that sends none of its own.
    unsent: Option<Report>,
}

/// The links by lane id.
#[derive(Default)]
pub(crate) struct LaneReports {
    links: StdMutex<BTreeMap<String, Link>>,
    /// Lanes with a check or report on its way, and the newest turn whose end was checked
    /// meanwhile (`Some` once another check came).
    inflight: StdMutex<HashMap<String, Option<u64>>>,
    /// The last turn of each session that ran on lane reports only. A later turn leaves it, so a
    /// report of that turn still sees it once the next has started.
    report_turns: StdMutex<HashMap<String, u64>>,
}

/// One report, before it is written out.
#[derive(Debug, Clone, PartialEq)]
struct Report {
    /// What makes two reports the same: the state, the reply and every pull request it names.
    content: String,
    name: String,
    session: String,
    turn: u64,
    state: String,
    reply: String,
    prs: Vec<String>,
    shas: Vec<String>,
}

impl Report {
    fn text(&self) -> String {
        let mut t = format!(
            "[{}] {HEAD}{} ended, {}.\nSession: {}\nLast message: {}",
            self.name, self.turn, self.state, self.session, self.reply
        );
        if !self.prs.is_empty() {
            t.push_str(&format!("\nPull requests: {}", self.prs.join(" ")));
        }
        if !self.shas.is_empty() {
            t.push_str(&format!("\nCommits named: {}", self.shas.join(" ")));
        }
        t.push_str(
            "\n(acpmux sends this at the end of each turn of a session you started or gave a \
             task. Answer only if it needs you.)",
        );
        t
    }
}

/// Whether a turn's provenance is lane reports only: a report, or a turn of agent messages that
/// took in nothing else.
fn reports_only(provenance: Option<&Value>) -> bool {
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
    fn lane_links<R>(&self, f: impl FnOnce(&mut BTreeMap<String, Link>) -> R) -> R {
        f(&mut self.lane_reports.links.lock().unwrap_or_else(|e| e.into_inner()))
    }

    fn lane_inflight(&self) -> std::sync::MutexGuard<'_, HashMap<String, Option<u64>>> {
        self.lane_reports.inflight.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Takes `lane`'s one check; when another has it, that one checks again once done.
    fn lane_claim(&self, lane: &str, ended: Option<u64>) -> bool {
        let mut inflight = self.lane_inflight();
        match inflight.get_mut(lane) {
            Some(again) => {
                *again = Some(again.unwrap_or(0).max(ended.unwrap_or(0)));
                false
            }
            None => {
                inflight.insert(lane.to_owned(), None);
                true
            }
        }
    }

    /// Gives `lane`'s check back: the newest turn end checked meanwhile, if another came.
    fn lane_release(&self, lane: &str) -> Option<u64> {
        self.lane_inflight().remove(lane).flatten()
    }

    /// The summary of session `id` (exact).
    fn lane_summary(&self, id: &str) -> Option<Value> {
        let s = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()?;
        Some(self.session_summary(&s))
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
        true
    }

    /// From now on `parent` hears the end of each of `child`'s turns (both exact ids): tags the
    /// child and keeps the link. Turns done now are not reported.
    pub(crate) fn lane_link(&self, parent: &str, child: &str) {
        // A session never becomes the child of itself or of its own descendant.
        if parent == child || self.lane_below(parent, child) {
            return;
        }
        let Some(s) = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(child).cloned()
        else {
            return;
        };
        let reported = s.meta().turn_count;
        self.lane_links(|links| {
            let link = Link { parent: parent.to_owned(), reported, ..Link::default() };
            links.insert(child.to_owned(), link);
        });
        let set = serde_json::Map::from_iter([(TAG.to_owned(), json!(parent))]);
        self.set_tags(&s, Some(&set), &[], None);
    }

    /// `session`'s turn started (its turn count counts it), with `provenance` for the whole turn
    /// (`digest.rs`).
    pub(super) fn lane_turn_started(&self, session: &Session, provenance: Option<&Value>) {
        if reports_only(provenance) {
            let turn = session.meta().turn_count;
            self.lane_report_turns().insert(session.id.clone(), turn);
        }
    }

    /// A prompt that is not a lane report steered into `session`'s running turn: that turn did
    /// more than take in reports.
    pub(super) fn lane_turn_steered(&self, session: &Session, provenance: Option<&Value>) {
        if reports_only(provenance) {
            return;
        }
        let turn = session.meta().turn_count;
        let mut marked = self.lane_report_turns();
        if marked.get(&session.id) == Some(&turn) {
            marked.remove(&session.id);
        }
    }

    fn lane_report_turns(&self) -> std::sync::MutexGuard<'_, HashMap<String, u64>> {
        self.lane_reports.report_turns.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// A local session's turn ended, or failed before its agent started (`turns.rs`).
    pub(super) fn lane_turn_ended(self: &Arc<Self>, session: &Arc<Session>) {
        let turn = session.meta().turn_count;
        self.lane_check(&session.id, Some(turn));
    }

    /// Sends `lane`'s report when a turn of it ended since the last one. `ended`: the turn whose
    /// end this is, so a running turn is reported up to it and no further: the turn it shows
    /// may be that one, still marked running, or a later one that started since.
    fn lane_check(self: &Arc<Self>, lane: &str, ended: Option<u64>) {
        // One check at a time, so two never read the same link and send the same turn twice; a
        // turn end meanwhile is checked once it is done.
        if !self.lane_links(|links| links.contains_key(lane)) || !self.lane_claim(lane, ended) {
            return;
        }
        let due = self.lane_due(lane, ended);
        let Some((link, summary, turns, on_reports)) = due else {
            if let Some(again) = self.lane_release(lane) {
                self.lane_check(lane, Some(again));
            }
            return;
        };
        let (hub, lane) = (self.clone(), lane.to_owned());
        tokio::spawn(async move {
            let done = hub.lane_report(&lane, &link, &summary, turns, on_reports).await;
            let again = hub.lane_release(&lane);
            // Turns that ended while it was on its way: reported now, or the same report.
            if done || again.is_some() {
                hub.lane_check(&lane, again);
            }
        });
    }

    /// `lane`'s link, summary and turn count when a turn of it is due a report, and whether that
    /// turn ran on lane reports only, read now: a turn that starts later changes neither.
    fn lane_due(&self, lane: &str, ended: Option<u64>) -> Option<(Link, Value, u64, bool)> {
        let link = self.lane_links(|links| links.get(lane).cloned())?;
        let summary = self.lane_summary(lane)?;
        let now = summary.get("turnCount").and_then(Value::as_u64).unwrap_or(0);
        let running = summary.get("turn").is_some_and(|t| !t.is_null())
            || summary.get("status").and_then(Value::as_str) == Some("running");
        let turns = due_turn(now, running, ended, link.reported)?;
        let on_reports = self.lane_report_turns().get(lane) == Some(&turns);
        Some((link, summary, turns, on_reports))
    }

    /// Reports turn `turns` of `lane`; true once it counts as reported (sent, or nothing due).
    async fn lane_report(
        self: &Arc<Self>,
        lane: &str,
        link: &Link,
        summary: &Value,
        turns: u64,
        on_reports: bool,
    ) -> bool {
        let now = now_ms();
        let recent = |sent: &[u64]| -> Vec<u64> {
            sent.iter().copied().filter(|t| now.saturating_sub(*t) < WINDOW_MS).collect()
        };
        let capped = recent(&link.sent).len() >= MAX_REPORTS;
        let own = if on_reports {
            None
        } else if capped {
            tracing::warn!(lane, "lane report not sent: {MAX_REPORTS} in the last 10 minutes");
            None
        } else {
            // A transcript it cannot read now is no reply: the turn waits for the next check.
            let Some(report) = self.lane_build(lane, link, summary, turns).await else {
                return false;
            };
            Some(report)
        };
        let own = own.filter(|r| link.last.as_deref() != Some(r.content.as_str()));
        let report = pick_report(own, link.unsent.as_ref(), capped);
        let report_turn = report.as_ref().map_or(turns, |r| r.turn);
        let prompt_id = self.lane_links(|links| {
            let l = links.get_mut(lane)?;
            let id = match &l.pending {
                Some((turn, id)) if *turn == report_turn => id.clone(),
                _ => format!("{PROMPT_PREFIX}{}", uuid::Uuid::new_v4()),
            };
            l.pending = Some((report_turn, id.clone()));
            Some(id)
        });
        let Some(prompt_id) = prompt_id else { return true };
        if let Some(report) = &report
            && let Err(e) = self.lane_deliver(&link.parent, lane, report, prompt_id).await
        {
            tracing::warn!(lane, parent = %link.parent, "lane report not delivered: {}", e.message);
            self.lane_links(|links| {
                if let Some(l) = links.get_mut(lane).filter(|l| l.parent == link.parent) {
                    l.unsent = Some(report.clone());
                }
            });
            return false;
        }
        self.lane_links(|links| {
            let Some(l) = links.get_mut(lane).filter(|l| l.parent == link.parent) else { return };
            l.reported = l.reported.max(turns);
            l.pending = None;
            l.sent = recent(&l.sent);
            if let Some(report) = &report {
                l.unsent = None;
                l.last = Some(report.content.clone());
                l.prs.extend(report.prs.iter().cloned());
                l.sent.push(now);
            }
        });
        true
    }

    /// None when the lane's transcript cannot be read now.
    async fn lane_build(
        &self,
        lane: &str,
        link: &Link,
        summary: &Value,
        turns: u64,
    ) -> Option<Report> {
        let reply = match self.lane_last_reply(lane, summary).await {
            Ok(reply) => reply.unwrap_or_default(),
            Err(e) => {
                tracing::warn!(lane, "lane report waits: its transcript did not read: {e}");
                return None;
            }
        };
        let opened = summary
            .get("pullRequests")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_owned);
        let named = PULL_URL.find_iter(&reply).map(|m| m.as_str().to_owned());
        let all = new_items(opened.chain(named), &[]);
        let prs = new_items(all.iter().cloned(), &link.prs);
        let shas = new_items(FULL_SHA.find_iter(&reply).map(|m| m.as_str().to_owned()), &[]);
        let name = summary.get("name").and_then(Value::as_str).unwrap_or(lane);
        let state = state(summary);
        Some(Report {
            content: format!("{state}\n{reply}\n{}", all.join(" ")),
            name: name.to_owned(),
            session: lane.to_owned(),
            turn: turns,
            state,
            reply: if reply.is_empty() {
                "(no reply)".into()
            } else {
                short_text(&reply, REPLY_CHARS)
            },
            prs,
            shas,
        })
    }

    /// The lane's last reply, read from its newest transcript records; an error when they
    /// cannot be read.
    async fn lane_last_reply(&self, lane: &str, summary: &Value) -> Result<Option<String>> {
        let last_seq = summary.get("lastSeq").and_then(Value::as_u64).unwrap_or(0);
        let filter = EventFilter::parse(Some(&json!(["transcript"])))
            .map_err(|e| anyhow::anyhow!("transcript filter: {e:?}"))?;
        let before = Some(last_seq.saturating_add(1));
        let page = self.events_page(lane, 0, before, TAIL_RECORDS, None, true, &filter)?;
        let events: Vec<Value> = page
            .events
            .into_iter()
            .map(|r| json!({"seq": r.seq, "at": r.at, "dir": r.dir, "kind": r.kind, "msg": r.msg}))
            .collect();
        Ok(last_reply(&events))
    }

    /// Hands the report to the parent: accepted (queued, started, steered or held for the
    /// person).
    async fn lane_deliver(
        self: &Arc<Self>,
        parent: &str,
        lane: &str,
        report: &Report,
        prompt_id: String,
    ) -> Result<(), RpcError> {
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
        });
        let (tx, rx) = oneshot::channel();
        let opts = PromptOptions {
            prompt_id: Some(prompt_id),
            resend: true,
            provenance: Some(provenance),
            agent: Some(report.name.clone()),
            on_accepted: Some(Box::new(move |v| {
                let _ = tx.send(v);
            })),
            ..PromptOptions::default()
        };
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

/// What a turn sends: its own report, or else one its parent did not take before (that turn
/// ended for real), but never past the cap: a held report waits for a turn under it. A newer
/// report of its own replaces the held one and keeps the pull requests only that one named.
fn pick_report(own: Option<Report>, unsent: Option<&Report>, capped: bool) -> Option<Report> {
    match (own, unsent) {
        (Some(mut own), Some(held)) => {
            for pr in &held.prs {
                if !own.prs.contains(pr) {
                    own.prs.push(pr.clone());
                }
            }
            Some(own)
        }
        (Some(own), None) => Some(own),
        (None, held) => held.filter(|_| !capped).cloned(),
    }
}

/// The turn a check reports: the lane's turn count `now` when no turn runs; while one runs,
/// the turn whose end this check is (`ended`) and none past it, since the one running may have
/// started after that end and has not ended. None when that turn was reported already.
fn due_turn(now: u64, running: bool, ended: Option<u64>, reported: u64) -> Option<u64> {
    let turns = match (running, ended) {
        (false, _) => now,
        (true, Some(ended)) => ended.min(now),
        (true, None) => return None,
    };
    (turns > reported).then_some(turns)
}

#[cfg(test)]
mod tests {
    fn report(turn: u64, prs: &[&str]) -> Report {
        Report {
            content: format!("turn {turn}"),
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
    fn a_report_the_parent_did_not_take_goes_with_a_later_turn_but_never_past_the_cap() {
        let held = report(1, &["pr/1"]);
        // A turn on reports only sends the held report.
        assert_eq!(pick_report(None, Some(&held), false), Some(held.clone()));
        // Past the cap it stays held.
        assert_eq!(pick_report(None, Some(&held), true), None);
        // A newer report replaces it and keeps the pull requests only the held one named.
        let got = pick_report(Some(report(2, &["pr/2"])), Some(&held), false).unwrap();
        assert_eq!((got.turn, got.prs), (2, vec!["pr/2".to_owned(), "pr/1".to_owned()]));
        assert_eq!(pick_report(None, None, false), None);
    }

    #[test]
    fn a_check_never_reports_a_turn_still_running() {
        // Turn 1 ended; by the retry turn 2 has started: the report is of turn 1.
        assert_eq!(due_turn(2, true, Some(1), 0), Some(1));
        // A retry with no turn end behind it waits while a turn runs.
        assert_eq!(due_turn(2, true, None, 1), None);
        // Turn 1 reported, turn 2 still running: nothing yet.
        assert_eq!(due_turn(2, true, Some(1), 1), None);
        // Turn 2 has ended and nothing runs: turn 2.
        assert_eq!(due_turn(2, false, None, 1), Some(2));
        // The ending turn still shows as running when its end is checked.
        assert_eq!(due_turn(3, true, Some(3), 2), Some(3));
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
}
