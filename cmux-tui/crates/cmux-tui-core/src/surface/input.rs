//! Input delivery on `Surface`: raw and receipted writes and bounded paste.

use super::*;

/// How long hosted input waits for a lost host connection to come back (a
/// reconnect or an in-place replacement host, cx-6so.49) before it fails.
#[cfg(any(unix, windows))]
///
/// It applies only while a host connection is lost, and a replacement host
/// usually installs within a second. The terminal's input port waits on its
/// own thread, for each frame from the moment the port took it
/// (`surface::input_port`); the person's keys do not wait, and every other
/// write (one control connection's next request, or the TUI's input worker)
/// waits for its frame's result.
pub(super) const HOST_INPUT_RECONNECT_WAIT: Duration = Duration::from_secs(5);

/// The error of input to a hosted terminal that has no input route. Every hosted runtime publishes one when it is
/// made and at every swap (`PtyTerminalRuntime::replace_runtime`), so this is a broken invariant: the input is
/// refused as not written, never written to the host connection around the terminal's input port.
#[cfg(any(unix, windows))]
fn no_input_route() -> std::io::Error {
    std::io::Error::new(
        std::io::ErrorKind::NotConnected,
        "the hosted terminal has no input route; input not written",
    )
}

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

impl Surface {
    /// Write input bytes to the PTY child. A hosted terminal's write goes through its input port (R-DAEMON-STATE S1)
    /// and answers when the port wrote it ([`InputReply::Written`]), with the write's error.
    pub fn write_bytes(&self, bytes: &[u8]) -> std::io::Result<()> {
        self.write_bytes_replying(bytes, InputReply::Written)
    }

