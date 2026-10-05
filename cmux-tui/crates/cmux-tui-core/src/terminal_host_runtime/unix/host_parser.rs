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
                    parser_host.clipboard.dispatch(&mut term, &parser_host.broadcast_lock);
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
            ParserCommand::Drain => {
                // FIFO reception proves every source byte published by
                // the PTY reader has reached the authoritative parser.
                parser_host.clipboard.end(&mut parser_host.term.lock().unwrap());
                parser_host.mark_pty_drained();
                parser_host.publish_exit_if_drained();
                flush_pending_responses();
                break;
            }
        }
    }
}
