//! Part of `Hub`; see `hub/mod.rs`. The review queue (`_acpmux/review_queue`): every ask that
//! waits on the person, whatever harness asked, and the pull requests sessions opened that have
//! no review verdict yet, in one list sorted by what most needs the person.
//!
//! - Index, not scan: [`Index`] holds the sessions that may hold a pending ask (added from each
//!   `permission_request` / `permission_reissued` record in `Hub::append_record_locked`, with
//!   when it was asked and its turn) and the sessions with pull requests (from their meta when
//!   the session is made, and from `pull_requests::absorb` as one is opened). A read visits only
//!   those sessions: an ask whose session no longer holds it (answered, withdrawn, its agent
//!   gone) is dropped there, and a pull request older than [`PR_WINDOW_MS`] leaves the index.
//!   Idle sessions cost a read nothing.
//! - Kinds: `plan` (Claude Code's ExitPlanMode, Gemini's `exit_plan_mode` naming a plan file),
//!   `question` (an agent's question, `questions::needs_person`), else `approval`; `pr` for a
//!   pull request of a session whose turn is not running, opened within [`PR_WINDOW_MS`],
//!   without a review verdict in the audit log (`audit_log.rs`, `_acpmux/review_verdict`).
//! - Impact (an integer): a base for the kind ([`BASE_ASK`] for an ask, which blocks its turn:
//!   `blocksTurn`; [`BASE_PR`] for a pull request), plus [`PER_QUEUED`] per prompt queued behind
//!   the session (`queuedPrompts:N`, at most [`MAX_COUNTED`] counted), plus [`PER_DOLLAR`] per
//!   whole US dollar the session spent (`costUsd:X`, at most [`MAX_DOLLARS`] counted), plus
//!   [`PER_SUBSESSION`] per live sub-session waiting under it (`subsessions:N`, at most
//!   [`MAX_COUNTED`]). Each reason is listed in `impactReasons`.
//! - Score (the sort key, highest first): `impact * (1 + min(ageMs, 24 h) / 1 h)`, so an item
//!   waiting an hour counts twice what a new one of the same impact does, and age stops growing
//!   it after a day. Ties go to the older item.
//! - Answering stays on each kind's own path (the page sends `chat.permission` with the item's
//!   `sessionId`, `permissionId` and an option, as Needs you does); each item carries them.

use super::*;
use cmux_json::JsonSet as _;
use std::collections::HashMap;

/// A pull request older than this leaves the queue (and the index).
pub(crate) const PR_WINDOW_MS: u64 = 14 * 24 * 60 * 60 * 1000;
pub(crate) const BASE_ASK: u32 = 50;
pub(crate) const BASE_PR: u32 = 20;
pub(crate) const PER_QUEUED: u32 = 10;
pub(crate) const PER_SUBSESSION: u32 = 10;
pub(crate) const PER_DOLLAR: u32 = 2;
pub(crate) const MAX_COUNTED: u32 = 5;
pub(crate) const MAX_DOLLARS: u32 = 20;
/// The age past which an item's score stops growing.
const AGE_CAP_MS: u64 = 24 * 60 * 60 * 1000;
const HOUR_MS: f64 = 60.0 * 60.0 * 1000.0;
/// An item's `ask`, in characters.
pub(crate) const ASK_CHARS: usize = 200;
/// An item's `detail`, in characters.
const DETAIL_CHARS: usize = 400;
/// What of a long text is read before it is masked and cut.
const READ_CHARS: usize = 4096;
/// How long an ask a read no longer saw pending keeps its audit context for the decision record
/// that may still be on its way (`respond_permission` drops the pending entry before the record).
pub(crate) const SETTLE_MS: u64 = 60_000;
/// A read's items when the request names no limit.
pub(crate) const DEFAULT_LIMIT: usize = 200;
pub(crate) const MAX_LIMIT: usize = 1000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Kind {
    Approval,
    Plan,
    Question,
}

impl Kind {
    pub(crate) fn of(request: &Value) -> Kind {
        let tool = &request["toolCall"];
        if tool.pointer("/_meta/claude/tool").and_then(Value::as_str) == Some("ExitPlanMode")
            || super::gemini_plan::names_plan(tool)
        {
            Kind::Plan
        } else if super::is_question(request) {
            Kind::Question
        } else {
            Kind::Approval
        }
    }
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Kind::Approval => "approval",
            Kind::Plan => "plan",
            Kind::Question => "question",
        }
    }
}

