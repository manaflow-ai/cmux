//! The reader thread of a hosted terminal (`surface-<id>-host`) as a named
//! type. It applies the terminal host's ordered frames to the daemon's mirror
//! terminal and, after a loss or resync, reconnects or rehosts.

use super::*;
use std::os::unix::net::UnixStream;

mod output;
mod reconnect;
mod resize;

/// Loop state of one hosted surface's reader thread. `spawn_hosted` builds
/// it from the first attachment; a reconnect replaces the per-connection
/// fields.
pub(super) struct HostedReader {
    pub(super) id: SurfaceId,
    pub(super) mux: Weak<Mux>,
    pub(super) scrollback: usize,
    pub(super) control_responses: Arc<crate::terminal_host_runtime::ControlResponses>,
    pub(super) sequence_boundary: u64,
    pub(super) protocol_version: u16,
    pub(super) smart_renderer: bool,
    pub(super) applied_color_overrides: TerminalColorOverrides,
    pub(super) applied_color_revision: u64,
    pub(super) applied_cursor_activity: Option<u64>,
    pub(super) title_changed: Arc<AtomicBool>,
    pub(super) pending_bells: PendingBells,
    /// Test seam: slows applying each output frame so tests can build an
    /// output backlog ahead of a targeted host response.
    pub(super) output_apply_delay: Option<Duration>,
    /// One backoff across consecutive losses: a host that accepts and then
    /// drops at once (or keeps asking for a resync) used to be reconnected
    /// with no delay and no limit, because each loss started a fresh backoff.
    /// It resets only after a connection stayed up for
    /// TERMINAL_HOST_HEALTHY_CONNECTION.
    pub(super) flap_backoff: TerminalHostReconnectBackoff,
    /// Spaces back-to-back resyncs of a live host without spending the
    /// failure budget that decides whether a real loss fails.
    pub(super) resync_backoff: TerminalHostReconnectBackoff,
    /// `None` until the first reconnect: the first loss of a connection keeps
    /// its immediate reconnect.
    pub(super) connected_at: Option<Instant>,
}

/// Whether the host stream goes on after one transition.
pub(super) enum Flow {
    Continue,
    Break,
}

/// How one host stream ended. The frame demultiplexer, the journal target
/// and any journal update reservation stay alive until the connection
/// iteration ends, after a reconnect installed its replacement. Keeping the
/// reservation is deliberate (cx-fr5l):
/// - An active update (the parser applied output, then the stream broke
///   before the bytes reached the journal, as on the color-contract break in
///   `apply_output`) keeps `journal_capture_epoch` odd. Checkpoint capture
///   (`terminal_replay_blob`) then refuses the diverged mirror until the
///   reconnect replaced it from the host snapshot and recorded the
///   `host_reconnect` gap. Releasing it at the break would publish an even
///   epoch while the mirror holds output that the journal lacks.
/// - A reserved but inactive update costs nothing: shutdown first waits for
///   this reader (`finish_terminal_reader`), and at its deadline
///   `close_terminal_journal_capture_when_idle` revokes an inactive
///   reservation at once.
struct StreamEnd<'a> {
    received_exit: Option<TerminalExit>,
    resync_requested: bool,
    _journal_target: Option<(Arc<Mux>, Arc<TerminalPublicId>)>,
    _journal_update: Option<TerminalJournalUpdateGuard<'a>>,
    _frames: host_frames::HostFrames,
}

