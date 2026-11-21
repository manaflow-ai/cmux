//! A route from this machine's app to each of the person's other machines' cmux-tui session
//! daemon, with no ssh: one local unix socket per machine the hub lists for this person
//! (`hub/mesh_book.rs`, the machines a sign-in, a pair code or a join line joined). The app opens
//! it as a server row's `unix` route (`ServerReach.Route.unix`), as it opens a server on this Mac,
//! and New Workspace on that row runs there.
//!
//! Each connection to a route's socket dials one hub carrier circuit naming the cmux-tui session
//! service ([`CircuitService::CmuxTuiSession`]) to that machine and carries its bytes both ways.
//! The far end admits it only while the person there granted "control for my other machines
//! signed in to this account" (`session_service.rs`); until then the circuit is refused with the
//! reason, the route's state says it, and the far machine's app asks once.
//!
//! Who reaches a route: its socket is in this daemon's own socket folder (owner only, the folder
//! the daemon's `acpmux.sock` is in), made 0600, and each accepted connection's peer must be this
//! user. That is the trust the local cmux-tui socket has: the person's own processes.
//!
//! Cost: one listener per listed machine (a person has a few) while the hub lists it; a circuit
//! exists only while a connection to its socket is open. A machine the book stops listing has
//! its listener and socket removed at the next read of the routes.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, Weak};

use serde_json::{Value, json};

use crate::hub::Hub;
use crate::hub_carrier::CircuitService;

/// The routes of one daemon, by hub `daemonId`.
pub struct Routes {
    routes: Mutex<BTreeMap<String, Route>>,
    /// One reconcile at a time: two reads of the routes never bind one socket twice, and one
    /// never removes a socket another just listed.
    reconciling: tokio::sync::Mutex<()>,
    /// Owns every route's accept loop (and, through it, its circuits): a route that goes aborts
    /// its own, and the rest end with the daemon's hub.
    scope: cmux_scope::Scope,
}

impl Default for Routes {
    fn default() -> Self {
        Self {
            routes: Mutex::default(),
            reconciling: tokio::sync::Mutex::default(),
            scope: cmux_scope::Scope::new("machine routes"),
        }
    }
}

/// Whether `folder` is this user's own and private (a directory, not a symlink, owned by this
/// user, no group or other access): only there may a route's socket be made.
#[cfg(unix)]
fn private_folder(folder: &Path) -> bool {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    std::fs::symlink_metadata(folder).is_ok_and(|m| {
        // SAFETY: geteuid has no preconditions.
        m.is_dir() && m.uid() == unsafe { libc::geteuid() } && m.permissions().mode() & 0o077 == 0
    })
}

