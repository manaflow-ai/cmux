//! Notices when this computer's network changes (an address comes or goes, an interface goes up
//! or down, the default route moves: Wi-Fi back after a wake, a switch of networks, a VPN), so
//! each link that rides the network can act at once: a parked recovery dials now, a dial on the
//! old network is dropped, and a live link is probed. Without it a link that rode the old route
//! waited out its heartbeat, and a parked one its backoff. Its users: cmux-remote's machine link
//! (`network_watch::forward`) and acpmux's peer links (`peer_network.rs`).
//!
//! macOS reads the routing socket (`PF_ROUTE`), Linux its netlink route groups; both are kernel
//! messages read on one thread, with no polling. A message is only a reason to look: [`SETTLE`]
//! after the first of a burst, the watch reads the network (`Snapshot`: addresses with their
//! prefix, the interfaces that are up, the default routes) and counts a change only when that
//! differs from the last one. A router advertisement every few seconds refreshes the lifetimes
//! of the addresses it gave, and the kernel sends RTM_NEWADDR for each: before, every one was a
//! change, and each parked peer link redialed (one ssh per advertisement, every 3 s). After a
//! change the next look waits [`SPACING`], so a burst that runs on (DHCP, a Wi-Fi roam) is at
//! most one more change.
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

/// How long a burst of routing messages is gathered before the watch looks at the network.
pub const SETTLE: Duration = Duration::from_millis(300);

/// How long after a change the next look waits, so a burst that runs past [`SETTLE`] is one more
/// change at most, not one per message.
pub const SPACING: Duration = Duration::from_secs(2);

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

/// Reads `socket` until `alive` says no (read at least every [`ALIVE_EVERY`]) or the socket
/// fails: each burst of messages that leaves the network different calls `changed` once.
fn run(socket: imp::Socket, alive: impl Fn() -> bool, changed: impl FnMut()) {
    run_with(socket, imp::snapshot, alive, changed);
}

/// [`run`], reading the network with `look` (`None` when it cannot be read, which counts as a
/// change, as every message did before).
fn run_with(
    socket: imp::Socket,
    mut look: impl FnMut() -> Option<Snapshot>,
    alive: impl Fn() -> bool,
    mut changed: impl FnMut(),
) {
    let mut changes = Changes::new(look());
    let mut buf = vec![0u8; 16 * 1024];
    loop {
        let wait = changes.look_at().map_or(ALIVE_EVERY, |at| {
            at.saturating_duration_since(Instant::now())
                .clamp(Duration::from_millis(1), ALIVE_EVERY)
        });
        match imp::read(&socket, &mut buf, wait) {
            Read::Message(n) => {
                if imp::may_change(buf.get(..n).unwrap_or_default()) {
                    changes.message(Instant::now());
                }
            }
            Read::Quiet => {}
            Read::Failed => return,
        }
        if !alive() {
            return;
        }
        let now = Instant::now();
        if changes.look_at().is_some_and(|at| now >= at) && changes.look(now, look()) {
            changed();
        }
    }
}

/// What the network is, as far as a link cares: each address with its prefix and interface,
/// each interface that is up and running, and the default routes (Linux; on macOS a new
/// default route comes with an address or interface change). Lifetimes and address flags are
/// not in it, so a refresh of what is already held reads the same.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Snapshot(BTreeSet<Item>);

// Read only through the derives; a platform with no watch builds none.
#[cfg_attr(not(any(target_os = "macos", target_os = "linux")), allow(dead_code))]
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
enum Item {
    Address {
        interface: String,
        ip: IpAddr,
        prefix: u8,
    },
    Up {
        interface: String,
    },
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    DefaultRoute {
        interface: String,
        gateway: Option<IpAddr>,
    },
}