/// An ask as its `permission_request` recorded it.
#[derive(Clone, Debug)]
pub(crate) struct Ask {
    /// Who settled it, when the decision record cannot say (`Index::mark_settled`).
    pub settled_by: Option<Settled>,
    pub at: u64,
    pub turn_id: Option<String>,
    pub request: Value,
    /// When the index learned it, to tell a read's lazy drop from a newer ask.
    noted: u64,
}

/// Who settled an ask when no one is named in its decision record.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Settled {
    /// The caller of `respond_permission` cancelled it (a question skipped, a card dismissed).
    Caller,
    /// Allowed by itself after a switch: `policy` (approve all) or `mode` (full access).
    Auto(&'static str),
}

#[derive(Clone, Debug)]
struct Pr {
    url: String,
    at: u64,
}

#[derive(Default)]
struct Inner {
    asks: HashMap<String, HashMap<String, Ask>>,
    /// Asks a read found no longer pending, by (session, permission), with when: out of the
    /// queue, but kept [`SETTLE_MS`] for the audit entry of a decision still being recorded.
    /// Reads never walk them; each read drops the expired ones.
    settling: HashMap<(String, String), (Ask, u64)>,
    prs: HashMap<String, Vec<Pr>>,
    noted: u64,
}

#[derive(Default)]
pub(crate) struct Index {
    inner: StdMutex<Inner>,
}

impl Index {
    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// A `permission_request` (or `permission_reissued`) record of `session`.
    pub(crate) fn note_ask(&self, session: &str, msg: &Value, at: u64) {
        let Some(id) = msg.get("permissionId").and_then(Value::as_str) else { return };
        let mut inner = self.lock();
        inner.noted += 1;
        let noted = inner.noted;
        let request = msg.get("request").cloned().unwrap_or(Value::Null);
        let asks = inner.asks.entry(session.to_owned()).or_default();
        // A reissue (which names no turn) keeps when it was first asked, and its turn.
        let turn_id = msg
            .get("turnId")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| asks.get(id).and_then(|a| a.turn_id.clone()));
        let at = asks.get(id).map_or(at, |a| a.at);
        let settled_by = asks.get(id).and_then(|a| a.settled_by);
        asks.insert(id.to_owned(), Ask { settled_by, at, turn_id, request, noted });
    }

    /// Who is settling `permission_id` of `session`, told before its reply is sent: the
    /// decision record that follows names no answerer for these.
    pub(crate) fn mark_settled(&self, session: &str, permission_id: &str, by: Settled) {
        let mut inner = self.lock();
        let key = (session.to_owned(), permission_id.to_owned());
        if let Some((a, _)) = inner.settling.get_mut(&key) {
            a.settled_by = Some(by);
        } else if let Some(a) = inner.asks.get_mut(session).and_then(|m| m.get_mut(permission_id)) {
            a.settled_by = Some(by);
        }
    }

    /// The ask a `permission_decision` record of `session` answered, taken out of the index.
    pub(crate) fn take_ask(&self, session: &str, permission_id: &str) -> Option<Ask> {
        let mut inner = self.lock();
        let key = (session.to_owned(), permission_id.to_owned());
        let settled = inner.settling.remove(&key).map(|(a, _)| a);
        let Some(asks) = inner.asks.get_mut(session) else { return settled };
        let ask = asks.remove(permission_id);
        if asks.is_empty() {
            inner.asks.remove(session);
        }
        ask.or(settled)
    }

    /// Drops the settling asks set aside before `now - SETTLE_MS`.
    fn expire_settling(&self, now: u64) {
        let mut inner = self.lock();
        if !inner.settling.is_empty() {
            inner.settling.retain(|_, (_, at)| now.saturating_sub(*at) < SETTLE_MS);
        }
    }

    /// The pull request at `url` that `session` opened at `at`.
    pub(crate) fn note_pr(&self, session: &str, url: &str, at: u64) {
        let mut inner = self.lock();
        let prs = inner.prs.entry(session.to_owned()).or_default();
        if !prs.iter().any(|p| p.url == url) {
            prs.push(Pr { url: url.to_owned(), at });
        }
    }

    /// Drops the pull requests of `session` past the window from its list as it is now (one
    /// noted since a read's snapshot stays), and the session once its list is empty or it is
    /// `gone`.
    pub(crate) fn prune_prs(&self, session: &str, now: u64, gone: bool) {
        let mut inner = self.lock();
        let Some(list) = inner.prs.get_mut(session) else { return };
        list.retain(|p| now.saturating_sub(p.at) <= PR_WINDOW_MS);
        if gone || list.is_empty() {
            inner.prs.remove(session);
        }
    }

    /// Sessions the index holds now: (asking, with pull requests).
    #[cfg(test)]
    pub(crate) fn sizes(&self) -> (usize, usize) {
        let inner = self.lock();
        (inner.asks.len(), inner.prs.len())
    }

    #[cfg(test)]
    pub(crate) fn settling(&self) -> usize {
        self.lock().settling.len()
    }
}

