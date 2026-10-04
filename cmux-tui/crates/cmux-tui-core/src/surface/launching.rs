//! A terminal surface that exists before its host (R81 stage A,
//! `plans/cmux-next/new-tab-accept-first.md` 3.3 and 3.4).
//!
//! A `new-tab` replies after its durable accept commit, before its host is
//! ready. Until the launch job adopts the host, the tab's surface is a
//! placeholder PTY surface: an empty Ghostty grid at the launch size with the
//! terminal theme colors, whose runtime is [`PtyRuntime::Launching`]. Reads,
//! resize, rename and move work on it as on any terminal. Input goes to a
//! bounded in-memory queue ([`LAUNCH_INPUT_BUDGET_BYTES`]) and reaches the PTY
//! after Activate, before any later input. A write that does not fit is
//! refused whole ([`LaunchInputBudgetError`]); nothing is dropped silently.
//!
//! On adoption the launch job flushes the queue into the hosted surface
//! under the queue lock and marks the control `Running`, so input that still
//! reaches the placeholder is forwarded in order. Then the hosted surface,
//! built with the same surface id and tab identity, replaces the placeholder
//! in the mux state. The queue is not durable: a daemon crash loses it.

use super::*;

/// Bytes a launching terminal queues at most.
pub(crate) const LAUNCH_INPUT_BUDGET_BYTES: usize = 64 * 1024;

/// Error code of a write refused because the launch queue is full.
pub(crate) const LAUNCH_INPUT_BUDGET_CODE: &str = "terminal.launch_input_budget";

/// A write to a launching terminal that does not fit the queue. The write
/// is refused whole, so a paste is never cut in half.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct LaunchInputBudgetError {
    pub(crate) budget_bytes: usize,
    pub(crate) queued_bytes: usize,
}

impl std::fmt::Display for LaunchInputBudgetError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "{LAUNCH_INPUT_BUDGET_CODE}: the terminal is launching and its input queue holds \
             {} of {} bytes; the write was refused whole",
            self.queued_bytes, self.budget_bytes
        )
    }
}

impl std::error::Error for LaunchInputBudgetError {}

/// The machine-readable code of a launch error, for the response.
pub(crate) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<LaunchInputBudgetError>().map(|_| LAUNCH_INPUT_BUDGET_CODE.to_string())
}

/// What happened to one write to a launching terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LaunchInputDelivery {
    /// Held in the queue until the shell runs. Not durable.
    Queued,
    /// The terminal runs now; the bytes went to its host.
    Forwarded,
    /// The launch failed or was cancelled; the bytes were dropped.
    Dropped,
}

struct QueuedInput {
    bytes: Vec<u8>,
    paste: bool,
}

enum LaunchPhase {
    Launching,
    Cancelled,
    Failed,
    Running(Arc<Surface>),
}

struct LaunchState {
    phase: LaunchPhase,
    /// The creation that made this surface committed its topology, so the
    /// launch job may activate the host.
    accepted: bool,
    queued: Vec<QueuedInput>,
    queued_bytes: usize,
}

/// The launch state of one launching terminal, shared by its placeholder
/// surface and its launch job.
pub(crate) struct LaunchControl {
    terminal_id: String,
    started: Instant,
    state: Mutex<LaunchState>,
    changed: Condvar,
}

impl LaunchControl {
    pub(crate) fn new(terminal_id: String) -> Arc<Self> {
        Arc::new(Self {
            terminal_id,
            started: Instant::now(),
            state: Mutex::new(LaunchState {
                phase: LaunchPhase::Launching,
                accepted: false,
                queued: Vec::new(),
                queued_bytes: 0,
            }),
            changed: Condvar::new(),
        })
    }

    /// The terminal host id this launch reserved.
    pub(crate) fn terminal_id(&self) -> &str {
        &self.terminal_id
    }

