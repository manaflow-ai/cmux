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
//! daemon keeps each link (its queued report and its last one) in memory.
//!
//! A report is made when the lane's turn ends (`turns.rs`), from that turn's own records and
//! the lane's state then, and queued; delivery and its retries send that report and never read
//! the lane again, so a later turn never leaks into it. One delivery per lane is in flight at a
//! time. A report the parent refused stays queued and goes at the next turn end; a newer turn's
//! report replaces one still queued (keeping the pull requests only that one named).
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
//! - A report never steers: it waits for the parent's turn to end. The hub alone sets a
//!   report's provenance (`prompt_provenance.rs` takes only `agent_message` from a client), so
//!   no prompt passes for one.
//! - At most [`MAX_REPORTS`] reports a lane in [`WINDOW_MS`]: past it the newest is held and
//!   goes at a turn end under the cap, whatever the runaway pair guard (`agent_pairs.rs`)
//!   decides.
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
/// Transcript records read per page, newest first, back to the start of the last turn.
const TAIL_RECORDS: usize = 400;
/// Pages read back at most for the last turn (its reply streamed in more records than this
/// holds is read from where they start).
const MAX_TAIL_PAGES: usize = 50;
/// Parents walked up from a session at most. A chain this deep without the session in it is
/// refused too, since a link map that was written wrong could loop past the walk.
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
    /// The last report's content, to leave out the same report again.
    last: Option<String>,
    /// Pull requests a report already named.
    prs: Vec<String>,
    /// When the reports of the last [`WINDOW_MS`] went.
    sent: Vec<u64>,
    /// The newest report not delivered yet, made when its turn ended.
    ready: Option<Report>,
}

/// The links by lane id.
#[derive(Default)]
pub(crate) struct LaneReports {
    links: StdMutex<BTreeMap<String, Link>>,
    /// Lanes with a delivery on its way, and whether a turn ended meanwhile.
    inflight: StdMutex<HashMap<String, bool>>,
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

