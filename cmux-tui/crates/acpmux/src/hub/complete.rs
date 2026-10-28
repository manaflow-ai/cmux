//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/complete` (hq#1957,
//! `crate::complete`): one headless call of a harness's CLI with the
//! harness's own login, profile env and bound route, the way the live-model
//! probe runs it (`hub/live_models.rs`), never a chat session.

use super::*;
use crate::complete::{
    self, CompleteError, Request,
    codex_config::CodexUserConfig,
    model_pick,
    places::Places,
    recipes::{self, Recipe},
    run::{self, RunDir, RunError},
};
use std::collections::BTreeMap;

/// Completions running at once; more wait for a slot within their deadline.
const SLOTS: usize = 4;

static RUNNING: std::sync::LazyLock<tokio::sync::Semaphore> =
    std::sync::LazyLock::new(|| tokio::sync::Semaphore::new(SLOTS));

/// The model ids `_acpmux/models` offers harness `name` (with aliases);
/// `refused`: only those its backend refused, else only those it did not.
fn offered_ids(models: &Value, name: &str, refused: bool) -> Vec<String> {
    let Some(entry) =
        models["harnesses"].as_array().and_then(|list| list.iter().find(|h| h["harness"] == name))
    else {
        return Vec::new();
    };
    let mut ids = Vec::new();
    for model in entry["models"].as_array().into_iter().flatten() {
        // A model its backend refused (`model_availability.rs`).
        if model.get("unavailable").is_some() != refused {
            continue;
        }
        ids.extend(model["id"].as_str().map(str::to_owned));
        for alias in model["aliases"].as_array().into_iter().flatten() {
            ids.extend(alias.as_str().map(str::to_owned));
        }
    }
    ids
}

/// The user's Codex config (`$CODEX_HOME/config.toml`, the profile's
/// `CODEX_HOME` first); empty when there is none.
async fn codex_user_config(env: &BTreeMap<String, String>) -> CodexUserConfig {
    let home = env_value(env, "CODEX_HOME");
    let Some(path) =
        complete::codex_config::config_path(home.as_deref(), dirs::home_dir().as_deref())
    else {
        return CodexUserConfig::default();
    };
    match tokio::fs::read_to_string(&path).await {
        Ok(text) => CodexUserConfig::parse(&text),
        Err(_) => CodexUserConfig::default(),
    }
}

/// `key` from the profile env (with its route), else the login environment,
/// else the daemon's. A secret reference is not a model id.
fn env_value(env: &BTreeMap<String, String>, key: &str) -> Option<String> {
    env.get(key)
        .cloned()
        .or_else(|| crate::login_env::var(key))
        .or_else(|| std::env::var(key).ok())
        .filter(|m| !m.trim().is_empty() && !m.contains("${"))
}

impl Hub {
    /// `_acpmux/complete` from a connection of `origin`: the unix socket
    /// only (`complete::allowed`). Logs the harness, model and duration only.
    pub async fn complete(
        self: &Arc<Self>,
        origin: crate::server::Origin,
        params: &Value,
    ) -> Result<Value, RpcError> {
        if !complete::allowed(origin) {
            return Err(CompleteError::LocalOnly.into());
        }
        let req = Request::parse(params)?;
        let started = std::time::Instant::now();
        let deadline = tokio::time::Instant::now() + req.timeout;
        let (name, profile) = {
            let cfg = self.config.read().await;
            let name = req
                .harness
                .clone()
                .or_else(|| cfg.default_harness.clone())
                .ok_or_else(|| CompleteError::UnknownHarness("(no default harness)".into()))?;
            let profile = cfg
                .harnesses
                .get(&name)
                .cloned()
                .ok_or_else(|| CompleteError::UnknownHarness(name.clone()))?;
            (name, profile)
        };
        let recipe = recipes::recipe_for(&name, &profile)?;
        let reply = self.complete_with(&name, &profile, recipe, &req, deadline).await;
        let ms = started.elapsed().as_millis() as u64;
        match &reply {
            Ok(v) => tracing::info!(
                agent = %name,
                model = %v["model"].as_str().unwrap_or_default(),
                ms,
                "complete"
            ),
            Err(e) => tracing::info!(agent = %name, reason = e.reason(), ms, "complete failed"),
        }
        reply.map_err(RpcError::from)
    }

