//! Notices when this computer's network changes (an address comes or goes, an interface goes up
//! or down: Wi-Fi back after a wake, a switch of networks, a VPN), so each link that rides the
//! network can act at once: a parked recovery dials now, a dial on the old network is dropped,
//! and a live link is probed. Without it a link that rode the old route waited out its
//! heartbeat, and a parked one its backoff. Its users: cmux-remote's machine link
//! (`network_watch::forward`) and acpmux's peer links (`peer_network.rs`).
//!
//! macOS reads the routing socket (`PF_ROUTE`), Linux its netlink route groups; both are kernel
//! messages read on one thread, with no polling. A burst (an interface coming up adds several
//! addresses) is one change, [`SETTLE`] after its first message, and only when it left this
//! computer's usable addresses ([`Usable`]: each up and running interface's, loopback and IPv6
//! link-local left out) other than they were. A burst that changes none is no change: on
//! a busy Mac (2026-11-22) a VM bridge (`bridge0`) added and removed the same ULA address every
//! minute or two, and each such burst had all 39 peer links probe and several reconnect (1-6 MB
//! of frames each). An address list that cannot be read counts as a change, as before.
//!
//! Each change bumps a generation. A link phase that starts later (the first connect, a
//! recovery) does not subscribe afresh, which would mark a change made in between as seen: the
//! owner takes one receiver before its first dial and keeps it, so a change made while it was
//! dialing still reaches the link once it exists.

use std::collections::BTreeSet;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::watch;

/// How long a burst of routing messages is gathered into one change.
pub const SETTLE: Duration = Duration::from_millis(300);

/// How often the thread, blocked on the socket, wakes to see whether its owner is still there.
const ALIVE_EVERY: Duration = Duration::from_secs(2);

/// The network's change generation for one process. Dropping it ends the watch thread within
/// [`ALIVE_EVERY`].
#[derive(Debug, Clone)]
pub struct NetworkWatch {
    generation: Arc<watch::Sender<u64>>,
}

impl NetworkWatch {
    /// Starts the kernel watch on its own thread. On a platform without one, or when its socket
    /// cannot be opened, nothing ever bumps the generation: the link relies on its heartbeat,
    /// as before.
    pub fn start() -> Self {
        let watch = Self::manual();
        if let Some(socket) = imp::open() {
            let weak = Arc::downgrade(&watch.generation);
            let _ =
                std::thread::Builder::new().name("cmux-network-watch".into()).spawn(move || {
                    run(
                        socket,
                        || weak.strong_count() > 0,
                        usable,
                        || {
                            if let Some(generation) = weak.upgrade() {
                                bump(&generation);
                            }
                        },
                    );
                });
        }
        watch
    }

    /// A watch no kernel socket feeds; [`NetworkWatch::signal`] is its only source.
    pub fn manual() -> Self {
        Self { generation: Arc::new(watch::channel(0).0) }
    }

    /// Record a change, as the kernel watch does after a burst settles.
    pub fn signal(&self) {
        bump(&self.generation);
    }

    /// A receiver that sees every change made after this call, however late it is read.
    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.generation.subscribe()
    }
}

fn bump(generation: &watch::Sender<u64>) {
    generation.send_modify(|value| *value = value.wrapping_add(1));
}

/// This computer's usable addresses: each address of an interface that is up and running, by
/// interface, leaving out loopback and IPv6 link-local ones (`fe80::/10`, which every interface
/// has, AWDL's and a VM bridge's too, and no peer link rides). None when they cannot be read.
pub type Usable = BTreeSet<(String, IpAddr)>;

/// Whether a settled burst changed the network: the usable addresses differ from the last ones
/// read, or cannot be read (then every burst counts, as before this check).
#[derive(Debug)]
struct Seen {
    last: Option<Usable>,
}

impl Seen {
    fn changed(&mut self, now: Option<Usable>) -> bool {
        let changed = now.is_none() || now != self.last;
        self.last = now;
        changed
    }
}

