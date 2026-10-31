//! The local runtime spawn path of a terminal surface: the parser, the
//! reader thread (bytes -> terminal state -> events) and the reaper thread
//! (the end of the far side). A PTY child and an app's byte-backend
//! terminal (`terminal_backend`) both start here, from a [`LocalLaunch`].

use std::io::{Read, Write};
#[cfg(unix)]
use std::os::fd::{AsRawFd, BorrowedFd, RawFd};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::Duration;

use cmux_pty::{ChildKiller, MasterPty};
use ghostty_vt::{Callbacks, RenderState, Terminal};

use super::*;
use crate::terminal_end::TerminalEnd;

#[cfg(unix)]
fn wait_for_local_output(fd: RawFd, wake: &mut UnixStream) -> std::io::Result<bool> {
    let mut descriptors = [
        libc::pollfd { fd, events: libc::POLLIN, revents: 0 },
        libc::pollfd { fd: wake.as_raw_fd(), events: libc::POLLIN, revents: 0 },
    ];
    loop {
        // SAFETY: both descriptors are initialized and owned by the reader.
        let result = unsafe { libc::poll(descriptors.as_mut_ptr(), 2, -1) };
        if result >= 0 {
            let mut bytes = [0u8; 64];
            if descriptors[1].revents != 0 {
                let _ = wake.read(&mut bytes);
            }
            return Ok(descriptors[0].revents != 0);
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

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
    /// The holder terminal this launch runs on, if any (`holder_runtime`).
    #[cfg(unix)]
    pub holder: Option<Arc<crate::holder_runtime::HolderTerminal>>,
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
    /// The registry identity a holder terminal carries; `None` otherwise.
    pub host_identity: Option<crate::terminal_host_runtime::TerminalHostIdentity>,
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
            host_identity,
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
            #[cfg(unix)]
            holder,
        } = launch;
        // A holder terminal's reader confirms each chunk it parsed under the
        // terminal lock, so a hand-off to a new holder after a holder crash
        // reads the screen and what is still unparsed at one instant.
        #[cfg(unix)]
        let parsed_sink = holder.as_ref().map(|terminal| terminal.sink.clone());
        // Direct PTY readers can wait for readiness before taking the source
        // order gate. Holder and byte-backend readers are not backed by this
        // PTY descriptor, so they retain their existing blocking path.
        #[cfg(unix)]
        let read_fd = holder.is_none().then(|| master.as_raw_fd()).flatten();
        #[cfg(unix)]
        let read_descriptor = read_fd
            .map(|fd| {
                // SAFETY: master still owns fd here. The duplicate remains owned
                // by LocalOutput until its reader has finished.
                unsafe { BorrowedFd::borrow_raw(fd) }.try_clone_to_owned()
            })
            .transpose()?;
        #[cfg(unix)]
        let (wake_writer, mut wake_reader) = if read_fd.is_some() {
            let (writer, reader) = UnixStream::pair()?;
            writer.set_nonblocking(true)?;
            reader.set_nonblocking(true)?;
            (Some(writer), Some(reader))
        } else {
            (None, None)
        };
        // Query responses generated while parsing pty output are queued
        // here and flushed to the pty after each vt_write (the callback
        // runs under the terminal lock; writing to the pty from inside it
        // is fine, but keeping it queued makes the locking obvious).
        let pending_responses: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));
        let title_changed = Arc::new(AtomicBool::new(false));
        let pending_bells = PendingBells::default();
        let terminal_metadata = crate::terminal_metadata::TerminalMetadata::default();

        let callbacks = Callbacks {
            on_pty_write: Some(Box::new({
                let pending = pending_responses.clone();
                move |bytes| pending.lock().unwrap().extend_from_slice(bytes)
            })),
            on_title_changed: Some(Box::new({
                let flag = title_changed.clone();
                move || flag.store(true, Ordering::Relaxed)
            })),
            // Counted only: the reader emits after it releases the terminal lock.
            on_bell: Some(pending_bells.callback()),
            on_clipboard_read: None,
            // The daemon owns this terminal's OSC 7501 records, and its
            // parser answers the support query through `on_pty_write`.
            on_program_status: Some(crate::program_status::sink(
                terminal_metadata.program_status(),
            )),
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
        let frame_requests = frame_producer::FrameRequests::new();
        #[cfg(test)]
        let frame_producer_before_upgrade = Arc::new(Mutex::new(None));
        let output = Arc::new(Mutex::new(local_output::LocalOutput::new(
            title_changed,
            pending_responses,
            pending_bells,
            #[cfg(unix)]
            read_descriptor,
            #[cfg(unix)]
            wake_writer,
            #[cfg(unix)]
            parsed_sink,
        )));
        #[cfg(unix)]
        let shared_output = read_fd.map(|_| output.clone());
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
                #[cfg(unix)]
                local_output: shared_output,
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
                terminal_metadata: Mutex::new(terminal_metadata),
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
                        writer,
                        master: Some(master),
                        killer,
                        #[cfg(unix)]
                        holder,
                    },
                ),
                lifetime,
                supports_clear_history_key_fallback: AtomicBool::new(
                    supports_clear_history_key_fallback,
                ),
                host_identity,
                #[cfg(any(unix, windows))]
                pending_host_binding: Mutex::new(None),
                #[cfg(any(unix, windows))]
                host_exit_record_path: None,
                pid,
                command: argv,
                cwd,
                exit: Mutex::new(None),
                local_pty_drained: AtomicBool::new(false),
                exit_notified: AtomicBool::new(false),
                dead: AtomicBool::new(false),
                owner_detaching: AtomicBool::new(false),
                recover_requested: AtomicBool::new(false),
                host_connection_state: AtomicU8::new(TerminalHostConnectionState::Connected as u8),
                host_fallback: std::sync::OnceLock::new(),
                dirty: AtomicBool::new(false),
                title: RankedMutex::new(LockRank::Leaf, "pty.title", String::new()),
                pwd: Mutex::new(None),
                published_directory: Mutex::new(PublishedDirectory::Reported(None)),
                directory_pending: AtomicBool::new(true),
                directory_reported: AtomicBool::new(false),
                geometry: RankedMutex::new(LockRank::Geometry, "pty.geometry", initial_geometry),
                kitty_graphics_limits: Box::new(RankedMutex::new(
                    LockRank::KittyLimits,
                    "pty.kitty_graphics_limits",
                    initial_kitty_limits,
                )),
                kitty_limits_request: RankedMutex::new(
                    LockRank::KittyLimitsRequest,
                    "pty.kitty_limits_request",
                    (),
                ),
                #[cfg(test)]
                geometry_test_hook: Mutex::new(None),
                #[cfg(test)]
                deferred_cell_pixel_ack_test_hook: Mutex::new(None),
                #[cfg(test)]
                test_master_control: None,
                #[cfg(test)]
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
        spawn_frame_producer(&surface)?;

        // PTY reader: pty bytes -> terminal state -> SurfaceOutput events.
        let reader_thread =
            std::thread::Builder::new().name(format!("surface-{id}-reader")).spawn({
                let surface = surface.clone();
                #[cfg(unix)]
                let read_fd = output
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .descriptor
                    .as_ref()
                    .map(AsRawFd::as_raw_fd);
                move || {
                    let _reader_completion = ReaderCompletionGuard(
                        surface
                            .as_pty()
                            .expect("local PTY reader owns a PTY surface")
                            .reader_completion
                            .clone(),
                    );
                    let mut would_block = crate::backoff::Backoff::new(
                        Duration::from_millis(1),
                        Duration::from_millis(50),
                    );
                    let publisher = output
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .publisher();
                    loop {
                        let pty = surface.as_pty().expect("surface reader got non-pty surface");
                        #[cfg(unix)]
                        let ready = if let (Some(fd), Some(wake)) = (read_fd, wake_reader.as_mut())
                        {
                            match wait_for_local_output(fd, wake) {
                                Ok(ready) => ready,
                                Err(_) => break,
                            }
                        } else {
                            true
                        };
                        #[cfg(not(unix))]
                        let ready = true;
                        #[cfg(all(test, unix))]
                        if ready {
                            pty.run_geometry_test_hook(PtyGeometryTestStep::LocalReaderReady);
                        }
                        let (result, events) = {
                            let mut output =
                                output.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                            // A resize may have drained the readiness that woke
                            // us. Recheck under the same parser lock before a
                            // blocking read, then parse on that same boundary.
                            #[cfg(unix)]
                            let ready = ready
                                && read_fd.is_none_or(|fd| {
                                    local_output::readable(fd, 0).unwrap_or(false)
                                });
                            let result = if ready {
                                output.read(pty, |buf| reader.read(buf)).map(Some)
                            } else {
                                Ok(None)
                            };
                            let events = output.take_pending();
                            (result, events)
                        };
                        publisher.publish(&surface, events);
                        match result {
                            Ok(Some(0)) => break,
                            Ok(_) => would_block.reset(),
                            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {
                                continue;
                            }
                            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                                // No parser or source lock is held across backoff.
                                would_block.sleep();
                            }
                            Err(_) => break,
                        }
                    }
                    #[cfg(unix)]
                    {
                        let mut output =
                            output.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                        // Dead surfaces can remain visible. Do not keep their
                        // duplicated PTY descriptor alive with that placement.
                        output.finish();
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
    /// Unix only, like `terminal_backend`.
    #[cfg(unix)]
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
        let master = BackendMaster::new(side.clone(), initial_geometry.pty_size());
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
            resource_identity: None,
            lifetime: PtyLifetime::DaemonOwned,
            cell_pixels,
            initial_geometry,
            host_identity: None,
        };
        Self::spawn_local(spawn, launch)
    }
}
