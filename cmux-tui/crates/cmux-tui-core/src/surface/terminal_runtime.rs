//! PTY terminal runtime: the per-terminal runtime state shared by surface views,
//! reader completion tracking, the local or hosted runtime enum, and the child
//! startup guard.

use super::*;

mod cold_terminal;
pub(crate) use cold_terminal::{
    ColdFreeze, ScrollbackMemory, TerminalCell, TerminalSlot, ThawWake,
};

#[derive(Default)]
pub(super) struct ReaderCompletion {
    finished: Mutex<bool>,
    changed: Condvar,
}

impl ReaderCompletion {
    pub(super) fn reset(&self) {
        *self.finished.lock().recover_poison() = false;
    }

    /// Whether the reader thread has ended.
    pub(super) fn is_complete(&self) -> bool {
        *self.finished.lock().recover_poison()
    }

    pub(super) fn complete(&self) {
        let mut finished = self.finished.lock().recover_poison();
        *finished = true;
        self.changed.notify_all();
    }

    pub(super) fn wait_until(&self, deadline: Instant) -> bool {
        let mut finished = self.finished.lock().recover_poison();
        while !*finished {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            let (next, result) = self.changed.wait_timeout(finished, remaining).recover_poison();
            finished = next;
            if result.timed_out() && !*finished {
                return false;
            }
        }
        true
    }
}

/// Where a terminal's output is read. Either way `reader_completion` marks
/// its end.
pub(super) enum TerminalReader {
    /// A thread of its own: a hosted terminal's host reader, a holder or
    /// byte-backend terminal's reader. Shutdown joins it.
    Thread(SupervisedThread<()>),
    /// A source on the owner's read loop (`mux::TerminalReads`): a
    /// daemon-local PTY. Nothing to join.
    #[cfg(unix)]
    Looped,
}

pub(super) struct ReaderCompletionGuard(pub(super) Arc<ReaderCompletion>);

