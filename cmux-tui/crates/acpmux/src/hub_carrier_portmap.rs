//! The router's mapping of the punch port (`hub_carrier_punch.rs`): a TCP mapping by PCP
//! (RFC 6887), else NAT-PMP (RFC 6886), from the default gateway, renewed at half its lease.
//! The mapped address is one more candidate a punch offers, the one a machine behind a
//! symmetric NAT is reachable at. Ported from cmux-mobile-host's UDP mapper (`portmap.rs`),
//! TCP here; UPnP-IGD is that mapper's alone for now.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Weak;
use std::time::Duration;

use tokio::net::UdpSocket;

use super::super::HubCarrier;

/// The PCP and NAT-PMP port on the gateway.
pub const PMP_PORT: u16 = 5351;
/// The lease asked for.
const LIFETIME_S: u32 = 3600;
/// How long each try waits for the gateway's answer.
const UDP_TRIES: [Duration; 2] = [Duration::from_millis(250), Duration::from_millis(500)];
/// How long a gateway that mapped nothing is left before asking again.
const NOTHING_RETRY: Duration = Duration::from_secs(5 * 60);
/// The shortest renewal wait, whatever lease the gateway grants.
const MIN_RENEW: Duration = Duration::from_secs(30);

const PCP_VERSION: u8 = 2;
const PCP_MAP: u8 = 1;
const TCP: u8 = 6;
/// NAT-PMP's TCP mapping opcode; its answer is 128 + 2.
const NATPMP_TCP: u8 = 2;

/// Keep the punch port mapped while the carrier lives: offer the mapping, renew it, and ask
/// again later when the gateway grants none.
pub async fn keep_mapped(carrier: Weak<HubCarrier>, port: u16) {
    loop {
        let mapped = match default_gateway() {
            Some(gateway) => match local_toward(gateway) {
                Some(local) => map(SocketAddr::new(gateway.into(), PMP_PORT), local, port).await,
                None => None,
            },
            None => None,
        };
        let Some(carrier) = carrier.upgrade() else { return };
        let wait = match mapped {
            Some((external, lifetime)) if public(external.ip()) => {
                tracing::info!("hub carrier punch: the router maps {external} to port {port}");
                carrier.set_punch_mapped(Some(external));
                (Duration::from_secs(u64::from(lifetime)) / 2).max(MIN_RENEW)
            }
            _ => {
                carrier.set_punch_mapped(None);
                NOTHING_RETRY
            }
        };
        drop(carrier);
        tokio::time::sleep(wait).await;
    }
}

/// A TCP mapping of `internal` from the PCP/NAT-PMP server at `gateway`, asked from `local`:
/// the external address and the lease granted. PCP first, then NAT-PMP.
pub async fn map(gateway: SocketAddr, local: Ipv4Addr, internal: u16) -> Option<(SocketAddr, u32)> {
    let mut nonce = [0u8; 12];
    getrandom::fill(&mut nonce).ok()?;
    let request = pcp_request(local, nonce, internal, LIFETIME_S);
    if let Some(found) =
        exchange(gateway, local, &request, |buf| pcp_answer(buf, &nonce, internal)).await
    {
        return Some(found);
    }
    let request = natpmp_request(internal, internal, LIFETIME_S);
    let (port, lifetime) =
        exchange(gateway, local, &request, |buf| natpmp_map_answer(buf, internal)).await?;
    let ip = exchange(gateway, local, &[0, 0], natpmp_address_answer).await?;
    Some((SocketAddr::new(ip.into(), port), lifetime))
}

async fn exchange<T>(
    gateway: SocketAddr,
    local: Ipv4Addr,
    request: &[u8],
    accept: impl Fn(&[u8]) -> Option<T>,
) -> Option<T> {
    // The client address a PCP request names is this socket's own, never a wildcard's.
    let socket = UdpSocket::bind((local, 0)).await.ok()?;
    let mut buffer = [0u8; 1100];
    for wait in UDP_TRIES {
        socket.send_to(request, gateway).await.ok()?;
        let deadline = tokio::time::Instant::now() + wait;
        loop {
            let received = tokio::time::timeout_at(deadline, socket.recv_from(&mut buffer)).await;
            let Ok(Ok((len, from))) = received else { break };
            // Only the gateway's PCP/NAT-PMP port answers (RFC 6887 §8.3, RFC 6886 §3.1).
            if from != gateway {
                continue;
            }
            let answer = buffer.get(..len).unwrap_or_default();
            if let Some(found) = accept(answer) {
                return Some(found);
            }
            if refused(request, answer) {
                return None;
            }
        }
    }
    None
}

