//! Workspace-scoped coding primitives for remote cmux clients.
//!
//! This service owns roots, file mutations, headless processes, and TCP route
//! registrations. Transport authentication and framing stay in the parent
//! `cmux-remote` crate. VM lifecycle is intentionally absent.

mod blocking;
mod files;
mod git;
mod patch;
mod path;
mod process;
mod route;

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex as StdMutex};

use cmux_remote_protocol::{
    ComputerUseCapability, ComputerUseFeature, RemoteCapability, RequestId, RouteId, RpcError,
    RpcRequest, RpcResponse, SessionId, WorkspaceId, WorkspaceRequest, WorkspaceResponse,
};
use tokio::net::TcpStream;
use tokio::sync::{Notify, RwLock, watch};

use blocking::WorkspaceBlockingPool;
use path::WorkspaceRoot;
pub use process::ProcessSubscription;
use process::{ProcessManager, ProcessSpawnOptions};
use route::RouteManager;

const MAX_WORKSPACES: usize = 256;
const MAX_PENDING_CANCELLATIONS: usize = 4_096;
const WORKSPACE_CODEC_JOBS: usize = 2;
const REQUEST_QUIESCE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

struct WorkspaceServiceInner {
    catalog: RwLock<WorkspaceCatalog>,
    blocking: WorkspaceBlockingPool,
    codec: WorkspaceBlockingPool,
    processes: ProcessManager,
    routes: RouteManager,
    computer_capabilities: Vec<ComputerUseCapability>,
    request_control: StdMutex<RequestControlState>,
    activity_changed: Notify,
}

#[derive(Default)]
struct RequestControlState {
    active: HashMap<(ClientScope, RequestId), ActiveRequest>,
    pending_cancellations: HashSet<(ClientScope, RequestId)>,
    cancellation_order: VecDeque<(ClientScope, RequestId)>,
    closing_clients: HashSet<ClientScope>,
    shutting_down: bool,
}

struct ActiveRequest {
    cancel: Option<watch::Sender<bool>>,
}

struct ActiveRequestGuard<'a> {
    control: &'a StdMutex<RequestControlState>,
    activity_changed: &'a Notify,
    key: (ClientScope, RequestId),
}

impl Drop for ActiveRequestGuard<'_> {
    fn drop(&mut self) {
        let removed = self
            .control
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active
            .remove(&self.key);
        if removed.is_some() {
            self.activity_changed.notify_waiters();
        }
    }
}

#[derive(Default)]
struct WorkspaceCatalog {
    workspaces: HashMap<WorkspaceId, Arc<WorkspaceRoot>>,
    leases: HashMap<ClientScope, HashSet<WorkspaceId>>,
}

/// Names lifecycle leases within one fully authorized daemon. This is not an
/// authorization boundary: every scope can still address every workspace and
/// process by its explicit identifier.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct ClientScope {
    device_id: String,
    session_id: SessionId,
}

impl ClientScope {
    pub(crate) fn new(device_id: impl Into<String>, session_id: SessionId) -> Self {
        Self { device_id: device_id.into(), session_id }
    }

    fn local() -> Self {
        Self::new("local", SessionId([0; 16]))
    }
}

/// Transport-independent implementation of `workspace.rpc`.
#[derive(Clone)]
pub struct WorkspaceService {
    inner: Arc<WorkspaceServiceInner>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct WorkspaceShutdownResidual {
    pub(crate) blocking_jobs: usize,
    pub(crate) codec_jobs: usize,
}

impl Default for WorkspaceService {
    fn default() -> Self {
        Self::new()
    }
}

impl WorkspaceService {
    pub fn new() -> Self {
        Self::with_computer_capabilities(Vec::new())
    }

    pub fn with_computer_capabilities(computer_capabilities: Vec<ComputerUseCapability>) -> Self {
        Self {
            inner: Arc::new(WorkspaceServiceInner {
                catalog: RwLock::new(WorkspaceCatalog::default()),
                blocking: WorkspaceBlockingPool::default(),
                codec: WorkspaceBlockingPool::with_jobs(WORKSPACE_CODEC_JOBS),
                processes: ProcessManager::default(),
                routes: RouteManager::default(),
                computer_capabilities,
                request_control: StdMutex::new(RequestControlState::default()),
                activity_changed: Notify::new(),
            }),
        }
    }

    #[cfg(test)]
    pub(crate) fn with_blocking_hook(jobs: usize, hook: Arc<dyn Fn() + Send + Sync>) -> Self {
        Self {
            inner: Arc::new(WorkspaceServiceInner {
                catalog: RwLock::new(WorkspaceCatalog::default()),
                blocking: WorkspaceBlockingPool::with_hook(jobs, hook),
                codec: WorkspaceBlockingPool::with_jobs(WORKSPACE_CODEC_JOBS),
                processes: ProcessManager::default(),
                routes: RouteManager::default(),
                computer_capabilities: Vec::new(),
                request_control: StdMutex::new(RequestControlState::default()),
                activity_changed: Notify::new(),
            }),
        }
    }

    pub(crate) async fn run_codec<T, F>(
        &self,
        operation: &'static str,
        job: F,
    ) -> Result<T, RpcError>
    where
        T: Send + 'static,
        F: FnOnce() -> Result<T, RpcError> + Send + 'static,
    {
        self.inner.codec.run(operation, job).await
    }

