//! Owns pooled host startup, initialization, and discard lifecycle.

use super::*;

impl Pooled {
    /// Whether this agent, started from `argv`, runs in full access (`runs_full_access`): its
    /// argv, the mode and config options its harness session came up in, and what it reported
    /// for that session since it started (`StartReports`), held until a chat takes it
    /// (`held.rs`; reviews 32 and 46 of #23322).
    pub(super) fn runs_full_access(&self, argv: &[String]) -> bool {
        use crate::hub::full_access_bound::{FullAccessView, runs_full_access};
        let new = self.new_result.as_ref();
        let mut view = FullAccessView::of_session_new(argv, new);
        if let TapSlot::Held(held) = &*self.tap.lock().unwrap_or_else(|e| e.into_inner()) {
            view.reported = held_reports_full_access(held, new);
        }
        runs_full_access(&view).is_some()
    }
}

/// Whether the lines `held` for a pooled agent whose harness answered `session/new` with `new`
/// report full access for its session (`StartReports`).
pub(in crate::hub) fn held_reports_full_access(
    held: &[(Direction, Message, Option<u64>)],
    new: Option<&Value>,
) -> bool {
    let mut reports = crate::hub::full_access_bound::StartReports::default();
    for (dir, msg, _) in held {
        if let (Direction::In, Message::Notification { method: m, params: Some(p) }) = (dir, msg)
            && m == crate::rpc::method::SESSION_UPDATE
        {
            reports.note(p);
        }
    }
    reports.of_answer(new)
}