/// Reads `socket` until `alive` says no (read at least every [`ALIVE_EVERY`]) or the socket
/// fails: each burst of changes calls `changed` once, [`SETTLE`] after its first message, when
/// `usable` (read then) is not what it was before the burst.
fn run(
    socket: imp::Socket,
    alive: impl Fn() -> bool,
    mut usable: impl FnMut() -> Option<Usable>,
    mut changed: impl FnMut(),
) {
    let mut seen = Seen { last: usable() };
    let mut first: Option<Instant> = None;
    let mut buf = vec![0u8; 16 * 1024];
    loop {
        let wait = match first {
            Some(at) => SETTLE.saturating_sub(at.elapsed()).max(Duration::from_millis(1)),
            None => ALIVE_EVERY,
        };
        match imp::read(&socket, &mut buf, wait) {
            Read::Message(n) => {
                if first.is_none() && imp::is_change(buf.get(..n).unwrap_or_default()) {
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
            if seen.changed(usable()) {
                changed();
            }
        }
    }
}

/// This computer's usable addresses now ([`Usable`]), read with `getifaddrs` (no process, no
/// socket); None when the list cannot be read.
#[cfg(unix)]
pub fn usable() -> Option<Usable> {
    use std::net::{Ipv4Addr, Ipv6Addr};
    let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: `list` is a valid out pointer; freed below.
    if unsafe { libc::getifaddrs(&mut list) } != 0 {
        return None;
    }
    let wanted = (libc::IFF_UP | libc::IFF_RUNNING) as libc::c_uint;
    let mut out = Usable::new();
    let mut at = list;
    while !at.is_null() {
        // SAFETY: a non-null node of the list getifaddrs returned.
        let entry = unsafe { &*at };
        at = entry.ifa_next;
        let flags = entry.ifa_flags;
        if entry.ifa_addr.is_null()
            || flags & wanted != wanted
            || flags & libc::IFF_LOOPBACK as libc::c_uint != 0
        {
            continue;
        }
        // SAFETY: ifa_addr is non-null and points to a sockaddr whose family tells its type.
        let family = i32::from(unsafe { (*entry.ifa_addr).sa_family });
        let ip = if family == libc::AF_INET {
            // SAFETY: an AF_INET address is a sockaddr_in.
            let sin = unsafe { &*entry.ifa_addr.cast::<libc::sockaddr_in>() };
            IpAddr::V4(Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr)))
        } else if family == libc::AF_INET6 {
            // SAFETY: an AF_INET6 address is a sockaddr_in6.
            let sin6 = unsafe { &*entry.ifa_addr.cast::<libc::sockaddr_in6>() };
            let v6 = Ipv6Addr::from(sin6.sin6_addr.s6_addr);
            if v6.is_unicast_link_local() {
                continue;
            }
            IpAddr::V6(v6)
        } else {
            continue;
        };
        // SAFETY: ifa_name is a NUL-terminated name getifaddrs filled.
        let name = unsafe { std::ffi::CStr::from_ptr(entry.ifa_name) };
        out.insert((name.to_string_lossy().into_owned(), ip));
    }
    // SAFETY: the list getifaddrs returned, freed once.
    unsafe { libc::freeifaddrs(list) };
    Some(out)
}

