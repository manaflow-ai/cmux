//! The BEFORE: a plain UDP forwarder, a TURN allocation's data plane.
//!
//! Two ports: whatever the phone sends to the phone port goes out of the Mac
//! port to the last address the Mac port heard from, and the reverse. No
//! sequence numbers, no repair, no priority, one FIFO (the kernel's): what
//! Cloudflare TURN does with a relayed WireGuard datagram.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use tokio::net::UdpSocket;

#[derive(Default)]
pub struct ForwardCounters {
    pub to_mac: AtomicU64,
    pub to_phone: AtomicU64,
    pub unknown_peer: AtomicU64,
}

pub struct Forwarder {
    phone: Arc<UdpSocket>,
    mac: Arc<UdpSocket>,
    pub counters: Arc<ForwardCounters>,
}

impl Forwarder {
    pub async fn bind(phone: SocketAddr, mac: SocketAddr) -> std::io::Result<Self> {
        Ok(Self {
            phone: Arc::new(UdpSocket::bind(phone).await?),
            mac: Arc::new(UdpSocket::bind(mac).await?),
            counters: Arc::default(),
        })
    }

    pub fn phone_addr(&self) -> std::io::Result<SocketAddr> {
        self.phone.local_addr()
    }

    pub fn mac_addr(&self) -> std::io::Result<SocketAddr> {
        self.mac.local_addr()
    }

    /// Forwards until either socket fails.
    pub async fn run(self) -> std::io::Result<()> {
        let mut phone_peer: Option<SocketAddr> = None;
        let mut mac_peer: Option<SocketAddr> = None;
        let mut a = vec![0_u8; 65_536];
        let mut b = vec![0_u8; 65_536];
        loop {
            tokio::select! {
                got = self.phone.recv_from(&mut a) => {
                    let (n, from) = got?;
                    phone_peer = Some(from);
                    match (mac_peer, a.get(..n)) {
                        (Some(to), Some(bytes)) => {
                            let _ = self.mac.send_to(bytes, to).await;
                            self.counters.to_mac.fetch_add(1, Ordering::Relaxed);
                        }
                        _ => { self.counters.unknown_peer.fetch_add(1, Ordering::Relaxed); }
                    }
                }
                got = self.mac.recv_from(&mut b) => {
                    let (n, from) = got?;
                    mac_peer = Some(from);
                    match (phone_peer, b.get(..n)) {
                        (Some(to), Some(bytes)) => {
                            let _ = self.phone.send_to(bytes, to).await;
                            self.counters.to_phone.fetch_add(1, Ordering::Relaxed);
                        }
                        _ => { self.counters.unknown_peer.fetch_add(1, Ordering::Relaxed); }
                    }
                }
            }
        }
    }
}
