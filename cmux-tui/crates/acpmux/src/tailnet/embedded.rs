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
#[path = "embedded_tests.rs"]
mod tests;
