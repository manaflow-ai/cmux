//! Tail first, history after (`agent-transfer-history-later-v1`): a move whose
//! chat goes live on the target with only its last turns, its packed history
//! following on the same link once the chat runs there.
//!
//! The client (`cmux link agent move --history-later TURNS`, or
//! `ACPMUX_MOVE_HISTORY_LATER`) asks for it only when both daemons list the
//! capability and both acpmux daemons answer `agent-transfer-history-ready`:
//!
//! 1. source `agent-transfer-prepare {surface, keep_turns}`: acpmux's
//!    `_acpmux/transfer_prepare` with `historyLater`, read like a move's
//!    bundle (`agent-transfer-read` with its `prepare_id`);
//! 2. target `agent-transfer-stage {manifest}`, its pages written with
//!    `agent-transfer-write` (the `stage_id` as `receive_id`), then
//!    `agent-transfer-stage-finish {stage_id}`;
//! 3. source `agent-transfer-begin` with the `prepare_id`, target
//!    `agent-transfer-receive` with the `stage_id`: only the tail moves;
//! 4. after commit, target `agent-transfer-history-have {receive_id}`, source
//!    `agent-transfer-history-export {transfer_id, have}` (read with its own
//!    `prepare_id`), target stage, writes and stage-finish again, then
//!    `agent-transfer-history {receive_id, stage_id}` installs it.
//!
//! The daemon fills in every session id from its own records (a tab, a
//! receive it settled, a prepare it made), as the other verbs do. A stage is
//! made under the target's receive guard control, so the receive that takes
//! it is the same guarded receive as today's.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Map, Value, json};

use super::{
    AgentTransfers, BundleFiles, CALL_TIMEOUT, Failure, MAX_MOVES, Move, Refusal, SurfaceId,
    guard_for, host_gate, is_plain_id, lock, tab_session, vm_word,
};
use crate::mux::Mux;
use crate::panic_free::JsonFields;

/// An export packs the chat's whole history, and a stage-finish or install
/// writes and indexes it: far longer than a page.
const HISTORY_TIMEOUT: Duration = Duration::from_secs(120);
/// At most this many turns kept by a prepare.
const MAX_KEEP_TURNS: u64 = 1 << 20;

/// What the daemon holds for tail-first moves.
#[derive(Default)]
pub(super) struct HistoryLater {
    /// Prepares made here (source), by `prepareId`.
    prefixes: Mutex<HashMap<String, Prefix>>,
    /// Stages made here (target), by `stageId`.
    stages: Mutex<HashMap<String, Stage>>,
    /// Moves begun here whose history is still on this machine, by
    /// `transferId` (kept past the commit).
    owed: Mutex<HashMap<String, Owed>>,
}

#[derive(Clone)]
pub(super) struct Prefix {
    pub(super) session: String,
    pub(super) after_seq: u64,
    pub(super) history_later: bool,
    touched: Instant,
}

struct Stage {
    touched: Instant,
}

struct Owed {
    session: String,
    through_seq: u64,
    touched: Instant,
}

impl HistoryLater {
    /// The prepare `prepare_id` made here, if it is `session`'s.
    pub(super) fn prefix(&self, prepare_id: &str, session: &str) -> Option<Prefix> {
        let mut prefixes = lock(&self.prefixes);
        let prefix = prefixes.get_mut(prepare_id).filter(|p| p.session == session)?;
        prefix.touched = Instant::now();
        Some(prefix.clone())
    }

    /// The move `transfer_id` owes its history: it began from a tail-only prefix.
    pub(super) fn owe(&self, transfer_id: &str, prefix: &Prefix) {
        let mut owed = lock(&self.owed);
        evict(&mut owed, |o| o.touched);
        let entry = Owed {
            session: prefix.session.clone(),
            through_seq: prefix.after_seq,
            touched: Instant::now(),
        };
        owed.insert(transfer_id.to_owned(), entry);
    }

    /// Whether `stage_id` is a stage made here (a write may name it).
    pub(super) fn holds_stage(&self, stage_id: &str) -> bool {
        let mut stages = lock(&self.stages);
        let Some(stage) = stages.get_mut(stage_id) else { return false };
        stage.touched = Instant::now();
        true
    }
}

/// Drops the oldest entries of `map` until one more fits under [`MAX_MOVES`].
fn evict<T>(map: &mut HashMap<String, T>, touched: impl Fn(&T) -> Instant) {
    while map.len() >= MAX_MOVES {
        let oldest = map.iter().min_by_key(|(_, v)| touched(v)).map(|(k, _)| k.clone());
        let Some(oldest) = oldest else { break };
        map.remove(&oldest);
    }
}