struct Route {
    host: String,
    socket: PathBuf,
    /// Why the last circuit was refused (`{reason, error}`), cleared by one that opened.
    last: Arc<Mutex<Option<Value>>>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Route {
    fn drop(&mut self) {
        self.task.abort();
        let _ = crate::home_fs::remove_file(&self.socket);
    }
}

/// The socket of the route to the machine whose hub `daemonId` is `key`, beside `daemon_socket`
/// (this daemon's own `acpmux.sock`): `m` and the key's hash, no longer than the daemon's own
/// file name, so a route's path fits a unix socket address whenever the daemon's does (at least
/// 8 hex digits, at most 24).
/// The hash covers the daemon's socket too, so two daemons of one user that share a socket
/// folder (`/tmp/acpmux-UID`) never name the same route.
pub fn socket_for(daemon_socket: &Path, key: &str) -> PathBuf {
    let mut input = daemon_socket.as_os_str().as_encoded_bytes().to_vec();
    input.push(0);
    input.extend_from_slice(key.as_bytes());
    let digest = crate::sha256::sha256_hex(&input);
    let own = daemon_socket.file_name().map_or(0, |name| name.len());
    let digits = own.saturating_sub(1).clamp(8, 24);
    let name = format!("m{}", digest.get(..digits).unwrap_or(&digest));
    daemon_socket.with_file_name(name)
}

/// A carrier's refusal (`"MESSAGE (REASON)"`, `ServiceRefusal`'s text) as `{reason, error}`.
pub fn refusal_of(text: &str) -> Value {
    let parsed =
        text.strip_suffix(')').and_then(|rest| rest.rsplit_once(" (")).filter(|(_, reason)| {
            !reason.is_empty()
                && reason.chars().all(|c| c.is_ascii_alphanumeric() || "._".contains(c))
        });
    match parsed {
        Some((message, reason)) => json!({"reason": reason, "error": message}),
        None => json!({"reason": "machine.unreachable", "error": text}),
    }
}

impl Routes {
    /// Keep one route per machine of `machines` (`(daemonId, host)`), sockets beside
    /// `daemon_socket`, and drop the rest. A route that cannot bind is listed with its error.
    #[cfg(unix)]
    pub async fn reconcile(
        &self,
        hub: &Arc<Hub>,
        daemon_socket: &Path,
        machines: &[(String, String)],
    ) -> Vec<Value> {
        let _one = self.reconciling.lock().await;
        let wanted: BTreeMap<&str, &str> =
            machines.iter().map(|(k, h)| (k.as_str(), h.as_str())).collect();
        let stale: Vec<Route> = {
            let mut routes = self.routes.lock().unwrap_or_else(|e| e.into_inner());
            let gone: Vec<String> =
                routes.keys().filter(|k| !wanted.contains_key(k.as_str())).cloned().collect();
            gone.into_iter().filter_map(|k| routes.remove(&k)).collect()
        };
        drop(stale);
        let mut listed = Vec::new();
        for (key, host) in wanted {
            let known = {
                let mut routes = self.routes.lock().unwrap_or_else(|e| e.into_inner());
                // A machine that changed its host name keeps its route under the new name.
                if let Some(route) = routes.get_mut(key) {
                    route.host = host.to_owned();
                }
                routes
                    .get(key)
                    .map(|r| (r.socket.clone(), r.last.lock().ok().and_then(|l| l.clone())))
            };
            let (socket, last) = match known {
                Some(known) => known,
                None => {
                    let socket = socket_for(daemon_socket, key);
                    // A shared folder (an `ACPMUX_SOCKET` in /tmp, say) gets no route: another
                    // user could take or race its path.
                    let folder = socket.parent().filter(|folder| {
                        // Made owner-only when missing, as `bind_unix` makes it.
                        let _ = crate::home_fs::create_dir_all(folder, 0o700);
                        private_folder(folder)
                    });
                    if folder.is_none() {
                        listed.push(json!({
                            "host": host, "daemonId": key, "via": "hub", "route": null,
                            "state": "unavailable",
                            "refusal": {"reason": "route.folder", "error":
                                "this daemon's socket folder is not private to this user"},
                        }));
                        continue;
                    }
                    match crate::server::bind_unix(&socket).await {
                        Ok(listener) => {
                            let last = Arc::new(Mutex::new(None));
                            let task = self.scope.spawn_named(
                                "machine route",
                                serve(Arc::downgrade(hub), key.to_owned(), listener, last.clone()),
                            );
                            let route =
                                Route { host: host.to_owned(), socket: socket.clone(), last, task };
                            self.routes
                                .lock()
                                .unwrap_or_else(|e| e.into_inner())
                                .insert(key.to_owned(), route);
                            (socket, None)
                        }
                        Err(e) => {
                            listed.push(json!({
                                "host": host, "daemonId": key, "via": "hub", "route": null,
                                "state": "unavailable",
                                "refusal": {"reason": "route.bind", "error": format!("{e:#}")},
                            }));
                            continue;
                        }
                    }
                }
            };
            let state = if last.is_some() { "refused" } else { "ready" };
            listed.push(json!({
                "host": host, "daemonId": key, "via": "hub", "route": "unix",
                "socket": socket, "state": state, "refusal": last,
            }));
        }
        listed
    }