/// An error answer to `request`: its opcode with the answer bit and a nonzero result.
fn refused(request: &[u8], answer: &[u8]) -> bool {
    let (Some(opcode), Some([_, op, result @ ..])) = (byte(request, 1), bytes::<4>(answer, 0))
    else {
        return false;
    };
    op == 0x80 | opcode && result != [0, 0]
}

/// The byte at `at`, or none past the end.
fn byte(buf: &[u8], at: usize) -> Option<u8> {
    buf.get(at).copied()
}

/// The `N` bytes from `at`, or none past the end.
fn bytes<const N: usize>(buf: &[u8], at: usize) -> Option<[u8; N]> {
    buf.get(at..at.checked_add(N)?)?.try_into().ok()
}

fn public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => !(v4.is_private() || v4.is_unspecified()) && super::candidate_ip(ip),
        IpAddr::V6(_) => super::candidate_ip(ip),
    }
}

/// A PCP MAP request for TCP port `internal` (60 bytes).
pub fn pcp_request(client: Ipv4Addr, nonce: [u8; 12], internal: u16, lifetime: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity(60);
    out.extend_from_slice(&[PCP_VERSION, PCP_MAP, 0, 0]);
    out.extend_from_slice(&lifetime.to_be_bytes());
    out.extend_from_slice(&client.to_ipv6_mapped().octets());
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&[TCP, 0, 0, 0]);
    out.extend_from_slice(&internal.to_be_bytes());
    // No suggested external port or address.
    out.extend_from_slice(&0u16.to_be_bytes());
    out.extend_from_slice(&Ipv4Addr::UNSPECIFIED.to_ipv6_mapped().octets());
    out
}

/// A PCP MAP success answer to `nonce` for TCP `internal`: the external address and lease.
pub fn pcp_answer(buf: &[u8], nonce: &[u8; 12], internal: u16) -> Option<(SocketAddr, u32)> {
    let [version, op, _, result] = bytes::<4>(buf, 0)?;
    if version != PCP_VERSION || op != 0x80 | PCP_MAP || result != 0 {
        return None;
    }
    if &bytes::<12>(buf, 24)? != nonce
        || byte(buf, 36)? != TCP
        || u16::from_be_bytes(bytes(buf, 40)?) != internal
    {
        return None;
    }
    let lifetime = u32::from_be_bytes(bytes(buf, 4)?);
    let port = u16::from_be_bytes(bytes(buf, 42)?);
    let ip = Ipv6Addr::from(bytes::<16>(buf, 44)?);
    let ip = ip.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(IpAddr::V6(ip));
    Some((SocketAddr::new(ip, port), lifetime))
}

/// A NAT-PMP TCP mapping request (12 bytes).
pub fn natpmp_request(internal: u16, external: u16, lifetime: u32) -> [u8; 12] {
    let [i0, i1] = internal.to_be_bytes();
    let [e0, e1] = external.to_be_bytes();
    let [l0, l1, l2, l3] = lifetime.to_be_bytes();
    [0, NATPMP_TCP, 0, 0, i0, i1, e0, e1, l0, l1, l2, l3]
}

/// A NAT-PMP TCP mapping success answer for `internal`: the external port and lease.
pub fn natpmp_map_answer(buf: &[u8], internal: u16) -> Option<(u16, u32)> {
    if bytes::<4>(buf, 0)? != [0, 0x80 | NATPMP_TCP, 0, 0] {
        return None;
    }
    if u16::from_be_bytes(bytes(buf, 8)?) != internal {
        return None;
    }
    Some((u16::from_be_bytes(bytes(buf, 10)?), u32::from_be_bytes(bytes(buf, 12)?)))
}

