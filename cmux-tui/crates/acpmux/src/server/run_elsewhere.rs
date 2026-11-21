//! "Run on a bigger machine" (`run_elsewhere.rs`): `_acpmux/run_elsewhere/plan {sessionId,
//! command, offerOnly: true}` says whether a running command is worth offering at all
//! (`{offer: {show, why, busyCores?}}`, `run_elsewhere::offer`: it computes, by its session's
//! measured CPU time over `OFFER_WINDOW` and its shape; one waiting on the network never is), and
//! the chat row shows the chip only on `show`. Without `offerOnly` it says whether a chat's command may run on another machine, which connected
//! machines can take it and exactly what would go (the base commit, every changed file, the
//! secret-looking ones left out, the untracked ones that stay); `_acpmux/run_elsewhere/start
//! {sessionId, command, cwd?, peer, digest, sendSecrets?}` starts it as a background task of the
//! chat (`hub/bg_tasks.rs`), whose output `_acpmux/bg/output` reads.
//!
//! Only the person starts one, from this machine: the methods carry a command, so a remote
//! WebSocket device and a peer are refused before anything is read (as the background-task
//! methods are), and so is the chat's own agent. A start goes only while the tree still has the
//! digest the plan showed.

use super::{Conn, str_param};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use crate::run_elsewhere as re;
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::Arc;

/// The reply to a run-elsewhere method, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(m, method::MUX_RUN_ELSEWHERE_PLAN | method::MUX_RUN_ELSEWHERE_START) {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        ))));
    }
    if !conn.is_person() {
        return Some(Err(RpcError::invalid_params(
            "only the person starts a run on another machine",
        )));
    }
    Some(handle(hub, m, params).await)
}

/// The connected machines a run can go to, each with its ssh destination, and the others with
/// why not.
fn machines(hub: &Hub) -> Vec<(String, Result<String, String>)> {
    hub.peers()
        .iter()
        .filter_map(|p| {
            let name = p.get("name")?.as_str()?.to_owned();
            let connected = p.get("connected").and_then(Value::as_bool).unwrap_or(false);
            let route = match p.get("url").and_then(Value::as_str).map(crate::peer::ssh_target) {
                _ if !connected => Err("not connected now".to_owned()),
                Some(Ok(t)) => Ok(t.destination),
                _ => Err("reached without ssh; runs need ssh for now".to_owned()),
            };
            Some((name, route))
        })
        .collect()
}