/// `vendor` of a session: the company whose models its harness runs, else the family.
pub(crate) fn vendor(family: Option<&str>, harness: &str, model: Option<&str>) -> String {
    let family = family.unwrap_or(harness);
    let by_model = || {
        let m = model?;
        let (provider, _) = m.split_once('/')?;
        (!provider.is_empty()).then(|| provider.to_owned())
    };
    match family {
        "claude" => "anthropic".into(),
        "codex" => "openai".into(),
        "gemini" => "google".into(),
        "opencode" | "pi" => by_model().unwrap_or_else(|| family.to_owned()),
        other => other.to_owned(),
    }
}

/// One line of `text`, its secrets masked, at most `max` characters.
pub(crate) fn line(text: &str, max: usize) -> String {
    let head = match text.char_indices().nth(READ_CHARS) {
        // The word the cut goes through is dropped, so a secret's head is never kept unmasked.
        Some((at, _)) => {
            let read = text.get(..at).unwrap_or("");
            read.rfind(char::is_whitespace).map_or("", |end| read.get(..end).unwrap_or(""))
        }
        None => text,
    };
    super::session::masked_preview(head, max)
}

/// What an ask asks, on one line: the question, else the tool call's title.
pub(crate) fn ask_text(kind: Kind, request: &Value) -> String {
    let title =
        request.pointer("/toolCall/title").and_then(Value::as_str).filter(|t| !t.is_empty());
    let text = match kind {
        Kind::Question => {
            super::question_prompt(request).map(str::to_owned).or(title.map(str::to_owned))
        }
        Kind::Plan => Some(title.map_or_else(|| "Approve the plan".to_owned(), str::to_owned)),
        Kind::Approval => title.map(str::to_owned),
    };
    line(&text.unwrap_or_else(|| "Permission".to_owned()), ASK_CHARS)
}

/// More of an ask, when its tool call says more than its title: the command, the plan.
fn detail(request: &Value) -> Option<String> {
    let input = request.pointer("/toolCall/rawInput")?;
    let text =
        ["command", "plan", "cmd", "path", "file_path", "url"].iter().find_map(|k| match input
            .get(*k)
        {
            Some(Value::String(s)) if !s.is_empty() => Some(s.clone()),
            Some(Value::Array(a)) => {
                let words: Vec<&str> = a.iter().filter_map(Value::as_str).collect();
                (!words.is_empty()).then(|| words.join(" "))
            }
            _ => None,
        })?;
    Some(line(&text, DETAIL_CHARS))
}

fn options(request: &Value) -> Vec<Value> {
    request["options"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|o| json!({"optionId": o["optionId"], "name": o["name"], "kind": o["kind"]}))
        .collect()
}

/// What makes a session's item matter, besides its kind.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(crate) struct Weight {
    pub queued: u64,
    pub cost_usd: f64,
    pub subsessions: u32,
}

