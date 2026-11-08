//! The plan approval card's build methods (`hub/plan_build.rs`), routed before peer forwarding
//! (`chats.rs`): a plan's builds are sub-sessions of its chat, on this daemon.
//!
//! - `_acpmux/plan/build {sessionId, permissionId, target, harnesses?}`: `target` is `here`
//!   (answers the plan approval's allow, under the same person rule and proof as
//!   `_acpmux/permission_respond`), `worktree` or `compare`. Answers `{target, buildId, builds,
//!   failed}`; `builds` are the started chats (`{sessionId, name, shortName, harness,
//!   worktree}`), `failed` the harnesses whose start was refused (`{harness, error, reason}`).
//! - `_acpmux/plan/compare {sessionId, buildId}`: each build's status and change.
//! - `_acpmux/plan/keep {sessionId, buildId, keep}`: keeps `keep`, archives the other builds'
//!   chats, and answers as `compare` does.
//!
//! Only the person starts or keeps builds: they run with the chat's policy in new worktrees. A
//! remote WebSocket device and a peer are refused, as for the goal methods (`goal.rs`).

use super::{Conn, str_param};
use crate::hub::Hub;
use crate::hub::plan_build::{self, Target};
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;

/// The reply to a plan build method, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(m, method::MUX_PLAN_BUILD | method::MUX_PLAN_COMPARE | method::MUX_PLAN_KEEP) {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        ))));
    }
    if !conn.is_person() {
        return Some(Err(crate::hub::person::person_required("building a plan")));
    }
    Some(handle(hub, conn, m, params).await)
}

fn required<'a>(params: &'a Value, key: &str) -> Result<&'a str, RpcError> {
    str_param(params, key)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| RpcError::invalid_params(format!("{key} is required")))
}

/// The harnesses a build runs: the caller's, else the chat's (`worktree`) or the chat's and the
/// other of Claude and Codex (`compare`).
fn harnesses(params: &Value, target: Target, chat: &str) -> Result<Vec<String>, RpcError> {
    let named: Vec<String> = match params.get("harnesses") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(list)) => list
            .iter()
            .map(|h| {
                h.as_str()
                    .map(str::trim)
                    .filter(|h| !h.is_empty())
                    .map(str::to_owned)
                    .ok_or_else(|| RpcError::invalid_params("harnesses must be harness names"))
            })
            .collect::<Result<_, _>>()?,
        Some(_) => return Err(RpcError::invalid_params("harnesses must be a list")),
    };
    match target {
        Target::Here => Ok(Vec::new()),
        Target::Worktree => Ok(vec![named.into_iter().next().unwrap_or_else(|| chat.to_owned())]),
        Target::Compare if named.is_empty() => Ok(plan_build::compare_harnesses(chat)),
        Target::Compare if (2..=plan_build::MAX_COMPARE).contains(&named.len()) => Ok(named),
        Target::Compare => Err(RpcError::invalid_params(format!(
            "a compare runs 2 to {} harnesses",
            plan_build::MAX_COMPARE
        ))),
    }
}

