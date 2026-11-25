//! Calls this machine runs for another of the person's machines, over the hub carrier: an agent
//! whose loop runs on one machine (a VM, say) uses Computer Use on the Mac the person sits at,
//! with no ssh and no peer set up by hand. A hub carrier circuit that names
//! [`CircuitService::MachineCall`] is answered here, in the daemon, by one task per circuit: no
//! process is started per call.
//!
//! ```text
//! agent -> acpmux computer-use-mcp (machine: "my-mac")     the machine the agent runs on, A
//!       -> _acpmux/computer_use_call on A's unix socket     (server/computer_use_relay.rs)
//!       -> a hub carrier stream naming this service         (Noise, pinned to the platform's key)
//!       -> this module on the Mac, B: one JSON line in, one out
//!       -> B's cmux-tui daemon (computer-use-endpoint) -> B's worker
//! ```
//!
//! What grants what, all on B and default deny:
//!
//! - The carrier's Noise handshake proves the dialer is one of this person's live machines (the
//!   platform's `peers`), and B's own read of the hub's book must list it too.
//! - The person on B granted "control for my other machines signed in to this account"
//!   (`signedInMachines`, `session_service.rs`): the same one-click grant that lets those
//!   machines open workspaces here. Until then a circuit is refused with the reason and B's app
//!   shows its one ask. Signing in never grants it.
//! - A call then runs exactly as one from a paired machine does (`computer_use_relay::run_here`):
//!   the origin `{"kind":"remote","machine":<the book's host name>,"same_account":true}` comes
//!   from the proof above, never from the request; B's control consent, Computer Use settings
//!   (`computerUse.allowOwnMachines`), deny list and approvals all still apply.
//!
//! The wire: each request is one line `{"id":N,"method":M,"params":{..}}`, each answer one line
//! `{"id":N,"result":..}` or `{"id":N,"error":{code,message,data}}`. Methods are a fixed list
//! ([`METHODS`]). The Computer Use methods spawn no process and take no path or command;
//! [`FILES_CALL`] reads and writes files and runs one command, under the hand's policy for a
//! person's machine (`machine_files.rs` says what it may do).
//! Requests on one circuit run one at a time, in order; a caller that wants two at once opens two
//! streams (each is one frame on the machine's kept circuit).

use std::future::Future;
use std::sync::{Arc, Weak};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};

use crate::cli::cloud_join::{CONSENT_REQUIRED, SIGNED_IN_MACHINES};
use crate::hub::Hub;
use crate::hub_carrier::{CircuitService, HubStream, MachineCallGate, ServiceRefusal};
use crate::rpc::RpcError;
use crate::session_service::{CONSENT_DECLINED, Decision};

/// One Computer Use tool call here (`computer_use_relay::run_here`).
pub const COMPUTER_USE_CALL: &str = "computer_use_call";
/// Whether Computer Use is on here.
pub const COMPUTER_USE_STATE: &str = "computer_use_state";
/// One file or command action here (`machine_files.rs`).
pub const FILES_CALL: &str = "files_call";
/// Every method the service answers.
pub const METHODS: &[&str] = &[COMPUTER_USE_CALL, COMPUTER_USE_STATE, FILES_CALL];

/// The longest request line: a tool's name and arguments, or one file's new text.
const MAX_REQUEST_BYTES: usize = 16 << 20;
/// The longest answer line a dialer reads: a screenshot is a few MiB of base64.
const MAX_ANSWER_BYTES: usize = 64 << 20;
/// The circuit's in-process buffer, each way.
const PIPE_BYTES: usize = 256 * 1024;

/// Whether another of the person's machines may have this one run calls, given this machine's
/// consent status: the workspace grant's own rule (`session_service::decide`), with the refusal
/// worded for this service. The bool is whether the refusal is the machine's one ask. A join from
/// another device admits workspaces there, never control: only the person's own grant does.
pub fn decide(consent: &Value, account: Option<&str>) -> Result<(), (ServiceRefusal, bool)> {
    match crate::session_service::decide(consent, account, false) {
        Decision::Admit => Ok(()),
        Decision::Refuse { refusal, ask } => {
            let message = if refusal.reason == CONSENT_DECLINED {
                "the person on that machine has not allowed control from their other machines; \
                 they can turn it on there, in Settings > Devices"
            } else {
                "waiting for the person on that machine to allow control from their other \
                 machines: cmux there asks once"
            };
            Err((ServiceRefusal::new(&refusal.reason, message), ask))
        }
    }
}

