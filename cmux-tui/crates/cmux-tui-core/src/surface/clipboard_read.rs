//! Hosted surface view of the clipboard-read broker: the read the terminal
//! host is asking this surface's user about, and the one answer to it. The
//! daemon broker (layer 3) decides who may answer; nothing here logs or keeps
//! clipboard text.

use ghostty_vt::ClipboardReadRequest;

use super::{PtyRuntime, Surface};
use crate::terminal_host_runtime::HostAttachment;

impl Surface {
    fn with_host<T>(&self, f: impl FnOnce(&HostAttachment) -> T) -> Option<T> {
        let pty = self.as_pty()?;
        let runtime = pty.runtime.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        match &*runtime {
            PtyRuntime::Hosted(host) => Some(f(host)),
            _ => None,
        }
    }

    /// Whether this surface's host connection negotiated clipboard reads.
    pub fn clipboard_reads_negotiated(&self) -> bool {
        self.with_host(HostAttachment::clipboard_reads_negotiated).unwrap_or(false)
    }

    /// The clipboard read the host is waiting on, if any.
    pub fn pending_clipboard_read(&self) -> Option<ClipboardReadRequest> {
        self.with_host(HostAttachment::pending_clipboard_read).flatten()
    }

    /// Answers the pending read `token`: `Some(text)` grants it, `None`
    /// refuses it. False, with nothing sent, when `token` is not pending
    /// (answered, replaced, or the connection changed).
    pub fn complete_clipboard_read(
        &self,
        token: u64,
        text: Option<Vec<u8>>,
    ) -> std::io::Result<bool> {
        self.with_host(|host| host.complete_clipboard_read(token, text.as_deref()))
            .unwrap_or(Ok(false))
    }
}
