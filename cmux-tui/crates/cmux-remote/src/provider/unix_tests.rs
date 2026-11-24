use std::collections::BTreeMap;

use cmux_remote_protocol::{Lane, LanePolicy, SessionId};
use tempfile::tempdir;
use url::Url;

use super::*;

fn request(path: &std::path::Path) -> ConnectRequest {
    let mut endpoint = Url::parse("unix:///").unwrap();
    endpoint.set_path(path.to_str().unwrap());
    ConnectRequest {
        endpoint,
        session: SessionId::ZERO,
        lane_policy: LanePolicy::Single,
        routing: BTreeMap::new(),
    }
}

/// A socket file whose socket is bound but never listens, so every dial
/// is refused. A dropped listener is not enough: a process that another
/// test forks in that moment inherits the listening descriptor until it
/// execs, and the dial lands in its backlog (accepted).
fn bound_not_listening(path: &std::path::Path) -> std::os::fd::OwnedFd {
    use std::os::fd::FromRawFd;
    use std::os::unix::ffi::OsStrExt;

    // SAFETY: socket has no pointer arguments; a non-negative result is a new descriptor.
    let raw = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    assert!(raw >= 0, "socket: {}", std::io::Error::last_os_error());
    // SAFETY: raw is a new descriptor nothing else owns.
    let socket = unsafe { std::os::fd::OwnedFd::from_raw_fd(raw) };
    // SAFETY: an all-zero sockaddr_un is a valid value.
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    let bytes = path.as_os_str().as_bytes();
    assert!(cmux_unix_socket::fits(path), "socket path too long: {}", path.display());
    for (slot, byte) in address.sun_path.iter_mut().zip(bytes) {
        *slot = *byte as libc::c_char;
    }
    let length = size_of::<libc::sockaddr_un>() as libc::socklen_t;
    #[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
    {
        address.sun_len = length as u8;
    }
    // SAFETY: address is an initialized sockaddr_un of `length` bytes.
    let bound = unsafe { libc::bind(raw, (&raw const address).cast::<libc::sockaddr>(), length) };
    assert_eq!(bound, 0, "bind {}: {}", path.display(), std::io::Error::last_os_error());
    socket
}

#[tokio::test]
async fn transient_dial_failures_are_retryable_carrier_failures() {
    let directory = tempdir().unwrap();
    let missing = directory.path().join("missing.sock");
    let refused = directory.path().join("refused.sock");
    let _bound = bound_not_listening(&refused);

    for socket in [missing, refused] {
        let group = UnixProvider::new(1024).connect(request(&socket)).await.unwrap();
        let error = match group.open(LinkRequest { lane: Lane::Interactive, generation: 1 }).await {
            Ok(_) => panic!("unavailable Unix responder was accepted"),
            Err(error) => error,
        };
        assert!(
            error.is_retryable_carrier_failure(),
            "Unix dial failure for {} was terminal: {error}",
            socket.display()
        );
    }
}
