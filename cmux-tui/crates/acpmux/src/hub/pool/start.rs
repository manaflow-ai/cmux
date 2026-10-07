//! Owns pooled host startup, initialization, and discard lifecycle.

use super::*;

impl Hub {
    /// Start one hidden session for `spec` under a fresh reserved id: its
    /// host in the pool directory, `initialize`, then the harness session.
    pub(super) async fn spawn_pooled(&self, spec: &PoolSpec) -> anyhow::Result<Pooled> {
        let session_id = uuid::Uuid::now_v7().to_string();
        let draft = &spec.draft;
        let name = self.unique_name(&draft.harness);
        let profile = &spec.spawn;
        let claude = profile.kind == crate::config::HarnessKind::ClaudeStdio;
        let (command_line, translator) = if claude {
            // As `ensure_child` starts a fresh Claude session.
            let fresh_id = uuid::Uuid::now_v7().to_string();
            let effort = current_option(draft, "effort").unwrap_or_else(|| "default".into());
            let mode = "default".to_owned();
            let model = current_model(draft).unwrap_or_else(|| "default".into());
            let plan = crate::claude_stdio::spawn_plan(
                profile,
                None,
                false,
                Some(&fresh_id),
                Some(&effort),
                &mode,
                Some(&model),
            );
            (
                Some((plan.program, plan.args)),
                Some(agent_host::TranslatorSpec {
                    acp_session_id: session_id.clone(),
                    mode,
                    model,
                    effort,
                    claude_session_id: Some(fresh_id),
                }),
            )
        } else {
            (None, None)
        };
        let cmd = crate::agent::harness_command(
            &draft.harness,
            profile,
            &draft.cwd,
            command_line,
            Some((&session_id, &name)),
        )?;
        let std_cmd = cmd.as_std();
        let dir = pool_dir();
        let host_spec = agent_host::SpawnSpec {
            session_id: session_id.clone(),
            program: std_cmd.get_program().to_string_lossy().into_owned(),
            args: std_cmd.get_args().map(|a| a.to_string_lossy().into_owned()).collect(),
            env: crate::agent::command_env(&cmd),
            cwd: draft.cwd.clone(),
            translator,
            socket: agent_host::socket_path(&dir, &session_id),
            hosts_dir: dir,
            buffer_cap: agent_host::DEFAULT_BUFFER_CAP,
        };
        // No host starts once `stop_pool` began: it could not end it.
        if self.pool.stopping.load(Ordering::SeqCst) {
            anyhow::bail!("the daemon is stopping");
        }
        let launcher = agent_host::link::HostLauncher::current()?;
        let record = agent_host::link::spawn(&launcher, &host_spec).await?;
        lock(&self.pool.starting).insert(session_id.clone(), record.clone());
        let started =
            self.start_pooled(session_id.clone(), name, record.clone(), spec, claude).await;
        if started.is_err() {
            lock(&self.pool.starting).remove(&session_id);
        }
        started
    }

    /// The rest of `spawn_pooled` once its host runs: attach, `initialize`,
    /// the harness session, all within `START_BUDGET`. On failure the host
    /// is ended.
    async fn start_pooled(
        &self,
        session_id: String,
        name: String,
        record: HostRecord,
        spec: &PoolSpec,
        claude: bool,
    ) -> anyhow::Result<Pooled> {
        let draft = &spec.draft;
        if self.pool.stopping.load(Ordering::SeqCst) {
            end_pooled_host(&record).await;
            anyhow::bail!("the daemon is stopping");
        }
        let (tap, slot) = holding_tap();
        let (inbound, target) = holding_inbound();
        let attach =
            ChildAgent::attach_hosted(&draft.harness, record.clone(), 0, Vec::new(), inbound, tap);
        let attached = tokio::time::timeout(START_BUDGET, attach)
            .await
            .unwrap_or_else(|_| Err(anyhow::anyhow!("no host link within {START_BUDGET:?}")));
        let child = match attached {
            Ok(Attached::Ready(child, _, _)) => child,
            Ok(Attached::Incompatible { .. }) => {
                end_pooled_host(&record).await;
                anyhow::bail!("a host of this build refused its controller")
            }
            Err(e) => {
                end_pooled_host(&record).await;
                return Err(e);
            }
        };
        let started = async {
            let init = child.request(method::INITIALIZE, initialize_params()).await?;
            let new_result = if claude {
                None
            } else {
                Some(
                    child
                        .request(method::SESSION_NEW, self.acp_params(draft, &spec.spawn, None))
                        .await?,
                )
            };
            Ok::<_, RpcError>((init, new_result))
        };
        let (init, new_result) = match tokio::time::timeout(START_BUDGET, started).await {
            Ok(Ok(v)) => v,
            failed => {
                let _ = tokio::time::timeout(END_GRACE, child.terminate(END_GRACE)).await;
                end_pooled_host(&record).await;
                match failed {
                    Ok(Err(e)) => anyhow::bail!("{}", e.message),
                    _ => anyhow::bail!("no harness session within {START_BUDGET:?}"),
                }
            }
        };
        Ok(Pooled {
            session_id,
            name,
            key: spec.key.clone(),
            child,
            record,
            claude,
            init,
            new_result,
            tap: slot,
            target: Some(target),
            rss: 0,
            parked: false,
        })
    }

    /// End entries nobody will take (in the background).
    pub(super) fn pool_discard(&self, entries: Vec<Pooled>) {
        // Also called from a drop (`ClaimGuard`): without a runtime the
        // next daemon's sweep ends the host.
        let Ok(rt) = tokio::runtime::Handle::try_current() else { return };
        for p in entries {
            rt.spawn(end_pooled(p));
        }
    }
}
