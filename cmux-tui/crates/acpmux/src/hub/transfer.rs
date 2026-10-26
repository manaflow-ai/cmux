//! Part of `Hub`; see `hub/mod.rs`.

use super::transfer_guard::plain_agent_session;
use super::*;
use std::sync::Mutex;

/// True when `id` is a single plain path component, so it can name a
/// directory under the sessions root (no separator, `.`, `..` or root).
static HARNESS_STATE_LOCK: Mutex<()> = Mutex::new(());

pub(super) fn write_json_atomic(path: &Path, value: &Value) -> Result<()> {
    let tmp = path.with_extension(format!(
        "{}.importing",
        path.extension().and_then(|e| e.to_str()).unwrap_or("json")
    ));
    if std::fs::symlink_metadata(&tmp).is_ok() {
        return Err(anyhow::anyhow!("transaction marker temporary path is occupied"));
    }
    let bytes = serde_json::to_vec(value)?;
    {
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).open(&tmp)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
    }
    std::fs::rename(&tmp, path)?;
    if let Some(parent) = path.parent() {
        std::fs::File::open(parent)?.sync_all()?;
    }
    Ok(())
}

pub(super) fn is_plain_id(id: &str) -> bool {
    let mut parts = Path::new(id).components();
    matches!(
        (parts.next(), parts.next()),
        (Some(std::path::Component::Normal(c)), None) if c.to_str() == Some(id)
    )
}

/// Releases an import's claim on its session id however the import ends.
struct ImportReservation<'a> {
    hub: &'a Hub,
    id: String,
}

impl Drop for ImportReservation<'_> {
    fn drop(&mut self) {
        self.hub.importing.lock().unwrap().remove(&self.id);
    }
}

impl Hub {
    // ------------------------------------------------------------- export

    pub fn export(&self, session: &Arc<Session>, dest: &Path) -> Result<PathBuf> {
        let meta = session.meta();
        let dir = dest.join(&meta.id);
        std::fs::create_dir_all(dir.join("events"))?;
        std::fs::write(dir.join("session.json"), serde_json::to_string_pretty(&meta)?)?;
        use std::io::Write;
        // Stream the log into the bundle; a long session never sits in memory whole.
        let file = std::fs::File::create(dir.join("events").join("000001.ndjson"))?;
        let mut out = std::io::BufWriter::new(file);
        let mut event_count = 0usize;
        let mut failed: Option<anyhow::Error> = None;
        self.store.scan(&meta.id, 0, &mut |e: EventRecord| {
            let written = serde_json::to_string(&e).map_err(anyhow::Error::from).and_then(|line| {
                out.write_all(line.as_bytes())?;
                out.write_all(b"\n")?;
                Ok(())
            });
            match written {
                Ok(()) => {
                    event_count += 1;
                    true
                }
                Err(err) => {
                    failed = Some(err);
                    false
                }
            }
        })?;
        if let Some(e) = failed {
            return Err(e);
        }
        out.flush()?;
        let native = crate::native::locate(&meta);
        let harness = self.export_harness_state(&meta, &dir)?;
        let mut manifest = json!({
            "schema": "acpmux.bundle.v1",
            "id": meta.id,
            "eventCount": event_count,
            "lastSeq": meta.last_seq,
            "native": [],
            "harness": harness,
        });
        if !native.is_empty() {
            std::fs::create_dir_all(dir.join("native"))?;
            let mut copied = Vec::new();
            for (label, src) in native {
                if let Ok(rel) = crate::native::copy_into(&src, &dir.join("native"), &label) {
                    copied.push(json!({"label": label, "path": rel, "source": src}));
                }
            }
            manifest["native"] = Value::Array(copied);
        }
        std::fs::write(dir.join("manifest.json"), serde_json::to_string_pretty(&manifest)?)?;
        Ok(dir)
    }

    pub async fn import(
        self: &Arc<Self>,
        bundle: &Path,
        name: Option<String>,
    ) -> Result<Arc<Session>, RpcError> {
        let session = self.import_into(bundle, name, false, None, false, false).await?;
        Ok(session)
    }

