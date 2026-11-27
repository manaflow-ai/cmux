//! Part of `Hub`; see `hub/mod.rs`. The agent's own session files going into a chat's bundle:
//! Claude Code's project file, Codex's rollout, pi's session, OpenCode's export and
//! cmux-harness's journal. A manual move (`transfer.rs` `export_grown`) and an Auto snapshot
//! (`auto_session/export/native.rs`) both carry the chat's agent memory through here, so the
//! two never name different files.

use super::transfer::NATIVE_DIGESTS;
use super::*;

/// What [`Hub::export_agent_files`] put in a bundle, as the bundle's manifest names it.
pub(crate) struct AgentFiles {
    /// The manifest's `native` list: `{label, path, source?}`, `path` under the bundle's
    /// `native` folder.
    pub native: Vec<Value>,
    /// The manifest's `harness`: cmux-harness's durable state under the bundle's `harness`
    /// folder, null for any other agent.
    pub harness: Value,
}

impl Hub {
    /// Copies the agent's own files of the chat `meta` into its bundle folder `dir`.
    ///
    /// `grown` is a history-later prepare's copies of the files and what each holds
    /// (`transfer_precopy.rs` `PrefixFold`): a file that only grew past its copy moves into the
    /// bundle with that growth appended, and `dest`'s [`NATIVE_DIGESTS`] says what its first
    /// bytes hash to.
    pub(crate) fn export_agent_files(
        &self,
        meta: &SessionMeta,
        dir: &Path,
        dest: &Path,
        grown: Option<(&Path, &Value)>,
    ) -> Result<AgentFiles> {
        let native = crate::native::locate(meta);
        let harness = self.export_harness_state(meta, dir)?;
        let mut copied = Vec::new();
        if !native.is_empty() {
            crate::home_fs::create_dirs(dir.join("native"))?;
            let home = dirs::home_dir().unwrap_or_default();
            let mut digests = serde_json::Map::new();
            for (label, src) in native {
                let fast = grown.and_then(|(prepared, held)| {
                    let rel = crate::native::grow_into_from(
                        &src,
                        prepared,
                        &dir.join("native"),
                        &label,
                        &home,
                    );
                    let rel = rel
                        .inspect_err(|e| tracing::debug!("native file not grown: {e:#}"))
                        .ok()??;
                    let at = format!("native/{rel}");
                    if let Some(digest) = held.get(&at) {
                        digests.insert(at, digest.clone());
                    }
                    Some(rel)
                });
                let rel = match fast {
                    Some(rel) => Ok(rel),
                    None => crate::native::copy_into(&src, &dir.join("native"), &label),
                };
                if let Ok(rel) = rel {
                    copied.push(json!({"label": label, "path": rel, "source": src}));
                }
            }
            if !digests.is_empty() {
                let digests = Value::Object(digests).to_string();
                crate::home_fs::write(dest.join(NATIVE_DIGESTS), digests)?;
            }
        }
        // OpenCode keeps its sessions in a database: the session goes as its export. A failed
        // export still moves the chat, which then resumes from this log only.
        match crate::native::export_opencode(meta, &dir.join("native")) {
            Ok(Some(rel)) => {
                copied.push(json!({"label": crate::native::OPENCODE_EXPORT, "path": rel}))
            }
            Ok(None) => {}
            Err(e) => tracing::warn!(session = %meta.id, "opencode session not bundled: {e:#}"),
        }
        Ok(AgentFiles { native: copied, harness })
    }
}
