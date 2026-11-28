//! `HostAttachment::mint_renderer_grant`: asks the host for a one-use
//! renderer capability over the admin connection and types the failure when
//! the host does not answer.

use std::sync::mpsc::RecvTimeoutError;
use std::time::Duration;

use super::super::*;
use super::attachment::HostAttachment;
use super::codec::encode_hex;
use crate::terminal_host_runtime::{RendererGrantFailure, RendererGrantUnavailable};

/// A control request whose response never reached its waiter. The text is
/// the one callers already match ("terminal host did not acknowledge
/// ClearHistory: ..."); the cause tells a deadline from a lost connection.
#[derive(Debug)]
pub(crate) struct ControlRequestUnanswered {
    pub(crate) request_kind: MessageKind,
    pub(crate) cause: RecvTimeoutError,
}

impl std::fmt::Display for ControlRequestUnanswered {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "terminal host did not acknowledge {:?}: {}",
            self.request_kind, self.cause
        )
    }
}

impl std::error::Error for ControlRequestUnanswered {}

/// The typed failure of a mint request that got no Capability, or an untyped
/// error that still carries its whole cause chain in its text.
fn mint_failure(error: anyhow::Error) -> anyhow::Error {
    let unavailable = match error.downcast_ref::<ControlRequestUnanswered>() {
        Some(ControlRequestUnanswered { cause: RecvTimeoutError::Timeout, .. }) => {
            RendererGrantUnavailable::Timeout
        }
        Some(ControlRequestUnanswered { cause: RecvTimeoutError::Disconnected, .. }) => {
            RendererGrantUnavailable::Disconnected
        }
        // The request frame could not be written: the connection is gone.
        None if error.downcast_ref::<std::io::Error>().is_some() => {
            RendererGrantUnavailable::Disconnected
        }
        None => return anyhow::anyhow!("terminal host did not mint renderer grant: {error:#}"),
    };
    RendererGrantFailure::new(unavailable, &error).into()
}

/// A sent renderer mint: the request is on the wire and the grant's
/// identity is captured, so the reply can be awaited without the surface's
/// runtime lock (see `PendingControlResponse`).
pub(crate) struct PendingRendererGrant {
    pending: super::attachment::PendingControlResponse,
    endpoint: String,
    terminal_id: String,
    incarnation: String,
    protocol_version: u16,
    supports_viewer_size_priority: bool,
}

impl HostAttachment {
    pub fn mint_renderer_grant(&self, ttl: Duration) -> anyhow::Result<RendererGrant> {
        self.begin_renderer_grant(ttl)?.wait()
    }

    /// Send the mint request; `PendingRendererGrant::wait` reads the reply.
    pub(crate) fn begin_renderer_grant(
        &self,
        ttl: Duration,
    ) -> anyhow::Result<PendingRendererGrant> {
        if ttl.is_zero() || ttl > MAX_RENDERER_CAPABILITY_TTL {
            anyhow::bail!("renderer capability TTL must be between 1ms and 60s");
        }
        let ttl_ms = u32::try_from(ttl.as_millis())
            .map_err(|_| anyhow::anyhow!("renderer capability TTL is too large"))?;
        let mut payload = Vec::with_capacity(8);
        payload.extend_from_slice(&CapabilityRights::RENDERER.bits().to_le_bytes());
        payload.extend_from_slice(&ttl_ms.to_le_bytes());
        let pending = self
            .begin_control_request(
                MessageKind::MintCapability,
                MessageKind::Capability,
                payload,
                std::time::Instant::now() + CONTROL_RESPONSE_TIMEOUT,
            )
            .map_err(|failure| mint_failure(failure.into_error()))?;
        Ok(PendingRendererGrant {
            pending,
            endpoint: self.record.endpoint.clone(),
            terminal_id: self.record.terminal_id.clone(),
            incarnation: self.record.incarnation.clone(),
            protocol_version: self.protocol_version,
            supports_viewer_size_priority: self.record.supports_viewer_size_priority,
        })
    }
}

impl PendingRendererGrant {
    pub(crate) fn wait(self) -> anyhow::Result<RendererGrant> {
        let payload =
            self.pending.wait(true).map_err(|failure| mint_failure(failure.into_error()))?;
        if payload.len() != crate::terminal_host::CAPABILITY_TOKEN_LEN {
            self.pending.disconnect();
            anyhow::bail!("terminal host returned a malformed renderer capability");
        }
        Ok(RendererGrant {
            endpoint: self.endpoint,
            terminal_id: self.terminal_id,
            incarnation: self.incarnation,
            token: encode_hex(&payload),
            rights: CapabilityRights::RENDERER,
            protocol_version: self.protocol_version,
            supports_viewer_size_priority: self.supports_viewer_size_priority,
        })
    }
}

#[cfg(test)]
mod tests;
