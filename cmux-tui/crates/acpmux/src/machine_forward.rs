//! Forwards: a local listener on this machine that reaches a service another of the owner's
//! machines exposes by name (`named_service.rs`), through the hub carrier, so a machine joined
//! only through the hub reaches, say, the lane GitHub broker's unix socket or the model
//! gateway's port with no ssh, no tailnet and no desktop app in the byte path.
//!
//! `acpmux machine forward add --name lane-gh-broker --from broker-host --listen-unix
//! ~/.cache/lane-gh/broker.sock` writes `machineForwards` in config.json and asks the daemon to
//! reload; the daemon binds every forward there at start and on each reload, so they survive a
//! restart. Per accepted local connection it dials one circuit naming the service
//! (`HubCarrier::dial_service(machine, Named{name})`) and carries bytes both ways
//! (`copy_bidirectional` over the carrier's bounded duplex: a slow side holds the other back),
//! closing both on EOF or an error. A refused circuit closes the local connection at once and its
//! reason shows in `acpmux machine forward ls`.
//!
//! Who reaches a forward: a unix listener is made 0600 in an owner-only folder and serves only
//! this user's processes (peer credentials); a TCP listener binds loopback only, the reach the
//! service has on its own machine. At most [`MAX_CIRCUITS`] circuits per forward at once.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::io::{AsyncRead, AsyncWrite};

use crate::config::named_services::{ListenAt, MachineForward, forward_listen, owner_home};
use crate::hub::Hub;
use crate::hub_carrier::CircuitService;

/// The most circuits one forward carries at once; each costs a ticket call and a relay circuit.
pub const MAX_CIRCUITS: usize = 64;

/// A byte stream to a named service on another machine.
pub trait Circuit: AsyncRead + AsyncWrite + Send + Unpin {}
impl<T: AsyncRead + AsyncWrite + Send + Unpin> Circuit for T {}

/// Opens one circuit to the service `name` on machine `from`: the daemon's hub carrier, or a
/// test's stand-in.
#[async_trait]
pub trait ForwardDialer: Send + Sync + 'static {
    /// The circuit, or the refusal as `{reason, error}`.
    async fn dial(&self, from: &str, name: &str) -> Result<Box<dyn Circuit>, Value>;
}

/// The daemon's dialer: its hub carrier, to the machine `from` names.
pub struct HubDialer(Weak<Hub>);

#[async_trait]
impl ForwardDialer for HubDialer {
    async fn dial(&self, from: &str, name: &str) -> Result<Box<dyn Circuit>, Value> {
        let hub = self
            .0
            .upgrade()
            .ok_or_else(|| json!({"reason": "carrier.off", "error": "the daemon is stopping"}))?;
        let carrier = hub.hub_carrier.get().ok_or_else(|| {
            json!({
                "reason": "carrier.off",
                "error": "this machine's hub carrier is off (not joined, or the cmux link holds its node key)",
            })
        })?;
        let daemon = target_daemon(&hub, &carrier, from).await.ok_or_else(|| {
            json!({
                "reason": "machine.unknown",
                "error": format!(
                    "no hub route to machine `{from}`: name its host as the hub lists it, a peer \
                     whose config names its WireGuard key, or its node key"
                ),
            })
        })?;
        let service = CircuitService::Named { name: name.to_owned() };
        let circuit = carrier
            .dial_service(&daemon, service)
            .await
            .map_err(|e| crate::machine_routes::refusal_of(&e))?;
        Ok(Box::new(circuit))
    }
}

