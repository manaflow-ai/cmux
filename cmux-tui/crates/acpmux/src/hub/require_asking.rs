//! Part of `Hub`; see `hub/mod.rs`. `session/new` with `_meta.acpmux.requireAsking`: a start
//! that must ask before each change or not start at all. The acpmux MCP server's guest mode
//! (`acpmux_mcp_guest.rs`, through `acpmux new --require-asking`) sends it: a guest is not the
//! person, so a session it starts never acts without asking.
//!
//! A session's policy is held only in a harness mode that asks (`policy_mode.rs`); a harness
//! with none (the legacy codex-acp adapter, opencode, pi) logs `policy_unenforced` and runs.
//! This start is refused instead, before anything exists, by the table the Web and paired
//! machines start from (`web_modes::remote_start`, the reviewed asking modes): fail closed,
//! so a harness that does not resolve, or resolves to one that table does not list, is refused.
//! Also refused: no policy or approve-all, a start mode (`_meta.acpmux.mode`) and an adopt.
//!
//! The request check (`check_require_asking`) answers early; the start itself carries it
//! (`NewRequest::require_asking`) and checks again on the profile it actually resolves, under the
//! same config read (`lifecycle.rs`), so a config reload between the two (bare `codex` moved from
//! the bridge to the legacy adapter) is refused, and its `ask` policy fails the start if the
//! harness does not keep it (`policy_mode::require_enforced`), never only logged.

use super::*;

/// The `_meta.acpmux` field that asks for it.
pub const FIELD: &str = "requireAsking";
/// The `initialize` feature that says this daemon refuses on [`FIELD`]: a client that needs
/// it refuses to start against a daemon that would ignore it.
pub const FEATURE: &str = "requireAsking";

/// Whether `session/new`'s `_meta.acpmux` asks for it.
pub(crate) fn asked(meta: Option<&Value>) -> bool {
    meta.and_then(|m| m.get(FIELD)).and_then(Value::as_bool) == Some(true)
}

fn refused(why: String) -> RpcError {
    RpcError::invalid_params(why).with_data(json!({"reason": "start.not_asking"}))
}

/// Whether a start of `agent` (resolved to `profile`) under `policy`, with `meta`, is held to
/// asking before each change.
pub(crate) fn admits(
    cfg: &Config,
    agent: &str,
    profile: &HarnessProfile,
    policy: Option<PermissionPolicy>,
    meta: Option<&Value>,
) -> Result<(), RpcError> {
    if !policy.is_some_and(|p| p != PermissionPolicy::ApproveAll) {
        return Err(refused(
            "a start held to asking needs a policy narrower than approve-all".to_owned(),
        ));
    }
    let mode = meta.and_then(|m| m.get(crate::hub::person::START_MODE_FIELD));
    if mode.is_some_and(|m| !m.is_null()) {
        return Err(refused("a start held to asking takes no start mode".to_owned()));
    }
    crate::web_modes::remote_start_for_config(cfg, agent, profile).map(|_| ()).map_err(|why| {
        refused(format!("{agent} cannot be held to asking before each change: {why}"))
    })
}

/// The start's own check (`lifecycle.rs`), on the profile it resolved and under the config read
/// it resolved it with: a narrow policy, no adopt, and a harness the asking table lists.
pub(super) fn holds_at_start(
    cfg: &Config,
    agent: &str,
    profile: &HarnessProfile,
    policy: Option<PermissionPolicy>,
    adopting: bool,
) -> Result<(), RpcError> {
    if adopting {
        return Err(refused("a start held to asking adopts no conversation".to_owned()));
    }
    admits(cfg, agent, profile, policy, None)
}

