use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use async_trait::async_trait;
use tokio::net::UnixStream;

use crate::admin::verify_unix_peer_owner;
#[cfg(test)]
use crate::admin::verify_unix_peer_uid;
use crate::link::{FrameLink, LinkError};
use crate::observability::{TransportPathKind, TransportPathSnapshot, TransportSnapshot};
use crate::provider::{
    CarrierEvidence, ConnectRequest, LengthDelimitedLink, LinkGroup, LinkRequest,
    ProviderCapabilities, ProviderError, SupportedClientAuthModes, TransportProvider,
};

#[derive(Debug, Clone)]
pub struct UnixProvider {
    maximum: usize,
    #[cfg(test)]
    expected_uid: Option<u32>,
}

impl UnixProvider {
    pub fn new(maximum: usize) -> Self {
        Self {
            maximum,
            #[cfg(test)]
            expected_uid: None,
        }
    }

    #[cfg(test)]
    fn new_with_expected_uid(maximum: usize, expected_uid: u32) -> Self {
        Self { maximum, expected_uid: Some(expected_uid) }
    }
}

#[async_trait]
impl TransportProvider for UnixProvider {
    fn name(&self) -> &'static str {
        "unix"
    }

    fn schemes(&self) -> &'static [&'static str] {
        &["unix"]
    }

    fn supported_client_auth(&self) -> SupportedClientAuthModes {
        SupportedClientAuthModes::DeviceOrCarrier
    }

    async fn connect(&self, request: ConnectRequest) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        let path = request.endpoint.to_file_path().map_err(|_| {
            ProviderError::Configuration("unix endpoint must contain an absolute path".into())
        })?;
        Ok(Arc::new(UnixLinkGroup {
            description: format!("unix://{}", path.display()),
            path,
            maximum: self.maximum,
            evidence: CarrierEvidence::LocalPeer { uid: None, pid: None },
            closed: AtomicBool::new(false),
            #[cfg(test)]
            expected_uid: self.expected_uid,
        }))
    }
}

struct UnixLinkGroup {
    description: String,
    path: PathBuf,
    maximum: usize,
    evidence: CarrierEvidence,
    closed: AtomicBool,
    #[cfg(test)]
    expected_uid: Option<u32>,
}

fn retryable_dial_error(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::NotFound
            | std::io::ErrorKind::ConnectionRefused
            | std::io::ErrorKind::ConnectionReset
            | std::io::ErrorKind::ConnectionAborted
            | std::io::ErrorKind::TimedOut
            | std::io::ErrorKind::Interrupted
            | std::io::ErrorKind::WouldBlock
    )
}

#[async_trait]
impl LinkGroup for UnixLinkGroup {
    fn description(&self) -> &str {
        &self.description
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities { carrier_encryption: false, ..ProviderCapabilities::MULTI_STREAM }
    }

    fn evidence(&self) -> &CarrierEvidence {
        &self.evidence
    }

    async fn transport_snapshot(&self) -> TransportSnapshot {
        TransportSnapshot {
            provider: "unix".into(),
            route: self.description.clone(),
            selected_path: Some(TransportPathSnapshot {
                kind: TransportPathKind::Local,
                remote: None,
                rtt_micros: None,
            }),
        }
    }

