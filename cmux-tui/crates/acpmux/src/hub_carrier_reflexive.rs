//! The punch port's public address (`hub_carrier_punch.rs`): the server-reflexive candidate.
//!
//! Leo, 2026-11-25: "why don't we do mac side connect + measure more numbers and do more stuff".
//! The punch offered only this machine's interface addresses and a PCP/NAT-PMP mapping. A machine
//! behind a NAT that grants no mapping (a cloud VM's 1:1 NAT, Cloud NAT, nearly every home router)
//! offered only its private address, so the far side never opened toward its public address and
//! each side's filter dropped the other's SYNs: hetzner-1 on 2026-11-28 read 1 direct of 161
//! tries, 90 of the misses `no candidate of 1 connected in 3s` (one private address offered).
//!
//! Now, every [`REFRESH`], the punch learns its public address from the punch port itself:
//!
//! - TCP: a STUN binding request (RFC 5389 over TCP, unframed) sent over a connection from the
//!   punch port. The answer is the exact public address of that port, which a NAT whose mapping
//!   does not depend on the destination (Cloud NAT's default, most home routers) reuses when the
//!   punch opens from the same port.
//! - UDP, when no TCP server answers: a binding request to the public UDP STUN servers names the
//!   public IP. That IP on the punch port is offered: a 1:1 NAT (GCP, AWS) and a NAT that keeps
//!   source ports (Linux conntrack, most home routers) put the punch there.
//!
//! An address that is already one of this machine's (a public IP on the interface) adds nothing:
//! the candidates are deduplicated. Off with `ACPMUX_PUNCH_REFLEXIVE=0`; servers named by
//! `ACPMUX_PUNCH_STUN_TCP` and `ACPMUX_PUNCH_STUN_UDP` (comma-separated `host:port`) replace the
//! defaults.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Weak;
use std::time::Duration;

use cmux_transport::classify::STUN_HEADER_LEN;
use cmux_transport::stun::{TransactionId, binding_request, parse_binding_success};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::super::HubCarrier;

/// STUN servers that answer over TCP (Google's and Cloudflare's answer UDP only).
pub const TCP_SERVERS: [&str; 2] = ["stun.nextcloud.com:443", "stun.nextcloud.com:3478"];
/// STUN servers that answer over UDP, the ones `cmux-nat-probe` reads.
pub const UDP_SERVERS: [&str; 3] =
    ["stun.l.google.com:19302", "stun.cloudflare.com:3478", "stun1.l.google.com:19302"];
/// How often the public address is read again while one is known.
pub const REFRESH: Duration = Duration::from_secs(5 * 60);
/// How soon to ask again when no server answered.
const NOTHING_RETRY: Duration = Duration::from_secs(2 * 60);
/// One server's bound (resolve, connect, answer).
const ASK_BOUND: Duration = Duration::from_millis(2500);
/// The longest STUN answer read.
const MAX_ANSWER: usize = 548;

/// How the public address was learned.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Learned {
    /// The exact TCP mapping of the punch port.
    Tcp,
    /// The public IP from UDP STUN, on the punch port.
    UdpIp,
}

/// Whether this process looks up the public address: unless `ACPMUX_PUNCH_REFLEXIVE=0`.
pub fn enabled() -> bool {
    super::enabled_by(std::env::var("ACPMUX_PUNCH_REFLEXIVE").ok().as_deref())
}

fn servers(var: &str, defaults: &[&str]) -> Vec<String> {
    match std::env::var(var) {
        Ok(named) if !named.trim().is_empty() => {
            named.split(',').map(|s| s.trim().to_owned()).filter(|s| !s.is_empty()).collect()
        }
        _ => defaults.iter().map(|s| (*s).to_owned()).collect(),
    }
}

/// Keep the punch port's public address offered while the carrier lives.
pub async fn keep_learned(carrier: Weak<HubCarrier>, port: u16) {
    let tcp = servers("ACPMUX_PUNCH_STUN_TCP", &TCP_SERVERS);
    let udp = servers("ACPMUX_PUNCH_STUN_UDP", &UDP_SERVERS);
    let mut last: Option<SocketAddr> = None;
    loop {
        let found = learn(port, &tcp, &udp).await;
        let Some(carrier) = carrier.upgrade() else { return };
        let wait = match found {
            Some((address, how)) => {
                if last != Some(address) {
                    tracing::info!("hub carrier punch: public address {address} ({how:?})");
                }
                last = Some(address);
                carrier.set_punch_reflexive(Some(address));
                REFRESH
            }
            None => {
                if last.is_some() {
                    tracing::info!(
                        "hub carrier punch: no public address (no STUN server answered)"
                    );
                }
                last = None;
                carrier.set_punch_reflexive(None);
                NOTHING_RETRY
            }
        };
        drop(carrier);
        tokio::time::sleep(wait).await;
    }
}

