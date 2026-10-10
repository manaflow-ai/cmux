use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use async_trait::async_trait;
use tokio::net::UnixStream;

use crate::admin::verify_unix_peer_owner;
use crate::link::{FrameLink, LinkError};
use crate::observability::{TransportPathKind, TransportPathSnapshot, TransportSnapshot};
use crate::provider::{
    CarrierEvidence, ConnectRequest, LengthDelimitedLink, LinkGroup, LinkRequest,
    ProviderCapabilities, ProviderError, SupportedClientAuthModes, TransportProvider,
};

#[derive(Debug, Clone)]
pub struct UnixProvider {
    maximum: usize,
}

impl UnixProvider {
    pub fn new(maximum: usize) -> Self {
        Self { maximum }
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
        }))
    }
}

struct UnixLinkGroup {
    description: String,
    path: PathBuf,
    maximum: usize,
    evidence: CarrierEvidence,
    closed: AtomicBool,
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
}
