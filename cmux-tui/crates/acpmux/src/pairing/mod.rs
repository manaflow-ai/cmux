//! Pairing: add a machine with one pasted line.
//!
//! The person mints a ticket here (`acpmux host ticket new --role R`). The new
//! machine redeems it once (`acpmux host join TICKET`, which the install
//! script runs) over this daemon's WebSocket listener, and gets a device
//! credential bound to the role the minter chose:
//!
//! - `client`: the new machine adds this daemon as its peer and drives its
//!   sessions. Its connections are served as `Origin::Peer`.
//! - `read-only`: the same direction, but its connections may only list,
//!   watch and read (`read_only.rs`), enforced here, never by the client.
//! - `daemon`: this daemon adds the new machine as its peer, at the URL the
//!   new machine advertises, with a `client` credential the new machine
//!   issued for this one.
//! - `phone`: a phone paired with the Mac app, which the app's mobile host
//!   (cmux-mobile-host) splices to this daemon. Never from a ticket: only
//!   the person issues one (`_acpmux/pair_issue`), and the app holds it in
//!   memory for that phone's link. Its connections are served as
//!   `Origin::Web`, with every rule the shared dashboard token has, but they
//!   name the phone, so its own Full-access setting (below) can cover them.
//!
//! A ticket is a bearer secret: single use, short-lived (15 minutes by
//! default), revocable, and stored here only as its SHA-256. A device
//! credential is stored the same way, so `pairing.json` holds no secret.
//! Both travel only over `wss://` or `ws://` to a loopback host
//! (`peer::carries_peer_token`): the joining side refuses anything else
//! before it sends a byte, and the listener accepts a ticket or a device
//! credential only from a loopback address (the end of a TLS terminator or
//! an ssh tunnel on this machine), as it does the peer token.
//!
//! Full access, per machine, off by default (Leo: "#2 seems
//! reasonable i think... it's a gate that you can enable for your phone,
//! which is an attack vector you opt in to"). A chat a remote connection
//! starts has the policy `ask` (`server/remote_guard.rs`), which holds it in
//! a mode that asks (`hub/policy_mode.rs`). The person may let one `client`
//! machine or `phone` move such a chat out of it (not one held by deny-all, and not a
//! chat started on this machine): `_acpmux/pair_set {id, fullAccess}`,
//! on the unix socket only, and turning it on needs the person
//! (`hub/person.rs`), so an agent on this machine cannot grant it to a
//! machine it paired itself. The setting is on the device's record, so
//! revoking the machine ends it; it is read again on every request
//! ([`Pairing::full_access`]), and turning it off (or revoking the
//! machine) puts every chat out of its policy's mode back at once
//! (`Hub::hold_policies_again`). It covers only a connection that
//! presented that machine's own credential (`ConnAuth::Device`): the
//! shared dashboard token, a peer token and a read-only machine never. The
//! mobile host marks what its own phone filter refuses
//! (`_meta.acpmux.requireFullAccess`, `server/remote_guard.rs`): that runs only
//! when the setting covers it.

mod read_only;
mod store;
mod ticket;

pub use read_only::{allows as read_only_allows, scrub as read_only_scrub};
pub use store::{Device, Redeemed, Store, TicketRecord, TicketState};
pub use ticket::{TICKET_PREFIX, Ticket};

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex as StdMutex};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::rpc::RpcError;

/// The upgrade request header that carries a ticket's secret at redeem.
pub const TICKET_HEADER: &str = "x-acpmux-pair-ticket";

/// How long a ticket lives unless the minter says otherwise.
pub const DEFAULT_TTL_SECS: u64 = 15 * 60;
/// The longest a ticket may live.
pub const MAX_TTL_SECS: u64 = 24 * 60 * 60;

/// What a paired machine may do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Role {
    /// This daemon drives the new machine's sessions.
    Daemon,
    /// The new machine drives this daemon's sessions.
    Client,
    /// The new machine lists and watches this daemon's sessions, nothing more.
    ReadOnly,
    /// A phone the Mac app's mobile host serves: the Web's rules, named by its
    /// own credential (module docs). Issued by the person only, never by a ticket.
    Phone,
}

impl Role {
    pub fn parse(name: &str) -> Option<Self> {
        match name.trim().to_ascii_lowercase().as_str() {
            "daemon" => Some(Self::Daemon),
            "client" => Some(Self::Client),
            "read-only" | "readonly" | "read_only" => Some(Self::ReadOnly),
            "phone" => Some(Self::Phone),
            _ => None,
        }
    }

    /// A record of this role drives chats here, so its Full-access setting may be on.
    pub fn drives_chats(self) -> bool {
        matches!(self, Self::Client | Self::Phone)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Daemon => "daemon",
            Self::Client => "client",
            Self::ReadOnly => "read-only",
            Self::Phone => "phone",
        }
    }
}

