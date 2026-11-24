//! `--history-later TURNS` (or `ACPMUX_MOVE_HISTORY_LATER=TURNS`, as `acpmux
//! move` reads it): the chat goes live on the machine with only its last
//! `TURNS` turns, and its packed history follows on the same two connections
//! once it runs there (`agent-transfer-history-later-v1`, the daemon's
//! `agent_transfer/history_later.rs`).
//!
//! Off unless asked. Asked, it runs only when both daemons serve the
//! capability and both acpmux daemons can (`agent-transfer-history-ready`);
//! anything short of a finished stage leaves the move exactly as it is
//! without it. A history that fails to follow leaves the chat running on the
//! machine and its history on the source, said on stderr.

use std::time::Instant;

use serde_json::{Value, json};

use super::daemon::{CALL_TIMEOUT, CallError, Daemon};
use super::{Args, Failed, copy_file};
use cmux_tui_core::server::agent_transfer::AGENT_TRANSFER_HISTORY_LATER_CAPABILITY;

/// An export packs the whole history and an install indexes it (the daemon
/// gives acpmux 120 s).
const HISTORY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(150);

/// The turns to keep: the flag's, else the env's; none (off) for 0 or a word.
pub(super) fn turns(flag: Option<u64>, env: Option<&str>) -> Option<u64> {
    flag.or_else(|| env?.trim().parse().ok()).filter(|turns| *turns > 0)
}

/// A prefix of the chat's last turns staged on the machine before the freeze.
pub(super) struct Staged {
    pub(super) prepare_id: String,
    pub(super) stage_id: String,
    pub(super) bytes: u64,
}

/// Whether the daemon at `socket` serves the tail-first verbs and its acpmux
/// can run them.
fn ready(socket: &std::path::Path) -> bool {
    let identity = super::super::machine_gate::reach(socket).ok();
    let served = identity.as_ref().and_then(super::super::machine_gate::served);
    if !served.is_some_and(|s| s.contains(&AGENT_TRANSFER_HISTORY_LATER_CAPABILITY)) {
        return false;
    }
    super::daemon::call_once(socket, "agent-transfer-history-ready", json!({}), CALL_TIMEOUT)
        .is_ok_and(|answer| answer["history_later"] == json!(true))
}

/// Stages the chat's last `keep` turns on the machine: `None` (and a line on
/// stderr when it got under way) for a move that goes as it does today.
pub(super) fn stage(
    args: &Args,
    source: &mut Daemon,
    keep: u64,
    vm_kind: &Option<String>,
    pages: &mut u64,
) -> Option<Staged> {
    if !ready(&args.from) || !ready(&args.to) {
        return None;
    }
    let staged = (|| {
        let params = json!({"surface": args.surface, "keep_turns": keep});
        let prepared = source
            .call("agent-transfer-prepare", params, HISTORY_TIMEOUT)
            .map_err(|e| Failed::call("source", &e))?;
        let mut target = target(args)?;
        let prepare_id = text(&prepared, "prepare_id")?;
        let stage_id = stage_into(args, &mut target, &prepared["manifest"], vm_kind)?;
        let bytes =
            copy_all(source, &mut target, &prepared["manifest"], &prepare_id, &stage_id, pages)?;
        finish_stage(&mut target, &stage_id)?;
        Ok::<_, Failed>(Staged { prepare_id, stage_id, bytes })
    })();
    match staged {
        Ok(staged) => Some(staged),
        Err(failed) => {
            eprintln!(
                "cmux: the chat's last turns could not go first ({}); it moves whole",
                failed.error
            );
            None
        }
    }
}

/// The history the move owes, sent after the chat runs on the machine.
pub(super) struct Followed {
    pub(super) through_seq: u64,
    pub(super) records: u64,
    pub(super) bytes: u64,
    pub(super) ms: u128,
}

