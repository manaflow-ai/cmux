//! Part of `Hub`; see `hub/mod.rs`. The `_acpmux/harnesses` reply.

use super::*;

use crate::config::folder_profiles::{self, FolderProfile};

impl Hub {
    /// Every configured harness: its profile, family, defaults, launcher and
    /// probe problems, and a profile file's display, capability, auth and
    /// sessions data; plus the profile sources' diagnostics.
    pub async fn harnesses_view(&self) -> Value {
        let cfg = self.config.read().await;
        let mut agents = serde_json::Map::new();
        for (name, p) in &cfg.harnesses {
            let mut v = serde_json::to_value(p).unwrap_or(Value::Null);
            if let Some(o) = v.as_object_mut() {
                o.insert("family".into(), json!(crate::config::derive_family(name, p)));
                if let Some(r) = cfg.unavailable.get(name) {
                    o.insert("unavailable".into(), json!(r));
                }
                if let Some(r) = self.probe_errors.lock().unwrap().get(name) {
                    o.insert("probeError".into(), json!(r));
                }
                let d = cfg.defaults_for(name);
                if !d.is_empty() {
                    o.insert("defaults".into(), json!(d));
                }
                // A profile file's display, capability, auth and sessions data.
                if let Some(Value::Object(meta)) =
                    cfg.profile_meta.get(name).and_then(|m| serde_json::to_value(m).ok())
                {
                    for (k, x) in meta {
                        o.insert(k, x);
                    }
                }
            }
            agents.insert(name.clone(), v);
        }
        json!({"harnesses": agents, "defaultHarness": cfg.default_harness, "families": cfg.families(), "defaults": cfg.defaults, "presets": cfg.presets, "diagnostics": cfg.profile_diagnostics, "catalog": self.catalog_harnesses(&cfg)})
    }
}

impl Hub {
    /// `_acpmux/harnesses {cwd?}`: the catalog (`harnesses_view`) and, with an
    /// absolute `cwd`, `folderProfiles`: the folder profiles a chat there
    /// sees, with their state (`folder_profile_row`). A Web or peer
    /// connection (`remote`) never gets them: a folder file is not catalog
    /// data, and its rows must not reach another device.
    pub async fn harnesses_reply(&self, params: &Value, remote: bool) -> Result<Value, RpcError> {
        let cwd = params.get("cwd").and_then(Value::as_str).filter(|c| !c.is_empty());
        let cwd = match cwd.map(PathBuf::from) {
            Some(cwd) if !cwd.is_absolute() => {
                return Err(RpcError::invalid_params("cwd must be an absolute path"));
            }
            other => other,
        };
        let mut view = self.harnesses_view().await;
        let Some(cwd) = cwd.filter(|_| !remote) else { return Ok(view) };
        let cfg = self.config.read().await.clone();
        let rows = tokio::task::spawn_blocking(move || match cfg.folder_gate.as_ref() {
            Some(gate) => folder_profiles::scan_for_cwd(&cfg, gate, &cwd)
                .iter()
                .map(folder_profile_row)
                .collect(),
            None => Vec::new(),
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?;
        view["folderProfiles"] = Value::Array(rows);
        Ok(view)
    }
}

/// One `folderProfiles` row: id, folder, path, state, diagnostics, and when
/// the file parsed displayName?, icon?, kind and family. Never the command
/// line or env.
fn folder_profile_row(fp: &FolderProfile) -> Value {
    let mut row = json!({
        "id": fp.id,
        "folder": fp.folder,
        "path": fp.path,
        "state": fp.state,
        "diagnostics": fp.diagnostics,
    });
    if let Some(meta) = &fp.meta {
        if let Some(name) = &meta.display_name {
            row["displayName"] = json!(name);
        }
        if let Some(icon) = &meta.icon {
            row["icon"] = json!(icon);
        }
    }
    if let Some(profile) = &fp.profile {
        row["kind"] = json!(profile.kind);
        row["family"] = json!(crate::config::derive_family(&fp.id, profile));
    }
    row
}
