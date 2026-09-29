//! Part of `Hub`; see `hub/mod.rs`.

use super::*;

impl Hub {
    // ------------------------------------------------------------- export

    pub fn export(&self, session: &Arc<Session>, dest: &Path) -> Result<PathBuf> {
        let meta = session.meta();
        let dir = dest.join(&meta.id);
        std::fs::create_dir_all(dir.join("events"))?;
        std::fs::write(dir.join("session.json"), serde_json::to_string_pretty(&meta)?)?;
        let events = self.store.events(&meta.id, 0, usize::MAX)?;
        let mut out = std::fs::File::create(dir.join("events").join("000001.ndjson"))?;
        use std::io::Write;
        for e in &events {
            out.write_all(serde_json::to_string(e)?.as_bytes())?;
            out.write_all(b"\n")?;
        }
        let native = crate::native::locate(&meta);
        let mut manifest = json!({
            "schema": "acpmux.bundle.v1",
            "id": meta.id,
            "eventCount": events.len(),
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

    pub async fn import(self: &Arc<Self>, bundle: &Path, name: Option<String>) -> Result<Arc<Session>, RpcError> {
        let meta_text = std::fs::read_to_string(bundle.join("session.json"))
            .map_err(|e| RpcError::invalid_params(format!("read session.json: {e}")))?;
        let mut meta: SessionMeta = serde_json::from_str(&meta_text)
            .map_err(|e| RpcError::invalid_params(format!("parse session.json: {e}")))?;
        if self.sessions.lock().unwrap().contains_key(&meta.id) {
            return Err(RpcError::invalid_params(format!("session {} already exists here", meta.id)));
        }
        if let Some(n) = name {
            meta.name = n;
        } else if self.sessions.lock().unwrap().values().any(|s| s.meta().name == meta.name) {
            meta.name = self.unique_name(&meta.name);
        }
        if !self.config.read().await.harnesses.contains_key(&meta.harness) {
            return Err(RpcError::invalid_params(format!("agent {:?} is not configured on this host", meta.harness)));
        }
        if !meta.cwd.is_dir() {
            return Err(RpcError::invalid_params(format!("cwd {} does not exist here; pass a new cwd via fork or edit session.json", meta.cwd.display())));
        }
        meta.status = SessionStatus::Idle;
        let restored = crate::native::restore(bundle, &meta).unwrap_or_default();
        let session = self.make_session(meta.clone());
        self.store.save(&meta).map_err(|e| RpcError::internal(e.to_string()))?;
        // Copy events verbatim, preserving seq.
        let events_path = bundle.join("events");
        let mut last = 0;
        if let Ok(rd) = std::fs::read_dir(&events_path) {
            let mut files: Vec<_> = rd.flatten().map(|e| e.path()).collect();
            files.sort();
            for f in files {
                if let Ok(text) = std::fs::read_to_string(&f) {
                    for line in text.lines() {
                        if let Ok(rec) = serde_json::from_str::<EventRecord>(line) {
                            last = last.max(rec.seq);
                            let _ = self.store.append(&meta.id, &rec);
                        }
                    }
                }
            }
        }
        session.seq.store(last, Ordering::SeqCst);
        session.meta.lock().unwrap().last_seq = last;
        self.sessions.lock().unwrap().insert(meta.id.clone(), session.clone());
        self.append(&session, "mux", "imported", json!({"from": bundle, "nativeRestored": restored}));
        self.save_meta(&session);
        Ok(session)
    }

}
