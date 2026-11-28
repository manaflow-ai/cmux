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
mod tests {
    use super::*;

    #[test]
    fn the_relay_is_a_braid_carrier_on_the_last_rung() {
        let tls = RelayTls::default();
        let url = Url::parse("wss://relay.example.test/v1/relay").unwrap();
        let rung = RelaySocketRung {
            endpoint: &url,
            authorization: None,
            maximum_message_bytes: 1024,
            tls: &tls,
        };
        assert_eq!(rung.kind(), CarrierKind::WssRelay);
        assert_eq!(rung.kind().rung(), cmux_braid_carrier::Rung::LastResort);
        let endpoint = carrier_endpoint(&url);
        assert_eq!(endpoint.address, "relay.example.test:443");
        assert!(endpoint.on_443());
        let plain = carrier_endpoint(&Url::parse("ws://127.0.0.1:8080/x").unwrap());
        assert_eq!((plain.address.as_str(), plain.port()), ("127.0.0.1:8080", Some(8080)));
        let v6 = carrier_endpoint(&Url::parse("ws://[::1]/x").unwrap());
        assert_eq!((v6.address.as_str(), v6.host.as_str()), ("[::1]:80", "::1"));
    }

    #[test]
    fn a_relay_failure_survives_the_carrier_error() {
        let refused = io::Error::other(RelayOpenFailure(RelaySocketConnectError::Authentication));
        assert!(matches!(from_io(refused), RelaySocketConnectError::Authentication));
        let other = from_io(io::Error::new(io::ErrorKind::TimedOut, "slow"));
        let RelaySocketConnectError::Provider(error) = other else {
            panic!("not a provider error")
        };
        assert!(error.to_string().contains("slow"), "{error}");
        assert!(error.is_retryable_carrier_failure(), "{error}");
    }

    #[tokio::test]
    async fn the_relay_rung_opens_only_relay_endpoints() {
        let tls = RelayTls::default();
        let url = Url::parse("ws://127.0.0.1:9/").unwrap();
        let rung = RelaySocketRung {
            endpoint: &url,
            authorization: None,
            maximum_message_bytes: 8,
            tls: &tls,
        };
        let mut endpoint = carrier_endpoint(&url);
        endpoint.kind = CarrierKind::LocalHub;
        let Err(error) = rung.open(&endpoint).await else {
            panic!("opened another carrier's endpoint")
        };
        assert!(error.to_string().contains("another carrier"), "{error}");
    }
}
