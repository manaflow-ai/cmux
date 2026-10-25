//! Tasks (leo-workspace research/2026-10-24-acpmux-tasks-liveness-urgency.md): a brief
//! (`dispatch.rs`) one session gives another, and its typed result back to the giver.
//!
//! - `acpmux task new SESSION TITLE` (`_acpmux/task_new`) writes a brief for a session already
//!   on this daemon (`dispatch` starts a new one), records the giver's session id
//!   (`fromSession`) beside its name, and sends the session the brief with the task id first.
//! - The lane ends it with one call, `acpmux task done|blocked|failed ID --summary …`
//!   (`_acpmux/report`): a result `{state, summary, prs, shas, why?, at, by}`, checked here. The
//!   same call again is a replay: one result, one card (sent again only if it was not
//!   delivered: the row's `result.undelivered` says why, and `task ls` shows it).
//! - The result goes to the giver's chat once, as one prompt with provenance `task_result`
//!   (`prompt_provenance.rs`): the chat draws it as the lane's card. That card is the lane's
//!   whole reply; nothing acknowledges it.
//!
//! - A lane that closes, or is deleted, with its task still open orphans it: the task's state
//!   becomes `orphaned`, and the giver gets its card at once, steered into a running turn
//!   ("Task T "…" orphaned: codex-lane closed with it still open"). `task ls` lists orphans
//!   first. A later result, from the giver or a revived lane, still ends it. The close itself
//!   decides (`Hub::kill` → `orphan_tasks_of`), never a later look at what is loaded, so a start
//!   that loads no sessions orphans nothing. The ledger row is written first, its card owed
//!   (`result.cardOwed`) until the giver's chat accepts it; `watch_orphans` sends owed cards on
//!   the close's event, at the start (a card a crash left owed) and after a lag, one send at a
//!   time per card (`result.cardSending`), and the card's prompt id makes a send after a crash a
//!   duplicate.
//! - Not here yet, with peer-hosted tasks: a lane that moves to another daemon. A lane in a move
//!   (`moving`), one whose move committed (its log's latest move record is `transferred`), one
//!   coming back in place of its closed copy (`replaced`), and one whose log cannot be read are
//!   never orphaned: the task stays open, and `task ls` shows the lane's state.
//!
//! A task for a peer's session is not here yet.

use super::{Hub, PromptOptions};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::sync::broadcast;

/// The states a lane ends its task in.
pub(crate) const RESULT_STATES: &[&str] = &["done", "blocked", "failed"];
/// Longest summary, in characters: one line; the detail goes in the PR.
const MAX_SUMMARY_CHARS: usize = 300;
/// Longest reason a task is blocked or failed, in characters.
const MAX_WHY_CHARS: usize = 1000;
/// Most PRs, and most SHAs, one result names.
const MAX_REFS: usize = 20;
/// Longest PR URL, in bytes.
const MAX_URL_BYTES: usize = 256;

fn refused(message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message.into()).with_data(json!({"reason": "task.result_invalid"}))
}

/// Whether task `row` is still to be done: its lane works on it, it is blocked, or its lane
/// closed with it open.
pub(crate) fn open(row: &Value) -> bool {
    worked_on(row) || orphaned(row)
}

/// Whether task `row`'s lane still has it: it works on it, or it is blocked.
fn worked_on(row: &Value) -> bool {
    row.get("kind").and_then(Value::as_str) == Some("task")
        && matches!(
            row.get("status").and_then(Value::as_str),
            Some("starting" | "running" | "blocked")
        )
}

/// Whether task `row`'s lane closed with it open (module docs).
pub(crate) fn orphaned(row: &Value) -> bool {
    row.get("status").and_then(Value::as_str) == Some("orphaned")
}

