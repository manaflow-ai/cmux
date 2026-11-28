//! `partition`: an in-process TCP proxy between two parts of a scenario (a client and a relay, a
//! daemon and its relay). The scenario points one side at [`Proxy::addr`] and sets the fault:
//!
//! - [`Partition::Pass`]: bytes flow (the healed state);
//! - [`Partition::Delay`]: each chunk waits that long, each direction in order;
//! - [`Partition::Blackhole`]: connections stay open and nothing answers; what was sent is held
//!   and flows once healed, as a network that comes back inside TCP's retry window;
//! - [`Partition::HalfOpen`]: the far side hears the near one, the near side hears nothing back;
//! - [`Partition::Drop`]: new connections are closed at once and live ones are blackholed.
//!
//! [`Proxy::cut`] closes every live connection now (a reset), whatever the mode.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use cmux_scope::Scope;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;

use crate::trace::Trace;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Partition {
    Pass,
    Delay(Duration),
    Blackhole,
    HalfOpen,
    Drop,
}

impl Partition {
    /// Whether bytes in this direction wait (`down`: from the upstream back to the client).
    fn holds(self, down: bool) -> bool {
        match self {
            Self::Pass | Self::Delay(_) => false,
            Self::Blackhole | Self::Drop => true,
            Self::HalfOpen => down,
        }
    }
}

pub struct Proxy {
    addr: SocketAddr,
    mode: Arc<watch::Sender<Partition>>,
    cuts: Arc<watch::Sender<u64>>,
    accepted: Arc<AtomicU64>,
    /// Owns the accept loop and every connection: cancelled when the proxy drops.
    scope: Arc<Scope>,
    trace: Trace,
}

impl Proxy {
    /// A proxy on a free loopback port to `upstream`, passing.
    pub async fn start(upstream: SocketAddr, trace: &Trace) -> std::io::Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let addr = listener.local_addr()?;
        let mode = Arc::new(watch::channel(Partition::Pass).0);
        let cuts = Arc::new(watch::channel(0_u64).0);
        let accepted = Arc::new(AtomicU64::new(0));
        let scope = Arc::new(Scope::new("cmux-fault proxy"));
        scope.spawn_until_cancelled("fault proxy accept", {
            let (mode, cuts, accepted) = (mode.clone(), cuts.clone(), accepted.clone());
            let scope = Arc::downgrade(&scope);
            async move {
                while let Ok((near, _)) = listener.accept().await {
                    if *mode.borrow() == Partition::Drop {
                        drop(near);
                        continue;
                    }
                    let Some(scope) = scope.upgrade() else { return };
                    accepted.fetch_add(1, Ordering::SeqCst);
                    let (mode, cuts) = (mode.subscribe(), cuts.subscribe());
                    scope.spawn_until_cancelled("fault proxy connection", async move {
                        let Ok(far) = TcpStream::connect(upstream).await else { return };
                        let _ = near.set_nodelay(true);
                        let _ = far.set_nodelay(true);
                        let (near_read, near_write) = near.into_split();
                        let (far_read, far_write) = far.into_split();
                        let up = pump(near_read, far_write, false, mode.clone(), cuts.clone());
                        let down = pump(far_read, near_write, true, mode, cuts);
                        // Either direction ending (a close or a cut) ends the connection.
                        tokio::select! { _ = up => {}, _ = down => {} }
                    });
                }
            }
        });
        Ok(Self { addr, mode, cuts, accepted, scope, trace: trace.clone() })
    }

    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    pub fn set(&self, partition: Partition) {
        self.trace.note(if partition == Partition::Pass {
            "heal partition".to_owned()
        } else {
            format!("fault partition {partition:?}")
        });
        self.mode.send_replace(partition);
    }

    pub fn partition(&self) -> Partition {
        *self.mode.borrow()
    }

    /// Closes every live connection.
    pub fn cut(&self) {
        self.trace.note("fault partition cut");
        self.cuts.send_modify(|cuts| *cuts += 1);
    }

    /// Connections accepted and passed on so far.
    pub fn accepted(&self) -> u64 {
        self.accepted.load(Ordering::SeqCst)
    }
}

impl Drop for Proxy {
    fn drop(&mut self) {
        self.scope.token().cancel();
        self.cuts.send_modify(|cuts| *cuts += 1);
    }
}

async fn pump(
    mut from: tokio::net::tcp::OwnedReadHalf,
    mut to: tokio::net::tcp::OwnedWriteHalf,
    down: bool,
    mut mode: watch::Receiver<Partition>,
    mut cuts: watch::Receiver<u64>,
) {
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let read = tokio::select! {
            read = from.read(&mut buffer) => read,
            _ = cuts.changed() => return,
        };
        let chunk = match read {
            Ok(0) | Err(_) => return,
            Ok(n) => buffer.get(..n).unwrap_or_default(),
        };
        let partition = tokio::select! {
            held = mode.wait_for(|partition| !partition.holds(down)) => match held {
                Ok(partition) => *partition,
                Err(_) => return,
            },
            _ = cuts.changed() => return,
        };
        if let Partition::Delay(by) = partition {
            tokio::select! {
                _ = tokio::time::sleep(by) => {}
                _ = cuts.changed() => return,
            }
        }
        if to.write_all(chunk).await.is_err() {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Partition, Proxy};
    use crate::trace::Trace;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};

    async fn echo_server() -> std::net::SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let mut buffer = [0_u8; 1024];
                    while let Ok(n) = socket.read(&mut buffer).await {
                        if n == 0 || socket.write_all(&buffer[..n]).await.is_err() {
                            return;
                        }
                    }
                });
            }
        });
        addr
    }

    async fn echo(stream: &mut TcpStream, within: Duration) -> Option<Vec<u8>> {
        stream.write_all(b"ping").await.ok()?;
        let mut answer = [0_u8; 4];
        match tokio::time::timeout(within, stream.read_exact(&mut answer)).await {
            Ok(Ok(_)) => Some(answer.to_vec()),
            _ => None,
        }
    }

    #[tokio::test]
    async fn the_proxy_passes_blackholes_heals_and_cuts() {
        let trace = Trace::new();
        let proxy = Proxy::start(echo_server().await, &trace).await.unwrap();
        let mut client = TcpStream::connect(proxy.addr()).await.unwrap();
        assert_eq!(echo(&mut client, Duration::from_secs(5)).await.as_deref(), Some(&b"ping"[..]));

        proxy.set(Partition::Blackhole);
        assert_eq!(echo(&mut client, Duration::from_millis(200)).await, None);
        proxy.set(Partition::Pass);
        // The held ping, then this one.
        let mut held = [0_u8; 8];
        client.write_all(b"ping").await.unwrap();
        client.read_exact(&mut held).await.unwrap();
        assert_eq!(&held, b"pingping");

        proxy.set(Partition::Delay(Duration::from_millis(150)));
        let started = std::time::Instant::now();
        assert!(echo(&mut client, Duration::from_secs(5)).await.is_some());
        assert!(started.elapsed() >= Duration::from_millis(300), "{:?}", started.elapsed());
        proxy.set(Partition::Pass);

        proxy.cut();
        let mut rest = Vec::new();
        let closed = tokio::time::timeout(Duration::from_secs(5), client.read_to_end(&mut rest));
        assert!(closed.await.is_ok(), "a cut connection stayed open");

        proxy.set(Partition::Drop);
        let mut refused = TcpStream::connect(proxy.addr()).await.unwrap();
        assert_eq!(echo(&mut refused, Duration::from_millis(300)).await, None);
        assert_eq!(proxy.accepted(), 1);
    }
}
