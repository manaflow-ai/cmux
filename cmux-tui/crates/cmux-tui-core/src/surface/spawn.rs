//! The local runtime spawn path of a terminal surface: the parser, the
//! reader thread (bytes -> terminal state -> events) and the reaper thread
//! (the end of the far side). A PTY child and an app's byte-backend
//! terminal (`terminal_backend`) both start here, from a [`LocalLaunch`].

use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};
use std::sync::mpsc::sync_channel;
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::Duration;

use cmux_pty::{ChildKiller, MasterPty};
use ghostty_vt::{Callbacks, RenderState, Terminal};

use super::*;
use crate::terminal_end::TerminalEnd;

/// What the local runtime of one terminal runs on.
pub(crate) struct LocalLaunch {
    pub master: Box<dyn MasterPty + Send>,
    pub reader: Box<dyn Read + Send>,
    pub writer: Box<dyn Write + Send>,
    pub killer: Box<dyn ChildKiller + Send>,
    /// Blocks until the far side ended; runs on the reaper thread. Dropping
    /// it without a call must stop the far side (the PTY guard kills).
    pub wait: Box<dyn FnOnce() -> TerminalEnd + Send>,
    pub pid: Option<u32>,
    pub command: Vec<String>,
    pub cwd: Option<String>,
    pub supports_clear_history_key_fallback: bool,
}

/// The surface-side inputs of [`Surface::spawn_local`].
pub(crate) struct LocalSpawn {
    pub id: SurfaceId,
    pub opts: SurfaceOptions,
    pub mux: Weak<Mux>,
    pub terminal_public_id: Option<TerminalPublicId>,
    pub kitty_reservation: Option<crate::mux::KittyImageBudgetReservation>,
    pub initial_kitty_limits: KittyGraphicsLimits,
    pub resource_identity: Option<TabResourceIdentity>,
    pub lifetime: PtyLifetime,
    pub cell_pixels: (u16, u16),
    pub initial_geometry: PtyGeometry,
}

