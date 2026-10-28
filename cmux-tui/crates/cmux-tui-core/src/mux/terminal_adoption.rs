//! Terminal adoption at startup: restored terminal bindings, adopting live
//! terminal hosts, template terminals, and scheduling adoption work.

use super::*;

impl Mux {
    #[cfg(any(unix, windows))]
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

    #[cfg(any(unix, windows))]
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

    #[cfg(any(unix, windows))]
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
        // Live hosts this pass hands to their adoption threads.
        let mut deferred: Vec<(
            crate::terminal_host_runtime::TerminalHostRecord,
            std::path::PathBuf,
        )> = Vec::new();
        // At most one warm snapshot host becomes the first terminal of a
        // fresh registry (SurfaceOptions::adopt_template_terminal).
        let mut template_claimed = false;
        let mut claimed_template = None;
        // Hosts this pass marks adopting together, with their rows.
        let mut adopting = Vec::new();
        let mut candidates = Vec::new();
        // Records whose cleanup failed retry on a thread scheduled after the
        // live hosts': a second record of a live terminal must not claim its
        // adoption thread first.
        let mut cleanup_retries = Vec::new();
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
        // Every host's row and public id under one registry lock: taken per
        // host, the lock waits on other startup threads cost about 7 ms each.
        let mut prefetched = {
            let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            let mut rows = HashMap::new();
            for (_, record) in &records {
                let row = registry.terminal_record(&record.terminal_id)?;
                let public_id = registry.terminal_resource_id(&record.terminal_id)?;
                rows.insert(record.terminal_id.clone(), (row, public_id));
            }
            rows
        };
        for (record_path, record) in records {
            let terminal_id = record.terminal_id.clone();
            if handled_terminals.contains(&terminal_id) {
                if !cleanup_terminal_host_record(&record, &record_path) {
                    cleanup_retries.push((record, record_path));
                }
                continue;
            }
            let (mut terminal, public_id) = match prefetched.remove(&terminal_id) {
                Some(prefetched) => prefetched,
                None => (
                    self.workspace_registry
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .terminal_record(&terminal_id)?,
                    None,
                ),
            };
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
                claimed_template = Some(terminal_id.clone());
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
                        cleanup_retries.push((record, record_path));
                    }
                    continue;
                }
            }
            let terminal = terminal.expect("terminal imported or loaded");
            if terminal.lifecycle == TerminalLifecycle::Tombstoned {
                if !cleanup_terminal_host_record(&record, &record_path) {
                    cleanup_retries.push((record, record_path));
                }
                continue;
            }
            if terminal.lifecycle == TerminalLifecycle::Exited {
                self.detach_exited_terminal_topology(&terminal.terminal_id)?;
                handled_terminals.insert(terminal_id.clone());
                if !cleanup_terminal_host_record(&record, &record_path) {
                    cleanup_retries.push((record, record_path));
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
                    cleanup_retries.push((record, record_path));
                }
                continue;
            }
            // A second record for this terminal is cleaned up, not adopted.
            handled_terminals.insert(terminal_id.clone());
            let incarnation = record.incarnation.clone();
            adopting.push((terminal, incarnation));
            candidates.push((record, record_path, public_id));
        }

        // Every host this pass adopts is marked adopting in one registry
        // transaction: a commit each cost 2.6 ms per host before the first
        // answer (plans/cmux-next/service-start-PERF.md 5b).
        let marked = {
            let mut registry =
                self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            let (marked, revision) = commit_terminals_adopting(&mut registry, &adopting)?;
            if let Some(revision) = revision {
                self.emit_terminal_registry_changed(&registry, revision);
            }
            marked
        };
        for ((record, record_path, public_id), marked) in candidates.into_iter().zip(marked) {
            let terminal_id = record.terminal_id.clone();
            if let Err(error) = marked {
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
                        cleanup_retries.push((record, record_path));
                    }
                    continue;
                }
                anyhow::bail!("terminal {terminal_id} could not be marked adopting: {error}");
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
            handled_terminals.insert(terminal_id.clone());
            if claimed_template.as_ref() == Some(&terminal_id) {
                // A Cloud clone's first answer must already list the template
                // terminal under its new identity: a client that listed
                // nothing (the Cloud prompt sync) created a second workspace.
                self.adopt_template_terminal_inline(&options, record, record_path)?;
                continue;
            }
            // The host adopts on its own thread, after the owner answers its
            // clients: one host's handshake and replay must not hold the first
            // answer, nor every other terminal (launch to a live terminal,
            // plans/cmux-next/service-start-PERF.md 5b). The tab is adopting,
            // not dead, until then (R41).
            match public_id {
                // An imported or recovered row has no prefetched id: read it now.
                Some(public_id) => {
                    self.set_pending_terminal_as(
                        public_id,
                        &terminal_id,
                        PendingTerminal::Adopting,
                    );
                }
                None => {
                    self.set_pending_terminal(&terminal_id, PendingTerminal::Adopting);
                }
            }
            deferred.push((record, record_path));
        }

        self.mark_unadoptable_terminal_hosts(&options, &mut handled_terminals)?;
        // The threads start after this pass: their registry commits would
        // otherwise queue each read above behind them (745 ms for 60 hosts).
        for (record, record_path) in deferred {
            self.schedule_terminal_adoption_after(
                options.clone(),
                record,
                record_path,
                Duration::ZERO,
            );
        }
        for (record, record_path) in cleanup_retries {
            self.schedule_terminal_adoption(options.clone(), record, record_path);
        }

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
            self.adopt_from_holder_or_end(&terminal, &options)?;
        }
        self.release_unclaimed_holder_terminals(&options);
        Ok(())
    }

    /// Adopt the template terminal this pass claimed before the owner
    /// answers anyone, then bind the warm shell to its new identity. A host
    /// that does not answer yet keeps adopting on its own thread.
    #[cfg(any(unix, windows))]
    fn adopt_template_terminal_inline(
        self: &Arc<Self>,
        options: &SurfaceOptions,
        record: crate::terminal_host_runtime::TerminalHostRecord,
        record_path: std::path::PathBuf,
    ) -> anyhow::Result<()> {
        let terminal_id = record.terminal_id.clone();
        let restored_binding = self.restored_terminal_binding(&terminal_id)?;
        let adopted =
            self.adopt_restored_terminal(restored_binding, options, &record, &record_path).ok();
        if let Some(surface) = adopted {
            if self
                .finish_terminal_adoption(&terminal_id, &record.incarnation, surface.clone())
                .is_ok()
            {
                self.ensure_template_adoption_completed(&terminal_id);
                self.reap_if_dead(&surface);
                return Ok(());
            }
            surface.disconnect_for_daemon_shutdown();
        }
        self.set_pending_terminal(&terminal_id, PendingTerminal::Adopting);
        self.schedule_terminal_adoption(options.clone(), record, record_path);
        Ok(())
    }

    /// Complete an adopted template terminal (complete_template_adoption),
    /// retrying in the background until it succeeds or the daemon shuts down.
    /// Adoption itself has already committed, so a failure here must neither
    /// abort startup nor leave the terminal without its public placement and
    /// binding.
    #[cfg(any(unix, windows))]
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
    #[cfg(any(unix, windows))]
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
    #[cfg(any(unix, windows))]
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
    #[cfg(any(unix, windows))]
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
    #[cfg(any(unix, windows))]
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

    #[cfg(any(unix, windows))]
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
        if let Some(public_id) = restored_public_id {
            let mut names = self.restored_tab_names.lock().unwrap_or_else(PoisonError::into_inner);
            for placement in state.placements_of_content(&ContentPublicId::Terminal(public_id)) {
                if let (Some(name), Some(surface)) =
                    (names.remove(placement), state.surfaces.get(placement))
                {
                    surface.set_name(Some(name));
                }
            }
        }
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
    #[cfg(any(unix, windows))]
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

    #[cfg(any(unix, windows))]
    pub(super) fn consume_template_completion_failure(&self) -> bool {
        self.template_completion_failures
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |remaining| remaining.checked_sub(1))
            .is_ok()
    }

    #[cfg(any(unix, windows))]
    pub(super) fn consume_terminal_adoption_insert_failure(&self) -> bool {
        self.terminal_adoption_insert_failures
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |remaining| remaining.checked_sub(1))
            .is_ok()
    }

    #[cfg(any(unix, windows))]
    pub(super) fn schedule_terminal_adoption(
        self: &Arc<Self>,
        options: SurfaceOptions,
        record: crate::terminal_host_runtime::TerminalHostRecord,
        record_path: std::path::PathBuf,
    ) {
        self.schedule_terminal_adoption_after(
            options,
            record,
            record_path,
            Duration::from_millis(100),
        );
    }

    /// Adopts a surviving host on its own thread, first after `first_delay` (zero:
    /// at a start, once the owner says ready), then retrying with backoff. At most ``ADOPTION_SLOTS`` hosts replay at once, so a
    /// start with hundreds of hosts does not hold every replay in memory together.
    pub(super) fn schedule_terminal_adoption_after(
        self: &Arc<Self>,
        options: SurfaceOptions,
        record: crate::terminal_host_runtime::TerminalHostRecord,
        record_path: std::path::PathBuf,
        first_delay: Duration,
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
                if first_delay.is_zero() {
                    // A start's adoptions wait for the owner to say ready: their
                    // registry and state locks held the rest of its start back
                    // (230 ms for 60 hosts). A mux that never says ready (a bare
                    // test mux) adopts after STARTUP_READY_WAIT.
                    let deadline = Instant::now() + STARTUP_READY_WAIT;
                    while !mux.server_lifecycle_ready()
                        && !mux.startup_adoptions_released.load(Ordering::Acquire)
                        && !mux
                            .terminal_adoptions_now
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            .contains(&terminal_id)
                        && !mux.shutting_down.load(Ordering::Acquire)
                        && Instant::now() < deadline
                    {
                        std::thread::sleep(Duration::from_millis(5));
                    }
                }
                // Test hook (fault injection, debug builds): the adoption starts
                // this much later, so a test can act while the terminal adopts.
                #[cfg(debug_assertions)]
                if let Some(ms) = std::env::var("CMUX_TUI_TEST_ADOPTION_DELAY_MS")
                    .ok()
                    .and_then(|ms| ms.parse::<u64>().ok())
                {
                    std::thread::sleep(Duration::from_millis(ms));
                }
                let mut delay = first_delay;
                let mut refusals = pending_terminals::RefusalStreak::default();
                loop {
                    if mux.shutting_down.load(Ordering::Acquire) {
                        break;
                    }
                    std::thread::sleep(delay);
                    // Retries back off from 100 ms, also after an immediate first try.
                    delay = delay.max(Duration::from_millis(50));
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
                    // Only a running row goes back to adopting: a launching one
                    // belongs to a respawn, and its new host must not be dropped.
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
                    let adopted = {
                        let _slot = AdoptionSlot::take();
                        mux.adopt_restored_terminal(
                            restored_binding,
                            &options,
                            &record,
                            &record_path,
                        )
                    };
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
                mux.terminal_adoption_ended.notify_all();
            });
        if spawn_result.is_err() {
            self.terminal_adoptions.lock().unwrap().remove(&cleanup_id);
            self.terminal_adoption_ended.notify_all();
            self.clear_pending_terminal(&cleanup_id);
        }
    }

    /// Waits, at most `bound`, until the adoption of `terminal_id` (a host id)
    /// ended, and has it start at once instead of after the owner says ready.
    /// Holds no other lock while it waits.
    pub(crate) fn wait_for_terminal_adoption(&self, terminal_id: &str, bound: Duration) {
        self.terminal_adoptions_now
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(terminal_id.to_owned());
        let deadline = Instant::now() + bound;
        let mut adoptions = self.terminal_adoptions.lock().unwrap_or_else(PoisonError::into_inner);
        while adoptions.contains(terminal_id) {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            adoptions = self
                .terminal_adoption_ended
                .wait_timeout(adoptions, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
        drop(adoptions);
        self.terminal_adoptions_now
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(terminal_id);
    }

    /// The running terminal `terminal_id` names, for a reopen that gives it a
    /// new view instead of a new process. A restarted owner answers before it
    /// adopted its surviving terminals (#23561): a terminal that still adopts
    /// is waited for (at most `REOPEN_ADOPTION_WAIT`), not taken for gone.
    pub(crate) fn resolve_running_terminal(&self, terminal_id: &str) -> Option<TerminalResolution> {
        let resolution = self.resolve_terminal(terminal_id).ok().flatten()?;
        let resolution = if resolution.terminal.lifecycle == TerminalLifecycle::Adopting {
            self.wait_for_terminal_adoption(&resolution.terminal.terminal_id, REOPEN_ADOPTION_WAIT);
            self.resolve_terminal(terminal_id).ok().flatten()?
        } else {
            resolution
        };
        (resolution.terminal.lifecycle == TerminalLifecycle::Running).then_some(resolution)
    }
}

/// The longest a reopen waits for its terminal's adoption
/// (`resolve_running_terminal`); after it the reopen starts a new shell.
const REOPEN_ADOPTION_WAIT: Duration = Duration::from_secs(10);

/// Hosts that may replay into this owner at once (`schedule_terminal_adoption_after`).
const ADOPTION_SLOTS: usize = 8;

/// The longest a start's adoption waits for its owner to say ready.
const STARTUP_READY_WAIT: Duration = Duration::from_secs(2);

/// One of the ``ADOPTION_SLOTS``, held while a host's handshake and replay run.
struct AdoptionSlot;

static ADOPTIONS_IN_FLIGHT: Mutex<usize> = Mutex::new(0);
static ADOPTION_SLOT_FREED: Condvar = Condvar::new();

impl AdoptionSlot {
    fn take() -> Self {
        let mut in_flight = ADOPTIONS_IN_FLIGHT.lock().unwrap_or_else(PoisonError::into_inner);
        while *in_flight >= ADOPTION_SLOTS {
            in_flight = ADOPTION_SLOT_FREED.wait(in_flight).unwrap_or_else(PoisonError::into_inner);
        }
        *in_flight += 1;
        AdoptionSlot
    }
}

impl Drop for AdoptionSlot {
    fn drop(&mut self) {
        *ADOPTIONS_IN_FLIGHT.lock().unwrap_or_else(PoisonError::into_inner) -= 1;
        ADOPTION_SLOT_FREED.notify_one();
    }
}
