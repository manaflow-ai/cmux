//! Transient guest OS-opener requests. URLs never enter the session journal or
//! notification ledger. A live frontend explicitly subscribes to its terminal
//! projections, claims each request, then acknowledges actual browser delivery.

use crate::panic_free::RecoverPoison;
use cmux_threads::checked::ipc_reply;
use cmux_threads::checked::sync as waits;
use cmux_threads::sync::Mutex;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::terminal_io_wire::{UrlOpenClaimParams, UrlOpenResultParams, UrlOpenSubscribeParams};
use super::{AsyncReply, Command, MessageWriter, Mux, Response, send_response};
use crate::resource::TerminalPublicId;

const DEADLINE: Duration = Duration::from_secs(5);
const CAPACITY: usize = 16;

struct Subscriber {
    terminals: HashSet<String>,
    writer: MessageWriter,
}

struct Pending {
    client: u64,
    deadline: Instant,
    claimed: bool,
    reply: mpsc::SyncSender<bool>,
}

#[derive(Default)]
struct State {
    subscribers: BTreeMap<u64, Subscriber>,
    pending: HashMap<String, Pending>,
}

#[derive(Default)]
pub(super) struct URLRequests(Mutex<State>);

impl URLRequests {
    pub(super) fn subscribe(
        &self,
        client: u64,
        terminals: Vec<String>,
        writer: MessageWriter,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(terminals.len() <= 256, "too many URL opener terminals");
        for terminal in &terminals {
            TerminalPublicId::parse(terminal.clone())?;
        }
        let mut state = self.0.lock().recover_poison();
        anyhow::ensure!(
            state.subscribers.len() < CAPACITY || state.subscribers.contains_key(&client),
            "too many URL opener clients"
        );
        state
            .subscribers
            .insert(client, Subscriber { terminals: terminals.into_iter().collect(), writer });
        Ok(())
    }

    fn prepare(&self, terminal: &str, url: &str) -> Option<(String, mpsc::Receiver<bool>)> {
        let (id, writer, receiver) = {
            let mut state = self.0.lock().recover_poison();
            if state.pending.len() >= CAPACITY {
                return None;
            }
            let mut candidates = state.subscribers.iter().filter(|(_, subscriber)| {
                subscriber.terminals.contains(terminal) && subscriber.writer.is_open()
            });
            let (&client, subscriber) = candidates.next()?;
            // A shared terminal has no reliable physical-Mac origin. Never
            // send its authentication URL to an arbitrary other frontend.
            if candidates.next().is_some() {
                return None;
            }
            let writer = subscriber.writer.clone();
            // An unguessable capability lets a frontend acknowledge on another
            // connection through the same authenticated mux tunnel.
            let id = crate::workspace_registry::new_uuid_v4();
            let (sender, receiver) = mpsc::sync_channel(1);
            state.pending.insert(
                id.clone(),
                Pending {
                    client,
                    deadline: Instant::now() + DEADLINE,
                    claimed: false,
                    reply: sender,
                },
            );
            (id, writer, receiver)
        };
        if writer.send_url_open(&id, terminal, url).is_err() {
            self.cancel(&id);
            return None;
        }
        Some((id, receiver))
    }

    /// A buffered event cannot open a stale auth URL after its caller timed out.
    pub(super) fn claim(&self, id: &str) -> bool {
        let mut state = self.0.lock().recover_poison();
        let Some(pending) = state.pending.get_mut(id) else {
            return false;
        };
        if pending.claimed || Instant::now() >= pending.deadline {
            return false;
        }
        pending.claimed = true;
        true
    }

    pub(super) fn complete(&self, id: &str, opened: bool) -> bool {
        let mut state = self.0.lock().recover_poison();
        let Some(pending) = state.pending.get(id) else {
            return false;
        };
        if !pending.claimed || Instant::now() >= pending.deadline {
            return false;
        }
        state.pending.remove(id).is_some_and(|pending| pending.reply.try_send(opened).is_ok())
    }

    fn cancel(&self, id: &str) {
        self.0.lock().recover_poison().pending.remove(id);
    }

    pub(super) fn disconnect(&self, client: u64) {
        let mut state = self.0.lock().recover_poison();
        state.subscribers.remove(&client);
        state.pending.retain(|_, pending| pending.client != client);
    }
}

impl MessageWriter {
    fn send_url_open(&self, request_id: &str, terminal_id: &str, url: &str) -> std::io::Result<()> {
        self.send_control(&json!({
            "event": "url-open", "request_id": request_id, "terminal_id": terminal_id, "url": url,
        }))
    }
}

/// The frontend side: `url-open-subscribe`, `url-open-claim` and
/// `url-open-result`.
pub(super) fn handle(
    mux: &Mux,
    client: u64,
    cmd: Command,
    writer: &MessageWriter,
) -> anyhow::Result<Value> {
    let opens = &mux.control_clients.url_opens;
    match cmd {
        Command::UrlOpenSubscribe(UrlOpenSubscribeParams { terminal_ids }) => {
            opens.subscribe(client, terminal_ids, writer.clone())?;
            Ok(json!({"url_open_ready": true}))
        }
        Command::UrlOpenClaim(UrlOpenClaimParams { request_id }) => {
            Ok(json!({"claimed": opens.claim(&request_id)}))
        }
        Command::UrlOpenResult(UrlOpenResultParams { request_id, opened }) => {
            Ok(json!({"accepted": opens.complete(&request_id, opened)}))
        }
        _ => anyhow::bail!("not a URL opener command"),
    }
}

fn validate_url(raw: &str) -> bool {
    raw.len() <= 16_384
        && !raw.chars().any(|c| c.is_control() || c.is_whitespace())
        && url::Url::parse(raw)
            .is_ok_and(|url| matches!(url.scheme(), "http" | "https") && url.host_str().is_some())
}

/// Only this bounded wait leaves the normal command dispatcher; ack/claim and
/// disconnect are independent control messages and never wait on the opener.
pub(super) fn start(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    terminal: String,
    url: String,
    reply: AsyncReply,
    writer: &MessageWriter,
) -> bool {
    let terminal_id = TerminalPublicId::parse(terminal.clone()).ok();
    let valid = mux.control_clients.is_unix(client)
        && validate_url(&url)
        && terminal_id.as_ref().and_then(|id| mux.resource_surface_for_terminal(id)).is_some();
    let pending = valid.then(|| mux.control_clients.url_opens.prepare(&terminal, &url)).flatten();
    let Some((request_id, receiver)) = pending else {
        return reply.reply(|| respond(writer, id, false));
    };
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let cleanup_id = request_id.clone();
    let reply = reply.hand_to_worker();
    let spawned = mux.request_qos().spawn_helper("mux-url-open", None, move || {
        let reply = reply.start();
        let _lock_scope = reply.enter_lock_scope();
        // Waits on the app, another process.
        let opened = ipc_reply(|| waits::recv_timeout(&receiver, DEADLINE)).unwrap_or(false);
        worker_mux.control_clients.url_opens.cancel(&request_id);
        reply.reply(|| respond(&worker_writer, worker_id, opened));
    });
    if spawned.is_err() {
        mux.control_clients.url_opens.cancel(&cleanup_id);
        return respond(writer, id, false);
    }
    true
}

fn respond(writer: &MessageWriter, id: Option<Value>, opened: bool) -> bool {
    send_response(
        writer,
        Response {
            id,
            ok: true,
            data: Some(json!({"opened": opened})),
            error: None,
            error_code: None,
            error_delivery: None,
        },
    )
}

#[cfg(test)]
#[path = "url_open_tests.rs"]
mod tests;
