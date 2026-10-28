//! The daemon-owned embedded Tailscale node.
//!
//! This controller owns the node lifecycle and its event-driven state.  The
//! ingress server is deliberately separate: it receives the same `Arc<Node>`
//! and the daemon's `Arc<Hub>`, so ticket minting and redemption remain in one
//! acpmux pairing store.

use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use cmux_tailnet::{BackendState, Node, NodeConfig, Notify};
use serde_json::{Value, json};
#[cfg(test)]
use tokio::sync::Notify as TokioNotify;
use tokio::sync::broadcast;

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

// Production stays on the existing controller until the final stack slice.
#[cfg(not(test))]
#[path = "embedded_legacy.rs"]
mod legacy;
#[cfg(not(test))]
pub use legacy::Controller;

#[cfg(test)]
struct Inner {
    snapshot: Snapshot,
    node: Option<Arc<Node>>,
    starting: bool,
    closing: bool,
    generation: u64,
    /// Set by daemon shutdown and never cleared: no node starts after it.
    closed: bool,
}

/// Owns one embedded node per daemon install. The controller is cheap to
/// clone; all state and node handles remain shared and serialized.
#[cfg(test)]
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
}

#[cfg(test)]
impl Controller {
    pub fn new(state_dir: impl Into<PathBuf>, hostname: impl Into<String>) -> Arc<Self> {
        let (changes, _) = broadcast::channel(32);
        Arc::new(Self {
            state_dir: state_dir.into(),
            hostname: hostname.into(),
            inner: Mutex::new(Inner {
                snapshot: Snapshot { state: "not_started", ..Snapshot::default() },
                node: None,
                starting: false,
                closing: false,
                generation: 0,
                closed: false,
            }),
            changes,
            retirement_gate: Arc::new(tokio::sync::Mutex::new(())),
            lifecycle: Arc::new(tokio::sync::Mutex::new(())),
            pending_retirement: Arc::new(AtomicBool::new(false)),
            retirement_finished: Arc::new(TokioNotify::new()),
            stopping: Arc::new(AtomicBool::new(false)),
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
        self.inner.lock().unwrap_or_else(PoisonError::into_inner).node.clone()
    }

    /// Resume only a saved explicit opt-in; an untouched installation creates nothing.
    pub async fn resume(self: &Arc<Self>) -> Result<(), String> {
        loop {
            let retirement = self.await_retirement_gate().await;
            let lifecycle = self.lifecycle.lock().await;
            if self.pending_retirement.load(Ordering::Acquire) {
                drop(lifecycle);
                drop(retirement);
                continue;
            }
            let path = self.state_dir.join("enabled");
            let enabled = tokio::task::spawn_blocking(move || saved_opt_in(&path))
                .await
                .map_err(|e| e.to_string())??;
            if enabled {
                self.start_locked().await?;
            }
            return Ok(());
        }
    }

    pub(crate) fn note_listener_error(&self) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if self.stopping.load(Ordering::Acquire) {
            return;
        }
        inner.snapshot.state = "error";
        inner.snapshot.error =
            Some("The tailnet listener stopped. Start it again to retry.".into());
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

    pub(crate) fn begin_shutdown(&self) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        self.stopping.store(true, Ordering::Release);
        inner.generation = inner.generation.wrapping_add(1);
        inner.snapshot.state = "stopped";
        self.publish_locked(&inner.snapshot);
    }

    pub(crate) async fn listener_failed(self: &Arc<Self>, failed: &Arc<Node>) {
        // Mark the retirement before waiting on the gate. A login/logout may
        // hold the lifecycle lock longer than the supervisor timeout; the
        // service must not start a replacement while this cleanup is queued.
        let Some((Some(node), generation)) =
            self.begin_listener_retirement(Some(failed), "stopped")
        else {
            self.pending_retirement.store(false, Ordering::Release);
            self.retirement_finished.notify_waiters();
            release_node(Arc::clone(failed));
            return;
        };
        // The cleanup task owns the failed node and the retirement gate. The
        // supervisor timeout may cancel only this join, never the cleanup.
        let failed = Arc::clone(failed);
        let controller = Arc::clone(self);
        let cleanup = spawn_after_retirement(
            Arc::clone(&self.retirement_gate),
            Arc::clone(&self.lifecycle),
            move || async move {
                let _ = tokio::task::spawn_blocking(move || node.close().map_err(|e| e.0))
                    .await
                    .map_err(|error| error.to_string());
                controller.note_listener_error_if_current(generation);
                controller.pending_retirement.store(false, Ordering::Release);
                controller.retirement_finished.notify_waiters();
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
            let retirement = self.await_retirement_gate().await;
            let lifecycle = self.lifecycle.lock().await;
            if self.pending_retirement.load(Ordering::Acquire) {
                drop(lifecycle);
                drop(retirement);
                continue;
            }
            return self.start_locked().await;
        }
    }

    async fn await_retirement_gate(&self) -> tokio::sync::OwnedMutexGuard<()> {
        loop {
            let waiting = self.retirement_finished.notified();
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
            if inner.node.is_some() || inner.starting {
                return Ok(inner.snapshot.clone());
            }
            inner.generation = inner.generation.wrapping_add(1);
            generation = inner.generation;
            inner.starting = true;
            inner.snapshot.state = "starting";
            inner.snapshot.error = None;
            self.publish_locked(&inner.snapshot);
        }
        let state_dir = self.state_dir.clone();
        let hostname = self.hostname.clone();
        let stopping = self.stopping.clone();
        let node = match tokio::task::spawn_blocking(move || {
            if stopping.load(Ordering::Acquire) {
                return Err("tailnet service is stopping".to_owned());
            }
            crate::config::private_state_dir(&state_dir).map_err(|e| e.to_string())?;
            let enabled = state_dir.join("enabled");
            let config = NodeConfig::new(state_dir, hostname);
            let node = Node::new(&config).map_err(|error| error.0)?;
            node.start().map_err(|error| error.0)?;
            crate::config::write_atomic(&enabled, b"1\n").map_err(|e| e.to_string())?;
            if stopping.load(Ordering::Acquire) {
                let _ = node.close();
                return Err("tailnet service is stopping".to_owned());
            }
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
        {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            if self.stopping.load(Ordering::Acquire) {
                inner.starting = false;
                tokio::task::spawn_blocking(move || {
                    let _ = node.close();
                });
                return Err("tailnet service is stopping".into());
            }
            inner.starting = false;
            inner.node = Some(node.clone());
        }
        let this = Arc::clone(self);
        let watch_node = node.clone();
        if let Err(error) = std::thread::Builder::new()
            .name("acpmux-tailnet-watch".into())
            .spawn(move || this.watch(watch_node, generation))
        {
            release_node(node);
            self.clear_node("error");
            self.update(|snapshot| snapshot.error = Some(error.to_string()));
            return Err(error.to_string());
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
        inner.starting = false;
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
        let _retirement = self.retirement_gate.lock().await;
        let _lifecycle = self.lifecycle.lock().await;
        let path = self.state_dir.join("enabled");
        tokio::task::spawn_blocking(move || clear_opt_in(&path))
            .await
            .map_err(|e| e.to_string())??;
        self.begin_intentional_close();
        let node = self.node();
        if let Some(node) = node {
            let result = tokio::task::spawn_blocking(move || {
                logout_and_close(
                    || node.logout().map_err(|e| e.0),
                    || node.close().map_err(|e| e.0),
                )
            })
            .await
            .map_err(|error| error.to_string())?;
            if let Err(error) = result {
                self.clear_node("error");
                self.update(|snapshot| snapshot.error = Some(error.clone()));
                return Err(error);
            }
        }
        self.clear_node("stopped");
        Ok(self.snapshot())
    }

    async fn shutdown_detached(self: Arc<Self>) -> Result<(), String> {
        {
            // Before waiting on the lifecycle lock: a start queued behind
            // this shutdown sees it and refuses.
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            inner.closed = true;
        }
        let _retirement = self.retirement_gate.lock().await;
        let _lifecycle = self.lifecycle.lock().await;
        self.shutdown_locked().await
    }

    async fn shutdown_locked(&self) -> Result<(), String> {
        self.begin_intentional_close();
        if let Some(node) = self.node() {
            let result = tokio::task::spawn_blocking(move || node.close().map_err(|e| e.0))
                .await
                .map_err(|error| error.to_string())?;
            if let Err(error) = result {
                self.clear_node("error");
                self.update(|snapshot| snapshot.error = Some(error.clone()));
                return Err(error);
            }
        }
        self.clear_node("stopped");
        Ok(())
    }

    fn begin_intentional_close(&self) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        inner.closing = true;
        inner.generation = inner.generation.wrapping_add(1);
        inner.snapshot.node_gone("stopped");
        self.publish_locked(&inner.snapshot);
    }

    fn retire_node(
        &self,
        expected: Option<&Arc<Node>>,
        state: &'static str,
    ) -> Option<(Option<Arc<Node>>, u64)> {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(expected) = expected
            && (inner.closing
                || !inner.node.as_ref().is_some_and(|node| Arc::ptr_eq(node, expected)))
        {
            return None;
        }
        inner.generation = inner.generation.wrapping_add(1);
        inner.starting = false;
        let node = inner.node.take();
        inner.snapshot.node_gone(state);
        self.publish_locked(&inner.snapshot);
        Some((node, inner.generation))
    }

    fn begin_listener_retirement(
        &self,
        expected: Option<&Arc<Node>>,
        state: &'static str,
    ) -> Option<(Option<Arc<Node>>, u64)> {
        self.pending_retirement.store(true, Ordering::Release);
        self.retire_node(expected, state)
    }

    pub(crate) fn listener_is_current(&self, node: &Arc<Node>) -> bool {
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        !inner.closing && inner.node.as_ref().is_some_and(|current| Arc::ptr_eq(current, node))
    }

    pub(super) fn retirement_pending(&self) -> bool {
        self.pending_retirement.load(Ordering::Acquire)
    }

    fn watch(self: Arc<Self>, node: Arc<Node>, generation: u64) {
        let result = node.watch();
        match result {
            Ok(watch) => {
                for notify in watch {
                    let mut snapshot = self.snapshot();
                    snapshot.apply_notify(&notify, Some(&node));
                    self.publish_if_current(generation, snapshot);
                }
                self.clear_if_same(&node, generation, "stopped");
            }
            Err(error) => {
                self.update_if_current(generation, |snapshot| {
                    snapshot.state = "error";
                    snapshot.error = Some(error.0);
                });
                self.clear_if_same(&node, generation, "error");
            }
        }
    }

    fn clear_node(&self, state: &'static str) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let node = inner.node.take();
        inner.starting = false;
        inner.closing = false;
        inner.snapshot.node_gone(state);
        self.publish_locked(&inner.snapshot);
        drop(inner);
        if let Some(node) = node {
            release_node(node);
        }
    }

    fn clear_if_same(&self, node: &Arc<Node>, generation: u64, state: &'static str) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if inner.generation == generation
            && inner.node.as_ref().is_some_and(|current| Arc::ptr_eq(current, node))
        {
            inner.node = None;
            inner.snapshot.node_gone(state);
            self.publish_locked(&inner.snapshot);
        }
    }

    fn update(&self, change: impl FnOnce(&mut Snapshot)) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        change(&mut inner.snapshot);
        self.publish_locked(&inner.snapshot);
    }

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

#[cfg(test)]
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

pub fn state_dir(home: &Path) -> PathBuf {
    home.join("tailnet")
}

#[cfg(test)]
fn saved_opt_in(path: &Path) -> Result<bool, String> {
    match std::fs::read(path) {
        Ok(value) => Ok(value == b"1\n"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error.to_string()),
    }
}

#[cfg(test)]
fn clear_opt_in(path: &Path) -> Result<(), String> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tailnet_late_start_failure_cannot_replace_shutdown_state() {
        let temporary = tempfile::tempdir().unwrap();
        let controller = Controller::new(temporary.path(), "test");
        let generation = controller.inner.lock().unwrap().generation;
        controller.start_failed(generation, "start failed");
        assert_eq!(controller.snapshot().state, "error");
        controller.begin_shutdown();
        controller.start_failed(generation, "late start failed");
        assert_eq!(controller.snapshot().state, "stopped");
    }

    #[test]
    fn intentional_logout_close_is_not_reported_as_listener_failure() {
        let temporary = tempfile::tempdir().unwrap();
        let config = NodeConfig::new(temporary.path(), "test");
        let node = Arc::new(Node::new(&config).unwrap());
        let controller = Controller::new(temporary.path(), "test");
        controller.inner.lock().unwrap().node = Some(Arc::clone(&node));
        assert!(controller.listener_is_current(&node));
        controller.begin_intentional_close();
        assert!(!controller.listener_is_current(&node));
        // Also fence a completion that passed the service check just before logout.
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("test runtime");
        runtime.block_on(controller.listener_failed(&node));
        assert!(!controller.retirement_pending());
        controller.clear_node("stopped");
        assert_eq!(controller.snapshot().state, "stopped");
        assert!(controller.snapshot().error.is_none());
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
        controller.note_listener_error();
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
        let marker = temporary.path().join("enabled");
        std::fs::write(&marker, b"1\n").unwrap();
        let controller = Controller::new(temporary.path(), "test");
        let lock = controller.lifecycle.lock().await;
        let queued = controller.clone();
        let resume = tokio::spawn(async move { queued.resume().await });
        tokio::task::yield_now().await;
        clear_opt_in(&marker).unwrap();
        drop(lock);
        resume.await.unwrap().unwrap();
        assert!(controller.node().is_none());
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
