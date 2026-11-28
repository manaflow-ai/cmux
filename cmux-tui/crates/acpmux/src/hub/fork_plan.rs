//! A chat in plan, forked onto another harness, stays in plan there (Leo's ask c-0e429cbe77:
//! "we ought to really hammer it hard and just test tons of variations of it"; the hammer found
//! a Claude chat in Plan forked onto Codex came up in Codex's `default` collaboration mode).
//!
//! Plan is a toggle a sub-session never inherits (`start_mode.rs` `TOGGLE_MODES`), but a fork is
//! the person's own chat going on elsewhere, so it keeps it, by meaning: Claude's (and Gemini's,
//! opencode's) `plan` mode, Codex's `collaboration_mode` option set to `plan`. Only what the new
//! harness itself advertises is set; one with neither keeps today's start mode. Plan never asks
//! less than the chat's mode did: Claude's plan asks before every tool, Codex's leaves its
//! approval mode (already inherited) as it was.

use crate::hub::*;

/// The mode id, and the `collaboration_mode` value, that mean plan.
pub(super) const PLAN: &str = "plan";
/// Codex's option that holds plan beside its approval modes (`web_modes.rs` `CLI_CONFIG_IDS`).
const COLLABORATION: &str = "collaboration_mode";

/// The current value of config option `id` on `meta`.
fn option_value<'a>(meta: &'a crate::store::SessionMeta, id: &str) -> Option<&'a str> {
    option(meta, id)?.get("currentValue")?.as_str()
}

fn option<'a>(meta: &'a crate::store::SessionMeta, id: &str) -> Option<&'a Value> {
    meta.config_options
        .as_deref()?
        .as_array()?
        .iter()
        .find(|o| o.get("id").and_then(Value::as_str) == Some(id))
}

/// Whether config option `id` on `meta` lists `value` among its choices.
fn option_lists(meta: &crate::store::SessionMeta, id: &str, value: &str) -> bool {
    option(meta, id)
        .and_then(|o| o.get("options"))
        .and_then(Value::as_array)
        .is_some_and(|a| a.iter().any(|v| v.get("value").and_then(Value::as_str) == Some(value)))
}

/// Whether chat `meta` is in plan: its mode, or Codex's collaboration mode.
pub(super) fn in_plan(meta: &crate::store::SessionMeta) -> bool {
    crate::web_modes::mode_of(meta).as_deref() == Some(PLAN)
        || option_value(meta, COLLABORATION) == Some(PLAN)
}

/// Whether chat `meta`'s harness offers a mode named plan.
pub(super) fn offers_plan_mode(meta: &crate::store::SessionMeta) -> bool {
    let modes = meta.modes.as_ref().and_then(|m| m.get("availableModes")).and_then(Value::as_array);
    let in_modes =
        modes.is_some_and(|a| a.iter().any(|m| m.get("id").and_then(Value::as_str) == Some(PLAN)));
    in_modes || option_lists(meta, "mode", PLAN)
}

impl Hub {
    /// Whether the chat `parent` (a fork's source) is in plan.
    pub(super) fn parent_plans(&self, parent: Option<&str>) -> bool {
        parent.and_then(|id| self.resolve(id).ok()).is_some_and(|p| in_plan(&p.meta()))
    }

    /// Puts `fork`, now up, in plan as its harness advertises it: its `plan` mode, else its
    /// `collaboration_mode` option's `plan`. A step its harness refuses is recorded on the fork,
    /// as a fork's other start defaults are (`fork.rs` `start_retargeted`).
    pub(super) async fn carry_plan(self: &Arc<Self>, fork: &Arc<Session>) {
        let meta = fork.meta();
        if in_plan(&meta) {
            return;
        }
        let result = if offers_plan_mode(&meta) {
            Box::pin(self.set_mode(fork, PLAN)).await.map(drop)
        } else if option_lists(&meta, COLLABORATION, PLAN) {
            Box::pin(self.set_config(fork, COLLABORATION, json!(PLAN))).await.map(drop)
        } else {
            return;
        };
        if let Err(e) = result {
            tracing::warn!(session = %fork.id, "fork plan skipped: {}", e.message);
            self.append(
                fork,
                "mux",
                "start_default_skipped",
                json!({"plan": PLAN, "error": e.message}),
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn meta(mut v: Value) -> crate::store::SessionMeta {
        let base = json!({"schema": crate::store::META_SCHEMA, "id": "c", "name": "c",
            "harness": "h", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2});
        for (k, val) in base.as_object().unwrap() {
            v[k] = val.clone();
        }
        serde_json::from_value(v).unwrap()
    }

    #[test]
    fn plan_is_read_from_the_mode_or_codexs_collaboration_mode() {
        let claude = meta(json!({"modes": {"currentModeId": "plan",
            "availableModes": [{"id": "default"}, {"id": "plan"}]}}));
        assert!(in_plan(&claude) && offers_plan_mode(&claude));
        let codex =
            meta(json!({"modes": {"currentModeId": "auto", "availableModes": [{"id": "auto"}]},
            "configOptions": [{"id": "collaboration_mode", "currentValue": "plan",
                                "options": [{"value": "default"}, {"value": "plan"}]}]}));
        assert!(in_plan(&codex) && !offers_plan_mode(&codex));
        assert!(option_lists(&codex, COLLABORATION, PLAN));
        let neither = meta(
            json!({"modes": {"currentModeId": "normal", "availableModes": [{"id": "normal"}]}}),
        );
        assert!(!in_plan(&neither) && !offers_plan_mode(&neither));
        assert!(!option_lists(&neither, COLLABORATION, PLAN));
    }
}