    /// [`Self::write_bytes`] answering as `reply` says: the person's keys pass [`InputReply::Accepted`] and return
    /// when the terminal's input port took them.
    pub(crate) fn write_bytes_replying(
        &self,
        bytes: &[u8],
        reply: InputReply,
    ) -> std::io::Result<()> {
        let Some(pty) = self.as_pty() else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "browser surface does not accept PTY bytes",
            ));
        };
        #[cfg(any(unix, windows))]
        if let Some(result) = Self::enqueue_on_input_port(pty, MessageKind::Input, bytes, reply) {
            return result;
        }
        // Not hosted: the daemon writes the PTY itself (the holder model's custody master). Marked
        // before the runtime lock, so the mark never runs under it.
        cmux_flow_trace::hop("daemon.pty.write", 0, pty.flow_terminal_id());
        let mut runtime = pty.runtime.lock().unwrap();
        match &mut *runtime {
            PtyRuntime::Local { writer, master, .. } => {
                let master = master.as_deref().map(|master| master as &dyn MasterPty);
                crate::pty_input_room::write_input(master, writer.as_mut(), bytes).map(|_| ())
            }
            // A hosted terminal's input went to its input port above; one with no input route is refused.
            #[cfg(any(unix, windows))]
            PtyRuntime::Hosted(_) => Err(no_input_route()),
            // A keep-on-exit terminal outlives its child, so typing into the
            // dead PTY is an expected interaction: drop the bytes silently
            // instead of failing every keystroke on the final screen.
            #[cfg(any(unix, windows))]
            PtyRuntime::ExitedHosted => Ok(()),
        }
    }

    /// Hands interactive input for a hosted terminal to the terminal's input port (R-DAEMON-STATE stage S1 step 6).
    /// The person's keys ([`InputReply::Accepted`]) return once the port took them; every other write returns with its
    /// frame's result (`InputPort::write`). `None` when the terminal is not hosted (the caller writes the PTY itself).
    /// The final screen of an exited host drops the input.
    #[cfg(any(unix, windows))]
    fn enqueue_on_input_port(
        pty: &PtySurface,
        kind: MessageKind,
        bytes: &[u8],
        reply: InputReply,
    ) -> Option<std::io::Result<()>> {
        match pty.input_route.load().as_deref() {
            None => None,
            Some(input_port::InputRoute::Exited) => Some(Ok(())),
            Some(input_port::InputRoute::Failed) => Some(Err(std::io::Error::new(
                std::io::ErrorKind::NotConnected,
                "the terminal's host connection failed; input not written",
            ))),
            // The reader ended: no host connection will come back, so the input is refused now (`cmux send` exits
            // non-zero). `Failed` alone is not that: the reader keeps retrying, and it installs a live replacement
            // before the state leaves `Failed` (#34544 review 2).
            Some(input_port::InputRoute::Hosted(_)) if pty.reader_completion.is_complete() => {
                Some(Err(std::io::Error::new(
                    std::io::ErrorKind::NotConnected,
                    "the terminal's host connection ended; input not written",
                )))
            }
            Some(input_port::InputRoute::Hosted(_)) => Some(match reply {
                InputReply::Accepted => {
                    pty.input_port.enqueue(&pty.terminal, kind, bytes).map_err(Into::into)
                }
                InputReply::Written => pty.input_port.write(&pty.terminal, kind, bytes),
            }),
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
            return Err(ConfirmedInputFailure::Known(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "browser surface does not accept PTY bytes",
            )));
        };
        let mut runtime = pty.runtime.lock().unwrap();
        match &mut *runtime {
            PtyRuntime::Local { writer, .. } => writer
                .write_all(bytes)
                .and_then(|()| writer.flush())
                .map_err(ConfirmedInputFailure::Indeterminate),
            #[cfg(any(unix, windows))]
            PtyRuntime::Hosted(host) => {
                let receipt = host.begin_input_confirmed(bytes)?;
                drop(runtime);
                receipt.wait().map_err(ConfirmedInputFailure::Indeterminate)
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
        self.write_paste_with_timeout(bytes, None, InputReply::Written)
    }

    /// [`Self::write_paste`] answering as `reply` says ([`Self::write_bytes_replying`]).
    pub(crate) fn write_paste_replying(
        &self,
        bytes: &[u8],
        reply: InputReply,
    ) -> std::io::Result<()> {
        self.write_paste_with_timeout(bytes, None, reply)
    }

    /// Write a paste with a bounded local PTY write for daemon-owned uploads.
    ///
    /// Hosted attachments already enforce their socket write deadline. Local
    /// PTY masters are switched to nonblocking mode for this operation and
    /// polled until the same two-second bound, so a full PTY cannot retain an
    /// image-paste reservation indefinitely.
    pub(crate) fn write_paste_bounded(&self, bytes: &[u8]) -> std::io::Result<()> {
        self.write_paste_with_timeout(bytes, Some(LOCAL_PASTE_WRITE_TIMEOUT), InputReply::Written)
    }

    pub(super) fn write_paste_with_timeout(
        &self,
        bytes: &[u8],
        timeout: Option<Duration>,
        reply: InputReply,
    ) -> std::io::Result<()> {
        let Some(pty) = self.as_pty() else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "browser surface does not accept PTY bytes",
            ));
        };
        if bytes.is_empty() {
            return Ok(());
        }
        // Keep-on-exit terminals accept and drop paste input the same way
        // as keystrokes: the final screen is read-only, not broken.
        #[cfg(any(unix, windows))]
        if let Some(result) = Self::enqueue_on_input_port(pty, MessageKind::Paste, bytes, reply) {
            return result;
        }
        let bracketed = {
            let term = pty.term.lock().unwrap();
            term.mode(2004, false)
        };
        let mut runtime = pty.runtime.lock().unwrap();
        let (writer, master) = match &mut *runtime {
            PtyRuntime::Local { writer, master, .. } => (writer, master),
            // A hosted terminal's paste went to its input port above; one with no input route is refused.
            #[cfg(any(unix, windows))]
            PtyRuntime::Hosted(_) => return Err(no_input_route()),
            // The final screen of a keep-on-exit terminal drops a paste, as it drops keys.
            #[cfg(any(unix, windows))]
            PtyRuntime::ExitedHosted => return Ok(()),
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
    }

    #[cfg(test)]
    pub(crate) fn replace_input_writer_for_test(&self, replacement: Box<dyn Write + Send>) {
        let pty = self.as_pty().expect("input test requires a terminal");
        let mut runtime = pty.runtime.lock().unwrap();
        let PtyRuntime::Local { writer, .. } = &mut *runtime else {
            panic!("input test requires the in-process test runtime");
        };
        *writer = replacement;
    }
}
