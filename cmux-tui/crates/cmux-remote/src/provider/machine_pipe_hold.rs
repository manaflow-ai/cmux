//! A machine pipe that lives through this machine's acpmux restarting (RFD 0127 cut 4): the
//! pipe's bytes ride a `ResumablePipe` whose far end the other machine's acpmux keeps
//! (acpmux `hub_carrier_resume.rs`). When the socket to acpmux ends early (acpmux restarted, its
//! carrier's circuit dropped), the pipe is asked for again and goes on where it stopped, with no
//! byte lost or doubled. ssh's ProxyCommand runs this, so an ssh session outlives acpmux.

use std::time::Duration;

use tokio::io::{AsyncRead, AsyncWrite};

use super::{MachinePipeDialer, machine_pipe_resume_request};
use crate::link::LinkError;
use crate::resume_hold::{Held, RESUME_GRACE, hold};

/// The far reason of a machine whose acpmux holds no pipes yet.
const NO_HELD_PIPES: &str = "service.unknown";

impl MachinePipeDialer {
    /// Carry `local` (the ProxyCommand's stdio) to loopback `port` on this dialer's machine,
    /// held across breaks: each new pipe within [`RESUME_GRACE`] of a break resumes it. An Err is
    /// the first pipe's refusal or failure, as [`super::Dialer::dial`] reports it. A far acpmux
    /// from before held pipes refuses them `service.unknown`; the bytes then ride a plain pipe,
    /// which ends with its circuit as it did before.
    pub async fn hold<L>(&self, port: u16, local: L) -> Result<Held, LinkError>
    where
        L: AsyncRead + AsyncWrite + Send + Unpin,
    {
        self.hold_within(port, local, RESUME_GRACE).await
    }

    /// [`Self::hold`], giving up `grace` after a break with no pipe back.
    pub async fn hold_within<L>(
        &self,
        port: u16,
        mut local: L,
        grace: Duration,
    ) -> Result<Held, LinkError>
    where
        L: AsyncRead + AsyncWrite + Send + Unpin,
    {
        let request = machine_pipe_resume_request(&self.machine, port);
        let first = match self.open_pipe_with(request.clone()).await {
            Ok(first) => first,
            Err(error) if error.refusal().is_some_and(|r| r.reason == NO_HELD_PIPES) => {
                let mut pipe = self.open_pipe(port).await?;
                return Ok(match tokio::io::copy_bidirectional(&mut local, &mut pipe).await {
                    Ok(_) => Held::Finished,
                    Err(error) => Held::Failed(error.to_string()),
                });
            }
            Err(error) => return Err(error),
        };
        let mut first = Some(first);
        let connect = || {
            let first = first.take();
            let request = request.clone();
            async move {
                match first {
                    Some(first) => Ok(first),
                    None => self.open_pipe_with(request).await.map_err(|e| e.to_string()),
                }
            }
        };
        Ok(hold(local, connect, grace).await)
    }
}
