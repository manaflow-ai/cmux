//! The tunnel's UDP socket gets a receive buffer that holds a burst.
//!
//! With the kernel's default (208 KiB on Linux), the datagrams of one 256 KiB
//! smoltcp window overflowed the peer's socket on loopback. smoltcp's fast
//! retransmit recovered few of the lost segments, and the rest waited out its
//! 1 s minimum retransmission timeout: half of the 8 MiB loopback echoes of
//! HQ 5080 took 1.1 s instead of 0.09 s, with 5 to 102 `RcvbufErrors` each.
#![cfg(target_os = "linux")]

use std::os::fd::AsRawFd;

use cmux_wg::{InterfaceAddress, RECEIVE_BUFFER, WgMesh, WgMeshConfig};
use zeroize::Zeroizing;

/// The receive buffer the kernel reports for `socket`, in the bytes it
/// accounts (Linux doubles the requested size for bookkeeping).
fn receive_buffer(socket: &impl AsRawFd) -> usize {
    let mut size: libc::c_int = 0;
    let mut len = size_of_val(&size) as libc::socklen_t;
    // SAFETY: the descriptor is open for the borrow, and `size` and `len`
    // are live and describe each other.
    let result = unsafe {
        libc::getsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_RCVBUF,
            (&raw mut size).cast(),
            &raw mut len,
        )
    };
    assert_eq!(result, 0, "getsockopt: {}", std::io::Error::last_os_error());
    usize::try_from(size).unwrap()
}

/// What an unprivileged request for [`RECEIVE_BUFFER`] may get.
fn allowed() -> usize {
    let max = std::fs::read_to_string("/proc/sys/net/core/rmem_max").unwrap();
    RECEIVE_BUFFER.min(max.trim().parse().unwrap())
}

#[tokio::test]
async fn a_mesh_socket_gets_a_receive_buffer_that_holds_a_burst() {
    let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    // The same socket, seen after the mesh takes its other handle.
    let probe = socket.try_clone().unwrap();
    socket.set_nonblocking(true).unwrap();
    let socket = tokio::net::UdpSocket::from_std(socket).unwrap();
    let (private, _) = cmux_wg::testing::random_keypair();
    let config = WgMeshConfig {
        private_key: Zeroizing::new(private),
        addresses: vec![InterfaceAddress { address: "10.77.0.1".parse().unwrap(), prefix: 32 }],
        mtu: cmux_wg::DEFAULT_MTU,
    };
    let mesh = WgMesh::start(config, socket).unwrap();

    let reported = receive_buffer(&probe);
    let wanted = allowed();
    assert!(
        reported / 2 >= wanted,
        "the kernel holds {} bytes; the tunnel asked for {RECEIVE_BUFFER}, and {wanted} is allowed",
        reported / 2
    );
    mesh.shutdown().await;
}
