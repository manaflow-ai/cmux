//! The daemon-owned embedded Tailscale node.
//!
//! This controller owns the node lifecycle and its event-driven state.  The
//! ingress server is deliberately separate: it receives the same `Arc<Node>`
//! and the daemon's `Arc<Hub>`, so ticket minting and redemption remain in one
//! acpmux pairing store.

#[cfg(unix)]
use std::ffi::CString;
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
#[cfg(unix)]
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use cmux_tailnet::{BackendState, Node, NodeConfig, Notify};
use serde_json::{Value, json};
use tokio::sync::{Notify as TokioNotify, broadcast};

/// A snapshot reported by the embedded node's IPN bus.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Snapshot {
    pub state: &'static str,
    pub browse_to_url: Option<String>,
    pub dns_name: Option<String>,
    pub ips: Vec<String>,
    pub error: Option<String>,
}

impl Snapshot {
    /// The sign-in URL is only included for an explicitly person-authorized
    /// local request. Ingress and all remote callers use `to_json(false)`.
    pub fn to_json(&self, include_sign_in_url: bool) -> Value {
        let mut value = json!({"state": self.state});
        if include_sign_in_url
            && self.state == "needs_login"
            && let Some(url) = &self.browse_to_url
        {
            value["browse_to_url"] = json!(url);
        }
        if let Some(name) = &self.dns_name {
            value["dns_name"] = json!(name);
        }
        if !self.ips.is_empty() {
            value["ips"] = json!(self.ips);
        }
        if let Some(error) = &self.error {
            value["error"] = json!(error);
        }
        value
    }

    /// The node is gone: nothing it reported (sign-in URL, name, addresses)
    /// stays in the snapshot. Any error it reported stays.
    fn node_gone(&mut self, state: &'static str) {
        self.state = state;
        self.browse_to_url = None;
        self.dns_name = None;
        self.ips.clear();
    }

    pub fn running(&self) -> bool {
        self.state == "running"
    }

    fn apply_notify(&mut self, notify: &Notify, node: Option<&Node>) {
        let needs_live_identity =
            self.running() || notify.backend_state() == Some(BackendState::Running);
        let live_identity = if needs_live_identity {
            node.and_then(|node| {
                let status = node.status().ok()?;
                let dns_name = status.dns_name();
                let ips =
                    if dns_name.is_some() { node.ips().unwrap_or_default() } else { Vec::new() };
                Some(LiveIdentity { state: status.state(), dns_name, ips })
            })
        } else {
            None
        };
        self.apply_notify_with_status(notify, live_identity);
    }

    fn apply_notify_with_status(&mut self, notify: &Notify, live_identity: Option<LiveIdentity>) {
        if let Some(url) = notify.browse_to_url.as_deref().filter(|url| !url.is_empty()) {
            self.browse_to_url = Some(url.to_owned());
        }
        if let Some(error) = notify.err_message.as_deref().filter(|error| !error.is_empty()) {
            self.error = Some(error.to_owned());
        }
        if let Some(state) = notify.backend_state() {
            self.state = state_name(state);
            if state != BackendState::NeedsLogin {
                self.browse_to_url = None;
            }
            if state != BackendState::Running {
                self.dns_name = None;
                self.ips.clear();
            }
        }
        // NetMap/name changes are delivered as IPN notifications without a
        // BackendState. Refresh while already running so ingress follows a
        // renamed node instead of retaining an unusable old certificate name.
        if self.running()
            && let Some(LiveIdentity { state, dns_name, ips }) = live_identity
        {
            self.apply_live_identity(state, dns_name, ips);
        }
    }

    fn apply_live_identity(
        &mut self,
        state: BackendState,
        dns_name: Option<String>,
        ips: Vec<String>,
    ) {
        if state != BackendState::Running {
            self.state = state_name(state);
            self.dns_name = None;
            self.ips.clear();
            return;
        }
        self.dns_name = dns_name;
        self.ips = if self.dns_name.is_some() { ips } else { Vec::new() };
        if self.dns_name.is_some() {
            self.error = None;
        }
    }
}

#[derive(Debug)]
struct LiveIdentity {
    state: BackendState,
    dns_name: Option<String>,
    ips: Vec<String>,
}

#[derive(Clone, Copy)]
struct ClosePlan {
    logout: bool,
}

