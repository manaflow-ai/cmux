//! The authoritative parser worker of one terminal host. It applies PTY
//! output and lifecycle commands to the host's Ghostty terminal in order and
//! hands the terminal's own replies (queries, clipboard reads) to the PTY
//! reply writer (`pty_replies`) after every command.

use crate::panic_free::RecoverPoison;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ghostty_vt::Callbacks;

use super::super::*;
use super::clipboard_read::*;
use super::host_shared::HostShared;
use super::host_state::*;
use super::pty_replies::{PtyReplies, write_to_pty};

/// State the parser shares with the terminal's callbacks.
pub(crate) struct ParserSignals {
    pub(crate) pending_responses: Arc<Mutex<Vec<u8>>>,
    pub(crate) title_changed: Arc<AtomicBool>,
    pub(crate) bell: Arc<AtomicBool>,
    /// The OSC 7501 records this host keeps, so a daemon that adopts it
    /// after a restart gets them in the snapshot (cx-6so.36.6).
    pub(crate) program_status: crate::program_status::SharedProgramStatus,
}

impl ParserSignals {
    pub(crate) fn new() -> Self {
        Self {
            pending_responses: Arc::new(Mutex::new(Vec::new())),
            title_changed: Arc::new(AtomicBool::new(false)),
            bell: Arc::new(AtomicBool::new(false)),
            program_status: Default::default(),
        }
    }

    /// The callbacks of the host's authoritative terminal. It keeps the
    /// program status records the snapshot carries, and it is the only
    /// parser that may answer the `OSC 7501 ; ?` support query.
    pub(crate) fn callbacks(&self, clipboard: &ClipboardReads) -> Callbacks {
        Callbacks {
            on_pty_write: Some(Box::new({
                let pending = self.pending_responses.clone();
                move |bytes| {
                    pending.lock().recover_poison().extend_from_slice(bytes);
                }
            })),
            on_title_changed: Some(Box::new({
                let title_changed = self.title_changed.clone();
                move || title_changed.store(true, Ordering::Release)
            })),
            on_bell: Some(Box::new({
                let bell = self.bell.clone();
                move || bell.store(true, Ordering::Release)
            })),
            on_clipboard_read: Some(clipboard.callback()),
            on_program_status: Some(crate::program_status::sink(self.program_status.clone())),
        }
    }
}

/// How long a host whose parser panicked waits for its exit to be
/// published before it ends anyway: the termination escalation (SIGHUP,
/// grace, SIGKILL, child wait) plus the launch-owner deadline.
const PARSER_FAILURE_EXIT_BOUND: Duration = Duration::from_secs(10);
/// The process exit status of a host whose parser panicked (EX_SOFTWARE).
pub(crate) const PARSER_FAILURE_EXIT_CODE: i32 = 70;

/// Runs the parser worker `parse` (production: [`run_host_parser`]) on the
/// calling thread. If it panics, the terminal can no longer apply output
/// and nothing else marks the PTY drained, so the host would live forever
/// without an exit. Instead the host ends its child, publishes its exit
/// (bounded wait), and then `end_process` ends the host process.
pub(crate) fn run_guarded_host_parser(
    host: &Arc<HostShared>,
    parse: impl FnOnce(),
    end_process: impl FnOnce(),
) {
    if std::panic::catch_unwind(std::panic::AssertUnwindSafe(parse)).is_ok() {
        return;
    }
    eprintln!("terminal-host: the parser thread panicked; publishing the exit and ending the host");
    if !host.end_after_parser_failure(PARSER_FAILURE_EXIT_BOUND) {
        eprintln!("terminal-host: the exit was not published in time; ending the host anyway");
    }
    end_process();
}

impl HostShared {
    /// Ends a host whose parser is gone. No later byte can be applied, so
    /// the PTY stream counts as drained; the child is ended (the usual
    /// termination escalation), and its reap publishes the exit. True when
    /// the exit was published within `bound`.
    fn end_after_parser_failure(self: &Arc<Self>, bound: Duration) -> bool {
        self.mark_pty_drained();
        self.request_termination();
        self.publish_exit_if_drained();
        self.wait_until_dead(bound)
    }

