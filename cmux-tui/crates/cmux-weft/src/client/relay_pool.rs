//! The client's relay connections: one WebSocket per relay URL in use,
//! opened on demand, re-opened with the latest ticket after any failure.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::Message;

use crate::relay_frame;

const OUTBOUND_QUEUE: usize = 1024;
const PING_EVERY: Duration = Duration::from_secs(15);

/// A datagram from a relay: the sender's WireGuard key and the payload.
pub type Inbound = ([u8; 32], Vec<u8>);

struct Connection {
    outbound: mpsc::Sender<Vec<u8>>,
    task: JoinHandle<()>,
}

pub struct RelayPool {
    connections: Mutex<HashMap<String, Connection>>,
    /// The current ticket; `None` while there is none (pending or rotating).
    ticket: watch::Sender<Option<String>>,
    inbound: mpsc::Sender<Inbound>,
}

impl RelayPool {
    pub fn new(inbound: mpsc::Sender<Inbound>) -> Arc<Self> {
        let (ticket, _) = watch::channel(None);
        Arc::new(Self { connections: Mutex::new(HashMap::new()), ticket, inbound })
    }

    /// Install a ticket. Connections pick it up on their next (re)connect;
    /// a changed ticket also makes each connection re-register now.
    pub fn set_ticket(&self, ticket: Option<String>) {
        self.ticket.send_if_modified(|current| {
            // Every netmap reissues the ticket with a later expiry. Only a new
            // key or tailnet (or none at all) notifies the connections; a mere
            // refresh is stored silently and used on the next reconnect.
            let changed = match (current.as_deref(), ticket.as_deref()) {
                (Some(old), Some(new)) => !same_key(old, new),
                (None, None) => false,
                _ => true,
            };
            *current = ticket.clone();
            changed
        });
    }

    /// Make sure a connection to `url` exists (the home relay is always open).
    pub fn ensure(self: &Arc<Self>, url: &str) {
        let Ok(mut connections) = self.connections.lock() else { return };
        if connections.get(url).is_some_and(|connection| !connection.task.is_finished()) {
            return;
        }
        let (outbound, receiver) = mpsc::channel(OUTBOUND_QUEUE);
        let task = tokio::spawn(run(
            url.to_owned(),
            self.ticket.subscribe(),
            receiver,
            self.inbound.clone(),
        ));
        connections.insert(url.to_owned(), Connection { outbound, task });
    }

    /// Send `datagram` to `peer` through `url`. Dropped if the queue is full.
    pub fn send(self: &Arc<Self>, url: &str, peer: &[u8; 32], datagram: &[u8]) {
        self.ensure(url);
        let Ok(connections) = self.connections.lock() else { return };
        if let Some(connection) = connections.get(url) {
            let _ = connection.outbound.try_send(relay_frame::encode(peer, datagram));
        }
    }

    /// Close every connection (key rotation, shutdown).
    pub fn reset(&self) {
        if let Ok(mut connections) = self.connections.lock() {
            for (_, connection) in connections.drain() {
                connection.task.abort();
            }
        }
    }
}

impl Drop for RelayPool {
    fn drop(&mut self) {
        self.reset();
    }
}

/// Whether two tickets name the same tailnet and key (expiry may differ).
fn same_key(old: &str, new: &str) -> bool {
    let key_of = |text: &str| {
        let payload = text.split_once('.')?.0;
        let bytes = crate::b64::decode_url(payload)?;
        let value: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
        Some((value.get("t")?.as_str()?.to_owned(), value.get("k")?.as_str()?.to_owned()))
    };
    matches!((key_of(old), key_of(new)), (Some(a), Some(b)) if a == b)
}

async fn run(
    url: String,
    mut ticket: watch::Receiver<Option<String>>,
    mut outbound: mpsc::Receiver<Vec<u8>>,
    inbound: mpsc::Sender<Inbound>,
) {
    let mut backoff = Duration::from_millis(200);
    loop {
        let current = ticket.borrow_and_update().clone();
        let Some(current) = current else {
            // No ticket: wait for one, discarding what queues meanwhile.
            tokio::select! {
                changed = ticket.changed() => if changed.is_err() { return },
                frame = outbound.recv() => if frame.is_none() { return },
            }
            continue;
        };
        match session(&url, &current, &mut ticket, &mut outbound, &inbound).await {
            SessionEnd::Stop => return,
            SessionEnd::Reconnect { healthy } => {
                if healthy {
                    backoff = Duration::from_millis(200);
                }
                // Bounded, cancellable retry delay (the task is aborted on reset).
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(Duration::from_secs(5));
            }
        }
    }
}

enum SessionEnd {
    Stop,
    Reconnect { healthy: bool },
}

async fn session(
    url: &str,
    ticket_text: &str,
    ticket: &mut watch::Receiver<Option<String>>,
    outbound: &mut mpsc::Receiver<Vec<u8>>,
    inbound: &mpsc::Sender<Inbound>,
) -> SessionEnd {
    let connect =
        tokio::time::timeout(Duration::from_secs(10), tokio_tungstenite::connect_async(url)).await;
    let Ok(Ok((socket, _))) = connect else { return SessionEnd::Reconnect { healthy: false } };
    let (mut sink, mut stream) = socket.split();
    if sink.send(Message::Text(ticket_text.to_owned().into())).await.is_err() {
        return SessionEnd::Reconnect { healthy: false };
    }
    match tokio::time::timeout(Duration::from_secs(10), stream.next()).await {
        Ok(Some(Ok(Message::Text(text)))) if text.as_str() == "ok" => {}
        Ok(Some(Ok(Message::Text(text)))) => {
            eprintln!("weft: relay {url} refused the ticket: {}", text.as_str());
            return SessionEnd::Reconnect { healthy: false };
        }
        _ => return SessionEnd::Reconnect { healthy: false },
    }
    let mut ping = tokio::time::interval(PING_EVERY);
    ping.tick().await;
    loop {
        tokio::select! {
            changed = ticket.changed() => {
                if changed.is_err() {
                    return SessionEnd::Stop;
                }
                // A new key or tailnet: register again with the new ticket.
                return SessionEnd::Reconnect { healthy: true };
            }
            frame = outbound.recv() => {
                let Some(frame) = frame else { return SessionEnd::Stop };
                if sink.send(Message::Binary(frame.into())).await.is_err() {
                    return SessionEnd::Reconnect { healthy: true };
                }
            }
            _ = ping.tick() => {
                if sink.send(Message::Ping(Vec::new().into())).await.is_err() {
                    return SessionEnd::Reconnect { healthy: true };
                }
            }
            message = stream.next() => {
                match message {
                    Some(Ok(Message::Binary(frame))) => {
                        if let Some((sender, datagram)) = relay_frame::decode(&frame) {
                            let _ = inbound.try_send((sender, datagram.to_vec()));
                        }
                    }
                    Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_))) => {}
                    Some(Ok(Message::Text(_))) => {}
                    Some(Ok(Message::Close(_)) | Err(_)) | None => return SessionEnd::Reconnect { healthy: true },
                }
            }
        }
    }
}
