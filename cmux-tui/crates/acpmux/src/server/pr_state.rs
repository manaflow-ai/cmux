//! `_acpmux/pr_state {sessionId, pr}`: one pull request's state for a chat's card, the read the
//! `pr_state` tool makes (`acpmux_mcp_pr.rs`), answered by this daemon for a client that has no
//! GitHub login of its own: the iPhone app's Feed and workspace rows (manaflow-ai/cmux#51332)
//! show a chat's pull request with its checks, mergeability and whether it merged.
//!
//! - Read only: one fixed `gh pr view <pr> --json <fields>` with this Mac's own `gh` login, in the
//!   chat's folder. No other `gh` command is reachable, and `pr` must be a number, `#number` or a
//!   `https://github.com/OWNER/REPO/pull/N` link (`acpmux_mcp_pr::target`, which refuses anything else).
//! - Named by a chat (`sessionId`), so a remote client reaches it only for a chat it may see (the
//!   iPhone host's session checks), and only for a pull request of that chat's own repository (its
//!   folder's `origin`): never another repository this Mac's login can read. A chat on a peer is
//!   not forwarded (`peer_forward.rs`): the read is this Mac's.
//! - At most two `gh` runs at once, whoever asks.
//! - The answer is the tool's `structuredContent` (`summary`, `status`, `state`, `mergeable`,
//!   failing, pending and passed checks, the review receipt) plus `url` and `title`. One call per
//!   pull request: the phone keeps the answer and asks again only after minutes.

use crate::acpmux_mcp::pr;
use crate::hub::Hub;
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::path::Path;
use std::sync::LazyLock;
use tokio::sync::Semaphore;

/// `gh` runs at most this many at once for this request, whoever asks: a client cannot make the
/// Mac spawn more (each may run up to the tool's 45 s deadline).
const AT_ONCE: usize = 2;
static SLOTS: LazyLock<Semaphore> = LazyLock::new(|| Semaphore::new(AT_ONCE));

/// `local`: the request came over this Mac's unix socket. Any other caller (the iPhone host, the
/// Web) gets only a pull request of the chat's own repository, named by number or by its
/// github.com link, and no `gh` error text.
pub(super) async fn handle(hub: &Hub, params: &Value, local: bool) -> Result<Value, RpcError> {
    let session = hub.resolve(super::session_key(params)?)?;
    let cwd = session.meta().cwd;
    let cwd = cwd.is_dir().then_some(cwd);
    let target = if local {
        pr::target(params).map_err(RpcError::invalid_params)?
    } else {
        remote_target(params, cwd.as_deref()).await?
    };
    let mut args = pr::gh_args(&target);
    // The tool's fields and the card's title.
    if let Some(fields) = args.last_mut() {
        fields.push_str(",title,isDraft");
    }
    let _slot =
        SLOTS.acquire().await.map_err(|_| RpcError::internal("pr_state is shutting down"))?;
    let out = pr::run_gh(&args, cwd).await.map_err(|e| {
        if local {
            RpcError::internal(e)
        } else {
            RpcError::internal("gh could not read the pull request")
        }
    })?;
    let view: Value = serde_json::from_slice(&out)
        .map_err(|e| RpcError::internal(format!("gh pr view gave no JSON: {e}")))?;
    Ok(answer(&view))
}

/// A remote caller's target: `pr` only (its `repo` is ignored), a github.com link's repository
/// must be the chat folder's `origin`, and a bare number reads that origin's.
async fn remote_target(params: &Value, cwd: Option<&Path>) -> Result<pr::Target, RpcError> {
    let raw = params.get("pr").and_then(Value::as_str).unwrap_or_default().trim().to_owned();
    if raw.contains("://") && !raw.starts_with("https://github.com/") {
        return Err(RpcError::invalid_params("pr must be a github.com pull request link"));
    }
    let only_pr = json!({"pr": params.get("pr").cloned().unwrap_or(Value::Null)});
    let target = pr::target(&only_pr).map_err(RpcError::invalid_params)?;
    let Some(asked) = target.repo.as_deref() else { return Ok(target) };
    let origin = match cwd {
        Some(cwd) => origin_repo(cwd).await,
        None => None,
    };
    if origin.as_deref().is_some_and(|origin| origin.eq_ignore_ascii_case(asked)) {
        Ok(target)
    } else {
        Err(RpcError::invalid_params("the pull request is not of this chat's repository"))
    }
}

/// `OWNER/REPO` of the folder's `origin` remote on github.com (`git remote get-url origin`).
async fn origin_repo(cwd: &Path) -> Option<String> {
    let out = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        tokio::process::Command::new("git")
            .args(["remote", "get-url", "origin"])
            .current_dir(cwd)
            .stdin(std::process::Stdio::null())
            .kill_on_drop(true)
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    let url = String::from_utf8_lossy(&out.stdout);
    out.status.success().then(|| github_repo(url.trim())).flatten()
}

/// `OWNER/REPO` of a github.com remote URL (https or ssh), without `.git`.
pub(crate) fn github_repo(url: &str) -> Option<String> {
    let rest = url
        .strip_prefix("https://github.com/")
        .or_else(|| url.strip_prefix("git@github.com:"))
        .or_else(|| url.strip_prefix("ssh://git@github.com/"))?;
    let rest = rest.trim_end_matches('/');
    let rest = rest.strip_suffix(".git").unwrap_or(rest);
    let (owner, repo) = rest.split_once('/')?;
    (!owner.is_empty() && !repo.is_empty() && !repo.contains('/'))
        .then(|| format!("{owner}/{repo}"))
}

/// The answer for `gh pr view --json` output `view`: the tool's structured state, its link and
/// title, and `draft` for a draft.
pub(crate) fn answer(view: &Value) -> Value {
    let (_, mut structured) = pr::pr_state(view);
    if let Some(object) = structured.as_object_mut() {
        object.insert("url".into(), view.get("url").cloned().unwrap_or(Value::Null));
        object.insert("title".into(), view.get("title").cloned().unwrap_or(Value::Null));
        let draft = view.get("isDraft").and_then(Value::as_bool) == Some(true);
        object.insert("draft".into(), json!(draft));
    }
    structured
}

#[cfg(test)]
mod tests {
    use super::{answer, github_repo};
    use serde_json::json;

    #[test]
    fn a_remote_names_its_repository() {
        let cmux = Some("manaflow-ai/cmux");
        assert_eq!(github_repo("https://github.com/manaflow-ai/cmux.git").as_deref(), cmux);
        assert_eq!(github_repo("git@github.com:manaflow-ai/cmux.git").as_deref(), cmux);
        assert_eq!(github_repo("ssh://git@github.com/o/r").as_deref(), Some("o/r"));
        assert_eq!(github_repo("https://gitlab.com/o/r.git"), None);
        assert_eq!(github_repo("https://github.com/o"), None);
    }

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
