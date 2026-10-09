//! The host-side terminal state shared by the PTY reader, the parser, the
//! accept loop and every client thread (cx-ko2e table B). The OS edges sit
//! behind `sys` seams: the accept waker, the PTY drain waker stream, the
//! adopted session id, and process-group signals (`GroupSignal`).

use std::collections::HashMap;
use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, SyncSender, sync_channel};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::Context;
use cmux_pty::{ChildKiller, MasterPty};
use ghostty_vt::Terminal;

use super::super::sys::{self, GroupSignal, HostStream};
use super::super::*;
use super::clipboard_read::ClipboardReads;
use super::codec::*;
use super::host_state::*;
use super::records::*;

mod lifecycle;
mod resize;

pub(crate) struct HostShared {
    pub(crate) terminal_id: TerminalId,
    pub(crate) incarnation: HostIncarnation,
    pub(crate) owner_token: CapabilityToken,
    pub(crate) capabilities: CapabilityStore,
    pub(crate) term: Mutex<Terminal>,
    /// Generic metadata parsed from the same ordered PTY bytes as the
    /// authoritative terminal. Snapshot code takes this after `term`,
    /// preserving one metadata boundary for reconnecting mirrors.
    pub(crate) terminal_metadata: Mutex<crate::terminal_metadata::TerminalMetadata>,
    pub(crate) default_colors: Mutex<DefaultColors>,
    pub(crate) stream_progress: TerminalStreamProgress,
    pub(crate) writer: Mutex<Box<dyn Write + Send>>,
    pub(crate) master: Mutex<Box<dyn MasterPty + Send>>,
    pub(crate) killer: Mutex<Box<dyn ChildKiller + Send>>,
    pub(crate) pid: Option<u32>,
    pub(crate) command: Vec<String>,
    pub(crate) cwd: Option<String>,
    pub(crate) size: Mutex<(u16, u16)>,
    pub(crate) cell_pixels: Mutex<(u16, u16)>,
    pub(crate) viewer_sizes: Mutex<ViewerSizes>,
    pub(crate) taps: Mutex<HashMap<u64, HostTap>>,
    pub(crate) broadcast_lock: Mutex<()>,
    pub(crate) sequence: AtomicU64,
    pub(crate) smart: SmartStreamState,
    /// Orders source-cursor allocation and parser-command enqueueing. A
    /// resize keeps this lock until all prior parser commands drain, which
    /// gives both the host and smart clients the same output/resize order.
    pub(crate) source_order_lock: Mutex<()>,
    pub(crate) parser_commands: SyncSender<ParserCommand>,
    pub(crate) parser_budget: ParserBudget,
    pub(crate) clipboard: ClipboardReads,
    /// Generation advanced after each parser write. Snapshot admission
    /// waits here when a PTY read ends inside UTF-8 or a control sequence,
    /// without blocking the reader from enqueueing the completing bytes.
    pub(crate) parser_progress: (Mutex<u64>, Condvar),
    pub(crate) next_client: AtomicU64,
    pub(crate) dead: AtomicBool,
    pub(crate) launch_owner_claimed: AtomicBool,
    pub(crate) launch_owner_stream_ready: AtomicBool,
    pub(crate) launch_owner_stream_gate: (Mutex<()>, Condvar),
    pub(crate) active_client_streams: AtomicUsize,
    /// Wakes the host's accept loop when `dead` or
    /// `active_client_streams` change, so the loop blocks instead of
    /// polling them.
    pub(crate) accept_waker: sys::AcceptWaker,
    pub(crate) child_exit: (Mutex<Option<TerminalExit>>, Condvar),
    pub(crate) child_waitable: AtomicBool,
    pub(crate) pty_drained: AtomicBool,
    pub(crate) exit_published: AtomicBool,
    pub(crate) exit_record_path: PathBuf,
    pub(crate) exit_publish_requests: Sender<()>,
    pub(crate) force_pty_drain: AtomicBool,
    pub(crate) pty_drain_waker: Mutex<HostStream>,
    pub(crate) termination_started: AtomicBool,
    pub(crate) child_signal_lock: Mutex<()>,
    pub(crate) child_reaped: AtomicBool,
    pub(crate) group_escalation_complete: AtomicBool,
    #[cfg(unix)]
    pub(crate) group_escalation_failed: AtomicBool,
    #[cfg(unix)]
    pub(crate) session_cleanup: crate::terminal_host_runtime::unix::session_cleanup::SessionCleanup,
    /// Session of an adopted, non-child process (`adopted_child.rs`).
    pub(crate) adopted_session: Option<sys::SessionId>,
    #[cfg(test)]
    pub(crate) fail_next_resize_publication: AtomicBool,
}