/// A device credential the listener accepted: who it is and what it may do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceAuth {
    pub id: String,
    pub role: Role,
}

/// What the Full-access setting lets a machine do, shown where it is turned on.
pub fn full_access_allows(name: &str) -> String {
    format!(
        "lets {name} run chats in Full access: the agent edits files and runs commands on this Mac without asking"
    )
}

/// Whether a ticket or a device credential may arrive over `url`: `wss://`,
/// or `ws://` to a loopback host.
pub fn transport_ok(url: &str) -> bool {
    (url.starts_with("ws://") || url.starts_with("wss://")) && crate::peer::carries_peer_token(url)
}

/// Whether a connection from `from` may present a ticket or a device
/// credential: the listener has no TLS, so only a loopback address (a TLS
/// terminator or an ssh tunnel on this machine) proves it did not cross a
/// network in clear.
pub fn source_ok(from: std::net::SocketAddr) -> bool {
    from.ip().to_canonical().is_loopback()
}

/// This machine's name as a peer: the host name's first label, or `host`.
pub fn machine_name() -> String {
    let host = crate::hand::pair::hostname();
    let first = host.split('.').next().unwrap_or_default().to_ascii_lowercase();
    if crate::session_name::validate(&first).is_ok() { first } else { "host".into() }
}

/// 32 random bytes as 64 lowercase hex digits.
pub fn random_secret() -> Result<String, RpcError> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes)
        .map_err(|e| RpcError::internal(format!("the OS random generator: {e}")))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// The daemon's pairing state: the store (in memory until the daemon gives
/// it a file), its open device connections, and a revocation signal.
pub struct Pairing {
    inner: StdMutex<Inner>,
    /// Revoked device ids, read by the `revoked` futures of open connections.
    revoked_ids: Arc<StdMutex<HashSet<String>>>,
    revoked: tokio::sync::watch::Sender<u64>,
}

struct Inner {
    store: Store,
    path: Option<PathBuf>,
    /// Open connections per device id.
    open: HashMap<String, usize>,
}

impl Default for Pairing {
    fn default() -> Self {
        Self {
            inner: StdMutex::new(Inner {
                store: Store::default(),
                path: None,
                open: Default::default(),
            }),
            revoked_ids: Arc::default(),
            revoked: tokio::sync::watch::channel(0).0,
        }
    }
}

