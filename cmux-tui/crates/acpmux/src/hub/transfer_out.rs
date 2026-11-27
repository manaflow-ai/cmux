//! Part of `Hub`; see `hub/mod.rs`. Moving a chat to another daemon (`acpmux.transfer.v1`): a
//! sibling build's daemon or a remote machine's. This side gives the chat away; `transfer_in.rs`
//! takes it. Any client moves it between the two (the app, a Move to Cloud service, `acpmux
//! transfer`), so neither daemon needs to reach the other:
//!
//! 1. source `_acpmux/transfer_begin {sessionId, interrupt?, atToolBoundary?, afterTurn?, to?:
//!    {socket, ssh?, host?}, gatesQueueApproval?}`: the chat stops
//!    taking prompts and starting queued ones (a running turn refuses the move, stops with
//!    `interrupt`, or with `atToolBoundary` stops once no tool call of it runs and until then
//!    answers `transfer.tool_in_flight`: [`TurnCut`]; with `afterTurn` the begin first waits,
//!    unfrozen, for the turn to end on its own), and its bundle (`transfer.rs` export) is
//!    made. A turn the move stops goes
//!    on: its continuation is queued first (`restart_resume.rs`, reason `moved`), so it runs where
//!    the chat lands, or here when the move is aborted. Answers `{schema, transferId,
//!    sessionId, files: [{path, size}], session, continues?}` (`continues`: that continuation's
//!    prompt id): the manifest the target takes. `to` names the
//!    target's local socket, which the source asks if the client goes away (`transfer_watch.rs`);
//!    with `ssh`, that socket is on that ssh host, reached through a forward (`ssh_forward.rs`);
//!    `host` is the peer's name, recorded in `movedTo` when the watch ends the move. With
//!    `hub` (no `socket`), the target is a machine only the team hub reaches, by its hub
//!    `daemonId`: it pulls the pages itself (`transfer_pull.rs`), and only it may.
//! 2. source `_acpmux/transfer_read {transferId, path, offset, limit?}` pages a file: `{data`
//!    (base64)`, next, eof}`.
//! 3. target `_acpmux/transfer_receive {manifest}`, `transfer_write`, `transfer_finish`.
//! 4. source `_acpmux/transfer_commit {sessionId, transferId, to?}`: the queue is withdrawn (it
//!    runs on the target), the draft cleared, and the chat closed here; or
//!    `_acpmux/transfer_abort {sessionId, transferId}`: the chat is given back as it was.
//!
//! The move is in the log (`transfer_out`, `transfer_aborted`, `transferred`), so a daemon that
//! restarts mid-move keeps the chat frozen (`queue.rs` `restore_queue`) until it commits or
//! aborts: each queued prompt runs once, on one daemon. While it is frozen its queue and draft
//! do not change either. A client aborts only a move the target does not have: one whose
//! `transfer_finish` answer was lost is committed when the target's log has the move's
//! `transferred_in {transferId}` (a chat with the same id there may be another copy). A move
//! whose client goes away ends on its own (`transfer_watch.rs`).
//!
//! Only the local socket moves a chat: a bundle holds the whole chat, and its queue runs on the
//! target under the rules it was sent with. A remote daemon takes one through its own guarded
//! entry, not this one.

use super::*;
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use cmux_json::JsonSet as _;

pub const TRANSFER_SCHEMA: &str = "acpmux.transfer.v1";
pub const DURABLE_TRANSFER_SCHEMA: &str = "acpmux.transfer.v2";
/// The largest page `transfer_read` answers, and `transfer_write` takes.
pub(super) const MAX_PAGE: u64 = 4 << 20;

/// Bundles being moved, out and in.
pub(super) fn transfers_dir() -> PathBuf {
    crate::config::home().join("transfers")
}

/// The most files in the current one-frame manifest. File contents are paged,
/// with no total byte limit.
pub(super) const MAX_FILES: usize = 10_000;
/// A move left that long without its commit, abort or finish is swept.
const STALE: std::time::Duration = std::time::Duration::from_secs(24 * 3600);

/// `rel` as a path under `root`, or an error for anything that could leave it.
pub(super) fn inside(root: &Path, rel: &str) -> Result<PathBuf, RpcError> {
    let path = Path::new(rel);
    let plain = path.components().all(|c| matches!(c, std::path::Component::Normal(_)));
    if rel.is_empty() || !plain {
        return Err(RpcError::invalid_params(format!("transfer: bad path {rel:?}")));
    }
    Ok(root.join(path))
}

/// Every file under `root`, relative, with its size, in a stable order.
pub(super) fn bundle_files(root: &Path) -> std::io::Result<Vec<(String, u64)>> {
    let mut files = Vec::new();
    let mut dirs = vec![root.to_path_buf()];
    while let Some(dir) = dirs.pop() {
        for entry in std::fs::read_dir(&dir)? {
            let entry = entry?;
            let kind = entry.file_type()?;
            if kind.is_dir() {
                dirs.push(entry.path());
            } else if kind.is_file() {
                let rel = entry.path().strip_prefix(root).unwrap_or(&entry.path()).to_owned();
                files.push((rel.to_string_lossy().into_owned(), entry.metadata()?.len()));
            }
        }
    }
    files.sort();
    Ok(files)
}

/// Removes moves left behind: a receive never finished, a bundle no chat here is in.
pub(super) fn sweep_transfers(moving: &[String]) {
    let Ok(entries) = std::fs::read_dir(transfers_dir()) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        // A receive's last page touched its `alive` file (`transfer_in.rs`).
        let alive = entry.path().join("alive");
        let stamp = std::fs::metadata(&alive).or_else(|_| entry.metadata());
        let old = stamp
            .and_then(|m| m.modified())
            .is_ok_and(|t| t.elapsed().is_ok_and(|age| age > STALE));
        if old && !moving.contains(&name) {
            let _ = crate::home_fs::remove_dir_all(entry.path());
        }
    }
}

/// How `transfer_begin` treats a running turn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::hub) enum TurnCut {
    /// Refuses the move (`transfer.busy`): no `interrupt`, no `atToolBoundary`.
    Refuse,
    /// Cuts it now (`interrupt`), a tool call in flight or not.
    Now,
    /// Cuts it only while no tool call of it runs (`atToolBoundary`): between a tool's result and
    /// the model's next step, or while it waits on the person's permission, when nothing it
    /// started is under way. Else `transfer.tool_in_flight`, and the client asks again. Every tool
    /// result so far is in the agent's transcript, which the bundle carries, and the turn's
    /// continuation (`restart_resume.rs` `Cut::Move`) goes on from it on the target. Leo,
    /// 2026-11-21: "you're supposed to be able to move shit while it's running. that's teh whole
    /// point."
    AtToolBoundary,
}

