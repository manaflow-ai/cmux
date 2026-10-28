//! Part of `Hub`; see `hub/mod.rs`. Moving a chat to another daemon (`acpmux.transfer.v1`): a
//! sibling build's daemon or a remote machine's. This side gives the chat away; `transfer_in.rs`
//! takes it. Any client moves it between the two (the app, a Move to Cloud service, `acpmux
//! transfer`), so neither daemon needs to reach the other:
//!
//! 1. source `_acpmux/transfer_begin {sessionId, interrupt?, to?: {socket}}`: the chat stops
//!    taking prompts and starting queued ones (a running turn refuses the move, or stops with
//!    `interrupt`), and its bundle (`transfer.rs` export) is made. Answers `{schema, transferId,
//!    sessionId, files: [{path, size}], session}`: the manifest the target takes. `to` names the
//!    target's local socket, which the source asks if the client goes away (`transfer_watch.rs`).
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

pub const TRANSFER_SCHEMA: &str = "acpmux.transfer.v1";
pub const DURABLE_TRANSFER_SCHEMA: &str = "acpmux.transfer.v2";
/// The largest page `transfer_read` answers, and `transfer_write` takes.
pub(super) const MAX_PAGE: u64 = 4 << 20;

/// Bundles being moved, out and in.
pub(super) fn transfers_dir() -> PathBuf {
    crate::config::home().join("transfers")
}

/// The most a move carries (its files' declared sizes), and the most files.
pub(super) const MAX_BUNDLE: u64 = 4 << 30;
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
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
}

