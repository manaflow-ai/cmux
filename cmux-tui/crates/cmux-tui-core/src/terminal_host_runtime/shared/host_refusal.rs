//! A host that closes the owner hello without a HostHello (R41,
//! plans/cmux-next/durable-sessions.md section 7): the typed refusal the
//! owner handshake reports, so adoption can tell it from other failures.

use std::io::{self as std_io, Read};

use crate::terminal_host_protocol::{Frame, MAX_FRAME_PAYLOAD, read_frame};

/// A live host closed every owner hello this build offered without a
/// HostHello: most often it shares no protocol version with this build (a
/// newer build's host after a rollback). Refusals that last make the
/// terminal unadoptable (plans/cmux-next/durable-sessions.md section 7).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NoCommonHostProtocol;

impl std::fmt::Display for NoCommonHostProtocol {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("terminal host shares no protocol version with this build")
    }
}

impl std::error::Error for NoCommonHostProtocol {}

/// Whether an adoption error proves the host shares no protocol version
/// with this build ([`NoCommonHostProtocol`]).
pub fn is_no_common_host_protocol(error: &anyhow::Error) -> bool {
    // `downcast_ref` also finds a type attached with `.context`, which
    // `chain()` items do not expose; `chain()` finds a typed `source`.
    error.downcast_ref::<NoCommonHostProtocol>().is_some()
        || error.chain().any(|cause| cause.downcast_ref::<NoCommonHostProtocol>().is_some())
}

/// The error of an adoption whose every protocol attempt failed. When every
/// attempt was refused (the hello closed without HostHello) the error carries
/// [`NoCommonHostProtocol`]; any other failure leaves it out. A refusal is
/// most often a host that shares no version with this build, but a host of
/// this build refuses the same way under thread or descriptor pressure or
/// for a wrong owner token, so the caller acts on it only after refusals over
/// time (`Mux::refused_all`).
pub(crate) fn adoption_failed(failures: &[String], every_attempt_refused: bool) -> anyhow::Error {
    let failed = anyhow::anyhow!("terminal-host adoption failed: {}", failures.join("; "));
    if every_attempt_refused {
        anyhow::Error::new(NoCommonHostProtocol).context(failed)
    } else {
        failed
    }
}

/// A host that writes a current record is at least this build's version,
/// so it refuses the current protocol only when its oldest supported
/// version is newer: no version is common.
pub(crate) fn no_common_protocol_if_refused(error: anyhow::Error) -> anyhow::Error {
    if is_refused_host_hello(&error) { error.context(NoCommonHostProtocol) } else { error }
}

/// One owner hello closed without a HostHello.
#[derive(Debug)]
pub(crate) struct RefusedHostHello;

impl std::fmt::Display for RefusedHostHello {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("terminal host closed the owner hello without HostHello")
    }
}

impl std::error::Error for RefusedHostHello {}

pub(crate) fn is_refused_host_hello(error: &anyhow::Error) -> bool {
    error.downcast_ref::<RefusedHostHello>().is_some()
        || error.chain().any(|cause| cause.downcast_ref::<RefusedHostHello>().is_some())
}

/// Read the HostHello. The host reads the whole hello before it refuses
/// one, so a clean EOF (or a reset) here is a refusal, not a torn frame.
pub(crate) fn read_host_hello(stream: &mut impl Read) -> anyhow::Result<Frame> {
    match read_frame(stream, MAX_FRAME_PAYLOAD) {
        Ok(Some(frame)) => Ok(frame),
        Ok(None) => Err(anyhow::Error::new(RefusedHostHello)),
        Err(crate::terminal_host_protocol::ProtocolError::Io(error))
            if error.kind() == std_io::ErrorKind::ConnectionReset =>
        {
            Err(anyhow::Error::new(RefusedHostHello))
        }
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
mod tests;
