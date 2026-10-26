//! Part of `Hub`; see `hub/mod.rs`.

use super::transfer_guard::plain_agent_session;
use super::*;

/// True when `id` is a single plain path component, so it can name a
/// directory under the sessions root (no separator, `.`, `..` or root).
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
        self.import_into(bundle, name, false, None).await
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
            if sessions.contains_key(&meta.id) || !importing.insert(meta.id.clone()) {
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
        if let Err(e) = self.restore_harness_state(bundle, &meta) {
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
        Ok(session)
    }

    /// Append every record of a bundle's `events/*.ndjson` to the store, in
    /// file order. Returns the highest sequence copied. Under a guard's `control`, the
    /// records of prompts still to run carry it (`transfer_guard.rs` `guarded_record`).
    fn harness_pi_session(root: &Path, agent_id: &str) -> Result<(PathBuf, Vec<u8>)> {
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
            let id = header.get("id").or_else(|| header.get("sessionId")).and_then(Value::as_str);
            if id == Some(agent_id) {
                if found.is_some() {
                    return Err(anyhow::anyhow!("multiple Pi sessions match ACP session id"));
                }
                found = Some((path, bytes));
            }
        }
        found.ok_or_else(|| anyhow::anyhow!("Pi session file for ACP session id is missing"))
    }

    fn rebind_harness_pi_session(bytes: &[u8], agent_id: &str, cwd: &Path) -> Result<Vec<u8>> {
        let Some(split) = bytes.iter().position(|b| *b == b'\n') else {
            return Err(anyhow::anyhow!("Pi session file has no header"));
        };
        let mut header: Value = serde_json::from_slice(&bytes[..split])?;
        let id = header.get("id").or_else(|| header.get("sessionId")).and_then(Value::as_str);
        if id != Some(agent_id) {
            return Err(anyhow::anyhow!("Pi session header id mismatch"));
        }
        if header.get("cwd").is_some() {
            header["cwd"] = Value::String(cwd.to_string_lossy().into_owned());
        }
        let mut out = serde_json::to_vec(&header)?;
        out.push(b'\n');
        out.extend_from_slice(&bytes[split + 1..]);
        Ok(out)
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
        let journal = root.join(agent_id).join("journal.ndjson");
        let (_pi_session_path, session_bytes) = Self::harness_pi_session(root, agent_id)?;
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
            "session": {"path": "harness/session.jsonl", "size": session_bytes.len(), "sha256": crate::sha256::sha256_hex(&session_bytes)},
        }))
    }

    fn restore_harness_state(&self, bundle: &Path, meta: &SessionMeta) -> Result<()> {
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
        let session_bytes = Self::rebind_harness_pi_session(&session_bytes, agent_id, &meta.cwd)?;
        let session_dir = self
            .store
            .session_dir(&meta.id)
            .ok_or_else(|| anyhow::anyhow!("target has no local session store"))?;
        let root = session_dir
            .parent()
            .ok_or_else(|| anyhow::anyhow!("invalid target session store root"))?;
        let journal_dir = root.join(agent_id);
        let existing_same = self.sessions.lock().unwrap().get(&meta.id).is_some_and(|session| {
            session.status() == SessionStatus::Closed
                && self.moved_away(session)
                && session.meta().agent_session_id.as_deref() == Some(agent_id)
        });
        if std::fs::symlink_metadata(&journal_dir).is_ok() && !existing_same {
            return Err(anyhow::anyhow!("target durable session is already occupied"));
        }
        if let Ok(owner) = std::fs::symlink_metadata(journal_dir.join("owner.sqlite")) {
            if owner.file_type().is_symlink() {
                return Err(anyhow::anyhow!("target durable owner lock is symlinked"));
            }
        }
        std::fs::create_dir_all(&journal_dir)?;
        let journal_tmp = journal_dir.join("journal.ndjson.importing");
        let session_tmp = root.join(format!("{agent_id}.jsonl.importing"));
        {
            use std::io::Write;
            let mut file = std::fs::File::create(&journal_tmp)?;
            file.write_all(&journal_bytes)?;
            file.sync_all()?;
            let mut file = std::fs::File::create(&session_tmp)?;
            file.write_all(&session_bytes)?;
            file.sync_all()?;
        }
        std::fs::rename(journal_tmp, journal_dir.join("journal.ndjson"))?;
        std::fs::File::open(&journal_dir)?.sync_all()?;
        std::fs::rename(session_tmp, root.join(format!("{agent_id}.jsonl")))?;
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