thread_local! {
    /// The `reaper_completion` of the terminal whose end this thread records
    /// and publishes now (0: none).
    static ENDING_TERMINAL: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// Marks this thread as the one publishing a terminal's end until dropped.
/// The publish may tear the terminal down, and teardown waits for the
/// terminal's reaper completion, which is marked only after the publish:
/// teardown on this thread skips that wait instead of waiting for itself.
pub(super) struct EndingTerminal {
    previous: usize,
}

impl EndingTerminal {
    pub(super) fn enter(completion: &Arc<ReaderCompletion>) -> Self {
        let marked = Arc::as_ptr(completion) as usize;
        Self { previous: ENDING_TERMINAL.with(|ending| ending.replace(marked)) }
    }

    /// Whether this thread publishes the end whose reaper is `completion`.
    pub(super) fn is_current(completion: &Arc<ReaderCompletion>) -> bool {
        ENDING_TERMINAL.with(|ending| ending.get() == Arc::as_ptr(completion) as usize)
    }
}

impl Drop for EndingTerminal {
    fn drop(&mut self) {
        ENDING_TERMINAL.with(|ending| ending.set(self.previous));
    }
}

impl Drop for ReaderCompletionGuard {
    fn drop(&mut self) {
        self.0.complete();
    }
}

impl PtyTerminalRuntime {
    /// Feed raw child output to the generic terminal metadata parser. The
    /// parser has no knowledge of agents or plugins and keeps only bounded
    /// terminal protocol state. Returns the desktop notifications (OSC 9,
    /// OSC 777, OSC 99) the output asked for that pass Ghostty's rate limit;
    /// the caller posts them after it releases the terminal lock.
    pub(super) fn observe_terminal_output(
        &self,
        bytes: &[u8],
    ) -> Vec<crate::terminal_metadata::TerminalNotification> {
        self.observe_terminal_output_replayed(bytes, false)
    }

    /// [`Self::observe_terminal_output`] of output that may be a restarted
    /// daemon's replay of a holder's ring (`replayed`): its prompt marks are
    /// old, so the shell is not idle until a prompt after it. Noted in the
    /// same metadata lock as the marks, so no publication sees them idle.
    pub(super) fn observe_terminal_output_replayed(
        &self,
        bytes: &[u8],
        replayed: bool,
    ) -> Vec<crate::terminal_metadata::TerminalNotification> {
        let mut metadata = self.terminal_metadata.lock().recover_poison();
        if !bytes.is_empty() {
            metadata.activity.note_output(crate::workspace_registry::unix_epoch_ms().unwrap_or(0));
        }
        metadata.observe_output(bytes);
        if replayed {
            metadata.activity.note_replayed_output();
        }
        metadata.take_admitted_notifications(Instant::now())
    }

    /// Applies the OSC 133 marks of the output just written to `term`. With
    /// `recording` false (the default) marks are dropped, any running command
    /// is forgotten, and nothing is read from the screen. The command line
    /// comes from Ghostty's semantic input cells, so a command typed before
    /// recording turned on is still read whole at `C`. It also notes whether
    /// a running command set the terminal up for interactive use
    /// (`terminal-activity-v1` `in_use`), recording or not.
    pub(super) fn observe_shell_marks(
        &self,
        term: &mut Terminal,
        recording: impl FnOnce() -> bool,
    ) -> Vec<crate::shell_history::FinishedCommand> {
        let marks = {
            let mut metadata = self.terminal_metadata.lock().recover_poison();
            // The modes after this output: a running command that took the
            // terminal for interaction is `in_use`, not `running`.
            metadata.observe_modes(|| crate::terminal_activity::terminal_modes(term));
            metadata.take_shell_marks()
        };
        if marks.is_empty() {
            return Vec::new();
        }
        let mut tracker = self.command_tracker.lock().recover_poison();
        if !recording() {
            tracker.reset();
            return Vec::new();
        }
        let mut screen = crate::shell_history::TerminalCommandScreen(term);
        let now_ms = crate::workspace_registry::unix_epoch_ms().unwrap_or(0);
        marks.into_iter().filter_map(|mark| tracker.apply(mark, now_ms, &mut screen)).collect()
    }

    pub(super) fn terminal_osc_progress(&self) -> String {
        self.terminal_metadata.lock().recover_poison().osc_progress().to_string()
    }

    pub(super) fn begin_terminal_journal_update(&self) -> Option<TerminalJournalUpdateGuard<'_>> {
        let _gate = self.journal_capture_gate.lock().recover_poison();
        if !self.journal_capture_open.load(Ordering::Acquire) {
            return None;
        }
        let reserved = self.journal_capture_reserved.swap(true, Ordering::AcqRel);
        debug_assert!(!reserved, "terminal journal reads must not overlap");
        Some(TerminalJournalUpdateGuard { owner: self })
    }

    pub(super) fn close_terminal_journal_capture_when_idle(&self, deadline: Instant) -> bool {
        let mut gate = self.journal_capture_gate.lock().recover_poison();
        let active_deadline = deadline + Duration::from_secs(2);
        loop {
            if !self.journal_capture_reserved.load(Ordering::Acquire)
                && self.journal_capture_epoch.load(Ordering::Acquire) & 1 == 0
            {
                self.journal_capture_open.store(false, Ordering::Release);
                return false;
            }
            if Instant::now() >= deadline {
                if !self.journal_capture_active.load(Ordering::Acquire) {
                    // A read is still blocked or has not started terminal
                    // mutation. Revoke its reservation. The reader checks the
                    // gate before parsing and exits without changing state.
                    self.journal_capture_open.store(false, Ordering::Release);
                    return false;
                }
                let remaining = active_deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    // Keep shutdown bounded if a source-owned parser or
                    // callback violates the active-update time contract. The
                    // closed gate prevents a late journal insert after the
                    // final barrier, and the daemon is already stopping.
                    self.journal_capture_open.store(false, Ordering::Release);
                    eprintln!(
                        "cmux-tui: active terminal journal update exceeded shutdown grace; closing capture and recording an output gap"
                    );
                    return true;
                }
                let (next, _) =
                    self.journal_capture_idle.wait_timeout(gate, remaining).recover_poison();
                gate = next;
            } else {
                let remaining = deadline.saturating_duration_since(Instant::now());
                let (next, _) =
                    self.journal_capture_idle.wait_timeout(gate, remaining).recover_poison();
                gate = next;
            }
        }
    }
}

