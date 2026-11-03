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
        for activity in run.activities.values().filter(|a| a.outcome.is_none()) {
            match &activity.child {
                Child::Agent { session_id, prompt_id, host } => {
                    anyhow::ensure!(
                        host.as_deref().is_none_or(|host| host == "local"),
                        "remote workflow agent cancellation is not supported on this route"
                    );
                    let session = match self.resolve(session_id) {
                        Ok(session) => session,
                        Err(error) if error.code == RpcError::not_found("").code => continue,
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
                        Err(error) if error.code == RpcError::not_found("").code => continue,
                        Err(error) => return Err(anyhow::anyhow!(error.message)),
                    };
                    self.bg_stop(&session, task_id)
                        .await
                        .map_err(|e| anyhow::anyhow!(e.message))?;
                }
            }
        }
        self.workflow_runs.store().paused(&run.id, run.generation)
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
            let result = match run.state {
                State::Pausing => self.workflow_finish_pause(run).await.map(|_| ()),
                State::Running => {
                    match self.workflow_runs.store().resume(&run.id, &run.owner_session_id, true) {
                        Ok(run) => self.workflow_launch(&run).await,
                        Err(error) => Err(error),
                    }
                }
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
                let _ = self.workflow_runs.store().settle(
                    &run.id,
                    run.generation,
                    &run.owner_session_id,
                    Err(json!({"message": error.to_string()})),
                );
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
                    let _ = hub.workflow_runs.store().settle(
                        &run.id,
                        run.generation,
                        &run.owner_session_id,
                        Err(json!({"message": message})),
                    );
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
    async fn cancelling_a_stale_activity_never_fences_another_prompt() {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let session = hub
            .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
            .await
            .unwrap();
        let before = session.cancels.load(Ordering::SeqCst);
        // The activity ended before pause arrived; it must not change even the
        // session-wide cancellation generation that a later prompt will observe.
        hub.cancel_prompt(&session, "already-ended-workflow-prompt").await.unwrap();
        assert_eq!(session.cancels.load(Ordering::SeqCst), before);
    }
}