fn transfer_error(what: &str, message: impl std::fmt::Display) -> RpcError {
    RpcError::new(-32000, format!("transfer.{what}: {message}"))
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
                let to = params.get("to").and_then(|to| to.get("socket")).and_then(Value::as_str);
                self.transfer_begin(&session, interrupt, to).await
            }
            "read" => {
                let offset = params.get("offset").and_then(Value::as_u64).unwrap_or(0);
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(1 << 20);
                self.transfer_read(text("transferId"), text("path"), offset, limit)
            }
            "commit" => {
                let session = self.resolve(text("sessionId"))?;
                let to = params.get("to").cloned().unwrap_or(Value::Null);
                self.transfer_commit(&session, text("transferId"), to).await
            }
            "abort" => {
                let session = self.resolve(text("sessionId"))?;
                self.transfer_abort(&session, text("transferId"), None)
            }
            "receive" => self.transfer_receive(params).await,
            "write" => self.transfer_write(params),
            "finish" => self.transfer_finish(params).await,
            "forget" => self.transfer_forget(params).await,
            _ => Err(RpcError::method_not_found(m)),
        }
    }

    /// Freezes the chat for its move and makes its bundle.
    async fn transfer_begin(
        self: &Arc<Self>,
        session: &Arc<Session>,
        interrupt: bool,
        to: Option<&str>,
    ) -> Result<Value, RpcError> {
        if session.status() == SessionStatus::Closed {
            return Err(transfer_error("closed", "this chat is closed"));
        }
        let transfer_id = uuid::Uuid::now_v7().to_string();
        self.sweep();
        {
            let mut moving = session.moving.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(other) = moving.as_ref() {
                let e = transfer_error("moving", "this chat is already being moved");
                return Err(e.with_data(json!({"transferId": other})));
            }
            *moving = Some(transfer_id.clone());
        }
        let unfreeze = |e: RpcError| {
            self.end_move(session);
            e
        };
        // No turn may run while the bundle is made: one that runs stops only if asked.
        if let Some(running) = session.turn().map(|t| t.turn_id) {
            if !interrupt {
                return Err(unfreeze(transfer_error("busy", "a turn is running")));
            }
            self.cancel_turn(session, &running).await;
        }
        let wait = std::time::Duration::from_secs(if interrupt { 20 } else { 2 });
        let Ok(guard) = tokio::time::timeout(wait, session.turn_lock.lock()).await else {
            return Err(unfreeze(transfer_error("busy", "the running turn did not stop")));
        };
        // A turn recovered from an agent host runs before its task takes the lock (`hosts.rs`).
        if session.turn().is_some() {
            drop(guard);
            return Err(unfreeze(transfer_error("busy", "a recovered turn is running")));
        }
        self.append(session, "mux", "transfer_out", json!({"transferId": transfer_id}));
        let dir = transfers_dir().join(&transfer_id);
        let made = self.export(session, &dir).and_then(|bundle| Ok(bundle_files(&bundle)?));
        drop(guard);
        let files = match made {
            Ok(files) => files,
            Err(e) => {
                let _ = std::fs::remove_dir_all(&dir);
                self.append(session, "mux", "transfer_aborted", json!({"transferId": transfer_id}));
                return Err(unfreeze(RpcError::internal(format!("transfer: bundle: {e}"))));
            }
        };
        if let Some(socket) = to {
            let _ = std::fs::write(dir.join("to"), socket);
        }
        super::transfer_watch::note_activity(&dir, None);
        self.watch_transfer(session, &transfer_id);
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
        });
        if let Some(manifest) = std::fs::read_to_string(dir.join(&session.id).join("manifest.json"))
            .ok()
            .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        {
            answer["harness"] = manifest.get("harness").cloned().unwrap_or(Value::Null);
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
    ) -> Result<Value, RpcError> {
        let root = self.transfer_bundle(transfer_id)?;
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
        let dir = transfers_dir().join(transfer_id);
        let _pages = super::transfer_watch::PAGES.lock().unwrap_or_else(|e| e.into_inner());
        // The watch may have aborted the move since `transfer_bundle` found it.
        if !dir.is_dir() {
            return Err(transfer_error("unknown", format!("no move {transfer_id} here")));
        }
        let (data, start, len) = page().map_err(|e| transfer_error("read", e))?;
        let next = start + data.len() as u64;
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
            Some(id) if id == transfer_id => Ok(()),
            other => Err(transfer_error("unknown", "the chat is not in this move")
                .with_data(json!({"transferId": other}))),
        }
    }

    /// The chat lives on the target now: its queue is withdrawn here (the target runs it), its
    /// draft and bookmarks cleared, and it closes.
    pub(super) async fn transfer_commit(
        &self,
        session: &Arc<Session>,
        transfer_id: &str,
        to: Value,
    ) -> Result<Value, RpcError> {
        Self::moving_as(session, transfer_id)?;
        // Committed already (by the source's own watch, or a retried commit).
        if session.status() == SessionStatus::Closed {
            return Ok(
                json!({"sessionId": session.id, "transferId": transfer_id, "committed": true}),
            );
        }
        for q in session.queue() {
            self.remove_queued(session, &q.prompt_id);
        }
        {
            // The chat's draft and bookmarks live on the target now.
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            meta.composer_draft = None;
            meta.bookmarks.clear();
        }
        self.append(session, "mux", "transferred", json!({"transferId": transfer_id, "to": to}));
        self.kill(session, false).await?;
        let _ = std::fs::remove_dir_all(transfers_dir().join(transfer_id));
        Ok(json!({"sessionId": session.id, "transferId": transfer_id, "committed": true}))
    }

    /// `_acpmux/set_policy`: a chat being moved keeps the rules it moves with.
    pub async fn set_policy_unless_moving(
        self: &Arc<Self>,
        session: &Arc<Session>,
        policy: crate::config::PermissionPolicy,
    ) -> Result<(), RpcError> {
        if session.moving().is_some() {
            return Err(super::queue::moving_error());
        }
        self.set_policy(session, policy).await;
        Ok(())
    }

    /// The move did not happen: the chat takes prompts and runs its queue again. `reason` says
    /// why when the source ended it itself (`transfer_watch.rs`). A policy that changed while it
    /// moved (a deny-all default skips a moving chat, `policy_mode.rs`) is followed now.
    pub(super) fn transfer_abort(
        self: &Arc<Self>,
        session: &Arc<Session>,
        transfer_id: &str,
        reason: Option<&str>,
    ) -> Result<Value, RpcError> {
        Self::moving_as(session, transfer_id)?;
        if session.status() == SessionStatus::Closed {
            return Err(transfer_error(
                "closed",
                "the move committed; the chat lives on the target",
            ));
        }
        let mut record = json!({"transferId": transfer_id});
        if let Some(reason) = reason {
            record["reason"] = json!(reason);
        }
        self.end_move(session);
        self.append(session, "mux", "transfer_aborted", record);
        let _ = std::fs::remove_dir_all(transfers_dir().join(transfer_id));
        Ok(json!({"sessionId": session.id, "transferId": transfer_id, "aborted": true}))
    }

    /// A move that did not happen (aborted, or its begin failed) gives the chat back: a policy
    /// that changed while it moved (a deny-all default skips a moving chat, `policy_mode.rs`) is
    /// followed, then its queued prompts run again.
    fn end_move(self: &Arc<Self>, session: &Arc<Session>) {
        *session.moving.lock().unwrap_or_else(|e| e.into_inner()) = None;
        let (hub, followed) = (self.clone(), session.clone());
        tokio::spawn(async move {
            hub.follow_policy(&followed).await;
            followed.queue_moved.notify_waiters();
        });
    }
}
