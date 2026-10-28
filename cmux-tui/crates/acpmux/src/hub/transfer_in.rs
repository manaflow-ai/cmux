//! Part of `Hub`; see `hub/mod.rs`. Taking a chat moved from another daemon
//! (`acpmux.transfer.v1`; the source side and the whole flow are in `transfer_out.rs`):
//!
//! - `_acpmux/transfer_receive {manifest}`: the source's `transfer_begin` answer. Refused when a
//!   chat with its id is here already, or its agent is not configured here. Answers `{receiveId}`.
//! - `_acpmux/transfer_write {receiveId, path, offset, data}`: one page (base64), in order.
//! - `_acpmux/transfer_finish {receiveId, cwd?, name?, from?}`: the chat is imported (its history,
//!   draft and agent store), in `cwd` when its folder has another path here, and its queue runs
//!   here at once, held prompts still held. Answers the session summary.
//! - `_acpmux/transfer_forget {transferId, sessionId}`: the source's question about a move whose
//!   client went away (`transfer_watch.rs`): any receive of the move is dropped and a later
//!   one refused (`transfers/forgot-<transferId>`, swept like the rest), so a late
//!   `transfer_finish` or `transfer_receive` fails, and the answer `{landed}` says whether the
//!   chat came here.
//!
//! A receive with a `guard` (`transfer_guard.rs`) keeps it for its write and finish calls, and
//! answers `guarded: true`.

use super::transfer_guard::{Guard, bundle_path_kind};
use super::transfer_out::{
    MAX_BUNDLE, MAX_FILES, MAX_PAGE, TRANSFER_SCHEMA, inside, transfers_dir,
};
use super::*;
use crate::no_panic::JsonExt;
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;

/// Held by a receive, a finish and a forget, so a forget either sees the move landed or drops its
/// receive before the finish reads it, and no receive of it starts after.
static RECEIVES: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn transfer_error(what: &str, message: impl std::fmt::Display) -> RpcError {
    RpcError::new(-32000, format!("transfer.{what}: {message}"))
}

/// Where `transfer_forget` marks a move this daemon must not take.
fn forgotten(transfer_id: &str) -> Option<PathBuf> {
    super::transfer::is_plain_id(transfer_id)
        .then(|| transfers_dir().join(format!("forgot-{transfer_id}")))
}

/// A receive's directory: its manifest, and the bundle as it arrives.
fn receive_dir(receive_id: &str) -> Result<PathBuf, RpcError> {
    let dir = inside(&transfers_dir(), &format!("in-{receive_id}"))?;
    if !cmux_blocking::fs::metadata(&dir).is_ok_and(|m| m.is_dir()) {
        return Err(RpcError::not_found(format!("transfer.unknown: no receive {receive_id:?}")));
    }
    Ok(dir)
}

/// The manifest a receive began with, and each file's declared size.
fn receive_manifest(dir: &Path) -> Result<(Value, Vec<(String, u64)>), RpcError> {
    let text = cmux_blocking::fs::read_to_string(dir.join("manifest.json"))
        .map_err(|e| transfer_error("unknown", e))?;
    let manifest: Value = serde_json::from_str(&text).map_err(|e| transfer_error("unknown", e))?;
    let files = manifest["files"]
        .as_array()
        .map(|files| {
            files
                .iter()
                .filter_map(|f| Some((f["path"].as_str()?.to_owned(), f["size"].as_u64()?)))
                .collect()
        })
        .unwrap_or_default();
    Ok((manifest, files))
}

/// The receive `receive_id` as `transfer_finish` takes it (blocking): its folder, manifest and
/// guard, once every file of the manifest arrived whole.
fn finished_receive(receive_id: &str) -> Result<(PathBuf, Value, Option<Guard>), RpcError> {
    let dir = receive_dir(receive_id)?;
    let (manifest, files) = receive_manifest(&dir)?;
    let guard = Guard::stored(&dir)?;
    let bundle = dir.join("bundle");
    for (path, size) in &files {
        let have = cmux_blocking::fs::metadata(inside(&bundle, path)?).map_or(0, |m| m.len());
        if have != *size {
            return Err(transfer_error("incomplete", format!("{path:?}: {have} of {size}")));
        }
    }
    Ok((dir, manifest, guard))
}