    pub(crate) fn elapsed_ms(&self) -> u64 {
        u64::try_from(self.started.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, LaunchState> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Queue `bytes` while launching, forward them once running, drop them
    /// after a failed or cancelled launch.
    pub(crate) fn enqueue(
        &self,
        bytes: &[u8],
        paste: bool,
    ) -> Result<LaunchInputDelivery, LaunchEnqueueError> {
        let mut state = self.lock();
        match &state.phase {
            LaunchPhase::Launching => {
                if bytes.is_empty() {
                    return Ok(LaunchInputDelivery::Queued);
                }
                let queued_bytes = state.queued_bytes;
                if queued_bytes.saturating_add(bytes.len()) > LAUNCH_INPUT_BUDGET_BYTES {
                    return Err(LaunchEnqueueError::Budget(LaunchInputBudgetError {
                        budget_bytes: LAUNCH_INPUT_BUDGET_BYTES,
                        queued_bytes,
                    }));
                }
                state.queued_bytes += bytes.len();
                state.queued.push(QueuedInput { bytes: bytes.to_vec(), paste });
                Ok(LaunchInputDelivery::Queued)
            }
            // Written under the queue lock, so it follows every queued byte.
            LaunchPhase::Running(hosted) => {
                let written =
                    if paste { hosted.write_paste(bytes) } else { hosted.write_bytes(bytes) };
                written.map(|()| LaunchInputDelivery::Forwarded).map_err(LaunchEnqueueError::Io)
            }
            LaunchPhase::Failed | LaunchPhase::Cancelled => Ok(LaunchInputDelivery::Dropped),
        }
    }

    /// The creation committed: the launch job may run the host.
    pub(crate) fn mark_accepted(&self) {
        self.lock().accepted = true;
        self.changed.notify_all();
    }

    /// Wait until the creation committed (true) or the launch was cancelled
    /// or `timeout` passed (false).
    pub(crate) fn wait_accepted(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut state = self.lock();
        loop {
            if !matches!(state.phase, LaunchPhase::Launching) {
                return false;
            }
            if state.accepted {
                return true;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            state = self
                .changed
                .wait_timeout(state, remaining)
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .0;
        }
    }

    pub(crate) fn is_cancelled(&self) -> bool {
        matches!(self.lock().phase, LaunchPhase::Cancelled)
    }

    /// Cancel a launch that has not adopted its host. Returns the hosted
    /// surface when the launch already runs, so a close can end it.
    pub(crate) fn cancel(&self) -> Option<Arc<Surface>> {
        let mut state = self.lock();
        match &state.phase {
            LaunchPhase::Launching => {
                state.phase = LaunchPhase::Cancelled;
                state.queued.clear();
                state.queued_bytes = 0;
                drop(state);
                self.changed.notify_all();
                None
            }
            LaunchPhase::Running(hosted) => Some(hosted.clone()),
            LaunchPhase::Failed | LaunchPhase::Cancelled => None,
        }
    }

    /// Flush the queue into the activated `hosted` surface and forward every
    /// later write to it. False when the launch was cancelled meanwhile.
    pub(crate) fn adopt(&self, hosted: &Arc<Surface>) -> bool {
        let mut state = self.lock();
        if !matches!(state.phase, LaunchPhase::Launching) {
            return false;
        }
        for input in std::mem::take(&mut state.queued) {
            let written = if input.paste {
                hosted.write_paste(&input.bytes)
            } else {
                hosted.write_bytes(&input.bytes)
            };
            if let Err(error) = written {
                eprintln!(
                    "cmux-tui: terminal {} lost queued launch input: {error}",
                    self.terminal_id
                );
                break;
            }
        }
        state.queued_bytes = 0;
        state.phase = LaunchPhase::Running(hosted.clone());
        drop(state);
        self.changed.notify_all();
        true
    }

    /// The launch failed: keep the queued bytes for the caller (R5) and drop
    /// later input. `None` when the launch was cancelled meanwhile.
    pub(crate) fn fail(&self) -> Option<Vec<u8>> {
        let mut state = self.lock();
        if !matches!(state.phase, LaunchPhase::Launching) {
            return None;
        }
        let kept = std::mem::take(&mut state.queued)
            .into_iter()
            .flat_map(|input| input.bytes)
            .collect::<Vec<_>>();
        state.queued_bytes = 0;
        state.phase = LaunchPhase::Failed;
        drop(state);
        self.changed.notify_all();
        Some(kept)
    }

    /// Wait until the launch settled or `timeout` passed. Returns the hosted
    /// surface when the terminal runs.
    pub(crate) fn wait_settled(&self, timeout: Duration) -> Option<Arc<Surface>> {
        let deadline = Instant::now() + timeout;
        let mut state = self.lock();
        loop {
            match &state.phase {
                LaunchPhase::Running(hosted) => return Some(hosted.clone()),
                LaunchPhase::Failed | LaunchPhase::Cancelled => return None,
                LaunchPhase::Launching => {}
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return None;
            }
            state = self
                .changed
                .wait_timeout(state, remaining)
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .0;
        }
    }
}

/// Why a write to a launching terminal did not go through.
#[derive(Debug)]
pub(crate) enum LaunchEnqueueError {
    Budget(LaunchInputBudgetError),
    Io(std::io::Error),
}

impl From<LaunchEnqueueError> for std::io::Error {
    fn from(error: LaunchEnqueueError) -> Self {
        match error {
            LaunchEnqueueError::Budget(error) => std::io::Error::other(error),
            LaunchEnqueueError::Io(error) => error,
        }
    }
}

impl From<LaunchEnqueueError> for anyhow::Error {
    fn from(error: LaunchEnqueueError) -> Self {
        match error {
            LaunchEnqueueError::Budget(error) => anyhow::Error::new(error),
            LaunchEnqueueError::Io(error) => anyhow::Error::new(error),
        }
    }
}

/// The runtime and liveness of a placeholder surface.
struct PlaceholderRuntime {
    runtime: PtyRuntime,
    host_identity: Option<crate::terminal_host_runtime::TerminalHostIdentity>,
    journal_generation: Arc<str>,
    dead: bool,
}

impl Surface {
    /// The placeholder surface of a launching terminal: an empty grid with
    /// the tab's surface id and identities, whose input goes to `control`.
    pub(crate) fn launching_placeholder(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        resource_identity: TabResourceIdentity,
        control: Arc<LaunchControl>,
    ) -> anyhow::Result<Arc<Surface>> {
        let terminal_public_id = terminal_public_id_from_resource_identity(
            &resource_identity,
            "launching terminal cannot use a browser resource identity",
        )?;
        let journal_generation = Arc::from(format!("launching-{}", control.terminal_id()));
        Self::placeholder_surface(
            id,
            opts,
            mux,
            terminal_public_id,
            Some(resource_identity),
            PlaceholderRuntime {
                // The host picks the incarnation at bootstrap, so it is
                // unknown while launching (G1): the identity carries an
                // empty one, which no host record or durable row matches.
                host_identity: Some(crate::terminal_host_runtime::TerminalHostIdentity {
                    terminal_id: control.terminal_id().to_string(),
                    incarnation: String::new(),
                }),
                runtime: PtyRuntime::Launching(control),
                journal_generation,
                dead: false,
            },
        )
    }

    /// The launch state of a launching placeholder surface.
    pub(crate) fn launch_control(&self) -> Option<Arc<LaunchControl>> {
        let pty = self.as_pty()?;
        match &*pty.runtime.lock().unwrap_or_else(std::sync::PoisonError::into_inner) {
            PtyRuntime::Launching(control) => Some(control.clone()),
            _ => None,
        }
    }

    /// Construct a dead hosted surface for lifecycle tests without inventing
    /// a live host connection. Production keeps exit receipts in the registry.
    #[cfg(test)]
    pub(super) fn exited_terminal_placeholder_with_identities(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        identity: crate::terminal_host_runtime::TerminalHostIdentity,
        terminal_public_id: TerminalPublicId,
        resource_identity: Option<TabResourceIdentity>,
    ) -> anyhow::Result<Arc<Surface>> {
        let journal_generation = Arc::from(identity.incarnation.clone());
        Self::placeholder_surface(
            id,
            opts,
            mux,
            terminal_public_id,
            resource_identity,
            PlaceholderRuntime {
                runtime: PtyRuntime::ExitedHosted,
                host_identity: Some(identity),
                journal_generation,
                dead: true,
            },
        )
    }

    /// A PTY surface with no process: an empty grid at the launch size.
    fn placeholder_surface(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        terminal_public_id: TerminalPublicId,
        resource_identity: Option<TabResourceIdentity>,
        placeholder: PlaceholderRuntime,
    ) -> anyhow::Result<Arc<Surface>> {
        let PlaceholderRuntime { runtime, host_identity, journal_generation, dead } = placeholder;
        let initial_kitty_limits = KittyGraphicsLimits::disabled();
        let title_changed = Arc::new(AtomicBool::new(false));
        let callbacks = hosted_terminal_callbacks(id, mux.clone(), title_changed);
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
        let connection_state = if dead {
            TerminalHostConnectionState::Exited
        } else {
            TerminalHostConnectionState::Connected
        };
        let surface = Arc::new(Surface::Pty(PtySurface {
            meta: SurfaceMeta {
                id,
                resource_identity,
                name: Mutex::new(None),
                selection: Mutex::new(None),
            },
            terminal: Arc::new(PtyTerminalRuntime {
                event_surface_id: id,
                terminal_public_id: Some(Arc::new(terminal_public_id)),
                journal_generation,
                journal_capture_supported: dead,
                journal_capture_epoch: AtomicU64::new(0),
                journal_capture_gate: Mutex::new(()),
                journal_capture_idle: Condvar::new(),
                journal_capture_open: AtomicBool::new(dead),
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
                runtime: Mutex::new(runtime),
                lifetime: PtyLifetime::SessionOwned,
                supports_clear_history_key_fallback: AtomicBool::new(false),
                host_identity,
                pending_host_binding: Mutex::new(None),
                host_exit_record_path: None,
                pid: None,
                command,
                cwd: opts.cwd,
                exit: Mutex::new(None),
                local_pty_drained: AtomicBool::new(true),
                exit_notified: AtomicBool::new(dead),
                dead: AtomicBool::new(dead),
                owner_detaching: AtomicBool::new(false),
                host_connection_state: AtomicU8::new(connection_state as u8),
                dirty: AtomicBool::new(true),
                title: Mutex::new(String::new()),
                pwd: Mutex::new(None),
                published_directory: Mutex::new(PublishedDirectory::Reported(None)),
                directory_pending: AtomicBool::new(true),
                directory_reported: AtomicBool::new(false),
                geometry: Mutex::new(PtyGeometry {
                    cols,
                    rows,
                    cell_width: cell_pixels.0,
                    cell_height: cell_pixels.1,
                }),
                kitty_graphics_limits: Box::new(Mutex::new(initial_kitty_limits)),
                #[cfg(test)]
                geometry_test_hook: Mutex::new(None),
                #[cfg(test)]
                deferred_cell_pixel_ack_test_hook: Mutex::new(None),
                #[cfg(test)]
                test_master_control: None,
                #[cfg(test)]
                vt_replay_builds: AtomicUsize::new(0),
                mux,
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
        spawn_frame_producer(&surface, frame_rx)?;
        Ok(surface)
    }
}
