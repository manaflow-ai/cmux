//! Surfaces built from existing terminals: adopting a running terminal host, and
//! placeholders for terminals whose host already exited.

use super::*;

impl Surface {
    #[cfg(unix)]
    pub(crate) fn adopt_hosted(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        record: crate::terminal_host_runtime::TerminalHostRecord,
        record_path: PathBuf,
    ) -> anyhow::Result<Arc<Surface>> {
        Self::adopt_hosted_with_resource_identity(
            id,
            opts,
            mux,
            record,
            record_path,
            TabResourceIdentity::terminal(None)?,
        )
    }

    #[cfg(unix)]
    pub(crate) fn adopt_hosted_with_resource_identity(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        record: crate::terminal_host_runtime::TerminalHostRecord,
        record_path: PathBuf,
        resource_identity: TabResourceIdentity,
    ) -> anyhow::Result<Arc<Surface>> {
        let terminal_public_id = terminal_public_id_from_resource_identity(
            &resource_identity,
            "hosted terminal cannot use a browser resource identity",
        )?;
        let kitty_reservation =
            mux.upgrade().map(|mux| mux.reserve_kitty_image_surface(id)).transpose()?;
        let initial_kitty_limits = kitty_reservation
            .as_ref()
            .map(crate::mux::KittyImageBudgetReservation::initial_limits)
            .unwrap_or_default();
        let attachment = crate::terminal_host_runtime::adopt_terminal_host_with_kitty_limits(
            record,
            record_path,
            initial_kitty_limits,
        )?;
        Self::spawn_hosted(
            id,
            opts,
            mux,
            HostedSurfaceLaunch {
                attachment,
                kitty_reservation,
                terminate_on_error: false,
                defer_launch_activation: false,
                lifetime: PtyLifetime::SessionOwned,
                terminal_public_id: Some(terminal_public_id),
                resource_identity: Some(resource_identity),
            },
        )
    }

    #[cfg(unix)]
    pub(crate) fn adopt_hosted_with_terminal_public_id(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        record: crate::terminal_host_runtime::TerminalHostRecord,
        record_path: PathBuf,
        terminal_public_id: TerminalPublicId,
    ) -> anyhow::Result<Arc<Surface>> {
        let kitty_reservation =
            mux.upgrade().map(|mux| mux.reserve_kitty_image_surface(id)).transpose()?;
        let initial_kitty_limits = kitty_reservation
            .as_ref()
            .map(crate::mux::KittyImageBudgetReservation::initial_limits)
            .unwrap_or_default();
        let attachment = crate::terminal_host_runtime::adopt_terminal_host_with_kitty_limits(
            record,
            record_path,
            initial_kitty_limits,
        )?;
        Self::spawn_hosted(
            id,
            opts,
            mux,
            HostedSurfaceLaunch {
                attachment,
                kitty_reservation,
                terminate_on_error: false,
                defer_launch_activation: false,
                lifetime: PtyLifetime::SessionOwned,
                terminal_public_id: Some(terminal_public_id),
                resource_identity: None,
            },
        )
    }

    /// Construct a dead hosted surface for lifecycle tests without inventing
    /// a live host connection. Production keeps exit receipts in the registry.
    #[cfg(all(unix, test))]
    pub(crate) fn exited_terminal_placeholder(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        identity: crate::terminal_host_runtime::TerminalHostIdentity,
    ) -> anyhow::Result<Arc<Surface>> {
        Self::exited_terminal_placeholder_with_resource_identity(
            id,
            opts,
            mux,
            identity,
            TabResourceIdentity::terminal(None)?,
        )
    }

    #[cfg(all(unix, test))]
    pub(crate) fn exited_terminal_placeholder_with_resource_identity(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        identity: crate::terminal_host_runtime::TerminalHostIdentity,
        resource_identity: TabResourceIdentity,
    ) -> anyhow::Result<Arc<Surface>> {
        let terminal_public_id = terminal_public_id_from_resource_identity(
            &resource_identity,
            "exited terminal cannot use a browser resource identity",
        )?;
        Self::exited_terminal_placeholder_with_identities(
            id,
            opts,
            mux,
            identity,
            terminal_public_id,
            Some(resource_identity),
        )
    }

    #[cfg(all(unix, test))]
    pub(crate) fn exited_terminal_placeholder_with_terminal_public_id(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        identity: crate::terminal_host_runtime::TerminalHostIdentity,
        terminal_public_id: TerminalPublicId,
    ) -> anyhow::Result<Arc<Surface>> {
        Self::exited_terminal_placeholder_with_identities(
            id,
            opts,
            mux,
            identity,
            terminal_public_id,
            None,
        )
    }