/// One `transfer_write` page (blocking): appended to its bundle file at the size written so far.
fn write_page(receive_id: &str, path: &str, offset: u64, data: &str) -> Result<Value, RpcError> {
    let dir = receive_dir(receive_id)?;
    let (_, files) = receive_manifest(&dir)?;
    let Some(&(_, size)) = files.iter().find(|(p, _)| p == path) else {
        return Err(transfer_error("path", format!("{path:?} is not in the manifest")));
    };
    if Guard::stored(&dir)?.is_some() && bundle_path_kind(path).is_none() {
        return Err(transfer_error("path", format!("{path:?} is not a file a guarded move takes")));
    }
    let data = BASE64.decode(data).map_err(|e| transfer_error("data", e))?;
    let file = inside(&dir.join("bundle"), path)?;
    let have = cmux_blocking::fs::metadata(&file).map_or(0, |m| m.len());
    if offset != have {
        let e = transfer_error("offset", format!("{path:?} has {have} bytes, not {offset}"));
        return Err(e.with_data(json!({"size": have})));
    }
    if data.len() as u64 > MAX_PAGE || have + data.len() as u64 > size {
        return Err(transfer_error("size", format!("{path:?} is {size} bytes")));
    }
    use std::io::Write;
    let wrote = cmux_blocking::fs::create_dir_all(file.parent().unwrap_or(&dir)).and_then(|()| {
        #[allow(clippy::disallowed_methods, reason = "inside scoped_blocking_call")]
        let opened = cmux_blocking::scoped_blocking_call(
            "fs::open_with",
            cmux_blocking::BlockingKind::Fs,
            || std::fs::OpenOptions::new().create(true).append(true).open(&file),
        );
        opened?.write_all(&data)
    });
    wrote.map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
    // Kept from the sweep while pages come (`transfer_out.rs` `sweep_transfers`).
    let _ = cmux_blocking::fs::write(dir.join("alive"), offset.to_string());
    Ok(json!({"next": have + data.len() as u64}))
}

/// Removes every receive of move `transfer_id` (blocking: a folder walk).
fn drop_receives(transfer_id: &str) {
    for entry in cmux_blocking::fs::read_dir(transfers_dir()).into_iter().flatten().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with("in-")
            && receive_manifest(&entry.path())
                .is_ok_and(|(manifest, _)| *manifest.field("transferId") == transfer_id)
        {
            let _ = cmux_blocking::fs::remove_dir_all(entry.path());
        }
    }
}