    pub async fn handle_rpc(&self, request: RpcRequest) -> RpcResponse {
        self.handle_rpc_for(ClientScope::local(), request).await
    }

    pub(crate) async fn handle_rpc_for(
        &self,
        scope: ClientScope,
        request: RpcRequest,
    ) -> RpcResponse {
        let id = request.id;
        if let WorkspaceRequest::CancelRequest { request: target } = &request.request {
            let result = self.cancel_request(&scope, *target).await;
            return RpcResponse { id, result };
        }
        if request.timeout_ms.is_some() && !request_supports_cancellation(&request.request) {
            return RpcResponse {
                id,
                result: Err(RpcError::new(
                    "deadline-unsupported",
                    "this mutating request cannot be canceled safely",
                )),
            };
        }
        let supports_cancellation = request_supports_cancellation(&request.request);
        let (cancel, mut canceled) = watch::channel(false);
        let key = (scope.clone(), id);
        {
            let mut control = self
                .inner
                .request_control
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if control.shutting_down || control.closing_clients.contains(&scope) {
                return RpcResponse {
                    id,
                    result: Err(RpcError::new("session-closed", "client session is closing")),
                };
            }
            if control.pending_cancellations.remove(&key) {
                control.cancellation_order.retain(|pending| pending != &key);
                return RpcResponse {
                    id,
                    result: Err(RpcError::new("canceled", "request was canceled before execution")),
                };
            }
            if control.active.contains_key(&key) {
                return RpcResponse {
                    id,
                    result: Err(RpcError::new(
                        "duplicate-request-id",
                        format!("request id {} is already active", id.0),
                    )),
                };
            }
            control.active.insert(
                key.clone(),
                ActiveRequest { cancel: supports_cancellation.then_some(cancel) },
            );
        }
        // A request task can be aborted when its logical stream is reset. The
        // synchronous guard prevents a stale request ID or cancellation sender
        // from surviving that future's drop.
        let _active_request = ActiveRequestGuard {
            control: &self.inner.request_control,
            activity_changed: &self.inner.activity_changed,
            key,
        };
        if !supports_cancellation {
            let result = self.handle_request_for(&scope, request.request).await;
            return RpcResponse { id, result };
        }
        let timeout_ms = request.timeout_ms;
        let operation = self.handle_request_for(&scope, request.request);
        tokio::pin!(operation);
        let deadline = async move {
            match timeout_ms {
                Some(timeout_ms) => {
                    tokio::time::sleep(std::time::Duration::from_millis(timeout_ms)).await;
                }
                None => std::future::pending().await,
            }
        };
        tokio::pin!(deadline);
        let result = tokio::select! {
            result = &mut operation => result,
            _ = &mut deadline => Err(RpcError::new("deadline-exceeded", "request deadline exceeded")),
            changed = canceled.changed() => match changed {
                Ok(()) => Err(RpcError::new("canceled", "request was canceled")),
                Err(_) => Err(RpcError::new("canceled", "request cancellation state closed")),
            },
        };
        RpcResponse { id, result }
    }

    pub async fn handle_request(
        &self,
        request: WorkspaceRequest,
    ) -> Result<WorkspaceResponse, RpcError> {
        self.handle_request_for(&ClientScope::local(), request).await
    }

