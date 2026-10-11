//! Terminal adoption at startup: restored terminal bindings, adopting live
//! terminal hosts, template terminals, and scheduling adoption work.

use super::*;

impl Mux {
    #[cfg(unix)]
    pub(super) fn restored_terminal_binding(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<RestoredTerminalBinding>> {
        let registry = self.workspace_registry.lock().unwrap();
        let Some(public_id) = registry.terminal_resource_id(terminal_id)? else {
            return detached_terminals::detached_adoption_binding(&registry, terminal_id);
        };
        drop(registry);
        let state = self.state.lock().unwrap();
        let content_id = ContentPublicId::Terminal(public_id.clone());
        let placements = state
            .placements_of_content(&content_id)
            .iter()
            .map(|slot| {
                let tab_id =
                    state.resource_indexes.tab_ids.get(slot).cloned().with_context(|| {
                        format!("restored terminal placement {slot} has no tab identity")
                    })?;
                Ok((*slot, TabResourceIdentity::new(tab_id, content_id.clone())))
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        Ok(Some(RestoredTerminalBinding { public_id, placements }))
    }

    #[cfg(unix)]
    pub(super) fn adopt_restored_terminal(
        self: &Arc<Self>,
        binding: Option<RestoredTerminalBinding>,
        options: &SurfaceOptions,
        record: &crate::terminal_host_runtime::TerminalHostRecord,
        record_path: &Path,
    ) -> anyhow::Result<Arc<Surface>> {
        let id = binding
            .as_ref()
            .and_then(|binding| binding.placements.first().map(|(slot, _)| *slot))
            .unwrap_or_else(|| self.next_id());
        match binding {
            Some(binding) if !binding.placements.is_empty() => {
                let (_, identity) = binding.placements.first().expect("checked placement");
                Surface::adopt_hosted_with_resource_identity(
                    id,
                    options.clone(),
                    Arc::downgrade(self),
                    record.clone(),
                    record_path.to_path_buf(),
                    identity.clone(),
                )
            }
            Some(binding) => Surface::adopt_hosted_with_terminal_public_id(
                id,
                options.clone(),
                Arc::downgrade(self),
                record.clone(),
                record_path.to_path_buf(),
                binding.public_id,
            ),
            None => Surface::adopt_hosted(
                id,
                options.clone(),
                Arc::downgrade(self),
                record.clone(),
                record_path.to_path_buf(),
            ),
        }
    }

    #[cfg(unix)]
    pub(super) fn adopt_terminal_hosts(self: &Arc<Self>) -> anyhow::Result<()> {
        let options = self.surface_options.lock().unwrap().clone();
        let exit_records = match options.terminal_host_root.as_deref() {
            Some(root) => crate::terminal_host_runtime::load_terminal_host_exit_records(root)?,
            None => Vec::new(),
        };
        if let Some(root) = options.terminal_host_root.as_deref() {
            crate::terminal_host_runtime::sweep_released_pty_locks(root);
        }
        let records = match options.terminal_host_root.as_deref() {
            Some(root) => crate::terminal_host_runtime::load_terminal_host_records(root)?,
            None => Vec::new(),
        };
        let mut handled_terminals = HashSet::new();
        // At most one warm snapshot host becomes the first terminal of a
        // fresh registry (SurfaceOptions::adopt_template_terminal).
        let mut template_claimed = false;
        let mut recovery_workspace = None;
        // Sidecars are host-owned write-ahead completion records. Reconcile
        // them before live discovery records so a daemon crash after host
        // completion cannot collapse the exact status into "host missing".
        for (exit_path, record) in exit_records {
            let Some(terminal) =
                self.workspace_registry.lock().unwrap().terminal_record(&record.terminal_id)?
            else {
                continue;
            };
            if terminal.lifecycle == TerminalLifecycle::Tombstoned {
                let _ = crate::terminal_host_runtime::acknowledge_terminal_host_exit_record(
                    &exit_path, &record,
                )?;
                handled_terminals.insert(record.terminal_id);
                continue;
            }
            if terminal
                .incarnation
                .as_deref()
                .is_some_and(|incarnation| incarnation != record.incarnation)
            {
                // Retain evidence from the non-current incarnation. It must
                // never be allowed to terminate a replacement process.
                continue;
            }
            // The host's durable sidecar records the child's end (an
            // owner-gone end is a host loss: the tabs stay, invariant 3).
            self.persist_terminal_exit(
                &record.terminal_id,
                Some(&record.incarnation),
                &TerminalEnd::from_host_exit(record.exit.clone()),
            )?;
            self.detach_exited_terminal_topology(&record.terminal_id)?;
            let _ = crate::terminal_host_runtime::acknowledge_terminal_host_exit_record(
                &exit_path, &record,
            )?;
            handled_terminals.insert(record.terminal_id);
        }
        for (record_path, record) in records {
            let terminal_id = record.terminal_id.clone();
            if handled_terminals.contains(&terminal_id) {
                if !cleanup_terminal_host_record(&record, &record_path) {
                    self.schedule_terminal_adoption(options.clone(), record, record_path);
                }
                continue;
            }
            let mut terminal =
                self.workspace_registry.lock().unwrap().terminal_record(&terminal_id)?;
            if terminal.is_none()
                && !template_claimed
                && options.adopt_template_terminal
                && detached_terminals::names_a_workspace(&record.workspace_key)
                && self.state.lock().unwrap().workspaces.is_empty()
                && terminal_host_record_liveness(&record_path, &record)
                    == TerminalHostLiveness::Live
            {
                terminal = Some(self.claim_template_terminal(&options, &record)?);
                template_claimed = true;
            }
            if terminal.is_none() {
                // One-release migration path for hosts launched before SQLite
                // became placement authority. Never trust the JSON hint when
                // its workspace no longer exists.
                let workspace_exists = !record.workspace_key.is_empty()
                    && self.state.lock().unwrap().workspace_by_key(&record.workspace_key).is_some();
                if workspace_exists {
                    let imported = RegistryTerminal {
                        terminal_id: terminal_id.clone(),
                        workspace_key: record.workspace_key.clone(),
                        incarnation: None,
                        lifecycle: TerminalLifecycle::Launching,
                        launch_spec: serde_json::json!({"legacy_import":true}),
                        exit: None,
                        on_exit: TerminalOnExit::Close,
                    };
                    let mut registry = self.workspace_registry.lock().unwrap();
                    let revision = commit_terminal_transition(
                        &mut registry,
                        "terminal-imported",
                        "import-legacy-terminal",
                        &imported,
                    )?;
                    self.emit_terminal_registry_changed(&registry, revision);
                    terminal = Some(imported);
                } else if orphan_hosts::recoverable(&options, &record_path, &record) {
                    match self.recover_orphan_terminal(&record, &mut recovery_workspace) {
                        Ok(recovered) => terminal = Some(recovered),
                        Err(error) => {
                            // The host and its record stay for a later start.
                            eprintln!("cmux-tui: terminal {terminal_id} not recovered: {error:#}");
                            continue;
                        }
                    }
                } else {
                    if !cleanup_terminal_host_record(&record, &record_path) {
                        self.schedule_terminal_adoption(options.clone(), record, record_path);
                    }
                    continue;
                }
            }
            let terminal = terminal.expect("terminal imported or loaded");
            if terminal.lifecycle == TerminalLifecycle::Tombstoned {
                if !cleanup_terminal_host_record(&record, &record_path) {
                    self.schedule_terminal_adoption(options.clone(), record, record_path);
                }
                continue;
            }
            if terminal.lifecycle == TerminalLifecycle::Exited {
                self.detach_exited_terminal_topology(&terminal.terminal_id)?;
                handled_terminals.insert(terminal_id.clone());
                if !cleanup_terminal_host_record(&record, &record_path) {
                    self.schedule_terminal_adoption(options.clone(), record, record_path);
                }
                continue;
            }
            if terminal.incarnation.as_deref().is_some_and(|value| value != record.incarnation) {
                self.mark_terminal_ended(
                    &terminal_id,
                    "terminal-incarnation-mismatch",
                    "host-incarnation-mismatch",
                    &options,
                )?;
                handled_terminals.insert(terminal_id.clone());
                if !cleanup_terminal_host_record(&record, &record_path) {
                    self.schedule_terminal_adoption(options.clone(), record, record_path);
                }
                continue;
            }
            if let Err(error) = self.transition_terminal_lifecycle(
                "terminal-adopting",
                "adopt-terminal",
                &terminal_id,
                TerminalLifecycle::Adopting,
                Some(&record.incarnation),
            ) {
                let current =
                    self.workspace_registry.lock().unwrap().terminal_record(&terminal_id)?;
                if current.as_ref().is_some_and(|terminal| {
                    matches!(
                        terminal.lifecycle,
                        TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned
                    )
                }) {
                    if current
                        .as_ref()
                        .is_some_and(|terminal| terminal.lifecycle == TerminalLifecycle::Exited)
                    {
                        self.detach_exited_terminal_topology(&terminal_id)?;
                    }
                    handled_terminals.insert(terminal_id.clone());
                    if !cleanup_terminal_host_record(&record, &record_path) {
                        self.schedule_terminal_adoption(options.clone(), record, record_path);
                    }
                    continue;
                }
                return Err(error);
            }
            if terminal_host_record_liveness(&record_path, &record) == TerminalHostLiveness::Dead {
                // Commit the durable exit before deleting the record. The
                // record is the only proof that this host ever existed, so a
                // failed commit must leave the next startup able to retry
                // instead of facing a lifecycle row with no evidence.
                self.mark_terminal_ended(
                    &terminal_id,
                    "terminal-host-proven-dead",
                    "host-process-ended-before-adoption",
                    &options,
                )?;
                let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                    &record_path,
                    &record,
                );
                handled_terminals.insert(terminal_id.clone());
                continue;
            }
            let restored_binding = self.restored_terminal_binding(&terminal_id)?;
            // Bound startup head-of-line blocking per host. One handshake is
            // enough for healthy hosts; live or indeterminate failures
            // continue on the asynchronous adoption loop instead of retrying
            // serially ahead of every later terminal.
            let adopted = self
                .adopt_restored_terminal(restored_binding, &options, &record, &record_path)
                .ok();
            let surface = match adopted {
                Some(surface) => surface,
                None => {
                    if terminal_host_record_liveness(&record_path, &record)
                        == TerminalHostLiveness::Dead
                    {
                        self.mark_terminal_ended(
                            &terminal_id,
                            "terminal-host-proven-dead",
                            "host-process-ended-before-adoption",
                            &options,
                        )?;
                        let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                            &record_path,
                            &record,
                        );
                        handled_terminals.insert(terminal_id.clone());
                    } else {
                        // Socket loss and descriptor pressure are not process
                        // death proof. Keep the capability and retry the same
                        // host rather than spawning a replacement shell. The
                        // tab has no surface meanwhile; it is adopting, not
                        // dead (R41).
                        handled_terminals.insert(terminal_id.clone());
                        self.set_pending_terminal(&terminal_id, PendingTerminal::Adopting);
                        self.schedule_terminal_adoption(options.clone(), record, record_path);
                    }
                    continue;
                }
            };
            if self
                .finish_terminal_adoption(&terminal_id, &record.incarnation, surface.clone())
                .is_err()
            {
                let host_is_dead = surface.is_dead()
                    || terminal_host_record_liveness(&record_path, &record)
                        == TerminalHostLiveness::Dead;
                surface.disconnect_for_daemon_shutdown();
                handled_terminals.insert(terminal_id.clone());
                if host_is_dead {
                    self.mark_terminal_ended(
                        &terminal_id,
                        "terminal-adoption-failed",
                        "host-exited-during-adoption",
                        &options,
                    )?;
                    let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                        &record_path,
                        &record,
                    );
                } else {
                    self.set_pending_terminal(&terminal_id, PendingTerminal::Adopting);
                    self.schedule_terminal_adoption(options.clone(), record, record_path);
                }
                continue;
            }
            self.ensure_template_adoption_completed(&terminal_id);
            handled_terminals.insert(terminal_id);
            self.reap_if_dead(&surface);
        }

        self.mark_unadoptable_terminal_hosts(&options, &mut handled_terminals)?;

        // No launcher survives a daemon restart. A durable lifecycle row
        // without a host-owned record therefore represents a closed crash
        // window, not permission to spawn a replacement shell.
        let snapshot = self.workspace_registry.lock().unwrap().terminal_snapshot()?;
        for terminal in snapshot.terminals {
            if terminal.lifecycle == TerminalLifecycle::Tombstoned
                || handled_terminals.contains(&terminal.terminal_id)
            {
                continue;
            }
            if terminal.lifecycle == TerminalLifecycle::Exited {
                self.detach_exited_terminal_topology(&terminal.terminal_id)?;
                self.record_terminal_end(&terminal.terminal_id);
                continue;
            }
            self.mark_terminal_ended(
                &terminal.terminal_id,
                "terminal-record-missing",
                "missing-host-record",
                &options,
            )?;
        }
        Ok(())
    }