fn state_name(state: BackendState) -> &'static str {
    match state {
        BackendState::NoState => "no_state",
        BackendState::InUseOtherUser => "in_use_other_user",
        BackendState::NeedsLogin => "needs_login",
        BackendState::NeedsMachineAuth => "needs_machine_auth",
        BackendState::Stopped => "stopped",
        BackendState::Starting => "starting",
        BackendState::Running => "running",
        BackendState::Unknown => "unknown",
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum RetirementPhase {
    Waiting,
    Closing,
    ClosingForLogout,
}

enum LifecycleState {
    Stopped,
    Starting,
    Running(Arc<Node>),
    Retiring { node: Option<Arc<Node>>, phase: RetirementPhase },
    LoggingOut { node: Option<Arc<Node>>, remote_result: Option<Result<(), String>> },
}

#[cfg(test)]
type NodeFactory = Box<dyn FnOnce() -> Result<Arc<Node>, String> + Send>;

struct Inner {
    snapshot: Snapshot,
    /// The one lifecycle state machine. Every transition is made while the
    /// short `inner` mutex is held; blocking node work happens after the
    /// transition and is reconciled with `generation`.
    state: LifecycleState,
    generation: u64,
    /// Set by daemon shutdown and never cleared: no node starts after it.
    closed: bool,
}

/// Owns one embedded node per daemon install. The controller is cheap to
/// clone; all state and node handles remain shared and serialized.
pub struct Controller {
    state_dir: PathBuf,
    hostname: String,
    inner: Mutex<Inner>,
    changes: broadcast::Sender<Snapshot>,
    /// Serializes starts, sign-outs and shutdown with failed-node retirement.
    /// A cleanup task holds this gate until its node is closed, so a queued
    /// start cannot create a second node for the same state directory.
    retirement_gate: Arc<tokio::sync::Mutex<()>>,
    lifecycle: Arc<tokio::sync::Mutex<()>>,
    /// Set synchronously when a listener fails, before cleanup waits on either
    /// lifecycle lock. The service uses this fence to avoid starting a new
    /// listener while the failed node is still being retired.
    pending_retirement: Arc<AtomicBool>,
    retirement_finished: Arc<TokioNotify>,
    stopping: Arc<AtomicBool>,
    /// Held on the blocking thread by a failure cleanup from its final
    /// shutdown check through its close, and taken by the shutdown fence after
    /// it sets `stopping`. A close job that the blocking pool runs late sees
    /// the fence and skips; only a close that really began before shutdown can
    /// outlast the fence's bound.
    close_admission: Arc<Mutex<()>>,
    #[cfg(test)]
    node_factory: Mutex<Option<NodeFactory>>,
    #[cfg(test)]
    before_close: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    #[cfg(test)]
    remote_logout: Mutex<Option<RemoteLogout>>,
    #[cfg(test)]
    before_admission: Mutex<Option<Box<dyn FnOnce() + Send>>>,
}

#[cfg(test)]
type RemoteLogout = Box<dyn FnOnce() -> Result<(), String> + Send>;

impl Controller {
    pub fn new(state_dir: impl Into<PathBuf>, hostname: impl Into<String>) -> Arc<Self> {
        let (changes, _) = broadcast::channel(32);
        Arc::new(Self {
            state_dir: state_dir.into(),
            hostname: hostname.into(),
            inner: Mutex::new(Inner {
                snapshot: Snapshot { state: "not_started", ..Snapshot::default() },
                state: LifecycleState::Stopped,
                generation: 0,
                closed: false,
            }),
            changes,
            retirement_gate: Arc::new(tokio::sync::Mutex::new(())),
            lifecycle: Arc::new(tokio::sync::Mutex::new(())),
            pending_retirement: Arc::new(AtomicBool::new(false)),
            retirement_finished: Arc::new(TokioNotify::new()),
            stopping: Arc::new(AtomicBool::new(false)),
            close_admission: Arc::new(Mutex::new(())),
            #[cfg(test)]
            node_factory: Mutex::new(None),
            #[cfg(test)]
            before_close: Mutex::new(None),
            #[cfg(test)]
            remote_logout: Mutex::new(None),
            #[cfg(test)]
            before_admission: Mutex::new(None),
        })
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Snapshot> {
        self.changes.subscribe()
    }

    pub fn snapshot(&self) -> Snapshot {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner).snapshot.clone()
    }

    /// The live node for the ingress server. It remains valid through a
    /// restart; callers should subscribe and discard it when state stops.
    pub fn node(&self) -> Option<Arc<Node>> {
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        match &inner.state {
            LifecycleState::Running(node) => Some(Arc::clone(node)),
            _ => None,
        }
    }

    fn state_node(&self) -> Option<Arc<Node>> {
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        match &inner.state {
            LifecycleState::Running(node)
            | LifecycleState::Retiring { node: Some(node), .. }
            | LifecycleState::LoggingOut { node: Some(node), .. } => Some(Arc::clone(node)),
            _ => None,
        }
    }

    /// Resume only a saved explicit opt-in; an untouched installation creates nothing.
    pub async fn resume(self: &Arc<Self>) -> Result<(), String> {
        let this = Arc::clone(self);
        detached(async move { this.resume_detached().await }).await
    }

    async fn resume_detached(self: Arc<Self>) -> Result<(), String> {
        loop {
            let retirement = self.await_retirement_gate().await;
            let lifecycle = self.lifecycle.lock().await;
            if self.shutting_down() {
                return Ok(());
            }
            let waiting_for_logout = {
                let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
                matches!(
                    &inner.state,
                    LifecycleState::Retiring { .. } | LifecycleState::LoggingOut { .. }
                )
            };
            if waiting_for_logout {
                let waiting = self.retirement_finished.notified();
                tokio::pin!(waiting);
                waiting.as_mut().enable();
                drop(lifecycle);
                drop(retirement);
                waiting.await;
                continue;
            }
            if self.pending_retirement.load(Ordering::Acquire) {
                drop(lifecycle);
                drop(retirement);
                continue;
            }
            let path = self.state_dir.join("enabled");
            let generation = self.inner.lock().unwrap_or_else(PoisonError::into_inner).generation;
            let enabled = tokio::task::spawn_blocking(move || saved_opt_in(&path))
                .await
                .map_err(|e| e.to_string())
                .and_then(|result| result)
                .inspect_err(|error| {
                    self.note_resume_error_if_current(generation, error);
                })?;
            if enabled {
                self.start_locked().await?;
            }
            return Ok(());
        }
    }

    fn note_resume_error_if_current(&self, generation: u64, error: &str) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if inner.generation != generation
            || inner.closed
            || self.stopping.load(Ordering::Acquire)
            || !matches!(&inner.state, LifecycleState::Stopped)
        {
            return;
        }
        inner.snapshot.node_gone("error");
        inner.snapshot.error = Some(error.to_owned());
        self.publish_locked(&inner.snapshot);
    }

    fn note_listener_error_if_current(&self, generation: u64) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if self.stopping.load(Ordering::Acquire) || inner.generation != generation {
            return;
        }
        inner.snapshot.state = "error";
        inner.snapshot.error =
            Some("The tailnet listener stopped. Start it again to retry.".into());
        self.publish_locked(&inner.snapshot);
    }

    /// The node's remote sign-out, run on a blocking thread by its caller.
    /// Every path that signs out clears the opt-in marker first, so a daemon
    /// restart during an unfinished sign-out never resumes this identity. If
    /// the marker cannot be cleared, no remote sign-out is attempted.
    fn remote_logout(
        &self,
        node: Arc<Node>,
    ) -> impl FnOnce() -> Result<(), String> + Send + 'static {
        let state_dir = self.state_dir.clone();
        #[cfg(test)]
        let hook = self.remote_logout.lock().unwrap_or_else(PoisonError::into_inner).take();
        move || {
            clear_opt_in(&state_dir)?;
            #[cfg(test)]
            if let Some(hook) = hook {
                return hook();
            }
            node.logout().map_err(|e| e.0)
        }
    }

    /// The daemon's shutdown fence: from here no start, resume or failure
    /// cleanup acts, and a failure cleanup's close already under way finishes
    /// (within a bound) before this returns. Daemon shutdown closes the node
    /// later, after the WebSocket drain.
    pub(crate) async fn fence(&self) {
        self.begin_shutdown();
        let admission = Arc::clone(&self.close_admission);
        let waited = tokio::task::spawn_blocking(move || {
            drop(admission.lock().unwrap_or_else(PoisonError::into_inner));
        });
        if tokio::time::timeout(FENCE_CLOSE_BOUND, waited).await.is_err() {
            // Only a close that began before shutdown can hold admission this
            // long; every later one sees `stopping` and leaves the node alone.
            tracing::warn!("a tailnet listener-failure close began before shutdown and is slow");
        }
    }

    fn shutting_down(&self) -> bool {
        self.stopping.load(Ordering::Acquire)
            || self.inner.lock().unwrap_or_else(PoisonError::into_inner).closed
    }

    pub(crate) fn begin_shutdown(&self) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        self.stopping.store(true, Ordering::Release);
        inner.generation = inner.generation.wrapping_add(1);
        inner.snapshot.node_gone("stopped");
        self.publish_locked(&inner.snapshot);
    }

    pub(crate) async fn listener_failed(self: &Arc<Self>, failed: &Arc<Node>) {
        // Retire synchronously before waiting on either async lock. Login and
        // logout hold the lifecycle lock during blocking LocalAPI calls; the
        // supervisor may cancel this future after its drain bound, but the
        // state swap and detached cleanup must still happen.
        let Some((Some(node), generation)) =
            self.begin_listener_retirement(Some(failed), "stopped")
        else {
            self.pending_retirement.store(false, Ordering::Release);
            self.retirement_finished.notify_waiters();
            release_node(Arc::clone(failed));
            return;
        };
        // The cleanup task owns the failed node and the gate. Dropping its
        // join handle (for example when the supervisor's close timeout
        // expires) never cancels the cleanup or opens the gate early.
        let failed = Arc::clone(failed);
        let controller = Arc::clone(self);
        let cleanup_node = Arc::clone(&node);
        let cleanup = spawn_after_retirement(
            Arc::clone(&self.retirement_gate),
            Arc::clone(&self.lifecycle),
            move || async move {
                let plan = controller.begin_retirement_close(generation, &node);
                let remote_logout = controller.remote_logout(Arc::clone(&cleanup_node));
                let admission = Arc::clone(&controller.close_admission);
                let stopping = Arc::clone(&controller.stopping);
                #[cfg(test)]
                let before_admission = controller
                    .before_admission
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .take();
                #[cfg(test)]
                let before_close =
                    controller.before_close.lock().unwrap_or_else(PoisonError::into_inner).take();
                let result = tokio::task::spawn_blocking(move || {
                    #[cfg(test)]
                    if let Some(before_admission) = before_admission {
                        before_admission();
                    }
                    let _admitted = admission.lock().unwrap_or_else(PoisonError::into_inner);
                    // Checked here, on the thread that closes, under the lock
                    // the fence takes after setting `stopping`: however late
                    // the pool runs this job, it never closes after the fence.
                    if !plan.logout && stopping.load(Ordering::Acquire) {
                        return None;
                    }
                    #[cfg(test)]
                    if let Some(before_close) = before_close {
                        before_close();
                    }
                    Some(if plan.logout {
                        logout_and_close(remote_logout, || cleanup_node.close().map_err(|e| e.0))
                    } else {
                        cleanup_node.close().map_err(|e| e.0)
                    })
                })
                .await;
                let result = match result {
                    Ok(None) => {
                        // Queued before the shutdown fence, running after it.
                        // The node stays owned (Retiring) and daemon shutdown
                        // closes it after the WebSocket drain.
                        controller.pending_retirement.store(false, Ordering::Release);
                        controller.retirement_finished.notify_waiters();
                        release_node(node);
                        release_node(failed);
                        return;
                    }
                    Ok(Some(result)) => Ok(result),
                    Err(error) => Err(error.to_string()),
                };
                let logout_pending = controller.finish_retirement(generation, &node, plan, result);
                controller.note_listener_error_if_current(generation);
                if !logout_pending {
                    controller.pending_retirement.store(false, Ordering::Release);
                    controller.retirement_finished.notify_waiters();
                }
                // `node` is an Arc clone taken for the async state machine;
                // the blocking client must never be its final drop on a Tokio
                // worker. The state-owned and failed-listener handles are
                // transferred the same way below.
                release_node(node);
                release_node(failed);
            },
        );
        // Dropping this join handle (for example when the supervisor's close
        // timeout expires) does not cancel the detached cleanup task. It owns
        // the retired node until close completes.
        let _ = cleanup.await;
    }

    /// Request an explicit browser sign-in URL for a running unsigned node.
    pub async fn login(self: &Arc<Self>) -> Result<Snapshot, String> {
        let this = Arc::clone(self);
        detached(async move { this.login_detached().await }).await
    }

    /// Sign out and close all ingress listeners that hold this node.
    pub async fn logout(self: &Arc<Self>) -> Result<Snapshot, String> {
        let this = Arc::clone(self);
        detached(async move { this.logout_detached().await }).await
    }

    /// Close without deleting the saved login, used by daemon shutdown.
    pub async fn shutdown(self: &Arc<Self>) -> Result<(), String> {
        let this = Arc::clone(self);
        detached(async move { this.shutdown_detached().await }).await
    }

    /// Start the node without waiting for login. A saved login resumes; an
    /// unsigned node reports `needs_login` and its URL through `state`.
    pub async fn start(self: &Arc<Self>) -> Result<Snapshot, String> {
        let this = Arc::clone(self);
        detached(async move { this.start_detached().await }).await
    }

    async fn start_detached(self: Arc<Self>) -> Result<Snapshot, String> {
        loop {
            let _retirement = self.await_retirement_gate().await;
            let _lifecycle = self.lifecycle.lock().await;
            if self.shutting_down() {
                // A deferred retirement may never notify; start_locked
                // refuses with the shutdown reason instead of waiting.
                return self.start_locked().await;
            }
            let waiting_for_retirement = {
                let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
                matches!(
                    &inner.state,
                    LifecycleState::Retiring { .. } | LifecycleState::LoggingOut { .. }
                )
            };
            if waiting_for_retirement {
                let waiting = self.retirement_finished.notified();
                tokio::pin!(waiting);
                waiting.as_mut().enable();
                drop(_lifecycle);
                drop(_retirement);
                waiting.await;
                continue;
            }
            return self.start_locked().await;
        }
    }

    async fn await_retirement_gate(&self) -> tokio::sync::OwnedMutexGuard<()> {
        loop {
            let waiting = self.retirement_finished.notified();
            tokio::pin!(waiting);
            waiting.as_mut().enable();
            let gate = Arc::clone(&self.retirement_gate).lock_owned().await;
            if !self.pending_retirement.load(Ordering::Acquire) {
                return gate;
            }
            drop(gate);
            waiting.await;
        }
    }

    async fn start_locked(self: &Arc<Self>) -> Result<Snapshot, String> {
        if self.stopping.load(Ordering::Acquire) {
            return Err("tailnet service is stopping".into());
        }
        let generation;
        {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            if inner.closed {
                return Err("the daemon is shutting down".to_owned());
            }
            if !matches!(&inner.state, LifecycleState::Stopped) {
                return Ok(inner.snapshot.clone());
            }
            inner.generation = inner.generation.wrapping_add(1);
            generation = inner.generation;
            inner.state = LifecycleState::Starting;
            inner.snapshot.state = "starting";
            inner.snapshot.error = None;
            self.publish_locked(&inner.snapshot);
        }
        let state_dir = self.state_dir.clone();
        let hostname = self.hostname.clone();
        let stopping = self.stopping.clone();
        #[cfg(test)]
        let factory = self.node_factory.lock().unwrap_or_else(PoisonError::into_inner).take();
        let node = match tokio::task::spawn_blocking(move || {
            if stopping.load(Ordering::Acquire) {
                return Err("tailnet service is stopping".to_owned());
            }
            crate::config::private_state_dir(&state_dir).map_err(|e| e.to_string())?;
            // An explicit Start records intent, not network success. Keep
            // the marker if node construction or startup fails so a daemon
            // relaunch can retry. Logout clears it under these same gates.
            crate::config::write_atomic(&state_dir.join("enabled"), b"1\n")
                .map_err(|e| e.to_string())?;
            #[cfg(test)]
            if let Some(factory) = factory {
                return factory();
            }
            let config = NodeConfig::new(state_dir, hostname);
            let node = Node::new(&config).map_err(|error| error.0)?;
            node.start().map_err(|error| error.0)?;
            // Reconcile even when shutdown overtook startup: only the
            // controller knows whether a pending logout needs a receipt.
            Ok::<_, String>(Arc::new(node))
        })
        .await
        .map_err(|error| error.to_string())
        .and_then(|started| started)
        {
            Ok(node) => node,
            Err(error) => {
                self.start_failed(generation, &error);
                return Err(error);
            }
        };
        let close = {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            let logout_pending =
                matches!(&inner.state, LifecycleState::LoggingOut { node: None, .. });
            if self.stopping.load(Ordering::Acquire) {
                inner.generation = inner.generation.wrapping_add(1);
                let state_node = Arc::clone(&node);
                inner.state = LifecycleState::Retiring {
                    node: Some(state_node.clone()),
                    phase: RetirementPhase::Closing,
                };
                inner.snapshot.node_gone("stopped");
                self.publish_locked(&inner.snapshot);
                Some((inner.generation, state_node, logout_pending, "tailnet service is stopping"))
            } else if inner.generation != generation
                || !matches!(&inner.state, LifecycleState::Starting)
            {
                inner.generation = inner.generation.wrapping_add(1);
                let state_node = Arc::clone(&node);
                inner.state = LifecycleState::Retiring {
                    node: Some(state_node.clone()),
                    phase: RetirementPhase::Closing,
                };
                inner.snapshot.node_gone("stopped");
                self.publish_locked(&inner.snapshot);
                Some((inner.generation, state_node, logout_pending, "tailnet start was superseded"))
            } else {
                inner.state = LifecycleState::Running(node.clone());
                None
            }
        };
        if let Some((close_generation, state_node, logout_pending, message)) = close {
            let close_result = self.close_node(node).await;
            self.finish_start_close(
                close_generation,
                &state_node,
                logout_pending,
                false,
                close_result,
            );
            release_node(state_node);
            return Err(message.into());
        }
        let this = Arc::clone(self);
        let watch_node = node.clone();
        let runtime = tokio::runtime::Handle::current();
        if let Err(error) = std::thread::Builder::new()
            .name("acpmux-tailnet-watch".into())
            .spawn(move || this.watch(watch_node, generation, runtime))
        {
            let error = error.to_string();
            self.finish_watch_start_failure(node, &error).await;
            return Err(error);
        }
        // A watch that already ended has cleared the node: this may be the last handle.
        release_node(node);
        Ok(self.snapshot())
    }

    fn start_failed(&self, generation: u64, error: &str) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if inner.generation != generation || self.stopping.load(Ordering::Acquire) {
            return;
        }
        if !matches!(&inner.state, LifecycleState::Starting) {
            return;
        }
        inner.state = LifecycleState::Stopped;
        inner.snapshot =
            Snapshot { state: "error", error: Some(error.to_owned()), ..Snapshot::default() };
        self.publish_locked(&inner.snapshot);
    }

    async fn login_detached(self: Arc<Self>) -> Result<Snapshot, String> {
        let _retirement = self.retirement_gate.lock().await;
        let _lifecycle = self.lifecycle.lock().await;
        let node = self.node().ok_or_else(|| "tailnet is not started".to_owned())?;
        let result = tokio::task::spawn_blocking(move || node.login_interactive().map_err(|e| e.0))
            .await
            .map_err(|error| error.to_string())?;
        result?;
        Ok(self.snapshot())
    }

    async fn logout_detached(self: Arc<Self>) -> Result<Snapshot, String> {
        // Publish the transition before waiting for either async lock. A
        // listener-failure cleanup that already owns the gate will therefore
        // perform logout on the Retiring node instead of silently dropping it.
        self.request_logout();
        let _retirement = self.retirement_gate.lock().await;
        let _lifecycle = self.lifecycle.lock().await;
        // The request may have observed Starting before it acquired the
        // lifecycle lock. Re-apply the transition now that the operation is
        // serialized, invalidating the starting watch generation as well.
        self.request_logout();
        let state_dir = self.state_dir.clone();
        let directory = tokio::task::spawn_blocking(move || {
            let directory = open_logout_directory(&state_dir)?;
            unlink_saved_file(directory.as_ref(), "enabled")?;
            Ok::<_, String>(directory)
        })
        .await
        .map_err(|error| error.to_string())
        .and_then(|result| result);
        let directory = match directory {
            Ok(directory) => directory,
            Err(error) => {
                self.abort_logout(&error).await;
                return Err(error);
            }
        };
        let signed_out = if let Some(node) = self.state_node() {
            let remote_logout = self.remote_logout(Arc::clone(&node));
            tokio::task::spawn_blocking(move || {
                logout_and_close(remote_logout, || node.close().map_err(|e| e.0))
            })
            .await
            .map_err(|error| error.to_string())
            .and_then(|result| result)
        } else {
            let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            match &inner.state {
                LifecycleState::LoggingOut { remote_result: Some(result), .. } => result.clone(),
                _ => Ok(()), // Already stopped: local-only logout.
            }
        };
        // Never create or start a node to sign out. Both gates fence any
        // pending close; only now may we forget the saved local identity.
        let forgotten = tokio::task::spawn_blocking(move || clear_saved_login(directory))
            .await
            .map_err(|error| error.to_string())
            .and_then(|result| result);
        let result = signed_out.and(forgotten);
        self.clear_node(if result.is_ok() { "stopped" } else { "error" });
        if let Err(error) = &result {
            self.update(|snapshot| snapshot.error = Some(error.clone()));
        }
        self.pending_retirement.store(false, Ordering::Release);
        self.retirement_finished.notify_waiters();
        result?;
        Ok(self.snapshot())
    }

    async fn shutdown_detached(self: Arc<Self>) -> Result<(), String> {
        {
            // Before waiting on the lifecycle lock: a start queued behind
            // this shutdown sees it and refuses.
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            inner.closed = true;
            inner.generation = inner.generation.wrapping_add(1);
            inner.snapshot.node_gone("stopped");
            self.publish_locked(&inner.snapshot);
        }
        let _retirement = self.retirement_gate.lock().await;
        let _lifecycle = self.lifecycle.lock().await;
        self.shutdown_locked().await
    }

    async fn shutdown_locked(&self) -> Result<(), String> {
        {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            inner.generation = inner.generation.wrapping_add(1);
            // Closing wakes the watcher. Retain ownership but stop accepting
            // listener failures before the node can report its intentional end.
            if let LifecycleState::Running(node) = &inner.state {
                inner.state = LifecycleState::Retiring {
                    node: Some(Arc::clone(node)),
                    phase: RetirementPhase::Closing,
                };
            }
            inner.snapshot.node_gone("stopped");
            self.publish_locked(&inner.snapshot);
        }
        if let Some(node) = self.state_node() {
            let result = self.close_node(node).await?;
            if let Err(error) = result {
                self.finish_shutdown("error");
                self.update(|snapshot| snapshot.error = Some(error.clone()));
                return Err(error);
            }
        }
        self.finish_shutdown("stopped");
        Ok(())
    }

    fn finish_shutdown(&self, state: &'static str) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        // A logout can queue behind shutdown while retirement owns the gate.
        // Shutdown must not consume that caller's remote sign-out receipt.
        let previous = std::mem::replace(&mut inner.state, LifecycleState::Stopped);
        let node = match previous {
            LifecycleState::LoggingOut { node, remote_result } => {
                inner.state = LifecycleState::LoggingOut {
                    remote_result: remote_result
                        .or_else(|| node.as_ref().map(|_| Err(late_logout_error()))),
                    node: None,
                };
                node
            }
            LifecycleState::Retiring { node, phase: RetirementPhase::ClosingForLogout } => {
                inner.state = LifecycleState::LoggingOut {
                    node: None,
                    remote_result: Some(Err(late_logout_error())),
                };
                node
            }
            LifecycleState::Running(node) => Some(node),
            LifecycleState::Retiring { node, .. } => node,
            _ => None,
        };
        inner.snapshot.node_gone(state);
        self.publish_locked(&inner.snapshot);
        drop(inner);
        if let Some(node) = node {
            release_node(node);
        }
        // A retirement deferred to shutdown is over now; wake its waiters.
        self.retirement_finished.notify_waiters();
    }

    fn retire_node(
        &self,
        expected: Option<&Arc<Node>>,
        state: &'static str,
    ) -> Option<(Option<Arc<Node>>, u64)> {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        // After the shutdown fence (set under this same mutex) a watch or
        // listener ending is not a failure: daemon shutdown owns the close,
        // after the WebSocket drain has sent its close frames.
        if self.stopping.load(Ordering::Acquire) {
            return None;
        }
        let node = match &inner.state {
            LifecycleState::Running(node) => {
                if let Some(expected) = expected
                    && !Arc::ptr_eq(node, expected)
                {
                    return None;
                }
                Some(Arc::clone(node))
            }
            LifecycleState::Stopped if expected.is_none() => None,
            _ => return None,
        };
        inner.generation = inner.generation.wrapping_add(1);
        let previous = std::mem::replace(
            &mut inner.state,
            LifecycleState::Retiring { node: node.clone(), phase: RetirementPhase::Waiting },
        );
        inner.snapshot.node_gone(state);
        self.publish_locked(&inner.snapshot);
        let generation = inner.generation;
        drop(inner);
        if let LifecycleState::Running(previous) = previous {
            release_node(previous);
        }
        Some((node, generation))
    }

    fn begin_listener_retirement(
        &self,
        expected: Option<&Arc<Node>>,
        state: &'static str,
    ) -> Option<(Option<Arc<Node>>, u64)> {
        self.pending_retirement.store(true, Ordering::Release);
        self.retire_node(expected, state)
    }

    fn request_logout(&self) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let next = match &inner.state {
            LifecycleState::Running(node) => Some(Some(Arc::clone(node))),
            LifecycleState::Retiring { node, phase: RetirementPhase::Waiting } => {
                Some(node.clone())
            }
            LifecycleState::Retiring {
                phase: RetirementPhase::Closing | RetirementPhase::ClosingForLogout,
                ..
            } => {
                // Closing already invalidated the watcher. Record logout intent
                // without taking its node or changing the close generation.
                if let LifecycleState::Retiring { phase, .. } = &mut inner.state {
                    *phase = RetirementPhase::ClosingForLogout;
                }
                return;
            }
            LifecycleState::LoggingOut { .. } => None,
            LifecycleState::Starting => Some(None),
            LifecycleState::Stopped => Some(None),
        };
        if let Some(node) = next {
            inner.generation = inner.generation.wrapping_add(1);
            let previous = std::mem::replace(
                &mut inner.state,
                LifecycleState::LoggingOut { node, remote_result: None },
            );
            if let LifecycleState::Running(previous_node)
            | LifecycleState::Retiring { node: Some(previous_node), .. } = &previous
            {
                debug_assert!(
                    matches!(&inner.state,
                    LifecycleState::LoggingOut { node: Some(current), .. }
                    if Arc::ptr_eq(current, previous_node)),
                    "logout must transfer ownership of its live node"
                );
            }
            inner.snapshot.node_gone("stopped");
            self.publish_locked(&inner.snapshot);
            drop(inner);
            match previous {
                LifecycleState::Running(previous)
                | LifecycleState::Retiring { node: Some(previous), .. } => release_node(previous),
                _ => {}
            }
        }
    }

    async fn abort_logout(&self, error: &str) {
        let node = {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            let state = std::mem::replace(&mut inner.state, LifecycleState::Stopped);
            match state {
                LifecycleState::LoggingOut { node, .. } => {
                    inner.generation = inner.generation.wrapping_add(1);
                    if let Some(node) = &node {
                        // The old watch generation is invalid. Retire explicitly
                        // rather than forgetting the live node or reviving it
                        // without a working watcher. Both gates remain held.
                        inner.state = LifecycleState::Retiring {
                            node: Some(Arc::clone(node)),
                            phase: RetirementPhase::Closing,
                        };
                        debug_assert!(matches!(&inner.state,
                            LifecycleState::Retiring { node: Some(current), .. }
                            if Arc::ptr_eq(current, node)));
                    }
                    inner.snapshot.node_gone("error");
                    inner.snapshot.error = Some(error.to_owned());
                    self.publish_locked(&inner.snapshot);
                    node
                }
                state => {
                    inner.state = state;
                    debug_assert!(false, "abort_logout called outside LoggingOut");
                    None
                }
            }
        };
        if let Some(node) = node {
            let _ = self.close_node(node).await;
            self.clear_node("error");
        }
        self.pending_retirement.store(false, Ordering::Release);
        self.retirement_finished.notify_waiters();
    }

    async fn close_node(&self, node: Arc<Node>) -> Result<Result<(), String>, String> {
        #[cfg(test)]
        let before_close = self.before_close.lock().unwrap_or_else(PoisonError::into_inner).take();
        tokio::task::spawn_blocking(move || {
            #[cfg(test)]
            if let Some(before_close) = before_close {
                before_close();
            }
            node.close().map_err(|error| error.0)
        })
        .await
        .map_err(|error| error.to_string())
    }

    fn begin_retirement_close(&self, generation: u64, node: &Arc<Node>) -> ClosePlan {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        match &inner.state {
            LifecycleState::Retiring { node: Some(current), phase: RetirementPhase::Waiting }
                if Arc::ptr_eq(current, node) && inner.generation == generation =>
            {
                inner.state = LifecycleState::Retiring {
                    node: Some(Arc::clone(node)),
                    phase: RetirementPhase::Closing,
                };
                ClosePlan { logout: false }
            }
            LifecycleState::LoggingOut { node: Some(current), .. }
                if Arc::ptr_eq(current, node) =>
            {
                ClosePlan { logout: true }
            }
            _ => ClosePlan { logout: false },
        }
    }

    fn finish_retirement(
        &self,
        generation: u64,
        node: &Arc<Node>,
        plan: ClosePlan,
        result: Result<Result<(), String>, String>,
    ) -> bool {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let same = matches!(
            &inner.state,
            LifecycleState::Retiring { node: Some(current), .. }
            | LifecycleState::LoggingOut { node: Some(current), .. }
                if Arc::ptr_eq(current, node)
        );
        // Shutdown may have acquired the gate first and already closed this
        // node. Its completion is idempotent and must not alter newer state.
        if !same {
            return false;
        }
        let result = result.and_then(|result| result);
        let remote_result = match &inner.state {
            LifecycleState::LoggingOut { .. }
            | LifecycleState::Retiring { phase: RetirementPhase::ClosingForLogout, .. } => {
                // State records intent, not which operation actually ran. A
                // generation change can leave Waiting in place during close.
                Some(if plan.logout { result.clone() } else { Err(late_logout_error()) })
            }
            _ => None,
        };
        let logout_pending = remote_result.is_some();
        let retired = std::mem::replace(
            &mut inner.state,
            if logout_pending {
                LifecycleState::LoggingOut { node: None, remote_result }
            } else {
                LifecycleState::Stopped
            },
        );
        let error = result.err();
        if let Some(error) = error {
            inner.snapshot.state = "error";
            inner.snapshot.error = Some(error);
        } else if inner.generation == generation {
            inner.snapshot.node_gone("stopped");
        }
        self.publish_locked(&inner.snapshot);
        drop(inner);
        match retired {
            LifecycleState::Retiring { node: Some(retired), .. }
            | LifecycleState::LoggingOut { node: Some(retired), .. } => release_node(retired),
            _ => {}
        }
        logout_pending
    }

    async fn finish_watch_start_failure(&self, node: Arc<Node>, error: &str) {
        let (generation, logout_pending) = {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            let pending = matches!(
                &inner.state,
                LifecycleState::LoggingOut { node: Some(current), .. }
                    if Arc::ptr_eq(current, &node)
            );
            let current = matches!(
                &inner.state,
                LifecycleState::Running(current) if Arc::ptr_eq(current, &node)
            ) || pending;
            if !current {
                release_node(node);
                return;
            }
            inner.generation = inner.generation.wrapping_add(1);
            inner.state = LifecycleState::Retiring {
                node: Some(Arc::clone(&node)),
                phase: if pending {
                    RetirementPhase::ClosingForLogout
                } else {
                    RetirementPhase::Closing
                },
            };
            inner.snapshot.node_gone("error");
            inner.snapshot.error = Some(error.to_owned());
            self.publish_locked(&inner.snapshot);
            (inner.generation, pending)
        };
        let work_node = Arc::clone(&node);
        let remote_logout = self.remote_logout(Arc::clone(&node));
        let result = tokio::task::spawn_blocking(move || {
            if logout_pending {
                logout_and_close(remote_logout, || work_node.close().map_err(|e| e.0))
            } else {
                work_node.close().map_err(|e| e.0)
            }
        })
        .await
        .map_err(|e| e.to_string());
        self.finish_start_close(generation, &node, logout_pending, logout_pending, result);
        release_node(node);
    }

    fn finish_start_close(
        &self,
        _generation: u64,
        node: &Arc<Node>,
        logout_pending: bool,
        logout_performed: bool,
        result: Result<Result<(), String>, String>,
    ) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let same = matches!(
            &inner.state,
            LifecycleState::Retiring { node: Some(current), phase: RetirementPhase::Closing | RetirementPhase::ClosingForLogout }
                if Arc::ptr_eq(current, node)
        );
        debug_assert!(same, "a starting node stays owned until close completes");
        if !same {
            return;
        }
        let logout_pending = logout_pending
            || matches!(
                &inner.state,
                LifecycleState::Retiring { phase: RetirementPhase::ClosingForLogout, .. }
            );
        let retired = std::mem::replace(
            &mut inner.state,
            if logout_pending {
                LifecycleState::LoggingOut {
                    node: None,
                    remote_result: Some(if logout_performed {
                        result.clone().and_then(|result| result)
                    } else {
                        Err(late_logout_error())
                    }),
                }
            } else {
                LifecycleState::Stopped
            },
        );
        let error = match result {
            Ok(result) => result.err(),
            Err(error) => Some(error),
        };
        if let Some(error) = error {
            inner.snapshot.state = "error";
            inner.snapshot.error = Some(error);
        } else {
            inner.snapshot.node_gone("stopped");
        }
        self.publish_locked(&inner.snapshot);
        drop(inner);
        if let LifecycleState::Retiring { node: Some(retired), .. } = retired {
            release_node(retired);
        }
    }

    pub(crate) fn listener_is_current(&self, node: &Arc<Node>) -> bool {
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        matches!(&inner.state, LifecycleState::Running(current) if Arc::ptr_eq(current, node))
    }

    /// Daemon shutdown has begun: no start, resume or listener failure acts.
    pub(super) fn stopping(&self) -> bool {
        self.stopping.load(Ordering::Acquire)
    }

    #[cfg(test)]
    pub(super) fn set_running_for_test(&self, node: Arc<Node>, dns_name: &str) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        inner.state = LifecycleState::Running(node);
        inner.snapshot.state = "running";
        inner.snapshot.dns_name = Some(dns_name.to_owned());
    }

    pub(super) fn retirement_pending(&self) -> bool {
        self.pending_retirement.load(Ordering::Acquire)
    }

    fn watch(self: Arc<Self>, node: Arc<Node>, generation: u64, runtime: tokio::runtime::Handle) {
        if let Ok(watch) = node.watch() {
            for notify in watch {
                let mut snapshot = self.snapshot();
                snapshot.apply_notify(&notify, Some(&node));
                self.publish_if_current(generation, snapshot);
            }
        }
        // Watch termination is a lifecycle event. Route it through the same
        // retirement task as listener failure so a pending logout retains its
        // node until remote sign-out and close have both been coordinated.
        let failed = Arc::clone(&node);
        runtime.spawn(async move {
            self.listener_failed(&failed).await;
            release_node(failed);
        });
    }

    fn clear_node(&self, state: &'static str) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let node = match std::mem::replace(&mut inner.state, LifecycleState::Stopped) {
            LifecycleState::Running(node)
            | LifecycleState::Retiring { node: Some(node), .. }
            | LifecycleState::LoggingOut { node: Some(node), .. } => Some(node),
            _ => None,
        };
        inner.snapshot.node_gone(state);
        self.publish_locked(&inner.snapshot);
        drop(inner);
        if let Some(node) = node {
            release_node(node);
        }
    }

    fn update(&self, change: impl FnOnce(&mut Snapshot)) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        change(&mut inner.snapshot);
        self.publish_locked(&inner.snapshot);
    }

    #[cfg(test)]
    fn update_if_current(&self, generation: u64, change: impl FnOnce(&mut Snapshot)) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if inner.generation != generation {
            return;
        }
        change(&mut inner.snapshot);
        self.publish_locked(&inner.snapshot);
    }

    fn publish_if_current(&self, generation: u64, snapshot: Snapshot) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if inner.generation != generation {
            return;
        }
        inner.snapshot = snapshot;
        self.publish_locked(&inner.snapshot);
    }

    fn publish_locked(&self, snapshot: &Snapshot) {
        let _ = self.changes.send(snapshot.clone());
    }
}

