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
//! A task for a peer's session, and a lane that closes with its task open, are not here yet.

use super::{Hub, PromptOptions};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::sync::Arc;

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

/// Whether task `row` is still to be done: its lane works on it, or it is blocked.
pub(crate) fn open(row: &Value) -> bool {
    matches!(row.get("status").and_then(Value::as_str), Some("starting" | "running" | "blocked"))
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
        let lane_name = self.session_name(lane);
        let provenance = crate::prompt_provenance::task_result(
            lane,
            &lane_name,
            &giver.id,
            &id,
            result["state"].as_str().unwrap_or_default(),
        );
        let opts = PromptOptions {
            prompt_id: Some(format!("task-result-{id}-{}", result["at"])),
            resend: true,
            provenance: Some(provenance),
            ..PromptOptions::default()
        };
        let at = result["at"].clone();
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

    /// Records on task `id` that the card of its result made `at` did not reach the chat that
    /// gave it, and why: the result stays in the ledger, and `acpmux task ls` shows it was not
    /// delivered. Nothing when the task has a newer result since.
    fn result_undelivered(&self, id: &str, at: &Value, why: &str) {
        self.briefs.update(id, |r| {
            if &r["result"]["at"] == at {
                r["result"]["undelivered"] = json!(why);
            }
        });
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
