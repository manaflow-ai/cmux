//! The class a terminal's threads run at (p02-threads-236): its echo
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
    /// Runs this terminal's threads at the echo class when `shown`, at
    /// [`HIDDEN_TERMINAL_QOS`] when not. A hosted terminal's host gets the
    /// class too when its record takes `SetThreadQos`. No effect when the
    /// class is unchanged or the surface is not a terminal.
    pub(crate) fn set_threads_shown(&self, shown: bool) {
        let Some(pty) = self.as_pty() else { return };
        let qos = if shown { ECHO_PATH_QOS } else { HIDDEN_TERMINAL_QOS };
        if !pty.thread_qos.request(qos) {
            return;
        }
        #[cfg(any(unix, windows))]
        pty.send_host_thread_qos();
    }

    /// The class this terminal's threads were last asked to run at.
    #[cfg(test)]
    pub(crate) fn thread_qos(&self) -> Option<ThreadQos> {
        self.as_pty().map(|pty| pty.thread_qos.get())
    }
}

impl PtySurface {
    /// Sends the terminal's class to its host.
    #[cfg(any(unix, windows))]
    fn send_host_thread_qos(&self) {
        let qos = self.thread_qos.get();
        let runtime = self.runtime.lock().unwrap_or_else(PoisonError::into_inner);
        if let PtyRuntime::Hosted(host) = &*runtime {
            // Advisory: after a failed write the host keeps its class, and
            // the connection's reader sees the broken stream and reconnects.
            let _ = host.send_thread_qos(qos);
        }
    }

    /// A new host connection (a reconnect or a replacement host) starts its
    /// threads at the echo class: send it a lowered class again.
    #[cfg(any(unix, windows))]
    pub(super) fn resend_lowered_host_thread_qos(&self) {
        if self.thread_qos.get() != ECHO_PATH_QOS {
            self.send_host_thread_qos();
        }
    }
}

#[cfg(test)]
#[path = "thread_qos_tests.rs"]
mod tests;