/// Lifecycle work runs on its own task: a request whose caller goes away
/// (a closed connection drops its future) still finishes and reconciles the
/// controller, so `starting` or a closed node never outlives it.
async fn detached<T: Send + 'static>(
    work: impl std::future::Future<Output = Result<T, String>> + Send + 'static,
) -> Result<T, String> {
    tokio::spawn(work).await.map_err(|error| error.to_string())?
}

fn late_logout_error() -> String {
    "Local sign-in was cleared, but remote sign-out could not be confirmed because the tailnet node was already closing. Remove the device in the Tailscale admin console to revoke its access.".into()
}

// Logout can fail remotely, but the local node and its watchers must still close.
fn logout_and_close(
    logout: impl FnOnce() -> Result<(), String>,
    close: impl FnOnce() -> Result<(), String>,
) -> Result<(), String> {
    let logged_out = logout();
    let closed = close();
    logged_out.and(closed)
}

/// libtailscale owns a background runtime. Never let its final `Arc<Node>`
/// drop on a Tokio worker or request task.
fn release_on_background<T: Send + 'static>(value: T) {
    let _ = std::thread::Builder::new()
        .name("acpmux-tailnet-release".into())
        .spawn(move || drop(value));
}

fn spawn_after_retirement<F, Fut>(
    retirement_gate: Arc<tokio::sync::Mutex<()>>,
    lifecycle: Arc<tokio::sync::Mutex<()>>,
    action: F,
) -> tokio::task::JoinHandle<()>
where
    F: FnOnce() -> Fut + Send + 'static,
    Fut: std::future::Future<Output = ()> + Send + 'static,
{
    tokio::spawn(async move {
        let _retirement = retirement_gate.lock().await;
        let _lifecycle = lifecycle.lock().await;
        action().await;
    })
}

