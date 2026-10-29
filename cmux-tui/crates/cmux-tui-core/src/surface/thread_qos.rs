//! The class a terminal's threads run at: its echo
//! threads (the local PTY reader and parser, or the hosted mirror reader and
//! its frame reader, and in the host process the PTY reader and parser) run
//! at the echo class while a view shows the terminal and at utility while
//! none does, as Chrome lowers a hidden renderer's priority
//! (content/browser/renderer_host/render_process_host_impl.cc,
//! `UpdateProcessPriority`). Each thread applies the class itself after its
//! next wake, so a change wakes no thread.

#[cfg(any(unix, windows))]
use std::sync::PoisonError;

use cmux_threads::ThreadQos;

use super::*;
use crate::echo_thread::ECHO_PATH_QOS;

/// The class of a terminal no view shows.
pub(crate) const HIDDEN_TERMINAL_QOS: ThreadQos = ThreadQos::Utility;

impl Surface {
    /// Asks this terminal's threads to run at the echo class when `shown`,
    /// at [`HIDDEN_TERMINAL_QOS`] when not. One atomic store, so a caller
    /// may hold its own lock. True when the class changed: the caller then
    /// calls [`Self::send_thread_qos_to_host`] without its lock.
    pub(crate) fn request_threads_shown(&self, shown: bool) -> bool {
        let Some(pty) = self.as_pty() else { return false };
        pty.thread_qos.request(if shown { ECHO_PATH_QOS } else { HIDDEN_TERMINAL_QOS })
    }

    /// Sends the terminal's current class to its host, when it is hosted
    /// and its record takes `SetThreadQos`.
    pub(crate) fn send_thread_qos_to_host(&self) {
        #[cfg(any(unix, windows))]
        if let Some(pty) = self.as_pty() {
            pty.send_host_thread_qos();
        }
    }

    /// [`Self::request_threads_shown`], then the host's copy when it changed.
    #[cfg(test)]
    pub(crate) fn set_threads_shown(&self, shown: bool) {
        if self.request_threads_shown(shown) {
            self.send_thread_qos_to_host();
        }
    }

    /// The class this terminal's threads were last asked to run at.
    #[cfg(test)]
    pub(crate) fn thread_qos(&self) -> Option<ThreadQos> {
        self.as_pty().map(|pty| pty.thread_qos.get())
    }
}

impl PtySurface {
    /// Sends the terminal's class to its host. The class is read under the
    /// runtime lock, so the last of two racing sends carries the latest
    /// request. A new host connection calls it too: a host keeps the class
    /// a previous owner set (`HostShared::thread_qos`), whatever this
    /// owner's start value.
    #[cfg(any(unix, windows))]
    pub(super) fn send_host_thread_qos(&self) {
        let runtime = self.runtime.lock().unwrap_or_else(PoisonError::into_inner);
        if let PtyRuntime::Hosted(host) = &*runtime {
            // Advisory: after a failed write the host keeps its class, and
            // the connection's reader sees the broken stream, reconnects and
            // sends the class again.
            let _ = host.send_thread_qos(self.thread_qos.get());
        }
    }
}

#[cfg(test)]
#[path = "thread_qos_tests.rs"]
mod tests;
