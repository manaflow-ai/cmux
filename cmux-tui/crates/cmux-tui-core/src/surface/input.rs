//! Input delivery on `Surface`: raw and receipted writes and bounded paste.
//!
//! Every write takes a turn of the terminal's input FIFO
//! ([`crate::pty_input_fifo::PtyInputFifo`]) and writes all of its bytes in it.
//! A caller whose one input is several writes (`send`: text, bytes and its
//! Return) takes one turn with [`Surface::input_turn`] and writes each part
//! with the `_in` variants, so no other input lands between them.

use super::*;
use crate::pty_input_fifo::InputTurn;
use std::sync::PoisonError;

/// How long hosted input waits for a lost host connection to come back (a
/// reconnect or an in-place replacement host, cx-6so.49) before it fails.
///
/// The wait blocks its caller: one control connection's next request, or
/// the TUI's input worker. It applies only while a host connection is lost,
/// and a replacement host usually installs within a second.
#[cfg(any(unix, windows))]
pub(super) const HOST_INPUT_RECONNECT_WAIT: Duration = Duration::from_secs(5);

/// Whether a host send failed because the host connection is gone (the
/// host died or its stream broke), not because the frame was refused.
#[cfg(any(unix, windows))]
pub(super) fn host_connection_lost(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::BrokenPipe
            | std::io::ErrorKind::ConnectionReset
            | std::io::ErrorKind::ConnectionAborted
            | std::io::ErrorKind::NotConnected
    )
}

/// The holder that runs `pty`'s shell, if one does, when a key press `flow`
/// (not 0) needs it. The runtime lock is released on return, so the holder
/// link's send never runs under it.
#[cfg(unix)]
fn flow_holder(pty: &PtySurface, flow: u64) -> Option<Arc<crate::holder_runtime::HolderTerminal>> {
    if flow == 0 {
        return None;
    }
    match &*pty.runtime.lock().unwrap_or_else(PoisonError::into_inner) {
        PtyRuntime::Local { holder, .. } => holder.clone(),
        _ => None,
    }
}

#[cfg(unix)]
impl From<crate::pty_write::DeliveryFailure> for ConfirmedInputFailure {
    fn from(failure: crate::pty_write::DeliveryFailure) -> Self {
        match failure {
            crate::pty_write::DeliveryFailure::NotDelivered(error) => Self::Known(error),
            crate::pty_write::DeliveryFailure::Partial(error) => Self::Indeterminate(error),
        }
    }
}

/// The error of an input write to a browser surface.
fn not_a_terminal() -> std::io::Error {
    std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "browser surface does not accept PTY bytes",
    )
}