/// Content runtime shared by every view placement of one terminal.
///
/// A [`PtySurface`] is a lightweight placement carrying tab-local metadata.
/// This object owns the process, terminal emulator, ordered input/output, and
/// canonical geometry. Keeping the two identities distinct makes a terminal
/// projectable into any number of panes without cloning its PTY or VT state.
///
/// Lock order (outer first): `Mux::state` -> `kitty_limits_request` ->
/// `geometry` -> local output parser (direct PTYs only) -> `term` ->
/// `runtime` -> `kitty_graphics_limits` -> `taps` ->
/// leaf locks (`render`, `title`, `mouse_encoders`, `last_attach_colors`,
/// `Mux::default_colors`, ...). These locks carry the ranks
/// `LockRank::{MuxState, KittyLimitsRequest, Geometry, Terminal, Runtime,
/// KittyLimits, AttachTaps, Leaf}`
/// (crate::lock_rank; `Mux::state` through `StateMutex`, the others as
/// [`RankedMutex`]): in debug and test builds a blocking acquisition at a rank
/// equal to or before one the thread holds panics and names both locks;
/// release builds compile the check out. Mux code holds `Mux::state` while it reads
/// `geometry` (`Surface::size`), and a resize holds `geometry` while it takes
/// `term`. So no path may call a mux method that takes `Mux::state` (every
/// `emit_terminal_*`, `mark_output_dirty`) while it holds `term` or
/// `geometry`: collect the event under the lock, release it, then emit.
/// Parser callbacks run inside `vt_write` under `term`, so they only record
/// flags or counters that the reader publishes after it unlocks.
pub struct PtyTerminalRuntime {
    pub(super) event_surface_id: SurfaceId,
    /// Stable public content identity. This belongs to the terminal runtime,
    /// while `SurfaceMeta::resource_identity` belongs to one view placement.
    pub(super) terminal_public_id: Option<Arc<TerminalPublicId>>,
    pub(super) journal_generation: Arc<str>,
    /// Legacy terminal hosts remain attachable, but cannot source-fence
    /// output at daemon shutdown and therefore never enter journal capture.
    pub(super) journal_capture_supported: bool,
    /// Shared read/parser state for a direct PTY. A geometry transaction drains
    /// its queued bytes before TIOCSWINSZ, using the reader's normalizer and
    /// observer path. Holder streams and byte backends are not direct PTYs.
    #[cfg(unix)]
    pub(super) local_output: Option<Arc<Mutex<local_output::LocalOutput>>>,
    /// Even while the emulator and terminal journal agree, odd while one
    /// output frame has updated one side but not yet reached the other.
    pub(super) journal_capture_epoch: AtomicU64,
    pub(super) journal_capture_gate: Mutex<()>,
    pub(super) journal_capture_idle: Condvar,
    pub(super) journal_capture_open: AtomicBool,
    pub(super) journal_capture_reserved: AtomicBool,
    pub(super) journal_capture_active: AtomicBool,
    /// Owned reader join fence. Shutdown gives this reader a bounded drain
    /// interval, then closes journal capture before it inserts the final
    /// journal barrier.
    pub(super) reader_thread: Mutex<Option<TerminalReader>>,
    pub(super) reader_completion: Arc<ReaderCompletion>,
    /// The class this terminal's own reader and parser threads run at: the
    /// echo class while a view shows it, utility while none does
    /// (`surface/thread_qos.rs`). The threads apply it themselves after
    /// their next wake. A direct PTY read on the owner's shared read loop
    /// has no thread of its own to follow it.
    pub(super) thread_qos: cmux_threads::DesiredQos,
    /// Owned child-reaper fence. Shutdown uses the same bounded deadline
    /// as the reader so the child wait cannot outlive terminal teardown.
    pub(super) reaper_thread: Mutex<Option<LocalReaper>>,
    pub(super) reaper_completion: Arc<ReaderCompletion>,
    /// Hot or compressed; every lock restores it first (cold_terminal.rs).
    pub(super) term: TerminalCell,
    pub(super) stream_progress: Box<TerminalStreamProgress>,
    /// Generic metadata parsed from raw PTY output. This field has no agent
    /// or roster knowledge, so userland plugins can consume it through the
    /// resource API without moving detection policy into core.
    pub(super) terminal_metadata: Mutex<crate::terminal_metadata::TerminalMetadata>,
    /// OSC 133 command tracking (`terminal-command-history-v1`); idle unless
    /// the daemon records terminal commands.
    pub(super) command_tracker: Mutex<crate::shell_history::CommandTracker>,
    pub(super) mouse_encoders: RankedMutex<Box<MouseEncoders>>,
    pub(super) runtime: RankedMutex<PtyRuntime>,
    /// The terminal's input FIFO: every input to it (any view, connection
    /// or thread) writes all of its bytes in one turn of it, in arrival
    /// order (crate::pty_input_fifo).
    pub(super) input_fifo: crate::pty_input_fifo::PtyInputFifo,
    /// Explicit lifecycle authority for this process. Session content may
    /// survive a daemon replacement through a durable host; daemon-owned
    /// auxiliaries must terminate with the backend that created them.
    pub(super) lifetime: PtyLifetime,
    pub(super) supports_clear_history_key_fallback: AtomicBool,
    pub(super) host_identity: Option<crate::terminal_host_runtime::TerminalHostIdentity>,
    #[cfg(any(unix, windows))]
    pub(super) pending_host_binding: Mutex<Option<crate::mux::PendingTerminalHostBinding>>,
    #[cfg(any(unix, windows))]
    pub(super) host_exit_record_path: Option<PathBuf>,
    pub(super) pid: Option<u32>,
    pub(super) command: Vec<String>,
    pub(super) cwd: Option<String>,
    /// How this incarnation ended, with its provenance (process end versus
    /// host loss); see [`TerminalEnd`].
    pub(super) exit: Mutex<Option<TerminalEnd>>,
    pub(super) local_pty_drained: AtomicBool,
    pub(super) exit_notified: AtomicBool,
    pub(super) dead: AtomicBool,
    /// The daemon is intentionally dropping its compatibility proxy while
    /// leaving the terminal host alive for a later daemon to adopt.
    pub(super) owner_detaching: AtomicBool,
    /// The host socket ended without a sequenced Exit. Closing this proxy
    /// must retain the host record so a fresh snapshot can recover it.
    pub(super) host_connection_state: AtomicU8,
    /// Why this terminal runs in the daemon process although terminal hosts
    /// are on (cx-ko2e); unset for a hosted terminal and for every terminal
    /// where hosts are off. Set before the surface is published.
    pub(super) host_fallback: std::sync::OnceLock<TerminalHostFallback>,
    /// Set when output arrived since the last render; cleared by the
    /// frontend when it draws.
    pub(super) dirty: AtomicBool,
    pub(super) title: RankedMutex<String>,
    pub(super) pwd: Mutex<Option<String>>,
    pub(super) published_directory: Mutex<PublishedDirectory>,
    pub(super) directory_pending: AtomicBool,
    /// A publication of this terminal's cwd and progress is queued on the
    /// mux's work lane (`Surface::post_pending_publications`): its output
    /// threads queue at most one at a time.
    pub(super) publication_posted: AtomicBool,
    /// This terminal's publications, in order, one at a time.
    pub(super) publications: Arc<crate::mux::mux_work::Sequence>,
    /// A shell has reported a directory at least once; only then is a later
    /// absent report a clear rather than the still-unreported launch directory.
    pub(super) directory_reported: AtomicBool,
    pub(super) geometry: RankedMutex<PtyGeometry>,
    /// The Kitty limits this surface last committed. Ranked between the
    /// runtime and the attach taps: a request reads it under the runtime,
    /// and a commit holds it with the terminal while it resynchronizes taps.
    pub(super) kitty_graphics_limits: Box<RankedMutex<KittyGraphicsLimits>>,
    /// Serializes Kitty limits requests for this surface. A request waits
    /// for the host's acknowledgement without the runtime lock (the
    /// reconnecting reader needs that lock), so this keeps a slower request
    /// from committing its limits after a newer one.
    pub(super) kitty_limits_request: RankedMutex<()>,
    #[cfg(test)]
    pub(super) geometry_test_hook: Mutex<Option<PtyGeometryTestHook>>,
    #[cfg(test)]
    pub(super) deferred_cell_pixel_ack_test_hook: Mutex<Option<DeferredCellPixelAckTestHook>>,
    #[cfg(test)]
    pub(super) test_master_control: Option<Arc<TestMasterPtyControl>>,
    #[cfg(test)]
    pub(super) vt_replay_builds: AtomicUsize,
    pub(super) mux: Weak<Mux>,
    /// Live output subscribers (attach streams). Guarded by the terminal
    /// lock ordering: the reader thread broadcasts while holding the
    /// terminal lock, and [`Surface::attach_stream`] registers taps under
    /// the same lock, so a subscriber sees exactly the bytes applied
    /// after its replay snapshot — no gap, no duplication.
    pub(super) taps: RankedMutex<AttachTaps>,
    /// A PTY color mutation awaiting bounded attach-stream fan-out.
    pub(super) attach_colors_pending: AtomicBool,
    /// A reset or cursor-semantic transition requires reapplying equal state:
    /// byte frontends may reset palettes or switch per-screen cursor storage
    /// even when the final effective values compare equal.
    pub(super) attach_colors_force_pending: AtomicBool,
    /// The flow of the newest key press a `send` wrote on this terminal's
    /// local PTY master (0: none since the last output took it): the
    /// daemon's next read of that PTY carries it, once.
    /// A hosted terminal's host and a holder
    /// terminal's sink keep their own slot: the daemon does not read
    /// their PTY.
    pub(super) last_input_flow: crate::input_flow::InputFlowSlot,
    /// This terminal's key presses on their way to their echo: the daemon's
    /// receive, the PTY write and the echo's read. Shared
    /// with each attach writer, which sends the stamps with the echo.
    pub(super) input_stages: Arc<crate::input_stages::InputStageRing>,
    /// Published byte offset and grid generation for snapshot viewers.
    pub(super) snapshot_position: snapshot_attach::SnapshotStreamPosition,
    /// Last effective color state emitted to attach streams. This suppresses
    /// repeated OSC sets that advance Ghostty's revision without changing the
    /// frontend-visible state.
    pub(super) last_attach_colors: RankedMutex<Option<Box<TerminalColors>>>,
    /// Single consume-once Ghostty render state shared by the local TUI and
    /// every protocol-v7 render attachment.
    pub(super) render: Arc<RankedMutex<RenderHub>>,
    pub(super) render_generation: AtomicU64,
    pub(super) frame_requests: frame_producer::FrameRequests,
    #[cfg(test)]
    pub(super) frame_producer_before_upgrade: FrameProducerTestHook,
}