    /// `import`; a `live` one (a chat moved here, `transfer_in.rs`) has its queue back before
    /// any client sees it, so no new prompt runs ahead of it. A `guard`ed one (`transfer_guard.rs`)
    /// queues under the guard's control and restores only its own agent file, without its mode.
    pub(super) async fn import_into(
        self: &Arc<Self>,
        bundle: &Path,
        name: Option<String>,
        live: bool,
        guarded: Option<super::transfer_guard::GuardedImport<'_>>,
        replace_durable: bool,
        defer_finalize: bool,
    ) -> Result<Arc<Session>, RpcError> {
        let meta_text = std::fs::read_to_string(bundle.join("session.json"))
            .map_err(|e| RpcError::invalid_params(format!("read session.json: {e}")))?;
        let mut meta: SessionMeta = serde_json::from_str(&meta_text)
            .map_err(|e| RpcError::invalid_params(format!("parse session.json: {e}")))?;
        // A store comes from this machine's chat index, never from a bundle.
        meta.chat_store = None;
        // Nor is a mode cmux set here, which only this daemon records (`SessionMeta::mode_set_by_cmux`).
        meta.mode_set_by_cmux = None;
        super::bookmarks::capped(&mut meta.bookmarks);
        // The id becomes a directory name under the sessions root.
        if !is_plain_id(&meta.id) {
            return Err(RpcError::invalid_params(format!(
                "bundle session id {:?} is not a plain id",
                meta.id
            )));
        }
        if let Some(n) = &name {
            crate::session_name::validate(n).map_err(RpcError::invalid_params)?;
            if self.sessions.lock().unwrap().values().any(|s| s.meta().name == *n) {
                return Err(RpcError::invalid_params(format!("session name {n:?} is taken")));
            }
        }
        // Claim the id so a concurrent import of the same bundle fails
        // instead of writing the store and log a second time.
        let _reservation = {
            let sessions = self.sessions.lock().unwrap();
            let mut importing = self.importing.lock().unwrap();
            let existing_moved =
                sessions.get(&meta.id).is_some_and(|session| self.moved_away(session));
            if (sessions.contains_key(&meta.id) && !(replace_durable && existing_moved))
                || !importing.insert(meta.id.clone())
            {
                return Err(RpcError::invalid_params(format!(
                    "session {} already exists here",
                    meta.id
                )));
            }
            ImportReservation { hub: self, id: meta.id.clone() }
        };
        if let Some(n) = name {
            meta.name = n;
        } else if self.sessions.lock().unwrap().values().any(|s| s.meta().name == meta.name) {
            meta.name = self.unique_name(&meta.name);
        }
        if !self.config.read().await.harnesses.contains_key(&meta.harness) {
            return Err(RpcError::invalid_params(format!(
                "agent {:?} is not configured on this host",
                meta.harness
            )));
        }
        if !meta.cwd.is_dir() {
            // `reason` and `cwd` let a client say it in its own words (`cli/errors.rs` `detail`).
            let e = RpcError::invalid_params(format!(
                "cwd {} does not exist here; pass a new cwd via fork or edit session.json",
                meta.cwd.display()
            ));
            return Err(e.with_data(json!({"reason": "cwd_missing", "cwd": meta.cwd})));
        }
        meta.status = SessionStatus::Idle;
        // A family lives on one daemon: a moved-in sub-session is a root here.
        meta.subsession = None;
        self.prepare_harness_state(&meta, replace_durable)
            .map_err(|e| RpcError::internal(e.to_string()))?;
        let session = self.make_session(meta.clone());
        self.store.save(&meta).map_err(|e| RpcError::internal(e.to_string()))?;
        // Copy events verbatim, preserving seq. A partial transcript is not
        // a valid import: any unreadable file or record rolls it back.
        let last = match self.copy_bundle_events(bundle, &meta.id, guarded.map(|g| g.guard.control))
        {
            Ok(last) => last,
            Err(e) => {
                let _ = self.store.delete(&meta.id);
                return Err(RpcError::invalid_params(format!("import events: {e}")));
            }
        };
        if let Err(e) = self.restore_harness_state(bundle, &meta, replace_durable) {
            let _ = self.store.delete(&meta.id);
            return Err(RpcError::invalid_params(format!("import durable journal: {e}")));
        }
        let restored = match guarded {
            None => crate::native::restore(bundle, &meta).unwrap_or_default(),
            // A guarded chat keeps its agent session only with its file: a failed restore fails
            // the import, like its events.
            Some(g) => {
                let restored = crate::native::guarded_plan(bundle, &meta)
                    .map_err(anyhow::Error::msg)
                    .and_then(|plan| crate::native::restore_guarded(&plan, g.replace_native));
                match restored {
                    Ok(n) => n,
                    Err(e) => {
                        let _ = self.store.delete(&meta.id);
                        return Err(RpcError::new(-32000, format!("transfer.native: {e:#}")));
                    }
                }
            }
        };
        session.seq.store(last, Ordering::SeqCst);
        session.meta.lock().unwrap().last_seq = last;
        if live {
            self.restore_queue(&session);
            // Its log holds the source's move (`transfer_out`), not one of this daemon's.
            *session.moving.lock().unwrap_or_else(|e| e.into_inner()) = None;
        }
        self.sessions.lock().unwrap().insert(meta.id.clone(), session.clone());
        self.offers.forget(&meta.id);
        self.append(
            &session,
            "mux",
            "imported",
            json!({"from": bundle, "nativeRestored": restored}),
        );
        self.save_meta(&session);
        if !defer_finalize {
            if let Err(error) = self.finalize_harness_state(&session.meta()) {
                self.recover_staged_replacements();
                let _ = self.kill(&session, true).await;
                return Err(RpcError::internal(error.to_string()));
            }
        }
        Ok(session)
    }