/// When to look at the network, and whether what it read is a change: the pure part of
/// [`run_with`], driven by message times and snapshots.
struct Changes {
    /// The network as last counted; `None` when it could not be read.
    seen: Option<Snapshot>,
    /// The first message since the last look.
    first: Option<Instant>,
    /// No look before this, after a change ([`SPACING`]).
    quiet_until: Option<Instant>,
}

impl Changes {
    fn new(seen: Option<Snapshot>) -> Self {
        Self { seen, first: None, quiet_until: None }
    }

    /// A routing message that may be a change arrived at `at`.
    fn message(&mut self, at: Instant) {
        self.first.get_or_insert(at);
    }

    /// When to look next; `None` while no message waits.
    fn look_at(&self) -> Option<Instant> {
        let settled = self.first? + SETTLE;
        Some(self.quiet_until.map_or(settled, |quiet| quiet.max(settled)))
    }

    /// Takes `now`, the network read at `at`: whether it differs from the last one counted. A
    /// network that cannot be read counts as a change.
    fn look(&mut self, at: Instant, now: Option<Snapshot>) -> bool {
        self.first = None;
        if now.is_some() && now == self.seen {
            return false;
        }
        self.seen = now;
        self.quiet_until = Some(at + SPACING);
        true
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
        // Routes too, so a default route that moves alone is looked at; the snapshot compare
        // keeps a route message that changes nothing (a router advertisement's refresh) quiet.
        addr.nl_groups = (libc::RTMGRP_LINK
            | libc::RTMGRP_IPV4_IFADDR
            | libc::RTMGRP_IPV6_IFADDR
            | libc::RTMGRP_IPV4_ROUTE
            | libc::RTMGRP_IPV6_ROUTE) as u32;
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

    /// Whether a routing message may mean the network changed, so the watch looks: an address
    /// added or removed, an interface's state, and on Linux a route. macOS route additions are
    /// left out: it adds a cloned host route for many new connections. An overflow (no message)
    /// counts.
    pub fn may_change(message: &[u8]) -> bool {
        if message.is_empty() {
            return true;
        }
        super::may_change_type(message_type(message))
    }

    /// The network now: every address of `getifaddrs(3)` with its prefix, every interface that
    /// is up and running, and on Linux the default routes. `None` when it cannot be read.
    pub fn snapshot() -> Option<super::Snapshot> {
        use super::Item;
        let mut items = std::collections::BTreeSet::new();
        let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
        // SAFETY: getifaddrs(3) fills `list`, freed below.
        if unsafe { libc::getifaddrs(&mut list) } != 0 {
            return None;
        }
        let up = (libc::IFF_UP | libc::IFF_RUNNING) as libc::c_uint;
        let mut at = list;
        while !at.is_null() {
            // SAFETY: a node of the list getifaddrs returned, alive until freeifaddrs below.
            let entry = unsafe { &*at };
            at = entry.ifa_next;
            if entry.ifa_name.is_null() {
                continue;
            }
            // SAFETY: a NUL-terminated name owned by the list.
            let interface =
                unsafe { std::ffi::CStr::from_ptr(entry.ifa_name) }.to_string_lossy().into_owned();
            if entry.ifa_flags & up == up {
                items.insert(Item::Up { interface: interface.clone() });
            }
            // SAFETY: sockaddrs of the list, or null.
            if let Some(ip) = unsafe { ip_of(entry.ifa_addr) } {
                // SAFETY: as above; the netmask has the address's family.
                let prefix = unsafe { prefix_of(entry.ifa_netmask, ip.is_ipv4()) };
                items.insert(Item::Address { interface, ip, prefix });
            }
        }
        // SAFETY: the list getifaddrs returned, freed once; no reference into it outlives this.
        unsafe { libc::freeifaddrs(list) };
        #[cfg(target_os = "linux")]
        items.extend(default_routes()?);
        Some(super::Snapshot(items))
    }

    /// The main table's default routes, from a netlink route dump (`RTM_GETROUTE`), each with
    /// its interface's name. `None` when the dump fails or runs past [`DUMP_LIMIT`].
    #[cfg(target_os = "linux")]
    fn default_routes() -> Option<Vec<super::Item>> {
        // SAFETY: plain socket(2); the fd is owned below.
        let fd = unsafe {
            libc::socket(libc::AF_NETLINK, libc::SOCK_RAW | libc::SOCK_CLOEXEC, libc::NETLINK_ROUTE)
        };
        if fd < 0 {
            return None;
        }
        // SAFETY: a valid fd this function just opened and nothing else owns.
        let socket = Socket(unsafe { OwnedFd::from_raw_fd(fd) });
        // An nlmsghdr (length, type, flags, sequence, port) and an rtmsg of family AF_UNSPEC:
        // every route of both families.
        let mut request = [0u8; 28];
        request[0..4].copy_from_slice(&28u32.to_ne_bytes());
        request[4..6].copy_from_slice(&libc::RTM_GETROUTE.to_ne_bytes());
        request[6..8]
            .copy_from_slice(&((libc::NLM_F_REQUEST | libc::NLM_F_DUMP) as u16).to_ne_bytes());
        request[8..12].copy_from_slice(&1u32.to_ne_bytes());
        // SAFETY: a valid buffer of the given length; an unbound netlink socket sends to the
        // kernel.
        let sent = unsafe { libc::send(fd, request.as_ptr().cast(), request.len(), 0) };
        if sent != request.len() as isize {
            return None;
        }
        let mut found = Vec::new();
        let mut buf = vec![0u8; 64 * 1024];
        let deadline = std::time::Instant::now() + DUMP_LIMIT;
        loop {
            let wait = deadline.saturating_duration_since(std::time::Instant::now());
            if wait.is_zero() {
                return None;
            }
            match read(&socket, &mut buf, wait) {
                Read::Message(n) if n > 0 => {
                    if super::default_routes_in(buf.get(..n)?, &mut found)? {
                        break;
                    }
                }
                Read::Quiet => {}
                Read::Message(_) | Read::Failed => return None,
            }
        }
        Some(
            found
                .into_iter()
                .map(|(index, gateway)| super::Item::DefaultRoute {
                    interface: interface_name(index),
                    gateway,
                })
                .collect(),
        )
    }

    /// How long a route dump may take; the kernel answers one in well under a millisecond.
    // timeout: a dump that never ends must not hold the watch thread; the look counts as a
    // change, as an unreadable network does.
    #[cfg(target_os = "linux")]
    const DUMP_LIMIT: Duration = Duration::from_secs(1);

    /// The name of interface `index`, or the index itself when it has none (gone since).
    #[cfg(target_os = "linux")]
    fn interface_name(index: u32) -> String {
        let mut name = [0 as libc::c_char; libc::IF_NAMESIZE];
        // SAFETY: `name` holds IF_NAMESIZE bytes, as if_indextoname(3) needs.
        if unsafe { libc::if_indextoname(index, name.as_mut_ptr()) }.is_null() {
            return index.to_string();
        }
        // SAFETY: if_indextoname wrote a NUL-terminated name into `name`.
        unsafe { std::ffi::CStr::from_ptr(name.as_ptr()) }.to_string_lossy().into_owned()
    }

    /// The IPv4 or IPv6 address in `sa`, or `None` for another family or null.
    ///
    /// # Safety
    /// `sa` is null or points at a sockaddr as large as its family's.
    unsafe fn ip_of(sa: *const libc::sockaddr) -> Option<std::net::IpAddr> {
        if sa.is_null() {
            return None;
        }
        // SAFETY: a valid sockaddr (caller); read as the struct its family names.
        unsafe {
            match i32::from((*sa).sa_family) {
                libc::AF_INET => {
                    let sin = &*sa.cast::<libc::sockaddr_in>();
                    Some(std::net::Ipv4Addr::from(sin.sin_addr.s_addr.to_ne_bytes()).into())
                }
                libc::AF_INET6 => {
                    let sin6 = &*sa.cast::<libc::sockaddr_in6>();
                    Some(std::net::Ipv6Addr::from(sin6.sin6_addr.s6_addr).into())
                }
                _ => None,
            }
        }
    }

    /// The prefix length of netmask `mask` (its set bits). macOS may give a netmask shorter
    /// than its struct (`sa_len`), and with no family; only the bytes it has are read.
    ///
    /// # Safety
    /// `mask` is null or points at a sockaddr of `sa_len` bytes (macOS) or of the address's
    /// family's size (Linux).
    unsafe fn prefix_of(mask: *const libc::sockaddr, v4: bool) -> u8 {
        if mask.is_null() {
            return 0;
        }
        let (offset, size) = if v4 {
            (std::mem::offset_of!(libc::sockaddr_in, sin_addr), 4)
        } else {
            (std::mem::offset_of!(libc::sockaddr_in6, sin6_addr), 16)
        };
        #[cfg(target_os = "macos")]
        // SAFETY: a valid sockaddr header (caller).
        let size = usize::from(unsafe { (*mask).sa_len }).saturating_sub(offset).min(size);
        // SAFETY: `size` bytes past `offset` lie inside the sockaddr (caller, and `sa_len` above).
        let bytes = unsafe { std::slice::from_raw_parts(mask.cast::<u8>().add(offset), size) };
        bytes.iter().map(|b| b.count_ones()).sum::<u32>() as u8
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

    pub fn may_change(_: &[u8]) -> bool {
        false
    }

    pub fn snapshot() -> Option<super::Snapshot> {
        None
    }
}

/// The routing message types that may be a change of network on this platform.
#[cfg(target_os = "macos")]
fn may_change_type(kind: u16) -> bool {
    [libc::RTM_IFINFO, libc::RTM_NEWADDR, libc::RTM_DELADDR].iter().any(|t| *t as u16 == kind)
}

#[cfg(target_os = "linux")]
fn may_change_type(kind: u16) -> bool {
    [
        libc::RTM_NEWADDR,
        libc::RTM_DELADDR,
        libc::RTM_NEWLINK,
        libc::RTM_DELLINK,
        libc::RTM_NEWROUTE,
        libc::RTM_DELROUTE,
    ]
    .contains(&kind)
}

/// One read of a netlink route dump: pushes each main-table unicast default route's output
/// interface index and gateway onto `routes`. Metrics, expiry and the rest are left out, so a
/// router advertisement that refreshes its route reads the same. `Some(true)` once the dump is
/// done, `None` when the kernel refused it or a message is cut short.
#[cfg(target_os = "linux")]
fn default_routes_in(messages: &[u8], routes: &mut Vec<(u32, Option<IpAddr>)>) -> Option<bool> {
    const HEADER: usize = 16;
    let mut rest = messages;
    while rest.len() >= HEADER {
        let len = u32_at(rest, 0)? as usize;
        let kind = u16_at(rest, 4)?;
        let message = rest.get(..len).filter(|_| len >= HEADER)?;
        if kind == libc::NLMSG_DONE as u16 {
            return Some(true);
        }
        if kind == libc::NLMSG_ERROR as u16 {
            return None;
        }
        if kind == libc::RTM_NEWROUTE
            && let Some(route) = default_route(message.get(HEADER..)?)
        {
            routes.push(route);
        }
        rest = rest.get(align4(len)..).unwrap_or_default();
    }
    Some(false)
}

/// An rtmsg and its attributes: its output interface index and gateway, when it is a unicast
/// default route (no destination prefix) of the main table.
#[cfg(target_os = "linux")]
fn default_route(body: &[u8]) -> Option<(u32, Option<IpAddr>)> {
    // family, dst_len, src_len, tos, table, protocol, scope, type, then a u32 of flags.
    const RTMSG: usize = 12;
    let [family, dst_len, _, _, table, _, _, kind] = *body.get(..8)? else {
        return None;
    };
    if dst_len != 0 || kind != libc::RTN_UNICAST {
        return None;
    }
    let mut table = u32::from(table);
    let (mut index, mut gateway) = (0, None);
    let mut attrs = body.get(RTMSG..)?;
    while attrs.len() >= 4 {
        let len = usize::from(u16_at(attrs, 0)?);
        let attr = u16_at(attrs, 2)?;
        let data = attrs.get(4..len).filter(|_| len >= 4)?;
        if attr == libc::RTA_TABLE {
            table = u32_at(data, 0)?;
        } else if attr == libc::RTA_OIF {
            index = u32_at(data, 0)?;
        } else if attr == libc::RTA_GATEWAY {
            gateway = match i32::from(family) {
                libc::AF_INET => <[u8; 4]>::try_from(data).ok().map(IpAddr::from),
                libc::AF_INET6 => <[u8; 16]>::try_from(data).ok().map(IpAddr::from),
                _ => None,
            };
        }
        attrs = attrs.get(align4(len)..).unwrap_or_default();
    }
    (table == u32::from(libc::RT_TABLE_MAIN)).then_some((index, gateway))
}

#[cfg(target_os = "linux")]
fn u16_at(bytes: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_ne_bytes(bytes.get(at..at + 2)?.try_into().ok()?))
}

#[cfg(target_os = "linux")]
fn u32_at(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_ne_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
}

/// Netlink pads each message and attribute to 4 bytes.
#[cfg(target_os = "linux")]
fn align4(len: usize) -> usize {
    (len + 3) & !3
}

// Every test here drives the Linux netlink watch.
#[cfg(test)]
#[cfg(target_os = "linux")]
mod tests {
    use super::*;