    async fn handle_request_for(
        &self,
        scope: &ClientScope,
        request: WorkspaceRequest,
    ) -> Result<WorkspaceResponse, RpcError> {
        match request {
            WorkspaceRequest::Capabilities => {
                let capabilities = vec![
                    RemoteCapability::WorkspaceFilesV1,
                    RemoteCapability::WorkspaceSearchV1,
                    RemoteCapability::WorkspacePatchV1,
                    RemoteCapability::WorkspaceDiffV1,
                    RemoteCapability::ProcessPipesV1,
                    RemoteCapability::TcpRoutesV1,
                    RemoteCapability::ComputerUseNegotiationV1,
                    RemoteCapability::WorkspacePaginationV1,
                    RemoteCapability::WorkspacePatchV2,
                    RemoteCapability::StructuredDiffV1,
                    RemoteCapability::ProcessLifecycleV2,
                    RemoteCapability::ProcessReplayV1,
                    RemoteCapability::RequestControlV1,
                ];
                #[cfg(unix)]
                let capabilities = {
                    let mut capabilities = capabilities;
                    capabilities.push(RemoteCapability::ProcessPtyV1);
                    capabilities
                };
                Ok(WorkspaceResponse::Capabilities { capabilities })
            }
            WorkspaceRequest::OpenWorkspace { root } => self.open_workspace(scope, &root).await,
            WorkspaceRequest::ListWorkspaces => self.list_workspaces(scope).await,
            WorkspaceRequest::Stat { workspace, path, follow_symlinks } => {
                let root = self.workspace_for(scope, &workspace).await?;
                files::stat(&root, &path, follow_symlinks).await
            }
            WorkspaceRequest::ReadFile { workspace, path, offset, limit } => {
                let root = self.workspace_for(scope, &workspace).await?;
                files::read_file(&root, &path, offset, limit).await
            }
            WorkspaceRequest::WriteFile { workspace, path, data, precondition, create_parents } => {
                let root = self.workspace_for(scope, &workspace).await?;
                files::write_file(&root, &path, &data, &precondition, create_parents).await
            }
            WorkspaceRequest::ListDirectory { workspace, path, include_hidden, limit, cursor } => {
                let root = self.workspace_for(scope, &workspace).await?;
                self.inner
                    .blocking
                    .run_async("list-directory", move || async move {
                        files::list_directory(&root, &path, include_hidden, limit, cursor.as_ref())
                            .await
                    })
                    .await
            }
            WorkspaceRequest::Search {
                workspace,
                query,
                paths,
                globs,
                include_hidden,
                max_results,
                cursor,
            } => {
                let root = self.workspace_for(scope, &workspace).await?;
                self.inner
                    .blocking
                    .run_async("search", move || async move {
                        files::search(
                            &root,
                            &query,
                            &paths,
                            &globs,
                            include_hidden,
                            max_results,
                            cursor.as_ref(),
                        )
                        .await
                    })
                    .await
            }
            WorkspaceRequest::ApplyPatch { workspace, patch: source, dry_run, preconditions } => {
                let root = self.workspace_for(scope, &workspace).await?;
                self.inner
                    .blocking
                    .run_async("apply-patch", move || async move {
                        patch::apply_patch(&root, &source, dry_run, &preconditions).await
                    })
                    .await
            }
            WorkspaceRequest::GitStatus { workspace } => {
                let root = self.workspace_for(scope, &workspace).await?;
                git::status(&root).await
            }
            WorkspaceRequest::Diff {
                workspace,
                paths,
                staged,
                context,
                format,
                cursor,
                max_bytes,
            } => {
                let root = self.workspace_for(scope, &workspace).await?;
                self.inner
                    .blocking
                    .run_async("diff", move || async move {
                        git::diff(
                            &root,
                            &paths,
                            staged,
                            context,
                            format,
                            cursor.as_ref(),
                            max_bytes,
                        )
                        .await
                    })
                    .await
            }
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
            } => {
                let root = self.workspace_for(scope, &workspace).await?;
                self.inner
                    .processes
                    .spawn(
                        root,
                        ProcessSpawnOptions {
                            owner: scope.clone(),
                            argv,
                            cwd,
                            env,
                            io,
                            lifetime,
                            operation,
                            timeout_ms,
                            retained_output_bytes,
                            environment,
                        },
                    )
                    .await
            }
            WorkspaceRequest::WriteProcess { process, write_id, data, eof } => {
                self.inner.processes.write(process, write_id, &data, eof).await
            }
            WorkspaceRequest::ResizeProcess { process, cols, rows } => {
                self.inner.processes.resize(process, cols, rows).await
            }
            WorkspaceRequest::SignalProcess { process, signal } => {
                self.inner.processes.signal(process, signal).await
            }
            WorkspaceRequest::WaitProcess { process } => self.inner.processes.wait(process).await,
            WorkspaceRequest::ReadProcessEvents { process, after_sequence, limit } => {
                self.inner.processes.read_events(process, after_sequence, limit).await
            }
            WorkspaceRequest::FinishOperation { operation } => {
                self.inner.processes.finish_operation_id(scope, operation).await
            }
            WorkspaceRequest::CloseWorkspace { workspace } => {
                self.close_workspace_response(scope, workspace).await
            }
            WorkspaceRequest::CancelRequest { request } => {
                self.cancel_request(scope, request).await
            }
            WorkspaceRequest::CreateRoute { workspace, host, port, policy } => {
                self.workspace_for(scope, &workspace).await?;
                self.inner.routes.create(scope.clone(), workspace, host, port, policy).await
            }
            WorkspaceRequest::CloseRoute { route } => self.inner.routes.close(route).await,
            WorkspaceRequest::ComputerUseCapabilities => {
                Ok(WorkspaceResponse::ComputerUseCapabilities {
                    capabilities: self
                        .inner
                        .computer_capabilities
                        .iter()
                        .map(|capability| computer_feature_name(capability.feature).to_string())
                        .collect(),
                })
            }
            WorkspaceRequest::ComputerUseCapabilitiesV1 => {
                Ok(WorkspaceResponse::ComputerUseCapabilitiesV1 {
                    capabilities: self.inner.computer_capabilities.clone(),
                })
            }
            WorkspaceRequest::InvokeComputerUse { invocation } => {
                if let Some(workspace) = &invocation.workspace {
                    self.workspace_for(scope, workspace).await?;
                }
                Err(RpcError::new(
                    "computer-use-unavailable",
                    "computer-use provider is not configured",
                ))
            }
            WorkspaceRequest::CancelComputerUse { invocation } => {
                Ok(WorkspaceResponse::ComputerUseCanceled { invocation, accepted: false })
            }
        }
    }

    /// Subscribe to retained and live process events. The remote session layer
    /// maps this receiver onto the process-stream service.
    pub async fn subscribe_process(
        &self,
        process: cmux_remote_protocol::ProcessId,
        after_sequence: u64,
    ) -> Result<ProcessSubscription, RpcError> {
        self.inner.processes.subscribe(process, after_sequence).await
    }

