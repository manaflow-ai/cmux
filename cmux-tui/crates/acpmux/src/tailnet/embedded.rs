//! The daemon-owned embedded Tailscale node.
//!
//! This controller owns the node lifecycle and its event-driven state.  The
//! ingress server is deliberately separate: it receives the same `Arc<Node>`
//! and the daemon's `Arc<Hub>`, so ticket minting and redemption remain in one
//! acpmux pairing store.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};

use cmux_tailnet::{BackendState, Node, NodeConfig, Notify};
use serde_json::{Value, json};
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

    pub fn running(&self) -> bool {
        self.state == "running"
    }

    fn apply_notify(&mut self, notify: &Notify, node: Option<&Node>) {
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
            if state == BackendState::Running
                && let Some(node) = node
            {
                if let Ok(status) = node.status() {
                    self.dns_name = status.dns_name();
                }
                self.ips = node.ips().unwrap_or_default();
                self.error = None;
            }
        }
    }
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

struct Inner {
    snapshot: Snapshot,
    node: Option<Arc<Node>>,
    starting: bool,
}

/// Owns one embedded node per daemon install. The controller is cheap to
/// clone; all state and node handles remain shared and serialized.
pub struct Controller {
    state_dir: PathBuf,
    hostname: String,
    inner: Mutex<Inner>,
    changes: broadcast::Sender<Snapshot>,
}

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
            }),
            changes,
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

    /// Start the node without waiting for login. A saved login resumes; an
    /// unsigned node reports `needs_login` and its URL through `state`.
    pub async fn start(self: &Arc<Self>) -> Result<Snapshot, String> {
        {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            if inner.node.is_some() || inner.starting {
                return Ok(inner.snapshot.clone());
            }
            inner.starting = true;
            inner.snapshot.state = "starting";
            self.publish_locked(&inner.snapshot);
        }
        let state_dir = self.state_dir.clone();
        let hostname = self.hostname.clone();
        let node = match tokio::task::spawn_blocking(move || {
            let config = NodeConfig::new(state_dir, hostname);
            let node = Node::new(&config).map_err(|error| error.0)?;
            node.start().map_err(|error| error.0)?;
            Ok::<_, String>(Arc::new(node))
        })
        .await
        .map_err(|error| error.to_string())?
        {
            Ok(node) => node,
            Err(error) => {
                self.clear_node("error");
                self.update(|snapshot| snapshot.error = Some(error.clone()));
                return Err(error);
            }
        };
        {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            inner.starting = false;
            inner.node = Some(node.clone());
        }
        let this = Arc::clone(self);
        if let Err(error) = std::thread::Builder::new()
            .name("acpmux-tailnet-watch".into())
            .spawn(move || this.watch(node))
        {
            self.clear_node("error");
            self.update(|snapshot| snapshot.error = Some(error.to_string()));
            return Err(error.to_string());
        }
        Ok(self.snapshot())
    }

    /// Request an explicit browser sign-in URL for a running unsigned node.
    pub async fn login(&self) -> Result<Snapshot, String> {
        let node = self.node().ok_or_else(|| "tailnet is not started".to_owned())?;
        let result = tokio::task::spawn_blocking(move || node.login_interactive().map_err(|e| e.0))
            .await
            .map_err(|error| error.to_string())?;
        result?;
        Ok(self.snapshot())
    }

    /// Sign out and close all ingress listeners that hold this node.
    pub async fn logout(&self) -> Result<Snapshot, String> {
        let node = self.node();
        if let Some(node) = node {
            tokio::task::spawn_blocking(move || {
                node.logout().map_err(|e| e.0)?;
                node.close().map_err(|e| e.0)
            })
            .await
            .map_err(|error| error.to_string())??;
        }
        self.clear_node("stopped");
        Ok(self.snapshot())
    }

    /// Close without deleting the saved login, used by daemon shutdown.
    pub async fn shutdown(&self) -> Result<(), String> {
        if let Some(node) = self.node() {
            tokio::task::spawn_blocking(move || node.close().map_err(|e| e.0))
                .await
                .map_err(|error| error.to_string())??;
        }
        self.clear_node("stopped");
        Ok(())
    }

    fn watch(self: Arc<Self>, node: Arc<Node>) {
        let result = node.watch();
        match result {
            Ok(watch) => {
                for notify in watch {
                    self.update(|snapshot| snapshot.apply_notify(&notify, Some(&node)));
                }
                self.clear_if_same(&node, "stopped");
            }
            Err(error) => {
                self.update(|snapshot| {
                    snapshot.state = "error";
                    snapshot.error = Some(error.0);
                });
                self.clear_if_same(&node, "error");
            }
        }
    }

    fn clear_node(&self, state: &'static str) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        inner.node = None;
        inner.starting = false;
        inner.snapshot.state = state;
        inner.snapshot.browse_to_url = None;
        inner.snapshot.dns_name = None;
        inner.snapshot.ips.clear();
        self.publish_locked(&inner.snapshot);
    }

    fn clear_if_same(&self, node: &Arc<Node>, state: &'static str) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if inner.node.as_ref().is_some_and(|current| Arc::ptr_eq(current, node)) {
            inner.node = None;
            inner.snapshot.state = state;
            self.publish_locked(&inner.snapshot);
        }
    }

    fn update(&self, change: impl FnOnce(&mut Snapshot)) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        change(&mut inner.snapshot);
        self.publish_locked(&inner.snapshot);
    }

    fn publish_locked(&self, snapshot: &Snapshot) {
        let _ = self.changes.send(snapshot.clone());
    }
}

pub fn state_dir(home: &Path) -> PathBuf {
    home.join("tailnet")
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