async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let session = hub.resolve(required(params, "sessionId")?)?;
    match m {
        method::MUX_PLAN_BUILD => {
            let permission_id = required(params, "permissionId")?;
            let target = Target::parse(required(params, "target")?).ok_or_else(|| {
                RpcError::invalid_params("target must be here, worktree or compare")
            })?;
            // One call per approval at a time: a second waits for nothing and starts nothing.
            let _claim = plan_build::claim(&session.id, permission_id)?;
            let (plan, request) = hub.pending_plan(&session, permission_id)?;
            // The turn that asked, as it is now: stopped once the plan is handed to its builds.
            let asking_turn = session.turn().map(|t| t.turn_id);
            let control = super::remote_guard::control_of(conn.origin, conn.auth, params);
            let mut answerer = crate::hub::person::Answerer::of(conn.is_person(), params);
            let author = crate::author::author(params)?;
            answerer.author = author.as_ref();
            if target == Target::Here {
                let allow = plan_build::option_of(&request, "allow_once").ok_or_else(|| {
                    RpcError::invalid_params("this plan approval has no approve option")
                })?;
                hub.respond_permission_annotated(
                    &session,
                    permission_id,
                    Some(allow),
                    None,
                    None,
                    None,
                    answerer,
                    control,
                )
                .await?;
                return Ok(json!({"target": "here", "buildId": null, "builds": [], "failed": []}));
            }
            // Checked before anything starts: an ask with no reject could not be stopped here.
            let reject = plan_build::option_of(&request, "reject_once")
                .or_else(|| plan_build::option_of(&request, "reject_always"))
                .ok_or_else(|| {
                    RpcError::invalid_params("this plan approval has no keep-planning option")
                })?;
            let harnesses = harnesses(params, target, &session.meta().harness)?;
            let build_id = format!("build-{}", uuid::Uuid::new_v4().simple());
            let local = control != crate::hub::Control::Web;
            let (builds, failed) =
                hub.start_plan_builds(&session, &plan, target, &harnesses, &build_id, local).await;
            if builds.is_empty() {
                // Nothing started: the card stays up, and says why.
                let first = failed.first().cloned().unwrap_or(Value::Null);
                let message = first
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("no build started")
                    .to_owned();
                return Err(RpcError::invalid_params(message).with_data(json!({
                    "reason": first.get("reason").cloned().unwrap_or(Value::Null),
                    "failed": failed,
                })));
            }
            hub.record_plan_build(
                &session,
                json!({
                    "event": "started",
                    "buildId": build_id,
                    "target": target.as_str(),
                    "permissionId": permission_id,
                    "builds": builds,
                    "failed": failed,
                }),
            );
            // The plan's own chat stops: it is built elsewhere. A refusal here (answered
            // meanwhile) is the reply's error, so the card stays and says so; the builds run on
            // and the record above shows them.
            hub.respond_permission_annotated(
                &session,
                permission_id,
                Some(reject),
                None,
                None,
                None,
                answerer,
                control,
            )
            .await
            .map_err(|e| {
                let data = json!({
                    "reason": "plan_build.answer_refused",
                    "buildId": build_id,
                    "builds": builds,
                    "answerReason": e.data.as_ref().and_then(|d| d.get("reason")).cloned(),
                });
                RpcError::invalid_params(format!(
                    "the plan's builds started, but its approval was not answered: {}",
                    e.message
                ))
                .with_data(data)
            })?;
            hub.stop_plan_turn(&session, asking_turn.as_deref()).await;
            Ok(json!({
                "target": target.as_str(),
                "buildId": build_id,
                "builds": builds,
                "failed": failed,
            }))
        }
        method::MUX_PLAN_COMPARE => hub.plan_compare(&session, required(params, "buildId")?).await,
        _ => {
            let build_id = required(params, "buildId")?;
            let (kept, others) =
                hub.plan_keep_others(&session, build_id, required(params, "keep")?)?;
            let now = crate::store::now_ms().to_string();
            let mut keep = serde_json::Map::new();
            keep.insert(plan_build::KEPT_TAG.into(), Value::String(now.clone()));
            hub.set_tags_answered(
                &kept,
                Some(&keep),
                &[plan_build::ARCHIVED_TAG.to_owned()],
                None,
            )?;
            let mut archive = serde_json::Map::new();
            archive.insert(plan_build::ARCHIVED_TAG.into(), Value::String(now));
            let mut archived = Vec::new();
            for other in &others {
                hub.set_tags_answered(
                    other,
                    Some(&archive),
                    &[plan_build::KEPT_TAG.to_owned()],
                    None,
                )?;
                archived.push(other.id.clone());
            }
            hub.record_plan_build(
                &session,
                json!({
                    "event": "kept",
                    "buildId": build_id,
                    "keptSessionId": kept.id,
                    "archived": archived,
                }),
            );
            hub.plan_compare(&session, build_id).await
        }
    }
}