    /// End an operation-scoped process after its caller's operation completes.
    pub async fn finish_operation(
        &self,
        process: cmux_remote_protocol::ProcessId,
    ) -> Result<(), RpcError> {
        self.inner.processes.finish_operation(process).await
    }

    /// Resolve and connect a registered route after applying its policy to the
    /// current DNS result. Tunnel byte forwarding belongs to the session layer.
    pub async fn dial_route(&self, route: RouteId) -> Result<TcpStream, RpcError> {
        self.inner.routes.dial(route).await
    }

    /// Remove workspace-scoped resources. Detached processes intentionally
    /// survive this call.
    pub async fn close_workspace(&self, workspace: &WorkspaceId) -> Result<(), RpcError> {
        self.close_workspace_for(&ClientScope::local(), workspace).await
    }

    async fn close_workspace_for(
        &self,
        scope: &ClientScope,
        workspace: &WorkspaceId,
    ) -> Result<(), RpcError> {
        {
            let mut catalog = self.inner.catalog.write().await;
            if !catalog.workspaces.contains_key(workspace) {
                return Err(unknown_workspace(workspace));
            }
            let released =
                catalog.leases.get_mut(scope).is_some_and(|leases| leases.remove(workspace));
            if !released {
                return Err(RpcError::new(
                    "workspace-not-open",
                    format!("workspace {} is not open for this client", workspace.0),
                ));
            }
            if catalog.leases.get(scope).is_some_and(HashSet::is_empty) {
                catalog.leases.remove(scope);
            }
            let still_leased = catalog.leases.values().any(|leases| leases.contains(workspace));
            if !still_leased {
                catalog.workspaces.remove(workspace);
            }
        }
        self.inner.processes.close_workspace(scope, workspace).await;
        self.inner.routes.close_workspace(scope, workspace).await;
        Ok(())
    }

    async fn close_workspace_response(
        &self,
        scope: &ClientScope,
        workspace: WorkspaceId,
    ) -> Result<WorkspaceResponse, RpcError> {
        self.close_workspace_for(scope, &workspace).await?;
        Ok(WorkspaceResponse::WorkspaceClosed { workspace })
    }

    async fn cancel_request(
        &self,
        scope: &ClientScope,
        request: RequestId,
    ) -> Result<WorkspaceResponse, RpcError> {
        let key = (scope.clone(), request);
        let accepted = {
            let mut control = self
                .inner
                .request_control
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if control.shutting_down || control.closing_clients.contains(scope) {
                return Err(RpcError::new("session-closed", "client session is closing"));
            }
            if let Some(active) = control.active.get(&key) {
                active.cancel.as_ref().is_some_and(|cancel| cancel.send(true).is_ok())
            } else {
                // A cancellation stream can overtake its target on another
                // lane. Record a bounded tombstone so registration and cancel
                // are atomic under the same lock.
                if control.pending_cancellations.insert(key.clone()) {
                    control.cancellation_order.push_back(key);
                }
                while control.cancellation_order.len() > MAX_PENDING_CANCELLATIONS {
                    if let Some(expired) = control.cancellation_order.pop_front() {
                        control.pending_cancellations.remove(&expired);
                    }
                }
                true
            }
        };
        Ok(WorkspaceResponse::RequestCanceled { request, accepted })
    }

