//! `HostAttachment::mint_renderer_grant`: asks the host for a one-use
//! renderer capability over the admin connection and types the failure when
//! the host does not answer.

use super::*;
use crate::terminal_host_runtime::{RendererGrantFailure, RendererGrantUnavailable};

/// A control request whose response never reached its waiter. The text is
/// the one callers already match ("terminal host did not acknowledge
/// ClearHistory: ..."); the cause tells a deadline from a lost connection.
#[derive(Debug)]
pub(super) struct ControlRequestUnanswered {
    pub(super) request_kind: MessageKind,
    pub(super) cause: RecvTimeoutError,
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

impl HostAttachment {
    pub fn mint_renderer_grant(&self, ttl: Duration) -> anyhow::Result<RendererGrant> {
        if ttl.is_zero() || ttl > MAX_RENDERER_CAPABILITY_TTL {
            anyhow::bail!("renderer capability TTL must be between 1ms and 60s");
        }
        let ttl_ms = u32::try_from(ttl.as_millis())
            .map_err(|_| anyhow::anyhow!("renderer capability TTL is too large"))?;
        let mut payload = Vec::with_capacity(8);
        payload.extend_from_slice(&CapabilityRights::RENDERER.bits().to_le_bytes());
        payload.extend_from_slice(&ttl_ms.to_le_bytes());
        let payload = self
            .send_control_request(MessageKind::MintCapability, MessageKind::Capability, payload)
            .map_err(|failure| mint_failure(failure.into_error()))?;
        if payload.len() != crate::terminal_host::CAPABILITY_TOKEN_LEN {
            self.disconnect();
            anyhow::bail!("terminal host returned a malformed renderer capability");
        }
        Ok(RendererGrant {
            endpoint: self.record.endpoint.clone(),
            terminal_id: self.record.terminal_id.clone(),
            incarnation: self.record.incarnation.clone(),
            token: encode_hex(&payload),
            rights: CapabilityRights::RENDERER,
            protocol_version: self.protocol_version,
            supports_viewer_size_priority: self.record.supports_viewer_size_priority,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unanswered_mints_are_typed_with_their_cause_in_the_message() {
        for (cause, expected) in [
            (RecvTimeoutError::Timeout, RendererGrantUnavailable::Timeout),
            (RecvTimeoutError::Disconnected, RendererGrantUnavailable::Disconnected),
        ] {
            let error = mint_failure(
                ControlRequestUnanswered { request_kind: MessageKind::MintCapability, cause }
                    .into(),
            );
            let failure = error.downcast_ref::<RendererGrantFailure>().expect("typed failure");
            assert_eq!(failure.unavailable(), expected);
            assert_eq!(
                error.to_string(),
                format!(
                    "terminal host did not mint renderer grant: terminal host did not \
                     acknowledge MintCapability: {cause}"
                )
            );
        }
        let broken = std::io::Error::from(std::io::ErrorKind::BrokenPipe);
        let error = mint_failure(broken.into());
        assert_eq!(
            error.downcast_ref::<RendererGrantFailure>().map(RendererGrantFailure::unavailable),
            Some(RendererGrantUnavailable::Disconnected)
        );
        let exhausted = mint_failure(anyhow::anyhow!("terminal host control request id exhausted"));
        assert!(exhausted.downcast_ref::<RendererGrantFailure>().is_none());
        assert_eq!(
            exhausted.to_string(),
            "terminal host did not mint renderer grant: terminal host control request id exhausted"
        );
    }
}