    /// Address, link and route messages are a reason to look; a neighbour is none.
    #[test]
    fn address_link_and_route_messages_are_a_reason_to_look() {
        assert!(may_change_type(libc::RTM_NEWADDR));
        assert!(may_change_type(libc::RTM_DELLINK));
        assert!(may_change_type(libc::RTM_NEWROUTE));
        assert!(!may_change_type(libc::RTM_NEWNEIGH));
        assert!(imp::may_change(&[]), "an overflowed burst is a reason to look");
    }

    fn address(ip: &str, prefix: u8) -> Item {
        Item::Address { interface: "wlan0".into(), ip: ip.parse().unwrap(), prefix }
    }

    fn network(items: &[Item]) -> Option<Snapshot> {
        Some(Snapshot(items.iter().cloned().collect()))
    }

    /// The bug: a router advertisement every 3 s refreshes the IPv6 lifetimes and the kernel
    /// sends RTM_NEWADDR for each address it already holds. A day of them is no change.
    #[test]
    fn repeated_lifetime_refreshes_are_no_change() {
        let held = [address("192.168.1.20", 24), address("2001:db8::20", 64)];
        let mut changes = Changes::new(network(&held));
        let start = Instant::now();
        let mut counted = 0;
        for advertisement in 0..28_800u32 {
            let at = start + Duration::from_secs(3) * advertisement;
            changes.message(at);
            changes.message(at + Duration::from_millis(5));
            let look = changes.look_at().unwrap();
            assert_eq!(look, at + SETTLE);
            counted += u32::from(changes.look(look, network(&held)));
            assert_eq!(changes.look_at(), None);
        }
        assert_eq!(counted, 0);
    }