pub(crate) fn release_node(node: Arc<Node>) {
    release_on_background(node);
}

/// How long the shutdown fence waits for a failure close that began before
/// shutdown. The fence takes effect at once either way.
const FENCE_CLOSE_BOUND: std::time::Duration = std::time::Duration::from_secs(3);

pub fn state_dir(home: &Path) -> PathBuf {
    home.join("tailnet")
}

/// Read the opt-in marker without creating state. Its directory must be the
/// private one an explicit start made, and the marker a regular file owned by
/// this user: no symlink, FIFO or device is followed, and a few bytes at most
/// are read, so a planted marker cannot start a node or stall daemon startup.
#[cfg(unix)]
fn saved_opt_in(path: &Path) -> Result<bool, String> {
    use std::io::Read;
    use std::os::unix::io::FromRawFd;

    let (Some(state_dir), Some(name)) = (path.parent(), path.file_name()) else {
        return Ok(false);
    };
    let Some(directory) = open_logout_directory(state_dir)? else { return Ok(false) };
    let name = CString::new(name.as_encoded_bytes()).map_err(|error| error.to_string())?;
    // SAFETY: openat on our open directory descriptor with a NUL-terminated name.
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::NotFound {
            return Ok(false);
        }
        return Err(format!("open tailnet opt-in marker: {error}"));
    }
    // SAFETY: fd was just returned by openat and is owned by nothing else.
    let file = unsafe { std::fs::File::from_raw_fd(fd) };
    let metadata =
        file.metadata().map_err(|error| format!("stat tailnet opt-in marker: {error}"))?;
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    if !metadata.is_file() || metadata.uid() != uid {
        return Err("tailnet opt-in marker is not a regular file owned by this user".into());
    }
    let mut value = Vec::with_capacity(3);
    file.take(3)
        .read_to_end(&mut value)
        .map_err(|error| format!("read tailnet opt-in marker: {error}"))?;
    Ok(value == b"1\n")
}

/// Remove the opt-in marker through the private state directory, refusing a
/// symlinked or shared directory. A missing directory has nothing to clear.
fn clear_opt_in(state_dir: &Path) -> Result<(), String> {
    let directory = open_logout_directory(state_dir)?;
    unlink_saved_file(directory.as_ref(), "enabled")
}

#[cfg(test)]
fn remove_if_present(path: &Path) -> Result<(), String> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.to_string()),
    }
}

// The pinned libtailscale uses tsnet's default FileStore at this exact path:
// tailscale v1.104.1, tsnet/tsnet.go. No custom store is configured by Node.
// Open once with both lifecycle gates held, before removing the opt-in marker.
// Retain this directory descriptor until live nodes close and credentials are removed.
#[cfg(unix)]
fn open_logout_directory(state_dir: &Path) -> Result<Option<std::fs::File>, String> {
    let directory = match std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(state_dir)
    {
        Ok(directory) => directory,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("open private tailnet state directory: {error}")),
    };
    let metadata = directory
        .metadata()
        .map_err(|error| format!("stat private tailnet state directory: {error}"))?;
    let uid = unsafe { libc::getuid() };
    if !metadata.is_dir() || metadata.uid() != uid || metadata.mode() & 0o777 != 0o700 {
        return Err("tailnet state directory is not a private directory owned by this user".into());
    }
    Ok(Some(directory))
}

fn clear_saved_login(directory: Option<std::fs::File>) -> Result<(), String> {
    unlink_saved_file(directory.as_ref(), "tailscaled.state")
}

