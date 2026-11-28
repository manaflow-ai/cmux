//! Which processes listen on a loopback address (macOS), for the egress
//! service check (crate::egress_services), without spawning a process. Two
//! sources, each matched by address AND port (a listener counts only when
//! its address covers the target: the same address, or the wildcard of its
//! family; a dual-stack IPv6 wildcard covers IPv4 too):
//!
//! - libproc gives this user's LISTEN sockets with their holders
//!   (`proc_listpids` for the effective uid, `PROC_PIDLISTFDS`,
//!   `PROC_PIDFDSOCKETINFO`, `proc_pidpath`). A covering listener held by a
//!   cmux service, Chrome or another Chromium-based browser refuses, and so
//!   does one whose holder cannot be read.
//! - `net.inet.tcp.pcblist64` (sysctl) gives TCP sockets of every user. The
//!   kernel can filter it to the caller's own sockets (a sandboxed or
//!   app-launched process sees one record of many), so it only adds
//!   refusals: a covering listener of another user refuses (this host
//!   cannot inspect its process), and so does a covering listener of this
//!   user that libproc does not find.
//! - No covering listener: allowed before a dial (nobody listens, or only a
//!   listener the table hides; the dial fails by itself or connects), and
//!   refused after a connect (a listener exists that neither source showed).
//!
//! Any libproc error other than an exited process (`ESRCH`, `EBADF`) makes
//! the sweep unreadable, and the caller refuses (fail closed).
//!
//! The struct offsets are `offsetof` values from the SDK headers
//! (`netinet/tcp_var.h` `xtcpcb64`, `sys/proc_info.h` `socket_fdinfo`),
//! measured equal on macOS 26.5 and 27.0.1; a table of another layout is
//! unreadable, and a live test checks the offsets on the running OS.

use std::net::{IpAddr, SocketAddr};

// The pcblist64 reader lives in cmux-tcp-listeners (acpmux's port
// inventory reads the same table); the tests build records with its offsets.
pub(crate) use cmux_tcp_listeners::Listener;
#[cfg(target_os = "macos")]
pub(crate) use cmux_tcp_listeners::system_listeners;
#[allow(unused_imports)]
pub(crate) use cmux_tcp_listeners::{
    IN6P_IPV6_V6ONLY, INP_IPV4, INP_IPV6, TCPS_LISTEN, XINPGEN_SIZE, XT_FLAGS, XT_LADDR, XT_LPORT,
    XT_STATE, XT_UID, XT_VFLAG, XTCPCB64_SIZE, local_addr, parse_pcblist64, u32_at,
};

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const SFI_SIZE: usize = 792;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const SFI_KIND: usize = 256;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const SFI_LPORT: usize = 268;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const SFI_VFLAG: usize = 288;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const SFI_LADDR: usize = 312;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const SFI_STATE: usize = 344;

/// A LISTEN socket of this user and a process that holds it (`None`:
/// unreadable or not read yet); `family`: that process is Chromium-based.
/// `fill_holders` reads the holders of the listeners that matter.
#[derive(Clone, Debug)]
pub(crate) struct Held {
    pub(crate) listener: Listener,
    pub(crate) pid: i32,
    pub(crate) holder: Option<crate::egress_holders::Holder>,
    pub(crate) family: bool,
}

/// Whether a connection to `target` can reach `listener`.
pub(crate) fn covers(listener: &Listener, target: SocketAddr) -> bool {
    if listener.port != target.port() {
        return false;
    }
    match (listener.addr, target.ip()) {
        (a, b) if a == b => true,
        (IpAddr::V4(a), IpAddr::V4(_)) => a.is_unspecified(),
        (IpAddr::V6(a), IpAddr::V6(_)) => a.is_unspecified(),
        (IpAddr::V6(a), IpAddr::V4(_)) => a.is_unspecified() && listener.v4_too,
        _ => false,
    }
}

