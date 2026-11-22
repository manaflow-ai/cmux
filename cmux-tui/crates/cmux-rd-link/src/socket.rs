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
    packet: &[u8],
    addr: SocketAddr,
) -> Option<(u64, usize)> {
    let sent = socket.send_to(packet, addr).ok()?;
    if sent != packet.len() {
        return None;
    }
    Some((monotonic_us()?, sent))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io;
    use std::mem::size_of_val;
    use std::os::fd::AsRawFd;

    #[test]
    fn departure_failed_socket_send_has_no_success_timestamp() {
        let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        let peer = UdpSocket::bind("127.0.0.1:0").unwrap();
        assert!(send_to_observed(&socket, &[0; 65_536], peer.local_addr().unwrap()).is_none());
        let before = monotonic_us().unwrap();
        let (departed, bytes) =
            send_to_observed(&socket, b"ok", peer.local_addr().unwrap()).unwrap();
        let after = monotonic_us().unwrap();
        assert!((before..=after).contains(&departed));
        assert_eq!(bytes, 2);
    }

    fn set_socket_buffer(socket: &UdpSocket, option: libc::c_int, value: i32) {
        // SAFETY: the descriptor is open for the borrow of `socket`, and the
        // option value points at a live integer of the length passed.
        let result = unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::SOL_SOCKET,
                option,
                (&value as *const i32).cast(),
                size_of_val(&value) as libc::socklen_t,
            )
        };
        assert_eq!(result, 0, "setsockopt failed: {}", io::Error::last_os_error());
    }

    fn socket_buffer(socket: &UdpSocket, option: libc::c_int) -> i32 {
        let mut value = 0i32;
        let mut length = size_of_val(&value) as libc::socklen_t;
        // SAFETY: the descriptor is open, and the kernel writes at most the
        // size of `value` bytes to the pointer and length supplied.
        let result = unsafe {
            libc::getsockopt(
                socket.as_raw_fd(),
                libc::SOL_SOCKET,
                option,
                (&mut value as *mut i32).cast(),
                &mut length,
            )
        };
        assert_eq!(result, 0, "getsockopt failed: {}", io::Error::last_os_error());
        value
    }

    #[test]
    fn grow_udp_buffers_expands_both_queues() {
        let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        // Use a small starting point so the assertion does not depend on the
        // host's default buffers already being larger than our request.
        set_socket_buffer(&socket, libc::SO_SNDBUF, 4096);
        set_socket_buffer(&socket, libc::SO_RCVBUF, 4096);
        let before =
            [socket_buffer(&socket, libc::SO_SNDBUF), socket_buffer(&socket, libc::SO_RCVBUF)];
        super::super::grow_udp_buffers(&socket);
        let after =
            [socket_buffer(&socket, libc::SO_SNDBUF), socket_buffer(&socket, libc::SO_RCVBUF)];
        assert!(after[0] > before[0], "send buffer did not grow: {before:?} -> {after:?}");
        assert!(after[1] > before[1], "receive buffer did not grow: {before:?} -> {after:?}");
    }
}