    /// Every route, dropped (the daemon stops, or the carrier left with the join).
    pub fn clear(&self) {
        let all = std::mem::take(&mut *self.routes.lock().unwrap_or_else(|e| e.into_inner()));
        drop(all);
    }

    /// Record the outcome of a circuit to `key`: None when it opened, else its refusal.
    pub fn record(&self, key: &str, outcome: Option<Value>) {
        if let Some(route) = self.routes.lock().unwrap_or_else(|e| e.into_inner()).get(key)
            && let Ok(mut last) = route.last.lock()
        {
            *last = outcome;
        }
    }
}

/// Whether `stream`'s peer is this process's user.
#[cfg(unix)]
fn same_user(stream: &tokio::net::UnixStream) -> bool {
    // SAFETY: geteuid has no preconditions.
    stream.peer_cred().is_ok_and(|cred| cred.uid() == unsafe { libc::geteuid() })
}

/// Dial one session circuit to `key`: the stream, or the refusal as `{reason, error}`. Refused
/// by name when the carrier is off or the hub no longer lists the machine for this person.
pub async fn dial(hub: &Hub, key: &str) -> Result<crate::hub_carrier::HubStream, Value> {
    if hub.mesh_book_machine(key).is_none() {
        return Err(json!({
            "reason": "machine.unlisted",
            "error": "the hub no longer lists that machine for this account",
        }));
    }
    let carrier = hub.hub_carrier.get().ok_or_else(|| {
        json!({
            "reason": "carrier.off",
            "error": "this machine's hub carrier is off (not joined, or no WireGuard key)",
        })
    })?;
    carrier.dial_service(key, CircuitService::CmuxTuiSession).await.map_err(|e| refusal_of(&e))
}

/// The most circuits one route carries at once: a person opens a few workspaces on a machine,
/// and each circuit costs a ticket call and a relay circuit.
const MAX_CIRCUITS: usize = 32;

#[cfg(unix)]
async fn serve(
    hub: Weak<Hub>,
    key: String,
    listener: tokio::net::UnixListener,
    last: Arc<Mutex<Option<Value>>>,
) {
    // Every circuit of this route lives in `circuits`: the route dropped (its machine left the
    // book, or the carrier stopped) aborts this task, which ends them all.
    let mut circuits = tokio::task::JoinSet::new();
    loop {
        let accepted = tokio::select! {
            accepted = listener.accept() => accepted,
            Some(_) = circuits.join_next(), if !circuits.is_empty() => continue,
        };
        let mut stream = match accepted {
            Ok((stream, _)) => stream,
            Err(error) if crate::server::accept_ends_listener(&error) => {
                tracing::warn!(machine = %key, "a workspace route's listener ended: {error}");
                return;
            }
            Err(error) => {
                let pause = crate::server::accept_retry_delay(&error);
                if !pause.is_zero() {
                    // timeout: a passing shortage (EMFILE); the next accept goes after it.
                    tokio::time::sleep(pause).await;
                }
                continue;
            }
        };
        if !same_user(&stream) || circuits.len() >= MAX_CIRCUITS {
            continue;
        }
        let Some(hub) = hub.upgrade() else { return };
        let key = key.clone();
        let last = last.clone();
        circuits.spawn(async move {
            match dial(&hub, &key).await {
                Ok(mut circuit) => {
                    if let Ok(mut l) = last.lock() {
                        *l = None;
                    }
                    drop(hub);
                    let _ = tokio::io::copy_bidirectional(&mut stream, &mut circuit).await;
                }
                Err(refusal) => {
                    tracing::info!(machine = %key, "a workspace route was refused: {refusal}");
                    if let Ok(mut l) = last.lock() {
                        *l = Some(refusal);
                    }
                }
            }
        });
    }
}

#[cfg(test)]
#[path = "machine_routes_tests.rs"]
mod tests;