/// Why `target` is refused, or `None` (see the module docs). `table` comes
/// from pcblist64 (maybe filtered), `own` from libproc.
pub(crate) fn verdict(
    target: SocketAddr,
    table: &[Listener],
    own: &[Held],
    own_uid: u32,
    connected: bool,
) -> Option<String> {
    if let Some(other) = table.iter().find(|l| l.uid != own_uid && covers(l, target)) {
        return Some(format!(
            "loopback {target} is held by a process of uid {}, which this host cannot inspect",
            other.uid
        ));
    }
    // A covering listener of this user that libproc did not find: the
    // kernel may give it the connection, and its holder is unknown.
    let found =
        |l: &Listener| own.iter().any(|h| (h.listener.addr, h.listener.port) == (l.addr, l.port));
    if table.iter().any(|l| covers(l, target) && !found(l)) {
        return Some(format!("the process that listens on loopback {target} cannot be identified"));
    }
    let mine: Vec<&Held> = own.iter().filter(|h| covers(&h.listener, target)).collect();
    for held in &mine {
        let Some(holder) = &held.holder else {
            return Some(format!("the holder of loopback {target} cannot be read"));
        };
        if let Some(why) = crate::egress_holders::holder_refusal(holder, target.port(), held.family)
        {
            return Some(why);
        }
    }
    (mine.is_empty() && connected)
        .then(|| format!("loopback {target} is held by a socket this host cannot see"))
}

/// Clears errno before a libproc call, so that `gone` reads that call's.
#[cfg(target_os = "macos")]
fn clear_errno() {
    // SAFETY: __error returns this thread's errno location.
    unsafe { *libc::__error() = 0 };
}

/// After a libproc call returned nothing: an exited process, a closed
/// descriptor, no error at all, or one of `also`; skipped, not an error.
#[cfg(target_os = "macos")]
fn gone(also: &[i32]) -> bool {
    match std::io::Error::last_os_error().raw_os_error() {
        Some(0 | libc::ESRCH | libc::EBADF) | None => true,
        Some(code) => also.contains(&code),
    }
}

/// This user's LISTEN sockets and their holders (libproc); `None` when the
/// sweep cannot be read.
#[cfg(target_os = "macos")]
pub(crate) fn system_own_listeners(uid: u32) -> Option<Vec<Held>> {
    let mut out = Vec::new();
    for pid in pids_of(uid)? {
        let mut found = Vec::new();
        for fd in socket_fds(pid)? {
            if let Some(mut listener) = listening(pid, fd)? {
                listener.uid = uid;
                found.push(listener);
            }
        }
        if found.is_empty() {
            continue;
        }
        out.extend(found.into_iter().map(|listener| Held {
            listener,
            pid,
            holder: None,
            family: false,
        }));
    }
    Some(out)
}

/// Reads the holders of the listeners that cover `target` (arguments,
/// environment and bundle cost a sysctl and a few stats each, so only
/// these).
#[cfg(target_os = "macos")]
pub(crate) fn fill_holders(own: &mut [Held], target: SocketAddr) {
    for held in own.iter_mut().filter(|h| covers(&h.listener, target)) {
        held.holder = crate::egress_holders::system_holder(held.pid);
        held.family = held
            .holder
            .as_ref()
            .is_some_and(|h| crate::egress_holders::bundle_is_chromium_family(&h.path));
    }
}

/// The pids of `uid`'s processes; grows the buffer until it is not full.
#[cfg(target_os = "macos")]
fn pids_of(uid: u32) -> Option<Vec<i32>> {
    const PROC_UID_ONLY: u32 = 4;
    // SAFETY: a size query (null buffer).
    let bytes = unsafe { libc::proc_listpids(PROC_UID_ONLY, uid, std::ptr::null_mut(), 0) };
    if bytes <= 0 {
        return None;
    }
    let mut room = bytes as usize / 4 + 64;
    for _ in 0..4 {
        let mut pids = vec![0i32; room];
        let size = (pids.len() * 4) as libc::c_int;
        // SAFETY: the buffer is writable for `size` bytes, which is passed.
        let filled =
            unsafe { libc::proc_listpids(PROC_UID_ONLY, uid, pids.as_mut_ptr().cast(), size) };
        if filled <= 0 {
            return None;
        }
        if filled < size {
            pids.truncate(filled as usize / 4);
            pids.retain(|pid| *pid > 0);
            return Some(pids);
        }
        room *= 2;
    }
    None
}

