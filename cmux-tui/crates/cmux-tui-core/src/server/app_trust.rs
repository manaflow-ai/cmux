//! `verified_app`: is this connection the cmux app? (P8 slice 3b-2,
//! plans/cmux-next/identity.md section 3.)
//!
//! Two provers; either one makes a LOCAL (Unix socket) connection the
//! verified app:
//!
//! - A, code signature: the peer's audit token, read once when the
//!   connection is accepted, names code that satisfies the containing app's
//!   requirement (team id and bundle id; `cmux_link::app_caller`). Signed
//!   builds only. Checked when first needed, then cached per connection.
//! - B, install key: the app that started this daemon handed it a 32-byte
//!   key and its install id over an inherited pipe (`read_frontend_key`).
//!   On a new connection the app sends `client-hello {install_id}` as its
//!   FIRST request and gets a fresh nonce, then `client-hello {install_id,
//!   proof}` as its SECOND, with proof = HMAC-SHA256(key, context, install
//!   id, nonce) (`cmux_local_auth::frontend_proof`).
//!
//! Fail closed: any other order, a wrong proof, a second hello, a WebSocket
//! or remote-entry connection, or a daemon with no key leaves the
//! connection unverified for its whole life. `set-client-info kind` is a
//! label and never counts.

use std::collections::HashMap;
use std::io::Read;
use std::sync::{Arc, Mutex, OnceLock};

use cmux_link::app_caller::PeerToken;
/// The proof math, for clients and tests of other crates.
pub use cmux_local_auth::frontend_proof;
use cmux_local_auth::frontend_proof::{INSTALL_KEY_LEN, NONCE_LEN};
use serde::Deserialize;
use serde_json::{Value, json};
use zeroize::Zeroizing;

/// The raw v1 command.
pub(crate) const CLIENT_HELLO: &str = "client-hello";
/// First token of the launcher pipe payload.
const KEY_MAGIC: &str = "cmuxik1";
/// Upper bound on the launcher pipe payload.
const MAX_KEY_PAYLOAD: u64 = 512;

/// The app's install key and install id, as the launcher handed them over.
pub struct FrontendKey {
    install_id: String,
    key: Zeroizing<[u8; INSTALL_KEY_LEN]>,
}

impl std::fmt::Debug for FrontendKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("FrontendKey")
            .field("install_id", &self.install_id)
            .finish_non_exhaustive()
    }
}

impl FrontendKey {
    /// Parses `cmuxik1 <install_id> <64 hex key>` (one line).
    pub fn parse(payload: &str) -> Option<Self> {
        let mut words = payload.trim_end_matches(['\n', '\r']).split(' ');
        let (Some(KEY_MAGIC), Some(install_id), Some(key), None) =
            (words.next(), words.next(), words.next(), words.next())
        else {
            return None;
        };
        if !frontend_proof::valid_install_id(install_id) {
            return None;
        }
        let key = Zeroizing::new(frontend_proof::unhex::<INSTALL_KEY_LEN>(key)?);
        if key.iter().all(|byte| *byte == 0) {
            return None;
        }
        Some(Self { install_id: install_id.to_string(), key })
    }

    /// The pipe payload for this key (the launcher writes it).
    pub fn to_payload(&self) -> Zeroizing<String> {
        Zeroizing::new(format!(
            "{KEY_MAGIC} {} {}\n",
            self.install_id,
            frontend_proof::hex(self.key.as_slice())
        ))
    }

    pub fn install_id(&self) -> &str {
        &self.install_id
    }
}

/// Reads one key payload from `reader` (an inherited pipe) to end of file.
/// The caller closes the descriptor right after.
pub fn read_frontend_key(reader: impl Read) -> std::io::Result<FrontendKey> {
    let mut payload = Zeroizing::new(String::new());
    reader.take(MAX_KEY_PAYLOAD + 1).read_to_string(&mut payload)?;
    if payload.len() as u64 > MAX_KEY_PAYLOAD {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "install key payload too long",
        ));
    }
    FrontendKey::parse(&payload).ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "malformed install key payload")
    })
}

/// Gives the daemon the app's install key. Only the first call wins; the
/// daemon keeps the key in memory only. Returns false when a key was set.
pub fn install_frontend_key(mux: &crate::Mux, key: FrontendKey) -> bool {
    mux.control_clients.app_trust.install_key.set(key).is_ok()
}

/// The role a connection declares in step 1 of `client-hello`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum HelloRole {
    /// The app's own control connection; the only role that can be the
    /// verified app.
    Main,
    /// A connection that relays a page's requests; never the verified app.
    PageRelay,
}