/// The result the `_acpmux/report` `params` give for `state`, reported by `by`, or why not.
pub(crate) fn result(params: &Value, state: &str, by: &str) -> Result<Value, RpcError> {
    let text = |key: &str| {
        params.get(key).and_then(Value::as_str).map(str::trim).filter(|t| !t.is_empty())
    };
    let summary = text("summary").ok_or_else(|| refused("a task result has a --summary"))?;
    if summary.contains('\n') || summary.chars().count() > MAX_SUMMARY_CHARS {
        return Err(refused(format!(
            "--summary is one line of at most {MAX_SUMMARY_CHARS} characters; the detail goes in the PR"
        )));
    }
    let why = text("why");
    if state != "done" && why.is_none() {
        return Err(refused(format!("a {state} task says why: --why \"what stops it\"")));
    }
    if why.is_some_and(|why| why.chars().count() > MAX_WHY_CHARS) {
        return Err(refused(format!("--why is at most {MAX_WHY_CHARS} characters")));
    }
    let list = |key: &str, fits: fn(&str) -> bool, what: &str| -> Result<Vec<String>, RpcError> {
        let items = match params.get(key) {
            None | Some(Value::Null) => return Ok(Vec::new()),
            Some(Value::Array(items)) if items.len() <= MAX_REFS => items,
            Some(_) => return Err(refused(format!("{key} is a list of at most {MAX_REFS}"))),
        };
        let item = |v: &Value| v.as_str().map(str::trim).filter(|s| fits(s)).map(str::to_owned);
        items.iter().map(|v| item(v).ok_or_else(|| refused(format!("{v} is not {what}")))).collect()
    };
    let prs = list("prs", is_url, "a PR's https URL")?;
    let shas = list("shas", is_sha, "a commit SHA (7 to 40 hex digits)")?;
    let mut result = json!({
        "state": state, "summary": summary, "prs": prs, "shas": shas,
        "at": crate::store::now_ms(), "by": by,
    });
    if let Some(why) = why {
        result["why"] = json!(why);
    }
    Ok(result)
}

fn is_url(s: &str) -> bool {
    s.len() <= MAX_URL_BYTES
        && s.strip_prefix("https://").is_some_and(|rest| !rest.is_empty())
        && !s.chars().any(|c| c.is_whitespace() || c.is_control())
}

fn is_sha(s: &str) -> bool {
    (7..=40).contains(&s.len()) && s.chars().all(|c| c.is_ascii_hexdigit())
}

/// Whether results `a` and `b` say the same, whenever, by whoever and whether delivered: a
/// retry of one call.
pub(crate) fn same_result(a: &Value, b: &Value) -> bool {
    ["state", "summary", "prs", "shas", "why"].iter().all(|key| a.get(key) == b.get(key))
}

/// The prompt task `row`'s lane gets: the task id first, then how to end it in one call.
pub(crate) fn brief_text(row: &Value) -> String {
    let field = |key: &str| row.get(key).and_then(Value::as_str).unwrap_or_default();
    let id = field("briefId");
    format!(
        "Task {id} from {from}: {title}\n\n{brief}\n\nDone when: {stop}\n\n\
         Finish with one call; it is your whole reply, so send nothing else:\n\
         acpmux task done {id} --summary \"one line\" [--pr URL]... [--sha SHA]...\n\
         If you can't finish it: acpmux task blocked {id} --summary \"one line\" --why \"what stops it\" \
         (or task failed).",
        from = field("from"),
        title = field("title"),
        brief = field("brief"),
        stop = field("stopCondition"),
    )
}

/// The card's text: the result as the giver reads it, and who ended the task when its lane
/// (named `lane`) did not.
fn card_text(row: &Value, result: &Value, lane: &str) -> String {
    fn field<'a>(v: &'a Value, key: &str) -> &'a str {
        v.get(key).and_then(Value::as_str).unwrap_or_default()
    }
    let mut text = format!(
        "Task {} \"{}\" {}: {}",
        field(row, "briefId"),
        field(row, "title"),
        field(result, "state"),
        field(result, "summary"),
    );
    for (key, label) in [("prs", "PR"), ("shas", "SHA")] {
        for item in result[key].as_array().into_iter().flatten().filter_map(Value::as_str) {
            text.push_str(&format!("\n{label}: {item}"));
        }
    }
    if let Some(why) = result.get("why").and_then(Value::as_str) {
        text.push_str(&format!("\nWhy: {why}"));
    }
    let by = field(result, "by");
    if !by.is_empty() && by != lane {
        text.push_str(&format!("\nEnded by: {by}"));
    }
    text
}

