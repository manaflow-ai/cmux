//! Trace control of a hosted terminal's host: the
//! daemon's `trace-start`, `trace-stop` and `trace-status` reach every live
//! terminal host through its surface's admin connection.

use std::sync::PoisonError;
use std::time::Instant;

use cmux_trace::ControlOp;

use super::*;
use crate::terminal_host_runtime::PendingHostTrace;

/// One host the daemon asked, or could not ask.
pub(crate) struct HostTraceCall {
    pub(crate) host_pid: u32,
    pub(crate) sent: HostTraceSent,
}

pub(crate) enum HostTraceSent {
    /// The host's record does not advertise trace control (an older host):
    /// it gets no frame.
    Untraced,
    /// `admit` said no: not asked.
    OverCap,
    /// The request is on the wire.
    Pending(PendingHostTrace),
    /// The request could not be written.
    Failed(String),
}

impl Surface {
    /// Sends `op` to this terminal's host; `None` when the terminal does not
    /// run on a host. A host that takes trace control is asked only when
    /// `admit` says yes. Never waits for the ack: the caller sends to every
    /// host first, then reads the acks against one deadline.
    pub(crate) fn begin_host_trace(
        &self,
        op: ControlOp,
        deadline: Instant,
        admit: &mut dyn FnMut() -> bool,
    ) -> Option<HostTraceCall> {
        let pty = self.as_pty()?;
        let runtime = pty.runtime.lock().unwrap_or_else(PoisonError::into_inner);
        let PtyRuntime::Hosted(host) = &*runtime else {
            return None;
        };
        let sent = if !host.record.supports_trace_control {
            HostTraceSent::Untraced
        } else if !admit() {
            HostTraceSent::OverCap
        } else {
            match host.begin_trace_control(op, deadline) {
                Ok(pending) => HostTraceSent::Pending(pending),
                Err(error) => HostTraceSent::Failed(error),
            }
        };
        Some(HostTraceCall { host_pid: host.record.host_pid, sent })
    }
}
