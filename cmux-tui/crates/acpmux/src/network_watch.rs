//! Notices when this computer's network changes (an address comes or goes, an interface goes up
//! or down: Wi-Fi back after a wake, a switch of networks, a VPN) and tells every peer link
//! (`Peer::network_changed`): one waiting to redial dials now, and a live one is checked at once.
//! Without it a link that rode the old route waited out its ping deadline, and one in backoff its
//! next step.
//!
//! macOS reads the routing socket (`PF_ROUTE`), Linux its netlink route groups; both are kernel
//! messages read on one thread, with no polling. The thread ends when the hub is gone.

use std::sync::Weak;
use std::time::{Duration, Instant};

use crate::hub::Hub;

/// How long a burst of messages (an interface coming up adds several addresses) is gathered
/// into one change.
const SETTLE: Duration = Duration::from_millis(300);

/// How often the thread, blocked on the socket, wakes to see whether the hub is still there.
const ALIVE_EVERY: Duration = Duration::from_secs(2);

/// Starts the watch on its own thread; nothing on a platform without one, or when the socket
/// cannot be opened (the links then rely on their ping deadline, as before). The thread ends
/// once `hub` is dropped.
pub fn start(hub: Weak<Hub>) {
    let Some(socket) = imp::open() else {
        tracing::debug!("no network change watch on this machine");
        return;
    };
    let spawned =
        std::thread::Builder::new().name("acpmux-network-watch".into()).spawn(move || {
            watch(
                socket,
                || hub.strong_count() > 0,
                || {
                    if let Some(hub) = hub.upgrade() {
                        hub.network_changed();
                    }
                },
            )
        });
    if let Err(e) = spawned {
        tracing::warn!("network change watch did not start: {e}");
    }
}

/// Reads `socket` until `alive` says no (the hub is gone, read at least every [`ALIVE_EVERY`]) or
/// the socket fails: each burst of changes calls `changed` once, [`SETTLE`] after its first
/// message.
fn watch(socket: imp::Socket, alive: impl Fn() -> bool, mut changed: impl FnMut()) {
    let mut first: Option<Instant> = None;
    let mut buf = vec![0u8; 16 * 1024];
    loop {
        let wait = match first {
            Some(at) => SETTLE.saturating_sub(at.elapsed()).max(Duration::from_millis(1)),
            None => ALIVE_EVERY,
        };
        match imp::read(&socket, &mut buf, wait) {
            Read::Message(n) => {
                if first.is_none() && imp::is_change(&buf[..n]) {
                    first = Some(Instant::now());
                }
            }
            Read::Quiet => {}
            Read::Failed => return,
        }
        if !alive() {
            return;
        }
        if first.is_some_and(|at| at.elapsed() >= SETTLE) {
            first = None;
            tracing::info!("this computer's network changed; checking peer links");
            changed();
        }
    }
}

enum Read {
    Message(usize),
    Quiet,
    Failed,
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
mod imp {
    use super::Read;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::time::Duration;

    pub struct Socket(OwnedFd);

    #[cfg(target_os = "macos")]
    pub fn open() -> Option<Socket> {
        // SAFETY: plain socket(2); the fd is owned below.
        let fd = unsafe { libc::socket(libc::PF_ROUTE, libc::SOCK_RAW, libc::AF_UNSPEC) };
        if fd < 0 {
            return None;
        }
        // SAFETY: a valid fd this function just opened and nothing else owns.
        let socket = Socket(unsafe { OwnedFd::from_raw_fd(fd) });
        // No harness or ssh this daemon starts inherits it.
        // SAFETY: fcntl(2) on an owned, open fd.
        unsafe { libc::fcntl(socket.0.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) };
        Some(socket)
    }

    #[cfg(target_os = "linux")]
    pub fn open() -> Option<Socket> {
        // SAFETY: plain socket(2); the fd is owned below.
        let fd = unsafe {
            libc::socket(libc::AF_NETLINK, libc::SOCK_RAW | libc::SOCK_CLOEXEC, libc::NETLINK_ROUTE)
        };
        if fd < 0 {
            return None;
        }
        // SAFETY: a valid fd this function just opened and nothing else owns.
        let socket = Socket(unsafe { OwnedFd::from_raw_fd(fd) });
        // SAFETY: a zeroed sockaddr_nl is valid; the fields set are plain integers.
        let mut addr: libc::sockaddr_nl = unsafe { std::mem::zeroed() };
        addr.nl_family = libc::AF_NETLINK as libc::sa_family_t;
        addr.nl_groups =
            (libc::RTMGRP_LINK | libc::RTMGRP_IPV4_IFADDR | libc::RTMGRP_IPV6_IFADDR) as u32;
        // SAFETY: `addr` is a sockaddr_nl of the size given.
        let bound = unsafe {
            libc::bind(
                socket.0.as_raw_fd(),
                (&addr as *const libc::sockaddr_nl).cast(),
                std::mem::size_of::<libc::sockaddr_nl>() as libc::socklen_t,
            )
        };
        (bound == 0).then_some(socket)
    }