    async fn open(&self, _request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(ProviderError::Link(LinkError::Closed));
        }
        let stream = UnixStream::connect(&self.path).await.map_err(|error| {
            if retryable_dial_error(&error) {
                ProviderError::Link(LinkError::Transport(error.to_string()))
            } else {
                ProviderError::Transport(error.to_string())
            }
        })?;
        #[cfg(test)]
        let peer_validation = match self.expected_uid {
            Some(expected_uid) => verify_unix_peer_uid(&stream, expected_uid),
            None => verify_unix_peer_owner(&stream),
        };
        #[cfg(not(test))]
        let peer_validation = verify_unix_peer_owner(&stream);
        peer_validation.map_err(|error| ProviderError::Transport(error.to_string()))?;
        let (reader, writer) = stream.into_split();
        Ok(Box::new(LengthDelimitedLink::new(
            self.description.clone(),
            self.maximum,
            reader,
            writer,
        )))
    }

    async fn close(&self) -> Result<(), ProviderError> {
        self.closed.store(true, Ordering::Release);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use cmux_remote_protocol::{Lane, LanePolicy, SessionId};
    use tempfile::tempdir;
    use tokio::net::UnixListener;
    use url::Url;

    use super::*;

    fn request(path: &std::path::Path) -> ConnectRequest {
        let mut endpoint = Url::parse("unix:///").unwrap();
        endpoint.set_path(path.to_str().unwrap());
        ConnectRequest {
            endpoint,
            session: SessionId::ZERO,
            lane_policy: LanePolicy::Single,
            routing: BTreeMap::new(),
        }
    }

    async fn open_with_expected_uid(path: &std::path::Path, expected_uid: u32) {
        let group = UnixProvider::new_with_expected_uid(1024, expected_uid)
            .connect(request(path))
            .await
            .unwrap();
        group
            .open(LinkRequest { lane: Lane::Interactive, generation: 1 })
            .await
            .unwrap_or_else(|error| panic!("same-uid Unix responder was rejected: {error}"));
    }

    #[tokio::test]
    async fn accepts_responder_owned_by_effective_uid() {
        let directory = tempdir().unwrap();
        let socket = directory.path().join("carrier.sock");
        let _listener = UnixListener::bind(&socket).unwrap();

        open_with_expected_uid(&socket, unsafe { libc::geteuid() }).await;
    }

    #[tokio::test]
    async fn transient_dial_failures_are_retryable_carrier_failures() {
        let directory = tempdir().unwrap();
        let missing = directory.path().join("missing.sock");
        let refused = directory.path().join("refused.sock");
        drop(UnixListener::bind(&refused).unwrap());

        for socket in [missing, refused] {
            let group = UnixProvider::new(1024).connect(request(&socket)).await.unwrap();
            let error =
                match group.open(LinkRequest { lane: Lane::Interactive, generation: 1 }).await {
                    Ok(_) => panic!("unavailable Unix responder was accepted"),
                    Err(error) => error,
                };
            assert!(
                error.is_retryable_carrier_failure(),
                "Unix dial failure for {} was terminal: {error}",
                socket.display()
            );
        }
    }

    #[tokio::test]
    async fn permanent_dial_failures_are_terminal() {
        let directory = tempdir().unwrap();
        let non_directory = directory.path().join("ordinary-file");
        std::fs::write(&non_directory, b"not a directory").unwrap();
        let socket = non_directory.join("carrier.sock");
        let group = UnixProvider::new(1024).connect(request(&socket)).await.unwrap();
        let error = match group.open(LinkRequest { lane: Lane::Interactive, generation: 1 }).await {
            Ok(_) => panic!("invalid Unix socket path was accepted"),
            Err(error) => error,
        };

        assert!(!error.is_retryable_carrier_failure(), "permanent dial failure was retryable");
    }

    #[tokio::test]
    async fn rejects_responder_owned_by_another_uid() {
        let directory = tempdir().unwrap();
        let socket = directory.path().join("carrier.sock");
        let _listener = UnixListener::bind(&socket).unwrap();
        let wrong_uid = unsafe { libc::geteuid() }.wrapping_add(1);
        let group = UnixProvider::new_with_expected_uid(1024, wrong_uid)
            .connect(request(&socket))
            .await
            .unwrap();

        let error = match group.open(LinkRequest { lane: Lane::Interactive, generation: 1 }).await {
            Ok(_) => panic!("wrong-uid Unix responder was accepted"),
            Err(error) => error,
        };
        assert!(
            matches!(error, ProviderError::Transport(ref message) if message.contains("peer uid")),
            "unexpected error: {error}"
        );
        assert!(
            !error.is_retryable_carrier_failure(),
            "peer ownership rejection must remain terminal"
        );
    }

    #[tokio::test]
    async fn missing_socket_is_a_retryable_carrier_failure() {
        let directory = tempdir().unwrap();
        let socket = directory.path().join("missing.sock");
        let group = UnixProvider::new(1024).connect(request(&socket)).await.unwrap();

        let error = match group.open(LinkRequest { lane: Lane::Interactive, generation: 1 }).await {
            Ok(_) => panic!("missing Unix socket unexpectedly opened"),
            Err(error) => error,
        };
        assert!(
            matches!(error, ProviderError::Link(LinkError::Transport(_))),
            "unexpected error: {error}"
        );
        assert!(error.is_retryable_carrier_failure());
    }

    #[tokio::test]
    async fn closed_group_is_a_retryable_carrier_failure() {
        let directory = tempdir().unwrap();
        let socket = directory.path().join("carrier.sock");
        let group = UnixProvider::new(1024).connect(request(&socket)).await.unwrap();
        group.close().await.unwrap();

        let error = match group.open(LinkRequest { lane: Lane::Interactive, generation: 1 }).await {
            Ok(_) => panic!("closed Unix connection group unexpectedly opened"),
            Err(error) => error,
        };
        assert!(
            matches!(error, ProviderError::Link(LinkError::Closed)),
            "unexpected error: {error}"
        );
        assert!(error.is_retryable_carrier_failure());
    }
}
