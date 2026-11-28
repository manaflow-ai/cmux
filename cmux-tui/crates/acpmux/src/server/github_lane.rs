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
use crate::hub::github_owner::Outcome;
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
    // Per caller: one session in a loop never takes every slot on the Mac or the shared quota
    // (`github_budget.rs`).
    let _permit = match crate::github_budget::budget().take(&session.id, crate::store::now_ms()) {
        Ok(p) => p,
        Err(e) => {
            record("refused", Some(&e), None);
            return Err(e);
        }
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
    let mut reply = Err(RpcError::internal("no owner was asked"));
    let mut asked = 0usize;
    for owner in owners.into_iter().take(OWNER_TRIES) {
        asked += 1;
        reply = ask(hub, owner, &request).await;
        match failover(&request, &reply) {
            Next::Done => break,
            Next::Stop => {
                // It may have run on that Mac: asking another could run it twice (F7).
                if let Err(e) = &mut reply {
                    mark(e, "failover", "not_retried_may_have_run");
                }
                break;
            }
            Next::Try => continue,
        }
    }
    // Every Mac asked lost it or never got it: the answer says how each owner is doing (its
    // record: running, failures in a row, stalled), so the agent and the person see which.
    if outcome(&reply) != Outcome::Answered
        && let Err(e) = &mut reply
        && let Some(Value::Object(d)) = e.data.as_mut()
    {
        d.insert("owners".into(), Value::Array(hub.github_owner_records()));
    }
    let source = source_of(&reply);
    let record = |status: &str, error: Option<&RpcError>| {
        let mut row = audit_payload(&request, status, error, source);
        row["owners"] = json!(asked);
        hub.append_github_audit(&session, row);
    };
    match &reply {
        Ok(_) => record("allowed", None),
        Err(e) if e.code == -32040 => record("denied", Some(e)),
        Err(e) => record("failed", Some(e)),
    }
    reply
}

/// How many lending Macs one action is asked of at most before its failure is answered.
const OWNER_TRIES: usize = 3;

/// One ask of one owner, counted on its record (`hub/github_owner.rs`).
async fn ask(hub: &Hub, owner: Arc<Conn>, request: &GithubActionParams) -> Result<Value, RpcError> {
    let call = hub.github_owner_call(owner);
    // The Mac starts nothing it could not finish before this machine stops waiting.
    let mut wire = request.clone();
    wire.deadline_ms = Some(deadline_from(crate::store::now_ms()));
    let wire = match serde_json::to_value(&wire) {
        Ok(w) => w,
        Err(e) => return Err(RpcError::internal(e.to_string())),
    };
    let method = crate::rpc::method::MUX_GITHUB_ACTION;
    let mut reply = call.link().request_client(method, wire, LANE_WAIT).await;
    // A `token` answer carries an App installation token and nothing else goes on as one: an
    // older Mac, or one that answered another shape, is refused here.
    if request.action == GithubAction::Token
        && let Ok(v) = &reply
        && !v.get("token").and_then(Value::as_str).is_some_and(installation_token)
    {
        reply = Err(RpcError::new(-32045, "the Mac's answer holds no GitHub App token")
            .with_data(json!({"reason": "github.app_token", "code": "invalid_reply"})));
    }
    call.end(outcome(&reply));
    reply
}

fn reason(reply: &Result<Value, RpcError>) -> Option<&str> {
    reply.as_ref().err()?.data.as_ref()?.get("reason")?.as_str()
}

/// What an owner's answer says of its progress.
fn outcome(reply: &Result<Value, RpcError>) -> Outcome {
    match reason(reply) {
        // A Mac whose pool is low or paced (`github_pool.rs`) ran nothing; another Mac's pool may
        // still serve it. A `github.budget.caller` refusal is this session's and stays.
        Some(
            "client.not_sent" | "client.busy" | "github.busy" | "github.budget.pool"
            | "github.budget.pace",
        ) => Outcome::NotRun,
        Some("client.ended" | "client.timeout") => Outcome::Lost,
        _ => Outcome::Answered,
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Next {
    Done,
    Try,
    Stop,
}

/// After one owner's answer: done, ask the next owner, or stop because it may have run. Only
/// an action that never ran moves on, and one that may have run moves on only when running it
/// twice changes nothing on GitHub (a read, a token mint).
fn failover(request: &GithubActionParams, reply: &Result<Value, RpcError>) -> Next {
    match outcome(reply) {
        Outcome::Answered => Next::Done,
        Outcome::NotRun => Next::Try,
        Outcome::Lost if matches!(request.action, GithubAction::Read | GithubAction::Token) => {
            Next::Try
        }
        Outcome::Lost => Next::Stop,
    }
}

fn mark(e: &mut RpcError, key: &str, value: &str) {
    if let Some(Value::Object(d)) = e.data.as_mut() {
        d.insert(key.into(), value.into());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(action: GithubAction) -> GithubActionParams {
        serde_json::from_value(json!({"action": action, "repo": "o/r"})).unwrap()
    }

    fn err(reason: &str) -> Result<Value, RpcError> {
        Err(RpcError::internal("x").with_data(json!({"reason": reason})))
    }

    #[test]
    fn only_what_never_ran_or_is_safe_twice_moves_to_the_next_owner() {
        for action in [GithubAction::Read, GithubAction::Token, GithubAction::Comment] {
            let r = req(action);
            assert_eq!(failover(&r, &Ok(json!({}))), Next::Done);
            assert_eq!(failover(&r, &err("github.command_failed")), Next::Done);
            assert_eq!(failover(&r, &Err(RpcError::new(-32040, "no"))), Next::Done);
            // A caller over its own hourly reads is over on every Mac: no other owner is asked.
            assert_eq!(failover(&r, &err("github.budget.caller")), Next::Done);
            for not_run in [
                "client.not_sent",
                "client.busy",
                "github.busy",
                "github.budget.pool",
                "github.budget.pace",
            ] {
                assert_eq!(failover(&r, &err(not_run)), Next::Try, "{action:?} {not_run}");
            }
        }
        for lost in ["client.ended", "client.timeout"] {
            assert_eq!(failover(&req(GithubAction::Read), &err(lost)), Next::Try);
            assert_eq!(failover(&req(GithubAction::Token), &err(lost)), Next::Try);
            for once in [GithubAction::Issue, GithubAction::Comment, GithubAction::DraftPr] {
                assert_eq!(failover(&req(once), &err(lost)), Next::Stop, "{once:?} {lost}");
            }
        }
    }

    #[test]
    fn a_github_refusal_counts_as_progress_and_a_lost_answer_does_not() {
        assert_eq!(outcome(&err("github.command_failed")), Outcome::Answered);
        assert_eq!(outcome(&err("github.expired")), Outcome::Answered);
        assert_eq!(outcome(&err("client.timeout")), Outcome::Lost);
        assert_eq!(outcome(&err("github.busy")), Outcome::NotRun);
    }
}