    /// An address that really comes, or goes, is one change, [`SETTLE`] after its message.
    #[test]
    fn an_address_that_comes_or_goes_is_one_change() {
        let before = [address("192.168.1.20", 24)];
        let after = [address("192.168.1.20", 24), address("2001:db8::20", 64)];
        let mut changes = Changes::new(network(&before));
        let start = Instant::now();
        changes.message(start);
        assert_eq!(changes.look_at(), Some(start + SETTLE));
        assert!(changes.look(start + SETTLE, network(&after)), "an address came");
        // Its refreshes after are none.
        let later = start + Duration::from_secs(10);
        changes.message(later);
        assert!(!changes.look(changes.look_at().unwrap(), network(&after)));
        // A prefix that changes is a different address.
        let renumbered = [address("192.168.1.20", 16), address("2001:db8::20", 64)];
        let at = start + Duration::from_secs(20);
        changes.message(at);
        assert!(changes.look(changes.look_at().unwrap(), network(&renumbered)));
        let gone = start + Duration::from_secs(30);
        changes.message(gone);
        assert!(changes.look(changes.look_at().unwrap(), network(&before[..0])), "it went");
    }

    /// A burst that runs past [`SETTLE`] (DHCP after the link comes up) waits [`SPACING`]
    /// after the change it gave, then is one more look, not one per message.
    #[test]
    fn a_burst_after_a_change_waits_the_spacing() {
        let up = Item::Up { interface: "wlan0".into() };
        let mut changes = Changes::new(network(&[]));
        let start = Instant::now();
        changes.message(start);
        assert!(changes.look(start + SETTLE, network(std::slice::from_ref(&up))));
        for ms in [500, 900, 1300] {
            changes.message(start + Duration::from_millis(ms));
        }
        assert_eq!(changes.look_at(), Some(start + SETTLE + SPACING));
        let full = [up, address("192.168.1.20", 24)];
        assert!(changes.look(start + SETTLE + SPACING, network(&full)));
        assert_eq!(changes.look_at(), None);
    }