    /// Complete an adopted template terminal (complete_template_adoption),
    /// retrying in the background until it succeeds or the daemon shuts down.
    /// Adoption itself has already committed, so a failure here must neither
    /// abort startup nor leave the terminal without its public placement and
    /// binding.
    #[cfg(unix)]
    pub(super) fn ensure_template_adoption_completed(self: &Arc<Self>, terminal_id: &str) {
        let Err(error) = self.complete_template_adoption(terminal_id) else {
            return;
        };
        eprintln!("cmux-tui: template terminal {terminal_id} not published yet: {error:#}");
        let mux = Arc::clone(self);
        let terminal_id = terminal_id.to_string();
        let spawned = std::thread::Builder::new()
            .name(format!("template-complete-{terminal_id}"))
            .spawn(move || {
                let mut delay = Duration::from_millis(100);
                loop {
                    std::thread::sleep(delay);
                    if mux.shutting_down.load(Ordering::Acquire) {
                        break;
                    }
                    match mux.complete_template_adoption(&terminal_id) {
                        Ok(()) => break,
                        Err(error) => {
                            eprintln!(
                                "cmux-tui: template terminal {terminal_id} not published yet: \
                                 {error:#}"
                            );
                            delay = (delay * 2).min(Duration::from_secs(5));
                        }
                    }
                }
            });
        if let Err(error) = spawned {
            eprintln!("cmux-tui: could not schedule template completion: {error}");
        }
    }

