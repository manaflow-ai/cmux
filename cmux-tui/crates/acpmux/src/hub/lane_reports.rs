//! Part of `Hub`; see `hub/mod.rs`. A lane reports to the session that started it, the way a
//! Claude subagent's parent hears when it stops: at the end of each of the lane's turns its
//! parent gets one short report, without the lane having to remember `acpmux send`.
//!
//! Who a lane reports to is the link the daemon keeps, from the session its connection proved
//! it runs in (its caller token); its tag `lane.reportsTo` shows it. `lane_detach.rs` ends it.
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
//! - A still-waiting turn's report is held, not sent: the lane is `idle` but a background task
//!   of its own still runs that brings its end to the lane (`bg_notify.rs`), so a turn that
//!   reports is sure to follow; and its reply says it still waits ([`WAITING`]) and names no
//!   pull request or commit not reported before, no review verdict, and none of [`DECISIVE`]'s
//!   words (merged, failed, blocked, done, please, timed out, a question mark...). A reply that
//!   says anything else is news. A harness's own background shell or subagent does not count:
//!   the turn its end starts is the harness's (`background_turn.rs`), which reports nothing. Leo, 2026-11-09, about a coordinator one helper woke 15 times in a row to say
//!   "still waiting on fleet run": "for stuff like this, are you able to simply not respond? why
//!   are you even the one reading and responding to these no-ops anyways". It neither wakes nor
//!   steers into the parent: the lane's next report replaces it and says how many such turns it
//!   folds in, a still-waiting turn never replaces a real report still queued, and the lane's own
//!   row shows its last words meanwhile. One that nothing replaced in [`HELD_MAX_MS`] goes as it
//!   is (a task that never ends, a dev server say). A report that is no longer still waiting
//!   (the work ended, it failed, it asks) goes as before, at once.

use super::*;
use cmux_json::JsonSet as _;
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
/// The longest a still-waiting turn's report is held when no newer one replaces it.
pub const HELD_MAX_MS: u64 = 15 * 60 * 1000;
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
pub(super) struct Link {
    pub(super) parent: String,
    pub(super) asked: bool,
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
    /// The timer that sends a still-waiting `ready` (its prompt id) once it was held
    /// [`HELD_MAX_MS`]; aborted when another is armed. One that fires for a link gone or a
    /// report replaced does nothing.
    held: Option<(String, tokio::task::AbortHandle)>,
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
    /// The parent's subagent that asked for each turn, by session and turn
    /// (`lane_report_subagents.rs` `asking_subagent`): its report goes to that subagent.
    subagents: HashMap<(String, u64), Value>,
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
        self.subagents.retain(|(s, _), _| s != id);
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

/// One report, before it is written out. Kept whole beside a subagent's notice until it takes
/// it (`lane_report_subagents.rs`), so a report it never took still reaches the lead.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub(super) struct Report {
    /// Its state and whole reply; with its pull requests, what makes two reports the same
    /// ([`Report::key`]).
    content: String,
    /// The same for every try of this report.
    pub(super) prompt_id: String,
    pub(super) name: String,
    /// The lane's id.
    pub(super) session: String,
    pub(super) turn: u64,
    state: String,
    reply: String,
    prs: Vec<String>,
    shas: Vec<String>,
    /// The Claude Code subagent of the parent that asked for this turn without waiting for its
    /// reply (`{id, type}`, its prompt's `fromSubagent`): the report goes to it while it runs.
    #[serde(default)]
    pub(super) for_subagent: Option<Value>,
    /// That subagent has ended: the report goes to the parent, saying whose it was.
    #[serde(default)]
    pub(super) subagent_ended: bool,
    /// Its turn only said the lane still waits on its own work (module docs): held, never sent
    /// unless a newer report replaces it.
    #[serde(default)]
    pub(super) interim: bool,
    /// Still-waiting turns before this one whose reports it replaced.
    #[serde(default)]
    pub(super) quiet_turns: u32,
}

impl Report {
    /// This report, for its parent's chat: the subagent it was for has ended.
    pub(super) fn subagent_gone(&self) -> Self {
        Self { subagent_ended: true, ..self.clone() }
    }