    /// A network that cannot be read counts as a change, as every message did before.
    #[test]
    fn an_unreadable_network_is_a_change() {
        let mut changes = Changes::new(None);
        let start = Instant::now();
        changes.message(start);
        assert!(changes.look(start + SETTLE, None));
    }

    /// One RTM_NEWROUTE message: an rtmsg (`family`, `dst_len`, `table`, unicast) and its
    /// attributes.
    fn route(family: u8, dst_len: u8, table: u8, attrs: &[(u16, &[u8])]) -> Vec<u8> {
        let mut body = vec![family, dst_len, 0, 0, table, 0, 0, libc::RTN_UNICAST];
        body.extend_from_slice(&0u32.to_ne_bytes());
        for (kind, data) in attrs {
            body.extend_from_slice(&((4 + data.len()) as u16).to_ne_bytes());
            body.extend_from_slice(&kind.to_ne_bytes());
            body.extend_from_slice(data);
            body.resize(align4(body.len()), 0);
        }
        message(libc::RTM_NEWROUTE, &body)
    }

    fn message(kind: u16, body: &[u8]) -> Vec<u8> {
        let mut out = ((16 + body.len()) as u32).to_ne_bytes().to_vec();
        out.extend_from_slice(&kind.to_ne_bytes());
        out.extend_from_slice(&[0; 10]);
        out.extend_from_slice(body);
        out
    }

