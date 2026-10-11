//! Part of `Hub`; see `hub/mod.rs`. Taking a chat moved from another daemon
//! (`acpmux.transfer.v1`; the source side and the whole flow are in `transfer_out.rs`):
//!
//! - `_acpmux/transfer_receive {manifest}`: the source's `transfer_begin` answer. Refused when a
//!   chat with its id is here already, or its agent is not configured here. Answers `{receiveId}`.
//! - `_acpmux/transfer_write {receiveId, path, offset, data}`: one page (base64), in order.
//! - `_acpmux/transfer_finish {receiveId, cwd?, name?, from?}`: the chat is imported (its history,
//!   draft and agent store), in `cwd` when its folder has another path here, and its queue runs
//!   here at once, held prompts still held. Answers the session summary.

use super::transfer_out::{
    MAX_BUNDLE, MAX_FILES, MAX_PAGE, TRANSFER_SCHEMA, inside, transfers_dir,
};
use super::*;
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;

fn transfer_error(what: &str, message: impl std::fmt::Display) -> RpcError {
    RpcError::new(-32000, format!("transfer.{what}: {message}"))
}

/// A receive's directory: its manifest, and the bundle as it arrives.
fn receive_dir(receive_id: &str) -> Result<PathBuf, RpcError> {
    let dir = inside(&transfers_dir(), &format!("in-{receive_id}"))?;
    if !dir.is_dir() {
        return Err(RpcError::not_found(format!("transfer.unknown: no receive {receive_id:?}")));
    }
    Ok(dir)
}

/// The manifest a receive began with, and each file's declared size.
fn receive_manifest(dir: &Path) -> Result<(Value, Vec<(String, u64)>), RpcError> {
    let text = std::fs::read_to_string(dir.join("manifest.json"))
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
        if manifest["schema"] != TRANSFER_SCHEMA {
            return Err(transfer_error("schema", format!("this daemon takes {TRANSFER_SCHEMA}")));
        }
        let id = manifest["sessionId"].as_str().unwrap_or("");
        if !super::transfer::is_plain_id(id) {
            return Err(RpcError::invalid_params(format!("transfer: bad session id {id:?}")));
        }
        // A chat that moved away from here may come back (`finish` replaces its closed copy).
        let here = self.sessions.lock().unwrap().get(id).cloned();
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
        self.sweep();
        let receive_id = uuid::Uuid::now_v7().to_string();
        let dir = transfers_dir().join(format!("in-{receive_id}"));
        let made = std::fs::create_dir_all(dir.join("bundle")).and_then(|()| {
            std::fs::write(dir.join("manifest.json"), serde_json::to_vec(&manifest)?)
        });
        made.map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
        Ok(json!({"receiveId": receive_id, "sessionId": id}))
    }

    /// Appends one page to a bundle file; pages come in order, each at the size written so far.
    pub(super) fn transfer_write(&self, params: &Value) -> Result<Value, RpcError> {
        let text = |k: &str| params.get(k).and_then(Value::as_str).unwrap_or("");
        let dir = receive_dir(text("receiveId"))?;
        let (_, files) = receive_manifest(&dir)?;
        let path = text("path");
        let Some(&(_, size)) = files.iter().find(|(p, _)| p == path) else {
            return Err(transfer_error("path", format!("{path:?} is not in the manifest")));
        };
        let data = BASE64.decode(text("data")).map_err(|e| transfer_error("data", e))?;
        let file = inside(&dir.join("bundle"), path)?;
        let have = std::fs::metadata(&file).map_or(0, |m| m.len());
        let offset = params.get("offset").and_then(Value::as_u64).unwrap_or(0);
        if offset != have {
            let e = transfer_error("offset", format!("{path:?} has {have} bytes, not {offset}"));
            return Err(e.with_data(json!({"size": have})));
        }
        if data.len() as u64 > MAX_PAGE || have + data.len() as u64 > size {
            return Err(transfer_error("size", format!("{path:?} is {size} bytes")));
        }
        use std::io::Write;
        let wrote = std::fs::create_dir_all(file.parent().unwrap_or(&dir)).and_then(|()| {
            std::fs::OpenOptions::new().create(true).append(true).open(&file)?.write_all(&data)
        });
        wrote.map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
        // Kept from the sweep while pages come (`transfer_out.rs` `sweep_transfers`).
        let _ = std::fs::write(dir.join("alive"), offset.to_string());
        Ok(json!({"next": have + data.len() as u64}))
    }

    /// Imports the received chat and runs its queue here.
    pub(super) async fn transfer_finish(
        self: &Arc<Self>,
        params: &Value,
    ) -> Result<Value, RpcError> {
        let text = |k: &str| params.get(k).and_then(Value::as_str).filter(|s| !s.is_empty());
        let dir = receive_dir(text("receiveId").unwrap_or(""))?;
        let (manifest, files) = receive_manifest(&dir)?;
        let bundle = dir.join("bundle");
        for (path, size) in &files {
            let have = std::fs::metadata(inside(&bundle, path)?).map_or(0, |m| m.len());
            if have != *size {
                return Err(transfer_error("incomplete", format!("{path:?}: {have} of {size}")));
            }
        }
        // Its folder may have another path here (a remote machine's checkout).
        if let Some(cwd) = text("cwd") {
            let path = bundle.join("session.json");
            let edited = std::fs::read(&path).map_err(anyhow::Error::from).and_then(|raw| {
                let mut meta: Value = serde_json::from_slice(&raw)?;
                meta["cwd"] = json!(cwd);
                Ok(std::fs::write(&path, serde_json::to_vec_pretty(&meta)?)?)
            });
            edited.map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
        }
        // Back where it once moved from: its closed copy gives way.
        let id = manifest["sessionId"].as_str().unwrap_or("");
        let old = self.sessions.lock().unwrap().get(id).cloned();
        if let Some(old) = old.filter(|s| self.moved_away(s)) {
            // Only once the chat can live here: a failed import keeps the closed copy's log.
            let cwd = text("cwd").map(PathBuf::from).or_else(|| {
                let raw = std::fs::read(bundle.join("session.json")).ok()?;
                let meta: Value = serde_json::from_slice(&raw).ok()?;
                meta["cwd"].as_str().map(PathBuf::from)
            });
            if !cwd.is_some_and(|c| c.is_dir()) {
                return Err(transfer_error("cwd", "the chat's folder is not here; pass cwd"));
            }
            self.kill(&old, true).await?;
        }
        let session = self.import_into(&bundle, text("name").map(str::to_owned), true).await?;
        let from = params.get("from").cloned().unwrap_or(Value::Null);
        let transfer_id = manifest["transferId"].clone();
        self.append(
            &session,
            "mux",
            "transferred_in",
            json!({"transferId": transfer_id, "from": from}),
        );
        // Its queue (back since the import) runs here now; the source withdraws it on commit.
        self.resume_queues();
        let _ = std::fs::remove_dir_all(&dir);
        Ok(self.session_summary(&session))
    }
}