/// The socket descriptors of `pid` (empty when it exited); `None` on any
/// other error. Grows the buffer until it is not full.
#[cfg(target_os = "macos")]
fn socket_fds(pid: i32) -> Option<Vec<i32>> {
    const PROX_FDTYPE_SOCKET: u32 = 2;
    clear_errno();
    // SAFETY: a size query (null buffer).
    let bytes =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
    if bytes <= 0 {
        return gone(&[]).then(Vec::new);
    }
    let size = size_of::<libc::proc_fdinfo>();
    let mut count = bytes as usize / size + 16;
    for _ in 0..4 {
        let mut fds = vec![libc::proc_fdinfo { proc_fd: 0, proc_fdtype: 0 }; count];
        let room = (fds.len() * size) as libc::c_int;
        clear_errno();
        // SAFETY: the buffer is writable for `room` bytes, which is passed.
        let filled = unsafe {
            libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, fds.as_mut_ptr().cast(), room)
        };
        if filled <= 0 {
            return gone(&[]).then(Vec::new);
        }
        if filled < room {
            fds.truncate(filled as usize / size);
            return Some(
                fds.into_iter()
                    .filter(|fd| fd.proc_fdtype == PROX_FDTYPE_SOCKET)
                    .map(|fd| fd.proc_fd)
                    .collect(),
            );
        }
        count *= 2;
    }
    None
}

/// Socket `fd` of `pid` as a TCP LISTEN socket (`Some(None)`: another kind
/// of socket, or closed meanwhile); `None` on any other error.
#[cfg(target_os = "macos")]
fn listening(pid: i32, fd: i32) -> Option<Option<Listener>> {
    const PROC_PIDFDSOCKETINFO: libc::c_int = 3;
    const SOCKINFO_TCP: u32 = 2;
    const TSI_S_LISTEN: u32 = 1;
    let mut info = vec![0u8; SFI_SIZE];
    clear_errno();
    // SAFETY: the buffer is writable for SFI_SIZE bytes, which is passed.
    let filled = unsafe {
        libc::proc_pidfdinfo(
            pid,
            fd,
            PROC_PIDFDSOCKETINFO,
            info.as_mut_ptr().cast(),
            SFI_SIZE as libc::c_int,
        )
    };
    if filled <= 0 {
        // ENOTSOCK: the descriptor was reopened as another kind meanwhile.
        return gone(&[libc::ENOTSOCK]).then_some(None);
    }
    if filled as usize != SFI_SIZE {
        return None;
    }
    if u32_at(&info, SFI_KIND) != Some(SOCKINFO_TCP)
        || u32_at(&info, SFI_STATE) != Some(TSI_S_LISTEN)
    {
        return Some(None);
    }
    let vflag = info[SFI_VFLAG];
    let Some(addr) = local_addr(vflag, &info[SFI_LADDR..SFI_LADDR + 16]) else {
        return Some(None);
    };
    Some(Some(Listener {
        addr,
        port: u16::from_be_bytes([info[SFI_LPORT], info[SFI_LPORT + 1]]),
        uid: 0,
        // A dual-stack socket carries both vflags.
        v4_too: addr.is_unspecified() && vflag & INP_IPV6 != 0 && vflag & INP_IPV4 != 0,
    }))
}

#[cfg(test)]
#[path = "egress_listeners_tests.rs"]
mod tests;
