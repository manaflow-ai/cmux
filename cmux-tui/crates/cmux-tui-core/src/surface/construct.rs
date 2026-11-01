//! Surface constructors: local and auxiliary PTY spawns with optional terminal
//! id, resource identity and cell pixels, prelaunched hosts, and the deferred
//! cell-pixel and hosted clear-history helpers they install.

use super::*;

impl Surface {
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn spawn(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
        let cell_pixels =
            mux.upgrade().map(|mux| mux.cell_pixel_creation_size()).unwrap_or((8, 16));
        Self::spawn_at_cell_pixels(id, opts, mux, cell_pixels)
    }

    /// Spawn runtime-only terminal content which is not part of the public
    /// resource tree, such as a sidebar view process.
    #[allow(dead_code)]
    pub(crate) fn spawn_auxiliary(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
        let cell_pixels =
            mux.upgrade().map(|mux| mux.cell_pixel_creation_size()).unwrap_or((8, 16));
        Self::spawn_auxiliary_at_cell_pixels(id, opts, mux, cell_pixels)
    }

    pub(crate) fn spawn_auxiliary_at_cell_pixels(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        Self::spawn_with_terminal_id_and_resource_identity_at_cell_pixels(
            id,
            opts,
            mux,
            HostLaunch::default(),
            None,
            PtyLifetime::DaemonOwned,
            cell_pixels,
        )
    }

    pub(crate) fn spawn_at_cell_pixels(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        Self::spawn_with_terminal_id_and_resource_identity_at_cell_pixels(
            id,
            opts,
            mux,
            HostLaunch::default(),
            Some(TabResourceIdentity::terminal(None)?),
            PtyLifetime::SessionOwned,
            cell_pixels,
        )
    }

    #[allow(dead_code)]
    pub(crate) fn spawn_with_resource_identity(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        resource_identity: Option<TabResourceIdentity>,
    ) -> anyhow::Result<Arc<Surface>> {
        let cell_pixels =
            mux.upgrade().map(|mux| mux.cell_pixel_creation_size()).unwrap_or((8, 16));
        Self::spawn_with_terminal_id_and_resource_identity_at_cell_pixels(
            id,
            opts,
            mux,
            HostLaunch::default(),
            resource_identity,
            PtyLifetime::SessionOwned,
            cell_pixels,
        )
    }

    /// The identity environment and Kitty image budget every terminal
    /// surface gets before its process starts.
    pub(super) fn spawn_prelude(
        id: SurfaceId,
        mut opts: SurfaceOptions,
        mux: &Weak<Mux>,
        resource_identity: Option<&TabResourceIdentity>,
        kitty_quota: KittyQuota,
    ) -> anyhow::Result<(
        SurfaceOptions,
        Option<TerminalPublicId>,
        Option<crate::mux::KittyImageBudgetReservation>,
    )> {
        let terminal_public_id = resource_identity
            .map(|identity| {
                terminal_public_id_from_resource_identity(
                    identity,
                    "terminal surface cannot use a browser resource identity",
                )
            })
            .transpose()?;
        if let Some(terminal_public_id) = terminal_public_id.as_ref() {
            set_env(&mut opts.extra_env, "CMUX_TUI_TERMINAL_ID", terminal_public_id.as_str());
            configure_agent_browser_session(&mut opts, terminal_public_id.as_str());
        }
        if let Some(mux) = mux.upgrade() {
            set_env(&mut opts.extra_env, "CMUX_TUI_SESSION_ID", mux.session_public_id().as_str());
            // The child's identity for the actor stamp (identity.md section
            // 2). Only the session host mints it; with none the variable is
            // set empty, so a value the daemon inherited never reaches a child.
            let credential = terminal_public_id
                .as_ref()
                .and_then(|terminal| mux.mint_terminal_credential(terminal))
                .unwrap_or_default();
            set_env(
                &mut opts.extra_env,
                crate::launch_credential::LAUNCH_CREDENTIAL_ENV,
                &credential,
            );
        }
        let kitty_reservation = mux
            .upgrade()
            .map(|mux| match kitty_quota {
                KittyQuota::AtLaunch => mux.reserve_kitty_image_surface(id),
                KittyQuota::AfterCommit => mux.reserve_kitty_image_surface_without_quota(id),
            })
            .transpose()?;
        Ok((opts, terminal_public_id, kitty_reservation))
    }