    /// Append every record of a bundle's `events/*.ndjson` to the store, in
    /// file order. Returns the highest sequence copied. Under a guard's `control`, the
    /// records of prompts still to run carry it (`transfer_guard.rs` `guarded_record`).
    fn harness_pi_session_optional(
        root: &Path,
        agent_id: &str,
    ) -> Result<Option<(PathBuf, Vec<u8>)>> {
        if !plain_agent_session(agent_id) {
            return Err(anyhow::anyhow!("invalid cmux-harness ACP session id"));
        }
        let mut found = None;
        for entry in std::fs::read_dir(root)? {
            let entry = entry?;
            let path = entry.path();
            let file_type = std::fs::symlink_metadata(&path)?.file_type();
            if !file_type.is_file() || path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let bytes = std::fs::read(&path)?;
            let first = bytes.splitn(2, |b| *b == b'\n').next().unwrap_or_default();
            let Ok(header) = serde_json::from_slice::<Value>(first) else { continue };
            let id = header.get("id").and_then(Value::as_str);
            let valid = header.get("type").and_then(Value::as_str) == Some("session")
                && header.get("cwd").and_then(Value::as_str).is_some();
            if valid && id == Some(agent_id) {
                if found.is_some() {
                    return Err(anyhow::anyhow!("multiple Pi sessions match ACP session id"));
                }
                found = Some((path, bytes));
            }
        }
        Ok(found)
    }

    fn harness_pi_session(root: &Path, agent_id: &str) -> Result<(PathBuf, Vec<u8>)> {
        Self::harness_pi_session_optional(root, agent_id)?
            .ok_or_else(|| anyhow::anyhow!("Pi session file for ACP session id is missing"))
    }

    fn rebind_harness_pi_session(bytes: &[u8], agent_id: &str, cwd: &Path) -> Result<Vec<u8>> {
        let Some(split) = bytes.iter().position(|b| *b == b'\n') else {
            return Err(anyhow::anyhow!("Pi session file has no header"));
        };
        let mut header: Value = serde_json::from_slice(&bytes[..split])?;
        let id = header.get("id").and_then(Value::as_str);
        if header.get("type").and_then(Value::as_str) != Some("session")
            || header.get("cwd").and_then(Value::as_str).is_none()
            || id != Some(agent_id)
        {
            return Err(anyhow::anyhow!(
                "Pi session header is not a valid session for this ACP id"
            ));
        }
        header["cwd"] = Value::String(cwd.to_string_lossy().into_owned());
        let mut out = serde_json::to_vec(&header)?;
        out.push(b'\n');
        out.extend_from_slice(&bytes[split + 1..]);
        Ok(out)
    }