    /// Finish a template terminal once its host is adopted, on the startup
    /// pass or the asynchronous retry: commit its new placement to the public
    /// topology, then tell the template shell its new identity. The binding is
    /// written only after the commit, so the first `terminal.list` after it
    /// appears includes the terminal it names.
    #[cfg(unix)]
    pub(super) fn complete_template_adoption(&self, terminal_id: &str) -> anyhow::Result<()> {
        let terminal = self.workspace_registry.lock().unwrap().terminal_record(terminal_id)?;
        // A recovered terminal (cx-0tgl LC) is placed the same way; only a
        // Cloud template gets the identity binding below.
        let Some(terminal) = terminal.filter(orphan_hosts::placed_on_adoption) else {
            return Ok(());
        };
        anyhow::ensure!(
            !self.consume_template_completion_failure(),
            "injected template completion failure"
        );
        self.commit_ordinary_full_resource_projection(
            &Actor::Daemon,
            "terminal.adopt-template",
            serde_json::json!({}),
        )?;
        let bound_file = self.surface_options.lock().unwrap().template_bound_file.clone();
        if let Some(path) = bound_file.filter(|_| is_template_terminal(&terminal)) {
            self.publish_template_binding(terminal_id, &path)?;
        }
        Ok(())
    }

    /// Claim a Cloud snapshot's warm terminal host as the first terminal of
    /// this fresh registry (SurfaceOptions::adopt_template_terminal). The
    /// host's workspace is recreated under its recorded key and named from
    /// the options; the durable row is marked as a template terminal so
    /// finish_terminal_adoption gives it a new placement with fresh public
    /// ids. The ordinary adoption handshake follows.
    #[cfg(unix)]
    pub(super) fn claim_template_terminal(
        &self,
        options: &SurfaceOptions,
        record: &crate::terminal_host_runtime::TerminalHostRecord,
    ) -> anyhow::Result<RegistryTerminal> {
        self.create_empty_workspace(
            options.template_workspace_name.clone(),
            Some(record.workspace_key.clone()),
            None,
        )?;
        let claimed = RegistryTerminal {
            terminal_id: record.terminal_id.clone(),
            workspace_key: record.workspace_key.clone(),
            incarnation: None,
            lifecycle: TerminalLifecycle::Launching,
            launch_spec: template_terminal_launch_spec(),
            exit: None,
            on_exit: TerminalOnExit::Close,
        };
        let mut registry = self.workspace_registry.lock().unwrap();
        let revision = commit_terminal_transition(
            &mut registry,
            "terminal-template-claimed",
            "claim-template-terminal",
            &claimed,
        )?;
        self.emit_terminal_registry_changed(&registry, revision);
        Ok(claimed)
    }

