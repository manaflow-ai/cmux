//! PTY terminal runtime: the per-terminal runtime state shared by surface views,
//! reader completion tracking, the local or hosted runtime enum, and the child
//! startup guard.

use super::*;
use crate::lock_rank::rank;

#[derive(Default)]
pub(super) struct ReaderCompletion {
    finished: RankedMutex<bool, { rank::LEAF }>,
    changed: Condvar,
}

impl ReaderCompletion {
    pub(super) fn reset(&self) {
        *self.finished.lock().unwrap() = false;
    }

    pub(super) fn complete(&self) {
        let mut finished = self.finished.lock().unwrap();
        *finished = true;
        self.changed.notify_all();
    }

    pub(super) fn wait_until(&self, deadline: Instant) -> bool {
        let mut finished = self.finished.lock().unwrap();
        while !*finished {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            let (next, result) = self.changed.wait_timeout(finished, remaining).unwrap();
            finished = next;
            if result.timed_out() && !*finished {
                return false;
            }
        }
        true
    }
}

pub(super) struct ReaderCompletionGuard(pub(super) Arc<ReaderCompletion>);

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
        let mut metadata = self.terminal_metadata.lock().unwrap();
        metadata.observe_output(bytes);
        metadata.take_admitted_notifications(Instant::now())
    }

    /// Applies the OSC 133 marks of the output just written to `term`. With
    /// `recording` false (the default) marks are dropped, any running command
    /// is forgotten, and nothing is read from the screen. The command line
    /// comes from Ghostty's semantic input cells, so a command typed before
    /// recording turned on is still read whole at `C`.
    pub(super) fn observe_shell_marks(
        &self,
        term: &mut Terminal,
        recording: impl FnOnce() -> bool,
    ) -> Vec<crate::shell_history::FinishedCommand> {
        let marks = self.terminal_metadata.lock().unwrap().take_shell_marks();
        if marks.is_empty() {
            return Vec::new();
        }
        let mut tracker = self.command_tracker.lock().unwrap();
        if !recording() {
            tracker.reset();
            return Vec::new();
        }
        let mut screen = crate::shell_history::TerminalCommandScreen(term);
        let now_ms = crate::workspace_registry::unix_epoch_ms().unwrap_or(0);
        marks.into_iter().filter_map(|mark| tracker.apply(mark, now_ms, &mut screen)).collect()
    }

    pub(super) fn terminal_osc_progress(&self) -> String {
        self.terminal_metadata.lock().unwrap().osc_progress().to_string()
    }

    pub(super) fn begin_terminal_journal_update(&self) -> Option<TerminalJournalUpdateGuard<'_>> {
        let _gate = self.journal_capture_gate.lock().unwrap();
        if !self.journal_capture_open.load(Ordering::Acquire) {
            return None;
        }
        let reserved = self.journal_capture_reserved.swap(true, Ordering::AcqRel);
        debug_assert!(!reserved, "terminal journal reads must not overlap");
        Some(TerminalJournalUpdateGuard { owner: self })
    }

    pub(super) fn close_terminal_journal_capture_when_idle(&self, deadline: Instant) -> bool {
        let mut gate = self.journal_capture_gate.lock().unwrap();
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
                let (next, _) = self.journal_capture_idle.wait_timeout(gate, remaining).unwrap();
                gate = next;
            } else {
                let remaining = deadline.saturating_duration_since(Instant::now());
                let (next, _) = self.journal_capture_idle.wait_timeout(gate, remaining).unwrap();
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
/// `geometry` -> `term` -> `runtime` -> `kitty_graphics_limits` -> `taps` ->
/// leaf locks (`render`, `title`, `mouse_encoders`, `last_attach_colors`,
/// `Mux::default_colors`, ...). These locks carry the ranks
/// `rank::{MUX_STATE, PTY_KITTY_LIMITS_REQUEST, PTY_GEOMETRY, PTY_TERM,
/// PTY_RUNTIME, PTY_KITTY_GRAPHICS_LIMITS, PTY_TAPS, LEAF}` in their type
/// (crate::lock_rank; `Mux::state` through `StateMutex`): in debug and test
/// builds a blocking acquisition at a rank equal to or below one the thread
/// holds panics and names both locks; release builds compile the check out.
/// The full crate table is in lock_rank.rs. Mux code holds `Mux::state` while it reads
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
    /// Even while the emulator and terminal journal agree, odd while one
    /// output frame has updated one side but not yet reached the other.
    pub(super) journal_capture_epoch: AtomicU64,
    pub(super) journal_capture_gate: RankedMutex<(), { rank::PTY_JOURNAL_CAPTURE_GATE }>,
    pub(super) journal_capture_idle: Condvar,
    pub(super) journal_capture_open: AtomicBool,
    pub(super) journal_capture_reserved: AtomicBool,
    pub(super) journal_capture_active: AtomicBool,
    /// Owned reader join fence. Shutdown gives this reader a bounded drain
    /// interval, then closes journal capture before it inserts the final
    /// journal barrier.
    pub(super) reader_thread:
        RankedMutex<Option<std::thread::JoinHandle<()>>, { rank::PTY_READER_THREAD }>,
    pub(super) reader_completion: Arc<ReaderCompletion>,
    /// Owned child-reaper join fence. Shutdown uses the same bounded deadline
    /// as the reader so the child wait cannot outlive terminal teardown.
    pub(super) reaper_thread: RankedMutex<Option<std::thread::JoinHandle<()>>, { rank::LEAF }>,
    pub(super) reaper_completion: Arc<ReaderCompletion>,
    pub(super) term: RankedMutex<Box<Terminal>, { rank::PTY_TERM }>,
    pub(super) stream_progress: Box<TerminalStreamProgress>,
    /// Generic metadata parsed from raw PTY output. This field has no agent
    /// or roster knowledge, so userland plugins can consume it through the
    /// resource API without moving detection policy into core.
    pub(super) terminal_metadata:
        RankedMutex<crate::terminal_metadata::TerminalMetadata, { rank::LEAF }>,
    /// OSC 133 command tracking (`terminal-command-journal-v1`); idle unless
    /// the daemon records terminal commands.
    pub(super) command_tracker: RankedMutex<crate::shell_history::CommandTracker, { rank::LEAF }>,
    pub(super) mouse_encoders: RankedMutex<Box<MouseEncoders>, { rank::LEAF }>,
    pub(super) runtime: RankedMutex<PtyRuntime, { rank::PTY_RUNTIME }>,
    /// Explicit lifecycle authority for this process. Session content may
    /// survive a daemon replacement through a durable host; daemon-owned
    /// auxiliaries must terminate with the backend that created them.
    pub(super) lifetime: PtyLifetime,
    pub(super) supports_clear_history_key_fallback: AtomicBool,
    pub(super) host_identity: Option<crate::terminal_host_runtime::TerminalHostIdentity>,
    #[cfg(unix)]
    pub(super) pending_host_binding: RankedMutex<
        Option<crate::mux::PendingTerminalHostBinding>,
        { rank::PTY_PENDING_HOST_BINDING },
    >,
    #[cfg(unix)]
    pub(super) host_exit_record_path: Option<PathBuf>,
    pub(super) pid: Option<u32>,
    pub(super) command: Vec<String>,
    pub(super) cwd: Option<String>,
    /// How this incarnation ended, with its provenance (process end versus
    /// host loss); see [`TerminalEnd`].
    pub(super) exit: RankedMutex<Option<TerminalEnd>, { rank::LEAF }>,
    pub(super) local_pty_drained: AtomicBool,
    pub(super) exit_notified: AtomicBool,
    pub(super) dead: AtomicBool,
    /// The daemon is intentionally dropping its compatibility proxy while
    /// leaving the terminal host alive for a later daemon to adopt.
    pub(super) owner_detaching: AtomicBool,
    /// The host socket ended without a sequenced Exit. Closing this proxy
    /// must retain the host record so a fresh snapshot can recover it.
    pub(super) host_connection_state: AtomicU8,
    /// Set when output arrived since the last render; cleared by the
    /// frontend when it draws.
    pub(super) dirty: AtomicBool,
    pub(super) title: RankedMutex<String, { rank::LEAF }>,
    pub(super) pwd: RankedMutex<Option<String>, { rank::LEAF }>,
    pub(super) published_directory: RankedMutex<PublishedDirectory, { rank::LEAF }>,
    pub(super) directory_pending: AtomicBool,
    /// A shell has reported a directory at least once; only then is a later
    /// absent report a clear rather than the still-unreported launch directory.
    pub(super) directory_reported: AtomicBool,
    pub(super) geometry: RankedMutex<PtyGeometry, { rank::PTY_GEOMETRY }>,
    /// The Kitty limits this surface last committed. Ranked between the
    /// runtime and the attach taps: a request reads it under the runtime,
    /// and a commit holds it with the terminal while it resynchronizes taps.
    pub(super) kitty_graphics_limits:
        Box<RankedMutex<KittyGraphicsLimits, { rank::PTY_KITTY_GRAPHICS_LIMITS }>>,
    /// Serializes Kitty limits requests for this surface. A request waits
    /// for the host's acknowledgement without the runtime lock (the
    /// reconnecting reader needs that lock), so this keeps a slower request
    /// from committing its limits after a newer one.
    pub(super) kitty_limits_request: RankedMutex<(), { rank::PTY_KITTY_LIMITS_REQUEST }>,
    #[cfg(test)]
    pub(super) geometry_test_hook: RankedMutex<Option<PtyGeometryTestHook>, { rank::LEAF }>,
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
    pub(super) taps: RankedMutex<Vec<AttachTap>, { rank::PTY_TAPS }>,
    /// A PTY color mutation awaiting bounded attach-stream fan-out.
    pub(super) attach_colors_pending: AtomicBool,
    /// A reset or cursor-semantic transition requires reapplying equal state:
    /// byte frontends may reset palettes or switch per-screen cursor storage
    /// even when the final effective values compare equal.
    pub(super) attach_colors_force_pending: AtomicBool,
    /// Published byte offset and grid generation for snapshot viewers.
    pub(super) snapshot_position: snapshot_attach::SnapshotStreamPosition,
    /// Last effective color state emitted to attach streams. This suppresses
    /// repeated OSC sets that advance Ghostty's revision without changing the
    /// frontend-visible state.
    pub(super) last_attach_colors: RankedMutex<Option<Box<TerminalColors>>, { rank::LEAF }>,
    /// Single consume-once Ghostty render state shared by the local TUI and
    /// every protocol-v7 render attachment.
    pub(super) render: Arc<RankedMutex<RenderHub, { rank::PTY_RENDER }>>,
    pub(super) render_generation: AtomicU64,
    pub(super) frame_requests: SyncSender<u64>,
    #[cfg(test)]
    pub(super) frame_producer_before_upgrade: FrameProducerTestHook,
}

pub(crate) struct TerminalJournalGap {
    pub(crate) terminal_id: Arc<TerminalPublicId>,
    pub(crate) generation: Arc<str>,
    pub(crate) reason: &'static str,
}

pub(super) enum PtyRuntime {
    Local {
        writer: Box<dyn Write + Send>,
        master: Option<Box<dyn MasterPty + Send>>,
        killer: Box<dyn ChildKiller + Send>,
    },
    #[cfg(unix)]
    Hosted(Box<crate::terminal_host_runtime::HostAttachment>),
    #[cfg(unix)]
    ExitedHosted,
}

/// Owns a freshly spawned PTY child until the child reaper has taken over.
///
/// `portable_pty::Child` does not stop or reap a process when its handle is
/// dropped. Startup performs several fallible operations after spawning, so a
/// guard keeps every error path terminating and reaping the child. The guard
/// moves into the reaper closure; if thread creation fails, dropping that
/// closure runs this cleanup instead.
pub(super) struct PtyChildStartupGuard {
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

    pub(super) fn wait_for_exit(&mut self) -> TerminalExit {
        let (exit, reaped) = wait_for_native_child_status_with_reap_result(self.child.as_mut());
        self.reaped = reaped;
        exit
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