    /// Build the surface of a host from [`Surface::prelaunch_hosted`].
    #[cfg(any(unix, windows))]
    pub(crate) fn spawn_prelaunched(
        host: PrelaunchedHost,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
        let PrelaunchedHost {
            id,
            terminal_id: _,
            opts,
            attachment,
            kitty_reservation,
            terminal_public_id,
            resource_identity,
        } = host;
        Self::spawn_hosted(
            id,
            opts,
            mux,
            HostedSurfaceLaunch {
                adopted: false,
                attachment,
                kitty_reservation,
                terminate_on_error: true,
                defer_launch_activation: true,
                lifetime: PtyLifetime::SessionOwned,
                terminal_public_id,
                resource_identity: Some(resource_identity),
            },
        )
    }

    /// `launch` is the reserved terminal id, the VT replay its host applies
    /// before the child's first byte, the workspace its first record names
    /// and the spare host process to use (a hosted launch with an id only).
    pub(crate) fn spawn_with_terminal_id_and_resource_identity_at_cell_pixels(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        launch: HostLaunch<'_>,
        resource_identity: Option<TabResourceIdentity>,
        lifetime: PtyLifetime,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        let (opts, terminal_public_id, kitty_reservation) =
            Self::spawn_prelude(id, opts, &mux, resource_identity.as_ref(), KittyQuota::AtLaunch)?;
        crate::debug_spans::mark("surface.prelude");
        let initial_kitty_limits = kitty_reservation
            .as_ref()
            .map(crate::mux::KittyImageBudgetReservation::initial_limits)
            .unwrap_or_default();
        #[cfg(windows)]
        let mut host_start_failed = false;
        #[cfg(not(windows))]
        let host_start_failed = false;
        // The holder runs the shell; this daemon parses it (holder_runtime).
        #[cfg(unix)]
        if lifetime == PtyLifetime::SessionOwned
            && crate::holder_runtime::enabled()
            && let Some(host_root) = opts.terminal_host_root.clone()
        {
            return Self::spawn_on_holder(HolderSpawn {
                id,
                opts,
                mux,
                host_root,
                terminal_id: launch.terminal_id,
                seed: launch.seed.to_vec(),
                terminal_public_id,
                resource_identity,
                kitty_reservation,
                initial_kitty_limits,
                cell_pixels,
            });
        }
        #[cfg(any(unix, windows))]
        if lifetime == PtyLifetime::SessionOwned
            && let Some(root) = opts.terminal_host_root.clone()
        {
            let default_colors = mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
            let HostLaunch { terminal_id, seed, workspace_key, standby } = launch;
            let launched = match terminal_id {
                Some(terminal_id) => crate::terminal_host_runtime::launch_terminal_host_seeded(
                    &opts,
                    &root,
                    (default_colors, cell_pixels, initial_kitty_limits),
                    terminal_id,
                    standby,
                    (seed, workspace_key),
                ),
                None => crate::terminal_host_runtime::launch_terminal_host(
                    &opts,
                    &root,
                    default_colors,
                    cell_pixels,
                    initial_kitty_limits,
                ),
            };
            crate::debug_spans::mark("surface.host_launched");
            match launched {
                Ok(attachment) => {
                    let defer_launch_activation = terminal_public_id.is_some();
                    return Self::spawn_hosted(
                        id,
                        opts,
                        mux,
                        HostedSurfaceLaunch {
                            adopted: false,
                            attachment,
                            kitty_reservation,
                            terminate_on_error: true,
                            defer_launch_activation,
                            lifetime,
                            terminal_public_id,
                            resource_identity,
                        },
                    );
                }
                // Windows: no host process started; the daemon runs the
                // terminal itself and every tree says so (cx-ko2e).
                #[cfg(windows)]
                Err(error)
                    if error
                        .downcast_ref::<crate::terminal_host_runtime::HostProcessStartFailed>()
                        .is_some() =>
                {
                    eprintln!("cmux-tui: {error:#}; running the terminal in the daemon");
                    host_start_failed = true;
                }
                Err(error) => return Err(error),
            }
        }
        #[cfg(not(any(unix, windows)))]
        let _ = launch;
        let initial_geometry = PtyGeometry {
            cols: opts.cols,
            rows: opts.rows,
            cell_width: cell_pixels.0,
            cell_height: cell_pixels.1,
        };
        let pty = cmux_pty::open(initial_geometry.pty_size())?;

        let launch = crate::shell_integration::shell_launch(opts.command.clone(), opts.extra_env.clone());
        let argv = launch.command;
        let mut cmd = PtyCommand::new(&argv[0]);
        cmd.args(argv[1..].iter().cloned());
        cmd.env("TERM", &opts.term);
        // The embedded ghostty-vt terminal always parses 24-bit SGR and every
        // frontend forwards RGB cells losslessly, so children can rely on
        // truecolor regardless of where the session server was started
        // (launchd, ssh, cron strip COLORTERM). Set before extra_env so a
        // caller can still override it.
        cmd.env("COLORTERM", "truecolor");
        // A daemon-local PTY never starts through login(1): its close ends
        // only the direct child, which would be login, not the shell.
        for (k, v) in &launch.env {
            if !crate::login_shell::is_marker(k) {
                cmd.env(k, v);
            }
        }
        for key in cmux_pty::UNSET_IN_TERMINAL_CHILDREN
            .iter()
            .copied()
            .chain(crate::shell_integration::inherited_keys_to_unset(&launch.env))
        {
            cmd.env_remove(key);
        }
        let cwd = opts.cwd.clone().or_else(platform::default_terminal_cwd);
        if let Some(cwd) = cwd.as_deref() {
            cmd.cwd(cwd);
        }

        let cmux_pty::SpawnedPty { master, child } = pty.spawn(cmd)?;
        let mut child = PtyChildStartupGuard::new(child);
        let pid = child.process_id();
        let killer = child.clone_killer();
        #[cfg(unix)]
        let supports_clear_history_key_fallback = master.as_raw_fd().is_some();
        #[cfg(not(unix))]
        let supports_clear_history_key_fallback = false;
        let reader = master.try_clone_reader()?;
        let writer = master.take_writer()?;
        let launch = LocalLaunch {
            master,
            reader,
            writer,
            killer,
            wait: Box::new(move || TerminalEnd::ProcessEnded(child.wait_for_exit())),
            pid,
            command: argv,
            cwd,
            supports_clear_history_key_fallback,
            #[cfg(unix)]
            holder: None,
        };
        let spawn = LocalSpawn {
            id,
            opts,
            mux,
            terminal_public_id,
            kitty_reservation,
            initial_kitty_limits,
            resource_identity,
            lifetime,
            cell_pixels,
            initial_geometry,
            host_identity: None,
        };
        let surface = Self::spawn_local(spawn, launch)?;
        if host_start_failed {
            surface.mark_terminal_host_fallback(TerminalHostFallback::HostStartFailed);
        }
        Ok(surface)
    }

