//! Workflow process ownership. Scripts execute in cmux's existing code-mode process;
//! the daemon owns only pinned inputs, lifecycle fences and child handles.
use super::*;
use crate::workflow_runs::{Child, RunRecord, State};
use anyhow::{Context, Result};
use std::collections::BTreeMap;
use std::process::Stdio;

impl Hub {
    pub async fn workflow_start(
        self: &Arc<Self>,
        owner: &Arc<Session>,
        name: String,
        source: String,
        args: Value,
        local_principal: bool,
    ) -> Result<RunRecord> {
        let meta = owner.meta();
        anyhow::ensure!(!meta.remote_origin, "a remote chat starts no local workflow");
        let env = self.bg_env(owner, &meta).await.map_err(|e| anyhow::anyhow!(e.message))?;
        let allowed_tools = env.get(crate::agent_tools::MCP_TOOLS_ENV).map(|v| {
            v.split(',').map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned).collect()
        });
        let id = format!("wf-{}", uuid::Uuid::now_v7().simple());
        let run = self.workflow_runs.store().start(RunRecord {
            version: 1,
            id,
            name,
            owner_session_id: owner.id.clone(),
            local_principal,
            source,
            source_hash: String::new(),
            args,
            allowed_tools,
            cwd: meta.cwd.clone(),
            generation: 1,
            state: State::Running,
            activities: BTreeMap::new(),
            outcome: None,
        })?;
        let _gate = self.workflow_runs.gate(&run.id).lock_owned().await;
        self.workflow_launch(&run).await?;
        Ok(run)
    }

    /// Current preset restrictions can narrow a pinned run, never grant it new tools.
    pub async fn workflow_allowed_tools(&self, run: &RunRecord) -> Result<Option<Vec<String>>> {
        let owner = self.resolve(&run.owner_session_id).map_err(|e| anyhow::anyhow!(e.message))?;
        let env =
            self.bg_env(&owner, &owner.meta()).await.map_err(|e| anyhow::anyhow!(e.message))?;
        let current = env.get(crate::agent_tools::MCP_TOOLS_ENV).map(|v| {
            v.split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect::<Vec<_>>()
        });
        Ok(match (&run.allowed_tools, current) {
            (None, current) => current,
            (Some(pinned), None) => Some(pinned.clone()),
            (Some(pinned), Some(current)) => {
                Some(pinned.iter().filter(|tool| current.contains(tool)).cloned().collect())
            }
        })
    }

    /// Fold only the same trusted tool-server specs this owner's next agent launch gets.
    /// These launch credentials never enter the durable run record or status response.
    async fn workflow_upstreams(&self, run: &RunRecord) -> Result<String> {
        let owner = self.resolve(&run.owner_session_id).map_err(|e| anyhow::anyhow!(e.message))?;
        let meta = owner.meta();
        let env = self.workflow_tool_env(&meta).await?;
        if crate::agent_tools::left_out(meta.remote_origin, &env, &[]) {
            return Ok("[]".into());
        }
        let config = crate::agent_tools::current()
            .scoped(&env)
            .without_off(&env)
            .for_session(&run.owner_session_id)
            .folded()
            .mcp_config();
        Ok(config
            .as_ref()
            .and_then(|config| config.pointer("/mcpServers/cmux/env/CMUX_MCP_UPSTREAMS"))
            .and_then(Value::as_str)
            .unwrap_or("[]")
            .to_owned())
    }

    async fn workflow_tool_env(&self, meta: &SessionMeta) -> Result<BTreeMap<String, String>> {
        // Tool folding reads the resolved session profile before harness_command
        // strips fold-only OFF_ENV and WORKSPACE_KEY from the agent process env.
        let (profile, defaults) = {
            let config = self.config.read().await;
            let profile = super::resolve::session_profile(
                &config,
                &meta.harness,
                &meta.cwd,
                meta.remote_origin,
            )
            .map_err(|error| anyhow::anyhow!(error))?;
            (profile, config.defaults_for(&meta.harness))
        };
        let profile = self
            .spawn_profile_for(meta, &profile, &defaults.env)
            .await
            .map_err(|error| anyhow::anyhow!(error.message))?;
        Ok(profile.env)
    }

    pub async fn workflow_resume(self: &Arc<Self>, id: &str, owner: &str) -> Result<RunRecord> {
        let _gate = self.workflow_runs.gate(id).lock_owned().await;
        let run = self.workflow_runs.store().resume(id, owner, false)?;
        self.workflow_launch(&run).await?;
        Ok(run)
    }

    pub async fn workflow_pause(self: &Arc<Self>, id: &str, owner: &str) -> Result<RunRecord> {
        let _gate = self.workflow_runs.gate(id).lock_owned().await;
        let run = self.workflow_runs.store().pause(id, owner)?;
        self.workflow_finish_pause(run).await
    }

    async fn workflow_finish_pause(self: &Arc<Self>, run: RunRecord) -> Result<RunRecord> {
        if run.state == State::Paused {
            return Ok(run);
        }
        self.workflow_runs.stop_runner(&run.id).await;
        self.workflow_cancel_children(&run).await?;
        self.workflow_runs.store().paused(&run.id, run.generation)
    }

    pub async fn workflow_cancel_children(self: &Arc<Self>, run: &RunRecord) -> Result<()> {
        let mut errors = Vec::new();
        for activity in run.activities.values().filter(|a| a.outcome.is_none()) {
            let result: Result<()> = async {
                match &activity.child {
                    Child::Agent { session_id, prompt_id, host } => {
                        anyhow::ensure!(
                            host.as_deref().is_none_or(|host| host == "local"),
                            "remote workflow agent cancellation is not supported on this route"
                        );
                        let session = match self.resolve(session_id) {
                            Ok(session) => session,
                            Err(error) if error.code == RpcError::not_found("").code => {
                                return Ok(());
                            }
                            Err(error) => return Err(anyhow::anyhow!(error.message)),
                        };
                        self.remove_queued(&session, prompt_id);
                        self.cancel_prompt(&session, prompt_id)
                            .await
                            .map_err(|e| anyhow::anyhow!(e.message))?;
                    }
                    Child::Machine { session_id, task_id, host } => {
                        anyhow::ensure!(
                            host.as_deref().is_none_or(|host| host == "local"),
                            "remote workflow machine cancellation is not supported on this route"
                        );
                        let session = match self.resolve(session_id) {
                            Ok(session) => session,
                            Err(error) if error.code == RpcError::not_found("").code => {
                                return Ok(());
                            }
                            Err(error) => return Err(anyhow::anyhow!(error.message)),
                        };
                        self.bg_stop(&session, task_id)
                            .await
                            .map_err(|e| anyhow::anyhow!(e.message))?;
                    }
                }
                Ok(())
            }
            .await;
            if let Err(error) = result {
                errors.push(format!("{}: {error}", activity.id));
            }
        }
        anyhow::ensure!(
            errors.is_empty(),
            "workflow child cleanup incomplete: {}",
            errors.join("; ")
        );
        Ok(())
    }

    /// One pass after adoption; no polling task and no credentials survive a daemon restart.
    pub async fn recover_workflows(self: &Arc<Self>) {
        let records = match self.workflow_runs.store().list() {
            Ok(records) => records,
            Err(error) => {
                tracing::warn!(%error, "read workflow recovery records");
                return;
            }
        };
        for run in records {
            let _gate = self.workflow_runs.gate(&run.id).lock_owned().await;
            // Requests may have changed this run while recovery waited for its gate.
            // Never restart a pause or stop a new generation from the listed snapshot.
            let current = match self.workflow_runs.store().get(&run.id) {
                Ok(current)
                    if current.generation == run.generation && current.state == run.state =>
                {
                    current
                }
                Ok(_) => continue,
                Err(error) => {
                    tracing::warn!(%error,"reload workflow recovery record");
                    continue;
                }
            };
            let run = current;
            let result = match run.state {
                State::Pausing => self.workflow_finish_pause(run).await.map(|_| ()),
                State::Running => {
                    match self.workflow_runs.store().resume(&run.id, &run.owner_session_id, true) {
                        Ok(run) => self.workflow_launch(&run).await,
                        Err(error) => Err(error),
                    }
                }
                State::Failed => self.workflow_cancel_children(&run).await,
                _ => Ok(()),
            };
            if let Err(error) = result {
                tracing::warn!(%error, "recover native workflow");
            }
        }
    }

    async fn workflow_launch(self: &Arc<Self>, run: &RunRecord) -> Result<()> {
        match self.workflow_spawn(run).await {
            Ok(()) => Ok(()),
            Err(error) => {
                self.workflow_runs.retire_runner(&run.id, run.generation);
                if let Ok(failed) = self.workflow_runs.store().settle(
                    &run.id,
                    run.generation,
                    &run.owner_session_id,
                    Err(json!({"message": error.to_string()})),
                ) && let Err(cleanup_error) = self.workflow_cancel_children(&failed).await
                {
                    tracing::warn!(run_id = %run.id, %cleanup_error, "cancel unlaunchable workflow children");
                }
                Err(error)
            }
        }
    }

    async fn workflow_spawn(self: &Arc<Self>, run: &RunRecord) -> Result<()> {
        let mut command = workflow_runner_command()?;
        let Some(token) = self.workflow_runs.issue_runner(run)? else {
            return Ok(());
        };
        command.args([
            "workflow",
            "__run",
            "--run-id",
            &run.id,
            "--generation",
            &run.generation.to_string(),
        ]);
        command.env_clear();
        for key in ["PATH", "HOME", "USER", "TMPDIR", "XDG_RUNTIME_DIR", "ACPMUX_HOME"] {
            if let Some(value) = std::env::var_os(key) {
                command.env(key, value);
            }
        }
        command.envs(super::person::caller_env(&run.owner_session_id));
        command.env("ACPMUX_SESSION_ID", &run.owner_session_id);
        command.env(crate::agent_tools::AGENT_SESSION_ENV, &run.owner_session_id);
        command.env(crate::workflow_runs::RUNNER_TOKEN_ENV, token);
        command.env(crate::agent_tools::UPSTREAMS_ENV, self.workflow_upstreams(run).await?);
        if let Some(tools) = self.workflow_allowed_tools(run).await? {
            command.env(crate::agent_tools::MCP_TOOLS_ENV, tools.join(","));
        }
        command
            .current_dir(&run.cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        command.kill_on_drop(true);
        #[cfg(unix)]
        command.process_group(0);
        let mut child = command.spawn().context("start native workflow runner")?;
        let (mut stop, finished) = self.workflow_runs.track_runner(&run.id, run.generation);
        let hub = self.clone();
        let run = run.clone();
        tokio::spawn(async move {
            let result = tokio::select! {
                result = child.wait() => Some(result),
                _ = &mut stop => { let _ = child.kill().await; None }
            };
            let _ = finished.send(());
            let _gate = hub.workflow_runs.gate(&run.id).lock_owned().await;
            if let Some(result) = result {
                // A successful script settles explicitly. An unacknowledged exit never
                // leaves an apparently running workflow with no owner process.
                if hub
                    .workflow_runs
                    .store()
                    .authorize(&run.id, run.generation, &run.owner_session_id)
                    .is_ok()
                {
                    let message = match result {
                        Ok(status) => format!("workflow runner exited before settling ({status})"),
                        Err(error) => format!("workflow runner wait failed: {error}"),
                    };
                    if let Ok(failed) = hub.workflow_runs.store().settle(
                        &run.id,
                        run.generation,
                        &run.owner_session_id,
                        Err(json!({"message": message})),
                    ) && let Err(error) = hub.workflow_cancel_children(&failed).await
                    {
                        tracing::warn!(run_id = %run.id, %error, "cancel failed workflow children");
                    }
                }
            }
            hub.workflow_runs.retire_runner(&run.id, run.generation);
        });
        Ok(())
    }
}