#[cfg(not(unix))]
pub fn usable() -> Option<Usable> {
    None
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

    pub struct Socket(pub OwnedFd);

    #[cfg(target_os = "macos")]
    pub fn open() -> Option<Socket> {
        // SAFETY: plain socket(2); the fd is owned below.
        let fd = unsafe { libc::socket(libc::PF_ROUTE, libc::SOCK_RAW, libc::AF_UNSPEC) };
        if fd < 0 {
            return None;
        }
        // SAFETY: a valid fd this function just opened and nothing else owns.
        let socket = Socket(unsafe { OwnedFd::from_raw_fd(fd) });
        // No ssh this process starts inherits it.
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
                size_of::<libc::sockaddr_nl>() as libc::socklen_t,
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
        if n > 0 {
            return Read::Message(n as usize);
        }
        if n == 0 {
            return Read::Failed;
        }
        let error = std::io::Error::last_os_error();
        match error.kind() {
            std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock => Read::Quiet,
            // A burst larger than the socket buffer: something changed.
            _ if error.raw_os_error() == Some(libc::ENOBUFS) => Read::Message(0),
            _ => Read::Failed,
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
            message
                .get(4..6)
                .and_then(|b| <[u8; 2]>::try_from(b).ok())
                .map_or(0, u16::from_ne_bytes)
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

// Every test here drives the Linux netlink watch.
#[cfg(test)]
#[cfg(target_os = "linux")]
mod tests {
    use super::*;

    /// Address and link messages are a change; a new route or neighbour (macOS clones a host
    /// route for many new connections) is none.
    #[test]
    fn only_address_and_link_messages_are_a_change() {
        assert!(is_change_type(libc::RTM_NEWADDR));
        assert!(is_change_type(libc::RTM_DELLINK));
        assert!(!is_change_type(libc::RTM_NEWROUTE));
        assert!(!is_change_type(libc::RTM_NEWNEIGH));
        assert!(imp::is_change(&[]), "an overflowed burst counts as a change");
    }

    /// The watch opens on Linux without privileges (netlink route groups are readable by any
    /// user), so a link on a fleet Linux host has it too.
    #[test]
    fn the_watch_opens_without_privileges() {
        assert!(imp::open().is_some());
    }

    /// A burst of messages is one change, called once it settles; the thread ends when its
    /// owner is gone.
    #[test]
    fn a_burst_is_one_change_and_the_thread_ends_with_its_owner() {
        let generation = NetworkWatch::manual();
        let receiver = generation.subscribe();
        // A socketpair stands in for the routing socket: three NEWADDR messages at once.
        let mut fds = [0; 2];
        // SAFETY: socketpair(2) fills two fds this test owns.
        assert_eq!(
            unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_DGRAM, 0, fds.as_mut_ptr()) },
            0
        );
        use std::os::fd::FromRawFd;
        // SAFETY: fresh fds from socketpair, owned once each.
        let (reader, writer) = unsafe {
            (std::os::fd::OwnedFd::from_raw_fd(fds[0]), std::os::fd::OwnedFd::from_raw_fd(fds[1]))
        };
        let mut message = [0u8; 16];
        message[4..6].copy_from_slice(&libc::RTM_NEWADDR.to_ne_bytes());
        for _ in 0..3 {
            use std::os::fd::AsRawFd;
            // SAFETY: a valid buffer of the given length.
            let sent = unsafe {
                libc::send(writer.as_raw_fd(), message.as_ptr().cast(), message.len(), 0)
            };
            assert_eq!(sent, message.len() as isize);
        }
        let owner = Arc::new(());
        let alive = Arc::downgrade(&owner);
        let counted = generation;
        // The addresses differ after the burst from before it.
        let mut reads = 0u32;
        let usable = move || {
            reads += 1;
            Some(Usable::from([("en0".to_owned(), IpAddr::from([10, 0, 0, reads as u8]))]))
        };
        let thread = std::thread::spawn(move || {
            run(imp::Socket(reader), || alive.strong_count() > 0, usable, || counted.signal());
        });
        std::thread::sleep(SETTLE * 3);
        assert_eq!(*receiver.borrow(), 1, "a burst of three messages is one change");
        drop(owner);
        drop(writer);
        thread.join().unwrap();
    }

    /// A burst that leaves the usable addresses as they were (an address added and removed at
    /// once, as a VM bridge did every minute on a busy Mac) is no change; one that leaves them
    /// otherwise is.
    #[test]
    fn a_burst_that_leaves_the_addresses_as_they_were_is_no_change() {
        use std::os::fd::{AsRawFd, FromRawFd};
        use std::sync::Mutex;
        let generation = NetworkWatch::manual();
        let receiver = generation.subscribe();
        let mut fds = [0; 2];
        // SAFETY: socketpair(2) fills two fds this test owns.
        assert_eq!(
            unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_DGRAM, 0, fds.as_mut_ptr()) },
            0
        );
        // SAFETY: fresh fds from socketpair, owned once each.
        let (reader, writer) = unsafe {
            (std::os::fd::OwnedFd::from_raw_fd(fds[0]), std::os::fd::OwnedFd::from_raw_fd(fds[1]))
        };
        let send = |kind: u16| {
            let mut message = [0u8; 16];
            message[4..6].copy_from_slice(&kind.to_ne_bytes());
            // SAFETY: a valid buffer of the given length.
            let sent = unsafe {
                libc::send(writer.as_raw_fd(), message.as_ptr().cast(), message.len(), 0)
            };
            assert_eq!(sent, message.len() as isize);
        };
        let wifi = ("en0".to_owned(), IpAddr::from([192, 168, 1, 20]));
        let now = Arc::new(Mutex::new(Usable::from([wifi])));
        let read = now.clone();
        let owner = Arc::new(());
        let alive = Arc::downgrade(&owner);
        let counted = generation;
        let thread = std::thread::spawn(move || {
            run(
                imp::Socket(reader),
                || alive.strong_count() > 0,
                || Some(read.lock().unwrap().clone()),
                || counted.signal(),
            );
        });
        // The bridge's flap: an address added and removed in one burst.
        send(libc::RTM_NEWADDR);
        send(libc::RTM_DELADDR);
        std::thread::sleep(SETTLE * 3);
        assert_eq!(*receiver.borrow(), 0, "an address added and removed again is no change");
        // A real change: Wi-Fi's address is another one.
        *now.lock().unwrap() = Usable::from([("en0".to_owned(), IpAddr::from([10, 1, 0, 7]))]);
        send(libc::RTM_NEWADDR);
        std::thread::sleep(SETTLE * 3);
        assert_eq!(*receiver.borrow(), 1, "a new address is a change");
        drop(owner);
        drop(writer);
        thread.join().unwrap();
    }
}