    #[cfg(all(unix, test))]
    pub(super) fn exited_terminal_placeholder_with_identities(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        identity: crate::terminal_host_runtime::TerminalHostIdentity,
        terminal_public_id: TerminalPublicId,
        resource_identity: Option<TabResourceIdentity>,
    ) -> anyhow::Result<Arc<Surface>> {
        let journal_generation = Arc::from(identity.incarnation.clone());
        let initial_kitty_limits = KittyGraphicsLimits::disabled();
        let title_changed = Arc::new(AtomicBool::new(false));
        let terminal_metadata = crate::terminal_metadata::TerminalMetadata::default();
        let records = terminal_metadata.program_status();
        let callbacks = hosted_terminal_callbacks(&PendingBells::default(), title_changed, records);
        let (cols, rows) = (opts.cols.max(1), opts.rows.max(1));
        let cell_pixels =
            mux.upgrade().map(|mux| mux.cell_pixel_creation_size()).unwrap_or((8, 16));
        let mut term = Terminal::new(cols, rows, opts.scrollback, callbacks)?;
        term.resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))?;
        term.set_kitty_graphics_limits(initial_kitty_limits)?;
        if let Some(mux) = mux.upgrade() {
            let colors = mux.default_colors();
            term.replace_default_colors(colors.fg, colors.bg, colors.cursor);
            term.set_default_palette(&colors.palette);
            replace_ghostty_cursor_defaults(&mut term, colors);
        }
        let mut mouse_encoders = MouseEncoders::new()?;
        mouse_encoders.sync_from_terminal(&term);
        let render_state = RenderState::new()?;
        let (frame_requests, frame_rx) = sync_channel(1);
        #[cfg(test)]
        let frame_producer_before_upgrade = Arc::new(Mutex::new(None));
        let command = opts
            .command
            .clone()
            .filter(|command| !command.is_empty())
            .unwrap_or_else(|| vec![platform::default_shell()]);
        let surface = Arc::new(Surface::Pty(PtySurface {
            meta: SurfaceMeta {
                id,
                resource_identity,
                name: RankedMutex::new(None),
                selection: Mutex::new(None),
            },
            terminal: Arc::new(PtyTerminalRuntime {
                event_surface_id: id,
                terminal_public_id: Some(Arc::new(terminal_public_id)),
                journal_generation,
                journal_capture_supported: true,
                journal_capture_epoch: AtomicU64::new(0),
                journal_capture_gate: RankedMutex::new(()),
                journal_capture_idle: Condvar::new(),
                journal_capture_open: AtomicBool::new(true),
                journal_capture_reserved: AtomicBool::new(false),
                journal_capture_active: AtomicBool::new(false),
                reader_thread: RankedMutex::new(None),
                reader_completion: Arc::new(ReaderCompletion::default()),
                reaper_thread: RankedMutex::new(None),
                reaper_completion: Arc::new(ReaderCompletion::default()),
                term: RankedMutex::new(Box::new(term)),
                stream_progress: Box::new(TerminalStreamProgress::default()),
                terminal_metadata: RankedMutex::new(terminal_metadata),
                command_tracker: RankedMutex::new(Default::default()),
                mouse_encoders: RankedMutex::new(Box::new(mouse_encoders)),
                runtime: RankedMutex::new(PtyRuntime::ExitedHosted),
                lifetime: PtyLifetime::SessionOwned,
                supports_clear_history_key_fallback: AtomicBool::new(false),
                host_identity: Some(identity),
                pending_host_binding: RankedMutex::new(None),
                host_exit_record_path: None,
                pid: None,
                command,
                cwd: opts.cwd,
                exit: RankedMutex::new(None),
                local_pty_drained: AtomicBool::new(true),
                exit_notified: AtomicBool::new(true),
                dead: AtomicBool::new(true),
                owner_detaching: AtomicBool::new(false),
                host_connection_state: AtomicU8::new(TerminalHostConnectionState::Exited as u8),
                dirty: AtomicBool::new(true),
                title: RankedMutex::new(String::new()),
                pwd: RankedMutex::new(None),
                published_directory: RankedMutex::new(PublishedDirectory::Reported(None)),
                directory_pending: AtomicBool::new(true),
                directory_reported: AtomicBool::new(false),
                geometry: RankedMutex::new(PtyGeometry {
                    cols,
                    rows,
                    cell_width: cell_pixels.0,
                    cell_height: cell_pixels.1,
                }),
                kitty_graphics_limits: Box::new(RankedMutex::new(initial_kitty_limits)),
                kitty_limits_request: RankedMutex::new(()),
                #[cfg(test)]
                geometry_test_hook: RankedMutex::new(None),
                #[cfg(test)]
                deferred_cell_pixel_ack_test_hook: Mutex::new(None),
                #[cfg(test)]
                test_master_control: None,
                #[cfg(test)]
                vt_replay_builds: AtomicUsize::new(0),
                mux,
                taps: RankedMutex::new(Vec::new()),
                attach_colors_pending: AtomicBool::new(false),
                attach_colors_force_pending: AtomicBool::new(false),
                snapshot_position: Default::default(),
                last_attach_colors: RankedMutex::new(None),
                render: Arc::new(RankedMutex::new(RenderHub {
                    state: Box::new(render_state),
                    built_generation: 0,
                    latest: None,
                    initial_graphics: None,
                    final_initial: None,
                    taps: Vec::new(),
                })),
                render_generation: AtomicU64::new(1),
                frame_requests,
                #[cfg(test)]
                frame_producer_before_upgrade,
            }),
            viewport: RankedMutex::new(TerminalViewportState::default()),
        }));
        spawn_frame_producer(&surface, frame_rx)?;
        Ok(surface)
    }
}
