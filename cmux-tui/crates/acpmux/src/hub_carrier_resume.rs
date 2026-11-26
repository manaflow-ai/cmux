//! The far side of a held pipe (RFD 0127 cut 4): a kept circuit's stream that names
//! [`CircuitService::CmuxTuiResume`] reaches this machine's cmux-tui remote daemon (its sshd,
//! for `carrier-pipe`) through a `ResumablePipe` this process keeps in [`PARKING`]. When the
//! stream ends before the pipe does (the dialer's acpmux restarted, its circuit dropped), the
//! daemon's connection stays open for [`RESUME_GRACE`]. The dialer's next stream names the
//! pipe's token, and the bytes go on from what each end received (`cmux_remote::resume_hold`).
//!
//! Only the machine that opened a pipe resumes it: its owner is the stream's Noise-proven
//! `daemonId`. The gate admits each stream again, as it admits a plain
//! [`CircuitService::CmuxTui`] one.
//!
//! [`CircuitService::CmuxTuiResume`]: super::super::CircuitService::CmuxTuiResume
//! [`CircuitService::CmuxTui`]: super::super::CircuitService::CmuxTui

use std::future::Future;
use std::sync::{Arc, LazyLock};

use cmux_remote::resume_hold::{Parking, RESUME_GRACE};
use tokio::io::DuplexStream;
use tokio::net::TcpStream;

use super::super::{DUPLEX_BYTES, Incoming, ServiceRefusal};

/// This process's held pipes to its cmux-tui remote daemon, by token.
static PARKING: LazyLock<Arc<Parking<TcpStream>>> = LazyLock::new(|| Parking::new(RESUME_GRACE));

/// This machine's end of a held-pipe stream from `from` to the daemon on `port`, and the
/// serving of its other end (the caller runs it beside the stream), or why it may not have one.
pub(super) async fn open(
    incoming: &Incoming,
    from: Option<String>,
    port: u16,
) -> Result<(DuplexStream, impl Future<Output = ()> + Send + use<>), ServiceRefusal> {
    let gate = incoming.carrier.cmux_tui_gate().ok_or_else(|| {
        ServiceRefusal::new(
            "service.off",
            "this machine does not serve its cmux-tui remote daemon to its other machines",
        )
    })?;
    let Some(from) = from else {
        return Err(ServiceRefusal::new(
            "service.unknown_machine",
            "the circuit's machine key is not one this machine admitted",
        ));
    };
    let target = gate.admit(port).await?;
    let (ours, theirs) = tokio::io::duplex(DUPLEX_BYTES);
    let serving = async move {
        let connect = || async move {
            let daemon = TcpStream::connect(target).await?;
            let _ = daemon.set_nodelay(true);
            Ok::<_, std::io::Error>(daemon)
        };
        let ran = PARKING.serve(theirs, &from, connect).await;
        tracing::debug!(port, "hub carrier: a held pipe's stream ended: {ran:?}");
    };
    Ok((ours, serving))
}