impl Hub {
    /// A chat that moved from here to another daemon: closed, its move committed (also before a
    /// restart, which does not rebuild a closed chat's state).
    fn moved_away(&self, session: &Session) -> bool {
        if session.status() != SessionStatus::Closed {
            return false;
        }
        let mut moved = session.moving().is_some();
        let _ = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
            moved |= e.kind == "transferred";
            !moved
        });
        moved
    }

    pub(super) async fn transfer_receive(&self, params: &Value) -> Result<Value, RpcError> {
        let manifest = params.get("manifest").cloned().unwrap_or(Value::Null);
        let guard = match params.get("guard") {
            Some(g) => Some(Guard::parse(g).await?),
            None => None,
        };
        if manifest["schema"] != TRANSFER_SCHEMA {
            return Err(transfer_error("schema", format!("this daemon takes {TRANSFER_SCHEMA}")));
        }
        let id = manifest["sessionId"].as_str().unwrap_or("");
        if !super::transfer::is_plain_id(id) {
            return Err(RpcError::invalid_params(format!("transfer: bad session id {id:?}")));
        }
        // A chat that moved away from here may come back (`finish` replaces its closed copy).
        let here = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
        if here.is_some_and(|s| !self.moved_away(&s)) {
            return Err(transfer_error("exists", format!("chat {id} is here already")));
        }
        let harness = manifest["session"]["harness"].as_str().unwrap_or("");
        if !self.config.read().await.harnesses.contains_key(harness) {
            let e = transfer_error("harness", format!("agent {harness:?} is not configured here"));
            return Err(e.with_data(json!({"harness": harness})));
        }
        let files = manifest["files"].as_array().cloned().unwrap_or_default();
        let mut total = 0u64;
        for f in &files {
            inside(Path::new("/"), f["path"].as_str().unwrap_or(""))?;
            total = total.saturating_add(f["size"].as_u64().unwrap_or(u64::MAX));
        }
        if files.len() > MAX_FILES || total > MAX_BUNDLE {
            return Err(transfer_error("size", format!("{} files, {total} bytes", files.len())));
        }
        if let Some(g) = &guard {
            self.guarded_receive_check(g, &manifest).await?;
        }
        let _receives = RECEIVES.lock().await;
        let transfer_id = manifest["transferId"].as_str().unwrap_or("");
        let Some(mark) = forgotten(transfer_id) else {
            return Err(RpcError::invalid_params(format!("transfer: bad move id {transfer_id:?}")));
        };
        if tokio::fs::try_exists(&mark).await.unwrap_or(false) {
            return Err(transfer_error("forgotten", format!("move {transfer_id} was given up")));
        }
        self.sweep().await;
        let receive_id = uuid::Uuid::now_v7().to_string();
        let dir = transfers_dir().join(format!("in-{receive_id}"));
        let made = async {
            tokio::fs::create_dir_all(dir.join("bundle")).await?;
            // The guard first: a receive with a manifest and no guard file is an unguarded one.
            if let Some(g) = &guard {
                g.store(&dir).await?;
            }
            tokio::fs::write(dir.join("manifest.json"), serde_json::to_vec(&manifest)?).await
        };
        made.await.map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
        let mut answer = json!({"receiveId": receive_id, "sessionId": id});
        if guard.is_some() {
            answer["guarded"] = json!(true);
        }
        Ok(answer)
    }

    /// Appends one page to a bundle file; pages come in order, each at the size written so far.
    pub(super) async fn transfer_write(&self, params: &Value) -> Result<Value, RpcError> {
        let text = |k: &str| params.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
        let (receive_id, path, data) = (text("receiveId"), text("path"), text("data"));
        let offset = params.get("offset").and_then(Value::as_u64).unwrap_or(0);
        cmux_blocking::spawn_blocking(move || write_page(&receive_id, &path, offset, &data))
            .await
            .map_err(|e| RpcError::internal(format!("transfer: {e}")))?
    }

    /// Imports the received chat and runs its queue here.
    pub(super) async fn transfer_finish(
        self: &Arc<Self>,
        params: &Value,
    ) -> Result<Value, RpcError> {
        let text = |k: &str| params.get(k).and_then(Value::as_str).filter(|s| !s.is_empty());
        let _receives = RECEIVES.lock().await;
        let receive_id = text("receiveId").unwrap_or("").to_owned();
        let (dir, manifest, guard) =
            cmux_blocking::spawn_blocking(move || finished_receive(&receive_id))
                .await
                .map_err(|e| RpcError::internal(format!("transfer: {e}")))??;
        let bundle = dir.join("bundle");
        let from = params.get("from").cloned().unwrap_or(Value::Null);
        // Back where it once moved from: its closed copy gives way (below).
        let id = manifest["sessionId"].as_str().unwrap_or("");
        let old = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
        let old = old.filter(|s| self.moved_away(s));
        let mut replace_native = false;
        if let Some(g) = &guard {
            let replaceable = old.as_ref().and_then(|o| o.meta().agent_session_id);
            let (meta, replace) =
                self.guard_session(&bundle, g, text("cwd"), &from, replaceable.as_deref()).await?;
            replace_native = replace;
            // The chat it imports is the one the receive was refused or allowed for.
            if Some(meta.id.as_str()) != manifest["sessionId"].as_str() {
                return Err(transfer_error("schema", "session.json names another chat"));
            }
        }
        // Its folder may have another path here (a remote machine's checkout).
        if guard.is_none()
            && let Some(cwd) = text("cwd")
        {
            let path = bundle.join("session.json");
            let edited = async {
                let mut meta: Value = serde_json::from_slice(&tokio::fs::read(&path).await?)?;
                meta["cwd"] = json!(cwd);
                tokio::fs::write(&path, serde_json::to_vec_pretty(&meta)?).await?;
                anyhow::Ok(())
            };
            edited.await.map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
        }
        if let Some(old) = old {
            // A guarded move never replaces a copy from a folder outside its roots.
            if let Some(g) = &guard
                && g.folder(&old.meta().cwd.to_string_lossy()).await.is_none()
            {
                return Err(transfer_error(
                    "exists",
                    format!("chat {id} is here already, in a folder outside the move's roots"),
                ));
            }
            // Only once the chat can live here: a failed import keeps the closed copy's log.
            let cwd = match text("cwd") {
                Some(cwd) => Some(PathBuf::from(cwd)),
                None => tokio::fs::read(bundle.join("session.json"))
                    .await
                    .ok()
                    .and_then(|raw| serde_json::from_slice::<Value>(&raw).ok())
                    .and_then(|meta| meta.field("cwd").as_str().map(PathBuf::from)),
            };
            let is_dir = match &cwd {
                Some(c) => tokio::fs::metadata(c).await.is_ok_and(|m| m.is_dir()),
                None => false,
            };
            if !is_dir {
                let e = transfer_error("cwd", "the chat's folder is not here; pass cwd");
                return Err(e.with_data(json!({"reason": "cwd_missing", "cwd": cwd})));
            }
            old.replaced.store(true, Ordering::SeqCst);
            self.kill(&old, true).await?;
        }
        let name = text("name").map(str::to_owned);
        let guarded = guard
            .as_ref()
            .map(|guard| super::transfer_guard::GuardedImport { guard, replace_native });
        let session = self.import_into(&bundle, name, true, guarded).await?;
        if let Some(g) = &guard {
            self.append(&session, "mux", "transfer_guarded", g.to_value());
        }
        let transfer_id = manifest["transferId"].clone();
        self.append(
            &session,
            "mux",
            "transferred_in",
            json!({"transferId": transfer_id, "from": from}),
        );
        // Its queue (back since the import) runs here now; the source withdraws it on commit.
        self.resume_queues();
        let _ = tokio::fs::remove_dir_all(&dir).await;
        Ok(self.session_summary(&session))
    }

    /// Drops every receive of move `transferId` and says whether its chat landed here.
    pub(super) async fn transfer_forget(&self, params: &Value) -> Result<Value, RpcError> {
        let text = |k: &str| params.get(k).and_then(Value::as_str).unwrap_or("");
        let (transfer_id, session_id) = (text("transferId"), text("sessionId"));
        if transfer_id.is_empty() {
            return Err(RpcError::invalid_params("transfer_forget: transferId is required"));
        }
        let Some(mark) = forgotten(transfer_id) else {
            return Err(RpcError::invalid_params("transfer_forget: bad transferId"));
        };
        let _receives = RECEIVES.lock().await;
        let made = tokio::fs::create_dir_all(&mark).await;
        made.map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
        let forget = transfer_id.to_owned();
        let dropped = cmux_blocking::spawn_blocking(move || drop_receives(&forget)).await;
        dropped.map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
        let here = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(session_id).cloned();
        let mut landed = false;
        if let Some(session) = here {
            let _ = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
                landed |= e.kind == "transferred_in" && e.msg["transferId"] == transfer_id;
                !landed
            });
        }
        Ok(json!({"transferId": transfer_id, "landed": landed}))
    }
}