/// The punch port's public IPv4 address: the TCP mapping when a TCP server answers, else the UDP
/// public IP on `port`.
pub async fn learn(port: u16, tcp: &[String], udp: &[String]) -> Option<(SocketAddr, Learned)> {
    for server in tcp {
        if let Some(address) = ask_tcp(port, server).await
            && reflexive_ok(address.ip())
        {
            return Some((address, Learned::Tcp));
        }
    }
    for server in udp {
        if let Some(address) = ask_udp(server).await
            && reflexive_ok(address.ip())
        {
            return Some((SocketAddr::new(address.ip(), port), Learned::UdpIp));
        }
    }
    None
}

/// Whether `ip` is worth offering as a public address: a routable IPv4 (IPv6 rides the
/// interface's own global address, no NAT between).
pub fn reflexive_ok(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => super::candidate_ip(ip) && !v4.is_private() && !v4.is_documentation(),
        IpAddr::V6(_) => false,
    }
}

async fn first_v4(server: &str) -> Option<SocketAddr> {
    tokio::net::lookup_host(server).await.ok()?.find(SocketAddr::is_ipv4)
}

fn transaction() -> Option<TransactionId> {
    let mut id = [0u8; 12];
    getrandom::fill(&mut id).ok()?;
    Some(id)
}

/// One TCP binding request to `server` from local `port` (shared with the punch listener).
pub async fn ask_tcp(port: u16, server: &str) -> Option<SocketAddr> {
    tokio::time::timeout(ASK_BOUND, async {
        let to = first_v4(server).await?;
        let socket = tokio::net::TcpSocket::new_v4().ok()?;
        socket.set_reuseaddr(true).ok()?;
        #[cfg(unix)]
        socket.set_reuseport(true).ok()?;
        socket.bind(SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), port)).ok()?;
        let mut tcp = socket.connect(to).await.ok()?;
        let id = transaction()?;
        tcp.write_all(&binding_request(id)).await.ok()?;
        read_answer(&mut tcp, &id).await
    })
    .await
    .ok()
    .flatten()
}

/// Read one STUN message (20-byte header, then its length) and parse it as the answer to `id`.
pub async fn read_answer(
    read: &mut (impl tokio::io::AsyncRead + Unpin),
    id: &TransactionId,
) -> Option<SocketAddr> {
    let mut header = [0u8; STUN_HEADER_LEN];
    read.read_exact(&mut header).await.ok()?;
    let len = usize::from(u16::from_be_bytes([header[2], header[3]]));
    if STUN_HEADER_LEN + len > MAX_ANSWER {
        return None;
    }
    let mut message = header.to_vec();
    message.resize(STUN_HEADER_LEN + len, 0);
    read.read_exact(&mut message[STUN_HEADER_LEN..]).await.ok()?;
    parse_binding_success(&message, id).ok()
}

/// One UDP binding request to `server`: its view of this machine's public address.
pub async fn ask_udp(server: &str) -> Option<SocketAddr> {
    tokio::time::timeout(ASK_BOUND, async {
        let to = first_v4(server).await?;
        let socket = tokio::net::UdpSocket::bind(SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0))
            .await
            .ok()?;
        let id = transaction()?;
        let request = binding_request(id);
        let mut buf = [0u8; MAX_ANSWER];
        // Two sends, the second after a lost first.
        for wait in [Duration::from_millis(700), Duration::from_millis(1200)] {
            socket.send_to(&request, to).await.ok()?;
            if let Ok(Ok((n, from))) = tokio::time::timeout(wait, socket.recv_from(&mut buf)).await
                && from == to
                && let Some(answer) = buf.get(..n)
                && let Ok(address) = parse_binding_success(answer, &id)
            {
                return Some(address);
            }
        }
        None
    })
    .await
    .ok()
    .flatten()
}
