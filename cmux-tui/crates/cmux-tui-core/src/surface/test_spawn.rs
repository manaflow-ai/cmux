//! Test constructors for surfaces: local PTY surfaces over in-memory or real
//! test PTYs, with optional resource identity, cell pixels and lifetime.

use super::*;

impl Surface {
    #[cfg(test)]
    pub(crate) fn spawn_for_test(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
        let cell_pixels =
            mux.upgrade().map(|mux| mux.cell_pixel_creation_size()).unwrap_or((8, 16));
        Self::spawn_for_test_with_resource_identity_at_cell_pixels(
            id,
            opts,
            mux,
            Some(TabResourceIdentity::terminal(None)?),
            cell_pixels,
        )
    }

    #[cfg(test)]
    pub(crate) fn spawn_for_test_at_cell_pixels(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        Self::spawn_for_test_with_resource_identity_at_cell_pixels(
            id,
            opts,
            mux,
            Some(TabResourceIdentity::terminal(None)?),
            cell_pixels,
        )
    }

    #[cfg(test)]
    pub(crate) fn spawn_for_test_with_resource_identity(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        resource_identity: Option<TabResourceIdentity>,
    ) -> anyhow::Result<Arc<Surface>> {
        let cell_pixels =
            mux.upgrade().map(|mux| mux.cell_pixel_creation_size()).unwrap_or((8, 16));
        Self::spawn_for_test_with_resource_identity_at_cell_pixels(
            id,
            opts,
            mux,
            resource_identity,
            cell_pixels,
        )
    }

    #[cfg(test)]
    pub(crate) fn spawn_for_test_with_resource_identity_at_cell_pixels(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        resource_identity: Option<TabResourceIdentity>,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        Self::spawn_for_test_with_lifetime_at_cell_pixels(
            id,
            opts,
            mux,
            resource_identity,
            PtyLifetime::SessionOwned,
            cell_pixels,
        )
    }

    #[cfg(test)]
    pub(crate) fn spawn_auxiliary_for_test_at_cell_pixels(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        Self::spawn_for_test_with_lifetime_at_cell_pixels(
            id,
            opts,
            mux,
            None,
            PtyLifetime::DaemonOwned,
            cell_pixels,
        )
    }

    #[cfg(test)]
    pub(super) fn spawn_for_test_with_lifetime_at_cell_pixels(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        resource_identity: Option<TabResourceIdentity>,
        lifetime: PtyLifetime,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        let terminal_public_id = resource_identity
            .as_ref()
            .map(|identity| {
                terminal_public_id_from_resource_identity(
                    identity,
                    "terminal surface cannot use a browser resource identity",
                )
            })
            .transpose()?;
        let kitty_reservation =
            mux.upgrade().map(|mux| mux.reserve_kitty_image_surface(id)).transpose()?;
        let initial_kitty_limits = kitty_reservation
            .as_ref()
            .map(crate::mux::KittyImageBudgetReservation::initial_limits)
            .unwrap_or_default();
        let initial_geometry = PtyGeometry {
            cols: opts.cols,
            rows: opts.rows,
            cell_width: cell_pixels.0,
            cell_height: cell_pixels.1,
        };
        let initial_pty_size = initial_geometry.pty_size()?;
        let callbacks = Callbacks {
            on_bell: Some(Box::new({
                let mux = mux.clone();
                move || {
                    if let Some(mux) = mux.upgrade() {
                        mux.emit_terminal_bell(id);
                    }
                }
            })),
            ..Callbacks::default()
        };

        let mut term = Terminal::new(opts.cols, opts.rows, opts.scrollback, callbacks)?;
        term.resize(opts.cols, opts.rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))?;
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
        let (frame_requests, _frame_rx) = sync_channel(1);
        let test_master_control = Arc::new(TestMasterPtyControl::default());
        let frame_producer_before_upgrade = Arc::new(Mutex::new(None));