    /// What makes two reports the same: the state, the reply and every pull request it names.
    fn key(&self) -> String {
        format!("{}\n{}", self.content, self.prs.join(" "))
    }

    pub(super) fn text(&self) -> String {
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
        if self.quiet_turns > 0 {
            let turns = if self.quiet_turns == 1 { "turn" } else { "turns" };
            t.push_str(&format!(
                "\n({} {turns} before this one only said it was still waiting on its own work; \
those reports were held.)",
                self.quiet_turns
            ));
        }
        if self.subagent_ended
            && let Some(label) = super::lane_report_subagents::label(self.for_subagent.as_ref())
        {
            t.push_str(&format!(
                "\nThis report is for your {label}, which asked for this turn and has ended, so \
it comes to you."
            ));
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

/// A clause of a still-waiting reply, whole: a wait on a named piece of the lane's own work
/// ("still waiting on fleet run 42549646257", "the compile check is still running on the pool"),
/// or "nothing new". Nothing else may be in the clause: a reply is still-waiting only when every
/// clause is one of these or an [`ELAPSED`] one (reviews of #39105 at bfdb6cd, dd6dd96 and
/// 849eeac: a request in or beside a wait is news). The work is named from a short list of
/// words, so a wait on anything else (a person, an input) is news too.
const WAITING: &str = concat!(
    r"(?i)^(?:",
    // "still waiting on (the) fleet run 4254...", "waiting for CI (attempt 2)"
    r"(?:still |just )?(?:waiting|wait) (?:on|for) (?:the |its |my |a |this )?(?:WORK|ID)(?: (?:WORK|ID))*",
    r"|(?:the |its |my )?(?:WORK)(?: (?:WORK|ID))* (?:is|are) still (?:running|pending|queued|in progress|going)",
    r"(?: on (?:the )?(?:pool|fleet|runner|runners|mini|minis|linux|mac|box|vm))?",
    r"|(?:still )?(?:waiting|running)",
    r"|nothing new(?: yet)?(?: (?:here|from (?:the )?(?:WORK)))?",
    r"|no change(?: yet)?",
    r")$",
);

/// The words a wait may name its work with, and what may follow them (an id, a number, a link,
/// "(attempt 2)").
const WAITING_WORK: &str = r"fleet|ci|checks?|builds?|tests?|compile|compile-check|compile check|jobs?|pool|runners?|runs?|review|reviews|reviewer|merge queue|queue|mirror|deploy|deployment|nightly|pr|pull request|workflow|actions|pipeline|the|its|my|linux|mac|macos|ios|web|rust|cargo|bench|benchmark|soak|sync|upload of the build|artifact|artifacts|lease|machine";
const WAITING_ID: &str = r"#?\d+|\(attempt \d+\)|https?://\S+|[0-9a-f]{7,12}|[A-Za-z]+-\d+";

/// Words that make a turn's reply news for its parent even while it says it waits: an end, a
/// failure, a block, an ask, a request to act, or a wait on the reader ("waiting for you to
/// upload the credentials", review of #39105 at e8aeb72, F1) (module docs). A false match only sends a
/// report, as before.
const DECISIVE: &str = r"(?i)\b(merged|landed|shipped|done|finished|completed?|passed|passing|green|succeeded|ready|fail(?:ed|s|ing|ure|ures)?|errors?|blocked|stuck|needs?|question|approve|approval|refused|denied|cancell?ed|broken|red|timed out|time ?outs?|please|rebase|restart|retry|retrying|can you|could you|should|must|want|you|your|yours|input|reply|answer|confirm|confirmation|decision|decide|permission|access|credentials?|token|login|sign in|upload)\b|\?|!";

/// A sentence of a still-waiting reply that only says how long it has waited ("4 min in").
const ELAPSED: &str = r"(?i)^\(?\s*(about |over |~)?\d+\s*(s|sec|secs|seconds?|m|min|mins|minutes?|h|hours?)\b( in| so far| now| elapsed)?\)?$";
/// Where a reply's clauses end: `.`, `,`, `;`, `:`, `!` or `?` before a space or the end, a
/// dash between spaces, or a line break. A period inside a URL ends none.
const SENTENCE_END: &str = r"[.,;:!?](\s+|$)|\s[-\u{2013}\u{2014}]\s|\n";

static WAITING_WORDS: LazyLock<Option<Regex>> = LazyLock::new(|| {
    let work = format!("(?:{WAITING_WORK})");
    let id = format!("(?:{WAITING_ID})");
    Regex::new(&WAITING.replace("WORK", &work).replace("ID", &id)).ok()
});
static DECISIVE_WORDS: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(DECISIVE).ok());
static ELAPSED_LINE: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(ELAPSED).ok());
static SENTENCE_ENDS: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(SENTENCE_END).ok());

