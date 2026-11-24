//! Both peers send a handshake initiation at the same moment (each just moved
//! to a new path, or each reasserts after the other announced one), and both
//! have data waiting. Each answers the other's initiation; the session must
//! still come up. It used to livelock: after answering, a side with queued data
//! and no current session started yet another handshake, which replaced the
//! initiation the peer was answering, so neither side ever accepted a response
//! (boringtun keeps one pending initiation besides the state it answers from).
//! Seen on macOS as a cmux-mobile-link dial that fell through to TURN over TLS
//! and then traded about 18,000 handshakes in 17 s without a session.

use std::collections::VecDeque;
use std::future::Future;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use cmux_wg::testing::config_pair;
use cmux_wg::{Origin, PathId, Received, Underlay, WgNet};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::{Instant, Sleep};

/// One-way delay of the wire. A crossing needs a round trip: each side
/// answers the other's initiation, and starts whatever it starts next, before
/// the answer to its own arrives. With no delay a side would read the answer
/// in the same batch as the initiation, and nothing would cross.
const DELAY: Duration = Duration::from_millis(5);

/// One direction of an in-memory wire, shut until the test opens it.
#[derive(Default)]
struct Wire {
    queue: Mutex<VecDeque<(Instant, Vec<u8>)>>,
    waker: Mutex<Option<Waker>>,
}

/// What the test controls and counts, shared by both ends.
#[derive(Default)]
struct Gate {
    open: AtomicBool,
    initiations: AtomicU64,
    wires: Mutex<Vec<Arc<Wire>>>,
}

impl Gate {
    /// Deliver what is held, and everything from now on.
    fn open(&self) {
        self.open.store(true, Ordering::SeqCst);
        for wire in self.wires.lock().unwrap_or_else(PoisonError::into_inner).iter() {
            if let Some(waker) = wire.waker.lock().unwrap_or_else(PoisonError::into_inner).take() {
                waker.wake();
            }
        }
    }
}

/// One peer's end: sends into `out`, receives from `inbound` [`DELAY`] after
/// the send, and nothing while the gate is shut (so both first initiations
/// are in flight at once and cross).
struct End {
    out: Arc<Wire>,
    inbound: Arc<Wire>,
    peer: SocketAddr,
    gate: Arc<Gate>,
    timer: Option<Pin<Box<Sleep>>>,
}

impl Underlay for End {
    fn send(&mut self, datagram: &[u8]) {
        if datagram.first() == Some(&1) {
            self.gate.initiations.fetch_add(1, Ordering::Relaxed);
        }
        let due = Instant::now() + DELAY;
        let mut queue = self.out.queue.lock().unwrap_or_else(PoisonError::into_inner);
        queue.push_back((due, datagram.to_vec()));
        drop(queue);
        if let Some(waker) = self.out.waker.lock().unwrap_or_else(PoisonError::into_inner).take() {
            waker.wake();
        }
    }

    fn poll_recv(&mut self, cx: &mut Context<'_>, buffer: &mut [u8]) -> Poll<io::Result<Received>> {
        *self.inbound.waker.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(cx.waker().clone());
        if !self.gate.open.load(Ordering::SeqCst) {
            return Poll::Pending;
        }
        let mut queue = self.inbound.queue.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(&(due, _)) = queue.front() else { return Poll::Pending };
        if due > Instant::now() {
            let timer = self.timer.get_or_insert_with(|| Box::pin(tokio::time::sleep_until(due)));
            timer.as_mut().reset(due);
            if timer.as_mut().poll(cx).is_pending() {
                return Poll::Pending;
            }
        }
        let Some((_, datagram)) = queue.pop_front() else { return Poll::Pending };
        let len = datagram.len().min(buffer.len());
        buffer[..len].copy_from_slice(&datagram[..len]);
        Poll::Ready(Ok(Received { len, origin: Origin { path: PathId(0), addr: Some(self.peer) } }))
    }

    fn has_peer(&self) -> bool {
        true
    }
}

fn ends() -> (End, End, Arc<Gate>) {
    let gate = Arc::new(Gate::default());
    let (a_to_b, b_to_a) = (Arc::new(Wire::default()), Arc::new(Wire::default()));
    gate.wires
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .extend([Arc::clone(&a_to_b), Arc::clone(&b_to_a)]);
    let a_addr: SocketAddr = "192.0.2.1:51820".parse().expect("address");
    let b_addr: SocketAddr = "192.0.2.2:51820".parse().expect("address");
    let a = End {
        out: Arc::clone(&a_to_b),
        inbound: Arc::clone(&b_to_a),
        peer: b_addr,
        gate: Arc::clone(&gate),
        timer: None,
    };
    let b =
        End { out: b_to_a, inbound: a_to_b, peer: a_addr, gate: Arc::clone(&gate), timer: None };
    (a, b, gate)
}

/// Echo every connection on `port` of `net`.
async fn echo(net: &WgNet, port: u16) {
    let mut listener = net.listen(port).await.expect("listen");
    tokio::spawn(async move {
        while let Some(mut stream) = listener.accept().await {
            tokio::spawn(async move {
                let mut buffer = [0u8; 1024];
                while let Ok(count) = stream.read(&mut buffer).await {
                    if count == 0 || stream.write_all(&buffer[..count]).await.is_err() {
                        break;
                    }
                }
            });
        }
    });
}

async fn round_trip(net: &WgNet, to: IpAddr) {
    let mut stream = net.connect(SocketAddr::new(to, 7000)).await.expect("connect");
    stream.write_all(b"crossed").await.expect("write");
    let mut back = [0u8; 7];
    stream.read_exact(&mut back).await.expect("read");
    assert_eq!(&back, b"crossed");
}

/// Both sides initiate at once and both have a connection waiting: the
/// session comes up within a few round trips, not never.
async fn crossing() {
    let pair = config_pair("192.0.2.2:51820".parse().expect("address"));
    let (a, b, gate) = ends();
    // Each side initiates as soon as it starts; the wire holds both.
    let mut client = pair.client;
    client.endpoint = None;
    let a = WgNet::start_with_underlay(client, a).expect("start a");
    let b = WgNet::start_with_underlay(pair.server, b).expect("start b");
    echo(&a, 7000).await;
    echo(&b, 7000).await;
    // Data waits on both sides behind the handshake.
    let a_dial = round_trip(&a, pair.server_v4);
    let b_dial = round_trip(&b, pair.client_v4);
    let opened = async {
        tokio::time::sleep(Duration::from_millis(200)).await;
        gate.open();
    };
    let linked = tokio::time::timeout(Duration::from_secs(8), async {
        tokio::join!(a_dial, b_dial, opened)
    })
    .await;
    let initiations = gate.initiations.load(Ordering::Relaxed);
    assert!(
        linked.is_ok(),
        "no session after crossing initiations ({initiations} initiations sent)"
    );
    assert!(initiations < 20, "{initiations} initiations for one session");
}

#[tokio::test]
async fn crossing_initiations_with_queued_data_still_make_a_session() {
    crossing().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn crossing_initiations_on_two_threads_still_make_a_session() {
    crossing().await;
}
