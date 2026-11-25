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

/// The network's change generation for one process. Dropping its last clone ends the watch
/// thread at once: the thread waits on the routing socket and on a pipe this holds the write end
/// of, with no timeout, so an idle watch never wakes (it checked for its owner every 2 s before,
/// 0.5 wakes a second in every acpmux daemon, where the watch is a static nobody drops).
#[derive(Debug, Clone)]
pub struct NetworkWatch {
    generation: Arc<watch::Sender<u64>>,
    /// The wake pipe's write end; closed when the last clone drops, which ends the thread.
    #[allow(dead_code)]
    owner: Option<Arc<OwnerEnd>>,
}

/// The write end of the watch thread's wake pipe: dropped, it hangs up the thread's read end.
#[derive(Debug)]
struct OwnerEnd(#[allow(dead_code)] std::os::fd::OwnedFd);

/// The read end the watch thread polls beside the routing socket: hung up when its owner drops.
#[derive(Debug)]
struct Ended(std::os::fd::OwnedFd);

/// A wake pipe (both ends close on exec), or None when the system has no fd for one.
fn owner_pipe() -> Option<(OwnerEnd, Ended)> {
    use std::os::fd::FromRawFd;
    let mut fds = [0; 2];
    // SAFETY: pipe(2) fills two fds owned below.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return None;
    }
    for fd in fds {
        // SAFETY: fcntl(2) on a fd pipe(2) just opened.
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
    }
    // SAFETY: fresh fds from pipe(2), each owned once.
    let (read, write) = unsafe {
        (std::os::fd::OwnedFd::from_raw_fd(fds[0]), std::os::fd::OwnedFd::from_raw_fd(fds[1]))
    };
    Some((OwnerEnd(write), Ended(read)))
}

impl NetworkWatch {
    /// Starts the kernel watch on its own thread. On a platform without one, or when its socket
    /// cannot be opened, nothing ever bumps the generation: the link relies on its heartbeat,
    /// as before.
    pub fn start() -> Self {
        let mut watch = Self::manual();
        if let (Some(socket), Some((owner, ended))) = (imp::open(), owner_pipe()) {
            let weak = Arc::downgrade(&watch.generation);
            watch.owner = Some(Arc::new(owner));
            let _ =
                std::thread::Builder::new().name("cmux-network-watch".into()).spawn(move || {
                    run_until(
                        socket,
                        ended,
                        usable,
                        || {
                            if let Some(generation) = weak.upgrade() {
                                bump(&generation);
                            }
                        },
                        || {},
                    );
                });
        }
        watch
    }