    pub(super) fn prepare_harness_state(
        &self,
        meta: &SessionMeta,
        replace_durable: bool,
    ) -> Result<()> {
        if meta.harness != "cmux-harness" {
            return Ok(());
        }
        let Some(agent_id) = meta.agent_session_id.as_deref() else { return Ok(()) };
        if !plain_agent_session(agent_id) {
            return Err(anyhow::anyhow!("invalid cmux-harness ACP session id"));
        }
        let Some(session_dir) = self.store.session_dir(&meta.id) else { return Ok(()) };
        let Some(root) = session_dir.parent() else { return Ok(()) };
        let marker = root.join(format!(".{agent_id}.durable-transfer-state"));
        if std::fs::symlink_metadata(&marker).is_ok() {
            return Err(anyhow::anyhow!("durable transfer recovery marker is already present"));
        }
        write_json_atomic(
            &marker,
            &json!({
                "outerId": meta.id,
                "agentId": agent_id,
                "replaceDurable": replace_durable,
                "phase": "prepared",
            }),
        )
    }

    fn export_harness_state(&self, meta: &SessionMeta, dir: &Path) -> Result<Value> {
        if meta.harness != "cmux-harness" {
            return Ok(Value::Null);
        }
        let agent_id = meta.agent_session_id.as_deref().ok_or_else(|| {
            anyhow::anyhow!("cmux-harness durable state requires an ACP session id")
        })?;
        if !plain_agent_session(agent_id) {
            return Err(anyhow::anyhow!("invalid cmux-harness ACP session id"));
        }
        let Some(session_dir) = self.store.session_dir(&meta.id) else {
            return Err(anyhow::anyhow!(
                "cmux-harness durable state requires a local session store"
            ));
        };
        let root =
            session_dir.parent().ok_or_else(|| anyhow::anyhow!("invalid session store root"))?;
        let legacy_root = dirs::home_dir()
            .map(|home| home.join(".cmux-harness").join("sessions"))
            .filter(|legacy| legacy != root);
        let current_state_present = std::fs::symlink_metadata(root.join(agent_id)).is_ok()
            || std::fs::read_dir(root).into_iter().flatten().flatten().any(|entry| {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                    return false;
                }
                let Ok(bytes) = std::fs::read(path) else { return false };
                let first = bytes.splitn(2, |b| *b == b'\n').next().unwrap_or_default();
                serde_json::from_slice::<Value>(first).ok().and_then(|header| {
                    header
                        .get("id")
                        .or_else(|| header.get("sessionId"))
                        .and_then(Value::as_str)
                        .map(|id| id == agent_id)
                }) == Some(true)
            });
        let (journal_root, pi_session_path, session_bytes) =
            match Self::harness_pi_session_optional(root, agent_id)? {
                Some((path, bytes)) => (root.to_path_buf(), path, bytes),
                None if !current_state_present => {
                    let legacy = legacy_root.ok_or_else(|| {
                        anyhow::anyhow!("Pi session file for ACP session id is missing")
                    })?;
                    let durable = legacy
                        .parent()
                        .map(|parent| parent.join("durable"))
                        .ok_or_else(|| anyhow::anyhow!("invalid legacy harness root"))?;
                    let (path, bytes) = Self::harness_pi_session(&legacy, agent_id)?;
                    (durable, path, bytes)
                }
                None => {
                    return Err(anyhow::anyhow!(
                        "current cmux-harness state is present but its Pi session is invalid"
                    ));
                }
            };
        let journal = journal_root.join(agent_id).join("journal.ndjson");
        let pi_filename = pi_session_path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| anyhow::anyhow!("Pi session filename is not valid UTF-8"))?;
        if pi_filename.is_empty()
            || pi_filename.len() > 256
            || !pi_filename.ends_with(".jsonl")
            || Path::new(pi_filename).components().count() != 1
        {
            return Err(anyhow::anyhow!("Pi session filename is unsafe"));
        }
        let read_private = |path: &Path, label: &str| -> Result<Vec<u8>> {
            let meta = std::fs::symlink_metadata(path)?;
            if !meta.file_type().is_file() {
                return Err(anyhow::anyhow!("{label} is not a regular file"));
            }
            Ok(std::fs::read(path).map_err(|e| anyhow::anyhow!("read {label}: {e}"))?)
        };
        let journal_bytes = read_private(&journal, "durable journal")?;
        let target = dir.join("harness");
        std::fs::create_dir_all(&target)?;
        std::fs::write(target.join("journal.ndjson"), &journal_bytes)?;
        std::fs::write(target.join("session.jsonl"), &session_bytes)?;
        Ok(json!({
            "sessionId": agent_id,
            "journal": {"path": "harness/journal.ndjson", "size": journal_bytes.len(), "sha256": crate::sha256::sha256_hex(&journal_bytes)},
            "session": {"path": "harness/session.jsonl", "filename": pi_filename, "size": session_bytes.len(), "sha256": crate::sha256::sha256_hex(&session_bytes)},
        }))
    }

    fn restore_harness_state(
        &self,
        bundle: &Path,
        meta: &SessionMeta,
        replace_durable: bool,
    ) -> Result<()> {
        if meta.harness != "cmux-harness" {
            return Ok(());
        }
        let agent_id = meta.agent_session_id.as_deref().ok_or_else(|| {
            anyhow::anyhow!("cmux-harness durable transfer requires an ACP session id")
        })?;
        if !plain_agent_session(agent_id) {
            return Err(anyhow::anyhow!("invalid cmux-harness ACP session id"));
        }
        let manifest: Value =
            serde_json::from_str(&std::fs::read_to_string(bundle.join("manifest.json"))?)?;
        let spec = manifest
            .get("harness")
            .filter(|v| !v.is_null())
            .ok_or_else(|| anyhow::anyhow!("missing cmux-harness durable manifest"))?;
        if spec.get("sessionId").and_then(Value::as_str) != Some(agent_id) {
            return Err(anyhow::anyhow!("cmux-harness ACP session id mismatch"));
        }
        let checked = |key: &str, path: &str| -> Result<Vec<u8>> {
            let item = spec
                .get(key)
                .ok_or_else(|| anyhow::anyhow!("missing cmux-harness {key} manifest"))?;
            if item.get("path").and_then(Value::as_str) != Some(path) {
                return Err(anyhow::anyhow!("invalid cmux-harness durable path"));
            }
            let bytes = std::fs::read(bundle.join(path))?;
            if item.get("size").and_then(Value::as_u64) != Some(bytes.len() as u64)
                || item.get("sha256").and_then(Value::as_str)
                    != Some(crate::sha256::sha256_hex(&bytes).as_str())
            {
                return Err(anyhow::anyhow!("cmux-harness durable digest mismatch"));
            }
            Ok(bytes)
        };
        let journal_bytes = checked("journal", "harness/journal.ndjson")?;
        let session_bytes = checked("session", "harness/session.jsonl")?;
        let pi_filename_owned;
        let mut pi_filename = spec
            .get("session")
            .and_then(|v| v.get("filename"))
            .and_then(Value::as_str)
            .unwrap_or("");
        if pi_filename.is_empty() {
            pi_filename_owned = format!("{agent_id}.jsonl");
            pi_filename = &pi_filename_owned;
        }
        if pi_filename.is_empty()
            || pi_filename.len() > 256
            || !pi_filename.ends_with(".jsonl")
            || Path::new(pi_filename).components().count() != 1
        {
            return Err(anyhow::anyhow!("Pi session filename is unsafe"));
        }
        let session_bytes = Self::rebind_harness_pi_session(&session_bytes, agent_id, &meta.cwd)?;
        let _state_lock = HARNESS_STATE_LOCK
            .lock()
            .map_err(|_| anyhow::anyhow!("durable transfer lock poisoned"))?;
        let session_dir = self
            .store
            .session_dir(&meta.id)
            .ok_or_else(|| anyhow::anyhow!("target has no local session store"))?;
        let root = session_dir
            .parent()
            .ok_or_else(|| anyhow::anyhow!("invalid target session store root"))?;
        let journal_dir = root.join(agent_id);
        let journal_dir_was_present = std::fs::symlink_metadata(&journal_dir).is_ok();
        if let Ok(meta) = std::fs::symlink_metadata(&journal_dir) {
            if meta.file_type().is_symlink() || !meta.file_type().is_dir() {
                return Err(anyhow::anyhow!("target durable session is not a real directory"));
            }
        }
        if std::fs::symlink_metadata(&journal_dir).is_ok() && !replace_durable {
            return Err(anyhow::anyhow!("target durable session is already occupied"));
        }
        if let Ok(owner) = std::fs::symlink_metadata(journal_dir.join("owner.sqlite")) {
            if owner.file_type().is_symlink() {
                return Err(anyhow::anyhow!("target durable owner lock is symlinked"));
            }
        }
        if !replace_durable && Self::harness_pi_session_optional(root, agent_id)?.is_some() {
            return Err(anyhow::anyhow!("target already has a Pi session for this ACP id"));
        }
        let existing_pi =
            if replace_durable { Self::harness_pi_session_optional(root, agent_id)? } else { None };
        let pi_target = existing_pi
            .as_ref()
            .map(|(path, _)| path.clone())
            .unwrap_or_else(|| root.join(pi_filename));
        if let Ok(meta) = std::fs::symlink_metadata(&pi_target) {
            if meta.file_type().is_symlink() || !meta.file_type().is_file() {
                return Err(anyhow::anyhow!("target Pi session is not a real file"));
            }
            if existing_pi.is_none() {
                return Err(anyhow::anyhow!("target Pi session filename is already occupied"));
            }
        }
        let journal = journal_dir.join("journal.ndjson");
        let journal_tmp = journal_dir.join("journal.ndjson.importing");
        let journal_backup = journal_dir.join("journal.ndjson.transfer-backup");
        let target_filename = pi_target
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| anyhow::anyhow!("Pi session target filename is invalid"))?;
        let session_tmp = root.join(format!("{target_filename}.importing"));
        let session_backup = root.join(format!("{target_filename}.transfer-backup"));
        for path in [&journal_tmp, &session_tmp, &journal_backup, &session_backup] {
            if std::fs::symlink_metadata(path).is_ok() {
                return Err(anyhow::anyhow!("durable transfer temporary path is occupied"));
            }
        }
        let durable_state = root.join(format!(".{agent_id}.durable-transfer-state"));
        if let Ok(raw) = std::fs::read(&durable_state) {
            let prepared: Value = serde_json::from_slice(&raw)?;
            if prepared.get("outerId").and_then(Value::as_str) != Some(meta.id.as_str()) {
                return Err(anyhow::anyhow!(
                    "durable transfer recovery marker belongs to another session"
                ));
            }
        }
        write_json_atomic(
            &durable_state,
            &json!({
                "agentId": agent_id,
                "outerId": meta.id,
                "replaceDurable": replace_durable,
                "phase": "staged",
                "transferId": manifest["transferId"],
                "piFilename": target_filename,
                "journalDirWasPresent": journal_dir_was_present,
                "hadJournal": std::fs::symlink_metadata(&journal).is_ok(),
                "hadPi": std::fs::symlink_metadata(&pi_target).is_ok(),
            }),
        )?;
        std::fs::create_dir_all(&journal_dir)?;
        let mut installed_journal = false;
        let mut installed_pi = false;
        let mut backed_journal = false;
        let mut backed_pi = false;
        let install = (|| -> Result<()> {
            use std::io::Write;
            let mut file =
                std::fs::OpenOptions::new().write(true).create_new(true).open(&journal_tmp)?;
            file.write_all(&journal_bytes)?;
            file.sync_all()?;
            let mut file =
                std::fs::OpenOptions::new().write(true).create_new(true).open(&session_tmp)?;
            file.write_all(&session_bytes)?;
            file.sync_all()?;
            if replace_durable {
                if std::fs::symlink_metadata(&journal).is_ok() {
                    std::fs::rename(&journal, &journal_backup)?;
                    backed_journal = true;
                }
                if std::fs::symlink_metadata(&pi_target).is_ok() {
                    if let Err(e) = std::fs::rename(&pi_target, &session_backup) {
                        let _ = std::fs::rename(&journal_backup, &journal);
                        backed_journal = false;
                        return Err(e.into());
                    }
                    backed_pi = true;
                }
            }
            std::fs::rename(&journal_tmp, &journal)?;
            installed_journal = true;
            std::fs::rename(&session_tmp, &pi_target)?;
            installed_pi = true;
            std::fs::File::open(&journal_dir)?.sync_all()?;
            std::fs::File::open(root)?.sync_all()?;
            Ok(())
        })();
        if let Err(e) = install {
            let _ = std::fs::remove_file(&journal_tmp);
            let _ = std::fs::remove_file(&session_tmp);
            if installed_journal {
                let _ = std::fs::remove_file(&journal);
            }
            if installed_pi {
                let _ = std::fs::remove_file(&pi_target);
            }
            if backed_journal {
                let _ = std::fs::rename(&journal_backup, &journal);
            }
            if backed_pi {
                let _ = std::fs::rename(&session_backup, &pi_target);
            }
            if !journal_dir_was_present {
                let _ = std::fs::remove_dir(&journal_dir);
            }
            let _ = std::fs::remove_file(&durable_state);
            return Err(e);
        }
        Ok(())
    }

    pub(super) fn mark_harness_state_committed(&self, meta: &SessionMeta) -> Result<()> {
        if meta.harness != "cmux-harness" {
            return Ok(());
        }
        let Some(agent_id) = meta.agent_session_id.as_deref() else { return Ok(()) };
        let Some(session_dir) = self.store.session_dir(&meta.id) else { return Ok(()) };
        let Some(root) = session_dir.parent() else { return Ok(()) };
        let state = root.join(format!(".{agent_id}.durable-transfer-state"));
        let mut marker = serde_json::from_slice::<Value>(&std::fs::read(&state)?)?;
        marker["phase"] = json!("committed");
        write_json_atomic(&state, &marker)
    }

    pub(super) fn finalize_harness_state(&self, meta: &SessionMeta) -> Result<()> {
        if meta.harness != "cmux-harness" {
            return Ok(());
        }
        let Some(agent_id) = meta.agent_session_id.as_deref() else { return Ok(()) };
        let Some(session_dir) = self.store.session_dir(&meta.id) else { return Ok(()) };
        let Some(root) = session_dir.parent() else { return Ok(()) };
        let state = root.join(format!(".{agent_id}.durable-transfer-state"));
        let mut marker = serde_json::from_slice::<Value>(&std::fs::read(&state)?)?;
        marker["phase"] = json!("committed");
        write_json_atomic(&state, &marker)?;
        let filename = marker.get("piFilename").and_then(Value::as_str).unwrap_or("");
        if !filename.is_empty() {
            std::fs::remove_file(root.join(format!("{filename}.transfer-backup"))).or_else(
                |e| {
                    if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) }
                },
            )?;
        }
        std::fs::remove_file(root.join(agent_id).join("journal.ndjson.transfer-backup")).or_else(
            |e| {
                if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) }
            },
        )?;
        std::fs::remove_file(&state)
            .or_else(|e| if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) })?;
        std::fs::File::open(root)?.sync_all()?;
        Ok(())
    }

    fn copy_bundle_events(&self, bundle: &Path, id: &str, control: Option<Control>) -> Result<u64> {
        let events_path = bundle.join("events");
        if !events_path.exists() {
            return Ok(0);
        }
        let mut files: Vec<PathBuf> = Vec::new();
        for entry in std::fs::read_dir(&events_path)? {
            let path = entry?.path();
            if path.extension().and_then(|e| e.to_str()) == Some("ndjson") {
                files.push(path);
            }
        }
        files.sort();
        let mut last = 0;
        for f in files {
            let text = std::fs::read_to_string(&f)
                .map_err(|e| anyhow::anyhow!("read {}: {e}", f.display()))?;
            for (n, line) in text.lines().enumerate() {
                if line.trim().is_empty() {
                    continue;
                }
                let mut rec: EventRecord = serde_json::from_str(line)
                    .map_err(|e| anyhow::anyhow!("{} line {}: {e}", f.display(), n + 1))?;
                if let Some(control) = control {
                    super::transfer_guard::guarded_record(&mut rec, control);
                }
                last = last.max(rec.seq);
                self.store.append(id, &rec)?;
            }
        }
        Ok(last)
    }
}