    #[cfg(any(unix, windows))]
    pub(super) fn install_deferred_cell_pixel_handler(
        surface: &Arc<Surface>,
        responses: &Arc<crate::terminal_host_runtime::ControlResponses>,
    ) {
        let surface = Arc::downgrade(surface);
        let responses = Arc::downgrade(responses);
        responses
            .upgrade()
            .expect("control responses are live while installing their handler")
            .set_deferred_cell_pixel_handler(Arc::new(move |request_id, expected, resolution| {
                if matches!(
                    &resolution,
                    crate::terminal_host_runtime::DeferredCellPixelResolution::Disconnected
                ) {
                    return;
                }
                let (Some(surface), Some(responses)) = (surface.upgrade(), responses.upgrade())
                else {
                    return;
                };
                let Some(mux) = surface.as_pty().and_then(|pty| pty.mux.upgrade()) else {
                    return;
                };
                let queued_surface = surface.clone();
                let queued_responses = responses.clone();
                let queued_resolution = resolution.clone();
                if !mux.submit_deferred_cell_pixel_ack(move || {
                    queued_surface.reconcile_deferred_cell_pixel_ack(
                        &queued_responses,
                        request_id,
                        expected,
                        queued_resolution,
                    );
                }) {
                    // The bounded pool is saturated or cannot create its first
                    // worker. Reconcile on the already-owned host reader
                    // instead of dropping a valid acknowledgement.
                    surface.reconcile_deferred_cell_pixel_ack(
                        &responses, request_id, expected, resolution,
                    );
                }
            }));
    }

