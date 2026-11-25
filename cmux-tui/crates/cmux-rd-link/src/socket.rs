use std::collections::BTreeMap;
use std::net::{SocketAddr, UdpSocket};

/// Read the host's absolute monotonic clock in the same domain as the ledger.
pub(super) fn monotonic_us() -> Option<u64> {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: the kernel writes a valid, live timespec; this is the host's clock domain.
    (unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) } == 0)
        .then_some(ts.tv_sec as u64 * 1_000_000 + ts.tv_nsec as u64 / 1000)
}

/// Sample the absolute protocol clock only after the complete payload is accepted.
pub(super) fn send_to_observed(
    socket: &UdpSocket,
    refused: &mut BTreeMap<i32, u64>,
    packet: &[u8],
    addr: SocketAddr,
) -> Option<(u64, usize)> {
    let sent = match socket.send_to(packet, addr) {
        Ok(sent) => sent,
        Err(e) => {
            *refused.entry(e.raw_os_error().unwrap_or(-1)).or_default() += 1;
            return None;
        }
    };
    if sent != packet.len() {
        return None;
    }
    Some((monotonic_us()?, sent))
}

#[cfg(test)]
#[path = "socket_tests.rs"]
mod tests;