/// The impact of an item (an ask when `ask`) and why.
pub(crate) fn impact(ask: bool, w: Weight) -> (u32, Vec<String>) {
    let mut reasons = Vec::new();
    let mut impact = if ask {
        reasons.push("blocksTurn".to_owned());
        BASE_ASK
    } else {
        BASE_PR
    };
    if w.queued > 0 {
        impact += PER_QUEUED * (w.queued.min(MAX_COUNTED as u64) as u32);
        reasons.push(format!("queuedPrompts:{}", w.queued));
    }
    let dollars = if w.cost_usd.is_finite() && w.cost_usd > 0.0 { w.cost_usd } else { 0.0 };
    if dollars >= 1.0 {
        impact += PER_DOLLAR * (dollars.floor().min(MAX_DOLLARS as f64) as u32);
    }
    if dollars > 0.0 {
        reasons.push(format!("costUsd:{dollars:.2}"));
    }
    if w.subsessions > 0 {
        impact += PER_SUBSESSION * w.subsessions.min(MAX_COUNTED);
        reasons.push(format!("subsessions:{}", w.subsessions));
    }
    (impact, reasons)
}

/// The sort key: `impact` weighted by age.
pub(crate) fn score(impact: u32, age_ms: u64) -> f64 {
    impact as f64 * (1.0 + age_ms.min(AGE_CAP_MS) as f64 / HOUR_MS)
}

/// Sorts `items` by score, highest first, older first on a tie, and keeps `limit`.
pub(crate) fn sort_items(items: &mut Vec<Value>, limit: usize) {
    let num = |v: &Value, k: &str| v.get(k).and_then(Value::as_f64).unwrap_or(0.0);
    items.sort_by(|a, b| {
        num(b, "score").total_cmp(&num(a, "score")).then(num(a, "at").total_cmp(&num(b, "at")))
    });
    items.truncate(limit);
}

/// The fields every item of a session shares.
struct Row {
    session_id: String,
    title: String,
    harness: String,
    vendor: String,
    workspace_id: Option<String>,
    weight: Weight,
}

impl Row {
    fn item(&self, id: String, kind: &str, ask: String, at: u64, now: u64) -> Value {
        let age = now.saturating_sub(at);
        let (impact, reasons) = impact(kind != "pr", self.weight);
        let mut v = json!({
            "id": id, "kind": kind, "sessionId": self.session_id, "title": self.title,
            "harness": self.harness, "vendor": self.vendor, "ask": ask, "at": at, "ageMs": age,
            "impact": impact, "impactReasons": reasons, "score": score(impact, age),
        });
        if let Some(w) = &self.workspace_id {
            v.set("workspaceId", json!(w));
        }
        v
    }
}

impl Hub {
    /// `session` made from its meta: its pull requests join the index at the time each was
    /// opened, or (for one kept before times were) the session's creation, never its last
    /// activity, so an old pull request does not come back into the window.
    pub(super) fn note_session_prs(&self, session: &Session) {
        let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        for url in &m.pull_requests {
            let at = m.pull_request_times.get(url).copied().unwrap_or(m.created_at);
            self.review_index.note_pr(&session.id, url, at);
        }
    }

    fn review_row(&self, session: &Session) -> Row {
        let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let model = current_model(&m);
        Row {
            session_id: session.id.clone(),
            title: m.title.clone().filter(|t| !t.is_empty()).unwrap_or_else(|| m.name.clone()),
            harness: m.harness.clone(),
            vendor: vendor(m.family.as_deref(), &m.harness, model.as_deref()),
            workspace_id: m.workspace_id.clone(),
            weight: Weight {
                queued: session.queued.load(Ordering::SeqCst),
                cost_usd: m.totals.as_ref().and_then(|t| t.cost_usd).unwrap_or(0.0),
                subsessions: 0,
            },
        }
    }