// MARK: Requests

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ReadyParams {}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct PrepareParams {
    surface: SurfaceId,
    keep_turns: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct StageParams {
    manifest: Map<String, Value>,
    /// The receive's folder: the guard the stage is made under is that receive's.
    cwd: String,
    #[serde(default, deserialize_with = "crate::server::command_args::present_nullable")]
    vm_kind: Option<Option<String>>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct StageFinishParams {
    stage_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct HaveParams {
    receive_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ExportParams {
    transfer_id: String,
    have: Value,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct InstallParams {
    receive_id: String,
    stage_id: String,
}

pub(super) enum Verb {
    Ready(ReadyParams),
    Prepare(PrepareParams),
    Stage(StageParams),
    StageFinish(StageFinishParams),
    Have(HaveParams),
    Export(ExportParams),
    Install(InstallParams),
}

impl Verb {
    pub(super) fn parse(cmd: &str, params: Value) -> Option<Self> {
        use serde_json::from_value;
        Some(match cmd {
            "agent-transfer-history-ready" => Self::Ready(from_value(params).ok()?),
            "agent-transfer-prepare" => Self::Prepare(from_value(params).ok()?),
            "agent-transfer-stage" => Self::Stage(from_value(params).ok()?),
            "agent-transfer-stage-finish" => Self::StageFinish(from_value(params).ok()?),
            "agent-transfer-history-have" => Self::Have(from_value(params).ok()?),
            "agent-transfer-history-export" => Self::Export(from_value(params).ok()?),
            "agent-transfer-history" => Self::Install(from_value(params).ok()?),
            _ => return None,
        })
    }
}

pub(super) enum Prepared {
    Ready,
    Prepare { session: String, keep_turns: u64 },
    Stage { manifest: Map<String, Value>, control: String },
    StageFinish { stage_id: String },
    Have { session: String },
    Export { session: String, through_seq: u64, have: Value },
    Install { session: String, stage_id: String },
}

pub(super) fn prepare(mux: &Mux, client: u64, verb: Verb) -> Result<Prepared, Failure> {
    let transfers = &mux.agent_transfers;
    let later = &transfers.history_later;
    Ok(match verb {
        Verb::Ready(ReadyParams {}) => Prepared::Ready,
        Verb::Prepare(PrepareParams { surface, keep_turns }) => {
            let session = tab_session(mux, surface).ok_or(Refusal::UnknownTab)?;
            if !(1..=MAX_KEEP_TURNS).contains(&keep_turns) {
                return Err(Refusal::BadRequest.into());
            }
            Prepared::Prepare { session, keep_turns }
        }
        Verb::Stage(StageParams { manifest, cwd, vm_kind }) => {
            let host = transfers.host().ok_or(Refusal::Unavailable)?;
            host_gate(mux, client, vm_word(&vm_kind))?;
            let (guard, _) = guard_for(&host, &cwd)?;
            let control = guard.field("control").as_str().unwrap_or_default().to_owned();
            if !manifest.get("sessionId").and_then(Value::as_str).is_some_and(is_plain_id) {
                return Err(Refusal::BadRequest.into());
            }
            Prepared::Stage { manifest, control }
        }
        Verb::StageFinish(StageFinishParams { stage_id }) => {
            if !later.holds_stage(&stage_id) {
                return Err(Refusal::UnknownReceive.into());
            }
            Prepared::StageFinish { stage_id }
        }
        Verb::Have(HaveParams { receive_id }) => {
            let session = settled_session(transfers, &receive_id)?;
            Prepared::Have { session }
        }
        Verb::Export(ExportParams { transfer_id, have }) => {
            let mut owed = lock(&later.owed);
            let entry = owed.get_mut(&transfer_id).ok_or(Refusal::UnknownTransfer)?;
            entry.touched = Instant::now();
            Prepared::Export {
                session: entry.session.clone(),
                through_seq: entry.through_seq,
                have,
            }
        }
        Verb::Install(InstallParams { receive_id, stage_id }) => {
            let session = settled_session(transfers, &receive_id)?;
            if !later.holds_stage(&stage_id) {
                return Err(Refusal::UnknownReceive.into());
            }
            Prepared::Install { session, stage_id }
        }
    })
}

/// The chat a finish here landed for the receive `receive_id`.
fn settled_session(transfers: &AgentTransfers, receive_id: &str) -> Result<String, Refusal> {
    let mut settled = lock(&transfers.settled);
    let entry = settled.get_mut(receive_id).ok_or(Refusal::UnknownReceive)?;
    entry.touched = Instant::now();
    Ok(entry.moved.session_id.clone())
}

/// Whether acpmux's `_acpmux/status` lists every capability a tail-first
/// move needs of it.
fn ready(status: &Value) -> bool {
    let caps = status.field("capabilities").as_array();
    let lists = |cap: &str| caps.is_some_and(|caps| caps.iter().any(|c| c == cap));
    lists("transfer-precopy-v1") && lists("transfer-history-later-v1")
}

/// Records a prefix manifest acpmux made here so its files can be read
/// (`agent-transfer-read` with its `prepareId`, no epoch: nothing is frozen).
fn hold_prefix(transfers: &AgentTransfers, manifest: &Value) -> Result<String, Failure> {
    let prepare_id = manifest
        .field("prepareId")
        .as_str()
        .filter(|id| is_plain_id(id))
        .ok_or(Refusal::Refused)?
        .to_owned();
    let files: BundleFiles = manifest
        .field("files")
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|file| file.field("path").as_str())
        .map(|path| (path.to_owned(), None))
        .collect();
    let mut moves = lock(&transfers.moves);
    evict(&mut moves, |m| m.touched);
    moves.insert(prepare_id.clone(), Move { files, epoch: 0, touched: Instant::now() });
    Ok(prepare_id)
}

pub(super) fn run(
    mux: &Mux,
    call: &impl Fn(&str, Value, Duration) -> Result<Value, Failure>,
    prepared: Prepared,
) -> Result<Value, Failure> {
    let transfers = &mux.agent_transfers;
    let later = &transfers.history_later;
    match prepared {
        Prepared::Ready => {
            // An acpmux too old for `_acpmux/status` cannot do this either.
            let ready = call("_acpmux/status", json!({}), CALL_TIMEOUT).is_ok_and(|s| ready(&s));
            Ok(json!({"history_later": ready}))
        }
        Prepared::Prepare { session, keep_turns } => {
            let params = json!({"sessionId": session, "historyLater": {"keepTurns": keep_turns}});
            let manifest = call("_acpmux/transfer_prepare", params, HISTORY_TIMEOUT)?;
            let after_seq = manifest.field("afterSeq").as_u64().ok_or(Refusal::Refused)?;
            if manifest.field("sessionId").as_str() != Some(session.as_str()) {
                return Err(Refusal::Refused.into());
            }
            let prepare_id = hold_prefix(transfers, &manifest)?;
            // A chat with fewer turns than kept is prepared whole.
            let history_later = *manifest.field("historyLater") == json!(true);
            let prefix = Prefix { session, after_seq, history_later, touched: Instant::now() };
            let mut prefixes = lock(&later.prefixes);
            evict(&mut prefixes, |p| p.touched);
            prefixes.insert(prepare_id.clone(), prefix);
            Ok(json!({"prepare_id": prepare_id, "after_seq": after_seq,
                       "history_later": history_later, "manifest": manifest}))
        }
        Prepared::Stage { manifest, control } => {
            let params = json!({"manifest": manifest, "control": control});
            let answer = call("_acpmux/transfer_stage", params, CALL_TIMEOUT)?;
            let stage_id = answer
                .field("stageId")
                .as_str()
                .filter(|id| is_plain_id(id))
                .ok_or(Refusal::Refused)?
                .to_owned();
            let mut stages = lock(&later.stages);
            evict(&mut stages, |s| s.touched);
            stages.insert(stage_id.clone(), Stage { touched: Instant::now() });
            Ok(json!({"stage_id": stage_id}))
        }
        Prepared::StageFinish { stage_id } => {
            let params = json!({"stageId": stage_id});
            let answer = call("_acpmux/transfer_stage_finish", params, HISTORY_TIMEOUT)?;
            Ok(json!({"after_seq": answer.field("afterSeq"), "records": answer.field("records")}))
        }
        Prepared::Have { session } => {
            let answer =
                call("_acpmux/transfer_history_have", json!({"sessionId": session}), CALL_TIMEOUT)?;
            Ok(json!({"have": answer.field("have")}))
        }
        Prepared::Export { session, through_seq, have } => {
            let params = json!({"sessionId": session, "throughSeq": through_seq, "have": have});
            let manifest = call("_acpmux/transfer_history_export", params, HISTORY_TIMEOUT)?;
            let prepare_id = hold_prefix(transfers, &manifest)?;
            Ok(json!({"prepare_id": prepare_id, "through_seq": through_seq, "manifest": manifest}))
        }
        Prepared::Install { session, stage_id } => {
            let params = json!({"sessionId": session, "stageId": stage_id});
            let answer = call("_acpmux/transfer_history", params, HISTORY_TIMEOUT)?;
            lock(&later.stages).remove(&stage_id);
            Ok(
                json!({"through_seq": answer.field("throughSeq"), "records": answer.field("records")}),
            )
        }
    }
}