    /// The harness's small model (`model_pick`). None: the CLI's default.
    async fn small_model(
        &self,
        name: &str,
        recipe: Recipe,
        env: &BTreeMap<String, String>,
        codex: &CodexUserConfig,
    ) -> Option<String> {
        let models = self.models_catalog().await;
        let live: Option<Vec<String>> =
            self.live_models_for(name).map(|list| list.into_iter().map(|m| m.id).collect());
        match recipe {
            Recipe::Claude => {}
            Recipe::Codex => {
                return codex.model_for(&offered_ids(&models, name, false), live.as_deref());
            }
            _ => return model_pick::pick(recipe, &offered_ids(&models, name, false)),
        }
        let refused = offered_ids(&models, name, true);
        let small_fast = env_value(env, model_pick::SMALL_FAST_ENV);
        let default_haiku = env_value(env, model_pick::DEFAULT_HAIKU_ENV);
        Some(model_pick::claude_model(&model_pick::ClaudeInputs {
            small_fast: small_fast.as_deref(),
            default_haiku: default_haiku.as_deref(),
            live: live.as_deref().filter(|l| !l.is_empty()),
            refused: &refused,
        }))
    }

    async fn complete_with(
        self: &Arc<Self>,
        name: &str,
        profile: &HarnessProfile,
        recipe: Recipe,
        req: &Request,
        deadline: tokio::time::Instant,
    ) -> Result<Value, CompleteError> {
        let failed = |detail: String| CompleteError::Failed { harness: name.to_owned(), detail };
        let timed_out = || CompleteError::Timeout {
            harness: name.to_owned(),
            ms: req.timeout.as_millis() as u64,
        };
        // The profile's env with its bound route (claude-sr, claude-cr, a route file).
        let mut env = profile.env.clone();
        self.apply_route_for(name, None, None, false, profile, &mut env)
            .await
            .map_err(|e| failed(e.message))?;
        // Codex runs without the user's config: their provider comes back.
        let codex = match recipe {
            Recipe::Codex => codex_user_config(&env).await,
            _ => CodexUserConfig::default(),
        };
        let model = match &req.model {
            Some(model) => Some(model.clone()),
            None => self.small_model(name, recipe, &env, &codex).await,
        };
        // The CLIs need the login environment (PATH, API keys).
        tokio::time::timeout_at(deadline, self.wait_startup()).await.map_err(|_| timed_out())?;
        let (program, prefix) = recipes::program(recipe, profile, &env, &crate::config::which)
            .ok_or_else(|| CompleteError::NotInstalled {
                harness: name.to_owned(),
                program: profile.argv.first().cloned().unwrap_or_default(),
            })?;
        let _slot = tokio::time::timeout_at(deadline, RUNNING.acquire())
            .await
            .map_err(|_| timed_out())?
            .map_err(|e| failed(e.to_string()))?;
        // One fixed empty cwd; this run's files in its own folder (`places.rs`).
        let places = tokio::task::spawn_blocking(|| {
            let places = Places::for_daemon();
            places.ensure().map(|()| places)
        })
        .await
        .map_err(|e| failed(e.to_string()))?
        .map_err(|e| failed(format!("the run folders: {e:#}")))?;
        let cwd = places.cwd();
        let dir =
            RunDir::new_in(&places.runs()).map_err(|e| failed(format!("a run folder: {e}")))?;
        let folders = recipes::Folders { cwd: &cwd, run: dir.path() };
        let inv = recipes::invocation(recipe, program, prefix, model.as_deref(), folders)
            .with_codex_overrides(&codex.overrides);
        if let Some(file) = &inv.prompt_file {
            dir.write_private(file, req.prompt.as_bytes())
                .map_err(|e| failed(format!("the prompt file: {e}")))?;
        }
        let mut spawn = profile.clone();
        spawn.env = env;
        // The harness's own command line rules: login env, nested-agent and
        // caller markers scrubbed, profile secrets resolved, route unsets.
        let mut cmd = crate::agent::harness_command(
            name,
            &spawn,
            &cwd,
            Some((inv.program.clone(), inv.args.clone())),
            None,
        )
        .map_err(|e| failed(format!("{e:#}")))?;
        for (key, value) in &inv.env_set {
            cmd.env(key, value);
        }
        for key in &inv.env_remove {
            cmd.env_remove(key);
        }
        let input = inv.stdin_prompt.then_some(req.prompt.as_bytes());
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        let out = run::run(cmd, input, left).await.map_err(|e| match e {
            RunError::Timeout => timed_out(),
            RunError::Spawn(why) => failed(format!("cannot start {}: {why}", inv.program)),
        })?;
        let answer = match &inv.output_file {
            Some(file) => run::read_file_capped(file, complete::OUTPUT_CAP).await,
            None => out.stdout.clone(),
        };
        let text = complete::finish(name, &out, &answer, req.max_tokens)?;
        Ok(json!({
            "text": text,
            "harness": name,
            "model": model.unwrap_or_else(|| "default".to_owned()),
        }))
    }
}