    /// Tell the warm template shell its new identity. The shell was spawned
    /// by the snapshot builder's daemon, so its CMUX_TUI_SESSION_ID and
    /// CMUX_TUI_TERMINAL_ID name the builder's session and terminal. Its
    /// first prompt waits for this file and re-exports both before any user
    /// command (or agent hook) runs. Written only after the adoption above
    /// committed, and atomically, so its presence means the clone is bound.
    #[cfg(unix)]
    pub(super) fn publish_template_binding(
        &self,
        terminal_id: &str,
        path: &Path,
    ) -> anyhow::Result<()> {
        let session_id = self.session_public_id();
        let terminal_public_id = {
            let state = self.state.lock().unwrap();
            state
                .surfaces
                .iter()
                .find(|(_, surface)| {
                    surface
                        .terminal_host_identity()
                        .is_some_and(|identity| identity.terminal_id == terminal_id)
                })
                .and_then(|(surface_id, _)| state.resource_indexes.content_ids.get(surface_id))
                .and_then(|content| match content {
                    ContentPublicId::Terminal(id) => Some(id.clone()),
                    _ => None,
                })
        };
        // Adoption may have fallen back to the asynchronous retry loop; the
        // shell's bounded wait then clears the builder's values instead.
        let Some(terminal_public_id) = terminal_public_id else { return Ok(()) };
        let contents = format!(
            "CMUX_TUI_SESSION_ID={}\nCMUX_TUI_TERMINAL_ID={}\n",
            session_id.as_str(),
            terminal_public_id.as_str()
        );
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let temporary = path.with_extension("tmp");
        std::fs::write(&temporary, contents)?;
        std::fs::rename(&temporary, path)?;
        Ok(())
    }