/// Read one line of at most `max` bytes: None at a clean end, an error for a longer line.
async fn read_line<R>(reader: &mut BufReader<R>, max: usize) -> std::io::Result<Option<Vec<u8>>>
where
    R: AsyncRead + Unpin,
{
    let mut line = Vec::new();
    loop {
        let chunk = reader.fill_buf().await?;
        if chunk.is_empty() {
            return Ok(None);
        }
        let (take, done) = match chunk.iter().position(|b| *b == b'\n') {
            Some(at) => (at + 1, true),
            None => (chunk.len(), false),
        };
        if line.len() + take > max + 1 {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "line too long"));
        }
        line.extend_from_slice(chunk.get(..take).unwrap_or(chunk));
        reader.consume(take);
        if done {
            line.pop();
            return Ok(Some(line));
        }
    }
}

/// Answer the requests of one circuit until it ends: `run(method, params)` for each method of
/// [`METHODS`], a refusal for anything else. A line that is not a request ends the circuit.
pub async fn serve<S, F, Fut>(io: S, run: F)
where
    S: AsyncRead + AsyncWrite + Send + Unpin,
    F: Fn(String, Value) -> Fut,
    Fut: Future<Output = Result<Value, RpcError>>,
{
    let (read, mut write) = tokio::io::split(io);
    let mut reader = BufReader::new(read);
    while let Ok(Some(line)) = read_line(&mut reader, MAX_REQUEST_BYTES).await {
        let Ok(request) = serde_json::from_slice::<Value>(&line) else {
            return;
        };
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let method = request.get("method").and_then(Value::as_str).unwrap_or_default();
        let answer = if METHODS.contains(&method) {
            let params = request.get("params").cloned().unwrap_or_else(|| json!({}));
            run(method.to_owned(), params).await
        } else {
            Err(RpcError::method_not_found(method))
        };
        let mut out = match answer {
            Ok(result) => json!({"id": id, "result": result}),
            Err(error) => json!({"id": id, "error": error}),
        }
        .to_string()
        .into_bytes();
        out.push(b'\n');
        if write.write_all(&out).await.is_err() || write.flush().await.is_err() {
            return;
        }
    }
}

/// One request over `io` (a circuit [`serve`] answers): its result, or the far end's error. A
/// circuit that ends first, or an answer that does not come within `wait`, is `Err(None)`.
pub async fn ask<S>(
    io: S,
    method: &str,
    params: Value,
    wait: Duration,
) -> Result<Value, Option<RpcError>>
where
    S: AsyncRead + AsyncWrite + Send + Unpin,
{
    let (read, mut write) = tokio::io::split(io);
    let mut line = json!({"id": 1, "method": method, "params": params}).to_string().into_bytes();
    line.push(b'\n');
    let answer = tokio::time::timeout(wait, async {
        write.write_all(&line).await.ok()?;
        write.flush().await.ok()?;
        read_line(&mut BufReader::new(read), MAX_ANSWER_BYTES).await.ok()?
    })
    .await
    .ok()
    .flatten()
    .ok_or(None)?;
    let mut answer: Value = serde_json::from_slice(&answer).map_err(|_| None)?;
    if let Some(error) = answer.get_mut("error").map(Value::take) {
        return Err(serde_json::from_value::<RpcError>(error).ok());
    }
    answer.get_mut("result").map(Value::take).ok_or(None)
}

fn refused(code: &str, message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"code": code}))
}

/// The hub `daemonId` of the one machine the book lists under `name` (its host name, or the id
/// itself). None when no machine or more than one has that name.
pub fn machine_key(machines: &[(String, String)], name: &str) -> Option<String> {
    let mut found = machines.iter().filter(|(key, host)| host == name || key == name);
    let (key, _) = found.next()?;
    found.next().is_none().then(|| key.clone())
}