fn workflow_runner_command() -> Result<tokio::process::Command> {
    let own = crate::self_command::SelfCommand::current()?;
    if !own.prefix.is_empty() {
        let mut command = tokio::process::Command::new(own.program());
        #[cfg(unix)]
        command.arg0("cmux");
        return Ok(command);
    }
    // Standalone acpmux is not cmux. Resolve only a sibling installed product binary,
    // never a configurable executable or a shell command supplied by the script.
    let parent = own.exe.parent().context("acpmux executable has no parent")?;
    for name in ["cmux", "cmux-tui"] {
        let path = parent.join(name);
        if path.is_file() {
            return Ok(tokio::process::Command::new(path));
        }
    }
    anyhow::bail!("native workflows require the cmux executable beside acpmux")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn workflow_tool_fold_keeps_disabled_servers_and_workspace_scope() {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        cfg.harnesses.insert(
            "workflow-fold-test".into(),
            serde_json::from_value(json!({
                "argv":["/bin/true"], "kind":"claude-stdio"
            }))
            .unwrap(),
        );
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema":crate::store::META_SCHEMA,"id":"workflow-fold-test","name":"Workflow fold",
            "harness":"workflow-fold-test","cwd":std::env::temp_dir(),"status":"idle",
            "createdAt":1,"updatedAt":1,"workspaceId":"workflow-workspace",
            "tools":{"off":["mcp:disabled-server"]}
        }))
        .unwrap();
        let env = hub.workflow_tool_env(&meta).await.unwrap();
        assert_eq!(
            env.get(crate::agent_tools::OFF_ENV).map(String::as_str),
            Some("disabled-server")
        );
        assert_eq!(
            env.get(crate::agent_displays::WORKSPACE_KEY).map(String::as_str),
            Some("workflow-workspace")
        );
    }

    #[tokio::test]
    async fn cancelling_a_stale_activity_never_fences_another_prompt() {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema":crate::store::META_SCHEMA,"id":"workflow-child","name":"Workflow child",
            "harness":"fake","cwd":std::env::temp_dir(),"status":"idle","createdAt":1,"updatedAt":1
        }))
        .unwrap();
        store.save(&meta).unwrap();
        let hub = Hub::new(cfg, store);
        let session = hub.resolve("workflow-child").unwrap();
        *session.turn.lock().unwrap() = Some(TurnInfo {
            trigger: false,
            started_at: 1,
            client: "person".into(),
            prompt_preview: String::new(),
            masked_preview: String::new(),
            turn_id: "person-turn".into(),
            prompt_id: "person-prompt".into(),
            turn_seq: 1,
            control: Control::Local,
            doing: Default::default(),
            notice: false,
            persons: true,
        });
        let before = session.cancels.load(Ordering::SeqCst);
        // The activity ended before pause arrived; it must not change even the
        // session-wide cancellation generation that a later prompt will observe.
        hub.cancel_prompt(&session, "already-ended-workflow-prompt").await.unwrap();
        assert_eq!(session.cancels.load(Ordering::SeqCst), before);
        assert_eq!(session.turn().unwrap().prompt_id, "person-prompt");
    }
}