    /// Startup and adoption-loop reconciliation of a host that is gone or no
    /// longer matches its row. Commits the exit receipt (the host's sidecar
    /// when it left one) and detaches the terminal's tabs only when that
    /// receipt proves a process end; a host loss leaves them dead.
    #[cfg(unix)]
    pub(super) fn mark_terminal_ended(
        self: &Arc<Self>,
        terminal_id: &str,
        _operation: &str,
        reason: &str,
        options: &SurfaceOptions,
    ) -> anyhow::Result<()> {
        self.clear_pending_terminal(terminal_id);
        if self.terminal_is_respawning(terminal_id) {
            return Ok(());
        }
        let terminal = self.workspace_registry.lock().unwrap().terminal_record(terminal_id)?;
        let Some(terminal) = terminal else { return Ok(()) };
        if terminal.lifecycle == TerminalLifecycle::Tombstoned {
            return Ok(());
        }
        let sidecar = options
            .terminal_host_root
            .as_ref()
            .map(|root| root.join(format!("{terminal_id}.json")))
            .map(|record_path| {
                crate::terminal_host_runtime::terminal_host_exit_record(&record_path)
            })
            .transpose()?
            .flatten()
            .filter(|(_, record)| {
                record.terminal_id == terminal_id
                    && terminal
                        .incarnation
                        .as_deref()
                        .is_none_or(|incarnation| incarnation == record.incarnation)
            });
        if terminal.lifecycle != TerminalLifecycle::Exited {
            // A sidecar is the host's record of the child's end. Without one
            // the host died with an unknown outcome: the terminal is exited
            // but its tabs stay, dead (invariant 3).
            let observed = sidecar
                .as_ref()
                .map(|(_, record)| TerminalEnd::from_host_exit(record.exit.clone()))
                .unwrap_or_else(|| TerminalEnd::host_lost(reason));
            let incarnation = sidecar
                .as_ref()
                .map(|(_, record)| record.incarnation.as_str())
                .or(terminal.incarnation.as_deref());
            self.persist_terminal_exit(terminal_id, incarnation, &observed)?;
        }
        if let Some((path, record)) = sidecar {
            let _ = crate::terminal_host_runtime::acknowledge_terminal_host_exit_record(
                &path, &record,
            )?;
        }
        self.detach_exited_terminal_topology(terminal_id)?;
        self.record_terminal_end(terminal_id);
        Ok(())
    }

