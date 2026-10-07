//! Part of `Hub`; see `hub/mod.rs`. The `_acpmux/harnesses` reply.

use super::*;

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
        json!({"harnesses": agents, "defaultHarness": cfg.default_harness, "families": cfg.families(), "defaults": cfg.defaults, "presets": cfg.presets, "diagnostics": cfg.profile_diagnostics})
    }
}
