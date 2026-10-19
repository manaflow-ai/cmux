//! The daemon's one tailnet node (`tailnet-v1`, feature `tailnet`): its
//! start, its state as the IPN bus reports it, sign-in and logout.

use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use crate::stream_interrupt::SignalSender;
use cmux_tailnet::{BackendState, Node, NodeConfig, Notify};
use serde_json::{Value, json};

use super::super::{MessageWriter, Mux, ResourceError, ResourceOperation, send_resource_response};
use crate::resource_router::ParsedResourceRequest;

/// How long `tailnet.login.start` waits for the control plane's answer (a
/// sign-in link, Running or NeedsMachineAuth) before it answers the state
/// it has; the stream reports the rest.
const LOGIN_WAIT: Duration = Duration::from_secs(20);
/// How long `tailnet.logout` waits for the node to leave Running.
const LOGOUT_WAIT: Duration = Duration::from_secs(10);

/// What `tailnet.state` and the mutations report (`TailnetState`).
#[derive(Clone, Default)]
pub(super) struct Snapshot {
    /// The catalog's state name (`not_started`, `needs_login`, `running`, ...).
    state: &'static str,
    /// The sign-in link while the node waits for one (a credential: only
    /// ever in an answer to the frontend actor, never logged).
    browse_to_url: Option<String>,
    dns_name: Option<String>,
    owner: Option<(String, String)>,
    ips: Vec<String>,
    error: Option<String>,
}

impl Snapshot {
    pub(super) fn to_json(&self) -> Value {
        let mut value = json!({"state": self.state});
        if self.state == "needs_login"
            && let Some(url) = &self.browse_to_url
        {
            value["browse_to_url"] = json!(url);
        }
        if let Some(name) = &self.dns_name {
            value["dns_name"] = json!(name);
        }
        if let Some((login, display)) = &self.owner {
            value["owner"] = json!({"login_name": login, "display_name": display});
        }
        if !self.ips.is_empty() {
            value["ips"] = json!(self.ips);
        }
        if let Some(error) = &self.error {
            value["error"] = json!(error);
        }
        value
    }

    pub(super) fn running(&self) -> bool {
        self.state == "running"
    }

    fn settled(&self) -> bool {
        match self.state {
            "needs_login" => self.browse_to_url.is_some(),
            "not_started" | "no_state" | "starting" => false,
            _ => true,
        }
    }
}

#[derive(Default)]
struct Inner {
    node: Option<Arc<Node>>,
    snapshot: Snapshot,
    /// Raised on every change; a stream sends an item when it moved.
    version: u64,
    /// One wake per open `tailnet.state` stream (coalescing).
    watchers: Vec<SignalSender>,
}

pub(super) struct Owner {
    inner: Mutex<Inner>,
    changed: Condvar,
}

pub(super) fn owner() -> &'static Owner {
    static OWNER: OnceLock<Owner> = OnceLock::new();
    OWNER.get_or_init(|| Owner {
        inner: Mutex::new(Inner {
            snapshot: Snapshot { state: "not_started", ..Snapshot::default() },
            ..Inner::default()
        }),
        changed: Condvar::new(),
    })
}

impl Owner {
    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The current state and its version.
    pub(super) fn current(&self) -> (Snapshot, u64) {
        let inner = self.lock();
        (inner.snapshot.clone(), inner.version)
    }

    /// The running node, if it runs.
    pub(super) fn node(&self) -> Option<Arc<Node>> {
        self.lock().node.clone()
    }

    /// Wakes `sender` on every later change, until its stream ends.
    pub(super) fn watch(&self, sender: SignalSender) {
        self.lock().watchers.push(sender);
    }

    /// Starts the node unless it runs. True when this call started it.
    fn start(&self, mux: &Mux) -> Result<bool, String> {
        let mut inner = self.lock();
        if inner.node.is_some() {
            return Ok(false);
        }
        let dir = state_dir(mux).ok_or("this daemon keeps no state (ephemeral)")?;
        let config = NodeConfig::new(dir, device_name());
        let node = Arc::new(Node::new(&config).map_err(|e| e.0)?);
        node.start().map_err(|e| e.0)?;
        inner.node = Some(node.clone());
        drop(inner);
        self.update(|snapshot| snapshot.state = "starting");
        let spawned = std::thread::Builder::new()
            .name("tailnet-ipn-bus".into())
            .spawn(move || owner().follow(&node));
        if let Err(error) = spawned {
            self.update(|snapshot| snapshot.error = Some(format!("watch: {error}")));
        }
        Ok(true)
    }

    /// Starts a node that already has a saved login (a signed-in install
    /// comes back on its tailnet when the app subscribes, with no click).
    pub(super) fn resume(&self, mux: &Mux) {
        if self.node().is_some() {
            return;
        }
        let saved = state_dir(mux).is_some_and(|dir| dir.join("tailscaled.state").is_file());
        if saved && let Err(error) = self.start(mux) {
            self.update(|snapshot| {
                snapshot.state = "error";
                snapshot.error = Some(error);
            });
        }
    }

    /// Follows the node's IPN bus until the node closes (no polling: each
    /// message is one change).
    fn follow(&self, node: &Node) {
        let watch = match node.watch() {
            Ok(watch) => watch,
            Err(error) => {
                self.update(|snapshot| {
                    snapshot.state = "error";
                    snapshot.error = Some(error.0);
                });
                return;
            }
        };
        for notify in watch {
            self.apply(node, &notify);
        }
        self.update(|snapshot| snapshot.state = "stopped");
    }

