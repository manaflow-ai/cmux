//! The local runtime spawn path of a terminal surface: the parser, the
//! reader (bytes -> terminal state -> events, `local_reader`) and the end of
//! the far side (a PTY child's exit through the mux's reaper, or a wait
//! thread). A PTY child and an app's byte-backend terminal
//! (`terminal_backend`) both start here, from a [`LocalLaunch`].

use std::io::{Read, Write};
#[cfg(unix)]
use std::os::fd::BorrowedFd;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};

use cmux_pty::{ChildKiller, MasterPty};
use ghostty_vt::{Callbacks, RenderState, Terminal};

use super::terminal_runtime::{EndingTerminal, LocalReaper};
use super::*;
use crate::terminal_end::TerminalEnd;

/// How a local terminal learns that its far side ended.
pub(crate) enum LocalEnd {
    /// Blocks until the far side ended; runs on its own thread. Dropping it
    /// without a call must stop the far side.
    Wait(Box<dyn FnOnce() -> TerminalEnd + Send>),
    /// A child of this process: the mux's one reaper waits for its exit
    /// (`cmux_threads::reaper`), no thread of its own. Dropping the guard
    /// kills and reaps it.
    #[cfg(unix)]
    Child(PtyChildStartupGuard),
}

/// What the local runtime of one terminal runs on.
pub(crate) struct LocalLaunch {
    pub master: Box<dyn MasterPty + Send>,
    pub reader: Box<dyn Read + Send>,
    pub writer: Box<dyn Write + Send>,
    pub killer: Box<dyn ChildKiller + Send>,
    pub end: LocalEnd,
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
            reader,
            writer,
            killer,
            end,
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
        // Direct PTY readers wait for readiness on the owner's read loop
        // before taking the source order gate. Holder and byte-backend
        // readers are not backed by this PTY descriptor, so they keep their
        // blocking reader thread (local_reader.rs).
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
                move |bytes| pending.lock().recover_poison().extend_from_slice(bytes)
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
            parsed_sink,
        )));
        #[cfg(unix)]
        let shared_output = read_fd.map(|_| output.clone());
        let pty = PtySurface {
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
                thread_qos: cmux_threads::DesiredQos::new(crate::echo_thread::ECHO_PATH_QOS),
                reaper_thread: Mutex::new(None),
                reaper_completion: Arc::new(ReaderCompletion::default()),
                term: terminal_runtime::TerminalCell::new(Box::new(term)),
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
                        writer: LocalWriter::new(writer),
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
                host_connection_state: AtomicU8::new(TerminalHostConnectionState::Connected as u8),
                host_fallback: std::sync::OnceLock::new(),
                dirty: AtomicBool::new(false),
                title: RankedMutex::new(LockRank::Leaf, "pty.title", String::new()),
                pwd: Mutex::new(None),
                published_directory: Mutex::new(PublishedDirectory::Reported(None)),
                directory_pending: AtomicBool::new(true),
                publication_posted: AtomicBool::new(false),
                publications: Arc::default(),
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
                taps: RankedMutex::new(LockRank::AttachTaps, "pty.taps", AttachTaps::default()),
                attach_colors_pending: AtomicBool::new(false),
                attach_colors_force_pending: AtomicBool::new(false),
                last_input_flow: Default::default(),
                input_stages: Default::default(),
                input_fifo: Default::default(),
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
        };
        // The reader and reaper slots, held apart from the surface so they
        // need no `as_pty` lookup.
        let threads = pty.terminal.clone();
        let surface = Arc::new(Surface::Pty(pty));

        if let Some(reservation) = kitty_reservation
            && let Err(error) = reservation.commit(&surface, initial_kitty_limits)
        {
            surface.kill();
            return Err(error);
        }
        spawn_frame_producer(&surface)?;

        // PTY reader: pty bytes -> terminal state -> SurfaceOutput events,
        // on the owner's read loop for a direct PTY (local_reader.rs).
        let local_reader = local_reader::LocalReader::new(
            surface.clone(),
            output,
            reader,
            threads.reader_completion.clone(),
        );
        let local_reader = local_reader.start(id)?;
        *threads.reader_thread.lock().recover_poison() = Some(local_reader);

        // Child reaper: retain the native status and rendezvous with PTY EOF
        // so final output is visible before the mux observes completion.
        let reaper_completion = threads.reaper_completion.clone();
        reaper_completion.reset();
        let reaper = match end {
            LocalEnd::Wait(wait) => {
                LocalReaper::Thread(spawn_end_wait(&surface, reaper_completion, wait)?)
            }
            #[cfg(unix)]
            LocalEnd::Child(child) => {
                watch_child_end(&surface, reaper_completion, child)?;
                LocalReaper::Watched
            }
        };
        *threads.reaper_thread.lock().recover_poison() = Some(reaper);

        Ok(surface)
    }
}

