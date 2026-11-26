//! The lane's side of the GitHub broker (`github_broker.rs`): an agent session's GitHub action,
//! asked over this machine's unix socket, goes to the Mac that lends GitHub here. Moved from
//! `github_broker.rs` (`github_broker::handle`): it reads the hub and the connection, which that
//! lower module does not reach.
//!
//! A `token` answer goes back to the agent session's process that asked (git's credential
//! helper, the `gh` shim, GitHub MCP: `github_lane_mint.rs`) and nowhere else: the session's
//! `github_broker_action` row names the repository and permissions, never the token.

use std::sync::Arc;

use serde_json::{Value, json};

use super::Conn;
use crate::github_broker::{
    GithubAction, GithubActionParams, LANE_WAIT, audit_payload, deadline_from, denied,
    installation_token, invalid, source_of, validate,
};
use crate::hub::Hub;
use crate::rpc::RpcError;

/// The lane's side: an agent session asked over the unix socket (`remote_guard.rs` refuses
/// every other origin).
pub async fn handle(hub: &Arc<Hub>, conn: &Arc<Conn>, params: Value) -> Result<Value, RpcError> {
    if conn.origin != crate::conn_origin::Origin::Local {
        return Err(denied("GitHub actions are asked over this machine's unix socket only"));
    }
    let mut request: GithubActionParams = serde_json::from_value(params)
        .map_err(|e| invalid(format!("invalid GitHub action: {e}")))?;
    let session = conn
        .caller()
        .ok_or_else(|| {
            denied("GitHub actions are for an acpmux session's agent (run it inside one)")
        })?
        .to_owned();
    request.session_id = Some(session.clone());
    validate(&request)?;
    let session = hub.resolve(&session)?;
    let record = |status: &str, error: Option<&RpcError>, source: Option<&str>| {
        hub.append_github_audit(&session, audit_payload(&request, status, error, source));
    };
    let owners = hub.github_owner_links();
    if owners.is_empty() {
        let error = RpcError::new(
            -32042,
            "no Mac that lends GitHub to this machine is connected (add this machine from the Mac with Add Machine)",
        )
        .with_data(json!({"reason": "github.no_owner"}));
        record("unavailable", Some(&error), None);
        return Err(error);
    }
    // Every owner is asked within the one `LANE_WAIT` the caller waits, with the one deadline the
    // first was given: whichever Mac takes it, its `gh` ends before this machine stops waiting,
    // by the same reasoning as a single ask (`github_broker::LANE_WAIT`). The next is asked only
    // while a whole run still fits before it (`still_fits`); past that, a Mac would refuse it.
    let first = crate::store::now_ms();
    let until = first + LANE_WAIT.as_millis() as u64;
    let deadline = deadline_from(first);
    let mut reply = Err(RpcError::internal("no owner was asked"));
    for (n, owner) in owners.iter().take(OWNERS_TRIED).enumerate() {
        let now = crate::store::now_ms();
        if n > 0 && !still_fits(now, deadline) {
            break;
        }
        // The Mac starts nothing it could not finish before this machine stops waiting.
        let mut wire = request.clone();
        wire.deadline_ms = Some(deadline);
        let wire = serde_json::to_value(&wire).map_err(|e| RpcError::internal(e.to_string()))?;
        let budget = std::time::Duration::from_millis(until.saturating_sub(now));
        reply = owner.request_client(crate::rpc::method::MUX_GITHUB_ACTION, wire, budget).await;
        let Err(e) = &reply else {
            hub.github_owner_health(owner, false);
            break;
        };
        let (next, stalled) = after_failure(request.action, e);
        if stalled {
            hub.github_owner_health(owner, true);
        }
        if !next {
            break;
        }
        tracing::info!(attempt = n + 1, code = e.code, "github broker: asking the next owner");
    }
    // A `token` answer carries an App installation token and nothing else goes on as one: an
    // older Mac, or one that answered another shape, is refused here.
    if request.action == GithubAction::Token
        && let Ok(v) = &reply
        && !v.get("token").and_then(Value::as_str).is_some_and(installation_token)
    {
        reply = Err(RpcError::new(-32045, "the Mac's answer holds no GitHub App token")
            .with_data(json!({"reason": "github.app_token", "code": "invalid_reply"})));
    }
    let source = source_of(&reply);
    match &reply {
        Ok(_) => record("allowed", None, source),
        Err(e) if e.code == -32040 => record("denied", Some(e), source),
        Err(e) => record("failed", Some(e), source),
    }
    reply
}