    /// A watch no kernel socket feeds; [`NetworkWatch::signal`] is its only source.
    pub fn manual() -> Self {
        Self { generation: Arc::new(watch::channel(0).0), owner: None }
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

/// How long the watch waits with no burst open: for ever (`poll`'s -1). Only a routing message
/// or its owner's end wakes it.
const IDLE_WAIT: Option<Duration> = None;

/// Reads `socket` until `ended` hangs up (the owner dropped) or the socket fails: each burst of
/// changes calls `changed` once, [`SETTLE`] after its first message, when `usable` (read then) is
/// not what it was before the burst. With no burst open it waits with no timeout; `woke_idle` is
/// called for each wait that ends with nothing to read and no burst to settle (tests count them).
fn run_until(
    socket: imp::Socket,
    ended: Ended,
    mut usable: impl FnMut() -> Option<Usable>,
    mut changed: impl FnMut(),
    mut woke_idle: impl FnMut(),
) {
    let mut seen = Seen { last: usable() };
    let mut first: Option<Instant> = None;
    let mut buf = vec![0u8; 16 * 1024];
    loop {
        let wait = match first {
            Some(at) => Some(SETTLE.saturating_sub(at.elapsed()).max(Duration::from_millis(1))),
            None => IDLE_WAIT,
        };
        match imp::read(&socket, &ended, &mut buf, wait) {
            Read::Message(n) => {
                if first.is_none() && imp::is_change(buf.get(..n).unwrap_or_default()) {
                    first = Some(Instant::now());
                }
            }
            Read::Quiet => {
                if first.is_none() {
                    woke_idle();
                }
            }
            Read::Ended | Read::Failed => return,
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
    /// The owner's wake pipe hung up: the last `NetworkWatch` dropped.
    Ended,
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

    /// One message, none within `wait` (None: no timeout), or the owner's end.
    pub fn read(
        socket: &Socket,
        ended: &super::Ended,
        buf: &mut [u8],
        wait: Option<Duration>,
    ) -> Read {
        let fd = socket.0.as_raw_fd();
        let mut polls = [
            libc::pollfd { fd, events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: ended.0.as_raw_fd(), events: libc::POLLIN, revents: 0 },
        ];
        let ms = wait.map_or(-1, |wait| wait.as_millis().clamp(1, i32::MAX as u128) as i32);
        // SAFETY: two valid pollfds.
        let ready = unsafe { libc::poll(polls.as_mut_ptr(), 2, ms) };
        if ready == 0 {
            return Read::Quiet;
        }
        if ready < 0 {
            return match std::io::Error::last_os_error().kind() {
                std::io::ErrorKind::Interrupted => Read::Quiet,
                _ => Read::Failed,
            };
        }
        // Nothing is ever written to the pipe: any event on it is the write end closing.
        if polls[1].revents != 0 {
            return Read::Ended;
        }
        if polls[0].revents & libc::POLLIN == 0 {
            return if polls[0].revents == 0 { Read::Quiet } else { Read::Failed };
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

    pub fn read(_: &Socket, _: &super::Ended, _: &mut [u8], _: Option<Duration>) -> Read {
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
        let (owner, ended) = owner_pipe().expect("a wake pipe");
        let counted = generation;
        // The addresses differ after the burst from before it.
        let mut reads = 0u32;
        let usable = move || {
            reads += 1;
            Some(Usable::from([("en0".to_owned(), IpAddr::from([10, 0, 0, reads as u8]))]))
        };
        let thread = std::thread::spawn(move || {
            run_until(imp::Socket(reader), ended, usable, || counted.signal(), || {});
        });
        std::thread::sleep(SETTLE * 3);
        assert_eq!(*receiver.borrow(), 1, "a burst of three messages is one change");
        drop(owner);
        drop(writer);
        thread.join().unwrap();
    }

    /// An idle watch never wakes: no message, no wake (cmux-next idle wakeups). It checked for its
    /// owner every 2 s (`ALIVE_EVERY`), 0.5 wakes a second in every acpmux daemon for its life,
    /// where the watch is a static nobody drops. Its owner's end is now an event: the last
    /// `NetworkWatch` dropped closes the wake pipe, and the thread ends at once.
    #[test]
    fn an_idle_watch_never_wakes_and_ends_when_its_owner_drops() {
        use std::os::fd::FromRawFd;
        use std::sync::atomic::{AtomicU32, Ordering};
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
        let (owner, ended) = owner_pipe().expect("a wake pipe");
        let checks = Arc::new(AtomicU32::new(0));
        let counted = checks.clone();
        let thread = std::thread::spawn(move || {
            run_until(
                imp::Socket(reader),
                ended,
                || None,
                || {},
                || {
                    counted.fetch_add(1, Ordering::SeqCst);
                },
            );
        });
        std::thread::sleep(Duration::from_secs(5));
        assert_eq!(checks.load(Ordering::SeqCst), 0, "the idle watch woke with nothing to read");
        let dropped = Instant::now();
        drop(owner);
        thread.join().unwrap();
        assert!(
            dropped.elapsed() < Duration::from_millis(500),
            "it ended {:?} after its owner",
            dropped.elapsed()
        );
        drop(writer);
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
        let (owner, ended) = owner_pipe().expect("a wake pipe");
        let counted = generation;
        let thread = std::thread::spawn(move || {
            run_until(
                imp::Socket(reader),
                ended,
                || Some(read.lock().unwrap().clone()),
                || counted.signal(),
                || {},
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