/// Records the far side's `end`, then publishes the exit once the reader has
/// drained the PTY, so final output is visible before the mux observes
/// completion. `completion` is marked only after the publish, so a finished
/// reaper always means a published exit; a shutdown the publish itself
/// starts sees [`EndingTerminal`] and does not wait for it.
fn record_local_end(surface: &Arc<Surface>, end: TerminalEnd, completion: ReaderCompletionGuard) {
    let ending = EndingTerminal::enter(&completion.0);
    if let Some(pty) = surface.as_pty() {
        *pty.exit.lock().recover_poison() = Some(end);
    }
    close_local_terminal_master_after_exit(surface);
    publish_local_exit_if_ready(surface);
    drop(ending);
    drop(completion);
}

/// Runs `wait` on thread `surface-<id>-wait`. The thread keeps the surface
/// alive until the wait returns, so a deadline timeout in teardown never
/// detaches a live wait when the last external surface reference drops.
/// `completion` is the surface's reset `reaper_completion`.
fn spawn_end_wait(
    surface: &Arc<Surface>,
    completion: Arc<ReaderCompletion>,
    wait: Box<dyn FnOnce() -> TerminalEnd + Send>,
) -> anyhow::Result<std::thread::JoinHandle<()>> {
    let waited = surface.clone();
    cmux_tui_platform::qos::spawn_outside_request(
        format!("surface-{}-wait", surface.id),
        move || {
            let completion = ReaderCompletionGuard(completion);
            let end = wait();
            record_local_end(&waited, end, completion);
        },
    )
    .map_err(|error| {
        close_local_terminal_master_after_exit(surface);
        error.into()
    })
}

/// Hands the PTY child to the mux's reaper: its exit status is recorded on a
/// work item, with no thread of this terminal waiting. The watch keeps the
/// surface alive until the child ends, as a wait thread would. Without a
/// mux (it is being dropped), or when nothing can wait for the child, the
/// launch fails and dropping `child` kills and reaps it.
/// `completion` is the surface's reset `reaper_completion`.
#[cfg(unix)]
fn watch_child_end(
    surface: &Arc<Surface>,
    completion: Arc<ReaderCompletion>,
    mut child: PtyChildStartupGuard,
) -> anyhow::Result<()> {
    let owner = surface.as_pty().and_then(|pty| pty.mux.upgrade());
    let (Some(owner), Some(pid)) = (owner, child.process_id()) else {
        close_local_terminal_master_after_exit(surface);
        anyhow::bail!("the terminal's child has no reaper: its mux is gone");
    };
    let watched = surface.clone();
    let on_exit: cmux_threads::reaper::OnExit = Box::new(move |status| {
        let completion = ReaderCompletionGuard(completion);
        let end = TerminalEnd::ProcessEnded(child.reaped(status));
        record_local_end(&watched, end, completion);
    });
    if let Err(unwatched) = owner.reaper.watch(pid, on_exit) {
        close_local_terminal_master_after_exit(surface);
        // `into_error` drops the guard uncalled: the child is killed and
        // reaped here, as when a wait thread did not start.
        return Err(
            anyhow::Error::new(unwatched.into_error()).context("watch the terminal's child")
        );
    }
    Ok(())
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
            end: LocalEnd::Wait(Box::new(move || wait_end(&side))),
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
