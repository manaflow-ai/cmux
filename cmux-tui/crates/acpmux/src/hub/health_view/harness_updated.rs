//! Part of `Hub`; see `hub/health_view.rs`. One harness update for every
//! chat: after an update installed a new version of a harness (a requested
//! one, `_acpmux/harness/update`, or auto-update), its live chats move to it
//! (`restart_harnesses`: an idle chat restarts now and resumes the same agent
//! session, a busy one when its turn ends), unless the person turned
//! `agents.restartChatsAfterUpdate` off in the cmux settings file (read at
//! each update; on by default). Every `_acpmux/watch` connection then gets
//! one `_acpmux/harness_updated` notification, and each of those chats a
//! `mux` row `harness_updated` (the same payload and `when`: `now`,
//! `after-turn`, `failed` or `manual`), so a chat opened later still shows
//! its receipt. Also `_acpmux/harness/changelog`: what the pending versions
//! bring (`harness_health/changelog.rs`).

use super::*;

use crate::harness_health::HarnessHealth;
use crate::harness_health::probe::is_newer;

use crate::harness_health::{HARNESS_UPDATED_NOTE, RESTART_SETTING};

/// Whether chats restart on their own after an update: the setting, true unless it is `false`.
fn restart_automatically() -> bool {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => {
            crate::user_settings::value(&doc, RESTART_SETTING) != Some(Value::Bool(false))
        }
        _ => true,
    }
}

/// A family's name as people know it, when its profile names none.
fn family_name(family: &str) -> Option<&'static str> {
    Some(match family {
        "claude" => "Claude Code",
        "codex" => "Codex",
        "gemini" => "Gemini CLI",
        "opencode" => "OpenCode",
        _ => return None,
    })
}

impl Hub {
    /// After updates ran: each harness whose installed version is now newer than `before`'s
    /// moves its chats and tells the watchers (`harness_updated`). Returns each one's
    /// `restart` summary by harness id, for the update's reply.
    pub(super) async fn announce_updates(
        self: &Arc<Self>,
        before: &[HarnessHealth],
        after: &[HarnessHealth],
    ) -> std::collections::BTreeMap<String, Value> {
        let mut out = std::collections::BTreeMap::new();
        let installed: Vec<(String, Option<String>, String)> = after
            .iter()
            .filter_map(|row| {
                let to = row.version.clone()?;
                let from = before.iter().find(|b| b.id == row.id)?.version.clone()?;
                // Only a newer version: an unchanged or unreadable one installed nothing.
                is_newer(&to, &from).then(|| (row.id.clone(), Some(from), to))
            })
            .collect();
        if installed.is_empty() {
            return out;
        }
        // Pooled sessions run the old version: new chats start the new one.
        self.drain_pool();
        for (id, from, to) in installed {
            let restart = self.harness_updated(&id, from.as_deref(), &to).await;
            out.insert(id, restart);
        }
        out
    }

    /// Moves harness `id`'s chats to version `to` (when the setting says so), records each one's
    /// receipt and tells the watchers. Returns `{auto, now, afterTurn, failed}`.
    async fn harness_updated(self: &Arc<Self>, id: &str, from: Option<&str>, to: &str) -> Value {
        let auto = restart_automatically();
        let only = std::collections::BTreeSet::from([id.to_owned()]);
        let mut when: Vec<(Arc<Session>, &'static str)> = Vec::new();
        let (now, after_turn, failed) = if auto {
            let done = self.restart_harnesses(Some(&only), None).await;
            let label = |sid: &str| {
                if done.restarted.iter().any(|id| id == sid) {
                    Some("now")
                } else if done.waiting.iter().any(|id| id == sid) {
                    Some("after-turn")
                } else {
                    done.failed.iter().any(|(id, _)| id == sid).then_some("failed")
                }
            };
            for session in self.sessions() {
                if let Some(label) = label(session.id.as_str()) {
                    when.push((session, label));
                }
            }
            (done.now, done.after_turn, done.failed.len())
        } else {
            when.extend(self.restartable(Some(&only), None).into_iter().map(|s| (s, "manual")));
            (0, 0, 0)
        };
        let name = {
            let cfg = self.config.read().await;
            cfg.profile_meta.get(id).and_then(|m| m.display_name.clone()).or_else(|| {
                let profile = cfg.harnesses.get(id)?;
                family_name(&crate::config::derive_family(id, profile)).map(str::to_owned)
            })
        };
        let restart = json!({"auto": auto, "now": now, "afterTurn": after_turn, "failed": failed});
        let payload = json!({
            "harness": id,
            "name": name,
            "from": from,
            "to": to,
            "at": crate::store::now_ms(),
            "restart": restart,
        });
        for (session, label) in when {
            let mut row = payload.clone();
            row["when"] = json!(label);
            self.append(&session, "mux", "harness_updated", row);
        }
        tracing::info!(harness = %id, %to, auto, now, after_turn, failed, "harness updated");
        self.send_harness_change(json!({ (HARNESS_UPDATED_NOTE): payload }));
        restart
    }

    /// `_acpmux/harness/changelog {id, from?, to?, limit?}`: the published changelog's entries in
    /// `(from, to]`, newest first (at most `limit`, default 50, up to 200), and the full
    /// changelog's URL. `from` defaults to the installed version and `to` to the newest one
    /// (`harness_health`). A harness without a known changelog (or no such harness) answers
    /// `{source: null, entries: []}`. `network`: this caller may fetch (else the saved copy).
    pub async fn harness_changelog(
        &self,
        params: &Value,
        network: bool,
    ) -> Result<Value, RpcError> {
        let bad = || RpcError::invalid_params("changelog needs {id, from?, to?, limit?}");
        let id =
            params.get("id").and_then(Value::as_str).filter(|s| !s.is_empty()).ok_or_else(bad)?;
        let version = |key: &str| match params.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(v)) if !v.trim().is_empty() && v.len() <= 64 => {
                Ok(Some(v.trim().to_owned()))
            }
            Some(_) => Err(bad()),
        };
        let (from, to) = (version("from")?, version("to")?);
        let limit = match params.get("limit") {
            None | Some(Value::Null) => 50,
            Some(v) => v.as_u64().filter(|n| (1..=200).contains(n)).ok_or_else(bad)? as usize,
        };
        let family = {
            let cfg = self.config.read().await;
            cfg.harnesses.get(id).map(|p| crate::config::derive_family(id, p))
        };
        let row = self.health.rows().into_iter().find(|r| r.id == id);
        let from = from.or_else(|| row.as_ref().and_then(|r| r.version.clone()));
        let to = to.or_else(|| row.as_ref().and_then(|r| r.latest.clone()));
        let found = match family {
            Some(family) => self.health.changelogs.entries(&family, to.as_deref(), network).await,
            None => None,
        };
        let Some((source, entries)) = found else {
            return Ok(json!({"source": null, "entries": []}));
        };
        let entries = crate::harness_health::changelog::range(
            &entries,
            from.as_deref(),
            to.as_deref(),
            limit,
        );
        Ok(json!({"source": source, "entries": entries}))
    }
}