/// The `transfer.` code of a begin that waits for a tool call to end ([`TurnCut::AtToolBoundary`]).
pub(crate) const TOOL_IN_FLIGHT: &str = "tool_in_flight";

/// Whether a tool call `doing` holds in flight runs: one that only waits on the person's answer to
/// a permission request in `pending` (`Session::pending_permissions`) has not started.
pub(in crate::hub) fn tool_runs(
    doing: &super::activity::TurnActivity,
    pending: &[(String, Value)],
) -> bool {
    if doing.open_past_cap > 0 {
        return true;
    }
    let asked: std::collections::BTreeSet<&str> = pending
        .iter()
        .filter_map(|(_, r)| r.pointer("/toolCall/toolCallId").and_then(Value::as_str))
        .collect();
    doing.open_tools.iter().any(|id| !asked.contains(id.as_str()))
}

fn transfer_error(what: &str, message: impl std::fmt::Display) -> RpcError {
    RpcError::new(-32000, format!("transfer.{what}: {message}"))
}

/// Claim the one move lease while its caller holds `Session::moving`.
fn claim_transfer(moving: &mut Option<String>, transfer_id: &str) -> bool {
    if moving.is_some() {
        return false;
    }
    *moving = Some(transfer_id.to_owned());
    true
}

/// Reads the fencing epoch persisted beside an outgoing transfer. Old bundles have no marker and
/// are treated as epoch zero for compatibility with a daemon that predates fencing.
pub(super) fn transfer_epoch(dir: &Path) -> Result<u64, RpcError> {
    Ok(transfer_epoch_marker(dir)?.unwrap_or(0))
}

/// Reads the marker without treating a crash before marker creation as epoch zero. Callers that
/// already have the session owner can safely use that owner epoch when this returns `None`.
pub(super) fn transfer_epoch_marker(dir: &Path) -> Result<Option<u64>, RpcError> {
    let path = dir.join("epoch");
    let raw = match std::fs::read_to_string(&path) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(transfer_error("epoch", error)),
    };
    let value = raw.trim().parse::<u64>().map_err(|error| {
        transfer_error("epoch", format!("invalid epoch marker {}: {error}", path.display()))
    })?;
    Ok(Some(value))
}

/// Reject a delayed request from an older owner. Missing epochs remain accepted for old clients;
/// all current clients include one, and any supplied value must match exactly.
pub(super) fn check_epoch(expected: u64, supplied: Option<u64>) -> Result<(), RpcError> {
    if let Some(supplied) = supplied.filter(|epoch| *epoch != expected) {
        return Err(transfer_error(
            "stale_epoch",
            format!("ownership epoch is {expected}, request carried {supplied}"),
        )
        .with_data(json!({"epoch": expected})));
    }
    Ok(())
}

/// Missing is the legacy protocol; an explicit non-number is malformed and must not be treated
/// as epoch zero.
pub(super) fn parse_epoch(value: Option<&Value>) -> Result<Option<u64>, RpcError> {
    let Some(value) = value else { return Ok(None) };
    value
        .as_u64()
        .map(Some)
        .ok_or_else(|| transfer_error("epoch", "epoch must be an unsigned integer"))
}

/// Current protocol calls must carry the lease. Epoch-zero requests are accepted only for
/// bundles produced by older daemons.
pub(super) fn require_epoch(expected: u64, supplied: Option<u64>) -> Result<(), RpcError> {
    if expected != 0 && supplied != Some(expected) {
        return Err(transfer_error(
            "stale_epoch",
            format!("ownership epoch is {expected}, request carried {supplied:?}"),
        )
        .with_data(json!({"epoch": expected})));
    }
    check_epoch(expected, supplied)
}

pub(super) fn require_valid_epoch(session: &Session) -> Result<u64, RpcError> {
    if !session.ownership_epoch_is_valid() {
        return Err(transfer_error(
            "epoch_unreadable",
            "ownership history is unreadable; refusing transfer writes",
        ));
    }
    Ok(session.ownership_epoch())
}

/// A target may receive a newer move after its closed copy was moved away, but never an older
/// bundle that could resurrect a fenced owner. This is used only at receive admission; writes
/// and finish remain exact-match checks against the persisted manifest.
pub(super) fn reject_stale_epoch(current: u64, incoming: u64) -> Result<(), RpcError> {
    if incoming < current {
        return Err(transfer_error(
            "stale_epoch",
            format!("ownership epoch is {current}, request carried {incoming}"),
        )
        .with_data(json!({"epoch": current})));
    }
    Ok(())
}

/// The `moving` mark of a chat that moved away (`SessionMeta::moved_to`), restored at load: no
/// move has that id, so it is never committed, aborted or watched again.
pub(super) const MOVED_AWAY: &str = "moved-away";

/// The `moving` mark of a chat being imported here (`transfer.rs` `import_into`): published
/// frozen and freed once its own `imported` receipt is logged. No move has that id.
pub(super) const IMPORTING: &str = "importing";

/// The `moving` mark of a chat whose log could not be read at load (`queue.rs`
/// `restore_queue`): whether a move of it began is unknown, so it stays frozen, as a move would
/// keep it, until a later load reads its log. No move has that id.
pub(super) const LOG_UNREADABLE: &str = "log-unreadable";

/// The `moving` mark a load restores from its log scan: the scan's own when it read the log,
/// else frozen (`LOG_UNREADABLE`). An unreadable log may hold a move that began here, so the
/// chat never runs beside the copy that may be running on its target.
pub(super) fn restored_moving(scanned: bool, moving: Option<String>) -> Option<String> {
    if scanned { moving } else { moving.or_else(|| Some(LOG_UNREADABLE.to_owned())) }
}

/// Whether a `moving` mark names a move (its transfer id), not a mark that only freezes the
/// chat (`MOVED_AWAY`, `LOG_UNREADABLE`, `IMPORTING`).
pub(super) fn names_a_move(mark: &str) -> bool {
    mark != MOVED_AWAY && mark != LOG_UNREADABLE && mark != IMPORTING && mark != super::AUTO_AWAY
}

#[path = "compaction_outline.rs"]
pub(super) mod compaction_outline;
/// Where a move's begin token is kept, in its bundle folder.
const BEGIN_TOKEN_FILE: &str = "begin-token";