    /// A route dump gives the main table's default routes, each with its interface and
    /// gateway; other routes and tables are left out, and so are metrics and expiry (a router
    /// advertisement's refresh changes only those).
    #[test]
    fn a_route_dump_gives_the_main_default_routes() {
        let (gateway, oif, metric, expires) =
            // RTA_EXPIRES is 23 (linux/rtnetlink.h).
            (libc::RTA_GATEWAY, libc::RTA_OIF, libc::RTA_PRIORITY, 23u16);
        let main = libc::RT_TABLE_MAIN;
        let index = 3u32.to_ne_bytes();
        let v6_gateway: std::net::Ipv6Addr = "fe80::1".parse().unwrap();
        let dump = |metric_value: u32, expiry: u32| {
            let mut dump = route(
                libc::AF_INET as u8,
                0,
                main,
                &[
                    (gateway, &[192, 168, 1, 1]),
                    (oif, &index),
                    (metric, &metric_value.to_ne_bytes()),
                ],
            );
            dump.extend(route(libc::AF_INET as u8, 24, main, &[(oif, &index)]));
            dump.extend(route(libc::AF_INET as u8, 0, libc::RT_TABLE_LOCAL, &[(oif, &index)]));
            dump.extend(route(
                libc::AF_INET6 as u8,
                0,
                main,
                &[(gateway, &v6_gateway.octets()), (oif, &index), (expires, &expiry.to_ne_bytes())],
            ));
            dump.extend(message(libc::NLMSG_DONE as u16, &0u32.to_ne_bytes()));
            dump
        };
        let mut routes = Vec::new();
        assert_eq!(default_routes_in(&dump(600, 1800), &mut routes), Some(true));
        assert_eq!(
            routes,
            [(3, Some(IpAddr::from([192, 168, 1, 1]))), (3, Some(IpAddr::from(v6_gateway)))]
        );
        let mut refreshed = Vec::new();
        assert_eq!(default_routes_in(&dump(1024, 1797), &mut refreshed), Some(true));
        assert_eq!(refreshed, routes, "metric and expiry are left out");
        let refused = message(libc::NLMSG_ERROR as u16, &[0; 20]);
        assert_eq!(default_routes_in(&refused, &mut Vec::new()), None);
    }

