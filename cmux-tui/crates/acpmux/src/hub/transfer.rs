//! Part of `Hub`; see `hub/mod.rs`.

use super::*;

/// True when `id` is a single plain path component, so it can name a
/// directory under the sessions root (no separator, `.`, `..` or root).
fn is_plain_id(id: &str) -> bool {
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
        let mut manifest = json!({
            "schema": "acpmux.bundle.v1",
            "id": meta.id,
            "eventCount": event_count,
            "lastSeq": meta.last_seq,
            "native": [],
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
        let meta_text = std::fs::read_to_string(bundle.join("session.json"))
            .map_err(|e| RpcError::invalid_params(format!("read session.json: {e}")))?;
        let mut meta: SessionMeta = serde_json::from_str(&meta_text)
            .map_err(|e| RpcError::invalid_params(format!("parse session.json: {e}")))?;
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
            return Err(RpcError::invalid_params(format!(
                "cwd {} does not exist here; pass a new cwd via fork or edit session.json",
                meta.cwd.display()
            )));
        }
        meta.status = SessionStatus::Idle;
        let session = self.make_session(meta.clone());
        self.store.save(&meta).map_err(|e| RpcError::internal(e.to_string()))?;
        // Copy events verbatim, preserving seq. A partial transcript is not
        // a valid import: any unreadable file or record rolls it back.
        let last = match self.copy_bundle_events(bundle, &meta.id) {
            Ok(last) => last,
            Err(e) => {
                let _ = self.store.delete(&meta.id);
                return Err(RpcError::invalid_params(format!("import events: {e}")));
            }
        };
        let restored = crate::native::restore(bundle, &meta).unwrap_or_default();
        session.seq.store(last, Ordering::SeqCst);
        session.meta.lock().unwrap().last_seq = last;
        self.sessions.lock().unwrap().insert(meta.id.clone(), session.clone());
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
    /// file order. Returns the highest sequence copied.
    fn copy_bundle_events(&self, bundle: &Path, id: &str) -> Result<u64> {
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
                let rec: EventRecord = serde_json::from_str(line)
                    .map_err(|e| anyhow::anyhow!("{} line {}: {e}", f.display(), n + 1))?;
                last = last.max(rec.seq);
                self.store.append(id, &rec)?;
            }
        }
        Ok(last)
    }
}

#[cfg(test)]
mod tests {
    use super::is_plain_id;

    #[test]
    fn bundle_ids_must_be_one_plain_component() {
        assert!(is_plain_id("0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"));
        assert!(!is_plain_id(""));
        assert!(!is_plain_id("."));
        assert!(!is_plain_id(".."));
        assert!(!is_plain_id("../escape"));
        assert!(!is_plain_id("a/b"));
        assert!(!is_plain_id("a/"));
        assert!(!is_plain_id("/abs"));
    }
}