impl Surface {
    /// Builds a local-runtime terminal surface on `launch` and starts its
    /// reader and reaper threads.
    pub(crate) fn spawn_local(
        spawn: LocalSpawn,
        launch: LocalLaunch,
    ) -> anyhow::Result<Arc<Surface>> {
        let LocalSpawn {
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
        } = spawn;
        let LocalLaunch {
            master,
            mut reader,
            writer,
            killer,
            wait,
            pid,
            command: argv,
            cwd,
            supports_clear_history_key_fallback,
        } = launch;
        // Query responses generated while parsing pty output are queued
        // here and flushed to the pty after each vt_write (the callback
        // runs under the terminal lock; writing to the pty from inside it
        // is fine, but keeping it queued makes the locking obvious).
        let pending_responses: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));
        let title_changed = Arc::new(AtomicBool::new(false));

        let callbacks = Callbacks {
            on_pty_write: Some(Box::new({
                let pending = pending_responses.clone();
                move |bytes| pending.lock().unwrap().extend_from_slice(bytes)
            })),
            on_title_changed: Some(Box::new({
                let flag = title_changed.clone();
                move || flag.store(true, Ordering::Relaxed)
            })),
            on_bell: Some(Box::new({
                let mux = mux.clone();
                move || {
                    if let Some(mux) = mux.upgrade() {
                        mux.emit_terminal_bell(id);
                    }
                }
            })),
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
        let (frame_requests, frame_rx) = sync_channel(1);
        #[cfg(test)]
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
                journal_generation: Arc::from(format!(
                    "local-{}",
                    crate::workspace_registry::new_uuid_v4()
                )),
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
                term: Mutex::new(Box::new(term)),
                stream_progress: Box::new(TerminalStreamProgress::default()),
                terminal_metadata: Mutex::new(Default::default()),
                command_tracker: Mutex::new(Default::default()),
                mouse_encoders: Mutex::new(Box::new(mouse_encoders)),
                runtime: Mutex::new(PtyRuntime::Local { writer, master: Some(master), killer }),
                lifetime,
                supports_clear_history_key_fallback: AtomicBool::new(
                    supports_clear_history_key_fallback,
                ),
                host_identity: None,
                #[cfg(unix)]
                pending_host_binding: Mutex::new(None),
                #[cfg(unix)]
                host_exit_record_path: None,
                pid,
                command: argv,
                cwd,
                exit: Mutex::new(None),
                local_pty_drained: AtomicBool::new(false),
                exit_notified: AtomicBool::new(false),
                dead: AtomicBool::new(false),
                owner_detaching: AtomicBool::new(false),
                host_connection_state: AtomicU8::new(TerminalHostConnectionState::Connected as u8),
                dirty: AtomicBool::new(false),
                title: Mutex::new(String::new()),
                pwd: Mutex::new(None),
                published_directory: Mutex::new(PublishedDirectory::Reported(None)),
                directory_pending: AtomicBool::new(true),
                directory_reported: AtomicBool::new(false),
                geometry: Mutex::new(initial_geometry),
                kitty_graphics_limits: Box::new(Mutex::new(initial_kitty_limits)),
                #[cfg(test)]
                geometry_test_hook: Mutex::new(None),
                #[cfg(test)]
                deferred_cell_pixel_ack_test_hook: Mutex::new(None),
                #[cfg(test)]
                test_master_control: None,
                #[cfg(test)]
                vt_replay_builds: AtomicUsize::new(0),
                mux: mux.clone(),
                taps: Mutex::new(Vec::new()),
                attach_colors_pending: AtomicBool::new(false),
                attach_colors_force_pending: AtomicBool::new(false),
                snapshot_position: Default::default(),
                last_attach_colors: Mutex::new(None),
                render: Arc::new(Mutex::new(RenderHub {
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
            viewport: Mutex::new(TerminalViewportState::default()),
        }));

        if let Some(reservation) = kitty_reservation
            && let Err(error) = reservation.commit(&surface, initial_kitty_limits)
        {
            surface.kill();
            return Err(error);
        }
        spawn_frame_producer(&surface, frame_rx)?;

        // PTY reader: pty bytes -> terminal state -> SurfaceOutput events.
        let reader_thread =
            std::thread::Builder::new().name(format!("surface-{id}-reader")).spawn({
                let surface = surface.clone();
                move || {
                    let _reader_completion = ReaderCompletionGuard(
                        surface
                            .as_pty()
                            .expect("local PTY reader owns a PTY surface")
                            .reader_completion
                            .clone(),
                    );
                    let mut buf = [0u8; 64 * 1024];
                    // The PTY master is blocking, so WouldBlock should not
                    // happen; if it does, retries are spaced instead of the
                    // old fixed 1 ms (1 kHz) poll.
                    let mut would_block = crate::backoff::Backoff::new(
                        Duration::from_millis(1),
                        Duration::from_millis(50),
                    );
                    loop {
                        let pty = surface.as_pty().expect("surface reader got non-pty surface");
                        let journal_target = pty.journal_target();
                        // Reserve the capture epoch before read(2). Shutdown
                        // can revoke a blocked reservation, but it cannot place
                        // its final barrier in the read-to-parser gap.
                        let mut journal_update = journal_target
                            .as_ref()
                            .and_then(|_| pty.begin_terminal_journal_update());
                        if journal_target.is_some() && journal_update.is_none() {
                            break;
                        }
                        let n = match reader.read(&mut buf) {
                            Ok(0) => break,
                            Ok(n) => {
                                would_block.reset();
                                n
                            }
                            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {
                                continue;
                            }
                            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                                would_block.sleep();
                                continue;
                            }
                            Err(_) => break,
                        };
                        let mut scroll_changed = None;
                        let terminal_notifications;
                        let finished_commands;
                        let generation = {
                            let mut term = pty.term.lock().unwrap();
                            if let Some(update) = journal_update.as_mut()
                                && !update.activate()
                            {
                                break;
                            }
                            let journal_enabled = journal_update.is_some();
                            let before = terminal_scroll_position(&term);
                            let color_revision = term.color_revision();
                            let color_reapply_revision = term.color_reapply_revision();
                            let cursor_activity = term
                                .cursor_activity()
                                .expect("valid local terminals expose cursor activity");
                            let normalized = term.vt_write_with_normalized(&buf[..n]);
                            terminal_notifications = pty.observe_terminal_output(&buf[..n]);
                            finished_commands = pty.observe_shell_marks(&mut term, || {
                                mux.upgrade()
                                    .is_some_and(|mux| mux.terminal_command_history_enabled())
                            });
                            let cursor_changed = term
                                .cursor_activity()
                                .expect("valid local terminals expose cursor activity")
                                != cursor_activity;
                            pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
                            let after = terminal_scroll_position(&term);
                            let has_attach_taps = pty.broadcast_attach_output(normalized.as_ref());
                            if has_attach_taps
                                && (term.color_revision() != color_revision || cursor_changed)
                            {
                                pty.attach_colors_pending.store(true, Ordering::Release);
                                if term.color_reapply_revision() != color_reapply_revision
                                    || cursor_changed
                                {
                                    pty.attach_colors_force_pending.store(true, Ordering::Release);
                                }
                            }
                            if title_changed.swap(false, Ordering::Relaxed) {
                                let title = term.title().unwrap_or_default();
                                *pty.title.lock().unwrap() = title.clone();
                                if let Some(mux) = mux.upgrade() {
                                    mux.emit_terminal_title(surface.id, title.into());
                                }
                            }
                            pty.record_directory(term.pwd());
                            if before != after {
                                scroll_changed = Some(after);
                                broadcast_render_scroll_locked(pty, after);
                            }
                            // Keep the terminal lock scoped to parser and observer work. A
                            // borrowed normalized frame still points into `buf`, which lives
                            // for the reader loop, so any journal allocation can happen after
                            // releasing the lock.
                            let journal_output = journal_enabled.then_some(normalized);
                            let generation =
                                pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
                            // Advance the output watermark before releasing
                            // the parser lock. Screen snapshots take the same
                            // lock, so they cannot observe this frame with the
                            // previous revision.
                            pty.stream_progress.notify();
                            (generation, journal_output)
                        };
                        let (generation, journal_output) = generation;
                        if let (Some(journal_target), Some(journal_output)) =
                            (journal_target, journal_output)
                        {
                            pty.journal_output_if_open(journal_target, journal_output.into_owned());
                        }
                        drop(journal_update);
                        surface.publish_pending_directory();
                        surface.publish_pending_progress();
                        pty.stream_progress.notify();
                        pty.request_frame(generation);
                        if let Some((offset, at_bottom)) = scroll_changed
                            && let Some(mux) = mux.upgrade()
                        {
                            mux.emit_terminal_scroll(surface.id, offset, at_bottom);
                        }
                        if !terminal_notifications.is_empty()
                            && let Some(mux) = mux.upgrade()
                        {
                            mux.post_terminal_notifications(surface.id, terminal_notifications);
                        }
                        if !finished_commands.is_empty()
                            && let Some(mux) = mux.upgrade()
                            && let Some(terminal) = surface.terminal_public_id()
                        {
                            mux.append_shell_commands(terminal.clone(), finished_commands);
                        }
                        let responses = std::mem::take(&mut *pending_responses.lock().unwrap());
                        if !responses.is_empty() {
                            let _ = surface.write_bytes(&responses);
                        }
                    }
                    if let Some(pty) = surface.as_pty() {
                        pty.publish_final_frame();
                        pty.local_pty_drained.store(true, Ordering::Release);
                    }
                    publish_local_exit_if_ready(&surface);
                }
            })?;
        *surface
            .as_pty()
            .expect("local PTY surface owns its reader")
            .reader_thread
            .lock()
            .unwrap() = Some(reader_thread);

        // Child reaper: retain the native status and rendezvous with PTY EOF
        // so final output is visible before the mux observes completion.
        let reaper_completion =
            surface.as_pty().expect("local PTY surface owns its reaper").reaper_completion.clone();
        reaper_completion.reset();
        // Keep the surface alive with the join handle until the child wait
        // completes. This prevents a deadline timeout from detaching a live
        // reaper when teardown drops the last external surface reference.
        let reaper_surface = surface.clone();
        let reaper_thread =
            match std::thread::Builder::new().name(format!("surface-{id}-wait")).spawn(move || {
                let _reaper_completion = ReaderCompletionGuard(reaper_completion);
                let end = wait();
                if let Some(pty) = reaper_surface.as_pty() {
                    *pty.exit.lock().unwrap() = Some(end);
                }
                close_local_terminal_master_after_exit(&reaper_surface);
                publish_local_exit_if_ready(&reaper_surface);
            }) {
                Ok(reaper_thread) => reaper_thread,
                Err(error) => {
                    close_local_terminal_master_after_exit(&surface);
                    return Err(error.into());
                }
            };
        *surface
            .as_pty()
            .expect("local PTY surface owns its reaper")
            .reaper_thread
            .lock()
            .unwrap() = Some(reaper_thread);

        Ok(surface)
    }
}