    /// One message, or none within `wait`.
    pub fn read(socket: &Socket, buf: &mut [u8], wait: Duration) -> Read {
        let fd = socket.0.as_raw_fd();
        let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        let ms = wait.as_millis().clamp(1, i32::MAX as u128) as i32;
        // SAFETY: one valid pollfd.
        let ready = unsafe { libc::poll(&mut poll, 1, ms) };
        if ready == 0 {
            return Read::Quiet;
        }
        if ready < 0 {
            return match std::io::Error::last_os_error().kind() {
                std::io::ErrorKind::Interrupted => Read::Quiet,
                _ => Read::Failed,
            };
        }
        // SAFETY: `buf` is valid for `buf.len()` bytes.
        let n = unsafe { libc::recv(fd, buf.as_mut_ptr().cast(), buf.len(), 0) };
        match n {
            n if n > 0 => Read::Message(n as usize),
            0 => Read::Failed,
            _ => match std::io::Error::last_os_error().kind() {
                // A burst larger than the socket buffer: something changed.
                std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock => Read::Quiet,
                _ if std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOBUFS) => {
                    Read::Message(0)
                }
                _ => Read::Failed,
            },
        }
    }

    /// Whether a routing message says the network changed: an address added or removed, or an
    /// interface's state. Route additions are left out: macOS adds a cloned host route for many
    /// new connections, which is no change of network. An overflow (no message) counts.
    pub fn is_change(message: &[u8]) -> bool {
        if message.is_empty() {
            return true;
        }
        super::is_change_type(message_type(message))
    }

    /// The message type: macOS `rt_msghdr`'s `rtm_type` (byte 3, after a u16 length and a u8
    /// version), Linux `nlmsghdr`'s `nlmsg_type` (a u16 at byte 4, after a u32 length).
    fn message_type(message: &[u8]) -> u16 {
        if cfg!(target_os = "macos") {
            message.get(3).copied().map_or(0, u16::from)
        } else {
            message.get(4..6).map_or(0, |b| u16::from_ne_bytes([b[0], b[1]]))
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod imp {
    use super::Read;
    use std::time::Duration;

    pub struct Socket;

    pub fn open() -> Option<Socket> {
        None
    }

    pub fn read(_: &Socket, _: &mut [u8], _: Duration) -> Read {
        Read::Failed
    }

    pub fn is_change(_: &[u8]) -> bool {
        false
    }
}

/// The routing message types that are a change of network on this platform.
#[cfg(target_os = "macos")]
fn is_change_type(kind: u16) -> bool {
    [libc::RTM_IFINFO, libc::RTM_NEWADDR, libc::RTM_DELADDR].iter().any(|t| *t as u16 == kind)
}

#[cfg(target_os = "linux")]
fn is_change_type(kind: u16) -> bool {
    [libc::RTM_NEWADDR, libc::RTM_DELADDR, libc::RTM_NEWLINK, libc::RTM_DELLINK].contains(&kind)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A burst of address messages is one change; a cloned host route (macOS adds one for many
    /// new connections) is none.
    #[cfg(target_os = "linux")]
    #[test]
    fn only_address_and_link_messages_are_a_change() {
        assert!(is_change_type(libc::RTM_NEWADDR));
        assert!(is_change_type(libc::RTM_DELLINK));
        assert!(!is_change_type(libc::RTM_NEWROUTE));
        assert!(!is_change_type(libc::RTM_NEWNEIGH));
    }

    /// The watch opens on Linux without privileges (netlink route groups are readable by any
    /// user), so the daemon has it on a fleet Linux host too.
    #[cfg(target_os = "linux")]
    #[test]
    fn the_watch_opens_without_privileges() {
        assert!(imp::open().is_some());
    }
}
