//! Transient guest OS-opener requests. URLs never enter the session journal or
//! notification ledger. A live frontend explicitly subscribes to its terminal
//! projections, claims each request, then acknowledges actual browser delivery.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{MessageWriter, Mux, Response, send_response};
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
        let mut state = self.0.lock().unwrap();
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
            let mut state = self.0.lock().unwrap();
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
        let mut state = self.0.lock().unwrap();
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
        let mut state = self.0.lock().unwrap();
        let Some(pending) = state.pending.get(id) else {
            return false;
        };
        if !pending.claimed || Instant::now() >= pending.deadline {
            return false;
        }
        let pending = state.pending.remove(id).unwrap();
        pending.reply.try_send(opened).is_ok()
    }

    fn cancel(&self, id: &str) {
        self.0.lock().unwrap().pending.remove(id);
    }

    pub(super) fn disconnect(&self, client: u64) {
        let mut state = self.0.lock().unwrap();
        state.subscribers.remove(&client);
        state.pending.retain(|_, pending| pending.client != client);
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
    writer: &MessageWriter,
) -> bool {
    let terminal_id = TerminalPublicId::parse(terminal.clone()).ok();
    let valid = mux.control_clients.is_unix(client)
        && validate_url(&url)
        && terminal_id.as_ref().and_then(|id| mux.resource_surface_for_terminal(id)).is_some();
    let pending = valid.then(|| mux.control_clients.url_opens.prepare(&terminal, &url)).flatten();
    let Some((request_id, receiver)) = pending else {
        return respond(writer, id, false);
    };
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let cleanup_id = request_id.clone();
    let spawned = std::thread::Builder::new().name("mux-url-open".into()).spawn(move || {
        let opened = receiver.recv_timeout(DEADLINE).unwrap_or(false);
        worker_mux.control_clients.url_opens.cancel(&request_id);
        respond(&worker_writer, worker_id, opened);
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
mod tests {
    use super::super::tests::captured_writer;
    use super::*;

    const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";

    #[test]
    fn url_open_has_no_headless_or_wrong_terminal_queue() {
        let broker = URLRequests::default();
        assert!(broker.prepare(TERMINAL, "https://github.com/login/device").is_none());
        let (writer, _) = captured_writer();
        broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
        assert!(broker.prepare("term_other", "https://example.com").is_none());
    }

    #[test]
    fn url_open_requires_claim_and_actual_delivery_ack() {
        let broker = URLRequests::default();
        let (writer, _) = captured_writer();
        broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
        let (id, receiver) = broker.prepare(TERMINAL, "https://example.com/?code=abc").unwrap();
        assert!(!broker.complete(&id, true));
        assert!(broker.claim(&id));
        assert!(!broker.claim(&id));
        assert!(broker.complete(&id, true));
        assert!(receiver.recv().unwrap());
        assert!(!broker.claim(&id));
    }

    #[test]
    fn url_open_does_not_guess_between_frontends() {
        let broker = URLRequests::default();
        let (first, _) = captured_writer();
        let (second, _) = captured_writer();
        broker.subscribe(1, vec![TERMINAL.into()], first).unwrap();
        broker.subscribe(2, vec![TERMINAL.into()], second).unwrap();
        assert!(broker.prepare(TERMINAL, "https://example.com").is_none());
        broker.disconnect(2);
        assert!(broker.prepare(TERMINAL, "https://example.com").is_some());
    }

    #[test]
    fn url_open_disconnect_deadline_and_capacity_are_bounded() {
        let broker = URLRequests::default();
        let (writer, _) = captured_writer();
        broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
        let mut requests = Vec::new();
        for _ in 0..CAPACITY {
            requests.push(broker.prepare(TERMINAL, "https://example.com").unwrap());
        }
        assert!(broker.prepare(TERMINAL, "https://example.com").is_none());
        broker.0.lock().unwrap().pending.get_mut(&requests[0].0).unwrap().deadline = Instant::now();
        assert!(!broker.claim(&requests[0].0));
        broker.disconnect(1);
        for (_, receiver) in requests {
            assert!(receiver.recv().is_err());
        }
        assert!(broker.0.lock().unwrap().pending.is_empty());
    }

    #[test]
    fn url_open_validates_without_rewriting_auth_url_bytes() {
        assert!(validate_url("HTTPS://github.com/login/device?state=AbC%2F%2b#fragment"));
        for url in [
            "file:///tmp/file",
            "javascript:alert(1)",
            "https://",
            "https://foo/\ncommand",
            "https://foo/a b",
        ] {
            assert!(!validate_url(url));
        }
        assert!(!validate_url(&format!("https://example.com/{}", "a".repeat(16_384))));
    }
}
