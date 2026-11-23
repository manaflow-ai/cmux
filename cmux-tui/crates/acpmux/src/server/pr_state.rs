//! `_acpmux/pr_state {sessionId, pr}`: one pull request's state for a chat's card, the read the
//! `pr_state` tool makes (`acpmux_mcp_pr.rs`), answered by this daemon for a client that has no
//! GitHub login of its own: the iPhone app's Feed and workspace rows (manaflow-ai/cmux#51332)
//! show a chat's pull request with its checks, mergeability and whether it merged.
//!
//! - Read only: one fixed `gh pr view <pr> --json <fields>` with this Mac's own `gh` login, in the
//!   chat's folder. No other `gh` command is reachable, and `pr` must be a number, `#number` or a
//!   `https://github.com/OWNER/REPO/pull/N` link (`acpmux_mcp_pr::target`, which refuses anything else).
//! - Named by a chat (`sessionId`), so a remote client reaches it only for a chat it may see (the
//!   iPhone host's session checks); a chat on a peer is not forwarded.
//! - The answer is the tool's `structuredContent` (`summary`, `status`, `state`, `mergeable`,
//!   failing, pending and passed checks, the review receipt) plus `url` and `title`. One call per
//!   pull request: the phone keeps the answer and asks again only after minutes.

use crate::acpmux_mcp::pr;
use crate::hub::Hub;
use crate::rpc::RpcError;
use serde_json::{Value, json};

pub(super) async fn handle(hub: &Hub, params: &Value) -> Result<Value, RpcError> {
    let session = hub.resolve(super::session_key(params)?)?;
    let target = pr::target(params).map_err(RpcError::invalid_params)?;
    let cwd = session.meta().cwd;
    let mut args = pr::gh_args(&target);
    // The tool's fields and the card's title.
    if let Some(fields) = args.last_mut() {
        fields.push_str(",title,isDraft");
    }
    let out = pr::run_gh(&args, cwd.is_dir().then_some(cwd)).await.map_err(RpcError::internal)?;
    let view: Value = serde_json::from_slice(&out)
        .map_err(|e| RpcError::internal(format!("gh pr view gave no JSON: {e}")))?;
    Ok(answer(&view))
}

/// The answer for `gh pr view --json` output `view`: the tool's structured state, its link and
/// title, and `draft` for a draft.
pub(crate) fn answer(view: &Value) -> Value {
    let (_, mut structured) = pr::pr_state(view);
    if let Some(object) = structured.as_object_mut() {
        object.insert("url".into(), view.get("url").cloned().unwrap_or(Value::Null));
        object.insert("title".into(), view.get("title").cloned().unwrap_or(Value::Null));
        object.insert("draft".into(), json!(view.get("isDraft").and_then(Value::as_bool) == Some(true)));
    }
    structured
}

#[cfg(test)]
mod tests {
    use super::answer;
    use serde_json::json;

    #[test]
    fn an_open_pull_request_with_green_checks_answers_mergeable() {
        let view = json!({
            "number": 51400, "url": "https://github.com/manaflow-ai/cmux/pull/51400", "title": "Feed cards",
            "state": "OPEN", "isDraft": false, "headRefOid": "abc123def456", "baseRefName": "feat-cmux-next",
            "mergeable": "MERGEABLE", "labels": [], "body": "", "comments": [],
            "statusCheckRollup": [{"__typename": "CheckRun", "name": "kit", "status": "COMPLETED", "conclusion": "SUCCESS"}],
        });
        let out = answer(&view);
        assert_eq!(out["state"], "open");
        assert_eq!(out["mergeable"], "mergeable");
        assert_eq!(out["passedChecks"], 1);
        assert_eq!(out["status"], "ok");
        assert_eq!(out["title"], "Feed cards");
        assert_eq!(out["url"], "https://github.com/manaflow-ai/cmux/pull/51400");
        assert_eq!(out["draft"], false);
    }

    #[test]
    fn a_merged_pull_request_says_merged() {
        let view = json!({
            "number": 7, "url": "https://github.com/o/r/pull/7", "title": "x", "state": "MERGED",
            "mergeCommit": {"oid": "f0175fe0aaaa"}, "headRefOid": "aa", "mergeable": "UNKNOWN",
            "statusCheckRollup": [], "comments": [], "labels": [],
        });
        assert_eq!(answer(&view)["state"], "merged");
    }
}