impl Surface {
    /// Takes this terminal's next input turn, after every input that took
    /// one before it (any connection, any thread); `None` for a browser
    /// surface. The `_in` writes take it; every other write takes its own.
    /// It ranks after `Mux::state` (crate::lock_rank `PtyInput`): take the
    /// state lock, the registry and the creating-input flush before it.
    #[track_caller]
    pub(crate) fn input_turn(&self) -> Option<InputTurn<'_>> {
        self.as_pty().map(|pty| pty.input_fifo.enter())
    }

    /// The PTY surface `turn` is a turn of.
    fn pty_in(&self, turn: &InputTurn<'_>) -> std::io::Result<&PtySurface> {
        let pty = self.as_pty().ok_or_else(not_a_terminal)?;
        debug_assert!(turn.is_of(&pty.input_fifo), "an input turn of another terminal");
        Ok(pty)
    }

    /// Write input bytes to the PTY child.
    pub fn write_bytes(&self, bytes: &[u8]) -> std::io::Result<()> {
        self.write_bytes_flow(bytes, 0)
    }

    /// [`Self::write_bytes_flow`] of a key press the daemon received at
    /// `received_ns` (trace clock; 0: unknown): the terminal's stage ring
    /// records the receive before the write, since the echo
    /// can be read before the write returns, and the PTY write after it.
    /// Tests only: `send` writes its parts in one turn ([`Self::write_key_flow_in`]).
    #[cfg(test)]
    pub(crate) fn write_key_flow(
        &self,
        bytes: &[u8],
        flow: u64,
        received_ns: u64,
    ) -> std::io::Result<()> {
        let turn = self.input_turn().ok_or_else(not_a_terminal)?;
        self.write_key_flow_in(&turn, bytes, flow, received_ns)
    }

    /// [`Self::write_key_flow`] in the input turn `turn` of this terminal.
    pub(crate) fn write_key_flow_in(
        &self,
        turn: &InputTurn<'_>,
        bytes: &[u8],
        flow: u64,
        received_ns: u64,
    ) -> std::io::Result<()> {
        let stages = self.as_pty().map(|pty| &*pty.input_stages);
        if let Some(stages) = stages {
            stages.received(flow, received_ns);
        }
        let result = self.write_bytes_in(turn, bytes, flow);
        if let (Ok(()), Some(stages)) = (&result, stages)
            && flow != 0
        {
            stages.written(flow, crate::input_stages::now_ns());
        }
        result
    }

    /// The terminal's key-stage ring; `None` for a browser surface.
    pub(crate) fn input_stages(&self) -> Option<Arc<crate::input_stages::InputStageRing>> {
        self.as_pty().map(|pty| pty.input_stages.clone())
    }

    /// [`Self::write_bytes`] of the key press `flow` (0: none).
    /// The PTY owner's first read after the bytes
    /// reached the PTY echoes it, and that read's `output` event carries
    /// `flow`, once: a hosted terminal's host stamps its read
    /// (`FLAG_INPUT_FLOW`); a master the daemon writes itself, its reader's
    /// next read (a holder terminal's: the holder's next output). Input
    /// that is dropped or fails arms nothing.
    pub(crate) fn write_bytes_flow(&self, bytes: &[u8], flow: u64) -> std::io::Result<()> {
        let turn = self.input_turn().ok_or_else(not_a_terminal)?;
        self.write_bytes_in(&turn, bytes, flow)
    }

    /// [`Self::write_bytes_flow`] in the input turn `turn` of this terminal.
    pub(crate) fn write_bytes_in(
        &self,
        turn: &InputTurn<'_>,
        bytes: &[u8],
        flow: u64,
    ) -> std::io::Result<()> {
        let pty = self.pty_in(turn)?;
        #[cfg(any(unix, windows))]
        if let Some(result) = Self::send_hosted_input(turn, pty, MessageKind::Input, bytes, flow) {
            return result;
        }
        // Not hosted: the daemon writes the PTY itself (the holder model's custody master). Marked
        // before the runtime lock, so the mark never runs under it.
        cmux_flow_trace::hop("daemon.pty.write", flow, pty.flow_terminal_id());
        // The slot of the reader that reads the echo: a holder terminal's sink (the holder gets
        // its flow mark before the bytes), else the terminal's own.
        #[cfg(unix)]
        let holder = flow_holder(pty, flow);
        #[cfg(unix)]
        if let Some(holder) = holder.as_ref() {
            holder.mark_input_flow(flow);
        }
        #[cfg(unix)]
        let slot = holder.as_ref().map_or(&pty.last_input_flow, |holder| &holder.sink.input_flow);
        #[cfg(not(unix))]
        let slot = &pty.last_input_flow;
        // Armed before the write: the echo can be read before the write returns.
        slot.arm(flow);
        let reached_pty = {
            let mut runtime = pty.runtime.lock().unwrap_or_else(PoisonError::into_inner);
            // A holder terminal's `pty-writer` queue takes the bytes in the
            // key lane: the request never waits for the child.
            #[cfg(unix)]
            let queued = match &*runtime {
                PtyRuntime::Local { master, holder: Some(holder), .. } => {
                    holder.input().map(|input| {
                        let master = master.as_deref().map(|master| master as &dyn MasterPty);
                        crate::pty_input_room::queue_input(master, input, bytes)
                    })
                }
                _ => None,
            };
            #[cfg(not(unix))]
            let queued = None;
            if let Some(queued) = queued {
                queued
            } else {
                match &mut *runtime {
                    PtyRuntime::Local { writer, master, .. } => {
                        let master = master.as_deref().map(|master| master as &dyn MasterPty);
                        // Waits while the child does not read its input.
                        crate::request_path::will_block(|| {
                            crate::pty_input_room::write_input(master, writer.as_mut(), bytes)
                        })
                    }
                    // The host stamps its own read of the echo.
                    #[cfg(any(unix, windows))]
                    PtyRuntime::Hosted(host) => crate::request_path::will_block(|| {
                        host.send_flow(MessageKind::Input, bytes, flow).map(|()| false)
                    }),
                    // A keep-on-exit terminal outlives its child, so typing into the
                    // dead PTY is an expected interaction: drop the bytes silently
                    // instead of failing every keystroke on the final screen.
                    #[cfg(any(unix, windows))]
                    PtyRuntime::ExitedHosted => Ok(false),
                }
            }
        };
        // Dropped, handed to a host, or failed: no echo of this write comes to this slot.
        if !matches!(reached_pty, Ok(true)) {
            slot.withdraw(flow);
        }
        reached_pty.map(|_| ())
    }

    /// Send input to a hosted terminal's host, across a lost host
    /// connection (cx-6so.49). A host that died or whose stream broke has a
    /// dead connection until the surface reader installs the reconnected or
    /// replacement host; a send in that window fails with EPIPE although the
    /// shell lives. Such a send waits for the reader's next stream change
    /// (it notifies after it installed the new attachment) and is sent again
    /// to the new host, until [`HOST_INPUT_RECONNECT_WAIT`] passed since the
    /// input asked for its `turn` ([`InputTurn::queued_at`]: inputs queued
    /// during one outage wait it out together) or the reader gives up or
    /// ends. A frame that failed with a lost connection never
    /// reached a live reader, so the retry cannot duplicate it. `None` when
    /// the runtime is not hosted (the caller writes locally).
    #[cfg(any(unix, windows))]
    fn send_hosted_input(
        turn: &InputTurn<'_>,
        pty: &PtySurface,
        kind: MessageKind,
        bytes: &[u8],
        flow: u64,
    ) -> Option<std::io::Result<()>> {
        let deadline = turn.queued_at() + HOST_INPUT_RECONNECT_WAIT;
        let mut first_error = None;
        loop {
            // Read the revision before the send: an install after it wakes
            // the wait below, so no reconnect is missed.
            let observed = pty.stream_progress.revision();
            let sent = match &*pty.runtime.lock().unwrap_or_else(PoisonError::into_inner) {
                // Waits while the host does not read its socket.
                PtyRuntime::Hosted(host) => {
                    crate::request_path::will_block(|| host.send_flow(kind, bytes, flow))
                }
                // Keep-on-exit: the final screen drops input (see
                // write_bytes). Input that already failed to reach the host
                // did not arrive: it keeps its error.
                PtyRuntime::ExitedHosted => return Some(first_error.map_or(Ok(()), Err)),
                PtyRuntime::Local { .. } => return None,
            };
            let error = match sent {
                Ok(()) => return Some(Ok(())),
                Err(error) if host_connection_lost(&error) => error,
                Err(error) => return Some(Err(error)),
            };
            let error = first_error.take().unwrap_or(error);
            let state = TerminalHostConnectionState::from_u8(
                pty.host_connection_state.load(Ordering::Acquire),
            );
            // Stop when nothing will install a new host: the reader gave up,
            // ended, or the owner detaches the terminal.
            if matches!(
                state,
                TerminalHostConnectionState::Failed | TerminalHostConnectionState::Exited
            ) || pty.reader_completion.is_complete()
                || pty.owner_detaching.load(Ordering::Acquire)
                || Instant::now() >= deadline
                || crate::request_path::will_block(|| {
                    pty.stream_progress.wait_for_change(observed, deadline)
                })
                .is_none()
            {
                return Some(Err(error));
            }
            first_error = Some(error);
        }
    }

    /// Write receipted input bytes and wait for authoritative PTY-owner delivery.
    ///
    /// Hosted input registers and writes its targeted request while holding the
    /// short runtime lock, then releases that lock before waiting for `InputAck`.
    /// Other receipted writes can therefore enter the host channel while an
    /// earlier caller is waiting. Interactive input continues to use `write_bytes`.
    pub(crate) fn write_bytes_confirmed(&self, bytes: &[u8]) -> Result<(), ConfirmedInputFailure> {
        let Some(pty) = self.as_pty() else {
            return Err(ConfirmedInputFailure::Known(not_a_terminal()));
        };
        // The request is sent in its turn; its acknowledgement is awaited
        // after the turn ended, as after the runtime lock.
        let turn = pty.input_fifo.enter();
        let mut runtime = pty.runtime.lock().unwrap_or_else(PoisonError::into_inner);
        // A holder terminal's `pty-writer` queue takes the bytes after every
        // earlier input and answers once its PTY took the last one. The wait
        // runs after the runtime lock and the input turn are released.
        #[cfg(unix)]
        if let PtyRuntime::Local { holder: Some(holder), .. } = &*runtime
            && let Some(input) = holder.input()
        {
            let receipt = input
                .send_receipted(bytes, crate::pty_write::InputLane::Bulk)
                .map_err(ConfirmedInputFailure::Known)?;
            drop(runtime);
            drop(turn);
            return crate::request_path::will_block(|| receipt.wait())
                .map_err(ConfirmedInputFailure::from);
        }
        match &mut *runtime {
            PtyRuntime::Local { writer, .. } => crate::request_path::will_block(|| {
                writer.write_all(bytes).and_then(|()| writer.flush())
            })
            .map_err(ConfirmedInputFailure::Indeterminate),
            #[cfg(any(unix, windows))]
            PtyRuntime::Hosted(host) => {
                let receipt = host.begin_input_confirmed(bytes)?;
                drop(runtime);
                drop(turn);
                crate::request_path::will_block(|| receipt.wait())
                    .map_err(ConfirmedInputFailure::Indeterminate)
            }
            // Receipted input confirms delivery to the PTY owner, and a kept
            // terminal's child is gone, so the write fails before any effect
            // with a known error instead of claiming the bytes arrived.
            // Unreceipted keystrokes to the final screen stay a silent no-op
            // (`write_bytes`).
            #[cfg(any(unix, windows))]
            PtyRuntime::ExitedHosted => Err(ConfirmedInputFailure::Known(std::io::Error::new(
                std::io::ErrorKind::NotConnected,
                "terminal has no live PTY owner for receipted input",
            ))),
        }
    }

    /// Write a protocol input payload, conditionally applying bracketed-paste
    /// markers from a terminal-mode snapshot taken before the PTY write.
    pub fn write_paste(&self, bytes: &[u8]) -> std::io::Result<()> {
        self.write_paste_with_timeout(bytes, None)
    }

    /// Write a paste with a bounded local PTY write for daemon-owned uploads.
    ///
    /// Hosted attachments already enforce their socket write deadline. Local
    /// PTY masters are switched to nonblocking mode for this operation and
    /// polled until the same two-second bound, so a full PTY cannot retain an
    /// image-paste reservation indefinitely.
    pub(crate) fn write_paste_bounded(&self, bytes: &[u8]) -> std::io::Result<()> {
        self.write_paste_with_timeout(bytes, Some(LOCAL_PASTE_WRITE_TIMEOUT))
    }

    pub(super) fn write_paste_with_timeout(
        &self,
        bytes: &[u8],
        timeout: Option<Duration>,
    ) -> std::io::Result<()> {
        let turn = self.input_turn().ok_or_else(not_a_terminal)?;
        self.write_paste_in(&turn, bytes, timeout)
    }

    /// [`Self::write_paste`] (with the local write bound `timeout`) in the
    /// input turn `turn` of this terminal.
    pub(crate) fn write_paste_in(
        &self,
        turn: &InputTurn<'_>,
        bytes: &[u8],
        timeout: Option<Duration>,
    ) -> std::io::Result<()> {
        let pty = self.pty_in(turn)?;
        if bytes.is_empty() {
            return Ok(());
        }
        // Keep-on-exit terminals accept and drop paste input the same way
        // as keystrokes: the final screen is read-only, not broken.
        #[cfg(any(unix, windows))]
        if let Some(result) = Self::send_hosted_input(turn, pty, MessageKind::Paste, bytes, 0) {
            return result;
        }
        let bracketed = {
            let term = pty.term.lock().unwrap_or_else(PoisonError::into_inner);
            term.mode(2004, false)
        };
        let mut runtime = pty.runtime.lock().unwrap_or_else(PoisonError::into_inner);
        #[allow(
            clippy::unreachable,
            reason = "INVARIANT: send_hosted_input took every hosted runtime, and a local \
                      runtime is never replaced by a hosted one"
        )]
        let PtyRuntime::Local {
            writer,
            master,
            #[cfg(unix)]
            holder,
            ..
        } = &mut *runtime
        else {
            unreachable!("hosted paste returned above")
        };
        #[cfg(not(unix))]
        let _ = master;
        let mut payload = Vec::with_capacity(bytes.len() + if bracketed { 12 } else { 0 });
        if bracketed {
            payload.extend_from_slice(b"\x1b[200~");
        }
        payload.extend_from_slice(bytes);
        if bracketed {
            payload.extend_from_slice(b"\x1b[201~");
        }
        // A holder terminal's `pty-writer` queue takes the paste whole, after
        // every key typed before it, without waiting for the child.
        #[cfg(unix)]
        if let Some(input) = holder.as_ref().and_then(|holder| holder.input()) {
            return input.send(&payload, crate::pty_write::InputLane::Bulk);
        }
        // Waits while the child does not read its input.
        crate::request_path::will_block(|| {
            #[cfg(unix)]
            if let Some(timeout) = timeout
                && let Some(fd) = master.as_ref().and_then(|master| master.as_raw_fd())
            {
                return crate::pty_write::write_bounded(
                    fd,
                    &payload,
                    timeout,
                    "PTY paste write timed out",
                )
                .map_err(|failure| failure.error);
            }
            writer.write_all(&payload)?;
            writer.flush()
        })
    }

    #[cfg(test)]
    pub(crate) fn replace_input_writer_for_test(&self, replacement: Box<dyn Write + Send>) {
        let pty = self.as_pty().expect("input test requires a terminal");
        let mut runtime = pty.runtime.lock().unwrap_or_else(PoisonError::into_inner);
        let PtyRuntime::Local { writer, .. } = &mut *runtime else {
            panic!("input test requires the in-process test runtime");
        };
        *writer = replacement;
    }
}