/// The hub `daemonId` (node key) of the machine `from` names: a peer whose config names its
/// WireGuard key, a route the carrier was given, a host the hub's book lists for this person, or
/// a key itself.
async fn target_daemon(
    hub: &Hub,
    carrier: &crate::hub_carrier::HubCarrier,
    from: &str,
) -> Option<String> {
    let configured = hub
        .config
        .read()
        .await
        .peers
        .get(from)
        .and_then(|peer| peer.wireguard.as_ref().map(|wg| wg.public_key.clone()));
    configured.or_else(|| carrier.route(from)).or_else(|| {
        let machines = hub.mesh_book_machines();
        let by_host = machines.iter().find(|(_, host)| host == from).map(|(key, _)| key.clone());
        by_host.or_else(|| is_key(from).then(|| from.to_owned()))
    })
}

fn is_key(text: &str) -> bool {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(text).is_ok_and(|bytes| bytes.len() == 32)
}

/// One bound forward.
struct Forward {
    config: MachineForward,
    listen: ListenAt,
    /// Why the last circuit was refused (`{reason, error}`), cleared by one that opened.
    last: Arc<Mutex<Option<Value>>>,
    open: Arc<AtomicUsize>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Forward {
    fn drop(&mut self) {
        self.task.abort();
        if let ListenAt::Unix(path) = &self.listen {
            let _ = crate::home_fs::remove_file(path);
        }
    }
}

/// The forwards of one daemon, by service name.
pub struct Forwards {
    bound: Mutex<BTreeMap<String, Forward>>,
    /// Why a forward in the config could not be bound, by name.
    failed: Mutex<BTreeMap<String, (MachineForward, String)>>,
    /// One reconcile at a time: two never bind one path twice.
    reconciling: tokio::sync::Mutex<()>,
    /// Owns every forward's accept loop (and, through it, its circuits): a forward that goes
    /// aborts its own, and the rest end with the daemon's hub.
    scope: cmux_scope::Scope,
}

impl Default for Forwards {
    fn default() -> Self {
        Self {
            bound: Mutex::default(),
            failed: Mutex::default(),
            reconciling: tokio::sync::Mutex::default(),
            scope: cmux_scope::Scope::new("machine forwards"),
        }
    }
}

impl Forwards {
    /// Bind every forward of `wanted` not bound as it is, and drop the rest; `home` expands `~/`.
    pub async fn reconcile(
        &self,
        wanted: &BTreeMap<String, MachineForward>,
        home: Option<&Path>,
        dialer: Arc<dyn ForwardDialer>,
    ) {
        let _one = self.reconciling.lock().await;
        let stale: Vec<Forward> = {
            let mut bound = self.bound.lock().unwrap_or_else(|e| e.into_inner());
            let gone: Vec<String> = bound
                .iter()
                .filter(|(name, f)| wanted.get(name.as_str()) != Some(&f.config))
                .map(|(name, _)| name.clone())
                .collect();
            gone.into_iter().filter_map(|name| bound.remove(&name)).collect()
        };
        // Dropped first, so a forward that moved to another path, or back, binds its new one.
        drop(stale);
        let mut failed = BTreeMap::new();
        for (name, forward) in wanted {
            if self.bound.lock().unwrap_or_else(|e| e.into_inner()).contains_key(name) {
                continue;
            }
            let bound = match forward_listen(name, forward, home) {
                Ok(listen) => bind(&self.scope, name, forward, listen, dialer.clone()).await,
                Err(e) => Err(e),
            };
            match bound {
                Ok(bound) => {
                    tracing::info!(service = %name, from = %forward.from, at = %bound.listen,
                        "machine forward: listening");
                    self.bound
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .insert(name.clone(), bound);
                }
                Err(e) => {
                    tracing::warn!(service = %name, "machine forward: not listening: {e}");
                    failed.insert(name.clone(), (forward.clone(), e));
                }
            }
        }
        *self.failed.lock().unwrap_or_else(|e| e.into_inner()) = failed;
    }