    #[cfg(unix)]
    pub(super) fn finish_terminal_adoption(
        &self,
        terminal_id: &str,
        incarnation: &str,
        surface: Arc<Surface>,
    ) -> anyhow::Result<()> {
        let _pending_host_release = PendingTerminalHostRelease(surface.clone());
        if surface.is_dead() {
            let end = surface
                .terminal_end()
                .unwrap_or_else(|| TerminalEnd::host_lost("host-exited-during-adoption"));
            self.persist_terminal_exit(terminal_id, Some(incarnation), &end)?;
            anyhow::bail!("terminal host exited during adoption");
        }
        let mut registry = self.workspace_registry.lock().unwrap();
        let mut state = self.lock_state_pinned(&registry).unwrap();
        let terminal = registry
            .terminal_record(terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("terminal disappeared during adoption"))?;
        anyhow::ensure!(
            terminal.lifecycle == TerminalLifecycle::Adopting,
            "terminal is no longer awaiting adoption"
        );
        anyhow::ensure!(
            terminal.incarnation.as_deref() == Some(incarnation),
            "terminal incarnation changed during adoption"
        );
        anyhow::ensure!(
            surface.terminal_host_identity().is_some_and(|identity| {
                identity.terminal_id == terminal_id && identity.incarnation == incarnation
            }),
            "adopted host identity does not match durable terminal"
        );

        let before = state.clone();
        let restored_public_id = surface.terminal_public_id().cloned();
        let has_restored_placements = restored_public_id.as_ref().is_some_and(|public_id| {
            !state.placements_of_content(&ContentPublicId::Terminal(public_id.clone())).is_empty()
        });
        if orphan_hosts::placed_on_adoption(&terminal) && !has_restored_placements {
            // Cloud snapshot template, first adoption: its builder's placement
            // was wiped with the builder's registry, so it gets a new one here.
            // The template marker stays on the durable row, so a later daemon
            // start (crash, in-place upgrade) finds the placement this one
            // committed and restores it below instead of placing it twice.
            self.place_adopted_terminal_in_new_screen(
                &mut state,
                &terminal.workspace_key,
                surface,
            )?;
        } else if has_restored_placements || surface.resource_identity().is_none() {
            anyhow::ensure!(
                !self.consume_terminal_adoption_insert_failure(),
                "injected terminal adoption topology failure"
            );
            insert_restored_terminal_runtime_checked(&mut state, surface)?;
        } else {
            // One-release import path for a host that predates public content
            // identities. Give it a real initial placement so the normal
            // resource projection can persist its generated identities.
            self.place_adopted_terminal_in_new_screen(
                &mut state,
                &terminal.workspace_key,
                surface,
            )?;
        }

        let revision = match commit_terminal_lifecycle(
            &mut registry,
            "terminal-ready",
            "terminal-adopted",
            terminal_id,
            TerminalLifecycle::Running,
            Some(incarnation),
            None,
        ) {
            Ok((_, revision)) => revision,
            Err(error) => {
                *state = before;
                return Err(error);
            }
        };
        drop(state);
        self.emit_terminal_registry_changed(&registry, revision);
        drop(registry);
        self.publish_adopted_detached_terminal(terminal_id);
        // Clients read tab liveness from the tree: an adopting tab is live now.
        if self.clear_pending_terminal(terminal_id) {
            self.emit(MuxEvent::TreeChanged);
        }
        // Adoption makes the terminal's resource surface available. Retry
        // only hooks scoped to this terminal, not the entire pending table.
        if let Ok(terminal_id) = TerminalPublicId::parse(terminal_id) {
            let _ = self.retry_pending_agent_hooks_for_terminal(&terminal_id);
            self.reconcile_agent_roster_projections_for_terminal(&terminal_id);
        }
        Ok(())
    }

