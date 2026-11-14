use super::*;

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
    let before = [socket_buffer(&socket, libc::SO_SNDBUF), socket_buffer(&socket, libc::SO_RCVBUF)];
    grow_udp_buffers(&socket);
    let after = [socket_buffer(&socket, libc::SO_SNDBUF), socket_buffer(&socket, libc::SO_RCVBUF)];
    assert!(after[0] > before[0], "send buffer did not grow: {before:?} -> {after:?}");
    assert!(after[1] > before[1], "receive buffer did not grow: {before:?} -> {after:?}");
}
