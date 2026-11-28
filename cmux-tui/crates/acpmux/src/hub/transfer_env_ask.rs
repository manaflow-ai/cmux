//! The env a move's target is asked about (RFD 0181 B7): before the source freezes or copies
//! anything, `_acpmux/transfer_preflight` carries the names of the env the chat's first start
//! had that it does not carry itself (`session_manifest::env_to_ask`), and its preset. This
//! daemon builds the env a start of the chat would get here, from its own profile, defaults and
//! that preset (`Hub::spawn_profile_for`, as every start does), and answers the names it lacks
//! (`envLacking`). Names only: no value crosses, and nothing here is written.
//!
//! Before, a move to a machine without the chat's key showed only at the start there (step 4's
//! `manifest-env` line), after the chat had moved. Off unless `ACPMUX_SESSION_MANIFEST=1` here.

use super::*;

impl Hub {
    /// The names of `manifest.env` a start of the chat would lack here, under `as_harness` (the
    /// move's `--as`) or its own harness. Empty while off, with nothing asked, or for a harness
    /// this daemon cannot build a start for (the admission names that refusal).
    pub(in crate::hub) async fn env_lacking_here(
        &self,
        manifest: &Value,
        as_harness: Option<&str>,
    ) -> Vec<String> {
        self.env_lacking_with(crate::session_manifest::on(), manifest, as_harness).await
    }

    pub(super) async fn env_lacking_with(
        &self,
        on: bool,
        manifest: &Value,
        as_harness: Option<&str>,
    ) -> Vec<String> {
        let asked: Vec<String> = manifest["env"]
            .as_array()
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default();
        if !on || asked.is_empty() {
            return Vec::new();
        }
        let harness = as_harness.or(manifest["session"]["harness"].as_str()).unwrap_or_default();
        // The chat as a start here would see it: its harness and preset. Its own session env and
        // store went unasked (`env_to_ask`); a folder only expands values, never adds a name.
        let Ok(meta) = serde_json::from_value::<crate::store::SessionMeta>(json!({
            "schema": crate::store::META_SCHEMA, "id": manifest["sessionId"], "name": "move",
            "harness": harness, "preset": manifest["preset"], "cwd": "/",
            "status": "idle", "createdAt": 0, "updatedAt": 0,
        })) else {
            return Vec::new();
        };
        let (profile, defaults) = {
            let cfg = self.config.read().await;
            match crate::hub::resolve::session_profile(&cfg, harness, &meta.cwd, false) {
                Ok(profile) => (profile, cfg.defaults_for(harness)),
                Err(_) => return Vec::new(),
            }
        };
        let Ok(profile) = self.spawn_profile_for(&meta, &profile, &defaults.env).await else {
            return Vec::new();
        };
        crate::session_manifest::env_lacking(&asked, &profile.env)
    }

    /// The same question for a move over the hub, which asks nothing before its freeze: op
    /// `move`'s `envAsk` (`{names, preset}`, the source's `manifestEnv`) against the moved chat's
    /// harness (`manifest.session.harness`), answered in the move's own `moved` reply
    /// (`hub/transfer_pull.rs`). Empty from a source older than the question.
    pub(in crate::hub) async fn env_lacking_for_move(
        &self,
        body: &Value,
        manifest: &Value,
    ) -> Vec<String> {
        match hub_ask(body, manifest) {
            Some(ask) => self.env_lacking_here(&ask, None).await,
            None => Vec::new(),
        }
    }
}

/// The preflight-shaped manifest [`Hub::env_lacking_with`] reads, made from op `move`'s `envAsk`
/// and the moved chat's manifest: None when the source sent no names.
fn hub_ask(body: &Value, manifest: &Value) -> Option<Value> {
    let ask = body.get("envAsk").filter(|a| a["names"].is_array())?;
    Some(json!({"sessionId": manifest["sessionId"],
                "session": {"harness": manifest["session"]["harness"]},
                "env": ask["names"], "preset": ask["preset"]}))
}

#[cfg(test)]
#[path = "transfer_env_ask_tests.rs"]
mod tests;
