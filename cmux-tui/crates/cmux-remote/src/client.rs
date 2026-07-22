use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use cmux_remote_protocol::{
    Lane, ProcessId, RequestId, RpcError, RpcEvent, RpcRequest, RpcResponse, Service,
    ServiceControl, WorkspaceRequest, WorkspaceResponse,
};
use tokio::sync::{Mutex, oneshot, watch};

use crate::service::{ServiceMultiplexer, ServiceStream};
use crate::services::MessageStream;

type PendingResponse = Result<RpcResponse, String>;
type PendingRequests = Arc<Mutex<HashMap<RequestId, oneshot::Sender<PendingResponse>>>>;

pub struct WorkspaceClient {
    multiplexer: Arc<ServiceMultiplexer>,
    interactive: WorkspaceRpcChannel,
    control: WorkspaceRpcChannel,
    cancellation: WorkspaceRpcChannel,
    bulk: WorkspaceRpcChannel,
    next_request: AtomicU64,
}

struct WorkspaceRpcChannel {
    messages: Arc<MessageStream>,
    pending: PendingRequests,
    shutdown: watch::Sender<bool>,
}

impl Drop for WorkspaceRpcChannel {
    fn drop(&mut self) {
        self.shutdown.send_replace(true);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RpcTrafficClass {
    Interactive,
    Control,
    Cancellation,
    Bulk,
}

impl WorkspaceClient {
    pub async fn connect(multiplexer: Arc<ServiceMultiplexer>) -> Result<Arc<Self>, RpcError> {
        let (interactive, control, cancellation, bulk) = tokio::try_join!(
            connect_rpc_channel(multiplexer.clone(), RpcTrafficClass::Interactive),
            connect_rpc_channel(multiplexer.clone(), RpcTrafficClass::Control),
            connect_rpc_channel(multiplexer.clone(), RpcTrafficClass::Cancellation),
            connect_rpc_channel(multiplexer.clone(), RpcTrafficClass::Bulk),
        )?;
        Ok(Arc::new(Self {
            multiplexer,
            interactive,
            control,
            cancellation,
            bulk,
            // A random start avoids collisions between independently
            // constructed clients sharing one authenticated session.
            next_request: AtomicU64::new(request_id_seed()),
        }))
    }

    pub fn multiplexer(&self) -> &Arc<ServiceMultiplexer> {
        &self.multiplexer
    }

    pub async fn request(&self, request: WorkspaceRequest) -> Result<WorkspaceResponse, RpcError> {
        self.begin_request(request).await?.receive().await
    }

    /// Start an RPC without waiting for it. Concurrent requests may execute in
    /// parallel across traffic classes; callers with dependent operations must
    /// await [`PendingWorkspaceRequest::receive`] before starting the next.
    /// The returned request ID can be canceled with [`Self::cancel_request`].
    pub async fn begin_request(
        &self,
        request: WorkspaceRequest,
    ) -> Result<PendingWorkspaceRequest, RpcError> {
        self.begin_request_inner(request, None).await
    }

    /// Start an RPC with a deadline enforced by both the server and client.
    pub async fn begin_request_with_timeout(
        &self,
        request: WorkspaceRequest,
        timeout: Duration,
    ) -> Result<PendingWorkspaceRequest, RpcError> {
        if timeout.is_zero() {
            return Err(RpcError::new("invalid-argument", "request timeout must be non-zero"));
        }
        let timeout_ms = u64::try_from(timeout.as_millis())
            .map_err(|_| RpcError::new("invalid-argument", "request timeout is too large"))?;
        self.begin_request_inner(request, Some((timeout_ms.max(1), timeout))).await
    }

    pub async fn request_with_timeout(
        &self,
        request: WorkspaceRequest,
        timeout: Duration,
    ) -> Result<WorkspaceResponse, RpcError> {
        self.begin_request_with_timeout(request, timeout).await?.receive().await
    }

    /// Cancel an in-flight request. The daemon keeps a bounded cancellation
    /// tombstone if this control-lane request overtakes a target on another
    /// lane.
    pub async fn cancel_request(&self, target: RequestId) -> Result<bool, RpcError> {
        let response = self.request(WorkspaceRequest::CancelRequest { request: target }).await?;
        match response {
            WorkspaceResponse::RequestCanceled { request, accepted } if request == target => {
                Ok(accepted)
            }
            _ => Err(RpcError::new("protocol", "invalid cancel-request response")),
        }
    }

    async fn begin_request_inner(
        &self,
        request: WorkspaceRequest,
        timeout: Option<(u64, Duration)>,
    ) -> Result<PendingWorkspaceRequest, RpcError> {
        let channel = self.channel(rpc_traffic_class(&request));
        let id = self.next_request_id()?;
        let timeout_ms = timeout.map(|(milliseconds, _)| milliseconds);
        let encoded = serde_json::to_vec(&RpcRequest { id, timeout_ms, request })
            .map_err(|error| RpcError::new("protocol", error.to_string()))?;
        let (sender, receiver) = oneshot::channel();
        channel.pending.lock().await.insert(id, sender);
        if let Err(error) = channel.messages.send(&encoded).await {
            channel.pending.lock().await.remove(&id);
            return Err(transport_error(error));
        }
        Ok(PendingWorkspaceRequest {
            id,
            receiver,
            timeout: timeout.map(|(_, duration)| duration),
            pending: channel.pending.clone(),
        })
    }

    fn channel(&self, class: RpcTrafficClass) -> &WorkspaceRpcChannel {
        match class {
            RpcTrafficClass::Interactive => &self.interactive,
            RpcTrafficClass::Control => &self.control,
            RpcTrafficClass::Cancellation => &self.cancellation,
            RpcTrafficClass::Bulk => &self.bulk,
        }
    }

    fn next_request_id(&self) -> Result<RequestId, RpcError> {
        self.next_request
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |value| value.checked_add(1))
            .map(RequestId)
            .map_err(|_| RpcError::new("resource-exhausted", "request identifiers exhausted"))
    }

    pub async fn process_events(
        &self,
        process: ProcessId,
        after_sequence: u64,
    ) -> Result<ProcessEventStream, RpcError> {
        let metadata = BTreeMap::from([
            ("process".into(), process.0.to_string()),
            ("after".into(), after_sequence.to_string()),
        ]);
        let stream = self
            .multiplexer
            .open(Service::ProcessStream, metadata)
            .await
            .map_err(transport_error)?;
        await_opened(&stream).await?;
        Ok(ProcessEventStream { messages: MessageStream::new(Arc::new(stream)) })
    }
}

pub struct PendingWorkspaceRequest {
    id: RequestId,
    receiver: oneshot::Receiver<PendingResponse>,
    timeout: Option<Duration>,
    pending: PendingRequests,
}

impl PendingWorkspaceRequest {
    pub fn id(&self) -> RequestId {
        self.id
    }