/// Per-connection proof state shared with the request handlers.
#[derive(Default)]
struct ConnectionProof {
    token: Option<PeerToken>,
    /// The role from step 1, set once.
    role: OnceLock<HelloRole>,
    /// The install id proved in step 2, set once.
    hello: OnceLock<String>,
    /// Prover A's cached answer.
    signature: OnceLock<bool>,
}

/// The daemon side of `verified_app` (one per daemon, in the registry).
pub(crate) struct AppTrust {
    install_key: OnceLock<FrontendKey>,
    connections: Mutex<HashMap<u64, Arc<ConnectionProof>>>,
    /// A signed daemon inside a signed app accepts only prover A: there a
    /// same-uid process could restart the owner with a key it chose, so the
    /// install-key proof alone must not count (security review, P1).
    signed_build: bool,
}

impl Default for AppTrust {
    fn default() -> Self {
        Self {
            install_key: OnceLock::new(),
            connections: Mutex::new(HashMap::new()),
            signed_build: cmux_link::app_caller::signed_app_build(),
        }
    }
}

impl AppTrust {
    /// A local (Unix socket) connection was accepted. Other transports are
    /// never registered, so they are never the verified app.
    pub(crate) fn connect_local(&self, client: u64, token: Option<PeerToken>) {
        let proof = Arc::new(ConnectionProof { token, ..ConnectionProof::default() });
        self.connections().insert(client, proof);
    }

    /// The connection map. A panic while it was held cannot leave a
    /// half-made entry (each operation is one insert, remove or clone), so
    /// a poisoned lock is still usable.
    fn connections(&self) -> std::sync::MutexGuard<'_, HashMap<u64, Arc<ConnectionProof>>> {
        self.connections.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub(crate) fn disconnect(&self, client: u64) {
        self.connections().remove(&client);
    }

    fn proof(&self, client: u64) -> Option<Arc<ConnectionProof>> {
        self.connections().get(&client).cloned()
    }

    /// Whether `client` is the cmux app: role `main` declared in its
    /// `client-hello`, and prover A on a signed build or the install-key
    /// proof on an unsigned (development) build.
    pub(crate) fn verified_app(&self, client: u64) -> bool {
        let Some(proof) = self.proof(client) else { return false };
        if proof.role.get() != Some(&HelloRole::Main) {
            return false;
        }
        if !self.signed_build {
            // Unsigned (development) builds: the install-key proof only.
            return proof.hello.get().is_some();
        }
        let Some(token) = proof.token else { return false };
        // Outside the registry lock: a few Security framework calls, once.
        *proof
            .signature
            .get_or_init(|| cmux_link::app_caller::verify_containing_app(&token).is_ok())
    }

    /// Marks `client` as a role-main connection proved by an install-key
    /// hello (other modules' tests; the hello itself is tested in
    /// app_trust_tests.rs and tests/frontend_hello.rs).
    #[cfg(test)]
    pub(crate) fn prove_for_test(&self, client: u64, install_id: &str) {
        let proof = Arc::new(ConnectionProof::default());
        let _ = proof.role.set(HelloRole::Main);
        let _ = proof.hello.set(install_id.to_string());
        self.connections().insert(client, proof);
    }
}

impl super::ClientRegistry {
    /// Whether `client` is a local (Unix socket) connection: the transport
    /// fact the apps gate and `verified_app` start from.
    pub(super) fn is_unix(&self, client: u64) -> bool {
        self.state
            .lock()
            .unwrap()
            .clients
            .get(&client)
            .is_some_and(|record| matches!(record.transport, super::ClientTransport::Unix))
    }
}

#[derive(Deserialize)]
struct HelloStart {
    role: HelloRole,
    #[serde(default)]
    install_id: Option<String>,
}

#[derive(Deserialize)]
struct HelloProof {
    install_id: String,
    proof: String,
}

enum GateState {
    /// Step 1 may come; `identified` once the one allowed `identify` came.
    Open { identified: bool },
    /// Step 1 issued a nonce; line 2 must be the proof.
    Challenged { install_id: String, nonce: Zeroizing<[u8; NONCE_LEN]> },
    /// The hello window is over.
    Closed,
}

type Refusal = (&'static str, &'static str);
const REFUSED: Refusal = ("client_hello.refused", "client-hello refused");

/// The hello state machine of ONE connection, owned by its read loop, so
/// ordinary requests pay one enum check and no lock.
pub(super) struct HelloGate {
    local: bool,
    state: GateState,
}

impl HelloGate {
    /// Ends the hello window (a line the connection's admission refused
    /// still counts as a line).
    pub(super) fn close(&mut self) {
        self.state = GateState::Closed;
    }

    pub(super) fn new(local: bool) -> Self {
        Self { local, state: GateState::Open { identified: false } }
    }