pub(crate) struct TerminalJournalGap {
    pub(crate) terminal_id: Arc<TerminalPublicId>,
    pub(crate) generation: Arc<str>,
    pub(crate) reason: &'static str,
}

/// A local terminal's PTY writer, shared, so a write that waits for the child
/// to read runs after the runtime lock is released: nothing that takes the
/// runtime lock (the foreground check behind `shell_idle`, a resize, a read
/// of the runtime) waits on a child that does not read. Writes stay in order:
/// each runs in the terminal's input turn (`InputTurn`). The lock here is a
/// leaf, never held while the runtime lock is taken.
#[derive(Clone)]
pub(crate) struct LocalWriter(Arc<std::sync::Mutex<Box<dyn Write + Send>>>);

impl LocalWriter {
    pub(crate) fn new(writer: Box<dyn Write + Send>) -> Self {
        Self(Arc::new(std::sync::Mutex::new(writer)))
    }

    /// Writes `bytes` whole and flushes. May block while the child does not read.
    pub(crate) fn write_all(&self, bytes: &[u8]) -> std::io::Result<()> {
        let mut writer = self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        writer.write_all(bytes)?;
        writer.flush()
    }

    /// Runs `write` on the writer (a caller with its own write policy).
    pub(crate) fn with<R>(&self, write: impl FnOnce(&mut dyn Write) -> R) -> R {
        let mut writer = self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        write(writer.as_mut())
    }