fn unlink_saved_file(directory: Option<&std::fs::File>, name: &str) -> Result<(), String> {
    let Some(directory) = directory else { return Ok(()) };
    let name = CString::new(name).map_err(|error| error.to_string())?;
    let result = unsafe { libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), 0) };
    if result == 0 {
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    if error.kind() == std::io::ErrorKind::NotFound {
        Ok(())
    } else {
        Err(format!("remove saved tailnet login: {error}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn clear_saved_login_rejects_a_symlinked_state_directory() {
        use std::os::unix::fs::symlink;

        let temporary = tempfile::tempdir().unwrap();
        let target = tempfile::tempdir().unwrap();
        std::fs::write(target.path().join("tailscaled.state"), b"keep me").unwrap();
        let state_dir = temporary.path().join("tailnet");
        symlink(target.path(), &state_dir).unwrap();

        let error = open_logout_directory(&state_dir).unwrap_err();
        assert!(error.contains("private tailnet state directory"), "{error}");
        assert_eq!(std::fs::read(target.path().join("tailscaled.state")).unwrap(), b"keep me");
    }

    #[test]
    fn intentional_logout_close_is_not_reported_as_listener_failure() {
        let temporary = tempfile::tempdir().unwrap();
        let config = NodeConfig::new(temporary.path(), "test");
        let node = Arc::new(Node::new(&config).unwrap());
        let controller = Controller::new(temporary.path(), "test");
        controller.inner.lock().unwrap().state = LifecycleState::Running(Arc::clone(&node));
        assert!(controller.listener_is_current(&node));
        controller.request_logout();
        assert!(!controller.listener_is_current(&node));
        // Also fence a completion that passed the service check just before logout.
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("test runtime");
        runtime.block_on(controller.listener_failed(&node));
        assert!(!controller.retirement_pending());
        assert_eq!(controller.snapshot().state, "stopped");
        assert!(controller.snapshot().error.is_none());
    }

    #[tokio::test]
    async fn shutdown_of_a_watched_node_does_not_report_listener_failure() {
        let temporary = tempfile::tempdir().unwrap();
        let config = NodeConfig::new(temporary.path(), "test");
        let node = tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap()))
            .await
            .unwrap();
        let controller = Controller::new(temporary.path(), "test");
        {
            let mut inner = controller.inner.lock().unwrap();
            inner.state = LifecycleState::Running(Arc::clone(&node));
            inner.snapshot.state = "running";
        }
        let (closing, release) = block_close(&controller);
        let shutdown = {
            let controller = controller.clone();
            tokio::spawn(async move { controller.shutdown().await })
        };
        closing.await.unwrap();
        // Force the watch's terminal callback while shutdown still owns both
        // gates, before it can clear the node after close returns.
        let closing_node = Arc::clone(&node);
        tokio::task::spawn_blocking(move || closing_node.close().unwrap()).await.unwrap();
        let mut watch_ended = {
            let controller = controller.clone();
            let node = Arc::clone(&node);
            tokio::spawn(async move {
                controller.listener_failed(&node).await;
                release_node(node);
            })
        };
        let returned =
            tokio::time::timeout(std::time::Duration::from_secs(1), &mut watch_ended).await;
        let before_finish = controller.snapshot();
        let retained =
            controller.state_node().expect("shutdown owns the node until close finishes");
        assert!(Arc::ptr_eq(&retained, &node));
        release_node(retained);
        release.send(()).unwrap();
        shutdown.await.unwrap().unwrap();
        let immediate = returned.is_ok();
        match returned {
            Ok(result) => result.unwrap(),
            Err(_) => watch_ended.await.unwrap(),
        }
        assert!(immediate, "intentional watch termination must not queue retirement cleanup");
        assert_eq!(before_finish.state, "stopped");
        assert_eq!(controller.snapshot().state, "stopped");
        assert!(controller.snapshot().error.is_none());
        assert!(controller.state_node().is_none());
        assert!(!controller.retirement_pending());
        release_node(node);
    }

    #[test]
    fn tailnet_late_start_failure_cannot_replace_shutdown_state() {
        let temporary = tempfile::tempdir().unwrap();
        let controller = Controller::new(temporary.path(), "test");
        let generation = {
            let mut inner = controller.inner.lock().unwrap();
            inner.state = LifecycleState::Starting;
            inner.generation
        };
        controller.start_failed(generation, "start failed");
        assert_eq!(controller.snapshot().state, "error");
        controller.begin_shutdown();
        controller.start_failed(generation, "late start failed");
        assert_eq!(controller.snapshot().state, "stopped");
    }

    #[tokio::test]
    async fn retirement_waiters_enable_notifications_before_releasing_gates() {
        let notify = tokio::sync::Notify::new();
        let waiting = notify.notified();
        tokio::pin!(waiting);
        waiting.as_mut().enable();
        notify.notify_waiters();
        tokio::time::timeout(std::time::Duration::from_millis(50), waiting)
            .await
            .expect("enabled waiter must observe a notification");
    }

    #[tokio::test]
    async fn tailnet_shutdown_fences_a_queued_start_before_node_creation() {
        let temporary = tempfile::tempdir().unwrap();
        let path = temporary.path().join("tailnet");
        let controller = Controller::new(&path, "test");
        let lock = controller.lifecycle.lock().await;
        let queued = controller.clone();
        let start = tokio::spawn(async move { queued.start().await });
        tokio::task::yield_now().await;
        controller.begin_shutdown();
        controller.note_listener_error_if_current(0);
        assert_eq!(controller.snapshot().state, "stopped");
        drop(lock);
        assert!(start.await.unwrap().is_err());
        assert!(controller.node().is_none());
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn tailnet_resume_does_not_create_state_without_opt_in() {
        let temporary = tempfile::tempdir().unwrap();
        let path = temporary.path().join("tailnet");
        let controller = Controller::new(&path, "test");
        controller.resume().await.unwrap();
        assert!(controller.node().is_none());
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn tailnet_logout_clears_opt_in_before_any_later_resume() {
        let temporary = tempfile::tempdir().unwrap();
        #[cfg(unix)]
        std::fs::set_permissions(
            temporary.path(),
            std::os::unix::fs::PermissionsExt::from_mode(0o700),
        )
        .unwrap();
        let marker = temporary.path().join("enabled");
        std::fs::write(&marker, b"1\n").unwrap();
        let controller = Controller::new(temporary.path(), "test");
        controller.shutdown().await.unwrap();
        assert!(saved_opt_in(&marker).unwrap());
        controller.logout().await.unwrap();
        assert!(!saved_opt_in(&marker).unwrap());
        controller.resume().await.unwrap();
        assert!(controller.node().is_none());
    }

    #[tokio::test]
    async fn tailnet_resume_rechecks_opt_in_after_waiting_for_lifecycle() {
        let temporary = tempfile::tempdir().unwrap();
        #[cfg(unix)]
        std::fs::set_permissions(
            temporary.path(),
            std::os::unix::fs::PermissionsExt::from_mode(0o700),
        )
        .unwrap();
        let marker = temporary.path().join("enabled");
        std::fs::write(&marker, b"1\n").unwrap();
        let controller = Controller::new(temporary.path(), "test");
        let lock = controller.lifecycle.lock().await;
        let queued = controller.clone();
        let resume = tokio::spawn(async move { queued.resume().await });
        tokio::task::yield_now().await;
        remove_if_present(&marker).unwrap();
        drop(lock);
        resume.await.unwrap().unwrap();
        assert!(controller.node().is_none());
    }

    #[tokio::test]
    async fn failed_explicit_start_keeps_opt_in_for_relaunch_retry() {
        let temporary = tempfile::tempdir().unwrap();
        let path = temporary.path().join("tailnet");
        let marker = path.join("enabled");
        let controller = Controller::new(&path, "test");
        let enabled = marker.clone();
        *controller.node_factory.lock().unwrap() = Some(Box::new(move || {
            assert!(saved_opt_in(&enabled).unwrap(), "intent precedes node startup");
            Err("transient startup failure".into())
        }));
        assert_eq!(controller.start().await.unwrap_err(), "transient startup failure");
        assert_eq!(controller.snapshot().state, "error");
        assert!(controller.state_node().is_none());
        assert!(saved_opt_in(&marker).unwrap());
        controller.shutdown().await.unwrap();

        // A new daemon controller must attempt startup based on persisted
        // intent, even though the first process never had a running node.
        let relaunched = Controller::new(&path, "test");
        let retried = Arc::new(AtomicBool::new(false));
        let attempt = retried.clone();
        *relaunched.node_factory.lock().unwrap() = Some(Box::new(move || {
            attempt.store(true, Ordering::Release);
            Err("retry attempted".into())
        }));
        assert_eq!(relaunched.resume().await.unwrap_err(), "retry attempted");
        assert!(retried.load(Ordering::Acquire));
        assert!(saved_opt_in(&marker).unwrap());
        relaunched.logout().await.unwrap();
        assert!(!saved_opt_in(&marker).unwrap());
        relaunched.resume().await.unwrap();
        assert!(relaunched.state_node().is_none());
    }

    #[tokio::test]
    async fn logout_table_never_starts_a_stopped_or_shutting_down_node() {
        for (name, saved, shutdown) in [
            ("untouched", false, 0),
            ("shutdown-begun", false, 1),
            ("shutdown-finished", false, 2),
            ("saved-stopped", true, 0),
            ("saved-shutdown-begun", true, 1),
            ("saved-shutdown-finished", true, 2),
        ] {
            let temporary = tempfile::tempdir().unwrap();
            let path = temporary.path().join("tailnet");
            if saved {
                std::fs::create_dir(&path).unwrap();
                #[cfg(unix)]
                std::fs::set_permissions(
                    &path,
                    std::os::unix::fs::PermissionsExt::from_mode(0o700),
                )
                .unwrap();
                std::fs::write(path.join("tailscaled.state"), b"saved identity").unwrap();
                std::fs::write(path.join("enabled"), b"1\n").unwrap();
                std::fs::write(path.join("unrelated"), b"keep").unwrap();
            }
            let controller = Controller::new(&path, name);
            *controller.node_factory.lock().unwrap() = Some(Box::new(|| {
                panic!("logout must never invoke node startup");
            }));
            match shutdown {
                1 => controller.begin_shutdown(),
                2 => controller.shutdown().await.unwrap(),
                _ => {}
            }
            let snapshot = controller.logout().await.unwrap();
            assert_eq!(snapshot.state, "stopped", "{name}");
            assert!(controller.state_node().is_none(), "{name}");
            assert!(!path.join("tailscaled.state").exists(), "{name}");
            assert!(!path.join("enabled").exists(), "{name}");
            assert!(controller.node_factory.lock().unwrap().is_some(), "{name}");
            if saved {
                assert_eq!(std::fs::read(path.join("unrelated")).unwrap(), b"keep", "{name}");
                assert_eq!(std::fs::read_dir(&path).unwrap().count(), 1, "{name}");
            } else {
                assert!(!path.exists(), "{name}: logout must not create a state directory");
            }
        }
    }

    #[tokio::test]
    async fn logout_during_shutdown_close_reports_remote_signout_unconfirmed() {
        let temporary = tempfile::tempdir().unwrap();
        let config = NodeConfig::new(temporary.path(), "shutdown-logout");
        let node = tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap()))
            .await
            .unwrap();
        let controller = Controller::new(temporary.path(), "shutdown-logout");
        {
            let mut inner = controller.inner.lock().unwrap();
            inner.state = LifecycleState::Running(Arc::clone(&node));
            inner.snapshot.state = "running";
        }
        let (closing, release) = block_close(&controller);
        let shutdown_controller = controller.clone();
        let shutdown = tokio::spawn(async move { shutdown_controller.shutdown().await });
        closing.await.expect("shutdown reached node close");
        // Model the request arriving while shutdown owns the close: record the
        // intent synchronously before allowing the blocked close to finish.
        controller.request_logout();
        assert!(matches!(
            &controller.inner.lock().unwrap().state,
            LifecycleState::Retiring { node: Some(_), phase: RetirementPhase::ClosingForLogout }
        ));
        let logout_controller = controller.clone();
        let logout = tokio::spawn(async move { logout_controller.logout().await });
        release.send(()).unwrap();
        shutdown.await.unwrap().expect("shutdown completes");
        let result = logout.await.unwrap();
        assert_eq!(result.unwrap_err(), late_logout_error());
        release_node(node);
    }

    #[test]
    fn shutdown_publishes_stopped_and_clears_identity_atomically() {
        let controller = Controller::new("/nonexistent/cmux-tailnet-test", "test");
        controller.update(|snapshot| {
            snapshot.state = "running";
            snapshot.dns_name = Some("old.example.ts.net".into());
            snapshot.ips = vec!["100.64.0.1".into()];
            snapshot.browse_to_url = Some("https://login.tailscale.com/fake".into());
        });
        let mut changes = controller.subscribe();
        controller.begin_shutdown();
        let published = changes.try_recv().unwrap();
        assert_eq!(published, controller.snapshot());
        assert_eq!(published.state, "stopped");
        assert!(published.dns_name.is_none());
        assert!(published.ips.is_empty());
        assert!(published.browse_to_url.is_none());
        assert!(changes.try_recv().is_err());
    }

    #[test]
    fn failed_logout_still_closes_the_node() {
        let closed = std::cell::Cell::new(false);
        let result = logout_and_close(
            || Err("logout failed".into()),
            || {
                closed.set(true);
                Ok(())
            },
        );
        assert!(closed.get());
        assert_eq!(result, Err("logout failed".into()));
    }

    fn block_close(
        controller: &Controller,
    ) -> (tokio::sync::oneshot::Receiver<()>, std::sync::mpsc::Sender<()>) {
        let (entered, notice) = tokio::sync::oneshot::channel();
        let (release, waiting) = std::sync::mpsc::channel();
        *controller.before_close.lock().unwrap() = Some(Box::new(move || {
            let _ = entered.send(());
            waiting.recv_timeout(std::time::Duration::from_secs(15)).unwrap();
        }));
        (notice, release)
    }

    #[tokio::test]
    async fn failed_marker_removal_keeps_the_original_node_until_shutdown_can_finish() {
        let temporary = tempfile::tempdir().unwrap();
        let config = NodeConfig::new(temporary.path(), "test");
        let node = tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap()))
            .await
            .unwrap();
        // remove_file fails on a directory, exercising the real marker error.
        std::fs::create_dir(temporary.path().join("enabled")).unwrap();
        let controller = Controller::new(temporary.path(), "test");
        controller.inner.lock().unwrap().state = LifecycleState::Running(Arc::clone(&node));
        controller.update(|snapshot| {
            snapshot.state = "running";
            snapshot.dns_name = Some("old.example.ts.net".into());
            snapshot.ips = vec!["100.64.0.1".into()];
        });
        let old_generation = controller.inner.lock().unwrap().generation;
        let (closing, release) = block_close(&controller);
        let logout = {
            let c = controller.clone();
            tokio::spawn(async move { c.logout().await })
        };
        closing.await.unwrap();
        let retained =
            controller.state_node().expect("failed logout retains ownership during close");
        assert!(Arc::ptr_eq(&retained, &node));
        release_node(retained);
        let mut shutdown = {
            let c = controller.clone();
            tokio::spawn(async move { c.shutdown().await })
        };
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(20), &mut shutdown)
                .await
                .is_err()
        );
        release.send(()).unwrap();
        assert!(logout.await.unwrap().is_err());
        shutdown.await.unwrap().unwrap();
        assert!(controller.state_node().is_none());
        // Abort explicitly closed the node; it must not revive a Running
        // snapshot whose watcher has already been invalidated.
        controller.publish_if_current(
            old_generation,
            Snapshot {
                state: "running",
                dns_name: Some("stale.example.ts.net".into()),
                ips: vec!["100.64.0.2".into()],
                ..Snapshot::default()
            },
        );
        assert_eq!(controller.snapshot().state, "stopped");
        assert!(controller.snapshot().dns_name.is_none());
        assert!(controller.snapshot().ips.is_empty());
        tokio::task::spawn_blocking(move || {
            assert_eq!(node.ips().unwrap_err().0, "node closed");
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn logout_during_start_waits_for_the_original_close() {
        let temporary = tempfile::tempdir().unwrap();
        let config = NodeConfig::new(temporary.path(), "test");
        let node = tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap()))
            .await
            .unwrap();
        let controller = Controller::new(temporary.path(), "test");
        let (creating, created) = tokio::sync::oneshot::channel();
        let (publish, unpublished) = std::sync::mpsc::channel();
        let starting_node = Arc::clone(&node);
        *controller.node_factory.lock().unwrap() = Some(Box::new(move || {
            let _ = creating.send(());
            unpublished.recv_timeout(std::time::Duration::from_secs(15)).unwrap();
            Ok(starting_node)
        }));
        let (closing, release) = block_close(&controller);
        let mut changes = controller.subscribe();
        let start = {
            let c = controller.clone();
            tokio::spawn(async move { c.start().await })
        };
        created.await.unwrap();
        assert_eq!(changes.recv().await.unwrap().state, "starting");
        let logout = {
            let c = controller.clone();
            tokio::spawn(async move { c.logout().await })
        };
        assert_eq!(changes.recv().await.unwrap().state, "stopped");
        publish.send(()).unwrap();
        closing.await.unwrap();
        // A second logout during the close must keep the state-owned handle.
        controller.request_logout();
        let retained = controller.state_node().expect("closing node remains controller-owned");
        assert!(Arc::ptr_eq(&retained, &node));
        release_node(retained);
        assert!(!controller.snapshot().running());
        assert!(controller.node().is_none());
        let replacement_created = Arc::new(AtomicBool::new(false));
        let created = replacement_created.clone();
        *controller.node_factory.lock().unwrap() = Some(Box::new(move || {
            created.store(true, Ordering::Release);
            Err("replacement factory reached".into())
        }));
        let mut retry = {
            let c = controller.clone();
            tokio::spawn(async move { c.start().await })
        };
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(3100), &mut retry).await.is_err()
        );
        assert!(
            !replacement_created.load(Ordering::Acquire),
            "no replacement before close completes"
        );
        release.send(()).unwrap();
        assert!(start.await.unwrap().is_err());
        assert_eq!(logout.await.unwrap().unwrap_err(), late_logout_error());
        assert!(retry.await.unwrap().is_err());
        assert!(replacement_created.load(Ordering::Acquire));
        tokio::task::spawn_blocking(move || {
            assert_eq!(node.ips().unwrap_err().0, "node closed");
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn cancelled_resume_keeps_startup_serialized_with_logout() {
        startup_logout_interleaving(true, false).await;
    }

    #[tokio::test]
    async fn shutdown_during_start_preserves_pending_logout_receipt() {
        startup_logout_interleaving(false, true).await;
    }

    async fn startup_logout_interleaving(cancel_resume: bool, shutdown: bool) {
        let temporary = tempfile::tempdir().unwrap();
        let config = NodeConfig::new(temporary.path(), "test");
        let node = tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap()))
            .await
            .unwrap();
        let controller = Controller::new(temporary.path(), "test");
        std::fs::write(temporary.path().join("enabled"), b"1\n").unwrap();
        let (creating, created) = tokio::sync::oneshot::channel();
        let (publish, unpublished) = std::sync::mpsc::channel();
        let starting_node = Arc::clone(&node);
        let saved_state = temporary.path().join("tailscaled.state");
        *controller.node_factory.lock().unwrap() = Some(Box::new(move || {
            let _ = creating.send(());
            unpublished.recv_timeout(std::time::Duration::from_secs(15)).unwrap();
            // Model startup writing saved state after the caller was cancelled.
            std::fs::write(saved_state, b"saved login").unwrap();
            Ok(starting_node)
        }));
        let mut changes = controller.subscribe();
        let startup = {
            let c = controller.clone();
            tokio::spawn(async move {
                if cancel_resume { c.resume().await } else { c.start().await.map(|_| ()) }
            })
        };
        created.await.unwrap();
        assert_eq!(changes.recv().await.unwrap().state, "starting");
        if cancel_resume {
            startup.abort();
        }
        let mut logout = {
            let c = controller.clone();
            tokio::spawn(async move { c.logout().await })
        };
        assert_eq!(changes.recv().await.unwrap().state, "stopped");
        if shutdown {
            controller.begin_shutdown();
        }
        let waiting =
            tokio::time::timeout(std::time::Duration::from_millis(50), &mut logout).await.is_err();
        // Unblock the worker even when the assertion would fail on old code.
        publish.send(()).unwrap();
        assert!(waiting, "logout must wait for startup reconciliation");
        assert!(
            startup
                .await
                .unwrap_or_else(|error| {
                    assert!(cancel_resume && error.is_cancelled());
                    Err("resume caller cancelled".into())
                })
                .is_err()
        );
        assert_eq!(logout.await.unwrap().unwrap_err(), late_logout_error());
        assert!(!temporary.path().join("enabled").exists());
        assert!(!temporary.path().join("tailscaled.state").exists());
        assert!(controller.node().is_none());
        controller.shutdown().await.unwrap();
        tokio::task::spawn_blocking(move || {
            assert_eq!(node.ips().unwrap_err().0, "node closed");
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn retirement_preserves_remote_logout_completion_for_the_waiter() {
        for (late, remote_result, shutdown_first, shutdown_before_plan) in [
            (true, Ok(()), false, false),
            (true, Ok(()), true, false),
            (false, Ok(()), false, false),
            (false, Ok(()), true, false),
            (false, Err("remote logout failed".to_owned()), false, false),
            (false, Err("remote logout failed".to_owned()), true, false),
            (true, Ok(()), false, true),
            (true, Ok(()), true, true),
            (false, Ok(()), false, true),
        ] {
            let temporary = tempfile::tempdir().unwrap();
            let config = NodeConfig::new(temporary.path(), "test");
            let node = tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap()))
                .await
                .unwrap();
            std::fs::write(temporary.path().join("tailscaled.state"), b"identity").unwrap();
            let controller = Controller::new(temporary.path(), "test");
            controller.inner.lock().unwrap().state = LifecycleState::Running(Arc::clone(&node));
            let (owned, generation) =
                controller.begin_listener_retirement(Some(&node), "stopped").unwrap();
            release_node(owned.unwrap());
            if !late {
                controller.request_logout();
            }
            if shutdown_before_plan {
                controller.begin_shutdown();
            }
            let plan = controller.begin_retirement_close(generation, &node);
            assert_eq!(plan.logout, !late);
            if late {
                controller.request_logout();
            }
            let closing_node = Arc::clone(&node);
            tokio::task::spawn_blocking(move || closing_node.close().unwrap()).await.unwrap();
            assert!(controller.finish_retirement(
                generation,
                &node,
                plan,
                Ok(remote_result.clone())
            ));
            let expected = if late { Err(late_logout_error()) } else { remote_result };
            if shutdown_first {
                controller.shutdown().await.unwrap();
            }
            assert_eq!(controller.logout().await.map(|_| ()), expected);
            assert!(!temporary.path().join("tailscaled.state").exists());
            assert!(controller.state_node().is_none());
            release_node(node);
        }
    }

    #[tokio::test]
    async fn queued_logout_clears_opt_in_before_retirement_signs_out() {
        // A login holds the lifecycle gate, a listener fails (its cleanup
        // queues first), then logout queues behind that cleanup. The cleanup
        // performs the remote sign-out; the marker must already be gone, or a
        // daemon restart during that sign-out resumes the saved identity.
        let temporary = tempfile::tempdir().unwrap();
        std::fs::set_permissions(
            temporary.path(),
            std::os::unix::fs::PermissionsExt::from_mode(0o700),
        )
        .unwrap();
        let marker = temporary.path().join("enabled");
        std::fs::write(&marker, b"1\n").unwrap();
        let config = NodeConfig::new(temporary.path(), "queued-logout");
        let node = tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap()))
            .await
            .unwrap();
        let controller = Controller::new(temporary.path(), "queued-logout");
        controller.inner.lock().unwrap().state = LifecycleState::Running(Arc::clone(&node));
        let (seen, marker_seen) = std::sync::mpsc::channel();
        let observed = marker.clone();
        *controller.remote_logout.lock().unwrap() = Some(Box::new(move || {
            let _ = seen.send(observed.exists());
            Ok(())
        }));
        let login = controller.lifecycle.lock().await;
        let failing = controller.clone();
        let failed = Arc::clone(&node);
        let failure = tokio::spawn(async move { failing.listener_failed(&failed).await });
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        let signing_out = controller.clone();
        let logout = tokio::spawn(async move { signing_out.logout().await });
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        drop(login);
        failure.await.unwrap();
        let result = logout.await.unwrap();
        assert!(
            !marker_seen.recv_timeout(std::time::Duration::from_secs(5)).unwrap(),
            "remote sign-out ran while the opt-in marker could still resume the node"
        );
        assert!(result.is_ok(), "{result:?}");
        assert!(!marker.exists());
        assert!(controller.state_node().is_none());
        release_node(node);
    }

    #[tokio::test]
    async fn watch_start_failure_clears_opt_in_before_remote_sign_out() {
        let temporary = tempfile::tempdir().unwrap();
        std::fs::set_permissions(
            temporary.path(),
            std::os::unix::fs::PermissionsExt::from_mode(0o700),
        )
        .unwrap();
        let marker = temporary.path().join("enabled");
        std::fs::write(&marker, b"1\n").unwrap();
        let config = NodeConfig::new(temporary.path(), "watch-logout");
        let node = tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap()))
            .await
            .unwrap();
        let controller = Controller::new(temporary.path(), "watch-logout");
        controller.inner.lock().unwrap().state = LifecycleState::Running(Arc::clone(&node));
        controller.request_logout();
        let (seen, marker_seen) = std::sync::mpsc::channel();
        let observed = marker.clone();
        *controller.remote_logout.lock().unwrap() = Some(Box::new(move || {
            let _ = seen.send(observed.exists());
            Ok(())
        }));
        controller.finish_watch_start_failure(Arc::clone(&node), "no watch thread").await;
        assert!(
            !marker_seen.recv_timeout(std::time::Duration::from_secs(5)).unwrap(),
            "remote sign-out ran while the opt-in marker could still resume the node"
        );
        assert!(!marker.exists());
        release_node(node);
    }

    #[tokio::test]
    async fn watch_end_after_the_shutdown_fence_leaves_the_node_to_shutdown() {
        let temporary = tempfile::tempdir().unwrap();
        let config = NodeConfig::new(temporary.path(), "fenced-watch");
        let node = tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap()))
            .await
            .unwrap();
        let controller = Controller::new(temporary.path(), "fenced-watch");
        controller.set_running_for_test(Arc::clone(&node), "node.example.ts.net");
        controller.begin_shutdown();
        // The watcher's terminal callback during the fenced interval.
        tokio::time::timeout(std::time::Duration::from_secs(1), controller.listener_failed(&node))
            .await
            .expect("a fenced watch end queues no retirement");
        let retained = controller.node().expect("shutdown, not the watcher, closes the node");
        assert!(Arc::ptr_eq(&retained, &node));
        release_node(retained);
        assert!(!controller.retirement_pending());
        assert!(controller.snapshot().error.is_none());
        controller.shutdown().await.unwrap();
        assert!(controller.state_node().is_none());
        release_node(node);
    }

    #[tokio::test]
    async fn watch_cleanup_queued_before_the_fence_leaves_the_close_to_shutdown() {
        let temporary = tempfile::tempdir().unwrap();
        let config = NodeConfig::new(temporary.path(), "queued-cleanup");
        let node = tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap()))
            .await
            .unwrap();
        let controller = Controller::new(temporary.path(), "queued-cleanup");
        controller.set_running_for_test(Arc::clone(&node), "node.example.ts.net");
        // A login holds the lifecycle gate; the watcher ends and its cleanup
        // queues behind it. Then the shutdown fence lands and login finishes
        // before the daemon's WebSocket shutdown.
        let login = controller.lifecycle.lock().await;
        let watcher = {
            let (controller, node) = (controller.clone(), Arc::clone(&node));
            tokio::spawn(async move { controller.listener_failed(&node).await })
        };
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        controller.begin_shutdown();
        drop(login);
        tokio::time::timeout(std::time::Duration::from_secs(5), watcher)
            .await
            .expect("queued cleanup finished")
            .unwrap();
        let retained =
            controller.state_node().expect("the queued cleanup must leave the close to shutdown");
        assert!(Arc::ptr_eq(&retained, &node));
        release_node(retained);
        assert!(!controller.retirement_pending());
        // A start or resume arriving now must not wait on the deferred
        // retirement, which no watcher will ever notify again.
        tokio::time::timeout(std::time::Duration::from_secs(1), controller.start())
            .await
            .expect("a start after the fence returns instead of waiting on retirement")
            .expect_err("nothing starts after the fence");
        tokio::time::timeout(std::time::Duration::from_secs(1), controller.resume())
            .await
            .expect("a resume after the fence returns instead of waiting on retirement")
            .unwrap();
        controller.shutdown().await.unwrap();
        assert!(controller.state_node().is_none());
        release_node(node);
    }

    #[tokio::test]
    async fn a_failure_close_the_pool_runs_after_the_fence_never_closes() {
        let temporary = tempfile::tempdir().unwrap();
        let config = NodeConfig::new(temporary.path(), "late-close");
        let node = tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap()))
            .await
            .unwrap();
        let controller = Controller::new(temporary.path(), "late-close");
        controller.set_running_for_test(Arc::clone(&node), "node.example.ts.net");
        // The cleanup passed every async check and queued its close, but the
        // blocking pool runs it only after the fence and well past its bound.
        let (queued, queued_seen) = tokio::sync::oneshot::channel();
        let (run, delayed) = std::sync::mpsc::channel::<()>();
        *controller.before_admission.lock().unwrap() = Some(Box::new(move || {
            let _ = queued.send(());
            delayed.recv_timeout(std::time::Duration::from_secs(15)).unwrap();
        }));
        *controller.before_close.lock().unwrap() =
            Some(Box::new(|| panic!("a close admitted after the fence")));
        let watcher = {
            let (controller, node) = (controller.clone(), Arc::clone(&node));
            tokio::spawn(async move { controller.listener_failed(&node).await })
        };
        queued_seen.await.unwrap();
        tokio::time::timeout(
            FENCE_CLOSE_BOUND + std::time::Duration::from_secs(1),
            controller.fence(),
        )
        .await
        .expect("the fence returns within its bound");
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        run.send(()).unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(5), watcher)
            .await
            .expect("the late cleanup finished")
            .unwrap();
        let retained = controller.state_node().expect("daemon shutdown, not the late job, closes");
        assert!(Arc::ptr_eq(&retained, &node));
        release_node(retained);
        assert!(!controller.retirement_pending());
        controller.shutdown().await.unwrap();
        assert!(controller.state_node().is_none());
        release_node(node);
    }

    #[tokio::test]
    async fn the_fence_waits_for_a_failure_close_already_under_way() {
        let temporary = tempfile::tempdir().unwrap();
        let config = NodeConfig::new(temporary.path(), "close-under-way");
        let node = tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap()))
            .await
            .unwrap();
        let controller = Controller::new(temporary.path(), "close-under-way");
        controller.set_running_for_test(Arc::clone(&node), "node.example.ts.net");
        let (closing, release) = block_close(&controller);
        let watcher = {
            let (controller, node) = (controller.clone(), Arc::clone(&node));
            tokio::spawn(async move { controller.listener_failed(&node).await })
        };
        // The cleanup passed its shutdown check and is inside its close.
        closing.await.unwrap();
        let mut fence = {
            let controller = controller.clone();
            tokio::spawn(async move { controller.fence().await })
        };
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), &mut fence).await.is_err(),
            "the fence must not return while an admitted close is under way"
        );
        release.send(()).unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(2), fence)
            .await
            .expect("the fence returns once the admitted close finished")
            .unwrap();
        watcher.await.unwrap();
        assert!(controller.state_node().is_none());
        controller.shutdown().await.unwrap();
        release_node(node);
    }

    #[test]
    fn saved_opt_in_refuses_a_marker_that_is_not_a_private_regular_file() {
        use std::os::unix::fs::{PermissionsExt, symlink};

        let temporary = tempfile::tempdir().unwrap();
        let state = temporary.path().join("tailnet");
        std::fs::create_dir(&state).unwrap();
        std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o700)).unwrap();
        let marker = state.join("enabled");
        let elsewhere = temporary.path().join("elsewhere");
        std::fs::write(&elsewhere, b"1\n").unwrap();
        symlink(&elsewhere, &marker).unwrap();
        assert!(saved_opt_in(&marker).is_err(), "a symlinked marker is not followed");
        std::fs::remove_file(&marker).unwrap();

        std::fs::write(&marker, b"1\n").unwrap();
        assert!(saved_opt_in(&marker).unwrap());
        std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o770)).unwrap();
        assert!(saved_opt_in(&marker).is_err(), "a shared state directory is refused");
        std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::remove_file(&marker).unwrap();

        let fifo = CString::new(marker.as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: mkfifo with a NUL-terminated path inside our temporary directory.
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        let (done, finished) = std::sync::mpsc::channel();
        let reading = marker.clone();
        std::thread::spawn(move || {
            let _ = done.send(saved_opt_in(&reading));
        });
        let result = finished
            .recv_timeout(std::time::Duration::from_secs(2))
            .expect("reading a FIFO marker must not block daemon startup");
        assert!(result.is_err(), "a FIFO is not a marker");
    }

    #[test]
    fn resume_error_cannot_replace_a_newer_start_or_shutdown() {
        for action in ["start", "logout", "shutdown"] {
            let controller = Controller::new("/nonexistent/cmux-tailnet-test", action);
            let generation = controller.inner.lock().unwrap().generation;
            match action {
                "start" => {
                    let mut inner = controller.inner.lock().unwrap();
                    inner.generation += 1;
                    inner.snapshot = Snapshot {
                        state: "running",
                        dns_name: Some("new.example.ts.net".into()),
                        ips: vec!["100.64.0.2".into()],
                        ..Snapshot::default()
                    };
                }
                "logout" => controller.request_logout(),
                _ => controller.begin_shutdown(),
            }
            let newer = controller.snapshot();
            let mut changes = controller.subscribe();
            controller.note_resume_error_if_current(generation, "old resume failed");
            assert_eq!(controller.snapshot(), newer, "{action}");
            assert!(changes.try_recv().is_err(), "{action}");
        }
    }

    #[tokio::test]
    async fn current_resume_marker_error_is_published_before_return() {
        let temporary = tempfile::tempdir().unwrap();
        std::fs::create_dir(temporary.path().join("enabled")).unwrap();
        let controller = Controller::new(temporary.path(), "test");
        let error = controller.resume().await.unwrap_err();
        assert_eq!(controller.snapshot().state, "error");
        assert_eq!(controller.snapshot().error.as_deref(), Some(error.as_str()));
    }

    #[test]
    fn sign_in_url_is_redacted_for_non_person_consumers() {
        let snapshot = Snapshot {
            state: "needs_login",
            browse_to_url: Some("https://login.tailscale.com/fake".into()),
            ..Snapshot::default()
        };
        assert!(snapshot.to_json(false).get("browse_to_url").is_none());
        assert_eq!(snapshot.to_json(true)["browse_to_url"], "https://login.tailscale.com/fake");
    }

    #[test]
    fn state_change_clears_stale_login_url_and_network_identity() {
        let mut snapshot = Snapshot {
            state: "needs_login",
            browse_to_url: Some("https://login.tailscale.com/fake".into()),
            dns_name: Some("cmux.example.ts.net".into()),
            ips: vec!["100.64.0.1".into()],
            ..Snapshot::default()
        };
        let notify = Notify { state: Some(5), ..Notify::default() };
        snapshot.apply_notify(&notify, None);
        assert_eq!(snapshot.state, "starting");
        assert!(snapshot.browse_to_url.is_none());
        assert!(snapshot.dns_name.is_none());
        assert!(snapshot.ips.is_empty());
    }

    #[test]
    fn a_running_name_notification_refresh_clears_a_stale_identity() {
        // NetMap rename notifications have no BackendState. The watcher
        // supplies the live status separately, so the actual notification
        // path must replace the old certificate/SNI identity.
        let mut snapshot = Snapshot {
            state: "running",
            dns_name: Some("old.example.ts.net".into()),
            ips: vec!["100.64.0.1".into()],
            ..Snapshot::default()
        };
        snapshot.apply_notify_with_status(
            &Notify::default(),
            Some(LiveIdentity {
                state: BackendState::Running,
                dns_name: Some("new.example.ts.net".into()),
                ips: vec!["100.64.0.2".into()],
            }),
        );
        assert_eq!(snapshot.dns_name.as_deref(), Some("new.example.ts.net"));
        assert_eq!(snapshot.ips, ["100.64.0.2"]);

        snapshot.apply_notify_with_status(
            &Notify::default(),
            Some(LiveIdentity { state: BackendState::Running, dns_name: None, ips: vec![] }),
        );
        assert_eq!(snapshot.state, "running");
        assert!(snapshot.dns_name.is_none());
        assert!(snapshot.ips.is_empty());
    }

    #[test]
    fn an_ended_node_leaves_no_sign_in_url_or_identity() {
        let mut snapshot = Snapshot {
            state: "running",
            browse_to_url: Some("https://login.tailscale.com/fake".into()),
            dns_name: Some("cmux.example.ts.net".into()),
            ips: vec!["100.64.0.1".into()],
            error: Some("watch ended".into()),
        };
        snapshot.node_gone("stopped");
        assert_eq!(snapshot.state, "stopped");
        assert!(snapshot.browse_to_url.is_none());
        assert!(snapshot.dns_name.is_none());
        assert!(snapshot.ips.is_empty());
        assert_eq!(snapshot.error.as_deref(), Some("watch ended"));
    }

    #[tokio::test]
    async fn a_dropped_caller_does_not_cancel_lifecycle_work() {
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = tokio::sync::oneshot::channel::<()>();
        let (done_tx, done_rx) = tokio::sync::oneshot::channel();
        let caller = tokio::spawn(detached(async move {
            let _ = started_tx.send(());
            let _ = release_rx.await;
            let _ = done_tx.send(());
            Ok::<_, String>(())
        }));
        started_rx.await.unwrap();
        caller.abort();
        let _ = caller.await;
        release_tx.send(()).unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(5), done_rx)
            .await
            .expect("detached lifecycle work finished after its caller was dropped")
            .unwrap();
    }

    #[tokio::test]
    async fn listener_failure_retires_state_before_a_slow_close() {
        let controller = Controller::new("/nonexistent/cmux-tailnet-test", "test");
        controller.update(|snapshot| snapshot.state = "running");
        let lifecycle = controller.lifecycle.lock().await;

        // A login/logout request can hold the lifecycle lock longer than the
        // supervisor's three-second close bound. Retirement must happen before
        // cleanup waits for that lock, so the service cannot restart this node.
        let Some((None, retired_generation)) =
            controller.begin_listener_retirement(None, "stopped")
        else {
            panic!("retiring an empty controller still records its generation");
        };
        let (closed, closed_rx) = tokio::sync::oneshot::channel();
        let cleanup = spawn_after_retirement(
            Arc::clone(&controller.retirement_gate),
            Arc::clone(&controller.lifecycle),
            {
                let controller = controller.clone();
                move || async move {
                    controller.note_listener_error_if_current(retired_generation);
                    controller.pending_retirement.store(false, Ordering::Release);
                    controller.retirement_finished.notify_waiters();
                    let _ = closed.send(());
                }
            },
        );
        let (started, started_rx) = tokio::sync::oneshot::channel();
        let queued = controller.clone();
        let mut start = tokio::spawn(async move {
            let _gate = queued.await_retirement_gate().await;
            let _lifecycle = queued.lifecycle.lock().await;
            let _ = started.send(queued.snapshot().state);
        });
        assert!(tokio::time::timeout(std::time::Duration::from_millis(10), cleanup).await.is_err());
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(10), &mut start).await.is_err()
        );
        assert_eq!(controller.snapshot().state, "stopped");
        assert!(controller.node().is_none());
        drop(lifecycle);
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            closed_rx.await.expect("detached close sent completion");
        })
        .await
        .expect("detached close completed after lifecycle lock was released");
        assert_eq!(started_rx.await.expect("queued start ran after retirement"), "error");
        start.await.expect("queued start task completed");
    }

    #[tokio::test]
    async fn queued_start_waits_for_retirement_cleanup() {
        let controller = Controller::new("/nonexistent/cmux-tailnet-test", "test");
        let retirement = controller.retirement_gate.lock().await;
        let lifecycle = controller.lifecycle.lock().await;
        let (cleanup_done, cleanup_rx) = tokio::sync::oneshot::channel();
        let cleanup = spawn_after_retirement(
            Arc::clone(&controller.retirement_gate),
            Arc::clone(&controller.lifecycle),
            move || async move {
                let _ = cleanup_done.send(());
            },
        );
        let (start_done, start_rx) = tokio::sync::oneshot::channel();
        let start = spawn_after_retirement(
            Arc::clone(&controller.retirement_gate),
            Arc::clone(&controller.lifecycle),
            move || async move {
                let _ = start_done.send(());
            },
        );
        drop(retirement);
        assert!(tokio::time::timeout(std::time::Duration::from_millis(10), cleanup).await.is_err());
        assert!(tokio::time::timeout(std::time::Duration::from_millis(10), start).await.is_err());
        drop(lifecycle);
        tokio::time::timeout(std::time::Duration::from_secs(1), cleanup_rx)
            .await
            .expect("retirement cleanup completed")
            .expect("retirement cleanup sent completion");
        tokio::time::timeout(std::time::Duration::from_secs(1), start_rx)
            .await
            .expect("queued start ran after retirement cleanup")
            .expect("queued start sent completion");
    }

    #[test]
    fn lifecycle_table_keeps_logout_inside_retirement() {
        // Exercise the short-mutex transitions as a table so the two
        // interleavings that used to lose saved credentials stay explicit:
        // retirement first, and logout first while retirement is pending.
        let cases = [
            (
                "retire",
                LifecycleState::Retiring { node: None, phase: RetirementPhase::Waiting },
                "stopped",
            ),
            (
                "logout-during-retire",
                LifecycleState::LoggingOut { node: None, remote_result: None },
                "stopped",
            ),
            ("logout-during-start", LifecycleState::Starting, "starting"),
        ];
        for (name, state, snapshot_state) in cases {
            let controller = Controller::new("/nonexistent/cmux-tailnet-test", name);
            {
                let mut inner = controller.inner.lock().unwrap();
                inner.state = state;
                inner.snapshot.node_gone(snapshot_state);
            }
            assert!(controller.node().is_none(), "{name} exposes no replacement node");
            assert_eq!(controller.snapshot().state, snapshot_state, "{name}");
        }

        let controller = Controller::new("/nonexistent/cmux-tailnet-test", "logout");
        controller.begin_listener_retirement(None, "stopped");
        controller.request_logout();
        assert!(matches!(
            &controller.inner.lock().unwrap().state,
            LifecycleState::LoggingOut { node: None, remote_result: None }
        ));

        let controller = Controller::new("/nonexistent/cmux-tailnet-test", "starting");
        let generation = controller.inner.lock().unwrap().generation;
        {
            let mut inner = controller.inner.lock().unwrap();
            inner.state = LifecycleState::Starting;
        }
        controller.request_logout();
        assert!(matches!(
            &controller.inner.lock().unwrap().state,
            LifecycleState::LoggingOut { node: None, remote_result: None }
        ));
        assert!(controller.inner.lock().unwrap().generation > generation);
    }

    #[test]
    fn watch_start_failure_preserves_the_remote_logout_result() {
        let temporary = tempfile::tempdir().unwrap();
        let config = NodeConfig::new(temporary.path(), "watch-failure");
        let node = Arc::new(Node::new(&config).unwrap());
        let controller = Controller::new(temporary.path(), "watch-failure");
        {
            let mut inner = controller.inner.lock().unwrap();
            inner.state = LifecycleState::Retiring {
                node: Some(Arc::clone(&node)),
                phase: RetirementPhase::ClosingForLogout,
            };
        }
        controller.finish_start_close(
            0,
            &node,
            true,
            true,
            Ok(Err("remote logout failed".to_owned())),
        );
        let inner = controller.inner.lock().unwrap();
        match &inner.state {
            LifecycleState::LoggingOut { node: None, remote_result: Some(Err(error)) } => {
                assert_eq!(error, "remote logout failed");
            }
            _ => panic!("pending logout result was discarded or changed"),
        }
        drop(inner);
        release_node(node);
    }

    #[tokio::test]
    async fn failed_marker_removal_rolls_back_logout_and_wakes_start() {
        let controller = Controller::new("/nonexistent/cmux-tailnet-test", "remove-failure");
        controller.request_logout();
        controller.abort_logout("remove enabled failed").await;
        assert!(matches!(&controller.inner.lock().unwrap().state, LifecycleState::Stopped));
        tokio::time::timeout(std::time::Duration::from_secs(1), controller.start())
            .await
            .expect("start is not left waiting on the failed logout transition")
            .expect_err("the test state directory is intentionally unavailable");
    }

    #[test]
    fn release_on_background_drops_after_the_caller_thread() {
        let caller = std::thread::current().id();
        let (dropped, received) = std::sync::mpsc::channel();
        struct Probe(std::sync::mpsc::Sender<std::thread::ThreadId>);
        impl Drop for Probe {
            fn drop(&mut self) {
                let _ = self.0.send(std::thread::current().id());
            }
        }
        release_on_background(Probe(dropped));
        let dropper = received.recv_timeout(std::time::Duration::from_secs(1)).unwrap();
        assert_ne!(dropper, caller);
    }

    #[tokio::test]
    async fn no_node_starts_after_shutdown() {
        let controller = Controller::new("/nonexistent/cmux-tailnet-test", "test");
        controller.shutdown().await.unwrap();
        assert_eq!(controller.start().await, Err("the daemon is shutting down".to_owned()));
        assert!(controller.node().is_none());
        assert_eq!(controller.snapshot().state, "stopped");
    }

    #[test]
    fn stale_watch_generation_cannot_publish_after_logout() {
        let controller = Controller::new("/tmp/cmux-tailnet-test", "test");
        {
            let mut inner = controller.inner.lock().unwrap();
            inner.generation = 2;
        }
        controller.update_if_current(1, |snapshot| snapshot.state = "running");
        assert_eq!(controller.snapshot().state, "not_started");
    }
}