/// How many lending links one action may be asked of.
const OWNERS_TRIED: usize = 3;

/// Whether an owner asked at `now_ms` could still start a whole `gh` run before `deadline` (a
/// few seconds kept for the link); one that could not would refuse it as late.
fn still_fits(now_ms: u64, deadline: u64) -> bool {
    now_ms + crate::github_broker::GH_TIMEOUT.as_millis() as u64 + 5_000 <= deadline
}

/// Whether an owner's failure `e` sends `action` on to the next owner, and whether it stalled.
/// A refusal at the door (busy, too late, the Mac's pool or pace budget) ran nothing: ask the
/// next. No answer, or a link that ended before answering, may have run it: only an action that
/// changes nothing (a read, a token) is asked again; an issue, comment or pull request is not,
/// or it could be made twice. Every other answer is GitHub's or the request's own: final.
fn after_failure(action: GithubAction, e: &RpcError) -> (bool, bool) {
    let reason = e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str);
    if matches!(
        reason,
        Some(
            "github.busy"
                | "client.busy"
                | "github.expired"
                | "github.budget.pool"
                | "github.budget.pace"
        )
    ) {
        return (true, false);
    }
    let stalled = e.message.starts_with("no answer within")
        || e.message.starts_with("the connection that would answer ended");
    (stalled && matches!(action, GithubAction::Read | GithubAction::Token), stalled)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn err(code: i64, message: &str, reason: Option<&str>) -> RpcError {
        let e = RpcError::new(code, message);
        match reason {
            Some(r) => e.with_data(json!({"reason": r})),
            None => e,
        }
    }

    #[test]
    fn a_refusal_at_the_door_goes_on_and_a_stall_retries_only_what_changes_nothing() {
        let busy = err(-32000, "too many", Some("github.busy"));
        assert_eq!(after_failure(GithubAction::Comment, &busy), (true, false));
        let pool = err(-32044, "pool", Some("github.budget.pool"));
        assert_eq!(after_failure(GithubAction::Read, &pool), (true, false));
        let caller = err(-32044, "caller", Some("github.budget.caller"));
        assert_eq!(
            after_failure(GithubAction::Read, &caller),
            (false, false),
            "a caller's cap holds on every Mac"
        );
        let gone = RpcError::internal("the connection that would answer ended");
        assert_eq!(after_failure(GithubAction::Read, &gone), (true, true));
        assert_eq!(after_failure(GithubAction::Token, &gone), (true, true));
        let slow = RpcError::internal("no answer within 125s");
        assert_eq!(after_failure(GithubAction::DraftPr, &slow), (false, true), "never made twice");
        assert_eq!(after_failure(GithubAction::Issue, &gone), (false, true));
        let github = err(-32041, "GitHub refused the action", Some("github.command_failed"));
        assert_eq!(after_failure(GithubAction::Read, &github), (false, false));
    }

    #[test]
    fn a_next_owner_is_asked_only_while_a_whole_run_fits() {
        let first = 1_000_000;
        let deadline = deadline_from(first);
        assert!(still_fits(first + 20_000, deadline), "a fast refusal leaves time");
        assert!(
            !still_fits(first + LANE_WAIT.as_millis() as u64 - 1_000, deadline),
            "a timeout spent it"
        );
    }
}