    /// This daemon's own queue items (no peer's), unsorted, and how many sessions the read
    /// visited.
    pub(crate) fn review_queue_local(&self, now: u64) -> (Vec<Value>, usize) {
        self.review_index.expire_settling(now);
        let (asking, with_prs, noted) = {
            let inner = self.review_index.lock();
            let asking: Vec<String> = inner.asks.keys().cloned().collect();
            let prs: Vec<(String, Vec<Pr>)> =
                inner.prs.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
            (asking, prs, inner.noted)
        };
        let mut items = Vec::new();
        let mut visited = 0;
        let lookup =
            |id: &str| self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
        for id in asking {
            visited += 1;
            let Some(session) = lookup(&id) else {
                self.drop_stale_asks(&id, &[], noted, now);
                continue;
            };
            let pending = session.pending_permissions();
            let held: Vec<&str> = pending.iter().map(|(k, _)| k.as_str()).collect();
            self.drop_stale_asks(&id, &held, noted, now);
            if pending.is_empty() {
                continue;
            }
            let mut row = self.review_row(&session);
            row.weight.subsessions = self.width_used(&session.id);
            let notes: HashMap<String, Ask> =
                self.review_index.lock().asks.get(&id).cloned().unwrap_or_default();
            for (permission_id, request) in pending {
                let kind = Kind::of(&request);
                let note = notes.get(&permission_id);
                let at = note.map_or(now, |n| n.at);
                let mut item = row.item(
                    format!("acpmux:{permission_id}"),
                    kind.as_str(),
                    ask_text(kind, &request),
                    at,
                    now,
                );
                item.set("permissionId", json!(permission_id));
                item.set("options", json!(options(&request)));
                if let Some(t) = note.and_then(|n| n.turn_id.as_ref()) {
                    item.set("turnId", json!(t));
                }
                if let Some(d) = detail(&request) {
                    item.set("detail", json!(d));
                }
                if kind != Kind::Approval {
                    item.set("question", request);
                }
                items.push(item);
            }
        }
        for (id, prs) in with_prs {
            visited += 1;
            let fresh: Vec<Pr> =
                prs.into_iter().filter(|p| now.saturating_sub(p.at) <= PR_WINDOW_MS).collect();
            let session = lookup(&id);
            self.review_index.prune_prs(&id, now, session.is_none());
            let Some(session) = session else { continue };
            if matches!(session.status(), SessionStatus::Running | SessionStatus::Waiting) {
                continue;
            }
            let mut row = self.review_row(&session);
            row.weight.subsessions = self.width_used(&session.id);
            for pr in fresh {
                if self.audit.reviewed(&id, &pr.url) {
                    continue;
                }
                let mut item = row.item(
                    format!("pr:{}", pr.url),
                    "pr",
                    line(&format!("Review {}", pr_label(&pr.url)), ASK_CHARS),
                    pr.at,
                    now,
                );
                item.set("prUrl", json!(pr.url));
                items.push(item);
            }
        }
        (items, visited)
    }

    /// Moves the asks of session `id` the index learned at or before `noted` that it no longer
    /// holds (`held`) out of the queue's index into `settling`: one learned after the read began
    /// stays for the next read, and a decision record that comes after still finds its ask.
    fn drop_stale_asks(&self, id: &str, held: &[&str], noted: u64, now: u64) {
        let mut inner = self.review_index.lock();
        let Some(asks) = inner.asks.get_mut(id) else { return };
        let stale: Vec<String> = asks
            .iter()
            .filter(|(k, a)| a.noted <= noted && !held.contains(&k.as_str()))
            .map(|(k, _)| k.clone())
            .collect();
        let mut moved = Vec::with_capacity(stale.len());
        for k in stale {
            if let Some(a) = asks.remove(&k) {
                moved.push((k, a));
            }
        }
        if asks.is_empty() {
            inner.asks.remove(id);
        }
        for (k, a) in moved {
            inner.settling.insert((id.to_owned(), k), (a, now));
        }
    }
}

