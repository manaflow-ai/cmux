//! The client's relay connections: one WebSocket per relay URL in use,
//! opened on demand, re-opened with the latest ticket after any failure.
//!
//! A connection has no timer of its own (p14-energy-077m). Its keepalive
//! rides on the node's one periodic wakeup, the netmap long poll: each time a
//! poll returns, [`RelayPool::keepalive`] pings every session that has been
//! silent both ways for [`PING_AFTER_SILENCE`]. Chromium aligns its timers
//! the same way, so an idle process wakes once for all of them
//! (base/task/sequence_manager/wake_up_queue.cc).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{Sink, SinkExt, Stream, StreamExt};
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::Message;

use crate::relay_frame;

const OUTBOUND_QUEUE: usize = 1024;
/// A session silent both ways this long is pinged at the next netmap poll's
/// return (at most `coord::LONG_POLL` later), so its silence stays under the
/// Fly proxy's idle limit that LONG_POLL is held under.
const PING_AFTER_SILENCE: Duration = Duration::from_secs(15);

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
    /// Bumped by [`RelayPool::keepalive`]; each session pings if silent.
    keepalive: watch::Sender<()>,
}

impl RelayPool {
    pub fn new(inbound: mpsc::Sender<Inbound>) -> Arc<Self> {
        let (ticket, _) = watch::channel(None);
        let (keepalive, _) = watch::channel(());
        Arc::new(Self { connections: Mutex::new(HashMap::new()), ticket, inbound, keepalive })
    }

    /// Ping every session silent for [`PING_AFTER_SILENCE`]. The netmap
    /// follower calls it each time a poll returns.
    pub fn keepalive(&self) {
        self.keepalive.send_replace(());
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
            self.keepalive.subscribe(),
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
    mut keepalive: watch::Receiver<()>,
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
        match session(&url, &current, &mut ticket, &mut outbound, &inbound, &mut keepalive).await {
            SessionEnd::Stop => return,
            SessionEnd::Reconnect { healthy } => {
                if healthy {
                    backoff = Duration::from_millis(200);
                }
                // Bounded, cancellable retry delay (the task is aborted on reset).
                // wakeup-allow: backoff the reconnect delay after a closed or refused session, doubled up to 5 s
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
    keepalive: &mut watch::Receiver<()>,
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
    relay_frames(&mut sink, &mut stream, ticket, outbound, inbound, keepalive).await
}

/// Moves frames between the queues and one registered session until it ends.
/// A keepalive pings only a session with no frame either way for
/// PING_AFTER_SILENCE: traffic keeps the relay's and the proxy's idle timers
/// alive by itself.
async fn relay_frames<S, R, E>(
    sink: &mut S,
    stream: &mut R,
    ticket: &mut watch::Receiver<Option<String>>,
    outbound: &mut mpsc::Receiver<Vec<u8>>,
    inbound: &mpsc::Sender<Inbound>,
    keepalive: &mut watch::Receiver<()>,
) -> SessionEnd
where
    S: Sink<Message> + Unpin,
    R: Stream<Item = Result<Message, E>> + Unpin,
{
    let mut last_frame = tokio::time::Instant::now();
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
                last_frame = tokio::time::Instant::now();
            }
            changed = keepalive.changed() => {
                if changed.is_err() {
                    return SessionEnd::Stop;
                }
                if last_frame.elapsed() >= PING_AFTER_SILENCE {
                    if sink.send(Message::Ping(Vec::new().into())).await.is_err() {
                        return SessionEnd::Reconnect { healthy: true };
                    }
                    last_frame = tokio::time::Instant::now();
                }
            }
            message = stream.next() => {
                last_frame = tokio::time::Instant::now();
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

#[cfg(test)]
mod tests {
    use std::task::Poll;

    use futures_util::{sink, stream};
    use tokio::sync::{mpsc, watch};
    use tokio::time::{Duration, sleep};
    use tokio_tungstenite::tungstenite::Message;

    use super::{PING_AFTER_SILENCE, SessionEnd, relay_frames};

    /// p14-energy-077m: a relay session has no timer. A keepalive (a netmap
    /// poll's return) pings it only after PING_AFTER_SILENCE with no frame;
    /// with no keepalive, a silent session sends nothing at all.
    #[tokio::test(start_paused = true)]
    async fn a_session_pings_only_on_a_keepalive_after_silence() {
        let (sent_tx, mut sent_rx) = mpsc::unbounded_channel::<Message>();
        let mut socket_sink =
            Box::pin(sink::unfold(sent_tx, |sent_tx, message: Message| async move {
                sent_tx.send(message).map_err(|_| ())?;
                Ok::<_, ()>(sent_tx)
            }));
        // The relay sends nothing; the stream stays open.
        let mut socket_stream = stream::poll_fn(|_| Poll::<Option<Result<Message, ()>>>::Pending);
        let (_ticket_tx, mut ticket) = watch::channel(Some("ticket".to_owned()));
        let (outbound_tx, mut outbound) = mpsc::channel(8);
        let (inbound, _inbound_rx) = mpsc::channel(8);
        let (keepalive_tx, mut keepalive) = watch::channel(());
        let session = tokio::spawn(async move {
            relay_frames(
                &mut socket_sink,
                &mut socket_stream,
                &mut ticket,
                &mut outbound,
                &inbound,
                &mut keepalive,
            )
            .await
        });
        // (frames, pings) the session sent since the last count.
        let count = |sent_rx: &mut mpsc::UnboundedReceiver<Message>| {
            let (mut frames, mut pings) = (0, 0);
            while let Ok(message) = sent_rx.try_recv() {
                match message {
                    Message::Ping(_) => pings += 1,
                    Message::Binary(_) => frames += 1,
                    other => panic!("unexpected {other:?}"),
                }
            }
            (frames, pings)
        };
        let settle = Duration::from_millis(1);
        for _ in 0..6 {
            sleep(Duration::from_secs(5)).await;
            outbound_tx.send(vec![0; 40]).await.unwrap();
            keepalive_tx.send_replace(());
        }
        sleep(settle).await;
        assert_eq!(count(&mut sent_rx), (6, 0), "keepalives during traffic must not ping");
        sleep(Duration::from_secs(60)).await;
        assert_eq!(count(&mut sent_rx), (0, 0), "a silent session pings nothing by itself");
        keepalive_tx.send_replace(());
        sleep(settle).await;
        assert_eq!(count(&mut sent_rx), (0, 1), "a keepalive after silence pings once");
        keepalive_tx.send_replace(());
        sleep(settle).await;
        assert_eq!(count(&mut sent_rx), (0, 0), "the ping counts as traffic");
        sleep(PING_AFTER_SILENCE).await;
        keepalive_tx.send_replace(());
        sleep(settle).await;
        assert_eq!(count(&mut sent_rx), (0, 1));
        drop(outbound_tx);
        assert!(matches!(session.await.unwrap(), SessionEnd::Stop));
    }
}
