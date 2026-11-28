//! Part of `Hub`; see `hub/mod.rs`. The memory inbox's offer and its answer (`memory_inbox.rs`):
//! a completed turn whose wrap-up offered facts, in a turn with a correction in it, logs a `mux`
//! `memory_offer` record `{offerId, file, facts, heading, created}` once, at the turn's end; the
//! person's Accept or Dismiss (`_acpmux/memory_resolve`, `server/memory_inbox.rs`) writes the
//! accepted facts to that file and logs `memory_resolved` `{offerId, file, accepted, dismissed}`.

use super::*;
use std::path::{Path, PathBuf};

/// Where the dismissed facts of every folder are kept.
fn dismissed() -> crate::memory_inbox::Dismissed {
    crate::memory_inbox::Dismissed::at(crate::config::home().join("memory-dismissed.json"))
}

/// Whether `cwd` is a project folder: not the home folder and not a private agent-home folder.
fn is_project(cwd: &Path) -> bool {
    let home = dirs::home_dir();
    cwd.is_absolute()
        && cwd.parent().is_some()
        && home.as_deref() != Some(cwd)
        && !crate::trust::agent_home_root().is_some_and(|root| cwd.starts_with(root))
}

impl Hub {
    /// The instruction file chat `session` learns into, and its folder.
    async fn learned_target(&self, session: &Session) -> (PathBuf, &'static str) {
        let meta = session.meta();
        let family = {
            let cfg = self.config.read().await;
            crate::context_inventory::family_for_folder(&cfg, &meta.harness)
        };
        let file = crate::folder_instructions::learned_target(&family, &meta.cwd);
        (meta.cwd, file)
    }

    /// A completed turn of `session` that taught something ended with `learned` from its wrap-up:
    /// the facts its folder's file does not say yet are offered. Off the turn's path.
    pub(super) fn offer_learned(self: &Arc<Self>, session: &Arc<Session>, learned: Vec<String>) {
        if learned.is_empty() {
            return;
        }
        let hub = self.clone();
        let session = session.clone();
        tokio::spawn(async move {
            let (cwd, file) = hub.learned_target(&session).await;
            if !is_project(&cwd) {
                return;
            }
            let read = {
                let cwd = cwd.clone();
                tokio::task::spawn_blocking(move || {
                    let existing = crate::memory_inbox::read(&cwd, file);
                    let dismissed = dismissed().of(&cwd);
                    (existing, dismissed)
                })
                .await
            };
            let Ok((Ok(existing), dismissed)) = read else { return };
            let created = existing.is_none();
            let existing = existing.unwrap_or_default();
            let facts = crate::memory_inbox::fresh(&learned, &existing, &dismissed);
            if facts.is_empty() {
                return;
            }
            let heading = (!crate::memory_inbox::has_heading(&existing))
                .then_some(crate::memory_inbox::HEADING);
            hub.append(
                &session,
                "mux",
                "memory_offer",
                json!({
                    "offerId": uuid::Uuid::now_v7().to_string(),
                    "file": file,
                    "facts": facts,
                    "heading": heading,
                    "created": created,
                }),
            );
        });
    }

    /// The person's answer to an offer of `session`: `accept` is written to the chat folder's
    /// instruction file, `dismiss` is never offered there again. The facts are the ones the
    /// person saw; `file` must be the one the chat learns into now.
    pub(crate) async fn memory_resolve(
        &self,
        session: &Arc<Session>,
        offer_id: &str,
        file: &str,
        accept: Vec<String>,
        dismiss: Vec<String>,
    ) -> Result<Value, RpcError> {
        let (cwd, target) = self.learned_target(session).await;
        if !is_project(&cwd) {
            return Err(RpcError::invalid_params("this chat has no project folder"));
        }
        if file != target {
            return Err(RpcError::invalid_params(format!(
                "this chat learns into {target} now, not {file}"
            )));
        }
        let written = {
            let cwd = cwd.clone();
            let accept = accept.clone();
            let dismiss = dismiss.clone();
            tokio::task::spawn_blocking(move || {
                dismissed().add(&cwd, &dismiss);
                if accept.is_empty() {
                    return Ok(Vec::new());
                }
                crate::memory_inbox::write(&cwd, target, &accept)
            })
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?
        };
        let added = written.map_err(RpcError::internal)?;
        let record = json!({
            "offerId": offer_id,
            "file": target,
            "accepted": accept,
            "dismissed": dismiss,
        });
        self.append(session, "mux", "memory_resolved", record);
        Ok(json!({
            "file": target,
            "accepted": accept,
            "dismissed": dismiss,
            "wrote": !added.is_empty(),
        }))
    }
}