/// A NAT-PMP public address success answer.
pub fn natpmp_address_answer(buf: &[u8]) -> Option<Ipv4Addr> {
    if bytes::<4>(buf, 0)? != [0, 128, 0, 0] {
        return None;
    }
    Some(Ipv4Addr::from(bytes::<4>(buf, 8)?))
}

/// This machine's address toward `gateway` (a connected UDP socket; nothing sent).
fn local_toward(gateway: Ipv4Addr) -> Option<Ipv4Addr> {
    let probe = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    probe.connect((gateway, PMP_PORT)).ok()?;
    match probe.local_addr().ok()?.ip() {
        IpAddr::V4(ip) if !ip.is_unspecified() => Some(ip),
        _ => None,
    }
}

/// The default IPv4 gateway: macOS reads it with `sysctl` `NET_RT_FLAGS`. Elsewhere none
/// (no port mapping): Linux hosts are mostly servers and cloud machines, which still punch
/// over IPv6 and toward a far side's mapping, and cmux-next never reads `/proc/net`.
pub fn default_gateway() -> Option<Ipv4Addr> {
    #[cfg(target_os = "macos")]
    {
        macos_gateway()
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

/// The default route's gateway in a `NET_RT_FLAGS` dump: routing messages (`rt_msghdr`,
/// `header` bytes) each followed by their sockaddrs, each padded to 4 bytes.
pub fn rt_dump_gateway(dump: &[u8], header: usize) -> Option<Ipv4Addr> {
    const RTA_DST: i32 = 0x1;
    const RTA_GATEWAY: i32 = 0x2;
    const AF_INET: u8 = 2;
    let mut rest = dump;
    while rest.len() >= header {
        let len = usize::from(u16::from_ne_bytes(bytes(rest, 0)?));
        if len < header || len > rest.len() {
            return None;
        }
        let (message, after) = rest.split_at(len);
        rest = after;
        let addrs = i32::from_ne_bytes(bytes(message, 12)?);
        if addrs & (RTA_DST | RTA_GATEWAY) != (RTA_DST | RTA_GATEWAY) {
            continue;
        }
        let mut sockaddrs = message.get(header..)?;
        let mut next = || -> Option<&[u8]> {
            let sa_len = usize::from(*sockaddrs.first()?);
            let step = if sa_len == 0 { 4 } else { sa_len.div_ceil(4) * 4 };
            let (sockaddr, rest) = sockaddrs.split_at(step.min(sockaddrs.len()));
            sockaddrs = rest;
            sockaddr.get(..sa_len.min(sockaddr.len()))
        };
        let (Some(destination), Some(gateway)) = (next(), next()) else { continue };
        let ipv4 = |sockaddr: &[u8]| {
            (byte(sockaddr, 1)? == AF_INET).then_some(Ipv4Addr::from(bytes::<4>(sockaddr, 4)?))
        };
        if ipv4(destination) == Some(Ipv4Addr::UNSPECIFIED)
            && let Some(gateway) = ipv4(gateway)
            && !gateway.is_unspecified()
        {
            return Some(gateway);
        }
    }
    None
}

#[cfg(target_os = "macos")]
fn macos_gateway() -> Option<Ipv4Addr> {
    let mut mib =
        [libc::CTL_NET, libc::PF_ROUTE, 0, libc::AF_INET, libc::NET_RT_FLAGS, libc::RTF_GATEWAY];
    let mut size: libc::size_t = 0;
    // SAFETY: sysctl with a null buffer only reports the size.
    let found = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as u32,
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if found != 0 || size == 0 {
        return None;
    }
    let mut dump = vec![0u8; size + 512];
    let mut size = dump.len();
    // SAFETY: the buffer is `size` bytes; sysctl writes at most that.
    let found = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as u32,
            dump.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if found != 0 {
        return None;
    }
    rt_dump_gateway(dump.get(..size)?, std::mem::size_of::<libc::rt_msghdr>())
}

#[cfg(test)]
#[path = "hub_carrier_portmap_tests.rs"]
mod tests;
