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
    DURABLE_TRANSFER_SCHEMA, MAX_BUNDLE, MAX_FILES, MAX_PAGE, TRANSFER_SCHEMA, inside,
    transfers_dir,
};
use super::*;
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use cmux_json::JsonSet as _;

/// Held by a receive, a finish and a forget, so a forget either sees the move landed or drops its
/// receive before the finish reads it, and no receive of it starts after.
static RECEIVES: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn recovery_owner(root: &Path, agent_id: &str, outer_id: &str) -> bool {
    if !super::transfer::is_plain_id(agent_id) || !super::transfer::is_plain_id(outer_id) {
        return false;
    }
    for candidate in [root.join(outer_id), root.join(format!(".{outer_id}.replacement-backup"))] {
        let path = candidate.join("session.json");
        let Ok(raw) = std::fs::read(path) else { continue };
        let Ok(meta) = serde_json::from_slice::<SessionMeta>(&raw) else { continue };
        return meta.id == outer_id
            && meta.harness == "cmux-harness"
            && meta.agent_session_id.as_deref() == Some(agent_id);
    }
    false
}

/// A test's hook right after a sweep read a durable marker, to run another writer there.
#[cfg(test)]
pub(super) static SWEEP_PAUSE: std::sync::Mutex<Option<Arc<dyn Fn(&str) + Send + Sync>>> =
    std::sync::Mutex::new(None);