/// One request to the machine whose hub `daemonId` is `key`, over a new stream of its carrier
/// circuit. A refusal keeps the far machine's reason as `data.code`; a machine that cannot be
/// reached now, or an answer that did not come, is `data.code: "unreachable"`.
pub async fn request(
    hub: &Hub,
    key: &str,
    method: &str,
    params: Value,
    wait: Duration,
) -> Result<Value, RpcError> {
    let carrier = hub.hub_carrier.get().ok_or_else(|| {
        refused(
            "carrier.off",
            "this machine's hub carrier is off (not signed in, or no WireGuard key)",
        )
    })?;
    let stream = carrier.dial_service(key, CircuitService::MachineCall).await.map_err(|e| {
        let refusal = crate::machine_routes::refusal_of(&e);
        let reason = refusal.get("reason").and_then(Value::as_str).unwrap_or("machine.unreachable");
        let code = if reason == "machine.unreachable" { "unreachable" } else { reason };
        refused(code, refusal.get("error").and_then(Value::as_str).unwrap_or(&e).to_owned())
    })?;
    ask(stream, method, params, wait).await.map_err(|error| {
        error.unwrap_or_else(|| refused("unreachable", "the machine did not answer the call"))
    })
}

/// Whether the person here grants calls from their other machines now, read from this machine's
/// consent record; a first refusal records the machine's one ask, naming `asking`.
async fn granted(asking: String) -> Result<(), ServiceRefusal> {
    tokio::task::spawn_blocking(move || {
        let consent = crate::cli::cloud_join::consent_status_for(&json!({}));
        let account = crate::cli::cloud_join::machine_user_id();
        decide(&consent, account.as_deref()).map_err(|(refusal, ask)| {
            if ask {
                // The app on this machine shows its one ask (`lastRefusal`).
                let _ = crate::cli::cloud_join::record_consent_refusal_from(
                    SIGNED_IN_MACHINES,
                    Some(asking.as_str()),
                );
            }
            refusal
        })
    })
    .await
    .unwrap_or_else(|_| Err(ServiceRefusal::new(CONSENT_REQUIRED, "consent unreadable")))
}

/// The daemon's gate: the hub's book, this machine's consent record, and the Computer Use relay.
pub struct ConfiguredGate {
    hub: Weak<Hub>,
}

impl ConfiguredGate {
    pub fn new(hub: &Arc<Hub>) -> Self {
        Self { hub: Arc::downgrade(hub) }
    }
}

#[async_trait]
impl MachineCallGate for ConfiguredGate {
    async fn open(&self, from: &str) -> Result<HubStream, ServiceRefusal> {
        let hub =
            self.hub.upgrade().ok_or_else(|| ServiceRefusal::new("service.off", "stopping"))?;
        // Defense in depth beside the carrier's handshake, as for a workspace circuit.
        let Some(host) = hub.mesh_book_machine(from) else {
            return Err(ServiceRefusal::new(
                "machine.unlisted",
                "this machine's hub book does not list the asking machine for its account yet; \
                 try again in a moment",
            ));
        };
        granted(host.clone()).await?;
        let (near, far) = tokio::io::duplex(PIPE_BYTES);
        // Ends when the circuit does: the carrier drops `near`, and the read sees the end.
        let serving = serve(far, move |method, params| {
            let machine = host.clone();
            async move {
                // The grant is read again for every request, so one taken back stops a circuit
                // that was opened while it held.
                granted(machine.clone())
                    .await
                    .map_err(|refusal| refused(&refusal.reason, refusal.message))?;
                match method.as_str() {
                    COMPUTER_USE_CALL => {
                        crate::server::computer_use_relay::run_from(&machine, &params).await
                    }
                    FILES_CALL => crate::machine_files::run_from(&params).await,
                    _ => Ok(crate::server::computer_use_relay::state_here().await),
                }
            }
        });
        hub.scope.spawn_named("machine call circuit", serving);
        Ok(near)
    }
}

#[cfg(test)]
#[path = "machine_call_service_tests.rs"]
mod tests;