/// A client's begin token: 1 to 128 of `[A-Za-z0-9_-]`.
fn is_begin_token(token: &str) -> bool {
    (1..=128).contains(&token.len())
        && token.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// The begin token the client that began move `transfer_id` gave, if it gave one: a
/// `transfer.moving` refusal hands it back, so that client alone can tell the move is its own.
pub(super) fn moving_begin_token(transfer_id: &str) -> Option<String> {
    if !names_a_move(transfer_id) {
        return None;
    }
    let dir = inside(&transfers_dir(), transfer_id).ok()?;
    let token = std::fs::read_to_string(dir.join(BEGIN_TOKEN_FILE)).ok()?;
    let token = token.trim();
    is_begin_token(token).then(|| token.to_owned())
}

#[cfg(test)]
#[path = "auto_startup_tests.rs"]
mod auto_startup_tests;
#[cfg(test)]
#[path = "restore_freeze_tests.rs"]
mod restore_freeze_tests;
#[path = "transfer_history.rs"]
pub(super) mod transfer_history;
#[path = "transfer_live.rs"]
pub(super) mod transfer_live;
#[path = "transfer_precopy.rs"]
pub(super) mod transfer_precopy;

/// The longest a move that waits for the running turn (`afterTurn`) waits for it to end. The
/// turn lock is fair, so a prompt queued before the move runs first; the queue's later prompts
/// move with the chat.
const AFTER_TURN_WAIT: std::time::Duration = std::time::Duration::from_secs(15 * 60);
/// How often a move that waits for the running turn looks again for a turn that holds no lock.
const AFTER_TURN_POLL: std::time::Duration = std::time::Duration::from_millis(250);

/// How long a `transfer_begin` with `afterTurn` waits for the running turn: its
/// `afterTurnTimeoutMs` (the mover's `--timeout`), at most [`AFTER_TURN_WAIT`]; that when absent.
pub(super) fn after_turn_wait(params: &Value) -> std::time::Duration {
    params
        .get("afterTurnTimeoutMs")
        .and_then(Value::as_u64)
        .map(std::time::Duration::from_millis)
        .map_or(AFTER_TURN_WAIT, |d| d.min(AFTER_TURN_WAIT))
}

/// What a chat that moved away answers a start: where it went.
pub(super) fn moved_error(to: &Value) -> RpcError {
    let host = to["host"].as_str().map(|h| format!(" to {h}")).unwrap_or_default();
    let id = to["sessionId"].as_str().map(|s| format!(" as {s}")).unwrap_or_default();
    transfer_error("moved", format!("this chat moved{host}{id}; it runs there, never here"))
        .with_data(json!({"movedTo": to}))
}

impl Hub {
    /// `_acpmux/transfer_*`, for the local socket and peers only: a bundle holds the whole chat.
    pub async fn transfer_request(
        self: &Arc<Self>,
        m: &str,
        params: &Value,
    ) -> Result<Value, RpcError> {
        let text = |k: &str| params.get(k).and_then(Value::as_str).unwrap_or("");
        match m.strip_prefix("_acpmux/transfer_").unwrap_or("") {
            "begin" => {
                let session = self.resolve(text("sessionId"))?;
                let interrupt = params.get("interrupt").and_then(Value::as_bool) == Some(true);
                let to = params.get("to");
                let socket = to.and_then(|to| to.get("socket")).and_then(Value::as_str);
                let ssh = to.and_then(|to| to.get("ssh")).and_then(Value::as_str);
                if let Some(host) = ssh
                    && (crate::cli::hosts::checked_host(host).is_err()
                        || !socket.is_some_and(|s| {
                            s.starts_with('/') && crate::cli::hosts::plain_path(s)
                        }))
                {
                    return Err(RpcError::invalid_params(
                        "transfer: `to.ssh` needs a plain ssh host and an absolute `to.socket`",
                    ));
                }
                let host = to.and_then(|to| to.get("host")).and_then(Value::as_str);
                let host = host.filter(|h| crate::cli::hosts::checked_host(h).is_ok());
                // A machine only the team hub reaches: its hub `daemonId`, which alone may pull
                // the move's pages (`transfer_pull.rs`).
                let hub = to.and_then(|to| to.get("hub")).and_then(Value::as_str);
                if let Some(hub) = hub {
                    let plain = (8..=128).contains(&hub.len())
                        && hub.bytes().all(|b| b.is_ascii_alphanumeric() || b"+/=_-".contains(&b));
                    if !plain || socket.is_some() || ssh.is_some() {
                        return Err(RpcError::invalid_params(
                            "transfer: `to.hub` needs a plain hub daemon id, and no socket or ssh",
                        ));
                    }
                }
                // The client hands the bundle only to a receiver whose own `initialize` listed
                // queue approval when it carries approved prompts that still wait.
                let gates = params.get("gatesQueueApproval").and_then(Value::as_bool) == Some(true);
                // A pre-copied move (`transfer_precopy.rs`): the bundle holds only what follows.
                let precopy = match (params.get("prepareId"), params.get("afterSeq")) {
                    (None, None) => None,
                    (Some(Value::String(id)), Some(after)) if after.is_u64() => {
                        Some((id.as_str(), after.as_u64().unwrap_or(0)))
                    }
                    _ => {
                        return Err(RpcError::invalid_params(
                            "transfer: `prepareId` and `afterSeq` go together",
                        ));
                    }
                };
                // Wait for a running turn to end on its own, then move (`AFTER_TURN_WAIT`).
                let after_turn =
                    !interrupt && params.get("afterTurn").and_then(Value::as_bool) == Some(true);
                // A running turn is cut only between its tool calls (`transfer_begin`).
                let at_boundary =
                    params.get("atToolBoundary").and_then(Value::as_bool) == Some(true);
                let cut = match (interrupt, at_boundary) {
                    (true, _) => TurnCut::Now,
                    (false, true) => TurnCut::AtToolBoundary,
                    (false, false) => TurnCut::Refuse,
                };
                // `afterTurnTimeoutMs`: the mover's `--timeout`, never past `AFTER_TURN_WAIT`.
                let turn_wait = after_turn.then(|| after_turn_wait(params));
                // The client's own mark for this begin, handed back by a `transfer.moving`
                // refusal of the move it began (`begin_token`).
                let token = params.get("beginToken").and_then(Value::as_str);
                if token.is_some_and(|t| !is_begin_token(t)) {
                    return Err(RpcError::invalid_params(
                        "transfer: `beginToken` must be 1 to 128 of [A-Za-z0-9_-]",
                    ));
                }
                let to = (socket, ssh, host, hub);
                self.transfer_begin(&session, (cut, turn_wait), to, gates, token, precopy).await
            }
            "hub" => self.transfer_hub(params).await,
            "prepare" => {
                // `historyLater: {keepTurns}`: the history follows the chat (`transfer_history.rs`).
                let keep = params.get("historyLater").filter(|l| !l.is_null());
                let keep = keep.map(|l| l.get("keepTurns").and_then(Value::as_u64).unwrap_or(1));
                // A prepare copies the whole history: off the runtime's workers, so the chat
                // and every other one answer while it runs (`qos::off_worker`, cmux#54461).
                let session = self.resolve(text("sessionId"))?;
                crate::qos::off_worker(|| self.transfer_prepare(&session, params.get("base"), keep))
            }
            "history_have" => self.transfer_history_have(params),
            "history_export" => {
                self.transfer_history_export(&self.resolve(text("sessionId"))?, params)
            }
            "history" => self.transfer_history(&self.resolve(text("sessionId"))?, params),
            "base" => self.transfer_base(params),
            "stage" => self.transfer_stage(params),
            // Rewrites the staged prefix whole: off the runtime's workers too.
            "stage_finish" => crate::qos::off_worker(|| self.transfer_stage_finish(params)),
            "digest" => self.transfer_digest(params),
            "end_stale" => self.transfer_end_stale(params).await,
            "progress" => self.transfer_progress(params),
            "read" => {
                let offset = params.get("offset").and_then(Value::as_u64).unwrap_or(0);
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(1 << 20);
                self.transfer_read(
                    text("transferId"),
                    text("path"),
                    offset,
                    limit,
                    parse_epoch(params.get("epoch"))?,
                )
            }
            "renew" => {
                let transfer_id = text("transferId");
                let dir = inside(&transfers_dir(), transfer_id)?;
                require_epoch(transfer_epoch(&dir)?, parse_epoch(params.get("epoch"))?)?;
                if !dir.is_dir() {
                    return Err(transfer_error("unknown", format!("no move {transfer_id} here")));
                }
                super::transfer_watch::note_activity(&dir, None);
                Ok(json!({"transferId": transfer_id, "epoch": transfer_epoch(&dir)?}))
            }
            "commit" => {
                let session = self.resolve(text("sessionId"))?;
                let to = params.get("to").cloned().unwrap_or(Value::Null);
                // What the client measured of the freeze (`{ms, bytes}`), for the receipt.
                let freeze = params.get("freeze").filter(|f| f.is_object()).cloned();
                self.transfer_commit_with_epoch(
                    &session,
                    text("transferId"),
                    to,
                    parse_epoch(params.get("epoch"))?,
                    freeze,
                )
                .await
            }
            "abort" => {
                let session = self.resolve(text("sessionId"))?;
                self.transfer_abort_with_epoch(
                    &session,
                    text("transferId"),
                    None,
                    parse_epoch(params.get("epoch"))?,
                )
            }
            "preflight" => self.transfer_preflight(params).await,
            "receive" => self.transfer_receive(params).await,
            "write" => self.transfer_write(params),
            "finish" => self.transfer_finish(params).await,
            "forget" => self.transfer_forget(params).await,
            _ => Err(RpcError::method_not_found(m)),
        }
    }

    /// This machine's route back as the owner of its agent memory, for a chat leaving it
    /// (`memory_follow::route_back`): its `remoteDaemon` through its hub carrier. A config being
    /// written right now reads as no route, as a machine with none does.
    fn memory_route_back(&self) -> Option<crate::memory_follow::Followed> {
        #[cfg(feature = "hub-carrier")]
        {
            let remote_daemon = self.config.try_read().ok()?.remote_daemon.clone();
            let key = self.hub_carrier.get().map(|c| c.public_key());
            crate::memory_follow::route_back(remote_daemon.as_deref(), key.as_deref())
        }
        #[cfg(not(feature = "hub-carrier"))]
        None
    }

    /// Freezes the chat for its move and makes its bundle. With `after_turn` (how long to wait), a
    /// running turn is neither refused nor stopped: the move first waits (that long) for the
    /// turn lock, unfrozen, so the turn ends on its own and every prompt sent meanwhile queues
    /// as usual; holding the lock, it freezes the chat and the queue moves with the bundle. With
    /// `precopy` (a prepare and its last seq), the bundle holds the log past that seq alone, once
    /// the prefix is checked (`transfer_precopy.rs`).
    #[allow(clippy::too_many_arguments)]
    async fn transfer_begin(
        self: &Arc<Self>,
        session: &Arc<Session>,
        (cut, after_turn): (TurnCut, Option<std::time::Duration>),
        (to, to_ssh, to_host, to_hub): (Option<&str>, Option<&str>, Option<&str>, Option<&str>),
        gates_receiver: bool,
        begin_token: Option<&str>,
        precopy: Option<(&str, u64)>,
    ) -> Result<Value, RpcError> {
        if !session.ownership_epoch_is_valid() {
            return Err(transfer_error(
                "epoch_unreadable",
                "ownership history is unreadable; refusing to begin a transfer",
            ));
        }
        // A stopped chat moves (its bundle is its whole history); one that moved away never
        // does again.
        if let Some(to) = session.meta().moved_to {
            return Err(moved_error(&to));
        }
        // Taken before the freeze, so nothing is refused while the turn finishes: its
        // permission answers, steering and new prompts go in as usual.
        // The lock alone is not the turn: a turn an agent host runs (a chat whose host is
        // another build's, `hosts.rs`) or one recovered from it holds no lock, so the wait is
        // for both the lock and no turn (2026-11-22: `--after-turn` refused a coordinator's move
        // at once with "a turn is running").
        let early = if let Some(wait) = after_turn {
            let deadline = tokio::time::Instant::now() + wait;
            let busy = || {
                let why = format!(
                    "the running turn did not end within {}s, so nothing moved; --interrupt stops it and moves the chat now",
                    wait.as_secs()
                );
                transfer_error("busy", why)
            };
            loop {
                let left = deadline.saturating_duration_since(tokio::time::Instant::now());
                let Ok(guard) = tokio::time::timeout(left, session.turn_lock.lock()).await else {
                    return Err(busy());
                };
                if session.turn().is_none() {
                    break Some(guard);
                }
                drop(guard);
                if tokio::time::Instant::now() >= deadline {
                    return Err(busy());
                }
                tokio::time::sleep(AFTER_TURN_POLL).await;
            }
        } else {
            None
        };
        // The wait may have outlasted the chat's stay here (another move took it meanwhile).
        if let Some(to) = session.meta().moved_to {
            return Err(moved_error(&to));
        }
        self.refuse_while_history_awaited(session)?;
        let transfer_id = uuid::Uuid::now_v7().to_string();
        self.sweep();
        // The freeze begins when the chat is marked moving, just below: its length to this
        // begin's answer is `frozenMs`, the share of a move's freeze this daemon can time.
        let frozen_at = std::time::Instant::now();
        // This begin holds the move's watch until it starts it, below: a watch that ran now
        // would read no `alive` stamp and end the move under it (`transfer_watch.rs`). Claimed
        // under the `moving` lock, so whoever sees the chat in this move sees the claim too.
        // If the old driver stopped heartbeating before it read the bundle to its end, abort
        // that fenced move first. The target cannot have finished such a bundle, so retrying
        // cannot create a second chat or lose the original.
        let lease = *self.transfer_lease.lock().unwrap_or_else(|e| e.into_inner());
        let watch = loop {
            let other = session.moving();
            let Some(other) = other else {
                let mut moving = session.moving.lock().unwrap_or_else(|e| e.into_inner());
                if claim_transfer(&mut moving, &transfer_id) {
                    let watch = self.claim_move_watch(&transfer_id);
                    break watch;
                }
                continue;
            };
            let old_dir = transfers_dir().join(&other);
            let idle = super::transfer_watch::idle_for(&old_dir);
            let fully_read = super::transfer_watch::fully_read(&old_dir);
            if super::transfer_watch::takeover_allowed(idle, fully_read, lease) {
                let epoch =
                    transfer_epoch_marker(&old_dir)?.or_else(|| Some(session.ownership_epoch()));
                if self
                    .transfer_abort_with_epoch(session, &other, Some("stalled_driver"), epoch)
                    .is_ok()
                {
                    continue;
                }
            }
            let age = idle.map_or_else(|| "an unknown time".to_owned(), |d| format!("{d:?} ago"));
            let e = transfer_error(
                "moving",
                format!(
                    "this chat is already being moved by transfer {other} (last heartbeat {age}); retry after the {}-second lease to take it over",
                    lease.as_secs()
                ),
            );
            let mut data = json!({"transferId": other, "idle": idle.map(|d| d.as_secs()), "takeover": "retry after the lease"});
            if let Some(token) = moving_begin_token(&other) {
                data.set("beginToken", json!(token));
            }
            return Err(e.with_data(data));
        };
        // The move fence is the freeze boundary. It is taken only after an optional
        // `--after-turn` wait and before cancelling a running turn or exporting its bundle.
        let freeze_started_at_ms = crate::store::now_ms();
        // Fence every prior owner before any bundle bytes are exposed. The marker is persisted
        // before transfer_out so a daemon restart restores the same epoch while this move is in flight.
        let dir = transfers_dir().join(&transfer_id);
        // The continuation of a turn the move stops (`restart_resume.rs`, `Cut::Move`): logged
        // before the Stop, which would leave the turn none, so the bundle's queue carries it and
        // the turn goes on where the chat lands. A move that does not happen queues it here.
        let mut carried: Option<String> = None;
        let unfreeze = |e: RpcError, carried: Option<&str>| {
            let _ = crate::home_fs::remove_dir_all(&dir);
            self.end_move(session);
            if let Some(id) = carried {
                self.queue_carried(session, id);
            }
            e
        };
        // No turn may run while the bundle is made: one that runs stops only if asked.
        if let Some(running) = session.turn().map(|t| t.turn_id) {
            match cut {
                TurnCut::Refuse => {
                    return Err(unfreeze(transfer_error("busy", "a turn is running"), None));
                }
                TurnCut::AtToolBoundary | TurnCut::Now => {}
            }
            // A Stop while Claude compacts withdraws the person's queued prompts (`cancel.rs`):
            // the move waits for the compaction instead of losing them.
            let child = session.child.lock().await.clone();
            let compacting = session.compacting.load(std::sync::atomic::Ordering::SeqCst)
                || child.is_some_and(|c| c.translator.as_ref().is_some_and(|t| t.is_compacting()));
            if compacting {
                let e = transfer_error("busy", "the chat is compacting; move it once that ends");
                return Err(unfreeze(e, None));
            }
            // `TurnCut::AtToolBoundary`: the turn's tool calls are read fresh here, after the
            // last await before the Stop is sent, so the window is the agent's own step from
            // here to the Stop. A call it starts in that window is cut with the turn, as
            // `interrupt` cuts it, and the continuation names it (`restart_resume.rs`); only a
            // harness that stops at a boundary on its own could close it.
            if cut == TurnCut::AtToolBoundary
                && session
                    .turn()
                    .is_some_and(|t| tool_runs(&t.doing, &session.pending_permissions()))
            {
                let e = transfer_error(
                    TOOL_IN_FLIGHT,
                    "a tool call of the running turn is in flight; the move cuts the turn once it ends",
                );
                return Err(unfreeze(e, None));
            }
            // At a tool boundary with no background work of the turn's, nothing was cut short:
            // the continuation says so, and Claude Code goes on from its own transcript with no
            // prompt of acpmux's (`claude_stdio/resume_cut.rs`). `--interrupt`, or a turn with a
            // background shell or subagent (which did not come along and must be told so), keeps
            // the continuation's text.
            let how = if cut == TurnCut::AtToolBoundary && !self.runs_background_work(session) {
                super::auto_resume::Cut::MoveAtBoundary
            } else {
                super::auto_resume::Cut::Move
            };
            carried = self.cut_turn_to_move(session, &running, how).await;
        }
        let carried = carried.as_deref();
        let guard = match early {
            Some(guard) => guard,
            None => {
                let wait =
                    std::time::Duration::from_secs(if cut == TurnCut::Refuse { 2 } else { 20 });
                let Ok(guard) = tokio::time::timeout(wait, session.turn_lock.lock()).await else {
                    let e = transfer_error("busy", "the running turn did not stop");
                    return Err(unfreeze(e, carried));
                };
                guard
            }
        };
        // A turn recovered from an agent host runs before its task takes the lock (`hosts.rs`).
        if session.turn().is_some() {
            drop(guard);
            return Err(unfreeze(transfer_error("busy", "a recovered turn is running"), carried));
        }
        let mut steps = transfer_live::MoveSteps::new("begin");
        // Nothing appends now: the prepared prefix is the log's head, or the move is refused.
        let mut prefix = match precopy.map(|(id, after)| self.check_prefix(session, id, after)) {
            Some(Err(error)) => {
                drop(guard);
                return Err(unfreeze(error, carried));
            }
            Some(Ok(prefix)) => Some(prefix),
            None => None,
        };
        steps.step("check_prefix");
        // Export before the ownership scan so a concurrent log-scan callback cannot remove a
        // held prompt before `held_prompts` captures the move's exact queue snapshot.
        if let Err(error) = crate::home_fs::create_dirs(&dir) {
            drop(guard);
            return Err(unfreeze(
                RpcError::internal(format!("transfer: bundle dir: {error}")),
                carried,
            ));
        }
        // A history-later prepare folded its prefix and copied the agent's files: the freeze
        // reads only what came after (`transfer_precopy.rs` `PrefixFold`).
        let mut folded = prefix.as_mut().and_then(|p| p.folded.take());
        let grown = folded.as_ref().map(|f| (f.native_dir.as_path(), &f.native));
        // A whole move's bundle is its whole history: made off the runtime's workers, so the
        // daemon's other chats answer while it is (`qos::off_worker`, cmux#54461).
        let made = crate::qos::off_worker(|| {
            self.export_grown(session, &dir, prefix.as_ref().map(|p| p.after_seq), grown)
        })
        .map_err(|e| RpcError::internal(format!("transfer: bundle: {e}")))
        .and_then(|bundle| {
            let approved_waiting = match folded.as_mut() {
                Some(f) => self.held_prompts_from(std::mem::take(&mut f.held), &bundle)?,
                None => {
                    let prefix_seq = prefix.as_ref().map(|p| (session.id.as_str(), p.after_seq));
                    self.held_prompts_with(prefix_seq, &bundle)?
                }
            };
            if !approved_waiting.is_empty() && !gates_receiver {
                return Err(approved_prompts_error(
                    json!(approved_waiting),
                    "the move's client does not check that its receiver approves",
                ));
            }
            let files = bundle_files(&bundle)
                .map_err(|e| RpcError::internal(format!("transfer: bundle: {e}")))?;
            Ok((files, approved_waiting))
        });
        steps.step("export");
        let (files, approved_waiting) = match made {
            Ok(made) => made,
            Err(error) => {
                // Preserve the historical rejection receipt even though export now precedes
                // fencing: callers and recovery use this durable abort to clear the attempted
                // move without leaving a transfer_out record for a bundle never offered.
                let record = json!({"transferId": transfer_id, "epoch": session.ownership_epoch()});
                let (_, logged) =
                    self.append_at(session, "mux", "transfer_aborted", record, None, None);
                drop(guard);
                return Err(if logged { unfreeze(error, carried) } else { error });
            }
        };
        let restored = match (&folded, &prefix) {
            (Some(f), Some(p)) => self
                .ownership_epoch_after(&session.id, p.after_seq, f.epoch)
                .map(|epoch| session.restore_ownership_epoch(epoch)),
            _ => self.restore_ownership_epoch(session),
        };
        if let Err(error) = restored {
            drop(guard);
            return Err(unfreeze(
                transfer_error("store", format!("ownership epoch unreadable: {error}")),
                carried,
            ));
        }
        steps.step("epoch");
        let epoch = session.bump_ownership_epoch();
        if let Err(error) = crate::home_fs::write(dir.join("epoch"), epoch.to_string()) {
            drop(guard);
            return Err(unfreeze(
                RpcError::internal(format!("transfer: epoch marker: {error}")),
                carried,
            ));
        }
        let (_, logged) = self.append_at(
            session,
            "mux",
            "transfer_out",
            json!({"transferId": transfer_id, "continues": carried, "epoch": epoch}),
            None,
            None,
        );
        if !logged {
            drop(guard);
            return Err(unfreeze(
                transfer_error("store", "could not durably record transfer_out"),
                carried,
            ));
        }
        steps.step("transfer_out");
        drop(guard);
        if let Some(socket) = to {
            let _ = crate::home_fs::write(dir.join("to"), socket);
        }
        if let Some(host) = to_ssh {
            let _ = crate::home_fs::write(dir.join("to-ssh"), host);
        }
        if let Some(host) = to_host {
            let _ = crate::home_fs::write(dir.join("to-host"), host);
        }
        // Written before the begin answers: no page is served before it names the target.
        if let Some(daemon) = to_hub
            && let Err(error) =
                crate::home_fs::write(dir.join(super::transfer_pull::TO_HUB), daemon)
        {
            tracing::warn!(session = %session.id, transfer_id = %transfer_id, "recording a hub move's target: {error}");
        }
        if let Some(id) = carried {
            let _ = crate::home_fs::write(dir.join("continues"), id);
        }
        // Beside the bundle, which a restart keeps while the log says the move runs
        // (`queue_restore.rs`), and written only once the move is begun: a client that lost
        // this answer ends only a move whose begin is done.
        if let Some(token) = begin_token {
            let _ = crate::home_fs::write(dir.join(BEGIN_TOKEN_FILE), token);
        }
        if let Some(prefix) = &prefix {
            let _ = crate::home_fs::write(dir.join("prepared"), &prefix.prepare_id);
        }
        let _ = crate::home_fs::write(dir.join("epoch"), epoch.to_string());
        super::transfer_watch::note_activity(&dir, None);
        if let Some(watch) = watch {
            self.watch_claimed(session, watch);
        }
        let files: Vec<Value> =
            files.into_iter().map(|(path, size)| json!({"path": path, "size": size})).collect();
        let schema = if session.meta().harness == "cmux-harness" {
            DURABLE_TRANSFER_SCHEMA
        } else {
            TRANSFER_SCHEMA
        };
        let mut answer = json!({
            "schema": schema,
            "transferId": transfer_id,
            "sessionId": session.id,
            "files": files,
            "session": self.session_summary(session),
            "epoch": epoch,
            "freezeStartedAtMs": freeze_started_at_ms,
            "frozenMs": u64::try_from(frozen_at.elapsed().as_millis()).unwrap_or(u64::MAX),
        });
        if let Some(id) = carried {
            answer.set("continues", json!(id));
        }
        // The chat's agent memory goes with it (`memory_follow.rs`).
        let settings = crate::user_settings::text();
        let memory = crate::memory_follow::outgoing(
            settings.as_deref(),
            &session.meta().session_env,
            self.memory_route_back(),
        );
        if let Some(memory) = memory {
            answer.set(crate::memory_follow::MANIFEST_FIELD, memory);
        }
        // The agent program its harness runs here: a receiver with no harness of that name
        // checks `--as` against it and names its own one for the same agent (`transfer_in.rs`).
        let meta = session.meta();
        let family = self.config.read().await.family(&meta.harness).or(meta.family);
        if let Some(family) = family {
            answer.set("harnessFamily", json!(family));
        }
        if let Some(p) = prefix {
            let named =
                json!({"prepareId": p.prepare_id, "afterSeq": p.after_seq, "token": p.token});
            answer.set("prefix", named);
        }
        // The receiver refuses the bundle unless it understands them (`transfer_in.rs`), and the
        // client hands it only to one that listed queue approval.
        if !approved_waiting.is_empty() {
            answer.set("approvedWaiting", json!(approved_waiting));
        }
        if let Some(manifest) = std::fs::read_to_string(dir.join(&session.id).join("manifest.json"))
            .ok()
            .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        {
            answer.set("harness", manifest.get("harness").cloned().unwrap_or(Value::Null));
        }
        Ok(answer)
    }

    /// A page of one of a move's bundle files.
    fn transfer_read(
        &self,
        transfer_id: &str,
        path: &str,
        offset: u64,
        limit: u64,
        epoch: Option<u64>,
    ) -> Result<Value, RpcError> {
        let root = self.transfer_bundle(transfer_id)?;
        let dir = transfers_dir().join(transfer_id);
        require_epoch(transfer_epoch(&dir)?, epoch)?;
        let file = inside(&root, path)?;
        use std::io::{Read, Seek};
        let page = || -> std::io::Result<(Vec<u8>, u64, u64)> {
            let mut f = std::fs::File::open(&file)?;
            let len = f.metadata()?.len();
            let start = offset.min(len);
            let mut data = vec![0; limit.clamp(1, MAX_PAGE).min(len - start) as usize];
            f.seek(std::io::SeekFrom::Start(start))?;
            f.read_exact(&mut data)?;
            Ok((data, start, len))
        };
        let _pages = super::transfer_watch::PAGES.lock().unwrap_or_else(|e| e.into_inner());
        // The watch may have aborted the move since `transfer_bundle` found it.
        if !dir.is_dir() {
            return Err(transfer_error("unknown", format!("no move {transfer_id} here")));
        }
        let (data, start, len) = page().map_err(|e| transfer_error("read", e))?;
        let next = start + data.len() as u64;
        super::transfer_watch::note_paged(&dir);
        super::transfer_watch::note_activity(&dir, (next == len).then_some(path));
        Ok(json!({"data": BASE64.encode(&data), "next": next, "eof": next == len}))
    }

    /// `sweep_transfers`, keeping every move a chat here is in.
    pub(super) fn sweep(&self) {
        let moving: Vec<String> = self.sessions().iter().filter_map(|s| s.moving()).collect();
        sweep_transfers(&moving);
    }

    /// The bundle directory of a move this daemon began.
    fn transfer_bundle(&self, transfer_id: &str) -> Result<PathBuf, RpcError> {
        // A receive (`in-…`) is not a move out.
        if transfer_id.to_ascii_lowercase().starts_with("in-") {
            return Err(RpcError::not_found(format!("transfer.unknown: no move {transfer_id:?}")));
        }
        let dir = inside(&transfers_dir(), transfer_id)?;
        let entries = std::fs::read_dir(&dir).map_err(|_| {
            RpcError::not_found(format!("transfer.unknown: no move {transfer_id:?} here"))
        })?;
        // The bundle is its one directory; beside it, `transfer_watch.rs`'s files.
        match entries.flatten().find(|entry| entry.path().is_dir()) {
            Some(entry) => Ok(entry.path()),
            None => Err(RpcError::not_found(format!("transfer.unknown: no move {transfer_id:?}"))),
        }
    }

    /// The move the session is in, or an error naming the one it is in (or that it is in none).
    fn moving_as(session: &Session, transfer_id: &str) -> Result<(), RpcError> {
        match session.moving() {
            // A mark that only freezes the chat is no move a caller may end.
            Some(id) if id == transfer_id && names_a_move(&id) => Ok(()),
            other => Err(transfer_error("unknown", "the chat is not in this move")
                .with_data(json!({"transferId": other}))),
        }
    }

    /// The chat lives on the target now: its queue is withdrawn here (the target runs it), its
    /// draft and bookmarks cleared, and it closes.
    pub(super) async fn transfer_commit_with_epoch(
        &self,
        session: &Arc<Session>,
        transfer_id: &str,
        to: Value,
        epoch: Option<u64>,
        freeze: Option<Value>,
    ) -> Result<Value, RpcError> {
        let dir = transfers_dir().join(transfer_id);
        let current = require_valid_epoch(session)?;
        require_epoch(current, epoch)?;
        Self::moving_as(session, transfer_id)?;
        // Committed already (by the source's own watch, or a retried commit). A stopped chat
        // is closed before its move, so the mark is where it went, not its status.
        if session.meta().moved_to.is_some() {
            return Ok(
                json!({"sessionId": session.id, "transferId": transfer_id, "committed": true}),
            );
        }
        if let Some(epoch) = transfer_epoch_marker(&dir)? {
            check_epoch(current, Some(epoch))?;
        }
        for q in session.queue() {
            self.remove_queued(session, &q.prompt_id);
        }
        {
            // The chat's draft and bookmarks live on the target now, and the chat with them.
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            meta.composer_draft = None;
            meta.bookmarks.clear();
            meta.moved_to = Some(if to.is_object() { to.clone() } else { json!({}) });
        }
        // Saved now: a stopped chat is closed already, so `kill` below saves nothing, and the
        // mark must outlive a restart or the source could reopen and run it: `committed` is
        // answered only once it is on disk.
        self.save_meta_answered(session)?;
        let mut moved =
            json!({"transferId": transfer_id, "to": to, "epoch": session.ownership_epoch()});
        if let Some(freeze) = freeze {
            moved.set("freeze", freeze);
        }
        self.append(session, "mux", "transferred", moved);
        self.kill(session, false).await?;
        self.note_shipped(session, transfer_id);
        transfer_precopy::forget_prepared(&dir);
        let _ = crate::home_fs::remove_dir_all(transfers_dir().join(transfer_id));
        Ok(json!({"sessionId": session.id, "transferId": transfer_id, "committed": true}))
    }

    /// `_acpmux/set_policy`: a chat being moved keeps the rules it moves with.
    pub async fn set_policy_unless_moving(
        self: &Arc<Self>,
        session: &Arc<Session>,
        policy: crate::config::PermissionPolicy,
    ) -> Result<(), RpcError> {
        if session.moving().is_some() {
            return Err(super::queue::moving_error(session));
        }
        self.set_policy_answered(session, policy).await
    }

    /// The move did not happen: the chat takes prompts and runs its queue again. `reason` says
    /// why when the source ended it itself (`transfer_watch.rs`). A policy that changed while it
    /// moved (a deny-all default skips a moving chat, `policy_mode.rs`) is followed now.
    pub(super) fn transfer_abort_with_epoch(
        self: &Arc<Self>,
        session: &Arc<Session>,
        transfer_id: &str,
        reason: Option<&str>,
        epoch: Option<u64>,
    ) -> Result<Value, RpcError> {
        let dir = transfers_dir().join(transfer_id);
        let current = require_valid_epoch(session)?;
        require_epoch(current, epoch)?;
        Self::moving_as(session, transfer_id)?;
        if session.meta().moved_to.is_some() {
            return Err(transfer_error(
                "closed",
                "the move committed; the chat lives on the target",
            ));
        }
        if let Some(epoch) = transfer_epoch_marker(&dir)? {
            check_epoch(current, Some(epoch))?;
        }
        let mut record = json!({"transferId": transfer_id});
        record.set("epoch", json!(session.ownership_epoch()));
        if let Some(reason) = reason {
            record.set("reason", json!(reason));
        }
        // Logged while the chat is still frozen: a new move begins only after it, so this
        // record never follows (and undoes) a newer `transfer_out` (`transfer_authority.rs`).
        // One that never reached the log leaves it frozen, as its `transfer_out` says.
        let (_, logged) = self.append_at(session, "mux", "transfer_aborted", record, None, None);
        if !logged {
            return Err(transfer_error("store", "could not durably record transfer_aborted"));
        }
        let carried = std::fs::read_to_string(dir.join("continues")).ok();
        self.end_move(session);
        if let Some(id) = carried.as_deref().map(str::trim).filter(|id| !id.is_empty()) {
            self.queue_carried(session, id);
        }
        let _ = crate::home_fs::remove_dir_all(dir);
        Ok(json!({"sessionId": session.id, "transferId": transfer_id, "aborted": true}))
    }

    /// A move that stopped a turn and then did not happen: the continuation it logged
    /// (`transfer_begin`) joins the queue here, at its head, and runs, as it would have where
    /// the chat was going. Only that prompt is taken from the log, once: the rest of the live
    /// queue (an inbox digest's messages included) stays as it is.
    pub(super) fn queue_carried(self: &Arc<Self>, session: &Arc<Session>, prompt_id: &str) {
        self.restore_queue_only(session, Some(prompt_id));
        self.reword_unmoved(session, prompt_id);
        let _ = self.move_queued(session, prompt_id, 0, None);
        if !self.hold_in_protected_folder(session) {
            self.start_restored(session);
        }
    }

    /// The carried continuation was written for the machine the chat was going to: here it says
    /// the chat stayed (`Cut::unmoved`), or the agent reports its turn finished there. Logged as
    /// an edit that keeps its provenance (`queue.rs` restores `queue_updated`), so a restart
    /// restores the same words.
    fn reword_unmoved(&self, session: &Arc<Session>, prompt_id: &str) {
        let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(q) = queue.iter_mut().find(|q| q.prompt_id == prompt_id) else {
            return;
        };
        let Some(text) = q.run.blocks.first().and_then(|b| b.get("text")).and_then(Value::as_str)
        else {
            return;
        };
        let Some(text) = super::auto_resume::Cut::unmoved(text) else {
            return;
        };
        let mut run = (*q.run).clone();
        if let Some(block) = run.blocks.first_mut() {
            block.set("text", json!(text));
        }
        q.run = Arc::new(run);
        q.preview = short_text(super::inbox::relay_body(&text), 200);
        let run = &q.run;
        let mut msg = json!({"promptId": prompt_id, "turnId": q.turn_id, "text": text, "prompt": run.blocks, "control": run.control.as_str(), "trustGate": run.trust_gate});
        // Its images, kept and named as `queued` names them (`prompt_images.rs`).
        let images = super::prompt_images::keep_sourced(&run.blocks, run.display_parts.as_ref());
        if !images.is_empty() {
            msg.set("images", Value::Array(images));
        }
        if let Some(display_parts) = &run.display_parts {
            msg.set("displayParts", display_parts.clone());
        }
        let msg = crate::prompt_provenance::marked(msg, run.provenance.as_ref());
        self.append(session, "mux", "queue_updated", msg);
    }

    /// A move that did not happen (aborted, or its begin failed) gives the chat back: a policy
    /// that changed while it moved (a deny-all default skips a moving chat, `policy_mode.rs`) is
    /// followed, then its queued prompts run again.
    pub(super) fn end_move(self: &Arc<Self>, session: &Arc<Session>) {
        *session.moving.lock().unwrap_or_else(|e| e.into_inner()) = None;
        let (hub, followed) = (self.clone(), session.clone());
        tokio::spawn(async move {
            hub.follow_policy(&followed).await;
            followed.queue_moved.notify_waiters();
        });
    }
}

#[cfg(test)]
mod fencing_tests {
    use super::*;

    #[test]
    fn a_tool_call_runs_unless_it_only_waits_on_a_permission() {
        let mut doing = super::super::activity::TurnActivity::default();
        assert!(!tool_runs(&doing, &[]), "no tool call: a move may stop the turn");
        doing.open_tools.insert("t-1".into());
        assert!(tool_runs(&doing, &[]), "a call in flight runs");
        let asked = json!({"toolCall": {"toolCallId": "t-1"}});
        assert!(!tool_runs(&doing, &[("r".into(), asked.clone())]), "it waits on the person");
        doing.open_tools.insert("t-2".into());
        assert!(tool_runs(&doing, &[("r".into(), asked)]), "another call runs beside it");
        let past = super::super::activity::TurnActivity { open_past_cap: 1, ..Default::default() };
        assert!(tool_runs(&past, &[]), "a call past the id cap runs");
    }

    #[test]
    fn a_delayed_owner_is_rejected_for_every_transfer_write_path() {
        // The four protocol operations all use the same fencing predicate. Keep this table
        // explicit so a new endpoint cannot silently accept an old host's epoch.
        for operation in ["read", "write", "commit", "abort"] {
            let error = require_epoch(9, Some(8)).expect_err(operation);
            assert!(error.message.contains("transfer.stale_epoch"));
        }
    }

    #[test]
    fn transfer_epoch_marker_survives_resume_and_only_moves_forward() {
        let dir = std::env::temp_dir().join(format!("acpmux-epoch-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("epoch"), "4").unwrap();
        assert_eq!(transfer_epoch(&dir).unwrap(), 4);
        // A resumed owner can never accept the old epoch after a retry increments it.
        assert!(require_epoch(5, Some(4)).is_err());
        assert!(require_epoch(5, Some(5)).is_ok());
        assert!(reject_stale_epoch(4, 5).is_ok());
        assert!(reject_stale_epoch(5, 4).is_err());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn malformed_epoch_marker_fails_closed() {
        let dir = std::env::temp_dir().join(format!("acpmux-epoch-bad-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("epoch"), "not-an-epoch").unwrap();
        assert!(transfer_epoch_marker(&dir).is_err());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn epoch_parser_distinguishes_legacy_missing_from_malformed() {
        assert_eq!(parse_epoch(None).unwrap(), None);
        assert_eq!(parse_epoch(Some(&json!(7))).unwrap(), Some(7));
        assert!(parse_epoch(Some(&json!("7"))).is_err());
        assert!(parse_epoch(Some(&json!(null))).is_err());
    }

    #[test]
    fn concurrent_transfer_claims_have_one_winner() {
        use std::sync::{Arc, Mutex};
        let moving = Arc::new(Mutex::new(None));
        let mut threads = Vec::new();
        for id in ["first", "second"] {
            let moving = moving.clone();
            threads.push(std::thread::spawn(move || {
                let mut moving = moving.lock().unwrap();
                claim_transfer(&mut moving, id)
            }));
        }
        let winners = threads.into_iter().filter_map(|t| t.join().ok()).filter(|won| *won).count();
        assert_eq!(winners, 1);
    }
}

#[cfg(test)]
mod after_turn_wait_tests {
    use super::{AFTER_TURN_WAIT, after_turn_wait};
    use serde_json::json;
    use std::time::Duration;

    /// Item C: the mover's `--timeout` bounds the daemon's wait for the turn, never past 15 min.
    #[test]
    fn the_movers_timeout_bounds_the_wait_for_the_turn() {
        assert_eq!(after_turn_wait(&json!({})), AFTER_TURN_WAIT);
        assert_eq!(
            after_turn_wait(&json!({"afterTurnTimeoutMs": 30_000})),
            Duration::from_secs(30)
        );
        assert_eq!(after_turn_wait(&json!({"afterTurnTimeoutMs": u64::MAX})), AFTER_TURN_WAIT);
    }
}
