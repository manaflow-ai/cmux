//! The environment and directories of an app server (`servers.rs`): only
//! `CMUX_APP_ID`, `CMUX_APP_DATA_DIR`, a per-app `TMPDIR` and the daemon's
//! `LANG`; the data and temporary directories are created at start and
//! removed at uninstall.

use std::path::{Path, PathBuf};

use serde_json::Value;

use super::supervisor::{ApiError, Inner, Supervisor};

impl Supervisor {
    /// The data and temporary directories of `app`'s server:
    /// `<state>/apps-data/<namespace>` and `<state>/apps-tmp/<namespace>`.
    pub(super) fn server_dirs(&self, app: &str) -> (PathBuf, PathBuf) {
        let base =
            self.config.state_dir.clone().unwrap_or_else(|| std::env::temp_dir().join("cmux-apps"));
        let namespace = cmux_app_manifest::app_namespace(app);
        (base.join("apps-data").join(&namespace), base.join("apps-tmp").join(&namespace))
    }

    /// Creates the server's directories and returns its environment (the
    /// allowlist in the module docs).
    pub(super) fn prepare_server_env(
        &self,
        inner: &Inner,
        app: &str,
    ) -> Result<Vec<(String, String)>, ApiError> {
        use std::os::unix::fs::DirBuilderExt;
        let failed = |e: std::io::Error| {
            ApiError::new("apps.server_failed", format!("server directories: {e}"))
        };
        let fresh = |dir: &Path| -> std::io::Result<()> {
            match std::fs::remove_dir_all(dir) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e),
            }
            std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)
        };
        let (data, tmp) = self.server_dirs(app);
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&data).map_err(failed)?;
        let entries = inner
            .catalog
            .packages
            .get(app)
            .and_then(|p| p.manifest.pointer("/server/data").and_then(Value::as_array).cloned())
            .unwrap_or_default();
        for entry in entries {
            // The schema limits names to a local id, so a name stays inside.
            let Some(name) = entry["name"].as_str() else { continue };
            let dir = data.join(name);
            if entry["class"] == "ephemeral" {
                fresh(&dir).map_err(failed)?;
            } else {
                std::fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(&dir)
                    .map_err(failed)?;
            }
        }
        fresh(&tmp).map_err(failed)?;
        let mut env = vec![
            ("CMUX_APP_ID".to_string(), app.to_string()),
            ("CMUX_APP_DATA_DIR".to_string(), data.to_string_lossy().into_owned()),
            ("TMPDIR".to_string(), tmp.to_string_lossy().into_owned()),
        ];
        if let Ok(lang) = std::env::var("LANG") {
            env.push(("LANG".to_string(), lang));
        }
        Ok(env)
    }

    /// Uninstall: the server's data and temporary directories go with the
    /// app's storage.
    pub(super) fn remove_server_dirs(&self, app: &str) {
        let (data, tmp) = self.server_dirs(app);
        let _ = std::fs::remove_dir_all(data);
        let _ = std::fs::remove_dir_all(tmp);
    }
}
