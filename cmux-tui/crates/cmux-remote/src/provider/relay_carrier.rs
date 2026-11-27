//! The relay as a braid carrier (RFD 0164 B7): [`RelaySocketRung`] implements
//! [`cmux_braid_carrier::Carrier`] (kind [`CarrierKind::WssRelay`], the ladder's last rung), and
//! every relay WebSocket opens through it. Its failure comes back through the carrier's
//! `io::Error` as the relay's own, so a refused ticket still reads as `Authentication` and is
//! retried once with a fresh one.

use std::fmt;
use std::io;

use cmux_braid_carrier::{Carrier, CarrierKind, Endpoint, OpenFuture};
use url::Url;

use super::{
    LinkError, ProviderError, RelayCredential, RelaySocket, RelaySocketConnectError, RelayTls,
    open_relay_socket,
};

/// One relay WebSocket to open: the endpoint URL, the ticket it presents and its message bound.
pub(super) struct RelaySocketRung<'a> {
    pub endpoint: &'a Url,
    pub authorization: Option<&'a RelayCredential>,
    pub maximum_message_bytes: usize,
    pub tls: &'a RelayTls,
}

/// A relay URL as a [`CarrierKind::WssRelay`] endpoint: `host:port`, the scheme's port (443 for
/// `wss`, 80 for `ws`) unless the URL names one.
pub(super) fn carrier_endpoint(url: &Url) -> Endpoint {
    let host = url.host_str().unwrap_or_default();
    let port = url.port_or_known_default().unwrap_or(443);
    Endpoint {
        kind: CarrierKind::WssRelay,
        address: format!("{host}:{port}"),
        host: host.trim_start_matches('[').trim_end_matches(']').to_owned(),
        login: None,
    }
}

/// The relay's own failure inside the carrier's `io::Error`.
struct RelayOpenFailure(RelaySocketConnectError);

impl fmt::Debug for RelayOpenFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, formatter)
    }
}

impl fmt::Display for RelayOpenFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.0 {
            RelaySocketConnectError::Authentication => {
                formatter.write_str("relay WebSocket authentication was rejected")
            }
            RelaySocketConnectError::Provider(error) => error.fmt(formatter),
        }
    }
}

impl std::error::Error for RelayOpenFailure {}

/// A carrier error back as the relay's own: the failure the open returned, else a transport
/// failure with the error's text (a retryable carrier failure, as a dial error was before).
pub(super) fn from_io(error: io::Error) -> RelaySocketConnectError {
    match error.downcast::<RelayOpenFailure>() {
        Ok(RelayOpenFailure(error)) => error,
        Err(error) => RelaySocketConnectError::Provider(ProviderError::Link(LinkError::Transport(
            format!("relay WebSocket connection failed: {error}"),
        ))),
    }
}

impl Carrier for RelaySocketRung<'_> {
    type Link = RelaySocket;

    fn kind(&self) -> CarrierKind {
        CarrierKind::WssRelay
    }

    fn open<'b>(&'b self, endpoint: &'b Endpoint) -> OpenFuture<'b, RelaySocket> {
        Box::pin(async move {
            if endpoint.kind != CarrierKind::WssRelay {
                return Err(io::Error::other("the endpoint is another carrier's"));
            }
            open_relay_socket(
                self.endpoint,
                self.authorization,
                self.maximum_message_bytes,
                self.tls,
            )
            .await
            .map_err(|error| io::Error::other(RelayOpenFailure(error)))
        })
    }
}

impl RelaySocketRung<'_> {
    /// [`Carrier::open`] on this rung's own endpoint, with the failure as the relay's own.
    pub(super) async fn join(&self) -> Result<RelaySocket, RelaySocketConnectError> {
        let endpoint = carrier_endpoint(self.endpoint);
        self.open(&endpoint).await.map_err(from_io)
    }
}

#[cfg(test)]
#[path = "relay_carrier_tests.rs"]
mod tests;