async fn handle(hub: &Arc<Hub>, m: &str, params: &Value) -> Result<Value, RpcError> {
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    let meta = session.meta();
    if meta.remote_origin {
        return Err(RpcError::invalid_params("a remote chat's commands run where it runs"));
    }
    let command = str_param(params, "command")
        .ok_or_else(|| RpcError::invalid_params("command is required"))?;
    if m == method::MUX_RUN_ELSEWHERE_PLAN
        && params.get("offerOnly").and_then(Value::as_bool).unwrap_or(false)
    {
        return Ok(json!({ "offer": offer(&session, command).await }));
    }
    let cwd = str_param(params, "cwd").filter(|c| !c.is_empty()).map(PathBuf::from);
    let cwd = cwd.unwrap_or(meta.cwd.clone());
    let plan = re::plan(&cwd).await;
    let refusal = re::command_refusal(command);
    let machines = machines(hub);
    if m == method::MUX_RUN_ELSEWHERE_PLAN {
        let list: Vec<Value> = machines
            .iter()
            .map(|(name, route)| match route {
                Ok(_) => json!({"name": name, "ok": true}),
                Err(why) => json!({"name": name, "ok": false, "why": why}),
            })
            .collect();
        let why = refusal.or_else(|| plan.as_ref().err().cloned());
        let mut reply = serde_json::Map::new();
        reply.insert("eligible".into(), json!(why.is_none()));
        reply.insert("machines".into(), json!(list));
        if let Some(why) = why {
            reply.insert("why".into(), json!(why));
        }
        if let Ok(plan) = &plan {
            reply.insert("tree".into(), plan.view());
        }
        return Ok(Value::Object(reply));
    }
    if let Some(why) = refusal {
        return Err(RpcError::invalid_params(format!("this command stays here: {why}")));
    }
    let plan = plan.map_err(RpcError::invalid_params)?;
    let digest = str_param(params, "digest")
        .ok_or_else(|| RpcError::invalid_params("digest is required (from the plan)"))?;
    if plan.digest() != digest {
        return Err(RpcError::invalid_params(
            "the files changed since you looked; check what goes again",
        ));
    }
    let peer =
        str_param(params, "peer").ok_or_else(|| RpcError::invalid_params("peer is required"))?;
    let destination = match machines.into_iter().find(|(name, _)| name == peer) {
        Some((_, Ok(destination))) => destination,
        Some((_, Err(why))) => return Err(RpcError::invalid_params(format!("{peer}: {why}"))),
        None => return Err(RpcError::invalid_params(format!("{peer} is not a connected machine"))),
    };
    let send_secrets: Vec<String> = params
        .get("sendSecrets")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default();
    let left_out = plan.left_out(&send_secrets);
    // What goes is cut from the diff the digest covers, so it is exactly what the person saw.
    let patch = if left_out.is_empty() {
        plan.patch.clone()
    } else {
        re::patch_without(&plan.patch, &left_out)
    };
    let run_id = uuid::Uuid::now_v7().simple().to_string();
    let script = re::remote_script(&plan, &patch, &left_out, command, &run_id)
        .map_err(RpcError::invalid_params)?;
    let path = write_script(&run_id, &script)
        .map_err(|e| RpcError::internal(format!("save the run's script: {e}")))?;
    let task = re::task_command("ssh", &destination, &path);
    let description = format!("{} on {peer}", crate::bg_run::label(None, command));
    // The task's own shell removes the script when the run ends; a start acpmux refuses (a stopped
    // chat, too many tasks) leaves it here, readable only by this user.
    let started = hub
        .bg_start(&session, &task, Some(plan.root.clone()), Some(description), false, false, None)
        .await?;
    Ok(json!({
        "task": started,
        "machine": peer,
        "base": plan.base,
        "sent": plan.files.len().saturating_sub(left_out.len()),
        "leftOut": left_out,
    }))
}

/// Whether `command`, running in `session` now, is worth a bigger machine: its words alone when
/// they settle it (one that stays here or waits on the network is never measured), else the CPU
/// time its session's process tree uses over [`re::OFFER_WINDOW`].
async fn offer(session: &crate::hub::Session, command: &str) -> re::Offer {
    if re::command_refusal(command).is_some() || re::shape(command) == re::Shape::Wait {
        return re::offer(command, None);
    }
    let Some((pid, before)) = session.harness_tree_cpu_ms().await else {
        return re::offer(command, None);
    };
    let started = std::time::Instant::now();
    tokio::time::sleep(re::OFFER_WINDOW).await;
    // The same harness at both reads: a restart in between measures nothing.
    let busy = match session.harness_tree_cpu_ms().await {
        Some((again, after)) if again == pid => {
            Some(re::busy_cores(before, after, started.elapsed()))
        }
        _ => None,
    };
    re::offer(command, busy)
}

/// The run's script, readable only by this user, in `<ACPMUX_HOME>/run-elsewhere/`; the task
/// removes it when the run ends.
fn write_script(run_id: &str, script: &str) -> std::io::Result<PathBuf> {
    use std::io::Write as _;
    let dir = crate::config::home().join("run-elsewhere");
    crate::home_fs::create_dirs(&dir)?;
    let path = dir.join(format!("{run_id}.sh"));
    let mut options = crate::home_fs::OpenOptions::new();
    options.write(true).create_new(true).mode(0o600);
    options.open(&path)?.write_all(script.as_bytes())?;
    Ok(path)
}