    pub async fn receive(self) -> Result<WorkspaceResponse, RpcError> {
        let response = match self.timeout {
            Some(timeout) => match tokio::time::timeout(timeout, self.receiver).await {
                Ok(response) => response,
                Err(_) => {
                    self.pending.lock().await.remove(&self.id);
                    return Err(RpcError::new("deadline-exceeded", "request deadline exceeded"));
                }
            },
            None => self.receiver.await,
        };
        self.pending.lock().await.remove(&self.id);
        response
            .map_err(|_| RpcError::new("transport", "workspace RPC response was canceled"))?
            .map_err(|message| RpcError::new("transport", message))?
            .result
    }
}

pub struct ProcessEventStream {
    messages: MessageStream,
}

impl ProcessEventStream {
    pub async fn receive(&self) -> Result<Option<RpcEvent>, RpcError> {
        let Some(encoded) = self.messages.receive().await.map_err(transport_error)? else {
            return Ok(None);
        };
        serde_json::from_slice(&encoded)
            .map(Some)
            .map_err(|error| RpcError::new("protocol", error.to_string()))
    }
}

async fn connect_rpc_channel(
    multiplexer: Arc<ServiceMultiplexer>,
    class: RpcTrafficClass,
) -> Result<WorkspaceRpcChannel, RpcError> {
    let stream = multiplexer
        .open(Service::WorkspaceRpc, rpc_metadata(class))
        .await
        .map_err(transport_error)?;
    await_opened(&stream).await?;
    let messages = Arc::new(MessageStream::with_lane(Arc::new(stream), rpc_lane(class)));
    let pending = Arc::new(Mutex::new(HashMap::new()));
    let (shutdown, mut shutdown_rx) = watch::channel(false);
    let channel =
        WorkspaceRpcChannel { messages: messages.clone(), pending: pending.clone(), shutdown };
    tokio::spawn(async move {
        let failure = loop {
            let received = tokio::select! {
                biased;
                changed = shutdown_rx.changed() => {
                    if changed.is_err() || *shutdown_rx.borrow() {
                        break "workspace RPC client closed".to_string();
                    }
                    continue;
                }
                received = messages.receive() => received,
            };
            let encoded = match received {
                Ok(Some(encoded)) => encoded,
                Ok(None) => break "workspace RPC stream closed".to_string(),
                Err(error) => break error.to_string(),
            };
            let response = match serde_json::from_slice::<RpcResponse>(&encoded) {
                Ok(response) => response,
                Err(error) => break error.to_string(),
            };
            if let Some(sender) = pending.lock().await.remove(&response.id) {
                let _ = sender.send(Ok(response));
            }
        };
        let _ = messages.close().await;
        for (_, sender) in pending.lock().await.drain() {
            let _ = sender.send(Err(failure.clone()));
        }
    });
    Ok(channel)
}

fn rpc_metadata(class: RpcTrafficClass) -> BTreeMap<String, String> {
    let lane = match class {
        RpcTrafficClass::Interactive => "interactive",
        RpcTrafficClass::Control | RpcTrafficClass::Cancellation => "control",
        RpcTrafficClass::Bulk => "bulk",
    };
    let mut metadata = BTreeMap::from([("lane".into(), lane.into())]);
    if class == RpcTrafficClass::Cancellation {
        metadata.insert("purpose".into(), "cancellation".into());
    }
    metadata
}

fn rpc_lane(class: RpcTrafficClass) -> Lane {
    match class {
        RpcTrafficClass::Interactive => Lane::Interactive,
        RpcTrafficClass::Control | RpcTrafficClass::Cancellation => Lane::Control,
        RpcTrafficClass::Bulk => Lane::Bulk,
    }
}

fn rpc_traffic_class(request: &WorkspaceRequest) -> RpcTrafficClass {
    match request {
        WorkspaceRequest::WriteProcess { .. }
        | WorkspaceRequest::ResizeProcess { .. }
        | WorkspaceRequest::SignalProcess { .. } => RpcTrafficClass::Interactive,
        WorkspaceRequest::ReadFile { .. }
        | WorkspaceRequest::WriteFile { .. }
        | WorkspaceRequest::ListDirectory { .. }
        | WorkspaceRequest::Search { .. }
        | WorkspaceRequest::ApplyPatch { .. }
        | WorkspaceRequest::GitStatus { .. }
        | WorkspaceRequest::Diff { .. }
        | WorkspaceRequest::ReadProcessEvents { .. } => RpcTrafficClass::Bulk,
        WorkspaceRequest::Capabilities
        | WorkspaceRequest::OpenWorkspace { .. }
        | WorkspaceRequest::ListWorkspaces
        | WorkspaceRequest::Stat { .. }
        | WorkspaceRequest::SpawnProcess { .. }
        | WorkspaceRequest::WaitProcess { .. }
        | WorkspaceRequest::FinishOperation { .. }
        | WorkspaceRequest::CloseWorkspace { .. }
        | WorkspaceRequest::CreateRoute { .. }
        | WorkspaceRequest::CloseRoute { .. }
        | WorkspaceRequest::ComputerUseCapabilities
        | WorkspaceRequest::ComputerUseCapabilitiesV1
        | WorkspaceRequest::InvokeComputerUse { .. }
        | WorkspaceRequest::CancelComputerUse { .. } => RpcTrafficClass::Control,
        WorkspaceRequest::CancelRequest { .. } => RpcTrafficClass::Cancellation,
    }
}

async fn await_opened(stream: &ServiceStream) -> Result<(), RpcError> {
    let chunk = stream
        .receive()
        .await
        .map_err(transport_error)?
        .ok_or_else(|| RpcError::new("transport", "service stream closed during open"))?;
    match serde_json::from_slice::<ServiceControl>(&chunk.payload)
        .map_err(|error| RpcError::new("protocol", error.to_string()))?
    {
        ServiceControl::Opened { service } if service == stream.service() => Ok(()),
        ServiceControl::Rejected { code, message } => Err(RpcError::new(code, message)),
        _ => Err(RpcError::new("protocol", "invalid service-open response")),
    }
}

fn transport_error(error: impl std::fmt::Display) -> RpcError {
    RpcError::new("transport", error.to_string())
}

fn request_id_seed() -> u64 {
    let bytes = uuid::Uuid::new_v4().into_bytes();
    u64::from_le_bytes(bytes[..8].try_into().expect("UUID contains eight request ID bytes"))
        & (u64::MAX >> 1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_remote_protocol::{
        ByteString, ComputerUseInvocationId, FilePrecondition, WorkspaceId,
    };

    #[test]
    fn workspace_requests_use_latency_appropriate_lanes() {
        let workspace = WorkspaceId("workspace".into());
        assert_eq!(
            rpc_traffic_class(&WorkspaceRequest::WriteProcess {
                process: ProcessId(1),
                write_id: 1,
                data: ByteString::from_bytes(b"x"),
                eof: false,
            }),
            RpcTrafficClass::Interactive
        );
        assert_eq!(
            rpc_traffic_class(&WorkspaceRequest::WriteFile {
                workspace,
                path: "large.bin".into(),
                data: ByteString::from_bytes(b"data"),
                precondition: FilePrecondition::Any,
                create_parents: false,
            }),
            RpcTrafficClass::Bulk
        );
        assert_eq!(
            rpc_traffic_class(&WorkspaceRequest::CancelComputerUse {
                invocation: ComputerUseInvocationId(1),
            }),
            RpcTrafficClass::Control
        );
        assert_eq!(rpc_traffic_class(&WorkspaceRequest::Capabilities), RpcTrafficClass::Control);
        assert_eq!(
            rpc_traffic_class(&WorkspaceRequest::CancelRequest { request: RequestId(9) }),
            RpcTrafficClass::Cancellation
        );
    }
}