impl Pairing {
    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Keep the store in `path` (the daemon's `pairing.json`), loading what
    /// it holds. A file that does not parse is kept aside, never trusted.
    pub fn persist_at(&self, path: PathBuf) {
        let store = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
                tracing::warn!("pairing.json does not parse ({e}); starting with no tickets");
                let _ = std::fs::rename(&path, path.with_extension("json.bad"));
                Store::default()
            }),
            Err(_) => Store::default(),
        };
        *self.revoked_ids.lock().unwrap_or_else(|e| e.into_inner()) =
            store.devices.iter().filter(|d| d.revoked_ms.is_some()).map(|d| d.id.clone()).collect();
        let mut inner = self.lock();
        inner.store = store;
        inner.path = Some(path);
    }

    /// Run `f` on the store and save it when `f` succeeded and changed it.
    /// A failed save puts the store back as it was and fails.
    fn change<T>(&self, f: impl FnOnce(&mut Store) -> Result<T, RpcError>) -> Result<T, RpcError> {
        let mut inner = self.lock();
        let before = inner.store.clone();
        let out = f(&mut inner.store)?;
        if inner.store != before
            && let Some(path) = inner.path.clone()
        {
            let bytes = serde_json::to_vec_pretty(&inner.store)
                .map_err(|e| RpcError::internal(e.to_string()))?;
            if let Err(e) = crate::config::write_atomic(&path, &bytes) {
                inner.store = before;
                return Err(RpcError::internal(format!("could not save pairing.json: {e:#}")));
            }
        }
        Ok(out)
    }

    /// Mint a ticket; returns it and its record.
    pub fn mint(
        &self,
        role: Role,
        ttl_secs: u64,
        label: Option<String>,
        url: String,
        minter: String,
    ) -> Result<(Ticket, TicketRecord), RpcError> {
        let secret = random_secret()?;
        let now = crate::store::now_ms();
        let record = self.change(|s| s.mint(&secret, role, ttl_secs, label, now))?;
        let ticket = Ticket { url, minter, role, expires_ms: record.expires_ms, secret };
        Ok((ticket, record))
    }

    /// Whether the ticket `secret` could be redeemed now (the handshake's check).
    pub fn ticket_open(&self, secret: &str) -> bool {
        self.lock().store.find_open(secret, crate::store::now_ms()).is_some()
    }

    /// Redeem `secret` for a device named `name`; `check` runs on the ticket's
    /// role before anything is consumed (the daemon role's peer checks).
    pub fn redeem(
        &self,
        secret: &str,
        name: &str,
        check: impl FnOnce(Role) -> Result<(), RpcError>,
    ) -> Result<Redeemed, RpcError> {
        let token = random_secret()?;
        let device_id = store::new_id("dv")?;
        let now = crate::store::now_ms();
        self.change(|s| s.redeem(secret, name, &token, &device_id, now, check))
    }

    /// Issue a device credential with no ticket: the joining side's own
    /// `client` credential for the daemon that will drive it (role daemon).
    pub fn issue(&self, name: &str, role: Role) -> Result<(Device, String), RpcError> {
        let token = random_secret()?;
        let id = store::new_id("dv")?;
        let now = crate::store::now_ms();
        let device = self.change(|s| s.issue(name, role, &token, &id, None, now))?;
        Ok((device, token))
    }

    /// Issue a phone's credential (`Role::Phone`, the person only): it
    /// replaces a live phone record named `name` (whose open connections
    /// close) and takes its Full-access setting, so the Mac app gets a fresh
    /// credential each launch without the person turning the setting on again.
    pub fn issue_phone(&self, name: &str) -> Result<(Device, String), RpcError> {
        let token = random_secret()?;
        let id = store::new_id("dv")?;
        let now = crate::store::now_ms();
        let (device, replaced) = self.change(|s| s.issue_phone(name, &token, &id, now))?;
        if let Some(old) = replaced {
            self.revoked_ids.lock().unwrap_or_else(|e| e.into_inner()).insert(old);
            self.revoked.send_modify(|n| *n += 1);
        }
        Ok((device, token))
    }

    /// The device a presented credential proves, if any (never a revoked one).
    pub fn device_for(&self, token: &str) -> Option<DeviceAuth> {
        self.lock().store.device_for(token).map(|d| DeviceAuth { id: d.id.clone(), role: d.role })
    }

    /// Whether device `id`'s Full-access setting covers a request now: read
    /// from the store on every call, so turning it off or revoking the
    /// machine counts for its very next request.
    pub fn full_access(&self, id: &str) -> bool {
        self.lock().store.devices.iter().any(|d| d.id == id && d.grants_full_access())
    }

    /// Turn the Full-access setting of a live device (by id or name) on or off.
    pub fn set_full_access(&self, key: &str, on: bool) -> Result<Device, RpcError> {
        self.change(|s| s.set_full_access(key, on))
    }

    /// Revoke a ticket or a device by id (or a device by name). Returns the
    /// record and how many open connections the revocation closes.
    pub fn revoke(&self, key: &str) -> Result<Value, RpcError> {
        let now = crate::store::now_ms();
        let revoked = self.change(|s| s.revoke(key, now))?;
        let open = match &revoked {
            store::Revoked::Device(d, _) => {
                self.revoked_ids.lock().unwrap_or_else(|e| e.into_inner()).insert(d.id.clone());
                self.lock().open.get(&d.id).copied().unwrap_or(0)
            }
            store::Revoked::Ticket(..) => 0,
        };
        self.revoked.send_modify(|n| *n += 1);
        Ok(revoked.to_value(open))
    }

    /// Every ticket and device, newest first, for `ticket ls`.
    pub fn list(&self) -> Value {
        let inner = self.lock();
        let now = crate::store::now_ms();
        let tickets: Vec<Value> =
            inner.store.tickets.iter().rev().map(|t| t.to_value(now)).collect();
        let devices: Vec<Value> = inner
            .store
            .devices
            .iter()
            .rev()
            .map(|d| {
                let mut v = d.to_value();
                v["connections"] = json!(inner.open.get(&d.id).copied().unwrap_or(0));
                v
            })
            .collect();
        json!({"tickets": tickets, "devices": devices})
    }

    /// A device connection opened; the guard counts it until dropped.
    pub fn opened(self: &Arc<Self>, id: &str) -> OpenGuard {
        *self.lock().open.entry(id.to_owned()).or_insert(0) += 1;
        OpenGuard { pairing: self.clone(), id: id.to_owned() }
    }

    /// Resolves once device `id` is revoked (at once when it already is).
    /// Subscribed before it reads the set, so no revocation falls between.
    pub fn revoked(&self, id: &str) -> impl std::future::Future<Output = ()> + Send + 'static {
        let mut rx = self.revoked.subscribe();
        let ids = self.revoked_ids.clone();
        let id = id.to_owned();
        async move {
            loop {
                if ids.lock().unwrap_or_else(|e| e.into_inner()).contains(&id) {
                    return;
                }
                if rx.changed().await.is_err() {
                    return;
                }
            }
        }
    }
}

/// Counts one open device connection while it lives.
pub struct OpenGuard {
    pairing: Arc<Pairing>,
    id: String,
}

impl Drop for OpenGuard {
    fn drop(&mut self) {
        let mut inner = self.pairing.lock();
        if let Some(n) = inner.open.get_mut(&self.id) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                inner.open.remove(&self.id);
            }
        }
    }
}

#[cfg(test)]
mod tests;