    /// Waits until the exit is published (`dead`), at most `bound`.
    fn wait_until_dead(&self, bound: Duration) -> bool {
        let deadline = Instant::now() + bound;
        let (lock, published) = &self.parser_progress;
        // Exit publication sets `dead`, then bumps parser progress under
        // this lock, so a check made under the lock cannot miss the wake.
        let mut generation = lock.lock().recover_poison();
        while !self.dead.load(Ordering::Acquire) {
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            generation = published.wait_timeout(generation, deadline - now).recover_poison().0;
        }
        true
    }
}

pub(crate) fn run_host_parser(
    parser_host: Arc<HostShared>,
    parser_command_receiver: Receiver<ParserCommand>,
    initial_colors: TerminalColorOverrides,
    signals: ParserSignals,
) {
    let ParserSignals { pending_responses, title_changed, bell, program_status: _ } = signals;
    // What the legacy (parser-ordered) stream last published. With no
    // legacy client attached nothing is published, and these two go stale;
    // the first chunk a legacy client sees reads them again first (below).
    let mut last_colors = initial_colors;
    let mut last_pwd = None;
    let mut legacy_state_stale = false;
    // The title last sent: one rewritten unchanged is not sent again.
    let mut last_title: Option<String> = None;
    let mut shell_marks = crate::prompt_mode_reset::ShellMarks::default();
    // Ghostty can answer terminal queries without producing a parser
    // frame. Flush those answers after every parser command, not only
    // after PTY output, so lifecycle operations (for example resize
    // during a Pi reload) cannot leave replies queued in memory and
    // deliver them to a later TUI write.
    // The answers go to the PTY on their own thread (`pty_replies`): a
    // program that stops reading its input must never stop this parser.
    let replies = PtyReplies::start({
        let host = parser_host.clone();
        move |bytes| write_to_pty(&host.writer, bytes)
    });
    let flush_pending_responses = || {
        let responses = std::mem::take(&mut *pending_responses.lock().recover_poison());
        replies.send(responses, |bytes| write_to_pty(&parser_host.writer, bytes));
    };
    let mut qos = cmux_interactivity::Follower::new();
    // A command taken off the queue while coalescing Output that was not
    // Output: it runs next, in its place in the order.
    let mut carried: Option<ParserCommand> = None;
    // Output frames joined into one parse (reused across chunks).
    let mut joined: Vec<u8> = Vec::new();
    while let Some(command) = carried.take().or_else(|| parser_command_receiver.recv().ok()) {
        if matches!(command, ParserCommand::Resize(_)) {
            cmux_interactivity::note(cmux_interactivity::InteractionKind::Drag);
        }
        qos.follow(super::host_start::host_work_class());
        match command {
            ParserCommand::Output { frame, source_cursor, accounted_bytes } => {
                // A flood queues Output frames faster than one parse a frame
                // takes them: the ones already queued join this one, so a
                // backlog is one terminal lock, one metadata walk and one
                // `vt_write` (its per-call cost is a third of a 16 KiB
                // frame's parse) instead of one each. It never waits for a
                // frame, so an echo goes out as before (goal
                // terminal-throughput, G6).
                let (source_cursor, accounted_bytes, bytes) = coalesce_queued_parser_output(
                    &parser_command_receiver,
                    &mut carried,
                    &mut joined,
                    &frame,
                    source_cursor,
                    accounted_bytes,
                );
                let bytes = bytes.unwrap_or(frame.payload.as_slice());
                let title = {
                    let mut term = parser_host.term.lock().recover_poison();
                    // A legacy client joins only under this lock (its
                    // snapshot is taken here), so the answer holds for the
                    // whole chunk. The smart stream (the daemon) parses the
                    // raw bytes itself and needs none of the legacy frames.
                    let legacy = !parser_host.taps.lock().recover_poison().is_empty();
                    if legacy && legacy_state_stale {
                        // The new client's snapshot holds the state before
                        // this chunk: compare this chunk's state with that.
                        last_colors = term.color_overrides();
                        last_pwd = term.pwd();
                        legacy_state_stale = false;
                    }
                    // A terminal that cannot report cursor activity reports
                    // no cursor change.
                    let cursor_activity = legacy.then(|| term.cursor_activity().ok());
                    // One walk of the chunk reads its OSC metadata and
                    // rewrites the title ops ghostty-vt skips.
                    let rewritten = parser_host
                        .terminal_metadata
                        .lock()
                        .recover_poison()
                        .observe_output_rewriting_titles(shell_marks.titles_mut(), bytes);
                    let normalized = crate::prompt_mode_reset::write_rewritten_output(
                        &mut term,
                        rewritten,
                        &mut shell_marks,
                    );
                    {
                        let mut metadata = parser_host.terminal_metadata.lock().recover_poison();
                        // Whether a running command took the terminal for
                        // interaction, so an adopting daemon still reads it
                        // `in_use` (cx-6so.59).
                        metadata.observe_modes(|| crate::terminal_activity::terminal_modes(&term));
                    }
                    let title = title_changed
                        .swap(false, Ordering::AcqRel)
                        .then(|| crate::terminal_title::read(&term))
                        .filter(|title| last_title.as_deref() != Some(title.as_str()));
                    if let Some(title) = &title {
                        last_title = Some(title.clone());
                    }
                    if let Some(cursor_activity) = cursor_activity {
                        let pwd = term.pwd();
                        let colors = term.color_overrides();
                        let cursor_changed = term.cursor_activity().ok() != cursor_activity;
                        let colors = if colors != last_colors || cursor_changed {
                            let encoded = encode_terminal_color_overrides(&colors);
                            last_colors = colors;
                            Some(encoded)
                        } else {
                            None
                        };
                        let pwd = changed_pwd_frame(&mut last_pwd, pwd);
                        parser_host.broadcast_frames(output_transition_frames(
                            normalized.into_owned(),
                            colors,
                            pwd,
                        ));
                    } else {
                        legacy_state_stale = true;
                    }
                    // After this chunk's Output, so the owner's mirror shows
                    // what the program printed before it asked.
                    parser_host.clipboard.dispatch(&mut term, &parser_host.broadcast_lock);
                    // The parser lock is also the snapshot lock. Mark
                    // this source cursor before releasing it so a
                    // snapshot cannot include output that its boundary
                    // still describes as unapplied.
                    parser_host.smart.mark_applied(source_cursor);
                    // Keep the host stream watermark on the same side
                    // of the terminal lock as the applied bytes.
                    parser_host.stream_progress.notify();
                    title
                };
                parser_host.note_parser_progress();
                parser_host.parser_budget.release(accounted_bytes);
                if let Some(title) = title {
                    parser_host.broadcast(MessageKind::Title, title.into_bytes());
                }
                if bell.swap(false, Ordering::AcqRel) {
                    parser_host.broadcast(MessageKind::Bell, Vec::new());
                }
                flush_pending_responses();
            }
            ParserCommand::Resize(resize) => {
                let ParserResize {
                    cols,
                    rows,
                    cell_pixels,
                    source_cursor,
                    acknowledge_with_replay,
                    targeted_ack,
                    pty_previous,
                    response,
                } = *resize;
                let result = parser_host.apply_parser_resize_after_pty(
                    cols,
                    rows,
                    source_cursor,
                    acknowledge_with_replay,
                    targeted_ack,
                    cell_pixels,
                    pty_previous,
                );
                flush_pending_responses();
                let _ = response.send(result);
            }
            ParserCommand::SetDefaults { colors, source_cursor, response } => {
                let colors = *colors;
                last_colors = parser_host.apply_parser_defaults(colors, source_cursor);
                flush_pending_responses();
                let _ = response.send(());
            }
            ParserCommand::ClearHistory(clear) => {
                let ParserClearHistory { fallback_key, response } = *clear;
                let result = parser_host
                    .apply_parser_clear_history(fallback_key.as_ref())
                    .map_err(|error| error.to_string());
                if matches!(result, Ok(ParserClearHistoryResult::Cleared(_))) {
                    parser_host.note_parser_progress();
                }
                flush_pending_responses();
                let _ = response.send(result);
            }
            ParserCommand::ClipboardReadComplete { token, text } => {
                parser_host
                    .term
                    .lock()
                    .recover_poison()
                    .complete_clipboard_read(token, text.as_deref());
                flush_pending_responses();
            }
            ParserCommand::Barrier(response) => {
                let _ = response.send(());
            }
            ParserCommand::Drain => {
                // FIFO reception proves every source byte published by
                // the PTY reader has reached the authoritative parser.
                parser_host.clipboard.end(
                    &mut parser_host.term.lock().recover_poison(),
                    &parser_host.broadcast_lock,
                );
                parser_host.mark_pty_drained();
                parser_host.publish_exit_if_drained();
                flush_pending_responses();
                break;
            }
        }
    }
}