    async fn open_workspace(
        &self,
        scope: &ClientScope,
        root_path: &str,
    ) -> Result<WorkspaceResponse, RpcError> {
        let candidate_id = WorkspaceId(uuid::Uuid::new_v4().to_string());
        let candidate = WorkspaceRoot::open(candidate_id, root_path).await?;
        let mut catalog = self.inner.catalog.write().await;
        if let Some(existing) = catalog
            .workspaces
            .values()
            .find(|workspace| workspace.canonical_root() == candidate.canonical_root())
            .cloned()
        {
            catalog.leases.entry(scope.clone()).or_default().insert(existing.id.clone());
            return Ok(WorkspaceResponse::Workspace {
                id: existing.id.clone(),
                root: existing.display_root(),
            });
        }
        if catalog.workspaces.len() >= MAX_WORKSPACES {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("workspace limit of {MAX_WORKSPACES} reached"),
            ));
        }
        let response = WorkspaceResponse::Workspace {
            id: candidate.id.clone(),
            root: candidate.display_root(),
        };
        catalog.leases.entry(scope.clone()).or_default().insert(candidate.id.clone());
        catalog.workspaces.insert(candidate.id.clone(), candidate);
        Ok(response)
    }

    async fn list_workspaces(&self, scope: &ClientScope) -> Result<WorkspaceResponse, RpcError> {
        let mut catalog = self.inner.catalog.write().await;
        let mut workspaces = catalog
            .workspaces
            .values()
            .map(|workspace| (workspace.id.clone(), workspace.display_root()))
            .collect::<Vec<_>>();
        catalog
            .leases
            .entry(scope.clone())
            .or_default()
            .extend(workspaces.iter().map(|(workspace, _)| workspace.clone()));
        workspaces
            .sort_by(|left, right| left.1.cmp(&right.1).then_with(|| left.0.0.cmp(&right.0.0)));
        Ok(WorkspaceResponse::Workspaces { workspaces })
    }

    async fn workspace_for(
        &self,
        scope: &ClientScope,
        workspace: &WorkspaceId,
    ) -> Result<Arc<WorkspaceRoot>, RpcError> {
        let mut catalog = self.inner.catalog.write().await;
        let root = catalog
            .workspaces
            .get(workspace)
            .cloned()
            .ok_or_else(|| unknown_workspace(workspace))?;
        catalog.leases.entry(scope.clone()).or_default().insert(workspace.clone());
        Ok(root)
    }

    pub(crate) async fn close_client(&self, scope: &ClientScope) {
        let cancellations = {
            let mut control = self
                .inner
                .request_control
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            control.closing_clients.insert(scope.clone());
            let cancellations = control
                .active
                .iter()
                .filter(|((owner, _), _)| owner == scope)
                .filter_map(|(_, active)| active.cancel.clone())
                .collect::<Vec<_>>();
            control.pending_cancellations.retain(|(owner, _)| owner != scope);
            control.cancellation_order.retain(|(owner, _)| owner != scope);
            cancellations
        };
        for cancel in cancellations {
            let _ = cancel.send(true);
        }
        self.inner.processes.close_client(scope).await;
        self.inner.routes.close_client(scope).await;
        self.wait_for_requests(Some(scope)).await;
        // A mutation that was already active when closure began can publish a
        // process, route, or lease after the first cleanup snapshot.
        self.inner.processes.close_client(scope).await;
        self.inner.routes.close_client(scope).await;
        let mut catalog = self.inner.catalog.write().await;
        // Workspace roots belong to the daemon, like tmux sessions. A client
        // disconnect releases only that client's lease; another authorized
        // client can discover and attach to the same root later.
        catalog.leases.remove(scope);
    }

    /// Remove the request-admission tombstone after the connection owner has
    /// joined every handler that could still issue an RPC for this scope.
    pub(crate) fn finish_client_close(&self, scope: &ClientScope) {
        let mut control =
            self.inner.request_control.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        debug_assert!(!control.active.keys().any(|(owner, _)| owner == scope));
        control.closing_clients.remove(scope);
    }

    pub(crate) async fn shutdown(&self) -> WorkspaceShutdownResidual {
        let cancellations = {
            let mut control = self
                .inner
                .request_control
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            control.shutting_down = true;
            let cancellations = control
                .active
                .values()
                .filter_map(|active| active.cancel.clone())
                .collect::<Vec<_>>();
            control.pending_cancellations.clear();
            control.cancellation_order.clear();
            cancellations
        };
        for cancel in cancellations {
            let _ = cancel.send(true);
        }
        self.inner.processes.shutdown().await;
        self.inner.routes.shutdown().await;
        self.wait_for_requests(None).await;
        let blocking_jobs = self.inner.blocking.close_and_drain(REQUEST_QUIESCE_TIMEOUT).await;
        let codec_jobs = self.inner.codec.close_and_drain(REQUEST_QUIESCE_TIMEOUT).await;
        // Catch resources published by mutations that were active at the
        // initial shutdown snapshot.
        self.inner.processes.shutdown().await;
        self.inner.routes.shutdown().await;
        let mut catalog = self.inner.catalog.write().await;
        catalog.leases.clear();
        catalog.workspaces.clear();
        WorkspaceShutdownResidual { blocking_jobs, codec_jobs }
    }

    async fn wait_for_requests(&self, scope: Option<&ClientScope>) {
        let deadline = tokio::time::Instant::now() + REQUEST_QUIESCE_TIMEOUT;
        loop {
            let notified = self.inner.activity_changed.notified();
            let active = {
                let control = self
                    .inner
                    .request_control
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                control.active.keys().any(|(owner, _)| scope.is_none_or(|scope| owner == scope))
            };
            if !active {
                return;
            }
            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                return;
            }
        }
    }
}

fn unknown_workspace(workspace: &WorkspaceId) -> RpcError {
    RpcError::new("unknown-workspace", format!("unknown workspace {}", workspace.0))
}

pub(crate) fn request_supports_cancellation(request: &WorkspaceRequest) -> bool {
    matches!(
        request,
        WorkspaceRequest::Capabilities
            | WorkspaceRequest::ListWorkspaces
            | WorkspaceRequest::Stat { .. }
            | WorkspaceRequest::ReadFile { .. }
            | WorkspaceRequest::ListDirectory { .. }
            | WorkspaceRequest::Search { .. }
            | WorkspaceRequest::GitStatus { .. }
            | WorkspaceRequest::Diff { .. }
            | WorkspaceRequest::WaitProcess { .. }
            | WorkspaceRequest::ReadProcessEvents { .. }
            | WorkspaceRequest::ComputerUseCapabilities
            | WorkspaceRequest::ComputerUseCapabilitiesV1
    )
}

fn computer_feature_name(feature: ComputerUseFeature) -> &'static str {
    match feature {
        ComputerUseFeature::Screenshot => "screenshot",
        ComputerUseFeature::AccessibilityTree => "accessibility-tree",
        ComputerUseFeature::Pointer => "pointer",
        ComputerUseFeature::Keyboard => "keyboard",
        ComputerUseFeature::TextInput => "text-input",
        ComputerUseFeature::Scroll => "scroll",
    }
}

