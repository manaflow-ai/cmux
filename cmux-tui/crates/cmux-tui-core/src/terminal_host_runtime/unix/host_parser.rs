//! The authoritative parser worker of one terminal host. It applies PTY
//! output and lifecycle commands to the host's Ghostty terminal in order and
//! flushes the terminal's own replies (queries, clipboard reads) to the PTY
//! after every command.

use super::*;

/// State the parser shares with the terminal's callbacks.
pub(super) struct ParserSignals {
    pub(super) pending_responses: Arc<Mutex<Vec<u8>>>,
    pub(super) title_changed: Arc<AtomicBool>,
    pub(super) bell: Arc<AtomicBool>,
}

impl ParserSignals {
    pub(super) fn new() -> Self {
        Self {
            pending_responses: Arc::new(Mutex::new(Vec::new())),
            title_changed: Arc::new(AtomicBool::new(false)),
            bell: Arc::new(AtomicBool::new(false)),
        }
    }

    /// The callbacks of the host's authoritative terminal. The host keeps no
    /// program status records (the daemon's mirror keeps them), but it is
    /// the only parser that may answer the `OSC 7501 ; ?` support query.
    pub(super) fn callbacks(&self, clipboard: &ClipboardReads) -> Callbacks {
        Callbacks {
            on_pty_write: Some(Box::new({
                let pending = self.pending_responses.clone();
                move |bytes| pending.lock().unwrap().extend_from_slice(bytes)
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
            on_program_status: Some(crate::program_status::query_only_sink()),
        }
    }
}

/// How long a host whose parser panicked waits for its exit to be
/// published before it ends anyway: the termination escalation (SIGHUP,
/// grace, SIGKILL, child wait) plus the launch-owner deadline.
const PARSER_FAILURE_EXIT_BOUND: Duration = Duration::from_secs(10);
/// The process exit status of a host whose parser panicked (EX_SOFTWARE).
pub(super) const PARSER_FAILURE_EXIT_CODE: i32 = 70;

/// Runs the parser worker `parse` (production: [`run_host_parser`]) on the
/// calling thread. If it panics, the terminal can no longer apply output
/// and nothing else marks the PTY drained, so the host would live forever
/// without an exit. Instead the host ends its child, publishes its exit
/// (bounded wait), and then `end_process` ends the host process.
pub(super) fn run_guarded_host_parser(
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
        let mut generation = lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        while !self.dead.load(Ordering::Acquire) {
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            generation = published
                .wait_timeout(generation, deadline - now)
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .0;
        }
        true
    }
}

pub(super) fn run_host_parser(
    parser_host: Arc<HostShared>,
    parser_command_receiver: Receiver<ParserCommand>,
    initial_colors: TerminalColorOverrides,
    signals: ParserSignals,
) {
    let ParserSignals { pending_responses, title_changed, bell } = signals;
    let mut last_colors = initial_colors;
    let mut last_pwd = None;
    // Ghostty can answer terminal queries without producing a parser
    // frame. Flush those answers after every parser command, not only
    // after PTY output, so lifecycle operations (for example resize
    // during a Pi reload) cannot leave replies queued in memory and
    // deliver them to a later TUI write.
    let flush_pending_responses = || {
        let responses = std::mem::take(&mut *pending_responses.lock().unwrap());
        if !responses.is_empty() {
            let mut writer = parser_host.writer.lock().unwrap();
            let _ = writer.write_all(&responses);
            let _ = writer.flush();
        }
    };
    while let Ok(command) = parser_command_receiver.recv() {
        match command {
            ParserCommand::Output { bytes, source_cursor, accounted_bytes } => {
                let title = {
                    let mut term = parser_host.term.lock().unwrap();
                    let cursor_activity = term
                        .cursor_activity()
                        .expect("valid host terminals expose cursor activity");
                    let normalized = term.vt_write_with_normalized(&bytes).into_owned();
                    parser_host.terminal_metadata.lock().unwrap().observe_output(&bytes);
                    let title = title_changed
                        .swap(false, Ordering::AcqRel)
                        .then(|| term.title().unwrap_or_default());
                    let pwd = term.pwd();
                    let colors = term.color_overrides();
                    let cursor_changed = term
                        .cursor_activity()
                        .expect("valid host terminals expose cursor activity")
                        != cursor_activity;
                    let colors = if colors != last_colors || cursor_changed {
                        let encoded = encode_terminal_color_overrides(&colors);
                        last_colors = colors;
                        Some(encoded)
                    } else {
                        None
                    };
                    let pwd = changed_pwd_frame(&mut last_pwd, pwd);
                    parser_host.broadcast_frames(output_transition_frames(normalized, colors, pwd));
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
            ParserCommand::Resize {
                cols,
                rows,
                cell_pixels,
                source_cursor,
                acknowledge_with_replay,
                targeted_ack,
                response,
            } => {
                let result = parser_host.apply_parser_resize(
                    cols,
                    rows,
                    source_cursor,
                    acknowledge_with_replay,
                    targeted_ack,
                    cell_pixels,
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
            ParserCommand::ClearHistory { fallback_key, response } => {
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
                parser_host.term.lock().unwrap().complete_clipboard_read(token, text.as_deref());
                flush_pending_responses();
            }
            ParserCommand::Barrier(response) => {
                let _ = response.send(());
            }
            ParserCommand::Drain => {
                // FIFO reception proves every source byte published by
                // the PTY reader has reached the authoritative parser.
                parser_host
                    .clipboard
                    .end(&mut parser_host.term.lock().unwrap(), &parser_host.broadcast_lock);
                parser_host.mark_pty_drained();
                parser_host.publish_exit_if_drained();
                flush_pending_responses();
                break;
            }
        }
    }
}
