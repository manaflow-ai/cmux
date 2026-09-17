//! Generated Swift ownership and async bindings. No hand-written pointer API.
use cmux_v3_grants::AuthorityKeys;
use cmux_v3_transport::{
    endpoint::Endpoint,
    session::{self, Lane, LaneKind, Session, SessionSender},
};
use ed25519_dalek::VerifyingKey;
use libp2p::{identity, PeerId};
use std::{collections::HashMap, future::Future, sync::Arc};
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;

uniffi::setup_scaffolding!();

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum NativeError {
    #[error("invalid argument")]
    Invalid,
    #[error("cancelled")]
    Cancelled,
    #[error("closed")]
    Closed,
    #[error("authorization denied")]
    Denied,
    #[error("authorization expired")]
    Expired,
    #[error("authorization revoked")]
    Revoked,
    #[error("capacity reached")]
    Capacity,
    #[error("transport failure")]
    Transport,
}
impl From<session::Error> for NativeError {
    fn from(error: session::Error) -> Self {
        match error {
            session::Error::Denied => Self::Denied,
            session::Error::Expired => Self::Expired,
            session::Error::Revoked => Self::Revoked,
            session::Error::Closed => Self::Closed,
            session::Error::Capacity | session::Error::Busy => Self::Capacity,
            _ => Self::Transport,
        }
    }
}