    fn lane_inflight(&self) -> std::sync::MutexGuard<'_, HashMap<String, bool>> {
        self.lane_reports.inflight.lock().unwrap_or_else(|e| e.into_inner())
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
        // A close sets the status before `lane_retire` takes this lock: read under it, a parent
        // or child that closed meanwhile is never linked, and one that closes after has its link
        // retired.
        let linked = self.lane_links(|links| {
            if !self.lane_open(parent) || !self.lane_open(child) {
                return false;
            }
            let link = Link { parent: parent.to_owned(), ..Link::default() };
            links.insert(child.to_owned(), link);
            true
        });
        if !linked {
            return;
        }
        let set = serde_json::Map::from_iter([(TAG.to_owned(), json!(parent))]);
        self.set_tags(&s, Some(&set), &[], None);
    }

    /// A local session's turn ended, or failed before its agent started (`turns.rs`): a lane's
    /// report of it is made now, from this turn's own records and state, and queued; delivery
    /// and its retries send that report and never read the lane again.
    pub(super) fn lane_turn_ended(self: &Arc<Self>, session: &Arc<Session>, started: bool) {
        let turn = session.meta().turn_count;
        if !self.lane_links(|links| links.contains_key(&session.id)) {
            return;
        }
        let report = self.lane_capture(session, turn, started);
        self.lane_links(|links| {
            if let Some(l) = links.get_mut(&session.id) {
                l.ready = Some(replace_ready(report, l.ready.take()));
            }
        });
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
    /// held (a newer turn's replaces it) and goes at a turn end under the cap; one the parent
    /// refused stays queued and goes at the next turn end.
    async fn lane_deliver_ready(self: &Arc<Self>, lane: &str) {
        let now = now_ms();
        let due = self.lane_links(|links| {
            let l = links.get_mut(lane)?;
            let report = due_report(l, now)?;
            Some((l.parent.clone(), report))
        });
        let Some((parent, report)) = due else { return };
        if let Err(e) = self.lane_deliver(&parent, lane, &report).await {
            tracing::warn!(lane, %parent, "lane report not delivered: {}", e.message);
            return;
        }
        self.lane_links(|links| {
            let Some(l) = links.get_mut(lane).filter(|l| l.parent == parent) else { return };
            if l.ready.as_ref().is_some_and(|r| r.prompt_id == report.prompt_id) {
                l.ready = None;
            }
            l.last = Some(report.key());
            l.prs.extend(report.prs.iter().cloned());
            l.sent.push(now);
        });
    }

    /// The report of turn `turn` of `session`, which just ended.
    /// `started`: its agent ran it. A turn that failed before its agent started has no reply
    /// of its own, so none is read (the last one is the turn before's).
    fn lane_capture(&self, session: &Session, turn: u64, started: bool) -> Report {
        let summary = self.session_summary(session);
        let read = if started { self.lane_last_reply(&session.id, &summary) } else { Ok(None) };
        let reply = match read {
            Ok(reply) => reply.unwrap_or_default(),
            Err(e) => {
                tracing::warn!(lane = %session.id, "lane report: its transcript did not read: {e}");
                String::new()
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
        let prs = new_items(opened.chain(named), &[]);
        let shas = new_items(FULL_SHA.find_iter(&reply).map(|m| m.as_str().to_owned()), &[]);
        let name = summary.get("name").and_then(Value::as_str).unwrap_or(&session.id);
        let state = state(&summary);
        Report {
            content: format!("{state}\n{reply}"),
            prompt_id: format!("{PROMPT_PREFIX}{}", uuid::Uuid::new_v4()),
            name: name.to_owned(),
            session: session.id.clone(),
            turn,
            state,
            reply: if reply.is_empty() {
                "(no reply)".into()
            } else {
                short_text(&reply, REPLY_CHARS)
            },
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
        let records = last_turn_records(last_seq, |before| {
            self.events_page(lane, 0, Some(before), TAIL_RECORDS, None, true, &filter)
        })?;
        let events: Vec<Value> = records
            .into_iter()
            .map(|r| json!({"seq": r.seq, "at": r.at, "dir": r.dir, "kind": r.kind, "msg": r.msg}))
            .collect();
        Ok(last_reply(&events))
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

/// The records of the last turn, from its `turn_started` on (or as far back as
/// [`MAX_TAIL_PAGES`] pages go), oldest first; `page(before)` reads the newest page below seq
/// `before`.
fn last_turn_records(
    last_seq: u64,
    mut page: impl FnMut(u64) -> Result<EventPage>,
) -> Result<Vec<crate::store::EventRecord>> {
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
            break;
        }
        before = first;
    }
    Ok(out)
}

/// `l`'s queued report to deliver now, without the pull requests reported before: none when it
/// is the same as the last (dropped) or past the cap (held).
fn due_report(l: &mut Link, now: u64) -> Option<Report> {
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
    Some(report)
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
        let got = due_report(&mut l, later).unwrap();
        assert_eq!((got.turn, got.prs), (4, vec![x.to_owned()]));
        // The very same report is dropped.
        let mut l = Link { last: Some(report(2, &[]).key()), ..Link::default() };
        l.ready = Some(report(2, &[]));
        assert_eq!(due_report(&mut l, now), None);
        assert!(l.ready.is_none());
    }

    #[test]
    fn a_newer_report_replaces_a_queued_one_and_keeps_its_pull_requests() {
        let got = replace_ready(report(2, &["pr/2"]), Some(report(1, &["pr/1", "pr/2"])));
        assert_eq!((got.turn, got.prs), (2, vec!["pr/2".to_owned(), "pr/1".to_owned()]));
        assert_eq!(replace_ready(report(1, &[]), None), report(1, &[]));
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
        let got = last_turn_records(1010, page).unwrap();
        assert_eq!(got.first().map(|r| r.seq), Some(10));
        assert_eq!(got.len(), 1001);
        assert!(got.windows(2).all(|w| w[0].seq + 1 == w[1].seq));
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
        hub.lane_link(&parent.id, &child.id);
        assert!(!hub.lane_links(|l| l.contains_key(&child.id)));
        // A child that closed after `lane_link` read it and before the link went in is not
        // linked again: its close retired its links already.
        let closing = hub.new_session(start()).await.unwrap();
        let open_parent = hub.new_session(start()).await.unwrap();
        hub.kill(&closing, false).await.unwrap();
        hub.lane_link(&open_parent.id, &closing.id);
        assert!(!hub.lane_links(|l| l.contains_key(&closing.id)));
        hub.kill(&closing, true).await.unwrap();
        hub.kill(&open_parent, true).await.unwrap();
        // An open parent is linked.
        let open = hub.new_session(start()).await.unwrap();
        hub.lane_link(&open.id, &child.id);
        assert!(hub.lane_links(|l| l.get(&child.id).is_some_and(|l| l.parent == open.id)));
        // Its parent closing retires it; a child is never linked under its own descendant.
        hub.kill(&open, false).await.unwrap();
        assert!(!hub.lane_links(|l| l.contains_key(&child.id)));
        let grandchild = hub.new_session(start()).await.unwrap();
        hub.lane_link(&child.id, &grandchild.id);
        hub.lane_link(&grandchild.id, &child.id);
        assert!(!hub.lane_links(|l| l.contains_key(&child.id)));
        hub.kill(&grandchild, true).await.unwrap();
        for s in [&child, &open] {
            hub.kill(s, true).await.unwrap();
        }
        hub.kill(&parent, true).await.unwrap();
    }

    use super::*;

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