impl Hub {
    /// [`admits`] for what `session/new` would resolve (`resolve_new`), before it exists.
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn check_require_asking(
        &self,
        harness: Option<String>,
        preset: Option<String>,
        model: Option<String>,
        cwd: Option<&Path>,
        policy: Option<PermissionPolicy>,
        meta: Option<&Value>,
        adopting: bool,
    ) -> Result<(), RpcError> {
        if adopting {
            return Err(refused("a start held to asking adopts no conversation".to_owned()));
        }
        self.wait_startup().await;
        let cfg = self.config.read().await;
        let r = self.resolve_new(&cfg, harness, &preset, model.as_deref(), false, cwd)?;
        admits(&cfg, &r.agent, &r.profile, policy, meta)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(value: Value) -> HarnessProfile {
        serde_json::from_value(value).unwrap()
    }

    /// Review F1 (#39320, second round): a start held to asking runs only where the asking
    /// table says the harness asks before each change, and is refused, not only logged, elsewhere.
    #[test]
    fn only_a_harness_that_asks_starts_held_to_asking() {
        let cfg = Config::default();
        let ask = Some(PermissionPolicy::Ask);
        let claude = profile(json!({"argv": ["claude"], "family": "claude"}));
        assert!(admits(&cfg, "claude", &claude, ask, None).is_ok());
        let bridge = profile(json!({"argv": ["codex", "app-server"], "family": "codex"}));
        assert!(admits(&cfg, "codex", &bridge, ask, None).is_ok());
        // The legacy adapter edits and runs without asking in every mode: refused, under any
        // name, including the bare `codex` a person's config may point at it.
        let legacy = profile(json!({"argv": ["codex-acp"], "family": "codex"}));
        for name in ["codex-acp", "codex"] {
            let e = admits(&cfg, name, &legacy, ask, None).unwrap_err();
            assert!(e.message.contains("cannot be held to asking"), "{name}: {}", e.message);
        }
        let opencode = profile(json!({"argv": ["opencode", "acp"], "family": "opencode"}));
        assert!(admits(&cfg, "opencode", &opencode, ask, None).is_err());
        // A family no asking table lists is refused.
        let other = profile(json!({"argv": ["foo-agent"]}));
        assert!(admits(&cfg, "foo", &other, ask, None).is_err());
    }

    fn hub_on(harnesses: Value) -> Arc<Hub> {
        let cfg = json!({"harnesses": harnesses, "defaultHarness": "codex"});
        let mut cfg: Config = serde_json::from_value(cfg).unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        Hub::new(cfg, store)
    }

    /// Review F1 (#39320, third round): a config reload between the request check and the start
    /// moves bare `codex` from the bridge to the legacy adapter; the start, on the profile it
    /// resolves itself, is refused, and nothing is created.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_reload_after_the_check_is_refused_at_the_start() {
        let bridge = json!({"codex": {"argv": ["codex", "app-server"], "family": "codex"}});
        let hub = hub_on(bridge);
        let ask = Some(PermissionPolicy::Ask);
        let name = Some("codex".to_owned());
        let dir = std::env::temp_dir();
        let ok = hub.check_require_asking(name.clone(), None, None, Some(&dir), ask, None, false);
        assert!(ok.await.is_ok());
        // The reload, between the check and the start.
        let legacy = json!({"harnesses": {"codex": {"argv": ["codex-acp"], "family": "codex"}}});
        let mut legacy: Config = serde_json::from_value(legacy).unwrap();
        legacy.store.mode = crate::config::StoreMode::Memory;
        *hub.config.write().await = legacy;
        let req = NewRequest {
            harness: name,
            cwd: Some(dir),
            policy: ask,
            require_asking: true,
            ..NewRequest::default()
        };
        let Err(e) = hub.new_session(req).await else {
            panic!("the start ran on the legacy adapter");
        };
        assert!(e.message.contains("cannot be held to asking"), "{}", e.message);
        assert_eq!(e.data.as_ref().and_then(|d| d["reason"].as_str()), Some("start.not_asking"));
        assert!(hub.sessions.lock().unwrap().is_empty());
    }

    #[test]
    fn a_start_held_to_asking_needs_a_narrow_policy_and_no_mode() {
        let cfg = Config::default();
        let claude = profile(json!({"argv": ["claude"], "family": "claude"}));
        assert!(admits(&cfg, "claude", &claude, None, None).is_err());
        assert!(admits(&cfg, "claude", &claude, Some(PermissionPolicy::ApproveAll), None).is_err());
        let mode = json!({"mode": "bypassPermissions"});
        assert!(admits(&cfg, "claude", &claude, Some(PermissionPolicy::Ask), Some(&mode)).is_err());
        let meta = json!({FIELD: true});
        assert!(asked(Some(&meta)));
        assert!(!asked(Some(&json!({FIELD: "yes"}))));
        assert!(!asked(None));
    }
}
