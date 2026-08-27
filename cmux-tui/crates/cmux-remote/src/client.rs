use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_remote_protocol::{
    Lane, OperationId, ProcessId, RequestId, RpcError, RpcEvent, RpcRequest, RpcResponse, Service,
    ServiceControl, WorkspaceRequest, WorkspaceResponse,
};
use tokio::sync::{mpsc, oneshot, watch};

use crate::service::{ServiceMultiplexer, ServiceStream};
use crate::services::MessageStream;

type PendingResponse = Result<RpcResponse, String>;
type RequestRegistry = Arc<Mutex<WorkspaceRequestRegistry>>;
const DROPPED_CANCELLATION_QUEUE: usize = 128;
const MAX_IGNORED_RESPONSES: usize = 4096;

pub struct WorkspaceClient {
    multiplexer: Arc<ServiceMultiplexer>,
    process_input: WorkspaceRpcChannel,
    process_control: WorkspaceRpcChannel,
    control: WorkspaceRpcChannel,
    cancellation: WorkspaceRpcChannel,
    bulk: WorkspaceRpcChannel,
    dropped_cancellations: mpsc::Sender<DroppedWorkspaceRequest>,
}

struct WorkspaceRpcChannel {
    messages: Arc<MessageStream>,
    requests: RequestRegistry,
    shutdown: watch::Sender<bool>,
}

#[derive(Default)]
struct WorkspaceRequestRegistry {
    // Live and retired IDs share one lock so cancellation cannot expose a
    // response-routing gap between removing a pending request and retiring it.
    pending: HashMap<RequestId, oneshot::Sender<PendingResponse>>,
    ignored: IgnoredResponses,
}

#[derive(Default)]
struct IgnoredResponses {
    ids: HashSet<RequestId>,
    order: VecDeque<RequestId>,
}

impl IgnoredResponses {
    fn insert(&mut self, id: RequestId) {
        if self.ids.insert(id) {
            self.order.push_back(id);
        }
        while self.order.len() > MAX_IGNORED_RESPONSES {
            let Some(oldest) = self.order.pop_front() else { break };
            self.ids.remove(&oldest);
        }
    }

    fn remove(&mut self, id: &RequestId) -> bool {
        self.ids.remove(id)
    }
}

struct DroppedWorkspaceRequest {
    target: RequestId,
    origin_shutdown: watch::Sender<bool>,
}

