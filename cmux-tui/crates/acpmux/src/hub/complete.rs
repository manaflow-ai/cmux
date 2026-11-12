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

/// The chat a daemon call speaks for (its recap, title or prompt coach): the call carries that
/// chat's text, so it runs on the chat's own harness in the env its own spawn would take (its
/// profile, preset, chat store and session env, then its route with its conversation's account
/// home kept, `Hub::spawn_profile_read`), never another account's or the default route instead.
pub(super) struct ChatRoute {
    meta: SessionMeta,
    /// It forks its parent's conversation (`Session::fork_from`), whose home it runs in.
    forking: bool,
}

impl ChatRoute {
    pub(super) fn of(session: &Session) -> Self {
        Self {
            meta: session.meta(),
            forking: session.fork_from.lock().unwrap_or_else(|e| e.into_inner()).is_some(),
        }
    }
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
        self.complete_request(&req).await.map_err(RpcError::from)
    }

    /// The harness `asked` names, else the daemon's default, with its profile.
    pub(crate) async fn completion_harness(
        &self,
        asked: Option<&str>,
    ) -> Result<(String, HarnessProfile), CompleteError> {
        let cfg = self.config.read().await;
        let name = asked
            .map(str::to_owned)
            .or_else(|| cfg.default_harness.clone())
            .ok_or_else(|| CompleteError::UnknownHarness("(no default harness)".into()))?;
        let profile = cfg
            .harnesses
            .get(&name)
            .cloned()
            .ok_or_else(|| CompleteError::UnknownHarness(name.clone()))?;
        Ok((name, profile))
    }

    /// Whether harness `asked` (else the default) could answer a completion here: it has a
    /// headless recipe and its program is installed. Runs nothing; a signed-out CLI passes.
    pub(crate) async fn completion_ready(
        &self,
        asked: Option<&str>,
    ) -> Result<String, CompleteError> {
        let (name, profile) = self.completion_harness(asked).await?;
        let recipe = recipes::recipe_for(&name, &profile)?;
        recipes::program(recipe, &profile, &profile.env, &crate::config::which).ok_or_else(
            || CompleteError::NotInstalled {
                harness: name.clone(),
                program: profile.argv.first().cloned().unwrap_or_default(),
            },
        )?;
        Ok(name)
    }

    /// One checked completion, for a caller past the origin gate (`complete::allowed`). Logs
    /// the harness, model and duration only.
    pub(crate) async fn complete_request(
        self: &Arc<Self>,
        req: &Request,
    ) -> Result<Value, CompleteError> {
        self.complete_request_for(req, None).await
    }

    /// [`Self::complete_request`] for a call that carries chat `chat`'s text (its title): on
    /// that chat's route.
    pub(super) async fn complete_request_for(
        self: &Arc<Self>,
        req: &Request,
        chat: Option<&ChatRoute>,
    ) -> Result<Value, CompleteError> {
        let started = std::time::Instant::now();
        let deadline = tokio::time::Instant::now() + req.timeout;
        let (name, profile) = self.completion_harness(req.harness.as_deref()).await?;
        let recipe = recipes::recipe_for(&name, &profile)?;
        let reply = self.complete_with(&name, &profile, recipe, req, deadline, chat).await;
        let ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
        match &reply {
            Ok(v) => tracing::info!(
                agent = %name,
                model = %v["model"].as_str().unwrap_or_default(),
                ms,
                "complete"
            ),
            Err(e) => tracing::info!(agent = %name, reason = e.reason(), ms, "complete failed"),
        }
        reply
    }

    /// One headless call for the daemon's own use on chat `chat`'s text (`away_recap.rs`,
    /// `prompt_coach.rs`): the chat's own harness alone, never another, on its small model, in
    /// the env the chat's own spawn takes ([`ChatRoute`]), the answer cut to about `max_tokens`
    /// tokens. An error when the harness has no headless recipe or that env cannot be built:
    /// never the default route or another account instead. The prompt is the daemon's, so
    /// `_acpmux/complete`'s prompt size limit does not apply.
    pub(super) async fn complete_own(
        self: &Arc<Self>,
        chat: &ChatRoute,
        prompt: String,
        max_tokens: u32,
        timeout: std::time::Duration,
    ) -> Result<String, CompleteError> {
        let (name, profile) = self.completion_harness(Some(&chat.meta.harness)).await?;
        self.complete_own_on(name, profile, prompt, max_tokens, timeout, Some(chat)).await
    }

    async fn complete_own_on(
        self: &Arc<Self>,
        name: String,
        profile: HarnessProfile,
        prompt: String,
        max_tokens: u32,
        timeout: std::time::Duration,
        chat: Option<&ChatRoute>,
    ) -> Result<String, CompleteError> {
        let recipe = recipes::recipe_for(&name, &profile)?;
        let req = Request { prompt, harness: Some(name.clone()), model: None, max_tokens, timeout };
        let deadline = tokio::time::Instant::now() + timeout;
        let reply = self.complete_with(&name, &profile, recipe, &req, deadline, chat).await?;
        Ok(reply.get("text").and_then(Value::as_str).unwrap_or_default().to_owned())
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

    /// The env chat `chat`'s own spawn would take now (`Hub::spawn_profile_read`: defaults,
    /// profile, preset, chat store, session env, then its route with its conversation's account
    /// home kept), for a completion of harness `name` on its text. An error, and no call, when
    /// `name` is another harness or the chat's store cannot be told.
    async fn chat_completion_env(
        &self,
        name: &str,
        chat: &ChatRoute,
    ) -> Result<BTreeMap<String, String>, String> {
        let meta = &chat.meta;
        if name != meta.harness {
            return Err(format!(
                "chat {} runs on {}: its text goes to no other harness",
                meta.id, meta.harness
            ));
        }
        if !meta.chat_store_applies() {
            return Err(format!(
                "chat {}'s conversation store does not apply to its harness: nothing is sent",
                meta.id
            ));
        }
        let (profile, defaults) = {
            let cfg = self.config.read().await;
            let profile = super::resolve::session_profile(
                &cfg,
                &meta.harness,
                &meta.cwd,
                meta.remote_origin,
            )?;
            (profile, cfg.defaults_for(&meta.harness))
        };
        let (spawn, ..) = self
            .spawn_profile_read(meta, chat.forking, &profile, &defaults.env)
            .await
            .map_err(|e| e.message)?;
        Ok(spawn.env)
    }

    async fn complete_with(
        self: &Arc<Self>,
        name: &str,
        profile: &HarnessProfile,
        recipe: Recipe,
        req: &Request,
        deadline: tokio::time::Instant,
        chat: Option<&ChatRoute>,
    ) -> Result<Value, CompleteError> {
        let failed = |detail: String| CompleteError::Failed { harness: name.to_owned(), detail };
        let timed_out = || CompleteError::Timeout {
            harness: name.to_owned(),
            ms: u64::try_from(req.timeout.as_millis()).unwrap_or(u64::MAX),
        };
        // The profile's env with its bound route (claude-sr, claude-cr, a route file); for a
        // chat's own call, the env its own spawn takes (`ChatRoute`).
        let env = match chat {
            Some(chat) => self.chat_completion_env(name, chat).await.map_err(failed)?,
            None => {
                let mut env = profile.env.clone();
                self.apply_route_for(name, None, None, false, profile, &mut env)
                    .await
                    .map_err(|e| failed(e.message))?;
                env
            }
        };
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
        let mut cmd = crate::agent::harness_command_ready(
            name,
            &spawn,
            &cwd,
            Some((inv.program.clone(), inv.args.clone())),
            None,
        )
        .await
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
