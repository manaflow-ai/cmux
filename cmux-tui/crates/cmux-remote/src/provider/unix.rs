use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use async_trait::async_trait;
use tokio::net::UnixStream;

use crate::link::FrameLink;
use crate::provider::{
    CarrierEvidence, ConnectRequest, LengthDelimitedLink, LinkGroup, LinkRequest,
    ProviderCapabilities, ProviderError, TransportProvider,
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

    async fn open(&self, _request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(ProviderError::Transport("Unix connection group is closed".into()));
        }
        let stream = UnixStream::connect(&self.path)
            .await
            .map_err(|error| ProviderError::Transport(error.to_string()))?;
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