#[cfg(test)]
mod tests {
    use cmux_remote_protocol::{
        ByteString, FilePrecondition, ProcessEnvironment, ProcessIo, ProcessLifetime,
        ProcessSignal, RequestId,
    };
    use tempfile::tempdir;

    use super::*;

    #[tokio::test]
    async fn service_runs_file_round_trip_through_protocol_types() {
        let directory = tempdir().unwrap();
        let service = WorkspaceService::new();
        let response = service
            .handle_rpc(RpcRequest {
                id: RequestId(1),
                timeout_ms: None,
                request: WorkspaceRequest::OpenWorkspace {
                    root: directory.path().to_string_lossy().into_owned(),
                },
            })
            .await;
        let WorkspaceResponse::Workspace { id: workspace, .. } = response.result.unwrap() else {
            panic!()
        };

        service
            .handle_request(WorkspaceRequest::WriteFile {
                workspace: workspace.clone(),
                path: "src/lib.rs".into(),
                data: ByteString::from_bytes(b"pub fn answer() -> u8 { 42 }\n"),
                precondition: FilePrecondition::Missing,
                create_parents: true,
            })
            .await
            .unwrap();
        let response = service
            .handle_request(WorkspaceRequest::ReadFile {
                workspace,
                path: "src/lib.rs".into(),
                offset: 0,
                limit: 1024,
            })
            .await
            .unwrap();
        let WorkspaceResponse::File { data, eof, .. } = response else { panic!() };
        assert!(eof);
        assert_eq!(data.decode().unwrap(), b"pub fn answer() -> u8 { 42 }\n");
    }

    #[tokio::test]
    async fn duplicate_open_reuses_workspace_identity() {
        let directory = tempdir().unwrap();
        let service = WorkspaceService::new();
        let root = directory.path().to_string_lossy().into_owned();
        let first = service
            .handle_request(WorkspaceRequest::OpenWorkspace { root: root.clone() })
            .await
            .unwrap();
        let second =
            service.handle_request(WorkspaceRequest::OpenWorkspace { root }).await.unwrap();
        assert_eq!(first, second);
    }

    #[tokio::test]
    async fn workspace_close_releases_only_the_calling_client_lease() {
        let directory = tempdir().unwrap();
        let service = WorkspaceService::new();
        let first_scope = ClientScope::new("device-a", SessionId([1; 16]));
        let second_scope = ClientScope::new("device-b", SessionId([2; 16]));
        let root = directory.path().to_string_lossy().into_owned();
        let first = service
            .handle_request_for(
                &first_scope,
                WorkspaceRequest::OpenWorkspace { root: root.clone() },
            )
            .await
            .unwrap();
        let second = service
            .handle_request_for(&second_scope, WorkspaceRequest::OpenWorkspace { root })
            .await
            .unwrap();
        let WorkspaceResponse::Workspace { id: workspace, .. } = first else { panic!() };
        let WorkspaceResponse::Workspace { id: second_workspace, .. } = second else { panic!() };
        assert_eq!(workspace, second_workspace);

        service
            .handle_request_for(
                &first_scope,
                WorkspaceRequest::CloseWorkspace { workspace: workspace.clone() },
            )
            .await
            .unwrap();
        service
            .handle_request_for(
                &second_scope,
                WorkspaceRequest::Stat {
                    workspace: workspace.clone(),
                    path: ".".into(),
                    follow_symlinks: false,
                },
            )
            .await
            .unwrap();

        service
            .handle_request_for(
                &second_scope,
                WorkspaceRequest::CloseWorkspace { workspace: workspace.clone() },
            )
            .await
            .unwrap();
        let error = service
            .handle_request_for(
                &second_scope,
                WorkspaceRequest::Stat { workspace, path: ".".into(), follow_symlinks: false },
            )
            .await
            .unwrap_err();
        assert_eq!(error.code, "unknown-workspace");
    }