    /// Sees every request line before dispatch. Returns the reply for a
    /// `client-hello` line inside the hello window (handled here, never
    /// dispatched), else `None` and the line goes on as usual.
    pub(super) fn observe(&mut self, trust: &AppTrust, client: u64, line: &str) -> Option<Value> {
        // After the window closes a late hello is dispatched like any other
        // line and fails there as an unknown command; nothing is scanned.
        if matches!(self.state, GateState::Closed) {
            return None;
        }
        // Any line closes the window unless it is the expected hello step;
        // only `identify` (read-only static facts) may come before step 1,
        // so a client can check the capability first.
        let state = std::mem::replace(&mut self.state, GateState::Closed);
        let value: Value = serde_json::from_str(line).ok()?;
        match value.get("cmd").and_then(Value::as_str) {
            Some(CLIENT_HELLO) => {}
            Some("identify") if matches!(state, GateState::Open { identified: false }) => {
                self.state = GateState::Open { identified: true };
                return None;
            }
            _ => return None,
        }
        let id = value.get("id").cloned();
        let result = if !self.local {
            Err(("client_hello.local_only", "client-hello needs a local socket connection"))
        } else {
            match state {
                GateState::Open { .. } => start(trust, client, value),
                GateState::Challenged { install_id, nonce } => {
                    prove(trust, client, value, &install_id, &nonce)
                        .map(|data| (GateState::Closed, data))
                }
                GateState::Closed => Err(REFUSED),
            }
        };
        Some(match result {
            Ok((next, data)) => {
                self.state = next;
                json!({ "id": id, "ok": true, "data": data })
            }
            Err((code, message)) => {
                json!({ "id": id, "ok": false, "error": message, "error_code": code })
            }
        })
    }
}

/// Step 1: fix the role. A role-main hello that names an install id always
/// gets a fresh nonce, known id or not, so step 1 never tells a caller
/// which install id this daemon holds; a wrong id fails only at step 2.
fn start(trust: &AppTrust, client: u64, value: Value) -> Result<(GateState, Value), Refusal> {
    let request: HelloStart = serde_json::from_value(value)
        .map_err(|_| ("bad_request", "client-hello needs role main or page_relay"))?;
    if request.install_id.as_deref().is_some_and(|id| !frontend_proof::valid_install_id(id)) {
        return Err(("bad_request", "client-hello install_id is malformed"));
    }
    let connection = trust.proof(client).ok_or(REFUSED)?;
    connection.role.set(request.role).map_err(|_| REFUSED)?;
    let mut data = json!({ "connection_id": client.to_string() });
    let (HelloRole::Main, Some(install_id)) = (request.role, request.install_id) else {
        return Ok((GateState::Closed, data));
    };
    let mut nonce = Zeroizing::new([0u8; NONCE_LEN]);
    getrandom::fill(nonce.as_mut_slice())
        .map_err(|_| ("client_hello.unavailable", "no randomness for a nonce"))?;
    data["nonce"] = Value::String(frontend_proof::hex(nonce.as_slice()));
    Ok((GateState::Challenged { install_id, nonce }, data))
}

/// Step 2: check the proof over this connection's nonce. Every check runs
/// whatever the earlier ones said (a daemon with no key checks against a
/// throwaway key), so the time taken does not tell which one failed.
fn prove(
    trust: &AppTrust,
    client: u64,
    value: Value,
    install_id: &str,
    nonce: &[u8; NONCE_LEN],
) -> Result<Value, Refusal> {
    let request: HelloProof = serde_json::from_value(value).map_err(|_| REFUSED)?;
    let mut throwaway = Zeroizing::new([0u8; INSTALL_KEY_LEN]);
    let (key, held_id) = match trust.install_key.get() {
        Some(key) => (key.key.as_slice(), key.install_id.as_str()),
        None => {
            getrandom::fill(throwaway.as_mut_slice()).map_err(|_| REFUSED)?;
            (throwaway.as_slice(), "")
        }
    };
    let mac_ok = frontend_proof::verify_hello_proof(key, install_id, nonce, &request.proof);
    let same_request = cmux_local_auth::tokens_match(&request.install_id, install_id);
    let held = cmux_local_auth::tokens_match(install_id, held_id);
    let proved = mac_ok & same_request & held & trust.install_key.get().is_some();
    let connection = trust.proof(client).ok_or(REFUSED)?;
    if !proved || connection.hello.set(install_id.to_string()).is_err() {
        return Err(REFUSED);
    }
    Ok(json!({ "verified": true, "install_id": install_id, "connection_id": client.to_string() }))
}

#[cfg(test)]
#[path = "app_trust_tests.rs"]
mod tests;