impl HostedReader {
    /// Test seam value of `CMUX_TUI_TEST_HOSTED_OUTPUT_APPLY_DELAY_MS`.
    pub(super) fn output_apply_delay_from_env() -> Option<Duration> {
        std::env::var("CMUX_TUI_TEST_HOSTED_OUTPUT_APPLY_DELAY_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .map(|ms| Duration::from_millis(ms.min(5_000)))
    }

    /// Thread body: stream from the host until it ends, then exit, resync or
    /// reconnect.
    pub(super) fn run(mut self, surface: Arc<Surface>, mut reader: UnixStream) {
        let _reader_completion = ReaderCompletionGuard(
            surface.as_pty().expect("host reader owns a PTY surface").reader_completion.clone(),
        );
        loop {
            let pty = surface.as_pty().expect("host reader owns a PTY surface");
            rehost::request_custody(&surface);
            let Some(end) = self.stream(&surface, pty, reader) else { return };
            let Some(next) = self.after_stream(&surface, end.received_exit, end.resync_requested)
            else {
                return;
            };
            reader = next;
        }
    }

    /// One host connection: targeted responses, staging and the ordered
    /// transitions. `None` when the frame demultiplexer cannot start.
    fn stream<'a>(
        &mut self,
        surface: &Arc<Surface>,
        pty: &'a PtySurface,
        reader: UnixStream,
    ) -> Option<StreamEnd<'a>> {
        let id = self.id;
        let mux = self.mux.clone();
        let mut stager = HostedFrameStager::new_for_version(
            self.sequence_boundary,
            self.protocol_version,
            self.smart_renderer,
        );
        let mut received_exit = None;
        let mut resync_requested = false;
        let mut journal_target = None;
        let mut journal_update = None;
        // `reader` moves into the demultiplexer; a reconnect reassigns it.
        let frames = match host_frames::HostFrames::spawn(
            format!("surface-{id}-host-frames"),
            reader,
            self.control_responses.clone(),
            self.protocol_version,
            self.smart_renderer,
        ) {
            Ok(frames) => frames,
            Err(_) => return None,
        };
        loop {
            if journal_update.is_none() {
                journal_target = pty.journal_target();
                journal_update =
                    journal_target.as_ref().and_then(|_| pty.begin_terminal_journal_update());
                if journal_target.is_some() && journal_update.is_none() {
                    break;
                }
            }
            let frame = match frames.recv() {
                host_frames::HostFrame::Frame(frame) => frame,
                host_frames::HostFrame::End => break,
            };
            // Targeted responses must be consumed before live staging:
            // HostedFrameStager intentionally rejects every nonzero request id.
            if host_frames::is_targeted_host_response(frame.kind) && frame.request_id != 0 {
                if frame.version != self.protocol_version || frame.flags != 0 || frame.sequence != 0
                {
                    break;
                }
                let clear_replay = if frame.kind == MessageKind::ClearHistoryAck
                    && frame.payload.len() > 1
                {
                    if !self.smart_renderer || frame.payload.first() != Some(&CLEAR_HISTORY_ACK_OK)
                    {
                        break;
                    }
                    Some(&frame.payload[1..])
                } else {
                    None
                };
                if !self.control_responses.resolve_after(&frame, || {
                    if let Some(replay) = clear_replay {
                        Surface::apply_hosted_clear_history_replay(surface, pty, replay, &mux);
                    }
                }) {
                    break;
                }
                drop(journal_update.take());
                journal_target = None;
                continue;
            }
            let Ok(transition) = stager.push(frame) else {
                break;
            };
            let Some(transition) = transition else { continue };
            let flow = match transition {
                transition @ (HostedTransition::Output(_)
                | HostedTransition::OutputWithColors { .. }) => self.apply_output(
                    surface,
                    pty,
                    transition,
                    &mut journal_target,
                    &mut journal_update,
                ),
                HostedTransition::Resized { cols, rows, cell_pixels } => {
                    self.apply_resized(surface, pty, cols, rows, cell_pixels)
                }
                HostedTransition::ResizedWithColors {
                    cols,
                    rows,
                    cell_pixels,
                    replay,
                    kitty_image_aliases,
                    kitty_state,
                    colors,
                } => self.apply_resized_with_colors(
                    surface,
                    pty,
                    (cols, rows),
                    cell_pixels,
                    replay,
                    kitty_image_aliases,
                    kitty_state,
                    colors,
                ),
                // The mirror derives these from the preceding Output; the
                // sequenced metadata frames are still consumed so they cannot
                // hide a stream gap.
                HostedTransition::Metadata(_kind) => Flow::Continue,
                HostedTransition::Exit(exit) => {
                    received_exit = Some(exit);
                    break;
                }
                HostedTransition::ResyncRequired => {
                    resync_requested = true;
                    break;
                }
                HostedTransition::KittyGraphicsLimits(limits) => {
                    if !pty.apply_host_kitty_graphics_limits(limits) {
                        resync_requested = true;
                        break;
                    }
                    Flow::Continue
                }
            };
            if let Flow::Break = flow {
                break;
            }
            drop(journal_update.take());
            journal_target = None;
            // Bells rung by this transition's parser work, emitted with
            // neither the terminal nor the geometry lock held.
            self.pending_bells.publish(&mux, surface.id);
        }
        frames.abandon();
        Some(StreamEnd {
            received_exit,
            resync_requested,
            _journal_target: journal_target,
            _journal_update: journal_update,
            _frames: frames,
        })
    }

    /// After a stream ended: publish an exit, or report the loss and wait out
    /// the backoff, then reconnect. `None` stops the reader thread.
    fn after_stream(
        &mut self,
        surface: &Arc<Surface>,
        received_exit: Option<TerminalExit>,
        resync_requested: bool,
    ) -> Option<UnixStream> {
        let mux = self.mux.clone();
        let pty = surface.as_pty()?;
        if pty.owner_detaching.load(Ordering::Acquire) {
            return None;
        }
        let identity = pty.host_identity.clone()?;
        if let Some(exit) = received_exit {
            // The host's Exit frame is its report that the child
            // ended, even when an older host omits the status.
            *pty.exit.lock().unwrap() = Some(TerminalEnd::ProcessEnded(exit));
            mark_hosted_runtime_exited(pty, &identity);
            pty.host_connection_state
                .store(TerminalHostConnectionState::Exited as u8, Ordering::Release);
            pty.stream_progress.notify();
            if let Some(mux) = mux.upgrade() {
                mux.surface_exited(surface.id);
            }
            return None;
        }

        // ResyncRequired is an ordered renderer reset from a live
        // host, not evidence that its admin stream or PTY was
        // lost. Reconnect from a fresh snapshot without moving
        // either the observable connection state or the durable
        // lifecycle through Adopting. This also keeps initial
        // topology binding valid if defaults legitimately change
        // while a new hosted surface is being installed.
        let first_loss = !resync_requested
            && pty
                .host_connection_state
                .swap(TerminalHostConnectionState::Reconnecting as u8, Ordering::AcqRel)
                != TerminalHostConnectionState::Reconnecting as u8;
        if first_loss
            && let Some(mux) = mux.upgrade()
            && !mux.terminal_host_connection_lost(surface.id, &identity)
        {
            return None;
        }

        if self.connected_at.is_none_or(|at| at.elapsed() >= TERMINAL_HOST_HEALTHY_CONNECTION) {
            self.flap_backoff = TerminalHostReconnectBackoff::default();
            self.resync_backoff = TerminalHostReconnectBackoff::default();
        } else if resync_requested {
            // A live host's resync never fails the terminal, but
            // back-to-back resyncs are spaced.
            let delay = self.resync_backoff.next_delay();
            std::thread::sleep(delay.unwrap_or(TERMINAL_HOST_RECONNECT_MAX_DELAY));
        } else if !self.flap_backoff.wait_or_fail(pty) {
            return None;
        }
        self.reconnect(surface, pty, identity)
    }
}
