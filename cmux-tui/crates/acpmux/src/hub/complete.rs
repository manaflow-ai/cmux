//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/complete` (hq#1957,
//! `crate::complete`): one headless call of a harness's CLI with the
//! harness's own login, profile env and bound route, the way the live-model
//! probe runs it (`hub/live_models.rs`), never a chat session.

use super::*;
use crate::complete::{
    self, CompleteError, Request, model_pick,
    recipes::{self, Recipe},
    run::{self, RunDir, RunError},
};
use std::collections::BTreeMap;

/// Completions running at once; more wait for a slot within their deadline.
const SLOTS: usize = 4;

static RUNNING: std::sync::LazyLock<tokio::sync::Semaphore> =
    std::sync::LazyLock::new(|| tokio::sync::Semaphore::new(SLOTS));

/// The model ids `_acpmux/models` offers harness `name` (with aliases).
fn offered_ids(models: &Value, name: &str) -> Vec<String> {
    let Some(entry) =
        models["harnesses"].as_array().and_then(|list| list.iter().find(|h| h["harness"] == name))
    else {
        return Vec::new();
    };
    let mut ids = Vec::new();
    for model in entry["models"].as_array().into_iter().flatten() {
        // A model its backend refused (`model_availability.rs`) is skipped.
        if model.get("unavailable").is_some() {
            continue;
        }
        ids.extend(model["id"].as_str().map(str::to_owned));
        for alias in model["aliases"].as_array().into_iter().flatten() {
            ids.extend(alias.as_str().map(str::to_owned));
        }
    }
    ids
}

/// `ANTHROPIC_SMALL_FAST_MODEL` from the profile env (with its route), else
/// the login environment. A secret reference is not a model id.
fn small_fast(env: &BTreeMap<String, String>) -> Option<String> {
    env.get(model_pick::SMALL_FAST_ENV)
        .cloned()
        .or_else(|| crate::login_env::var(model_pick::SMALL_FAST_ENV))
        .or_else(|| std::env::var(model_pick::SMALL_FAST_ENV).ok())
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
        // The profile's env with its bound route (claude-sr, claude-cr, a cmux route).
        let mut env = profile.env.clone();
        self.apply_route_for(name, None, None, profile, &mut env)
            .await
            .map_err(|e| failed(e.message))?;
        let model = match &req.model {
            Some(model) => Some(model.clone()),
            None => {
                let models = self.models_catalog().await;
                model_pick::pick(recipe, &offered_ids(&models, name), small_fast(&env).as_deref())
            }
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
        let dir = RunDir::new().map_err(|e| failed(format!("a run folder: {e}")))?;
        let inv = recipes::invocation(recipe, program, prefix, model.as_deref(), dir.path());
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
            dir.path(),
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