    /// This machine's network reads (its addresses and a route dump, without privileges), with
    /// its loopback address in it.
    #[test]
    fn this_machines_network_reads() {
        let network = imp::snapshot().expect("getifaddrs and the route dump");
        assert!(
            network.0.iter().any(|item| matches!(item, Item::Address { ip, prefix: 8, .. }
                if *ip == IpAddr::from([127, 0, 0, 1]))),
            "{network:?}"
        );
    }

    /// The watch opens on Linux without privileges (netlink route groups are readable by any
    /// user), so a link on a fleet Linux host has it too.
    #[test]
    fn the_watch_opens_without_privileges() {
        assert!(imp::open().is_some());
    }

    /// A burst of messages that changes the network is one change, called once it settles; the
    /// thread ends when its owner is gone.
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
        // The network as read at the start, then with an address added.
        let mut looks = 0;
        let look = move || {
            looks += 1;
            let items: &[Item] = if looks == 1 { &[] } else { &[address("192.168.1.20", 24)] };
            network(items)
        };
        let thread = std::thread::spawn(move || {
            run_with(imp::Socket(reader), look, || alive.strong_count() > 0, || counted.signal());
        });
        std::thread::sleep(SETTLE * 3);
        assert_eq!(*receiver.borrow(), 1, "a burst of three messages is one change");
        drop(owner);
        drop(writer);
        thread.join().unwrap();
    }

    /// A router advertisement every few seconds refreshes the lifetimes of the addresses it
    /// gave: the kernel sends RTM_NEWADDR for an address it already has. That is no change of
    /// network; counting it redialed every parked peer link at each advertisement.
    #[test]
    fn a_lifetime_refresh_of_an_address_already_held_is_no_change() {
        use std::os::fd::{AsRawFd, FromRawFd};
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
        let owner = Arc::new(());
        let alive = Arc::downgrade(&owner);
        let counted = generation;
        let thread = std::thread::spawn(move || {
            run(imp::Socket(reader), || alive.strong_count() > 0, || counted.signal());
        });
        // Three advertisements, each settled apart: this machine's addresses stay the same.
        let mut message = [0u8; 16];
        message[4..6].copy_from_slice(&libc::RTM_NEWADDR.to_ne_bytes());
        for _ in 0..3 {
            // SAFETY: a valid buffer of the given length.
            let sent = unsafe {
                libc::send(writer.as_raw_fd(), message.as_ptr().cast(), message.len(), 0)
            };
            assert_eq!(sent, message.len() as isize);
            std::thread::sleep(SETTLE * 3);
        }
        assert_eq!(*receiver.borrow(), 0, "a refresh of addresses already held is no change");
        drop(owner);
        drop(writer);
        thread.join().unwrap();
    }
}