    #[cfg(any(unix, windows))]
    pub(super) fn reconcile_deferred_cell_pixel_ack(
        &self,
        responses: &Arc<crate::terminal_host_runtime::ControlResponses>,
        request_id: u64,
        expected: (u16, u16),
        resolution: crate::terminal_host_runtime::DeferredCellPixelResolution,
    ) {
        #[cfg(test)]
        if let Some(pty) = self.as_pty()
            && let Some(hook) = pty.deferred_cell_pixel_ack_test_hook.lock().unwrap().clone()
        {
            hook();
        }
        let crate::terminal_host_runtime::DeferredCellPixelResolution::Response(frame) = resolution
        else {
            // The replacement host snapshot is authoritative for an
            // acknowledgement whose delivery raced a broken admin stream.
            return;
        };
        let Some(pty) = self.as_pty() else { return };
        let owns_response = {
            let runtime = pty.runtime.lock().unwrap();
            matches!(
                &*runtime,
                PtyRuntime::Hosted(host)
                    if Arc::ptr_eq(&host.control_responses(), responses)
            )
        };
        if !owns_response || responses.latest_cell_pixel_ack() > request_id {
            return;
        }
        let expected_payload = [expected.0.to_le_bytes(), expected.1.to_le_bytes()].concat();
        if frame.kind != MessageKind::CellPixelSizeAck
            || frame.payload.as_slice() != expected_payload
        {
            if let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap() {
                host.disconnect();
            }
            return;
        }

        let mut geometry = pty.geometry.lock().unwrap();
        let still_owns_response = {
            let runtime = pty.runtime.lock().unwrap();
            matches!(
                &*runtime,
                PtyRuntime::Hosted(host)
                    if Arc::ptr_eq(&host.control_responses(), responses)
            )
        };
        if !still_owns_response || responses.latest_cell_pixel_ack() > request_id {
            return;
        }
        let next = PtyGeometry { cell_width: expected.0, cell_height: expected.1, ..*geometry };
        let committed = pty.commit_geometry(&mut geometry, next, false);
        drop(geometry);
        match committed {
            Ok(changed) => {
                if let Some(mux) = pty.mux.upgrade() {
                    if changed {
                        mux.emit_terminal_output(pty.event_surface_id);
                    }
                    mux.reconcile_deferred_cell_pixel_ack(self.id, expected);
                }
            }
            Err(_) => {
                if let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap() {
                    host.disconnect();
                }
            }
        }
    }

    #[cfg(any(unix, windows))]
    pub(super) fn apply_hosted_clear_history_replay(
        surface: &Arc<Surface>,
        pty: &PtySurface,
        replay: &[u8],
        mux: &Weak<Mux>,
    ) {
        let mut scroll_changed = None;
        let generation = {
            let mut term = pty.term.lock().unwrap();
            let before = terminal_scroll_position(&term);
            let normalized = term.vt_write_with_normalized(replay);
            let output = match normalized {
                Cow::Borrowed(_) => replay.to_vec(),
                Cow::Owned(normalized) => normalized,
            };
            pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
            pty.broadcast_attach_output(&output);
            let after = terminal_scroll_position(&term);
            if before != after {
                scroll_changed = Some(after);
                broadcast_render_scroll_locked(pty, after);
            }
            pty.stream_progress.notify();
            pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
        };
        pty.request_frame(generation);
        if let Some((offset, at_bottom)) = scroll_changed
            && let Some(mux) = mux.upgrade()
        {
            // Drops a position output deferred, so it cannot follow this one.
            pty.frame_requests.publish_scroll_now(&mux, surface.id, offset, at_bottom);
        }
    }
}