impl Hub {
    /// Start one hidden session for `spec` under a fresh reserved id: its
    /// host in the pool directory, `initialize`, then the harness session.
    /// `off`: MDM's off as the pooled start began (`pool_want`), the start's one read of it.
    pub(super) async fn spawn_pooled(
        self: &Arc<Self>,
        spec: &PoolSpec,
        off: &crate::hub::full_access_bound::OffLatch,
    ) -> anyhow::Result<Pooled> {
        let session_id = uuid::Uuid::now_v7().to_string();
        let draft = &spec.draft;
        let name = self.unique_name(&draft.harness);
        let profile = &spec.spawn;
        // MDM forces full access off (#23322): a profile pinning it is never prewarmed.
        if self.refuse_pinned_full_access(off, profile).is_err() {
            anyhow::bail!("{} pins full access, which MDM forces off", draft.harness);
        }
        #[cfg(debug_assertions)]
        self.off_blip_seam();
        let claude = profile.kind == crate::config::HarnessKind::ClaudeStdio;
        let (command_line, translator) = if claude {
            // As `ensure_child` starts a fresh Claude session.
            let fresh_id = uuid::Uuid::now_v7().to_string();
            let effort = current_effort(draft).unwrap_or_else(|| "default".into());
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
                    fast: current_option(draft, "fast-mode").as_deref() == Some("on"),
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
        let preview = crate::agent::pinned_preview_format(&cmd);
        let std_cmd = cmd.as_std();
        let dir = pool_dir();
        let host_spec = agent_host::SpawnSpec {
            session_id: session_id.clone(),
            program: std_cmd.get_program().to_string_lossy().into_owned(),
            args: std_cmd.get_args().map(|a| a.to_string_lossy().into_owned()).collect(),
            env: if draft.remote_origin {
                crate::agent::command_env_cleared(&cmd)
            } else {
                crate::agent::command_env(&cmd)
            },
            cwd: draft.cwd.clone(),
            codex_bridge: !claude && crate::codex_app_server::is_profile_launch(&profile.argv),
            translator,
            socket: agent_host::socket_path(&dir, &session_id),
            hosts_dir: dir,
            buffer_cap: agent_host::DEFAULT_BUFFER_CAP,
            router_owner_fifo: crate::daemon::router_owner_path(),
            // Never a sub-session's checked folder: a sub-session start takes no pooled harness.
            cwd_pin: None,
        };
        // No host starts once `stop_pool` began: it could not end it.
        if self.pool.stopping.load(Ordering::SeqCst) {
            anyhow::bail!("the daemon is stopping");
        }
        let launcher = agent_host::link::HostLauncher::current()?;
        // Its MCP configs are read before it starts, never after (`hub/idle_census.rs`).
        let launch = crate::agent::Launch::new(
            &host_spec.program,
            &host_spec.args,
            &host_spec.env,
            &host_spec.cwd,
        );
        let servers =
            crate::hub::LaunchServers::read(&launch, spec.draft.family.clone().unwrap_or_default())
                .await;
        let record = agent_host::program_wait::spawn(&launcher, &host_spec).await?;
        lock(&self.pool.starting).insert(session_id.clone(), record.clone());
        let started =
            self.start_pooled(session_id.clone(), name, record.clone(), spec, claude, off).await;
        let started = started.map(|p| {
            p.child.record_launch(servers);
            Pooled { preview, ..p }
        });
        if started.is_err() {
            lock(&self.pool.starting).remove(&session_id);
        }
        started
    }

    /// The rest of `spawn_pooled` once its host runs: attach, `initialize`,
    /// the harness session, all within `START_BUDGET`. On failure the host
    /// is ended.
    async fn start_pooled(
        self: &Arc<Self>,
        session_id: String,
        name: String,
        record: HostRecord,
        spec: &PoolSpec,
        claude: bool,
        latch: &crate::hub::full_access_bound::OffLatch,
    ) -> anyhow::Result<Pooled> {
        let draft = &spec.draft;
        if self.pool.stopping.load(Ordering::SeqCst) {
            end_pooled_host(&record).await;
            anyhow::bail!("the daemon is stopping");
        }
        // MDM's off as this start began (`latch`, reviews 71, 73 and 77 of #23322): a report of
        // full access while it starts ends it then, an unset after the off too, not at its answer.
        let reported = Arc::new(tokio::sync::Notify::new());
        let reported_off = Arc::new(AtomicBool::new(false));
        let (hub, notify, flag) = (Arc::downgrade(self), reported.clone(), reported_off.clone());
        let id = session_id.clone();
        let (tap, slot) = holding_tap(move || {
            notify.notify_one();
            if let Some(hub) = hub.upgrade() {
                hub.pool_reported(&id, &flag);
            }
        });
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
                        .request(
                            method::SESSION_NEW,
                            self.acp_params(&session_id, draft, &spec.spawn, None, &child),
                        )
                        .await?,
                )
            };
            Ok::<_, RpcError>((init, new_result))
        };
        let held = slot.clone();
        let held_full = move || {
            let slot = held.lock().unwrap_or_else(|e| e.into_inner());
            matches!(&*slot, TapSlot::Held(h) if held_reports_full_access(h, None))
        };
        let outcome = tokio::time::timeout(START_BUDGET, async {
            tokio::select! {
                started = started => started.map_err(|e| anyhow::anyhow!("{}", e.message)),
                () = latch.reported_under_off(&reported, held_full) => {
                    Err(anyhow::anyhow!("its harness reported full access, which MDM forces off"))
                }
            }
        })
        .await
        .unwrap_or_else(|_| Err(anyhow::anyhow!("no harness session within {START_BUDGET:?}")));
        let (init, new_result) = match outcome {
            Ok(v) => v,
            Err(e) => {
                let _ = tokio::time::timeout(END_GRACE, child.terminate(END_GRACE)).await;
                end_pooled_host(&record).await;
                return Err(e);
            }
        };
        let p = Pooled {
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
            opencode_asks: spec.spawn.env.contains_key(crate::opencode_ask::MARKER),
            preview: Default::default(),
            reported_off,
            started: latch.clone(),
            claimed_under: None,
        };
        // An off this start began under, or that began while it ran, holds though an unset
        // followed (review 73): an agent that came up in full access then is not kept.
        if latch.off() && p.runs_full_access(&spec.spawn.argv) {
            end_pooled(p).await;
            anyhow::bail!("it came up in full access, which MDM forces off");
        }
        Ok(p)
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