    #[cfg(test)]
    pub(crate) fn replace(&self, replacement: Box<dyn Write + Send>) {
        *self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = replacement;
    }
}

pub(super) enum PtyRuntime {
    Local {
        writer: LocalWriter,
        master: Option<Box<dyn MasterPty + Send>>,
        killer: Box<dyn ChildKiller + Send>,
        /// The holder runs this terminal's shell (`holder_runtime`): a
        /// daemon shutdown detaches instead of killing it.
        #[cfg(unix)]
        holder: Option<Arc<crate::holder_runtime::HolderTerminal>>,
    },
    #[cfg(any(unix, windows))]
    Hosted(Box<crate::terminal_host_runtime::HostAttachment>),
    #[cfg(any(unix, windows))]
    ExitedHosted,
}

/// What reports the end of a local terminal's far side; `reaper_completion`
/// says when it has.
pub(super) enum LocalReaper {
    /// A thread blocked until the far side ended (a holder terminal, a byte
    /// backend, a Windows child).
    Thread(std::thread::JoinHandle<()>),
    /// The mux's reaper waits for the child (`cmux_threads::reaper`).
    #[cfg(unix)]
    Watched,
}

/// Owns a freshly spawned PTY child until the child reaper has taken over.
///
/// `portable_pty::Child` does not stop or reap a process when its handle is
/// dropped. Startup performs several fallible operations after spawning, so a
/// guard keeps every error path terminating and reaping the child. The guard
/// moves into the reaper closure; if thread creation fails, dropping that
/// closure runs this cleanup instead.
pub(crate) struct PtyChildStartupGuard {
    child: Box<dyn cmux_pty::Child + Send + Sync>,
    reaped: bool,
}

impl PtyChildStartupGuard {
    pub(super) fn new(child: Box<dyn cmux_pty::Child + Send + Sync>) -> Self {
        Self { child, reaped: false }
    }

    pub(super) fn process_id(&self) -> Option<u32> {
        self.child.process_id()
    }

    pub(super) fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        self.child.clone_killer()
    }

    #[cfg(not(unix))]
    pub(super) fn wait_for_exit(&mut self) -> TerminalExit {
        let (exit, reaped) =
            crate::terminal_host_protocol::wait_for_native_child_status_with_reap_result(
                self.child.as_mut(),
            );
        self.reaped = reaped;
        exit
    }

    /// The end from the status the mux's reaper took. A failed reap leaves
    /// the child to this guard's kill and wait.
    #[cfg(unix)]
    pub(super) fn reaped(
        &mut self,
        status: std::io::Result<std::process::ExitStatus>,
    ) -> TerminalExit {
        match status {
            Ok(status) => {
                self.reaped = true;
                TerminalExit::from_exit_status(&status)
            }
            Err(error) => TerminalExit::unknown(format!("wait failed: {error}")),
        }
    }
}

impl Drop for PtyChildStartupGuard {
    fn drop(&mut self) {
        if self.reaped {
            return;
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
