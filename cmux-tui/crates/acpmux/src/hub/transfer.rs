//! Part of `Hub`; see `hub/mod.rs`.

use super::*;
use crate::no_panic::JsonExt;
use crate::no_panic::LockExt;

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
        self.hub.importing.lock_or_recover().remove(&self.id);
    }
}

impl Hub {
    // ------------------------------------------------------------- export

    pub fn export(&self, session: &Arc<Session>, dest: &Path) -> Result<PathBuf> {
        let meta = session.meta();
        let dir = dest.join(&meta.id);
        cmux_blocking::fs::create_dir_all(dir.join("events"))?;
        cmux_blocking::fs::write(dir.join("session.json"), serde_json::to_string_pretty(&meta)?)?;
        use std::io::Write;
        // Stream the log into the bundle; a long session never sits in memory whole.
        let file = cmux_blocking::fs::create(dir.join("events").join("000001.ndjson"))?;
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
        let mut manifest = json!({
            "schema": "acpmux.bundle.v1",
            "id": meta.id,
            "eventCount": event_count,
            "lastSeq": meta.last_seq,
            "native": [],
        });
        if !native.is_empty() {
            cmux_blocking::fs::create_dir_all(dir.join("native"))?;
            let mut copied = Vec::new();
            for (label, src) in native {
                if let Ok(rel) = crate::native::copy_into(&src, &dir.join("native"), &label) {
                    copied.push(json!({"label": label, "path": rel, "source": src}));
                }
            }
            manifest.set("native", Value::Array(copied));
        }
        cmux_blocking::fs::write(
            dir.join("manifest.json"),
            serde_json::to_string_pretty(&manifest)?,
        )?;
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
        let meta_text = tokio::fs::read_to_string(bundle.join("session.json"))
            .await
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
            if self.sessions.lock_or_recover().values().any(|s| s.meta().name == *n) {
                return Err(RpcError::invalid_params(format!("session name {n:?} is taken")));
            }
        }
        // Claim the id so a concurrent import of the same bundle fails
        // instead of writing the store and log a second time.
        let _reservation = {
            let sessions = self.sessions.lock_or_recover();
            let mut importing = self.importing.lock_or_recover();
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
        } else if self.sessions.lock_or_recover().values().any(|s| s.meta().name == meta.name) {
            meta.name = self.unique_name(&meta.name);
        }
        if !self.config.read().await.harnesses.contains_key(&meta.harness) {
            return Err(RpcError::invalid_params(format!(
                "agent {:?} is not configured on this host",
                meta.harness
            )));
        }
        if !tokio::fs::metadata(&meta.cwd).await.is_ok_and(|m| m.is_dir()) {
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
        let (hub, from, copied) = (Arc::clone(self), bundle.to_path_buf(), meta.clone());
        let guard = guarded.map(|g| (g.guard.control, g.replace_native));
        let imported =
            cmux_blocking::spawn_blocking(move || hub.import_files(&from, &copied, guard))
                .await
                .map_err(|e| RpcError::internal(format!("import: {e}")))
                .and_then(|imported| imported);
        let (last, restored) = match imported {
            Ok(imported) => imported,
            Err(e) => {
                let _ = self.store.delete(&meta.id);
                return Err(e);
            }
        };
        session.seq.store(last, Ordering::SeqCst);
        session.meta.lock_or_recover().last_seq = last;
        if live {
            self.restore_queue(&session);
            // Its log holds the source's move (`transfer_out`), not one of this daemon's.
            *session.moving.lock().unwrap_or_else(|e| e.into_inner()) = None;
        }
        self.sessions.lock_or_recover().insert(meta.id.clone(), session.clone());
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

    /// The bundle's events and agent files, copied in (blocking): the highest sequence copied and
    /// how many agent files were restored. A partial transcript is not a valid import: any
    /// unreadable file or record fails it. A guarded chat (`guard`: its control and whether it
    /// replaces its agent file) keeps its agent session only with its file: a failed restore
    /// fails the import, like its events. The caller deletes the stored chat on an error.
    fn import_files(
        &self,
        bundle: &Path,
        meta: &SessionMeta,
        guard: Option<(Control, bool)>,
    ) -> Result<(u64, usize), RpcError> {
        let last = self
            .copy_bundle_events(bundle, &meta.id, guard.map(|(control, _)| control))
            .map_err(|e| RpcError::invalid_params(format!("import events: {e}")))?;
        let restored = match guard {
            None => crate::native::restore(bundle, meta).unwrap_or_default(),
            Some((_, replace_native)) => crate::native::guarded_plan(bundle, meta)
                .map_err(anyhow::Error::msg)
                .and_then(|plan| crate::native::restore_guarded(&plan, replace_native))
                .map_err(|e| RpcError::new(-32000, format!("transfer.native: {e:#}")))?,
        };
        Ok((last, restored))
    }

    /// Append every record of a bundle's `events/*.ndjson` to the store, in
    /// file order. Returns the highest sequence copied. Under a guard's `control`, the
    /// records of prompts still to run carry it (`transfer_guard.rs` `guarded_record`).
    fn copy_bundle_events(&self, bundle: &Path, id: &str, control: Option<Control>) -> Result<u64> {
        let events_path = bundle.join("events");
        if cmux_blocking::fs::metadata(&events_path).is_err() {
            return Ok(0);
        }
        let mut files: Vec<PathBuf> = Vec::new();
        for entry in cmux_blocking::fs::read_dir(&events_path)? {
            let path = entry?.path();
            if path.extension().and_then(|e| e.to_str()) == Some("ndjson") {
                files.push(path);
            }
        }
        files.sort();
        let mut last = 0;
        for f in files {
            let text = cmux_blocking::fs::read_to_string(&f)
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