    /// Each forward and its state, as `acpmux machine forward ls --json` shows it.
    pub fn list(&self) -> Vec<Value> {
        let bound = self.bound.lock().unwrap_or_else(|e| e.into_inner());
        let failed = self.failed.lock().unwrap_or_else(|e| e.into_inner());
        let mut rows: BTreeMap<&str, Value> = BTreeMap::new();
        for (name, f) in bound.iter() {
            let last = f.last.lock().ok().and_then(|l| l.clone());
            rows.insert(
                name,
                json!({
                    "name": name, "from": f.config.from, "listen": f.listen.to_string(),
                    "state": if last.is_some() { "refused" } else { "listening" },
                    "open": f.open.load(Ordering::Relaxed), "refusal": last,
                }),
            );
        }
        for (name, (config, error)) in failed.iter() {
            rows.insert(
                name,
                json!({
                    "name": name, "from": config.from, "listen": Value::Null,
                    "state": "unavailable", "open": 0, "error": error,
                }),
            );
        }
        rows.into_values().collect()
    }

    /// Every forward dropped (the daemon stops).
    pub fn clear(&self) {
        let all = std::mem::take(&mut *self.bound.lock().unwrap_or_else(|e| e.into_inner()));
        drop(all);
    }
}

impl Hub {
    /// Bind the config's `machineForwards` as they are now (start and every reload).
    pub(crate) async fn reconcile_machine_forwards(self: &Arc<Self>) {
        let wanted = self.config.read().await.machine_forwards.clone();
        let dialer: Arc<dyn ForwardDialer> = Arc::new(HubDialer(Arc::downgrade(self)));
        self.forwards.reconcile(&wanted, owner_home().as_deref(), dialer).await;
    }
}

enum Listener {
    Unix(tokio::net::UnixListener),
    Tcp(tokio::net::TcpListener),
}

async fn bind(
    scope: &cmux_scope::Scope,
    name: &str,
    config: &MachineForward,
    listen: ListenAt,
    dialer: Arc<dyn ForwardDialer>,
) -> Result<Forward, String> {
    let listener = match &listen {
        ListenAt::Unix(path) => Listener::Unix(bind_unix(path).await?),
        ListenAt::Tcp(address) => Listener::Tcp(
            tokio::net::TcpListener::bind(address)
                .await
                .map_err(|e| format!("bind {address}: {e}"))?,
        ),
    };
    let last = Arc::new(Mutex::new(None));
    let open = Arc::new(AtomicUsize::new(0));
    let task = scope.spawn_named(
        "machine forward",
        serve(listener, config.from.clone(), name.to_owned(), dialer, last.clone(), open.clone()),
    );
    Ok(Forward { config: config.clone(), listen, last, open, task })
}

/// Bind `path` as a 0600 socket in an owner-only folder. A live socket there (an ssh forward, an
/// older daemon) is left alone and refused; a dead one is replaced; any other file is refused.
async fn bind_unix(path: &Path) -> Result<tokio::net::UnixListener, String> {
    use std::os::unix::fs::{FileTypeExt, PermissionsExt};
    cmux_unix_socket::check_path(path).map_err(|e| format!("{e:#}"))?;
    let folder = path.parent().ok_or_else(|| format!("`{}` has no folder", path.display()))?;
    crate::home_fs::create_dir_all(folder, 0o700)
        .map_err(|e| format!("create {}: {e}", folder.display()))?;
    if !private_folder(folder) {
        return Err(format!(
            "{} is not a folder only this user can open; a forward's socket goes in one",
            folder.display()
        ));
    }
    if let Ok(meta) = std::fs::symlink_metadata(path) {
        if !meta.file_type().is_socket() {
            return Err(format!("{} is there and is not a socket", path.display()));
        }
        if tokio::net::UnixStream::connect(path).await.is_ok() {
            return Err(format!(
                "something already listens on {} (an ssh forward?); stop it first",
                path.display()
            ));
        }
        crate::home_fs::remove_file(path).map_err(|e| format!("remove {}: {e}", path.display()))?;
    }
    let listener = tokio::net::UnixListener::bind(path)
        .map_err(|e| format!("bind {}: {e}", path.display()))?;
    crate::home_fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("chmod {}: {e}", path.display()))?;
    Ok(listener)
}