/// Explicit cancellation also works where a foreign async runtime cannot drop
/// the Rust future directly. Cancelling one operation never closes another lane.
#[derive(uniffi::Object)]
pub struct Operation {
    cancelled: CancellationToken,
}
#[uniffi::export]
impl Operation {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            cancelled: CancellationToken::new(),
        })
    }
    pub fn cancel(&self) {
        self.cancelled.cancel();
    }
}
impl Operation {
    async fn run<T>(
        &self,
        future: impl Future<Output = Result<T, session::Error>>,
    ) -> Result<T, NativeError> {
        tokio::select! {
            biased;
            _ = self.cancelled.cancelled() => Err(NativeError::Cancelled),
            value = future => value.map_err(Into::into),
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LaneDescriptor {
    pub kind: u8,
    pub resource: Option<String>,
    pub cursor: Option<u64>,
}
impl TryFrom<LaneDescriptor> for Lane {
    type Error = NativeError;
    fn try_from(value: LaneDescriptor) -> Result<Self, Self::Error> {
        let kind = match value.kind {
            0 => LaneKind::Control,
            1 => LaneKind::Events,
            2 => LaneKind::Terminal,
            3 => LaneKind::TerminalInput,
            4 => LaneKind::Artifact,
            5 => LaneKind::Simulator,
            _ => return Err(NativeError::Invalid),
        };
        let lane = Lane {
            kind,
            resource: value.resource,
            cursor: value.cursor,
        };
        lane.validate().map_err(|_| NativeError::Invalid)?;
        Ok(lane)
    }
}
impl From<Lane> for LaneDescriptor {
    fn from(value: Lane) -> Self {
        let kind = match value.kind {
            LaneKind::Control => 0,
            LaneKind::Events => 1,
            LaneKind::Terminal => 2,
            LaneKind::TerminalInput => 3,
            LaneKind::Artifact => 4,
            LaneKind::Simulator => 5,
        };
        Self {
            kind,
            resource: value.resource,
            cursor: value.cursor,
        }
    }
}

#[derive(uniffi::Record)]
pub struct AcceptedStream {
    pub peer_id: String,
    pub lane: LaneDescriptor,
    pub stream: Arc<NativeStream>,
}

#[derive(uniffi::Object)]
pub struct NativeEndpoint {
    endpoint: Endpoint,
}
#[uniffi::export(async_runtime = "tokio")]
impl NativeEndpoint {
    #[uniffi::constructor]
    pub async fn create(
        seed: Vec<u8>,
        team: String,
        authority_keys: HashMap<String, Vec<u8>>,
    ) -> Result<Arc<Self>, NativeError> {
        if seed.len() != 32 || authority_keys.is_empty() || authority_keys.len() > 32 {
            return Err(NativeError::Invalid);
        }
        let key = identity::Keypair::ed25519_from_bytes(seed).map_err(|_| NativeError::Invalid)?;
        let mut keys = AuthorityKeys::default();
        for (id, bytes) in authority_keys {
            if id.is_empty() || id.len() > 128 {
                return Err(NativeError::Invalid);
            }
            let raw: [u8; 32] = bytes.try_into().map_err(|_| NativeError::Invalid)?;
            keys.insert(
                id,
                VerifyingKey::from_bytes(&raw).map_err(|_| NativeError::Invalid)?,
            );
        }
        let endpoint = Endpoint::new(key, team, Arc::new(keys)).await?;
        Ok(Arc::new(Self { endpoint }))
    }
    pub fn peer_id(&self) -> String {
        self.endpoint.peer.to_string()
    }
    pub fn close(&self) {
        self.endpoint.close();
    }
    pub async fn listen(
        &self,
        address: String,
        operation: Arc<Operation>,
    ) -> Result<String, NativeError> {
        let address = address.parse().map_err(|_| NativeError::Invalid)?;
        operation
            .run(self.endpoint.listen(address))
            .await
            .map(|a| a.to_string())
    }
    pub async fn addresses(&self, operation: Arc<Operation>) -> Result<Vec<String>, NativeError> {
        Ok(operation
            .run(self.endpoint.addresses())
            .await?
            .iter()
            .map(ToString::to_string)
            .collect())
    }
    pub async fn reserve(
        &self,
        address: String,
        grant: String,
        operation: Arc<Operation>,
    ) -> Result<String, NativeError> {
        if grant.len() > 8192 || address.len() > 2048 {
            return Err(NativeError::Invalid);
        }
        let address = address.parse().map_err(|_| NativeError::Invalid)?;
        operation
            .run(self.endpoint.reserve(address, grant))
            .await
            .map(|a| a.to_string())
    }
    pub async fn open(
        &self,
        peer_id: String,
        address: String,
        grant: String,
        relay_grant: Option<String>,
        lane: LaneDescriptor,
        operation: Arc<Operation>,
    ) -> Result<Arc<NativeStream>, NativeError> {
        if address.len() > 2048
            || grant.len() > 8192
            || relay_grant.as_ref().is_some_and(|g| g.len() > 8192)
        {
            return Err(NativeError::Invalid);
        }
        let peer = peer_id.parse().map_err(|_| NativeError::Invalid)?;
        let address = address.parse().map_err(|_| NativeError::Invalid)?;
        let stream = operation
            .run(
                self.endpoint
                    .open(peer, address, grant, relay_grant, lane.try_into()?),
            )
            .await?;
        Ok(NativeStream::new(stream, self.endpoint.cancellation()))
    }
    pub async fn accept(&self, operation: Arc<Operation>) -> Result<AcceptedStream, NativeError> {
        let accepted = operation.run(self.endpoint.accept()).await?;
        Ok(AcceptedStream {
            peer_id: accepted.peer.to_string(),
            lane: accepted.lane.into(),
            stream: NativeStream::new(accepted.session, self.endpoint.cancellation()),
        })
    }
    /// Caller supplies verified server updates; these only revoke, never grant.
    pub fn update_revocations(&self, revision: u64, peers: Vec<String>) -> Result<(), NativeError> {
        if peers.len() > 10000 {
            return Err(NativeError::Invalid);
        }
        let peers = peers
            .into_iter()
            .map(|p| p.parse::<PeerId>().map_err(|_| NativeError::Invalid))
            .collect::<Result<_, _>>()?;
        self.endpoint.update_revocations(revision, peers);
        Ok(())
    }
}

#[derive(uniffi::Object)]
pub struct NativeStream {
    receiving: Mutex<Session>,
    writing: Mutex<()>,
    sending: SessionSender,
    stopped: CancellationToken,
    endpoint: CancellationToken,
}
impl NativeStream {
    fn new(session: Session, endpoint: CancellationToken) -> Arc<Self> {
        Arc::new(Self {
            sending: session.sender(),
            receiving: Mutex::new(session),
            writing: Mutex::new(()),
            stopped: CancellationToken::new(),
            endpoint,
        })
    }
    async fn run<T>(
        &self,
        operation: &Operation,
        future: impl Future<Output = Result<T, session::Error>>,
    ) -> Result<T, NativeError> {
        tokio::select! {
            biased;
            _ = self.stopped.cancelled() => Err(NativeError::Closed),
            _ = self.endpoint.cancelled() => Err(NativeError::Closed),
            result = operation.run(future) => result,
        }
    }
}
impl Drop for NativeStream {
    fn drop(&mut self) {
        self.sending.close();
    }
}
#[uniffi::export(async_runtime = "tokio")]
impl NativeStream {
    pub fn is_closed(&self) -> bool {
        self.stopped.is_cancelled() || self.endpoint.is_cancelled() || self.sending.is_closed()
    }
    pub async fn wait_closed(&self, operation: Arc<Operation>) -> Result<NativeError, NativeError> {
        self.run(&operation, async { Ok(self.sending.closed().await.into()) })
            .await
    }
    pub fn close(&self) {
        self.stopped.cancel();
        self.sending.close();
    }
    pub async fn send(&self, data: Vec<u8>, operation: Arc<Operation>) -> Result<(), NativeError> {
        if data.is_empty() || data.len() > 16 * 1024 * 1024 {
            return Err(NativeError::Invalid);
        }
        let result = self
            .run(&operation, async {
                let _write = self.writing.lock().await;
                for chunk in data.chunks(session::MAX_DATA) {
                    self.sending.send(chunk.to_vec().into()).await?;
                }
                Ok(())
            })
            .await;
        // A cancelled partial application write cannot be spliced with a later one.
        if result == Err(NativeError::Cancelled) {
            self.close();
        }
        result
    }
    pub async fn receive(&self, operation: Arc<Operation>) -> Result<Vec<u8>, NativeError> {
        self.run(&operation, async {
            self.receiving.lock().await.receive().await
        })
        .await
        .map(|b| b.to_vec())
    }
    pub async fn renew(&self, grant: String, operation: Arc<Operation>) -> Result<(), NativeError> {
        self.run(&operation, self.sending.renew(grant)).await
    }
}