    #[tokio::test]
    async fn client_disconnect_preserves_daemon_workspace_for_later_clients() {
        let directory = tempdir().unwrap();
        let service = WorkspaceService::new();
        let first_scope = ClientScope::new("device-a", SessionId([1; 16]));
        let second_scope = ClientScope::new("device-b", SessionId([2; 16]));
        let root = directory.path().to_string_lossy().into_owned();
        let canonical_root =
            std::fs::canonicalize(directory.path()).unwrap().to_string_lossy().into_owned();
        let opened = service
            .handle_request_for(
                &first_scope,
                WorkspaceRequest::OpenWorkspace { root: root.clone() },
            )
            .await
            .unwrap();
        let WorkspaceResponse::Workspace { id: workspace, .. } = opened else { panic!() };

        service.close_client(&first_scope).await;
        service.finish_client_close(&first_scope);

        let listed = service
            .handle_request_for(&second_scope, WorkspaceRequest::ListWorkspaces)
            .await
            .unwrap();
        let WorkspaceResponse::Workspaces { workspaces } = listed else { panic!() };
        assert_eq!(workspaces, vec![(workspace.clone(), canonical_root)]);
        service
            .handle_request_for(
                &second_scope,
                WorkspaceRequest::Stat {
                    workspace: workspace.clone(),
                    path: ".".into(),
                    follow_symlinks: false,
                },
            )
            .await
            .unwrap();
        service
            .handle_request_for(&second_scope, WorkspaceRequest::CloseWorkspace { workspace })
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn capabilities_match_implemented_service_families() {
        let service = WorkspaceService::new();
        let response = service.handle_request(WorkspaceRequest::Capabilities).await.unwrap();
        let WorkspaceResponse::Capabilities { capabilities } = response else { panic!() };
        assert!(capabilities.contains(&RemoteCapability::WorkspaceFilesV1));
        assert!(capabilities.contains(&RemoteCapability::ProcessPipesV1));
        #[cfg(unix)]
        assert!(capabilities.contains(&RemoteCapability::ProcessPtyV1));
        #[cfg(not(unix))]
        assert!(!capabilities.contains(&RemoteCapability::ProcessPtyV1));
        assert!(capabilities.contains(&RemoteCapability::TcpRoutesV1));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn wait_request_supports_deadlines_and_explicit_cancellation() {
        let directory = tempdir().unwrap();
        let service = WorkspaceService::new();
        let opened = service
            .handle_request(WorkspaceRequest::OpenWorkspace {
                root: directory.path().to_string_lossy().into_owned(),
            })
            .await
            .unwrap();
        let WorkspaceResponse::Workspace { id: workspace, .. } = opened else { panic!() };
        let started = service
            .handle_request(WorkspaceRequest::SpawnProcess {
                workspace,
                argv: vec!["/bin/sleep".into(), "30".into()],
                cwd: None,
                env: Default::default(),
                io: ProcessIo::Pipes { stdin: false },
                lifetime: ProcessLifetime::Workspace,
                operation: None,
                timeout_ms: None,
                retained_output_bytes: None,
                environment: ProcessEnvironment::Inherit,
            })
            .await
            .unwrap();
        let WorkspaceResponse::ProcessStarted { process, .. } = started else { panic!() };

        let deadline = service
            .handle_rpc(RpcRequest {
                id: RequestId(40),
                timeout_ms: Some(10),
                request: WorkspaceRequest::WaitProcess { process },
            })
            .await;
        assert_eq!(deadline.result.unwrap_err().code, "deadline-exceeded");

        let waiting_service = service.clone();
        let waiting = tokio::spawn(async move {
            waiting_service
                .handle_rpc(RpcRequest {
                    id: RequestId(41),
                    timeout_ms: None,
                    request: WorkspaceRequest::WaitProcess { process },
                })
                .await
        });
        while !service
            .inner
            .request_control
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .active
            .contains_key(&(ClientScope::local(), RequestId(41)))
        {
            tokio::task::yield_now().await;
        }
        let canceled = service
            .handle_rpc(RpcRequest {
                id: RequestId(42),
                timeout_ms: None,
                request: WorkspaceRequest::CancelRequest { request: RequestId(41) },
            })
            .await;
        assert_eq!(
            canceled.result.unwrap(),
            WorkspaceResponse::RequestCanceled { request: RequestId(41), accepted: true }
        );
        assert_eq!(waiting.await.unwrap().result.unwrap_err().code, "canceled");

        service
            .handle_request(WorkspaceRequest::SignalProcess {
                process,
                signal: ProcessSignal::Kill,
            })
            .await
            .unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn request_ids_and_cancellation_are_scoped_per_client_session() {
        let directory = tempdir().unwrap();
        let service = WorkspaceService::new();
        let opened = service
            .handle_request(WorkspaceRequest::OpenWorkspace {
                root: directory.path().to_string_lossy().into_owned(),
            })
            .await
            .unwrap();
        let WorkspaceResponse::Workspace { id: workspace, .. } = opened else { panic!() };
        let started = service
            .handle_request(WorkspaceRequest::SpawnProcess {
                workspace,
                argv: vec!["/bin/sleep".into(), "30".into()],
                cwd: None,
                env: Default::default(),
                io: ProcessIo::Pipes { stdin: false },
                lifetime: ProcessLifetime::Detached,
                operation: None,
                timeout_ms: None,
                retained_output_bytes: None,
                environment: ProcessEnvironment::Inherit,
            })
            .await
            .unwrap();
        let WorkspaceResponse::ProcessStarted { process, .. } = started else { panic!() };
        let first_scope = ClientScope::new("device-a", SessionId([1; 16]));
        let second_scope = ClientScope::new("device-b", SessionId([2; 16]));
        let request_id = RequestId(77);

        let first = tokio::spawn({
            let service = service.clone();
            let scope = first_scope.clone();
            async move {
                service
                    .handle_rpc_for(
                        scope,
                        RpcRequest {
                            id: request_id,
                            timeout_ms: None,
                            request: WorkspaceRequest::WaitProcess { process },
                        },
                    )
                    .await
            }
        });
        let second = tokio::spawn({
            let service = service.clone();
            let scope = second_scope.clone();
            async move {
                service
                    .handle_rpc_for(
                        scope,
                        RpcRequest {
                            id: request_id,
                            timeout_ms: None,
                            request: WorkspaceRequest::WaitProcess { process },
                        },
                    )
                    .await
            }
        });
        loop {
            let both_registered = {
                let active = service
                    .inner
                    .request_control
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                active.active.contains_key(&(first_scope.clone(), request_id))
                    && active.active.contains_key(&(second_scope.clone(), request_id))
            };
            if both_registered {
                break;
            }
            tokio::task::yield_now().await;
        }

        let canceled = service
            .handle_rpc_for(
                first_scope,
                RpcRequest {
                    id: RequestId(78),
                    timeout_ms: None,
                    request: WorkspaceRequest::CancelRequest { request: request_id },
                },
            )
            .await;
        assert_eq!(
            canceled.result.unwrap(),
            WorkspaceResponse::RequestCanceled { request: request_id, accepted: true }
        );
        assert_eq!(first.await.unwrap().result.unwrap_err().code, "canceled");
        assert!(!second.is_finished(), "canceling one client canceled another client's request");

        service
            .handle_request(WorkspaceRequest::SignalProcess {
                process,
                signal: ProcessSignal::Kill,
            })
            .await
            .unwrap();
        assert!(second.await.unwrap().result.is_ok());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn aborting_a_request_future_releases_its_request_id() {
        let directory = tempdir().unwrap();
        let service = WorkspaceService::new();
        let opened = service
            .handle_request(WorkspaceRequest::OpenWorkspace {
                root: directory.path().to_string_lossy().into_owned(),
            })
            .await
            .unwrap();
        let WorkspaceResponse::Workspace { id: workspace, .. } = opened else { panic!() };
        let started = service
            .handle_request(WorkspaceRequest::SpawnProcess {
                workspace,
                argv: vec!["/bin/sleep".into(), "30".into()],
                cwd: None,
                env: Default::default(),
                io: ProcessIo::Pipes { stdin: false },
                lifetime: ProcessLifetime::Detached,
                operation: None,
                timeout_ms: None,
                retained_output_bytes: None,
                environment: ProcessEnvironment::Inherit,
            })
            .await
            .unwrap();
        let WorkspaceResponse::ProcessStarted { process, .. } = started else { panic!() };
        let scope = ClientScope::new("aborted-device", SessionId([3; 16]));
        let request_id = RequestId(91);
        let waiting = tokio::spawn({
            let service = service.clone();
            let scope = scope.clone();
            async move {
                service
                    .handle_rpc_for(
                        scope,
                        RpcRequest {
                            id: request_id,
                            timeout_ms: None,
                            request: WorkspaceRequest::WaitProcess { process },
                        },
                    )
                    .await
            }
        });
        loop {
            let registered = {
                let active = service
                    .inner
                    .request_control
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                active.active.contains_key(&(scope.clone(), request_id))
            };
            if registered {
                break;
            }
            tokio::task::yield_now().await;
        }

        waiting.abort();
        assert!(waiting.await.unwrap_err().is_cancelled());
        assert!(
            !service
                .inner
                .request_control
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .active
                .contains_key(&(scope.clone(), request_id))
        );
        let reused = service
            .handle_rpc_for(
                scope,
                RpcRequest {
                    id: request_id,
                    timeout_ms: None,
                    request: WorkspaceRequest::Capabilities,
                },
            )
            .await;
        assert!(reused.result.is_ok());

        service
            .handle_request(WorkspaceRequest::SignalProcess {
                process,
                signal: ProcessSignal::Kill,
            })
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn cancellation_that_overtakes_its_request_prevents_execution() {
        let service = WorkspaceService::new();
        let scope = ClientScope::new("racing-device", SessionId([4; 16]));
        let target = RequestId(120);
        let canceled = service
            .handle_rpc_for(
                scope.clone(),
                RpcRequest {
                    id: RequestId(121),
                    timeout_ms: None,
                    request: WorkspaceRequest::CancelRequest { request: target },
                },
            )
            .await;
        assert_eq!(
            canceled.result.unwrap(),
            WorkspaceResponse::RequestCanceled { request: target, accepted: true }
        );

        let overtaken = service
            .handle_rpc_for(
                scope,
                RpcRequest {
                    id: target,
                    timeout_ms: None,
                    request: WorkspaceRequest::Capabilities,
                },
            )
            .await;
        assert_eq!(overtaken.result.unwrap_err().code, "canceled");
    }

    #[tokio::test]
    async fn closed_client_scope_rejects_late_requests() {
        let service = WorkspaceService::new();
        let scope = ClientScope::new("closed-device", SessionId([5; 16]));
        service.close_client(&scope).await;

        let response = service
            .handle_rpc_for(
                scope,
                RpcRequest {
                    id: RequestId(130),
                    timeout_ms: None,
                    request: WorkspaceRequest::Capabilities,
                },
            )
            .await;
        assert_eq!(response.result.unwrap_err().code, "session-closed");
    }

    #[tokio::test]
    async fn finished_client_close_releases_its_admission_tombstone() {
        let service = WorkspaceService::new();
        let scope = ClientScope::new("reusable-device", SessionId([6; 16]));
        service.close_client(&scope).await;
        service.finish_client_close(&scope);

        let response = service
            .handle_rpc_for(
                scope,
                RpcRequest {
                    id: RequestId(131),
                    timeout_ms: None,
                    request: WorkspaceRequest::Capabilities,
                },
            )
            .await;
        assert!(response.result.is_ok());
    }
}