    fn apply(&self, node: &Node, notify: &Notify) {
        let state = notify.backend_state();
        // Read outside the lock: status is the node's own in-memory view.
        let running = (state == Some(BackendState::Running)).then(|| {
            let status = node.status().unwrap_or_default();
            let owner = status.owner().map(|o| (o.login_name.clone(), o.display_name.clone()));
            (status.dns_name(), owner, node.ips().unwrap_or_default())
        });
        self.update(|snapshot| {
            if let Some(url) = notify.browse_to_url.as_deref().filter(|url| !url.is_empty()) {
                snapshot.browse_to_url = Some(url.to_owned());
            }
            if let Some(message) = notify.err_message.as_deref().filter(|m| !m.is_empty()) {
                snapshot.error = Some(message.to_owned());
            }
            if let Some(state) = state {
                snapshot.state = state_name(state);
                if state != BackendState::NeedsLogin {
                    snapshot.browse_to_url = None;
                }
                if state != BackendState::Running {
                    snapshot.dns_name = None;
                    snapshot.owner = None;
                    snapshot.ips.clear();
                }
            }
            if let Some((dns_name, owner, ips)) = running.clone() {
                snapshot.dns_name = dns_name;
                snapshot.owner = owner;
                snapshot.ips = ips;
                snapshot.error = None;
            }
        });
    }

    /// Changes the snapshot, then wakes every waiter and stream.
    fn update(&self, change: impl FnOnce(&mut Snapshot)) {
        let mut inner = self.lock();
        change(&mut inner.snapshot);
        inner.version += 1;
        inner.watchers.retain(|sender| {
            !matches!(sender.try_send(()), Err(std::sync::mpsc::TrySendError::Disconnected(())))
        });
        drop(inner);
        self.changed.notify_all();
    }

    /// Waits (on change events, up to `wait`) until `done` holds.
    fn wait_until(&self, wait: Duration, done: impl Fn(&Snapshot) -> bool) -> Snapshot {
        let deadline = Instant::now() + wait;
        let mut inner = self.lock();
        while !done(&inner.snapshot) {
            let Some(left) = deadline.checked_duration_since(Instant::now()) else { break };
            inner =
                self.changed.wait_timeout(inner, left).unwrap_or_else(PoisonError::into_inner).0;
        }
        inner.snapshot.clone()
    }
}

/// `tailnet.login.start` and `tailnet.logout`: they wait on the node, so
/// they answer from their own thread.
pub(super) fn answer_later(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
    writer: &MessageWriter,
) -> bool {
    let id = request.envelope.id.clone();
    let operation = request.envelope.operation;
    let (thread_mux, thread_writer, reply_id) = (mux.clone(), writer.clone(), id.clone());
    let spawned = std::thread::Builder::new().name("mux-tailnet".into()).spawn(move || {
        let result = match operation {
            ResourceOperation::TailnetLoginStart => login_start(&thread_mux, operation),
            _ => logout(operation),
        };
        let result = result.map(|value| super::mutation_result(&thread_mux, value));
        send_resource_response(&thread_writer, reply_id, operation, result);
    });
    spawned.is_ok()
        || send_resource_response(
            writer,
            id,
            operation,
            Err(failed(operation, "unavailable", "cannot start the tailnet request".into())),
        )
}

fn login_start(mux: &Mux, operation: ResourceOperation) -> Result<Value, ResourceError> {
    let owner = owner();
    let started = owner.start(mux).map_err(|error| failed(operation, "start_failed", error))?;
    if !started {
        // A node that runs and needs a login but offers no link (after a
        // logout) gets a new one; the bus brings it.
        let (snapshot, _) = owner.current();
        if snapshot.state == "needs_login"
            && snapshot.browse_to_url.is_none()
            && let Some(node) = owner.node()
        {
            node.login_interactive().map_err(|e| failed(operation, "login_failed", e.0))?;
        }
    }
    Ok(owner.wait_until(LOGIN_WAIT, Snapshot::settled).to_json())
}

fn logout(operation: ResourceOperation) -> Result<Value, ResourceError> {
    let owner = owner();
    let Some(node) = owner.node() else { return Ok(owner.current().0.to_json()) };
    node.logout().map_err(|e| failed(operation, "logout_failed", e.0))?;
    Ok(owner.wait_until(LOGOUT_WAIT, |snapshot| snapshot.state != "running").to_json())
}

pub(super) fn failed(operation: ResourceOperation, reason: &str, message: String) -> ResourceError {
    ResourceError::operation_failed(operation.wire_name(), reason, json!({"message": message}))
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

/// `<daemon state root>/tailnet` (the root above the session folders, so one
/// node per install, not per session): the node's keys and login;
/// cmux-tailnet makes it 0700. A tagged DEV build has its own state root, so
/// its own node. An ephemeral daemon has none and starts no node.
fn state_dir(mux: &Mux) -> Option<PathBuf> {
    let session = mux.session_state_directory()?;
    Some(session.parent()?.join("tailnet"))
}

/// `cmux-` and the computer name as a DNS label, as cmux-screen-host names
/// its node: `Lawrence's Mac mini` -> `cmux-lawrences-mac-mini`.
fn device_name() -> String {
    let mut label = String::from("cmux-");
    for c in computer_name().to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            label.push(c);
        } else if (c.is_whitespace() || c == '-' || c == '_' || c == '.') && !label.ends_with('-') {
            label.push('-');
        }
    }
    label.trim_end_matches('-').chars().take(63).collect()
}

fn computer_name() -> String {
    #[cfg(target_os = "macos")]
    let name = std::process::Command::new("scutil")
        .args(["--get", "ComputerName"])
        .output()
        .ok()
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty());
    #[cfg(not(target_os = "macos"))]
    let name: Option<String> = None;
    name.or_else(crate::platform::local_hostname).unwrap_or_else(|| "computer".into())
}