        let surface = Arc::new(Surface::Pty(PtySurface {
            meta: SurfaceMeta {
                id,
                resource_identity,
                name: Mutex::new(None),
                selection: Mutex::new(None),
            },
            terminal: Arc::new(PtyTerminalRuntime {
                event_surface_id: id,
                terminal_public_id: terminal_public_id.map(Arc::new),
                journal_generation: Arc::from(format!("test-{id}")),
                journal_capture_supported: true,
                journal_capture_epoch: AtomicU64::new(0),
                journal_capture_gate: Mutex::new(()),
                journal_capture_idle: Condvar::new(),
                journal_capture_open: AtomicBool::new(true),
                journal_capture_reserved: AtomicBool::new(false),
                journal_capture_active: AtomicBool::new(false),
                reader_thread: Mutex::new(None),
                reader_completion: Arc::new(ReaderCompletion::default()),
                reaper_thread: Mutex::new(None),
                reaper_completion: Arc::new(ReaderCompletion::default()),
                term: RankedMutex::new(LockRank::Terminal, "pty.term", Box::new(term)),
                stream_progress: Box::new(TerminalStreamProgress::default()),
                terminal_metadata: Mutex::new(Default::default()),
                command_tracker: Mutex::new(Default::default()),
                mouse_encoders: RankedMutex::new(
                    LockRank::Leaf,
                    "pty.mouse_encoders",
                    Box::new(mouse_encoders),
                ),
                runtime: RankedMutex::new(
                    LockRank::Runtime,
                    "pty.runtime",
                    PtyRuntime::Local {
                        writer: Box::new(std::io::sink()),
                        master: Some(Box::new(TestMasterPty {
                            size: Mutex::new(initial_pty_size),
                            control: test_master_control.clone(),
                        })),
                        killer: Box::new(TestChildKiller),
                    },
                ),
                lifetime,
                supports_clear_history_key_fallback: AtomicBool::new(false),
                host_identity: None,
                #[cfg(unix)]
                pending_host_binding: Mutex::new(None),
                #[cfg(unix)]
                host_exit_record_path: None,
                pid: Some(id as u32),
                command: opts.command.unwrap_or_else(|| vec![platform::default_shell()]),
                cwd: opts.cwd,
                exit: Mutex::new(None),
                local_pty_drained: AtomicBool::new(false),
                exit_notified: AtomicBool::new(false),
                dead: AtomicBool::new(false),
                owner_detaching: AtomicBool::new(false),
                host_connection_state: AtomicU8::new(TerminalHostConnectionState::Connected as u8),
                dirty: AtomicBool::new(false),
                title: RankedMutex::new(LockRank::Leaf, "pty.title", String::new()),
                pwd: Mutex::new(None),
                published_directory: Mutex::new(PublishedDirectory::Reported(None)),
                directory_pending: AtomicBool::new(true),
                directory_reported: AtomicBool::new(false),
                geometry: RankedMutex::new(LockRank::Geometry, "pty.geometry", initial_geometry),
                kitty_graphics_limits: Box::new(Mutex::new(initial_kitty_limits)),
                geometry_test_hook: Mutex::new(None),
                deferred_cell_pixel_ack_test_hook: Mutex::new(None),
                test_master_control: Some(test_master_control),
                vt_replay_builds: AtomicUsize::new(0),
                mux,
                taps: RankedMutex::new(LockRank::AttachTaps, "pty.taps", Vec::new()),
                attach_colors_pending: AtomicBool::new(false),
                attach_colors_force_pending: AtomicBool::new(false),
                snapshot_position: Default::default(),
                last_attach_colors: RankedMutex::new(
                    LockRank::Leaf,
                    "pty.last_attach_colors",
                    None,
                ),
                render: Arc::new(RankedMutex::new(
                    LockRank::Leaf,
                    "pty.render",
                    RenderHub {
                        state: Box::new(render_state),
                        built_generation: 0,
                        latest: None,
                        initial_graphics: None,
                        final_initial: None,
                        taps: Vec::new(),
                    },
                )),
                render_generation: AtomicU64::new(1),
                frame_requests,
                frame_producer_before_upgrade,
            }),
            viewport: Mutex::new(TerminalViewportState::default()),
        }));
        if let Some(reservation) = kitty_reservation {
            reservation.commit(&surface, initial_kitty_limits)?;
        }
        Ok(surface)
    }
}