/// `owner/name#N` of a pull request URL, else the URL.
fn pr_label(url: &str) -> String {
    let rest = url.strip_prefix("https://github.com/").unwrap_or(url);
    let parts: Vec<&str> = rest.split('/').collect();
    match parts.as_slice() {
        [owner, name, "pull", n, ..] => format!("{owner}/{name}#{n}"),
        _ => url.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_prune_keeps_a_pull_request_noted_after_the_snapshot() {
        let index = Index::default();
        index.note_pr("s1", "https://github.com/o/r/pull/1", 0);
        // A read's snapshot saw only the expired one; a new one is noted before its prune.
        let now = PR_WINDOW_MS + 10;
        index.note_pr("s1", "https://github.com/o/r/pull/2", now);
        index.prune_prs("s1", now, false);
        assert_eq!(index.sizes().1, 1);
        assert_eq!(index.lock().prs["s1"].len(), 1);
        assert_eq!(index.lock().prs["s1"][0].url, "https://github.com/o/r/pull/2");
        index.prune_prs("s1", now + PR_WINDOW_MS + 1, false);
        assert_eq!(index.sizes().1, 0);
    }

    #[test]
    fn kinds_are_plan_question_or_approval() {
        let plan =
            json!({"toolCall": {"kind": "other", "_meta": {"claude": {"tool": "ExitPlanMode"}}}});
        assert_eq!(Kind::of(&plan), Kind::Plan);
        let gemini = json!({"toolCall": {"kind": "other", "title": "Requesting plan approval for: plans/p.md"}});
        assert_eq!(Kind::of(&gemini), Kind::Plan);
        let question = json!({"toolCall": {"kind": "other", "_meta": {"claude": {"tool": "AskUserQuestion"}},
            "rawInput": {"questions": [{"question": "Which?", "options": [{"label": "a"}]}]}}});
        assert_eq!(Kind::of(&question), Kind::Question);
        assert_eq!(ask_text(Kind::Question, &question), "Which?");
        let tool = json!({"toolCall": {"kind": "execute", "title": "Run ls",
            "rawInput": {"command": "ls -la"}}, "options": [{"optionId": "a", "name": "Allow", "kind": "allow_once"}]});
        assert_eq!(Kind::of(&tool), Kind::Approval);
        assert_eq!(ask_text(Kind::Approval, &tool), "Run ls");
        assert_eq!(detail(&tool).as_deref(), Some("ls -la"));
    }

    #[test]
    fn an_ask_is_one_masked_line() {
        let secret = "ghp_aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jSaZ3k";
        let tool =
            json!({"toolCall": {"kind": "execute", "title": format!("Run\n  curl -H {secret}")}});
        let ask = ask_text(Kind::Approval, &tool);
        assert!(!ask.contains('\n'), "{ask}");
        assert!(!ask.contains(secret), "{ask}");
        assert!(ask.chars().count() <= ASK_CHARS + 1);
    }

    #[test]
    fn impact_and_score_follow_the_documented_formula() {
        let (i, r) = impact(true, Weight::default());
        assert_eq!((i, r), (BASE_ASK, vec!["blocksTurn".to_owned()]));
        let w = Weight { queued: 7, cost_usd: 3.5, subsessions: 2 };
        let (i, r) = impact(true, w);
        assert_eq!(i, BASE_ASK + PER_QUEUED * MAX_COUNTED + PER_DOLLAR * 3 + PER_SUBSESSION * 2);
        assert_eq!(r, vec!["blocksTurn", "queuedPrompts:7", "costUsd:3.50", "subsessions:2"]);
        assert_eq!(impact(false, Weight::default()).0, BASE_PR);
        assert_eq!(score(50, 0), 50.0);
        assert_eq!(score(50, 3_600_000), 100.0);
        assert_eq!(score(50, 10 * AGE_CAP_MS), score(50, AGE_CAP_MS));
    }

    #[test]
    fn the_queue_sorts_by_score_then_age() {
        let mut items = vec![
            json!({"id": "new-low", "score": 20.0, "at": 5}),
            json!({"id": "high", "score": 90.0, "at": 9}),
            json!({"id": "old-low", "score": 20.0, "at": 1}),
        ];
        sort_items(&mut items, 2);
        let ids: Vec<_> = items.iter().map(|i| i["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["high", "old-low"]);
    }

    #[test]
    fn vendors_follow_the_family_or_the_models_provider() {
        assert_eq!(vendor(Some("claude"), "claude", None), "anthropic");
        assert_eq!(vendor(Some("codex"), "codex", None), "openai");
        assert_eq!(vendor(None, "gemini", None), "google");
        assert_eq!(vendor(Some("opencode"), "opencode", Some("openrouter/x")), "openrouter");
        assert_eq!(vendor(Some("pi"), "pi", None), "pi");
        assert_eq!(vendor(Some("grok"), "grok", None), "grok");
    }

    #[test]
    fn pr_labels_name_the_repository_and_number() {
        assert_eq!(pr_label("https://github.com/o/r/pull/12"), "o/r#12");
        assert_eq!(pr_label("weird"), "weird");
    }
}