/// Whether `reply`, a lane's turn's, says only that it still waits: each of its clauses is a
/// whole wait ([`WAITING`]) or says how long ([`ELAPSED`]), so a request in or beside a wait
/// ("Still waiting on fleet, stop the rollout.") is news; and it has no review
/// verdict, no full commit sha and none of [`DECISIVE`]'s words. A pull request it names is news
/// only when not reported before, which delivery decides (`due_report`). A pattern that failed
/// to build counts every reply as news.
fn says_only_waiting(reply: &str) -> bool {
    let (Some(waiting), Some(decisive), Some(elapsed), Some(ends)) = (
        WAITING_WORDS.as_ref(),
        DECISIVE_WORDS.as_ref(),
        ELAPSED_LINE.as_ref(),
        SENTENCE_ENDS.as_ref(),
    ) else {
        return false;
    };
    let mut sentences = ends.split(reply).map(str::trim).filter(|s| !s.is_empty()).peekable();
    sentences.peek().is_some()
        && sentences.all(|s| waiting.is_match(s) || elapsed.is_match(s))
        && !decisive.is_match(reply)
        && !super::lane_report_text::has_verdict(reply)
        && matches(&FULL_SHA, reply).is_empty()
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

    pub(super) fn lane_links<R>(&self, f: impl FnOnce(&mut BTreeMap<String, Link>) -> R) -> R {
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
    /// child and keeps the link. Turns done now are not reported.
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

    /// `session`'s turn started (its turn count counts it), with `provenance` for the whole turn
    /// (`digest.rs`).
    pub(super) fn lane_turn_started(&self, session: &Session, provenance: Option<&Value>) {
        self.lane_turn_on(session, reports_only(provenance));
        self.lane_turn_asked(session, provenance);
        let parent = self.lane_report_parent(&session.id);
        let turn = session.meta().turn_count;
        let kind = provenance.and_then(|p| p.get("kind")).and_then(Value::as_str);
        if parent.is_some() && kind == Some(super::digest::DIGEST_KIND) {
            self.lane_report_turn_joined(&session.id, turn);
        }
    }

    /// `session`'s turn started (its turn count counts it) on the messages `provenance` names: a
    /// subagent of the lane's parent that asked for it gets its report
    /// (`lane_report_subagents.rs`). A carried turn's names the steers it carried
    /// (`carried_turn.rs`).
    pub(super) fn lane_turn_asked(&self, session: &Session, provenance: Option<&Value>) {
        let parent = self.lane_report_parent(&session.id);
        if let Some(sub) =
            super::lane_report_subagents::asking_subagent(parent.as_deref(), provenance)
        {
            let turn = session.meta().turn_count;
            self.lane_turns().subagents.insert((session.id.clone(), turn), sub);
        }
    }

    /// `session`'s turn started (its turn count counts it); `reports`: on lane reports only (a
    /// carried turn's steers, `carried_turn.rs`).
    pub(super) fn lane_turn_on(&self, session: &Session, reports: bool) {
        if reports {
            let turn = session.meta().turn_count;
            self.lane_turns().report_only.insert((session.id.clone(), turn));
        }
    }

    /// The subagent of the lane's parent that asked for turn `turn` of session `id`.
    #[cfg(test)]
    pub(super) fn lane_turn_subagent(&self, id: &str, turn: u64) -> Option<Value> {
        self.lane_turns().subagents.get(&(id.to_owned(), turn)).cloned()
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
        // Reports left for its subagents that none of them will take (`lane_report_subagents.rs`).
        self.subagent_notices_sweep(session);
        // One that failed to start left the lane stuck, so it reports whatever it took in.
        let on_reports = self.lane_turns().end(&session.id, turn) && started;
        if !self.lane_links(|links| links.contains_key(&session.id)) {
            self.lane_turns().subagents.remove(&(session.id.clone(), turn));
            return;
        }
        self.lane_report_ended(&session.id, turn);
        // A turn on reports only makes none, and leaves one still queued to go now.
        if !on_reports {
            let report = self.lane_capture(session, turn, started);
            self.lane_links(|links| {
                if let Some(l) = links.get_mut(&session.id) {
                    l.ready = Some(replace_ready_seen(report, l.ready.take(), &l.prs));
                }
            });
        } else {
            self.lane_turns().subagents.remove(&(session.id.clone(), turn));
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
            self.lane_release_waiting_at(lane, HELD_MAX_MS);
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

    /// A still-waiting report held now (`due_report`) goes as it is once held `after` ms, unless
    /// a newer one replaced it meanwhile, which arms its own. One timer a lane: arming one aborts
    /// the one before, and it stops after its one send.
    fn lane_release_waiting_at(self: &Arc<Self>, lane: &str, after: u64) {
        let held = self.lane_links(|links| {
            let l = links.get_mut(lane)?;
            let r = l.ready.as_ref().filter(|r| r.interim)?;
            // Already timed: held since it was first held, not since this look.
            if l.held.as_ref().is_some_and(|(id, t)| *id == r.prompt_id && !t.is_finished()) {
                return None;
            }
            Some(r.prompt_id.clone())
        });
        let Some(held) = held else { return };
        let (hub, id, report) = (Arc::downgrade(self), lane.to_owned(), held.clone());
        let timer = tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(after)).await;
            let Some(hub) = hub.upgrade() else { return };
            let released = hub.lane_links(|links| {
                let l = links.get_mut(&id)?;
                l.held = None;
                let r = l.ready.as_mut().filter(|r| r.prompt_id == held && r.interim)?;
                r.interim = false;
                Some(())
            });
            if released.is_some() {
                hub.lane_send(&id);
            }
        });
        let old = self.lane_links(|links| {
            let l = links.get_mut(lane)?;
            l.held.replace((report, timer.abort_handle()))
        });
        if let Some((_, old)) = old {
            old.abort();
        }
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
        let for_subagent = self.lane_turns().subagents.remove(&(session.id.clone(), turn));
        self.capture_report(session, turn, started, for_subagent)
    }

    /// The report of `session`'s turn `turn`, which just ended, for the session that asked it a
    /// question without waiting (`question_replies.rs`), and the asking subagent, if any.
    /// `started` as in [`Hub::lane_capture`]: a turn whose agent never got the prompt has no reply.
    pub(super) fn lane_capture_reply(
        &self,
        session: &Session,
        turn: u64,
        started: bool,
        for_subagent: Option<Value>,
    ) -> Report {
        self.capture_report(session, turn, started, for_subagent)
    }

    /// [`Hub::lane_capture`] with the subagent the report is for.
    fn capture_report(
        &self,
        session: &Session,
        turn: u64,
        started: bool,
        for_subagent: Option<Value>,
    ) -> Report {
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
        // Still waiting (module docs): idle, its own work runs on, and its words say nothing new.
        let interim = started
            && state == "idle"
            && says_only_waiting(&reply)
            && self.lane_own_work_runs(session);
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
            for_subagent,
            subagent_ended: false,
            interim,
            quiet_turns: 0,
        }
    }

    /// Whether work `session` started still runs past its turn and is sure to bring it a turn
    /// that reports: a background task of the daemon that brings its end to the chat (module
    /// docs).
    fn lane_own_work_runs(&self, session: &Session) -> bool {
        self.bg_notifying_count(session) > 0
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
        // Reports left for its subagents (`lane_report_subagents.rs`): none of them runs now.
        crate::subagent_notice::forget(&crate::config::home(), id);
    }

    /// Hands the report to the parent: accepted (queued, started, steered or held for the
    /// person). A turn a subagent of the parent asked for without waiting goes to that subagent
    /// while it runs (`lane_report_subagents.rs`), and to the parent, saying whose it was, once
    /// it has ended.
    pub(super) async fn lane_deliver(
        self: &Arc<Self>,
        parent: &str,
        lane: &str,
        report: &Report,
    ) -> Result<(), RpcError> {
        let local = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(parent).cloned();
        let Some(p) = local else {
            // The parent is gone: nobody to report to.
            self.lane_links(|links| {
                links.remove(lane);
            });
            return Ok(());
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
                let provenance = self.lane_report_provenance(parent, lane, report);
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
        let ended;
        let report = if report.for_subagent.is_some() && !report.subagent_ended {
            if self.lane_report_to_subagent(&p, report, false) {
                return Ok(());
            }
            ended = report.subagent_gone();
            &ended
        } else {
            report
        };
        self.lane_report_to_parent(p, lane, report).await
    }

    /// The report's provenance: `{kind: "lane_report", from, fromName, to, turn, state,
    /// details}`, the lane bound as its sender, and `forSubagent` for a subagent's turn.
    fn lane_report_provenance(&self, parent: &str, lane: &str, report: &Report) -> Value {
        let mut provenance = json!({
            "kind": KIND, "from": lane, "fromName": report.name, "to": parent,
            "turn": report.turn, "state": report.state,
            "details": {"session": report.session, "commits": report.shas},
        });
        if let Some(sub) = &report.for_subagent {
            provenance.set(super::lane_report_subagents::FOR_SUBAGENT, sub.clone());
        }
        // The lane's id and harness, for the parent's queue list (`prompt_provenance.rs`).
        let lane_session =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(lane).cloned();
        let sender = lane_session
            .map(|l| crate::prompt_provenance::BoundSender::of_session(&l.id, &l.meta()));
        crate::prompt_provenance::stamp_sender(provenance, sender.as_ref())
    }

    /// Puts the report in parent `p`'s chat as a hub-set prompt; done once it is accepted.
    pub(super) async fn lane_report_to_parent(
        self: &Arc<Self>,
        p: Arc<Session>,
        lane: &str,
        report: &Report,
    ) -> Result<(), RpcError> {
        let provenance = self.lane_report_provenance(&p.id, lane, report);
        let blocks = vec![json!({"type": "text", "text": report.text()})];
        let (tx, rx) = oneshot::channel();
        let opts = PromptOptions {
            prompt_id: Some(report.prompt_id.clone()),
            resend: true,
            provenance: Some(provenance),
            agent: Some(report.name.clone()),
            // A lane's report says what its turn did (`prompt_class.rs`).
            class: Some(crate::prompt_class::PromptClass::Result),
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
    // A still-waiting turn's report stays queued for the next one to replace (module docs).
    if report.interim && report.prs.is_empty() {
        return None;
    }
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
/// named, and counting a still-waiting one it folds in. A still-waiting turn's report never
/// replaces one that is news: that one stays queued, to go as it is.
#[cfg(test)]
fn replace_ready(newer: Report, queued: Option<Report>) -> Report {
    replace_ready_seen(newer, queued, &[])
}

/// [`replace_ready`] on a link whose reports already named `reported`: a still-waiting turn
/// naming only those is no news (review of #39105 at e8aeb72, F2).
fn replace_ready_seen(mut newer: Report, queued: Option<Report>, reported: &[String]) -> Report {
    let Some(queued) = queued else { return newer };
    if newer.interim && !queued.interim {
        // A still-waiting turn that names a pull request the news does not is news itself: it
        // replaces the news as any newer report does, under its own turn and id (review of
        // #39105 at bfdb6cd, F2). One that names none leaves the news queued as it is.
        if newer.prs.iter().all(|pr| queued.prs.contains(pr) || reported.contains(pr)) {
            return queued;
        }
        newer.interim = false;
    }
    newer.quiet_turns = queued.quiet_turns.saturating_add(u32::from(queued.interim));
    for pr in queued.prs {
        if !newer.prs.contains(&pr) {
            newer.prs.push(pr);
        }
    }
    newer
}

#[cfg(test)]
mod tests;