impl Drop for WorkspaceRpcChannel {
    fn drop(&mut self) {
        self.shutdown.send_replace(true);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RpcTrafficClass {
    ProcessInput,
    ProcessControl,
    Control,
    Cancellation,
    Bulk,
}

impl WorkspaceClient {
    pub async fn connect(multiplexer: Arc<ServiceMultiplexer>) -> Result<Arc<Self>, RpcError> {
        let (process_input, process_control, control, cancellation, bulk) = tokio::try_join!(
            connect_rpc_channel(multiplexer.clone(), RpcTrafficClass::ProcessInput),
            connect_rpc_channel(multiplexer.clone(), RpcTrafficClass::ProcessControl),
            connect_rpc_channel(multiplexer.clone(), RpcTrafficClass::Control),
            connect_rpc_channel(multiplexer.clone(), RpcTrafficClass::Cancellation),
            connect_rpc_channel(multiplexer.clone(), RpcTrafficClass::Bulk),
        )?;
        let dropped_cancellations =
            cancellation_worker(cancellation.messages.clone(), cancellation.requests.clone());
        Ok(Arc::new(Self {
            multiplexer,
            process_input,
            process_control,
            control,
            cancellation,
            bulk,
            dropped_cancellations,
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
        let id = self.next_request_id();
        let timeout_ms = timeout.map(|(milliseconds, _)| milliseconds);
        let deadline = timeout.map(|(_, duration)| tokio::time::Instant::now() + duration);
        let cancellable = crate::workspace::request_supports_cancellation(&request);
        let encoded = serde_json::to_vec(&RpcRequest { id, timeout_ms, request })
            .map_err(|error| RpcError::new("protocol", error.to_string()))?;
        let (sender, receiver) = oneshot::channel();
        request_registry(&channel.requests).pending.insert(id, sender);
        let mut pending = PendingWorkspaceRequest {
            id,
            receiver: Some(receiver),
            deadline,
            requests: channel.requests.clone(),
            cancellable,
            dropped_cancellations: self.dropped_cancellations.clone(),
            origin_shutdown: channel.shutdown.clone(),
            armed: true,
        };
        if let Err(error) = channel.messages.send(&encoded).await {
            pending.disarm();
            return Err(transport_error(error));
        }
        Ok(pending)
    }

    fn channel(&self, class: RpcTrafficClass) -> &WorkspaceRpcChannel {
        match class {
            RpcTrafficClass::ProcessInput => &self.process_input,
            RpcTrafficClass::ProcessControl => &self.process_control,
            RpcTrafficClass::Control => &self.control,
            RpcTrafficClass::Cancellation => &self.cancellation,
            RpcTrafficClass::Bulk => &self.bulk,
        }
    }

    fn next_request_id(&self) -> RequestId {
        RequestId::from_uuid(uuid::Uuid::new_v4())
    }

    pub async fn process_events(
        &self,
        process: ProcessId,
        after_sequence: u64,
    ) -> Result<ProcessEventStream, RpcError> {
        self.process_events_inner(process, after_sequence, false).await
    }

    /// Allocate an opaque handle before starting any asynchronous work.
    ///
    /// Callers retain this handle if the spawn future is canceled and can use
    /// it to reconnect to a process whose spawn request reached the daemon.
    pub fn allocate_process_handle(&self) -> ProcessId {
        ProcessId(uuid::Uuid::new_v4())
    }

    /// Reserve an output stream before spawning with `process`. This removes
    /// the response-before-subscribe race for commands that emit immediately.
    pub async fn spawn_process_with_events(
        &self,
        process: ProcessId,
        request: WorkspaceRequest,
    ) -> Result<SpawnedProcess, RpcError> {
        let request = attach_process_handle(request, process)?;
        let events = self.process_events_inner(process, 0, true).await?;
        let response = match self.request(request).await {
            Ok(response) => response,
            Err(error) => {
                let _ = events.close().await;
                return Err(error);
            }
        };
        let WorkspaceResponse::ProcessStarted { process: started, pid, operation } = response
        else {
            let _ = events.close().await;
            return Err(RpcError::new("protocol", "invalid spawn-process response"));
        };
        if started != process {
            let _ = events.close().await;
            return Err(RpcError::new(
                "protocol",
                format!("spawn-process returned handle {started} for requested handle {process}"),
            ));
        }
        Ok(SpawnedProcess { process, pid, operation, events })
    }

    async fn process_events_inner(
        &self,
        process: ProcessId,
        after_sequence: u64,
        reserve: bool,
    ) -> Result<ProcessEventStream, RpcError> {
        let metadata = BTreeMap::from([
            ("process".into(), process.to_string()),
            ("after".into(), after_sequence.to_string()),
        ]);
        let mut metadata = metadata;
        if reserve {
            metadata.insert("reserve".into(), "true".into());
        }
        let stream = self
            .multiplexer
            .open(Service::ProcessStream, metadata)
            .await
            .map_err(transport_error)?;
        await_opened(&stream, Lane::Bulk).await?;
        Ok(ProcessEventStream { messages: MessageStream::with_lane(Arc::new(stream), Lane::Bulk) })
    }
}

pub struct PendingWorkspaceRequest {
    id: RequestId,
    receiver: Option<oneshot::Receiver<PendingResponse>>,
    deadline: Option<tokio::time::Instant>,
    requests: RequestRegistry,
    cancellable: bool,
    dropped_cancellations: mpsc::Sender<DroppedWorkspaceRequest>,
    origin_shutdown: watch::Sender<bool>,
    armed: bool,
}

impl PendingWorkspaceRequest {
    pub fn id(&self) -> RequestId {
        self.id
    }

    pub async fn receive(mut self) -> Result<WorkspaceResponse, RpcError> {
        let receiver = self.receiver.take().expect("pending workspace request has a receiver");
        let response = match self.deadline {
            Some(deadline) => match tokio::time::timeout_at(deadline, receiver).await {
                Ok(response) => response,
                Err(_) => {
                    return Err(RpcError::new("deadline-exceeded", "request deadline exceeded"));
                }
            },
            None => receiver.await,
        };
        self.disarm();
        response
            .map_err(|_| RpcError::new("transport", "workspace RPC response was canceled"))?
            .map_err(|message| RpcError::new("transport", message))?
            .result
    }

    fn disarm(&mut self) {
        if self.armed {
            request_registry(&self.requests).pending.remove(&self.id);
            self.armed = false;
        }
    }
}

impl Drop for PendingWorkspaceRequest {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        self.armed = false;
        let was_pending = {
            let mut requests = request_registry(&self.requests);
            let was_pending = requests.pending.remove(&self.id).is_some();
            if was_pending {
                requests.ignored.insert(self.id);
            }
            was_pending
        };
        if !was_pending || !self.cancellable {
            return;
        }
        let dropped = DroppedWorkspaceRequest {
            target: self.id,
            origin_shutdown: self.origin_shutdown.clone(),
        };
        if self.dropped_cancellations.try_send(dropped).is_err() {
            self.origin_shutdown.send_replace(true);
        }
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

    pub async fn close(&self) -> Result<(), RpcError> {
        self.messages.close().await.map_err(transport_error)
    }
}

pub struct SpawnedProcess {
    pub process: ProcessId,
    pub pid: Option<u32>,
    pub operation: Option<OperationId>,
    pub events: ProcessEventStream,
}

async fn connect_rpc_channel(
    multiplexer: Arc<ServiceMultiplexer>,
    class: RpcTrafficClass,
) -> Result<WorkspaceRpcChannel, RpcError> {
    let stream = multiplexer
        .open(Service::WorkspaceRpc, rpc_metadata(class))
        .await
        .map_err(transport_error)?;
    await_opened(&stream, rpc_lane(class)).await?;
    let messages = Arc::new(MessageStream::with_lane(Arc::new(stream), rpc_lane(class)));
    let requests = Arc::new(Mutex::new(WorkspaceRequestRegistry::default()));
    let (shutdown, mut shutdown_rx) = watch::channel(false);
    let failure_shutdown = shutdown.clone();
    let channel =
        WorkspaceRpcChannel { messages: messages.clone(), requests: requests.clone(), shutdown };
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
            if let Err(error) = route_response(response, &requests) {
                failure_shutdown.send_replace(true);
                break error;
            }
        };
        let _ = messages.close().await;
        for (_, sender) in request_registry(&requests).pending.drain() {
            let _ = sender.send(Err(failure.clone()));
        }
    });
    Ok(channel)
}

fn request_registry(
    requests: &RequestRegistry,
) -> std::sync::MutexGuard<'_, WorkspaceRequestRegistry> {
    requests.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn route_response(response: RpcResponse, requests: &RequestRegistry) -> Result<(), String> {
    // A response without a live request indicates a peer that lost protocol
    // state. Retired IDs are the bounded exception for cancellation and
    // callers that timed out or were dropped while their response was in
    // flight.
    let mut requests = request_registry(requests);
    if let Some(sender) = requests.pending.remove(&response.id) {
        drop(requests);
        let _ = sender.send(Ok(response));
        return Ok(());
    }
    if requests.ignored.remove(&response.id) {
        return Ok(());
    }
    Err(format!("workspace RPC response has unknown request id {}", response.id))
}

fn cancellation_worker(
    messages: Arc<MessageStream>,
    requests: RequestRegistry,
) -> mpsc::Sender<DroppedWorkspaceRequest> {
    let (sender, mut receiver) =
        mpsc::channel::<DroppedWorkspaceRequest>(DROPPED_CANCELLATION_QUEUE);
    tokio::spawn(async move {
        while let Some(dropped) = receiver.recv().await {
            let request = RpcRequest {
                id: RequestId::from_uuid(uuid::Uuid::new_v4()),
                timeout_ms: None,
                request: WorkspaceRequest::CancelRequest { request: dropped.target },
            };
            let encoded = match serde_json::to_vec(&request) {
                Ok(encoded) => encoded,
                Err(_) => {
                    dropped.origin_shutdown.send_replace(true);
                    continue;
                }
            };
            request_registry(&requests).ignored.insert(request.id);
            if messages.send(&encoded).await.is_err() {
                request_registry(&requests).ignored.remove(&request.id);
                dropped.origin_shutdown.send_replace(true);
                while let Ok(queued) = receiver.try_recv() {
                    queued.origin_shutdown.send_replace(true);
                }
                break;
            }
        }
    });
    sender
}

fn rpc_metadata(class: RpcTrafficClass) -> BTreeMap<String, String> {
    let lane = match class {
        RpcTrafficClass::ProcessInput | RpcTrafficClass::ProcessControl => "interactive",
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
        RpcTrafficClass::ProcessInput | RpcTrafficClass::ProcessControl => Lane::Interactive,
        RpcTrafficClass::Control | RpcTrafficClass::Cancellation => Lane::Control,
        RpcTrafficClass::Bulk => Lane::Bulk,
    }
}

fn rpc_traffic_class(request: &WorkspaceRequest) -> RpcTrafficClass {
    match request {
        WorkspaceRequest::WriteProcess { .. } => RpcTrafficClass::ProcessInput,
        WorkspaceRequest::ResizeProcess { .. } | WorkspaceRequest::SignalProcess { .. } => {
            RpcTrafficClass::ProcessControl
        }
        WorkspaceRequest::ReadFile { .. }
        | WorkspaceRequest::WriteFile { .. }
        | WorkspaceRequest::ListDirectory { .. }
        | WorkspaceRequest::Search { .. }
        | WorkspaceRequest::ApplyPatch { .. }
        | WorkspaceRequest::GitStatus { .. }
        | WorkspaceRequest::Diff { .. }
        | WorkspaceRequest::ReadProcessEvents { .. }
        | WorkspaceRequest::ListProcesses
        | WorkspaceRequest::SnapshotProcessTerminal { .. } => RpcTrafficClass::Bulk,
        WorkspaceRequest::Capabilities
        | WorkspaceRequest::OpenWorkspace { .. }
        | WorkspaceRequest::ListWorkspaces
        | WorkspaceRequest::Stat { .. }
        | WorkspaceRequest::SpawnProcess { .. }
        | WorkspaceRequest::SpawnProcessWithHandle { .. }
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

async fn await_opened(stream: &ServiceStream, expected_lane: Lane) -> Result<(), RpcError> {
    let chunk = stream
        .receive()
        .await
        .map_err(transport_error)?
        .ok_or_else(|| RpcError::new("transport", "service stream closed during open"))?;
    match serde_json::from_slice::<ServiceControl>(&chunk.payload)
        .map_err(|error| RpcError::new("protocol", error.to_string()))?
    {
        ServiceControl::Opened { service } if service == stream.service() => {
            if chunk.lane != expected_lane {
                return Err(RpcError::new(
                    "protocol",
                    format!(
                        "service-open response used {:?} instead of {expected_lane:?}",
                        chunk.lane
                    ),
                ));
            }
            Ok(())
        }
        ServiceControl::Rejected { code, message } => Err(RpcError::new(code, message)),
        _ => Err(RpcError::new("protocol", "invalid service-open response")),
    }
}

fn transport_error(error: impl std::fmt::Display) -> RpcError {
    RpcError::new("transport", error.to_string())
}

fn attach_process_handle(
    request: WorkspaceRequest,
    process: ProcessId,
) -> Result<WorkspaceRequest, RpcError> {
    match request {
        WorkspaceRequest::SpawnProcess {
            workspace,
            argv,
            cwd,
            env,
            io,
            lifetime,
            operation,
            timeout_ms,
            retained_output_bytes,
            environment,
        } => Ok(WorkspaceRequest::SpawnProcessWithHandle {
            process,
            workspace,
            argv,
            cwd,
            env,
            io,
            lifetime,
            operation,
            timeout_ms,
            retained_output_bytes,
            environment,
            output_drain_idle_timeout_ms: None,
            output_drain_total_timeout_ms: None,
        }),
        request @ WorkspaceRequest::SpawnProcessWithHandle { process: requested, .. }
            if requested == process =>
        {
            Ok(request)
        }
        WorkspaceRequest::SpawnProcessWithHandle { .. } => Err(RpcError::new(
            "invalid-argument",
            "spawn-process handle changed while reserving its output stream",
        )),
        _ => Err(RpcError::new(
            "invalid-argument",
            "process handle can be attached only to a spawn-process request",
        )),
    }
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
        let process_input = rpc_traffic_class(&WorkspaceRequest::WriteProcess {
            process: ProcessId::from_u128(1),
            write_id: 1,
            data: ByteString::from_bytes(b"x"),
            eof: false,
        });
        let process_resize = rpc_traffic_class(&WorkspaceRequest::ResizeProcess {
            process: ProcessId::from_u128(1),
            cols: 80,
            rows: 24,
        });
        let process_signal = rpc_traffic_class(&WorkspaceRequest::SignalProcess {
            process: ProcessId::from_u128(1),
            signal: cmux_remote_protocol::ProcessSignal::Interrupt,
        });
        assert_eq!(rpc_lane(process_input), Lane::Interactive);
        assert_eq!(rpc_lane(process_resize), Lane::Interactive);
        assert_eq!(rpc_lane(process_signal), Lane::Interactive);
        assert_ne!(process_input, process_signal);
        assert_eq!(process_resize, process_signal);
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
                invocation: ComputerUseInvocationId::from_u128(1),
            }),
            RpcTrafficClass::Control
        );
        assert_eq!(rpc_traffic_class(&WorkspaceRequest::Capabilities), RpcTrafficClass::Control);
        assert_eq!(
            rpc_traffic_class(&WorkspaceRequest::CancelRequest {
                request: RequestId::from_u128(9),
            }),
            RpcTrafficClass::Cancellation
        );
        assert_eq!(rpc_traffic_class(&WorkspaceRequest::ListProcesses), RpcTrafficClass::Bulk);
        assert_eq!(
            rpc_traffic_class(&WorkspaceRequest::SnapshotProcessTerminal {
                process: ProcessId::from_u128(2),
            }),
            RpcTrafficClass::Bulk
        );
    }

