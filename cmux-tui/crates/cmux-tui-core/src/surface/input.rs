//! Input delivery on `Surface`: raw and receipted writes and bounded paste.

use super::*;

/// How long hosted input waits for a lost host connection to come back (a
/// reconnect or an in-place replacement host, cx-6so.49) before it fails.
#[cfg(any(unix, windows))]
///
/// The wait blocks its caller: one control connection's next request, or
/// the TUI's input worker. It applies only while a host connection is lost,
/// and a replacement host usually installs within a second.
const HOST_INPUT_RECONNECT_WAIT: Duration = Duration::from_secs(5);

/// Whether a host send failed because the host connection is gone (the
/// host died or its stream broke), not because the frame was refused.
#[cfg(any(unix, windows))]
fn host_connection_lost(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::BrokenPipe
            | std::io::ErrorKind::ConnectionReset
            | std::io::ErrorKind::ConnectionAborted
            | std::io::ErrorKind::NotConnected
    )
}

impl Surface {
    /// Write input bytes to the PTY child.
    pub fn write_bytes(&self, bytes: &[u8]) -> std::io::Result<()> {
        let Some(pty) = self.as_pty() else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "browser surface does not accept PTY bytes",
            ));
        };
        #[cfg(any(unix, windows))]
        if let Some(result) = Self::send_hosted_input(pty, MessageKind::Input, bytes) {
            return result;
        }
        let mut runtime = pty.runtime.lock().unwrap();
        match &mut *runtime {
            PtyRuntime::Local { writer, .. } => {
                writer.write_all(bytes)?;
                writer.flush()
            }
            #[cfg(any(unix, windows))]
            PtyRuntime::Hosted(host) => host.send(MessageKind::Input, bytes),
            // A keep-on-exit terminal outlives its child, so typing into the
            // dead PTY is an expected interaction: drop the bytes silently
            // instead of failing every keystroke on the final screen.
            #[cfg(any(unix, windows))]
            PtyRuntime::ExitedHosted => Ok(()),
        }
    }

    /// Send input to a hosted terminal's host, across a lost host
    /// connection (cx-6so.49). A host that died or whose stream broke has a
    /// dead connection until the surface reader installs the reconnected or
    /// replacement host; a send in that window fails with EPIPE although the
    /// shell lives. Such a send waits for the reader's next stream change
    /// (it notifies after it installed the new attachment) and is sent again
    /// to the new host, until [`HOST_INPUT_RECONNECT_WAIT`] passes or the
    /// reader gives up or ends. A frame that failed with a lost connection never
    /// reached a live reader, so the retry cannot duplicate it. `None` when
    /// the runtime is not hosted (the caller writes locally).
    #[cfg(any(unix, windows))]
    fn send_hosted_input(
        pty: &PtySurface,
        kind: MessageKind,
        bytes: &[u8],
    ) -> Option<std::io::Result<()>> {
        let deadline = Instant::now() + HOST_INPUT_RECONNECT_WAIT;
        let mut first_error = None;
        loop {
            // Read the revision before the send: an install after it wakes
            // the wait below, so no reconnect is missed.
            let observed = pty.stream_progress.revision();
            let sent = match &*pty.runtime.lock().unwrap() {
                PtyRuntime::Hosted(host) => host.send(kind, bytes),
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
                || pty.stream_progress.wait_for_change(observed, deadline).is_none()
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
        if let Some(result) = Self::send_hosted_input(pty, MessageKind::Paste, bytes) {
            return result;
        }
        let bracketed = {
            let term = pty.term.lock().unwrap();
            term.mode(2004, false)
        };
        let mut runtime = pty.runtime.lock().unwrap();
        let PtyRuntime::Local { writer, master, .. } = &mut *runtime else {
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
