//! The dialer's standby relay socket (`CMUX_RELAY_DIAL_STANDBY=1`; off by default). A relay dial
//! opens its control socket first: the TCP connect and the WebSocket upgrade, two round trips
//! before the Connect can go (`ttfc_dial_relay_ms`, 143 ms on the lte profile). Here a dial that
//! opened one leaves another socket open on the same relay for the next dial, which takes it and
//! skips both.
//!
//! The socket waits unattached, which only a relay with a pre-attach hold allows
//! (`CMUX_RELAY_PREATTACH_HOLD_SECONDS`): it answers a `Ping` before the first register, connect
//! or join, each within its handshake timeout. The standby pings every [`PING_EVERY`] and is
//! replaced after [`KEEP_FOR`], so the relay's hold must be longer. A relay without the hold
//! answers the first `Ping` with an error; the standby stops for that endpoint for this process,
//! so it never redials in a loop. A standby that dies on its transport is not redialed: the next
//! dial opens its own socket and leaves a new standby.
//!
//! Cost while on: one idle socket per relay endpoint and message limit, a 40-byte `Ping` every
//! [`PING_EVERY`], and one reconnect every [`KEEP_FOR`].

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use cmux_remote_protocol::RelayControl;
use tokio::sync::oneshot;
use tokio::time::Instant;
use url::Url;

use super::{
    RELAY_CONNECT_TIMEOUT, RelayCredentialSource, RelaySocket, RelayTls, connect_provider_control,
    read_control, send_control,
};

/// Under the relay's 10 s handshake timeout, which bounds each wait between messages.
const PING_EVERY: Duration = Duration::from_secs(4);
/// A standby's own Pong this late means a dead relay path.
const PONG_WAIT: Duration = Duration::from_secs(3);
/// A standby is replaced at this age; the relay's pre-attach hold must be longer.
const KEEP_FOR: Duration = Duration::from_secs(50);

type Key = (String, usize);

struct Slot {
    id: u64,
    hand: oneshot::Sender<oneshot::Sender<RelaySocket>>,
}

static SLOTS: LazyLock<Mutex<HashMap<Key, Slot>>> = LazyLock::new(Mutex::default);
/// Endpoints whose relay refused a `Ping` before an attach (no pre-attach hold).
static REFUSED: LazyLock<Mutex<HashSet<String>>> = LazyLock::new(Mutex::default);
static NEXT_ID: AtomicU64 = AtomicU64::new(1);

/// Whether dials leave a standby socket for the next one.
pub(super) fn dial_standby_wanted() -> bool {
    std::env::var_os("CMUX_RELAY_DIAL_STANDBY").is_some_and(|value| value == "1")
}

/// Opens a standby socket on `endpoint` in the background, unless one is open or opening, or
/// the relay refused one. Needs a Tokio runtime; off one it does nothing.
pub(super) fn prime(
    endpoint: &Url,
    credentials: &RelayCredentialSource,
    maximum_message_bytes: usize,
    tls: &RelayTls,
) {
    let Ok(runtime) = tokio::runtime::Handle::try_current() else {
        return;
    };
    let key = (endpoint.as_str().to_owned(), maximum_message_bytes);
    if REFUSED.lock().is_ok_and(|refused| refused.contains(&key.0)) {
        return;
    }
    let (hand, wanted) = oneshot::channel();
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    {
        let Ok(mut slots) = SLOTS.lock() else {
            return;
        };
        if slots.contains_key(&key) {
            return;
        }
        slots.insert(key.clone(), Slot { id, hand });
    }
    let standby = Standby {
        key,
        id,
        endpoint: endpoint.clone(),
        credentials: credentials.clone(),
        tls: tls.clone(),
    };
    runtime.spawn(standby.run(wanted));
}

/// The standby socket on `endpoint`, if one is open (or opening: then this waits for it, as long
/// as a fresh dial would). `None` sends the caller to its own dial.
pub(super) async fn take(endpoint: &Url, maximum_message_bytes: usize) -> Option<RelaySocket> {
    let key = (endpoint.as_str().to_owned(), maximum_message_bytes);
    let slot = SLOTS.lock().ok()?.remove(&key)?;
    let (reply, socket) = oneshot::channel();
    slot.hand.send(reply).ok()?;
    tokio::time::timeout(RELAY_CONNECT_TIMEOUT + PONG_WAIT, socket).await.ok()?.ok()
}

struct Standby {
    key: Key,
    id: u64,
    endpoint: Url,
    credentials: RelayCredentialSource,
    tls: RelayTls,
}

impl Standby {
    async fn run(self, mut wanted: oneshot::Receiver<oneshot::Sender<RelaySocket>>) {
        let Ok(mut socket) =
            connect_provider_control(&self.endpoint, &self.credentials, self.key.1, &self.tls)
                .await
        else {
            self.forget();
            return;
        };
        let born = Instant::now();
        let mut nonce = 0_u64;
        let mut outstanding: Option<(u64, Instant)> = None;
        let mut tick = tokio::time::interval_at(born + PING_EVERY, PING_EVERY);
        loop {
            tokio::select! {
                biased;
                asked = &mut wanted => {
                    // Taken (or the slot was dropped): hand the socket over once its own Pong is
                    // in, so the dial's first read is the relay's answer to it.
                    if let Ok(reply) = asked
                        && (outstanding.is_none() || settle(&mut socket, outstanding).await)
                    {
                        let _ = reply.send(socket);
                    }
                    return;
                }
                _ = tick.tick() => {
                    if born.elapsed() >= KEEP_FOR {
                        self.forget();
                        drop(socket);
                        prime(&self.endpoint, &self.credentials, self.key.1, &self.tls);
                        return;
                    }
                    if outstanding.is_some_and(|(_, sent)| sent.elapsed() >= PONG_WAIT) {
                        self.forget();
                        return;
                    }
                    nonce += 1;
                    if send_control(&mut socket, &RelayControl::Ping { nonce }).await.is_err() {
                        self.forget();
                        return;
                    }
                    outstanding = Some((nonce, Instant::now()));
                }
                read = read_control(&mut socket) => match read {
                    Ok(RelayControl::Pong { nonce: answered })
                        if outstanding.is_some_and(|(sent, _)| sent == answered) =>
                    {
                        outstanding = None;
                    }
                    Ok(RelayControl::Pong { .. }) => {}
                    Ok(RelayControl::Error { .. }) => {
                        // No pre-attach hold on this relay: stop for this endpoint.
                        if let Ok(mut refused) = REFUSED.lock() {
                            refused.insert(self.key.0.clone());
                        }
                        self.forget();
                        return;
                    }
                    _ => {
                        self.forget();
                        return;
                    }
                },
            }
        }
    }

    /// Drops this standby's slot, if it is still this one's.
    fn forget(&self) {
        if let Ok(mut slots) = SLOTS.lock()
            && slots.get(&self.key).is_some_and(|slot| slot.id == self.id)
        {
            slots.remove(&self.key);
        }
    }
}

/// Reads up to the outstanding `Ping`'s `Pong`; false when the relay does not answer in time.
async fn settle(socket: &mut RelaySocket, outstanding: Option<(u64, Instant)>) -> bool {
    let Some((nonce, _)) = outstanding else {
        return true;
    };
    tokio::time::timeout(PONG_WAIT, async {
        loop {
            match read_control(socket).await {
                Ok(RelayControl::Pong { nonce: answered }) if answered == nonce => return true,
                Ok(RelayControl::Pong { .. }) => {}
                _ => return false,
            }
        }
    })
    .await
    .unwrap_or(false)
}