    #[tokio::test]
    async fn unknown_response_fails_pending_request() {
        let requests = Arc::new(Mutex::new(WorkspaceRequestRegistry::default()));
        let (sender, receiver) = oneshot::channel();
        let expected = RequestId::from_u128(1);
        request_registry(&requests).pending.insert(expected, sender);

        let failure = route_response(
            RpcResponse {
                id: RequestId::from_u128(2),
                result: Err(RpcError::new("server", "unexpected")),
            },
            &requests,
        )
        .expect_err("an unknown response ID must fail the channel");
        for (_, sender) in request_registry(&requests).pending.drain() {
            let _ = sender.send(Err(failure.clone()));
        }

        assert_eq!(receiver.await.unwrap().unwrap_err(), failure);
    }

    #[tokio::test]
    async fn known_response_is_delivered_to_pending_request() {
        let requests = Arc::new(Mutex::new(WorkspaceRequestRegistry::default()));
        let (sender, receiver) = oneshot::channel();
        let id = RequestId::from_u128(1);
        request_registry(&requests).pending.insert(id, sender);

        route_response(
            RpcResponse { id, result: Err(RpcError::new("server", "expected")) },
            &requests,
        )
        .expect("a pending response should be delivered");

        let response = receiver.await.unwrap().unwrap();
        assert_eq!(response.id, id);
    }