    /// Give an adopted terminal host a new screen and pane in the workspace
    /// with `workspace_key`, without stealing focus. The resource projection
    /// then generates and persists its public ids.
    #[cfg(unix)]
    pub(super) fn place_adopted_terminal_in_new_screen(
        &self,
        state: &mut State,
        workspace_key: &str,
        surface: Arc<Surface>,
    ) -> anyhow::Result<()> {
        let workspace_index = state
            .workspaces
            .iter()
            .position(|workspace| workspace.key == workspace_key)
            .ok_or_else(|| anyhow::anyhow!("terminal workspace disappeared during adoption"))?;
        let (pane_id, pane) = self.make_pane(surface.id)?;
        let screen_id = self.next_id();
        let screen_public_id = ScreenPublicId::random()?;
        anyhow::ensure!(
            !self.consume_terminal_adoption_insert_failure(),
            "injected terminal adoption topology failure"
        );
        insert_surface_checked(state, surface)?;
        {
            let workspace = &mut state.workspaces[workspace_index];
            workspace.screens.push(Screen {
                id: screen_id,
                public_id: screen_public_id,
                name: None,
                root: Node::Leaf(pane_id),
                active_pane: pane_id,
                zoomed_pane: None,
                creation_order_auto_layout: Some(vec![pane_id]),
                viewport_splits: Default::default(),
                viewport_base_width: None,
                layout_columns: Vec::new(),
                layout_revision: 0,
                layout_undo: Default::default(),
            });
            workspace.active_screen = workspace.screens.len() - 1;
        }
        // Adoption materializes a live pane without stealing focus, but it
        // must still advance the pane-set revision used by frontend focus
        // history pruning.
        state.insert_pane(pane);
        state.rebuild_resource_indexes();
        Ok(())
    }