/// The most bytes [`coalesce_queued_parser_output`] joins into one parse:
/// as the daemon mirror's `OUTPUT_COALESCE_BYTES`.
pub(crate) const HOST_PARSER_COALESCE_BYTES: usize = 64 * 1024;

/// [`HOST_PARSER_COALESCE_BYTES`], unless `CMUX_HOST_PARSER_COALESCE_BYTES`
/// names another bound (0 parses one frame at a time, as before G6), so the
/// stage bench compares both on one binary and one machine.
fn host_parser_coalesce_bytes() -> usize {
    static BYTES: std::sync::OnceLock<usize> = std::sync::OnceLock::new();
    *BYTES.get_or_init(|| {
        std::env::var("CMUX_HOST_PARSER_COALESCE_BYTES")
            .ok()
            .and_then(|value| value.trim().parse().ok())
            .unwrap_or(HOST_PARSER_COALESCE_BYTES)
    })
}

/// Joins the Output commands already queued behind `frame` (up to
/// [`HOST_PARSER_COALESCE_BYTES`]) into `joined`. Returns the last joined
/// source cursor, the accounted bytes of every joined command, and the joined
/// bytes (`None` when nothing joined: parse `frame` itself, no copy). The
/// first command that is not Output, or would pass the bound, goes to
/// `carried` and runs next. It never waits.
fn coalesce_queued_parser_output<'a>(
    receiver: &Receiver<ParserCommand>,
    carried: &mut Option<ParserCommand>,
    joined: &'a mut Vec<u8>,
    frame: &Frame,
    mut source_cursor: u64,
    mut accounted_bytes: usize,
) -> (u64, usize, Option<&'a [u8]>) {
    joined.clear();
    let bound = host_parser_coalesce_bytes();
    let mut total = frame.payload.len();
    while total < bound
        && let Ok(next) = receiver.try_recv()
    {
        match next {
            ParserCommand::Output {
                frame: more,
                source_cursor: more_cursor,
                accounted_bytes: more_accounted,
            } if total.saturating_add(more.payload.len()) <= bound => {
                if joined.is_empty() {
                    joined.reserve(bound);
                    joined.extend_from_slice(&frame.payload);
                }
                joined.extend_from_slice(&more.payload);
                total = total.saturating_add(more.payload.len());
                source_cursor = more_cursor;
                accounted_bytes = accounted_bytes.saturating_add(more_accounted);
            }
            other => {
                *carried = Some(other);
                break;
            }
        }
    }
    let bytes = (!joined.is_empty()).then_some(joined.as_slice());
    (source_cursor, accounted_bytes, bytes)
}