/// Sends the history of move `transfer_id` (received as `receive_id`) from
/// the source to the machine. An error leaves the history on the source.
pub(super) fn follow(
    args: &Args,
    transfer_id: &str,
    receive_id: &str,
    vm_kind: &Option<String>,
    pages: &mut u64,
) -> Result<Followed, Failed> {
    let started = Instant::now();
    let mut source = Daemon::connect(&args.from).map_err(|e| Failed::call("source", &e))?;
    let mut target = target(args)?;
    let have = target
        .call("agent-transfer-history-have", json!({"receive_id": receive_id}), CALL_TIMEOUT)
        .map_err(|e| Failed::call("target", &e))?;
    let ask = json!({"transfer_id": transfer_id, "have": have["have"]});
    let export = source
        .call("agent-transfer-history-export", ask, HISTORY_TIMEOUT)
        .map_err(|e| Failed::call("source", &e))?;
    let prepare_id = text(&export, "prepare_id")?;
    let stage_id = stage_into(args, &mut target, &export["manifest"], vm_kind)?;
    let bytes =
        copy_all(&mut source, &mut target, &export["manifest"], &prepare_id, &stage_id, pages)?;
    finish_stage(&mut target, &stage_id)?;
    let install = json!({"receive_id": receive_id, "stage_id": stage_id});
    let arrived = target
        .call("agent-transfer-history", install, HISTORY_TIMEOUT)
        .map_err(|e| Failed::call("target", &e))?;
    Ok(Followed {
        through_seq: export["through_seq"].as_u64().unwrap_or(0),
        records: arrived["records"].as_u64().unwrap_or(0),
        bytes,
        ms: started.elapsed().as_millis(),
    })
}

/// A connection to the machine, from the process the caller checked.
fn target(args: &Args) -> Result<Daemon, Failed> {
    let target = Daemon::connect(&args.to).map_err(|e| Failed::call("target", &e))?;
    if let Some(pid) = args.to_pid
        && target.peer_pid() != Some(pid)
    {
        let error = "the Cloud link this machine's answer came from has ended";
        return Err(Failed::new("agent_session.host_unverified", error));
    }
    Ok(target)
}

fn text(answer: &Value, key: &str) -> Result<String, Failed> {
    answer[key]
        .as_str()
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| Failed::bad_answer(format!("the answer names no {key}")))
}

fn stage_into(
    args: &Args,
    target: &mut Daemon,
    manifest: &Value,
    vm_kind: &Option<String>,
) -> Result<String, Failed> {
    let mut params = json!({"manifest": manifest, "cwd": args.cwd});
    if let Some(kind) = vm_kind {
        cmux_json::JsonSet::set(&mut params, "vm_kind", json!(kind));
    }
    let staged = target
        .call("agent-transfer-stage", params, CALL_TIMEOUT)
        .map_err(|e| Failed::call("target", &e))?;
    text(&staged, "stage_id")
}

fn finish_stage(target: &mut Daemon, stage_id: &str) -> Result<(), Failed> {
    let params = json!({"stage_id": stage_id});
    target
        .call("agent-transfer-stage-finish", params, HISTORY_TIMEOUT)
        .map(drop)
        .map_err(|e: CallError| Failed::call("target", &e))
}

/// Every file `manifest` lists, read under `read_id` and written to `write_id`.
fn copy_all(
    source: &mut Daemon,
    target: &mut Daemon,
    manifest: &Value,
    read_id: &str,
    write_id: &str,
    pages: &mut u64,
) -> Result<u64, Failed> {
    let files = manifest["files"]
        .as_array()
        .ok_or_else(|| Failed::bad_answer("the prefix manifest lists no files"))?;
    let mut bytes = 0;
    for file in files {
        let (Some(path), Some(size)) = (file["path"].as_str(), file["size"].as_u64()) else {
            return Err(Failed::bad_answer(
                "the prefix manifest lists a file without path or size",
            ));
        };
        bytes += copy_file(source, target, read_id, write_id, path, size, pages)?;
    }
    Ok(bytes)
}