    #[cfg(unix)]
    pub(super) fn consume_template_completion_failure(&self) -> bool {
        self.template_completion_failures
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |remaining| remaining.checked_sub(1))
            .is_ok()
    }

    #[cfg(unix)]
    pub(super) fn consume_terminal_adoption_insert_failure(&self) -> bool {
        self.terminal_adoption_insert_failures
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |remaining| remaining.checked_sub(1))
            .is_ok()
    }

    #[cfg(unix)]
    pub(super) fn schedule_terminal_adoption(
        self: &Arc<Self>,
        options: SurfaceOptions,
        record: crate::terminal_host_runtime::TerminalHostRecord,
        record_path: std::path::PathBuf,
    ) {
        let terminal_id = record.terminal_id.clone();
        if !self.terminal_adoptions.lock().unwrap().insert(terminal_id.clone()) {
            return;
        }
        let cleanup_id = terminal_id.clone();
        let mux = self.clone();
        let spawn_result = std::thread::Builder::new()
            .name(format!("terminal-adopt-{terminal_id}"))
            .spawn(move || {
                let mut delay = Duration::from_millis(100);
                let mut refusals = pending_terminals::RefusalStreak::default();
                loop {
                    if mux.shutting_down.load(Ordering::Acquire) {
                        break;
                    }
                    std::thread::sleep(delay);
                    if mux.shutting_down.load(Ordering::Acquire) {
                        break;
                    }
                    // A failed read proves nothing about the host: retry.
                    let Ok(terminal) =
                        mux.workspace_registry.lock().unwrap().terminal_record(&terminal_id)
                    else {
                        delay = (delay * 2).min(Duration::from_secs(5));
                        continue;
                    };
                    let Some(terminal) = terminal else {
                        if cleanup_terminal_host_record(&record, &record_path) {
                            break;
                        }
                        delay = (delay * 2).min(Duration::from_secs(5));
                        continue;
                    };
                    if matches!(
                        terminal.lifecycle,
                        TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned
                    ) {
                        if terminal.lifecycle == TerminalLifecycle::Exited
                            && let Err(error) = mux.detach_exited_terminal_topology(&terminal_id)
                        {
                            eprintln!(
                                "cmux-tui: could not detach exited terminal \
                                 {terminal_id}: {error:#}"
                            );
                            delay = (delay * 2).min(Duration::from_secs(5));
                            continue;
                        }
                        if cleanup_terminal_host_record(&record, &record_path) {
                            break;
                        }
                        delay = (delay * 2).min(Duration::from_secs(5));
                        continue;
                    }
                    if terminal
                        .incarnation
                        .as_deref()
                        .is_some_and(|incarnation| incarnation != record.incarnation)
                    {
                        if let Err(error) = mux.mark_terminal_ended(
                            &terminal_id,
                            "terminal-incarnation-mismatch",
                            "host-incarnation-mismatch",
                            &options,
                        ) {
                            eprintln!(
                                "cmux-tui: could not reconcile exited terminal \
                                 {terminal_id}: {error:#}"
                            );
                            delay = (delay * 2).min(Duration::from_secs(5));
                            continue;
                        }
                        if cleanup_terminal_host_record(&record, &record_path) {
                            break;
                        }
                        delay = (delay * 2).min(Duration::from_secs(5));
                        continue;
                    }
                    if terminal.lifecycle == TerminalLifecycle::Running {
                        let already_live = mux
                            .resolve_terminal(&terminal_id)
                            .ok()
                            .flatten()
                            .is_some_and(|resolution| resolution.surface.is_some());
                        if already_live {
                            break;
                        }
                        if mux
                            .transition_terminal_lifecycle(
                                "terminal-adopting",
                                "retry-terminal-adoption",
                                &terminal_id,
                                TerminalLifecycle::Adopting,
                                Some(&record.incarnation),
                            )
                            .is_err()
                        {
                            break;
                        }
                    }
                    if terminal_host_record_liveness(&record_path, &record)
                        == TerminalHostLiveness::Dead
                    {
                        if let Err(error) = mux.mark_terminal_ended(
                            &terminal_id,
                            "terminal-host-proven-dead",
                            "host-process-ended-before-adoption",
                            &options,
                        ) {
                            eprintln!(
                                "cmux-tui: could not reconcile exited terminal \
                                 {terminal_id}: {error:#}"
                            );
                            delay = (delay * 2).min(Duration::from_secs(5));
                            continue;
                        }
                        let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                            &record_path,
                            &record,
                        );
                        break;
                    }
                    let restored_binding = match mux.restored_terminal_binding(&terminal_id) {
                        Ok(binding) => binding,
                        Err(_) => {
                            delay = (delay * 2).min(Duration::from_secs(5));
                            continue;
                        }
                    };
                    let adopted = mux.adopt_restored_terminal(
                        restored_binding,
                        &options,
                        &record,
                        &record_path,
                    );
                    if mux.refused_all(
                        &mut refusals,
                        Instant::now(),
                        &adopted,
                        &options,
                        &record_path,
                        &record,
                    ) {
                        break;
                    }
                    if let Ok(surface) = adopted {
                        if mux
                            .finish_terminal_adoption(
                                &terminal_id,
                                &record.incarnation,
                                surface.clone(),
                            )
                            .is_ok()
                        {
                            mux.ensure_template_adoption_completed(&terminal_id);
                            mux.reap_if_dead(&surface);
                            break;
                        }
                        let host_is_dead = surface.is_dead()
                            || terminal_host_record_liveness(&record_path, &record)
                                == TerminalHostLiveness::Dead;
                        surface.disconnect_for_daemon_shutdown();
                        if host_is_dead {
                            if let Err(error) = mux.mark_terminal_ended(
                                &terminal_id,
                                "terminal-adoption-failed",
                                "host-exited-during-adoption",
                                &options,
                            ) {
                                eprintln!(
                                    "cmux-tui: could not reconcile exited terminal \
                                     {terminal_id}: {error:#}"
                                );
                                delay = (delay * 2).min(Duration::from_secs(5));
                                continue;
                            }
                            let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                                &record_path,
                                &record,
                            );
                            break;
                        }
                        delay = (delay * 2).min(Duration::from_secs(5));
                        continue;
                    }
                    if terminal_host_record_liveness(&record_path, &record)
                        == TerminalHostLiveness::Dead
                    {
                        if let Err(error) = mux.mark_terminal_ended(
                            &terminal_id,
                            "terminal-host-proven-dead",
                            "host-process-ended-before-adoption",
                            &options,
                        ) {
                            eprintln!(
                                "cmux-tui: could not reconcile exited terminal \
                                 {terminal_id}: {error:#}"
                            );
                            delay = (delay * 2).min(Duration::from_secs(5));
                            continue;
                        }
                        let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                            &record_path,
                            &record,
                        );
                        break;
                    }
                    delay = (delay * 2).min(Duration::from_secs(5));
                }
                mux.clear_adopting_marker(&terminal_id);
                mux.terminal_adoptions.lock().unwrap().remove(&terminal_id);
            });
        if spawn_result.is_err() {
            self.terminal_adoptions.lock().unwrap().remove(&cleanup_id);
            self.clear_pending_terminal(&cleanup_id);
        }
    }
}