impl Hub {
    /// Sends task `row`'s result to the chat that gave it, once per result: steered into its
    /// running turn, else started or queued, as an agent's message is. Nothing when no chat here
    /// gave it, or when that chat reported it itself (`reporter`).
    pub(crate) fn send_task_result(self: &Arc<Self>, row: &Value, reporter: Option<&str>) {
        let Some(to) = row.get("fromSession").and_then(Value::as_str) else { return };
        if reporter == Some(to) {
            return;
        }
        let id = row.get("briefId").and_then(Value::as_str).unwrap_or_default().to_owned();
        let Ok(giver) = self.resolve(to) else {
            self.result_undelivered(&id, &row["result"]["at"], "the chat that gave it is gone");
            return;
        };
        let field = |key: &str| row.get(key).and_then(Value::as_str).unwrap_or_default();
        let (lane, result) = (field("sessionId"), &row["result"]);
        // A lane deleted since keeps the name the task was given to.
        let lane_name = match self.session_name(lane) {
            name if name == lane && !field("to").is_empty() => field("to").to_owned(),
            name => name,
        };
        let provenance = crate::prompt_provenance::task_result(
            lane,
            &lane_name,
            &giver.id,
            &id,
            result["state"].as_str().unwrap_or_default(),
        );
        let at = result["at"].clone();
        let (hub, card) = (self.clone(), (id.clone(), at.clone()));
        let opts = PromptOptions {
            prompt_id: Some(format!("task-result-{id}-{}", result["at"])),
            resend: true,
            provenance: Some(provenance),
            // Accepted, or a duplicate of one accepted before: an orphan card is no longer owed.
            on_accepted: Some(Box::new(move |_| hub.card_sent(&card.0, &card.1))),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": card_text(row, result, &lane_name)})];
        let hub = self.clone();
        // Off the report's path: the call returns, and the giver's turn runs.
        tokio::spawn(async move {
            if let Err(e) = hub.prompt_with(&giver, blocks, "acpmux", true, opts).await {
                tracing::warn!(session = %giver.id, "task result: {}", e.message);
                hub.result_undelivered(&id, &at, &e.message);
            }
        });
    }

    /// Orphans every open task of `session`, a lane that ends now: closed, or deleted when
    /// `deleted` (module docs). Called by `Hub::kill`, under no lock; nothing for a chat that
    /// moved on (`replaced`, `moved_on`). Each row's card is owed until the giver accepts it.
    pub(super) fn orphan_tasks_of(&self, session: &super::Session, deleted: bool) {
        // A lane in a move, or coming back here in place of its copy (module docs).
        if session.replaced.load(std::sync::atomic::Ordering::SeqCst) || session.moving().is_some()
        {
            return;
        }
        let mine = |row: &Value| worked_on(row) && row["sessionId"] == session.id.as_str();
        let rows = self.briefs.matching(mine);
        if rows.is_empty() {
            return;
        }
        match self.moved_on(&session.id) {
            Ok(false) => {}
            Ok(true) => return,
            // Unread, it may have moved on: the task stays as it is (module docs).
            Err(e) => {
                tracing::warn!(lane = %session.id, "a closing lane's moves could not be read: {e}");
                return;
            }
        }
        let gone = if deleted { "is gone" } else { "closed" };
        for row in rows {
            let lane_name = row.get("to").and_then(Value::as_str).unwrap_or(&session.id).to_owned();
            let result = json!({
                "state": "orphaned", "summary": format!("{lane_name} {gone} with it still open"),
                "prs": [], "shas": [], "at": crate::store::now_ms(), "by": lane_name,
                "cardOwed": true,
            });
            let id = row.get("briefId").and_then(Value::as_str).unwrap_or_default();
            // Under the ledger's lock: a result reported meanwhile wins.
            self.briefs.update(id, |r| {
                if worked_on(r) {
                    r["status"] = json!("orphaned");
                    r["result"] = result.clone();
                }
            });
            tracing::warn!(task = %id, lane = %session.id, "a task's lane {gone} with it open");
        }
    }

    /// Whether chat `id` moved to another daemon: its log's latest move record is its commit
    /// here (`transferred`), not an arrival (`transferred_in`). Read from the log, so it holds
    /// after a restart, when `moving` is gone.
    fn moved_on(&self, id: &str) -> anyhow::Result<bool> {
        let mut away = false;
        let kinds = ["transferred", "transferred_in"];
        self.store.scan_kinds(id, &kinds, &mut |e: crate::store::EventRecord| {
            away = e.kind == "transferred";
            true
        })?;
        Ok(away)
    }

    /// Sends the cards orphaned tasks owe (module docs) on each local close or delete, at the
    /// start and after a lag. Ends when the hub's event channel closes or the hub is dropped.
    pub(super) fn watch_orphans(self: &Arc<Self>) {
        let mut events = self.subscribe();
        // The start's pass runs before the hub is handed out: a card a crash left owed.
        self.send_owed_cards(true);
        let hub = Arc::downgrade(self);
        tokio::spawn(async move {
            loop {
                match events.recv().await {
                    Ok(ev) => {
                        let rec = &ev.record;
                        let closed = rec.kind == "status" && rec.msg["status"] == "closed";
                        if rec.dir != "mux"
                            || ev.remote.is_some()
                            || !(closed || rec.kind == "purged")
                        {
                            continue;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => return,
                }
                let Some(hub) = hub.upgrade() else { return };
                hub.send_owed_cards(false);
            }
        });
    }

    /// Sends each owed orphan card, one send at a time: a pass claims a card (`cardSending`)
    /// under the ledger's lock, and its acceptance (`card_sent`) or refusal (`result_undelivered`)
    /// ends the claim; the owed mark goes only on acceptance. The start's pass (`start`) takes
    /// every card, since no send outlives the process that made it; the card's prompt id makes a
    /// send the giver had before a crash a duplicate. A card whose giver is not loaded (a start
    /// whose session list failed loads none) waits for a later pass.
    fn send_owed_cards(self: &Arc<Self>, start: bool) {
        let owed = |row: &Value| orphaned(row) && row["result"]["cardOwed"] == true;
        for row in self.briefs.matching(owed) {
            let giver = row.get("fromSession").and_then(Value::as_str).unwrap_or_default();
            if self.resolve(giver).is_err() {
                continue;
            }
            let id = row.get("briefId").and_then(Value::as_str).unwrap_or_default();
            let mut mine = false;
            let row = self.briefs.update(id, |r| {
                if owed(r) && (start || r["result"]["cardSending"] != true) {
                    r["result"]["cardSending"] = json!(true);
                    mine = true;
                }
            });
            if let Some(row) = row.filter(|_| mine) {
                self.send_task_result(&row, None);
            }
        }
    }

    /// Ends the claim and the owed mark of task `id`'s result made `at` (`send_owed_cards`),
    /// once its card reached the giver's chat. Nothing when the task has a newer result since.
    fn card_sent(&self, id: &str, at: &Value) {
        self.card_claim_ends(id, at, true);
    }

    /// Ends a send's claim on task `id`'s card made `at`; `delivered` also clears its owed mark.
    fn card_claim_ends(&self, id: &str, at: &Value, delivered: bool) {
        if self.briefs.get(id).is_none_or(|r| r["result"]["cardSending"] != true) {
            return;
        }
        self.briefs.update(id, |r| {
            if &r["result"]["at"] == at
                && let Some(result) = r["result"].as_object_mut()
            {
                result.remove("cardSending");
                if delivered {
                    result.remove("cardOwed");
                }
            }
        });
    }

    /// Records on task `id` that the card of its result made `at` did not reach the chat that
    /// gave it, and why: the result stays in the ledger, and `acpmux task ls` shows it was not
    /// delivered. Nothing when the task has a newer result since.
    fn result_undelivered(&self, id: &str, at: &Value, why: &str) {
        self.briefs.update(id, |r| {
            if &r["result"]["at"] == at {
                r["result"]["undelivered"] = json!(why);
            }
        });
        // An owed card stays owed, for a later pass.
        self.card_claim_ends(id, at, false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_result_is_one_checked_line_with_its_refs() {
        let ok = json!({"summary": " Merged ", "prs": ["https://github.com/o/r/pull/1"], "shas": ["abc1234"]});
        let result = super::result(&ok, "done", "lane").expect("a done result");
        assert_eq!(result["summary"], "Merged");
        assert_eq!(result["prs"], json!(["https://github.com/o/r/pull/1"]));
        assert_eq!(result["by"], "lane");
        for bad in [
            json!({}),
            json!({"summary": "two\nlines"}),
            json!({"summary": "x", "prs": ["github.com/o/r/pull/1"]}),
            json!({"summary": "x", "prs": "https://github.com/o/r/pull/1"}),
            json!({"summary": "x", "shas": ["abc12"]}),
            json!({"summary": "x", "shas": ["not-a-sha"]}),
        ] {
            assert!(super::result(&bad, "done", "lane").is_err(), "{bad}");
        }
        // A blocked or failed task says why.
        assert!(super::result(&json!({"summary": "x"}), "blocked", "lane").is_err());
        let blocked = super::result(&json!({"summary": "x", "why": "CI is down"}), "blocked", "l");
        assert_eq!(blocked.expect("blocked")["why"], "CI is down");
    }

    #[test]
    fn the_same_call_again_is_the_same_result() {
        let params = json!({"summary": "Merged", "shas": ["abc1234"]});
        let first = result(&params, "done", "lane").unwrap();
        let again = result(&params, "done", "someone").unwrap();
        assert!(same_result(&first, &again));
        let failed = json!({"summary": "Merged", "shas": ["abc1234"], "why": "reverted"});
        assert!(!same_result(&first, &result(&failed, "failed", "lane").unwrap()));
        let other = result(&json!({"summary": "Merged too"}), "done", "lane").unwrap();
        assert!(!same_result(&first, &other));
    }
}