fn sweep_pause(_agent_id: &str) {
    #[cfg(test)]
    {
        let hook = SWEEP_PAUSE.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(hook) = hook {
            hook(_agent_id);
        }
    }
}

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
    pub(super) fn moved_away(&self, session: &Session) -> bool {
        if session.status() != SessionStatus::Closed {
            return false;
        }
        if session.meta().moved_to.is_some() {
            return true;
        }
        // A move only begun is not: a stopped chat is closed for its whole move.
        if session.moving().is_some() {
            return false;
        }
        // A move committed before `moved_to` was recorded: its log says so.
        let mut moved = false;
        let _ = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
            // The daemon's own records only: an agent's update may carry any kind.
            moved |= e.dir == "mux" && e.kind == "transferred";
            !moved
        });
        moved
    }

    /// Recover an outer session store staged for a replacement before a daemon crash.
    pub(super) fn recover_staged_replacements(&self) {
        let Some(probe) = self.store.session_dir("__cmux_harness_recovery_probe__") else {
            return;
        };
        let Some(root) = probe.parent() else { return };
        let Ok(entries) = std::fs::read_dir(root) else { return };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.ends_with(".durable-transfer-state.importing")
                || name.ends_with(".replacement-state.json.importing")
            {
                let _ = std::fs::remove_file(entry.path());
            }
        }
        let Ok(entries) = std::fs::read_dir(root) else { return };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(id) =
                name.strip_prefix(".").and_then(|n| n.strip_suffix(".replacement-backup"))
            else {
                continue;
            };
            if !super::transfer::is_plain_id(id) {
                continue;
            }
            let target = root.join(id);
            let state = entry.path().with_extension("replacement-state.json");
            let Ok(raw) = std::fs::read(&state) else { continue };
            let Ok(value) = serde_json::from_slice::<Value>(&raw) else { continue };
            let owner_agent = value.get("agentId").and_then(Value::as_str).unwrap_or("");
            if value.get("id").and_then(Value::as_str) != Some(id)
                || !recovery_owner(root, owner_agent, id)
            {
                continue;
            }
            let phase = value.get("phase").and_then(Value::as_str).unwrap_or("");
            if phase != "staged" && phase != "committed" {
                continue;
            }
            let landed = if let Some(transfer_id) = value.get("transferId").and_then(Value::as_str)
            {
                let mut landed = false;
                let _ = self.store.scan(id, 0, &mut |event: EventRecord| {
                    landed |= event.kind == "transferred_in"
                        && event.msg.get("transferId").and_then(Value::as_str) == Some(transfer_id);
                    !landed
                });
                landed
            } else {
                false
            };
            let committed = phase == "committed" || landed;
            if committed {
                let _ = std::fs::remove_dir_all(entry.path());
            } else {
                if std::fs::symlink_metadata(&target).is_ok() {
                    let _ = std::fs::remove_dir_all(&target);
                }
                let _ = std::fs::rename(entry.path(), target);
            }
        }
        let Ok(entries) = std::fs::read_dir(root) else { return };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(agent_id) =
                name.strip_prefix(".").and_then(|n| n.strip_suffix(".durable-transfer-state"))
            else {
                continue;
            };
            if !super::transfer::is_plain_id(agent_id) {
                continue;
            }
            let _state_lock = super::transfer::harness_state_lock();
            self.recover_durable_marker(root, &entry.path(), agent_id);
        }
        if let Ok(entries) = std::fs::read_dir(root) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if !name.starts_with(".") || !name.ends_with(".replacement-state.json") {
                    continue;
                }
                if let Ok(raw) = std::fs::read(entry.path())
                    && let Ok(value) = serde_json::from_slice::<Value>(&raw)
                {
                    let agent = value.get("agentId").and_then(Value::as_str).unwrap_or("");
                    let outer = value.get("outerId").and_then(Value::as_str).unwrap_or("");
                    let phase = value.get("phase").and_then(Value::as_str).unwrap_or("");
                    if matches!(phase, "prepared" | "staged" | "committed")
                        && recovery_owner(root, agent, outer)
                    {
                        let _ = std::fs::remove_file(entry.path());
                    }
                }
            }
        }
    }

    /// Recover one durable session's transfer marker (`.{agent_id}.durable-transfer-state` at
    /// `path`): the chat it stood for comes back as it was before the transfer, or keeps what a
    /// committed one installed, and the marker goes.
    pub(super) fn recover_durable_marker(&self, root: &Path, path: &Path, agent_id: &str) {
        let Ok(marker) = std::fs::read(path) else { return };
        let Ok(value) = serde_json::from_slice::<Value>(&marker) else { return };
        sweep_pause(agent_id);
        let phase = value.get("phase").and_then(Value::as_str).unwrap_or("");
        if phase == "prepared" {
            let outer_id = value.get("outerId").and_then(Value::as_str).unwrap_or("");
            let replace_durable =
                value.get("replaceDurable").and_then(Value::as_bool).unwrap_or(false);
            let target = root.join(outer_id);
            let backup = root.join(format!(".{outer_id}.replacement-backup"));
            if target.join("session.json").exists() || backup.join("session.json").exists() {
                if value.get("agentId").and_then(Value::as_str) != Some(agent_id)
                    || !recovery_owner(root, agent_id, outer_id)
                {
                    return;
                }
                if !replace_durable {
                    let _ = std::fs::remove_dir_all(target);
                }
            }
            let _ = std::fs::remove_file(path);
            return;
        }
        if phase != "staged" && phase != "committed" {
            return;
        }
        let filename = value.get("piFilename").and_then(Value::as_str).unwrap_or("");
        let outer_id = value.get("outerId").and_then(Value::as_str).unwrap_or("");
        let replace_durable = value.get("replaceDurable").and_then(Value::as_bool).unwrap_or(false);
        if value.get("agentId").and_then(Value::as_str) != Some(agent_id)
            || !recovery_owner(root, agent_id, outer_id)
        {
            return;
        }
        if !filename.is_empty()
            && (Path::new(filename).components().count() != 1 || !filename.ends_with(".jsonl"))
        {
            return;
        }
        let Some(had_journal) = value.get("hadJournal").and_then(Value::as_bool) else {
            return;
        };
        let Some(had_pi) = value.get("hadPi").and_then(Value::as_bool) else { return };
        let Some(dir_was_present) = value.get("journalDirWasPresent").and_then(Value::as_bool)
        else {
            return;
        };
        let landed = if let (Some(transfer_id), true) = (
            value.get("transferId").and_then(Value::as_str),
            super::transfer::is_plain_id(outer_id),
        ) {
            let mut landed = false;
            let _ = self.store.scan(outer_id, 0, &mut |event: EventRecord| {
                landed |= event.kind == "transferred_in"
                    && event.msg.get("transferId").and_then(Value::as_str) == Some(transfer_id);
                !landed
            });
            landed
        } else {
            false
        };
        let outer_committed = phase == "committed"
            || landed
            || std::fs::read(root.join(format!(".{outer_id}.replacement-state.json")))
                .ok()
                .and_then(|raw| serde_json::from_slice::<Value>(&raw).ok())
                .and_then(|v| {
                    v.get("phase").and_then(Value::as_str).map(|phase| phase == "committed")
                })
                .unwrap_or(false);
        let journal = root.join(agent_id).join("journal.ndjson");
        let journal_backup = root.join(agent_id).join("journal.ndjson.transfer-backup");
        let pi = root.join(filename);
        let pi_backup = root.join(format!("{filename}.transfer-backup"));
        if outer_committed {
            let _ = std::fs::remove_file(&journal_backup);
            let _ = std::fs::remove_file(&pi_backup);
        } else {
            if std::fs::symlink_metadata(&journal_backup).is_ok() {
                let _ = std::fs::remove_file(&journal);
                let _ = std::fs::rename(&journal_backup, &journal);
            } else if !had_journal {
                let _ = std::fs::remove_file(&journal);
            }
            if std::fs::symlink_metadata(&pi_backup).is_ok() {
                let _ = std::fs::remove_file(&pi);
                let _ = std::fs::rename(&pi_backup, &pi);
            } else if !had_pi {
                let _ = std::fs::remove_file(&pi);
            }
        }
        let _ = std::fs::remove_file(root.join(agent_id).join("journal.ndjson.importing"));
        let _ = std::fs::remove_file(root.join(format!("{filename}.importing")));
        if !dir_was_present {
            let _ = std::fs::remove_dir(root.join(agent_id));
        }
        if !replace_durable && !outer_committed && super::transfer::is_plain_id(outer_id) {
            let _ = std::fs::remove_dir_all(root.join(outer_id));
        }
        let _ = std::fs::remove_file(path);
    }

    /// Fence the outgoing instance before staging the incoming durable store. Keep
    /// this boundary shared by transfer_finish and its admission-race regression.
    pub(super) async fn retire_transfer_instance(
        &self,
        old: &Arc<Session>,
    ) -> Result<(), RpcError> {
        // Retry tasks hold the same lock across their replaced check and append.
        self.seal_retry_replacement(old);
        // Drain an earlier retention commit before replacing the journal.
        drop(old.append_lock.lock().unwrap_or_else(|e| e.into_inner()));
        self.kill(old, false).await
    }

    pub(super) async fn transfer_receive(&self, params: &Value) -> Result<Value, RpcError> {
        let manifest = params.get("manifest").cloned().unwrap_or(Value::Null);
        let guard = match params.get("guard") {
            Some(g) => Some(Guard::parse(g).await?),
            None => None,
        };
        let schema = manifest["schema"].as_str().unwrap_or("");
        if schema != TRANSFER_SCHEMA && schema != DURABLE_TRANSFER_SCHEMA {
            return Err(transfer_error(
                "schema",
                format!("this daemon takes {TRANSFER_SCHEMA} or {DURABLE_TRANSFER_SCHEMA}"),
            ));
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
        if harness == "cmux-harness" && schema != DURABLE_TRANSFER_SCHEMA {
            return Err(transfer_error(
                "schema",
                "cmux-harness durable transfers require acpmux.transfer.v2",
            ));
        }
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
        if mark.exists() {
            return Err(transfer_error("forgotten", format!("move {transfer_id} was given up")));
        }
        self.sweep();
        let receive_id = uuid::Uuid::now_v7().to_string();
        let dir = transfers_dir().join(format!("in-{receive_id}"));
        let made = std::fs::create_dir_all(dir.join("bundle")).and_then(|()| {
            // The guard first: a receive with a manifest and no guard file is an unguarded one.
            if let Some(g) = &guard {
                g.store(&dir)?;
            }
            std::fs::write(dir.join("manifest.json"), serde_json::to_vec(&manifest)?)
        });
        made.map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
        let mut answer = json!({"receiveId": receive_id, "sessionId": id});
        if guard.is_some() {
            answer.set("guarded", json!(true));
        }
        Ok(answer)
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
        if Guard::stored(&dir)?.is_some() && bundle_path_kind(path).is_none() {
            return Err(transfer_error(
                "path",
                format!("{path:?} is not a file a guarded move takes"),
            ));
        }
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
        let _receives = RECEIVES.lock().await;
        let dir = receive_dir(text("receiveId").unwrap_or(""))?;
        let (manifest, files) = receive_manifest(&dir)?;
        let guard = Guard::stored(&dir)?;
        let bundle = dir.join("bundle");
        for (path, size) in &files {
            let have = std::fs::metadata(inside(&bundle, path)?).map_or(0, |m| m.len());
            if have != *size {
                return Err(transfer_error("incomplete", format!("{path:?}: {have} of {size}")));
            }
        }
        let from = params.get("from").cloned().unwrap_or(Value::Null);
        // Back where it once moved from: its closed copy gives way (below). Bind the
        // bundle's outer identity, harness, and ACP identity before any source is killed.
        let id = manifest["sessionId"].as_str().unwrap_or("");
        let bundle_meta: SessionMeta = serde_json::from_slice(
            &std::fs::read(bundle.join("session.json"))
                .map_err(|e| transfer_error("schema", format!("read session metadata: {e}")))?,
        )
        .map_err(|e| transfer_error("schema", format!("invalid session metadata: {e}")))?;
        if bundle_meta.id != id
            || manifest["session"]["harness"].as_str() != Some(bundle_meta.harness.as_str())
            || (bundle_meta.harness == "cmux-harness"
                && manifest["session"]["agentSessionId"].as_str()
                    != bundle_meta.agent_session_id.as_deref())
        {
            return Err(transfer_error(
                "schema",
                "bundle identity does not match transfer manifest",
            ));
        }
        let old = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
        let old = old.filter(|s| self.moved_away(s));
        let replacing_durable = old.as_ref().is_some_and(|existing| {
            let existing_meta = existing.meta();
            existing_meta.harness == bundle_meta.harness
                && existing_meta.agent_session_id == bundle_meta.agent_session_id
        });
        if old.is_some() && !replacing_durable {
            return Err(transfer_error(
                "exists",
                "closed session identity does not match transfer bundle",
            ));
        }
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
            let edited = std::fs::read(&path).map_err(anyhow::Error::from).and_then(|raw| {
                let mut meta: Value = serde_json::from_slice(&raw)?;
                meta.set("cwd", json!(cwd));
                Ok(std::fs::write(&path, serde_json::to_vec_pretty(&meta)?)?)
            });
            edited.map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
        }
        if let Some(old) = old.as_ref() {
            if let Some(g) = &guard
                && g.folder(&old.meta().cwd.to_string_lossy()).await.is_none()
            {
                return Err(transfer_error(
                    "exists",
                    format!("chat {id} is here already, in a folder outside the move's roots"),
                ));
            }
            let cwd = text("cwd").map(PathBuf::from).or_else(|| {
                let raw = std::fs::read(bundle.join("session.json")).ok()?;
                let meta: Value = serde_json::from_slice(&raw).ok()?;
                meta["cwd"].as_str().map(PathBuf::from)
            });
            if !cwd.as_ref().is_some_and(|c| c.is_dir()) {
                let e = transfer_error("cwd", "the chat's folder is not here; pass cwd");
                return Err(e.with_data(json!({"reason": "cwd_missing", "cwd": cwd})));
            }
            self.retire_transfer_instance(old).await?;
        }
        let source_store = if replacing_durable { self.store.session_dir(id) } else { None };
        let source_store_backup = if let Some(source_store) = source_store.as_ref() {
            let backup = source_store
                .parent()
                .map(|parent| parent.join(format!(".{id}.replacement-backup")))
                .ok_or_else(|| transfer_error("store", "source store has no parent"))?;
            if std::fs::symlink_metadata(source_store).is_ok() {
                if std::fs::symlink_metadata(&backup).is_ok() {
                    return Err(transfer_error("store", "source-store backup path is occupied"));
                }
                let state = backup.with_extension("replacement-state.json");
                super::transfer::write_json_atomic(&state, &json!({"id": id, "agentId": bundle_meta.agent_session_id, "transferId": manifest["transferId"], "phase": "staged"}))
                    .map_err(|e| transfer_error("store", format!("write replacement state: {e}")))?;
                std::fs::rename(source_store, &backup)
                    .map_err(|e| transfer_error("store", format!("stage source store: {e}")))?;
                Some((source_store.clone(), backup))
            } else {
                None
            }
        } else {
            None
        };
        let transfer_id = manifest["transferId"].clone();
        let name = text("name").map(str::to_owned);
        let guarded = guard
            .as_ref()
            .map(|guard| super::transfer_guard::GuardedImport { guard, replace_native });
        let session = match self
            .import_into(&bundle, name, true, guarded, replacing_durable, true)
            .await
        {
            Ok(session) => {
                let (_, appended) = self.append_at(
                    &session,
                    "mux",
                    "transferred_in",
                    json!({"transferId": transfer_id, "from": from}),
                    None,
                    None,
                );
                let stored = appended
                    && self.store.flush_session(&session.id).map(|()| true).unwrap_or_else(|error| {
                        tracing::warn!(session = %session.id, "sync transferred_in receipt: {error:#}");
                        false
                    });
                if !stored {
                    if source_store_backup.is_none() {
                        self.recover_staged_replacements();
                        let _ = self.kill(&session, true).await;
                    } else {
                        let _ = self.kill(&session, true).await;
                        if let Some((source_store, backup)) = source_store_backup.as_ref() {
                            let _ = std::fs::remove_dir_all(source_store);
                            let _ = std::fs::rename(backup, source_store);
                            let _ = std::fs::remove_file(
                                backup.with_extension("replacement-state.json"),
                            );
                        }
                        self.recover_staged_replacements();
                    }
                    return Err(transfer_error("store", "could not durably record transferred_in"));
                }
                if let Some((_, backup)) = source_store_backup.as_ref() {
                    let state = backup.with_extension("replacement-state.json");
                    let commit = serde_json::to_value(json!({"id": id, "agentId": bundle_meta.agent_session_id, "transferId": manifest["transferId"], "phase": "committed"}))
                        .map_err(|e| transfer_error("store", format!("encode commit state: {e}")))
                        .and_then(|value| {
                            super::transfer::write_json_atomic(&state, &value)
                                .map_err(|e| transfer_error("store", format!("commit state: {e}")))
                        });
                    if let Err(error) = commit {
                        let _ = self.kill(&session, true).await;
                        self.recover_staged_replacements();
                        return Err(error);
                    }
                }
                if let Err(error) = self.finalize_harness_state(&session.meta()) {
                    if let Err(mark_error) = self.mark_harness_state_committed(&session.meta()) {
                        tracing::warn!(session = %session.id, "durable commit marker deferred: {mark_error:#}");
                    }
                    tracing::warn!(session = %session.id, "durable transfer finalization deferred: {error:#}");
                }
                if let Some((_, backup)) = source_store_backup.as_ref() {
                    let _ = std::fs::remove_dir_all(backup);
                    let _ = std::fs::remove_file(backup.with_extension("replacement-state.json"));
                }
                session
            }
            Err(error) => {
                if let Some((source_store, backup)) = source_store_backup.as_ref() {
                    let _ = std::fs::remove_dir_all(source_store);
                    let _ = std::fs::rename(backup, source_store);
                    let _ = std::fs::remove_file(backup.with_extension("replacement-state.json"));
                }
                return Err(error);
            }
        };
        if let Some(g) = &guard {
            self.append(&session, "mux", "transfer_guarded", g.to_value());
        }
        // Its queue (back since the import) runs here now; the source withdraws it on commit.
        self.resume_queues();
        let _ = std::fs::remove_dir_all(&dir);
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
        let made = std::fs::create_dir_all(&mark);
        made.map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
        for entry in std::fs::read_dir(transfers_dir()).into_iter().flatten().flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with("in-")
                && receive_manifest(&entry.path())
                    .is_ok_and(|(manifest, _)| manifest["transferId"] == transfer_id)
            {
                let _ = std::fs::remove_dir_all(entry.path());
            }
        }
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