/// Runs on every platform: what the watch decides of a settled burst.
#[cfg(test)]
mod seen_tests {
    use super::*;

    fn addresses(list: &[(&str, [u8; 4])]) -> Option<Usable> {
        Some(list.iter().map(|(name, ip)| ((*name).to_owned(), IpAddr::from(*ip))).collect())
    }

    /// The harness behind the PR's numbers: an hour of the churn a busy Mac's routing socket
    /// showed (a VM bridge adding and removing one address in one burst, about once a minute)
    /// with two real changes in it (Wi-Fi to another network, a VPN coming up). Before, every
    /// settled burst was a change; now only the two real ones are.
    #[test]
    fn an_hour_of_bridge_flaps_is_two_changes_not_sixty_two() {
        let wifi = addresses(&[("en0", [192, 168, 1, 20])]);
        let moved = addresses(&[("en0", [10, 1, 0, 7])]);
        let vpn = addresses(&[("en0", [10, 1, 0, 7]), ("utun4", [100, 64, 0, 3])]);
        let mut seen = Seen { last: wifi.clone() };
        let (mut before, mut after) = (0, 0);
        for minute in 0..60 {
            // The flap's burst settles with the addresses as they were.
            let now = match minute {
                0..20 => wifi.clone(),
                20..40 => moved.clone(),
                _ => vpn.clone(),
            };
            before += 1;
            after += u32::from(seen.changed(now.clone()));
            // The real change's own burst, once each.
            if minute == 19 {
                before += 1;
                after += u32::from(seen.changed(moved.clone()));
            }
            if minute == 39 {
                before += 1;
                after += u32::from(seen.changed(vpn.clone()));
            }
        }
        eprintln!("settled bursts in the hour: {before}; changes signalled: {after}");
        assert_eq!(before, 62);
        assert_eq!(after, 2, "only Wi-Fi's new address and the VPN's are changes");
    }

    /// An address list that cannot be read counts every burst, as the watch did before.
    #[test]
    fn an_unreadable_address_list_counts_every_burst() {
        let mut seen = Seen { last: None };
        assert!(seen.changed(None));
        assert!(seen.changed(None));
    }

    /// The live list reads on this machine: loopback and IPv6 link-local are never in it.
    #[test]
    fn the_usable_list_leaves_out_loopback_and_link_local() {
        let Some(now) = usable() else { return };
        for (_, ip) in &now {
            assert!(!ip.is_loopback(), "{ip}");
            if let IpAddr::V6(v6) = ip {
                assert!(!v6.is_unicast_link_local(), "{v6}");
            }
        }
    }
}