/// Whether `folder` is this user's own and private (a directory, not a symlink, owned by this
/// user, no group or other access).
fn private_folder(folder: &Path) -> bool {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    std::fs::symlink_metadata(folder).is_ok_and(|m| {
        // SAFETY: geteuid has no preconditions.
        m.is_dir() && m.uid() == unsafe { libc::geteuid() } && m.permissions().mode() & 0o077 == 0
    })
}

async fn serve(
    listener: Listener,
    from: String,
    name: String,
    dialer: Arc<dyn ForwardDialer>,
    last: Arc<Mutex<Option<Value>>>,
    open: Arc<AtomicUsize>,
) {
    // Every circuit of this forward lives in `circuits`: a forward dropped (removed, changed, the
    // daemon stopping) aborts this task, which ends them all.
    let mut circuits = tokio::task::JoinSet::new();
    loop {
        let accepted: std::io::Result<Box<dyn Circuit>> = tokio::select! {
            accepted = accept(&listener) => accepted,
            Some(_) = circuits.join_next(), if !circuits.is_empty() => continue,
        };
        let local = match accepted {
            Ok(local) => local,
            Err(error) if crate::server::accept_ends_listener(&error) => {
                tracing::warn!(service = %name, "a machine forward's listener ended: {error}");
                return;
            }
            Err(error) => {
                let pause = crate::server::accept_retry_delay(&error);
                if !pause.is_zero() {
                    tokio::time::sleep(pause).await;
                }
                continue;
            }
        };
        if circuits.len() >= MAX_CIRCUITS {
            // Dropped: the caller sees its connection close.
            continue;
        }
        let (from, name, dialer, last, open) =
            (from.clone(), name.clone(), dialer.clone(), last.clone(), open.clone());
        circuits.spawn(async move { carry(local, &from, &name, dialer, &last, &open).await });
    }
}

/// The next connection this user may make: a unix peer of another user is closed unserved.
async fn accept(listener: &Listener) -> std::io::Result<Box<dyn Circuit>> {
    loop {
        match listener {
            Listener::Unix(listener) => {
                let (stream, _) = listener.accept().await?;
                // SAFETY: geteuid has no preconditions.
                let own = stream.peer_cred().is_ok_and(|c| c.uid() == unsafe { libc::geteuid() });
                if own {
                    return Ok(Box::new(stream));
                }
            }
            Listener::Tcp(listener) => {
                let (stream, _) = listener.accept().await?;
                let _ = stream.set_nodelay(true);
                return Ok(Box::new(stream));
            }
        }
    }
}

/// One local connection: dial its circuit and carry bytes until either side ends.
async fn carry(
    mut local: Box<dyn Circuit>,
    from: &str,
    name: &str,
    dialer: Arc<dyn ForwardDialer>,
    last: &Mutex<Option<Value>>,
    open: &AtomicUsize,
) {
    match dialer.dial(from, name).await {
        Ok(mut circuit) => {
            if let Ok(mut l) = last.lock() {
                *l = None;
            }
            open.fetch_add(1, Ordering::Relaxed);
            let carried = tokio::io::copy_bidirectional(&mut local, &mut circuit).await;
            open.fetch_sub(1, Ordering::Relaxed);
            if let Err(e) = carried {
                tracing::debug!(service = %name, "a machine forward's circuit ended: {e}");
            }
        }
        Err(refusal) => {
            tracing::info!(service = %name, machine = %from, "a machine forward was refused: {refusal}");
            if let Ok(mut l) = last.lock() {
                *l = Some(refusal);
            }
        }
    }
    // Both sides drop here: the local connection and the circuit close.
}

#[cfg(test)]
#[path = "machine_forward_tests.rs"]
mod tests;
