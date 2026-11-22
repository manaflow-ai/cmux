//! Input delivery on `Surface`: raw and receipted writes and bounded paste.

use super::*;

impl Surface {
    /// Write input bytes to the PTY child.
    pub fn write_bytes(&self, bytes: &[u8]) -> std::io::Result<()> {
        let Some(pty) = self.as_pty() else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "browser surface does not accept PTY bytes",
            ));
        };
        let mut runtime = pty.runtime.lock().unwrap();
        match &mut *runtime {
            PtyRuntime::Local { writer, .. } => {
                writer.write_all(bytes)?;
                writer.flush()
            }
            #[cfg(unix)]
            PtyRuntime::Hosted(host) => host.send(MessageKind::Input, bytes),
            // A keep-on-exit terminal outlives its child, so typing into the
            // dead PTY is an expected interaction: drop the bytes silently
            // instead of failing every keystroke on the final screen.
            #[cfg(unix)]
            PtyRuntime::ExitedHosted => Ok(()),
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
            #[cfg(unix)]
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
            #[cfg(unix)]
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
        #[cfg(unix)]
        {
            let runtime = pty.runtime.lock().unwrap();
            if let PtyRuntime::Hosted(host) = &*runtime {
                return host.send(MessageKind::Paste, bytes);
            }
            // Keep-on-exit terminals accept and drop paste input the same
            // way as keystrokes: the final screen is read-only, not broken.
            if matches!(&*runtime, PtyRuntime::ExitedHosted) {
                return Ok(());
            }
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