    #[test]
    fn ignored_response_is_consumed_without_failing_channel() {
        let requests = Arc::new(Mutex::new(WorkspaceRequestRegistry::default()));
        let id = RequestId::from_u128(1);
        request_registry(&requests).ignored.insert(id);

        route_response(RpcResponse { id, result: Err(RpcError::new("server", "late")) }, &requests)
            .expect("a retired response should be consumed");
        assert!(!request_registry(&requests).ignored.remove(&id));
    }

    #[test]
    fn response_racing_with_request_drop_is_delivered_or_ignored_atomically() {
        for sequence in 0..128_u128 {
            let requests = Arc::new(Mutex::new(WorkspaceRequestRegistry::default()));
            let id = RequestId::from_u128(sequence + 1);
            let (response_sender, response_receiver) = oneshot::channel();
            request_registry(&requests).pending.insert(id, response_sender);
            let (dropped_cancellations, mut cancellation_receiver) = mpsc::channel(1);
            let (origin_shutdown, _shutdown_receiver) = watch::channel(false);
            let pending_request = PendingWorkspaceRequest {
                id,
                receiver: Some(response_receiver),
                deadline: None,
                requests: requests.clone(),
                cancellable: true,
                dropped_cancellations,
                origin_shutdown,
                armed: true,
            };
            let start = Arc::new(std::sync::Barrier::new(3));

            let routed = std::thread::scope(|scope| {
                let route_start = start.clone();
                let route_requests = requests.clone();
                let route_thread = scope.spawn(move || {
                    route_start.wait();
                    route_response(
                        RpcResponse { id, result: Err(RpcError::new("server", "race")) },
                        &route_requests,
                    )
                });
                let drop_start = start.clone();
                let drop_thread = scope.spawn(move || {
                    drop_start.wait();
                    drop(pending_request);
                });
                start.wait();
                let routed = route_thread.join().expect("response thread must not panic");
                drop_thread.join().expect("drop thread must not panic");
                routed
            });

            routed.expect("a response racing with drop must not look unknown");
            assert!(request_registry(&requests).pending.is_empty());
            assert!(!request_registry(&requests).ignored.remove(&id));
            match cancellation_receiver.try_recv() {
                Ok(dropped) => assert_eq!(dropped.target, id),
                Err(mpsc::error::TryRecvError::Empty | mpsc::error::TryRecvError::Disconnected) => {
                }
            }
        }
    }
}