impl HostShared {
    pub(crate) fn mark_launch_owner_stream_ready(&self) {
        let _gate = self.launch_owner_stream_gate.0.lock().unwrap();
        if !self.launch_owner_stream_ready.swap(true, Ordering::AcqRel) {
            self.launch_owner_stream_gate.1.notify_all();
        }
        self.publish_exit_if_drained();
    }

    pub(crate) fn wait_for_launch_owner_stream_ready(&self) {
        if self.launch_owner_stream_ready.load(Ordering::Acquire) {
            return;
        }
        let mut gate = self.launch_owner_stream_gate.0.lock().unwrap();
        while !self.launch_owner_stream_ready.load(Ordering::Acquire) {
            gate = self.launch_owner_stream_gate.1.wait(gate).unwrap();
        }
    }

    pub(crate) fn note_parser_progress(&self) {
        let mut generation = self.parser_progress.0.lock().unwrap();
        *generation = generation.wrapping_add(1);
        self.parser_progress.1.notify_all();
    }

    pub(crate) fn terminal_at_snapshot_boundary(
        &self,
        timeout: Duration,
    ) -> anyhow::Result<std::sync::MutexGuard<'_, Terminal>> {
        let deadline = Instant::now() + timeout;
        let mut generation = self.parser_progress.0.lock().unwrap();
        loop {
            let term = self.term.lock().unwrap();
            if term.vt_stream_is_ground() {
                drop(generation);
                return Ok(term);
            }
            drop(term);
            if self.dead.load(Ordering::Acquire) {
                anyhow::bail!("terminal host exited before a safe snapshot boundary");
            }

            let now = Instant::now();
            if now >= deadline {
                anyhow::bail!(
                    "terminal VT stream did not reach a safe snapshot boundary before timeout"
                );
            }
            let observed = *generation;
            let (next, wait) = self
                .parser_progress
                .1
                .wait_timeout_while(generation, deadline - now, |current| {
                    *current == observed && !self.dead.load(Ordering::Acquire)
                })
                .unwrap();
            generation = next;
            if wait.timed_out() && *generation == observed {
                anyhow::bail!(
                    "terminal VT stream did not reach a safe snapshot boundary before timeout"
                );
            }
        }
    }

    pub(crate) fn broadcast(&self, kind: MessageKind, payload: Vec<u8>) {
        self.broadcast_frames([Frame::new(kind, payload)]);
    }

    pub(crate) fn broadcast_frames(&self, frames: impl IntoIterator<Item = Frame>) {
        publish_host_frames(&self.broadcast_lock, &self.sequence, &self.taps, frames);
    }

    pub(crate) fn broadcast_with_colors(
        &self,
        kind: MessageKind,
        payload: Vec<u8>,
        colors: Vec<u8>,
    ) {
        debug_assert!(matches!(kind, MessageKind::Output | MessageKind::Resized));
        let mut first = Frame::new(kind, payload);
        first.flags = FLAG_COLORS_FOLLOW;
        self.broadcast_frames([first, Frame::new(MessageKind::Colors, colors)]);
    }

    pub(crate) fn set_default_colors(&self, colors: DefaultColors) {
        // Default changes have no raw VT representation. Order an
        // explicit resync marker with PTY bytes, then apply the defaults
        // on the FIFO parser worker before advancing its snapshot
        // boundary. Legacy mirrors retain their coupled color update.
        let _source_order = self.source_order_lock.lock().unwrap();
        if *self.default_colors.lock().unwrap() == colors {
            return;
        }
        let source_cursor = self.smart.publish(Frame::new(MessageKind::ResyncRequired, Vec::new()));
        let (response, applied) = sync_channel(1);
        if self
            .parser_commands
            .send(ParserCommand::SetDefaults { colors: Box::new(colors), source_cursor, response })
            .is_err()
        {
            self.smart.mark_applied(source_cursor);
            return;
        }
        if applied.recv().is_ok() {
            *self.default_colors.lock().unwrap() = colors;
        } else {
            self.smart.mark_applied(source_cursor);
        }
    }

    pub(crate) fn apply_parser_defaults(
        &self,
        colors: DefaultColors,
        source_cursor: u64,
    ) -> TerminalColorOverrides {
        let resolved = {
            let mut term = self.term.lock().unwrap();
            term.replace_default_colors(colors.fg, colors.bg, colors.cursor);
            term.set_default_palette(&colors.palette);
            replace_ghostty_cursor_defaults(&mut term, colors);
            let resolved = term.color_overrides();
            // An empty coupled Output is an ordered state transition
            // already understood by every legacy v2 consumer. Smart
            // clients reopen from the ResyncRequired snapshot boundary
            // published by the command submitter.
            self.broadcast_with_colors(
                MessageKind::Output,
                Vec::new(),
                encode_terminal_color_overrides(&resolved),
            );
            self.smart.mark_applied(source_cursor);
            resolved
        };
        self.note_parser_progress();
        resolved
    }

    pub(crate) fn clear_history_or_encode_key(
        &self,
        fallback_key: Option<&KeyInput>,
        smart_ack: Option<(u64, &HostTap)>,
    ) -> Result<ClearHistoryAckDisposition, ClearHistoryFailure> {
        let mut observed_progress = self.stream_progress.revision();
        let mut stream_wait = None;
        loop {
            // Clear-history observes and mutates parser state. Keep its
            // command in the same FIFO as PTY output while holding source
            // order so neither already-read nor later bytes can cross the
            // emulator-only transition.
            let (result, acknowledgement) = {
                let _source_order = self.source_order_lock.lock().unwrap();
                let (response, applied) = sync_channel(1);
                if self
                    .parser_commands
                    .send(ParserCommand::ClearHistory {
                        fallback_key: fallback_key.cloned(),
                        response,
                    })
                    .is_err()
                {
                    return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                        "terminal parser worker stopped"
                    )));
                }
                let result = applied
                    .recv()
                    .map_err(|_| {
                        ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                            "terminal parser worker stopped"
                        ))
                    })?
                    .map_err(|error| {
                        ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(error))
                    })?;
                let acknowledgement = match &result {
                    ParserClearHistoryResult::Cleared(clear) => {
                        let marker = Frame::new(MessageKind::ResyncRequired, Vec::new());
                        let (source_cursor, acknowledgement) = if let Some((request_id, target)) =
                            smart_ack
                        {
                            let mut payload = Vec::with_capacity(1 + clear.len());
                            payload.push(CLEAR_HISTORY_ACK_OK);
                            payload.extend_from_slice(clear);
                            let mut response = Frame::new(MessageKind::ClearHistoryAck, payload);
                            response.request_id = request_id;
                            let (source_cursor, queued) =
                                self.smart.publish_after_targeted(target, response, marker);
                            (
                                source_cursor,
                                if queued {
                                    ClearHistoryAckDisposition::Queued
                                } else {
                                    ClearHistoryAckDisposition::ConnectionClosed
                                },
                            )
                        } else {
                            (self.smart.publish(marker), ClearHistoryAckDisposition::Pending)
                        };
                        self.smart.mark_applied(source_cursor);
                        Some(acknowledgement)
                    }
                    _ => None,
                };
                (result, acknowledgement)
            };
            match result {
                ParserClearHistoryResult::Cleared(_) => {
                    return Ok(acknowledgement
                        .expect("a cleared parser transition has an acknowledgement"));
                }
                ParserClearHistoryResult::Noop => {
                    return Ok(ClearHistoryAckDisposition::Pending);
                }
                ParserClearHistoryResult::Blocked => {
                    let deadline = stream_wait
                        .get_or_insert_with(|| {
                            self.stream_progress
                                .begin_clear_history_wait(CLEAR_HISTORY_STREAM_WAIT_TIMEOUT)
                        })
                        .deadline();
                    let Some(progress) =
                        self.stream_progress.wait_for_change(observed_progress, deadline)
                    else {
                        stream_wait.as_mut().unwrap().mark_timed_out();
                        return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                            CLEAR_HISTORY_STREAM_TIMEOUT_ERROR
                        )));
                    };
                    observed_progress = progress;
                }
                ParserClearHistoryResult::EncodedFallback(encoded) => {
                    let mut writer = self.writer.lock().unwrap();
                    let master = self.master.lock().unwrap();
                    return write_clear_history_fallback(
                        master.as_ref(),
                        writer.as_mut(),
                        &encoded,
                    )
                    .map(|()| ClearHistoryAckDisposition::Pending);
                }
            }
        }
    }

    pub(crate) fn apply_parser_clear_history(
        &self,
        fallback_key: Option<&KeyInput>,
    ) -> anyhow::Result<ParserClearHistoryResult> {
        let mut term = self.term.lock().unwrap();
        Ok(match apply_clear_history_transition(&mut term, fallback_key)? {
            ClearHistoryTransition::Cleared(clear) => {
                // Legacy mirrors consume this replay directly. The
                // command submitter publishes the smart resync marker
                // while it still owns source order.
                self.broadcast(MessageKind::Output, clear.clone());
                self.stream_progress.notify();
                ParserClearHistoryResult::Cleared(clear)
            }
            ClearHistoryTransition::Blocked => ParserClearHistoryResult::Blocked,
            ClearHistoryTransition::EncodedFallback(encoded) => {
                ParserClearHistoryResult::EncodedFallback(encoded)
            }
            ClearHistoryTransition::Noop => ParserClearHistoryResult::Noop,
        })
    }

    pub(crate) fn remove_client(&self, client: u64) {
        self.release_clipboard_owner(client);
        self.taps.lock().unwrap().remove(&client);
        self.smart.remove(client);
        let _ = mutate_viewer_sizes(
            &self.viewer_sizes,
            |viewer_sizes| viewer_sizes.remove_client(client),
            |desired| self.apply_viewer_minimum(desired, false, None).map(|_| ()),
        );
    }

    pub(crate) fn write_input(&self, payload: &[u8], request_id: u64, target: &HostTap) -> bool {
        let delivered = {
            let mut writer = self.writer.lock().unwrap();
            writer.write_all(payload).and_then(|()| writer.flush()).is_ok()
        };
        // Interactive input has always been best-effort. Only a nonzero
        // request id asks the authoritative host to certify delivery.
        if request_id == 0 {
            return true;
        }
        if !delivered {
            return false;
        }
        let mut response = Frame::new(MessageKind::InputAck, Vec::new());
        response.request_id = request_id;
        let _broadcast = self.broadcast_lock.lock().unwrap();
        target.try_send(response)
    }

    pub(crate) fn fence_client_detach(
        &self,
        client: u64,
        request_id: u64,
        target: &HostTap,
    ) -> bool {
        let mut response = Frame::new(MessageKind::DetachAck, Vec::new());
        response.request_id = request_id;
        let _source_order = self.source_order_lock.lock().unwrap();
        self.taps.lock().unwrap().remove(&client);
        self.smart.remove(client);
        target.try_send(response)
    }
}