impl Surface {
    /// A tab-less terminal surface whose local runtime is an app's
    /// byte-backend terminal: output comes from the channel, input and
    /// resize go to the app, and the end is the channel's end. Parsing,
    /// journal, snapshots and attach are the same as for a PTY child.
    pub(crate) fn spawn_backend(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        cell_pixels: (u16, u16),
        terminal_public_id: TerminalPublicId,
        side: crate::terminal_backend::pty::BackendSide,
    ) -> anyhow::Result<Arc<Surface>> {
        use crate::terminal_backend::pty::{BackendKiller, BackendMaster, wait_end};
        let (opts, _, kitty_reservation) =
            Self::spawn_prelude(id, opts, &mux, None, KittyQuota::AtLaunch)?;
        // A catalog-owned terminal with zero views: its first projection
        // (`terminal.project`) gives it a tab.
        let terminal_public_id = Some(terminal_public_id);
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
        let master = BackendMaster::new(side.clone(), initial_geometry.pty_size()?);
        let reader = master.try_clone_reader()?;
        let writer = master.take_writer()?;
        let command = vec![side.terminal.clone()];
        let launch = LocalLaunch {
            master: Box::new(master),
            reader,
            writer,
            killer: Box::new(BackendKiller(side.clone())),
            wait: Box::new(move || wait_end(&side)),
            pid: None,
            command,
            cwd: None,
            supports_clear_history_key_fallback: false,
        };
        let spawn = LocalSpawn {
            id,
            opts,
            mux,
            terminal_public_id,
            kitty_reservation,
            initial_kitty_limits,
            resource_identity: None,
            lifetime: PtyLifetime::DaemonOwned,
            cell_pixels,
            initial_geometry,
        };
        Self::spawn_local(spawn, launch)
    }
}
