//! Which processes listen on a loopback address (macOS), for the egress
//! service check (crate::egress_services), without spawning a process:
//!
//! - `net.inet.tcp.pcblist64` (sysctl) lists every TCP socket of every user
//!   with its local address, port, state and owner uid. Only a LISTEN socket
//!   whose address covers the target counts: the same address, or the
//!   wildcard of its family (a dual-stack IPv6 wildcard covers IPv4 too).
//! - A covering listener of another user refuses: this host cannot inspect
//!   its process (fail closed).
//! - This user's covering listeners: libproc finds the processes that hold
//!   them (`proc_listpids` for the uid, `PROC_PIDLISTFDS`,
//!   `PROC_PIDFDSOCKETINFO`), `proc_pidpath` their executables; a cmux
//!   service, Chrome or another Chromium-based browser refuses, and so does a
//!   listener whose holder cannot be found or read.
//! - No covering listener: allowed before a dial (nobody listens; the dial
//!   fails by itself), refused after a connect (a listener exists that the
//!   table did not show).
//!
//! The struct offsets are `offsetof` values from the SDK headers
//! (`netinet/tcp_var.h` `xtcpcb64`, `sys/proc_info.h` `socket_fdinfo`),
//! measured equal on macOS 26.5 and 27.0.1; a live-table test checks them on
//! the running OS.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

pub(crate) const XINPGEN_SIZE: usize = 24;
pub(crate) const XTCPCB64_SIZE: usize = 472;
pub(crate) const XT_LPORT: usize = 22;
pub(crate) const XT_FLAGS: usize = 88;
pub(crate) const XT_VFLAG: usize = 96;
pub(crate) const XT_LADDR: usize = 116;
pub(crate) const XT_UID: usize = 252;
pub(crate) const XT_STATE: usize = 292;
pub(crate) const TCPS_LISTEN: i32 = 1;
pub(crate) const INP_IPV4: u8 = 0x1;
const INP_IPV6: u8 = 0x2;
const IN6P_IPV6_V6ONLY: i32 = 0x8000;
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

/// One TCP socket in LISTEN.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Listener {
    pub(crate) addr: IpAddr,
    pub(crate) port: u16,
    pub(crate) uid: u32,
    /// An IPv6 socket that accepts IPv4 too (dual stack).
    pub(crate) v4_too: bool,
}

/// The executables of the processes that hold a listener.
pub(crate) enum Holders {
    Found(Vec<String>),
    Unreadable,
}

fn u32_at(data: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(data.get(at..at + 4)?.try_into().ok()?))
}

/// A socket's local address from its vflag and 16-byte address union
/// (IPv4 in the last 4 bytes); a v4-mapped IPv6 address is IPv4.
fn local_addr(vflag: u8, laddr: &[u8]) -> Option<IpAddr> {
    let bytes: [u8; 16] = laddr.try_into().ok()?;
    if vflag & INP_IPV6 != 0 {
        let v6 = Ipv6Addr::from(bytes);
        return Some(v6.to_ipv4_mapped().map_or(IpAddr::V6(v6), IpAddr::V4));
    }
    (vflag & INP_IPV4 != 0)
        .then(|| IpAddr::V4(Ipv4Addr::new(bytes[12], bytes[13], bytes[14], bytes[15])))
}

/// The LISTEN sockets in a `net.inet.tcp.pcblist64` answer: an `xinpgen`
/// header, `xtcpcb64` records, an `xinpgen` trailer.
pub(crate) fn parse_pcblist64(data: &[u8]) -> Vec<Listener> {
    let mut out = Vec::new();
    let mut at = match u32_at(data, 0) {
        Some(len) => len as usize,
        None => return out,
    };
    while let Some(len) = u32_at(data, at).map(|len| len as usize) {
        if len <= XINPGEN_SIZE || at + len > data.len() || len < XTCPCB64_SIZE {
            break;
        }
        let record = &data[at..at + len];
        let state = u32_at(record, XT_STATE).map(|s| s as i32);
        let vflag = record[XT_VFLAG];
        if state == Some(TCPS_LISTEN)
            && let Some(addr) = local_addr(vflag, &record[XT_LADDR..XT_LADDR + 16])
            && let Some(uid) = u32_at(record, XT_UID)
        {
            let flags = u32_at(record, XT_FLAGS).unwrap_or(0) as i32;
            let dual =
                vflag & INP_IPV6 != 0 && (vflag & INP_IPV4 != 0 || flags & IN6P_IPV6_V6ONLY == 0);
            out.push(Listener {
                addr,
                port: u16::from_be_bytes([record[XT_LPORT], record[XT_LPORT + 1]]),
                uid,
                v4_too: dual && addr.is_unspecified(),
            });
        }
        at += len;
    }
    out
}

/// Whether a connection to `target` can reach `listener`.
fn covers(listener: &Listener, target: SocketAddr) -> bool {
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

/// Why `target` is refused, or `None` (see the module docs).
pub(crate) fn verdict(
    target: SocketAddr,
    listeners: &[Listener],
    own_uid: u32,
    connected: bool,
    holders: impl Fn(&Listener) -> Holders,
) -> Option<String> {
    let covering: Vec<&Listener> = listeners.iter().filter(|l| covers(l, target)).collect();
    if covering.is_empty() {
        return connected
            .then(|| format!("loopback {target} is held by a socket this host cannot see"));
    }
    if let Some(other) = covering.iter().find(|l| l.uid != own_uid) {
        return Some(format!(
            "loopback {target} is held by a process of uid {}, which this host cannot inspect",
            other.uid
        ));
    }
    for listener in covering {
        let Holders::Found(paths) = holders(listener) else {
            return Some(format!("the holder of loopback {target} cannot be read"));
        };
        if paths.is_empty() {
            return Some(format!(
                "the process that listens on loopback {target} cannot be identified"
            ));
        }
        for path in &paths {
            let name = path.rsplit('/').next().unwrap_or(path);
            if crate::egress_services::is_service_name(name)
                || crate::egress_services::is_app_service_name(name)
            {
                return Some(format!("loopback {target} is the cmux service {name}"));
            }
        }
    }
    None
}

/// Every LISTEN socket on this Mac (`net.inet.tcp.pcblist64`); `None` when
/// the table cannot be read.
#[cfg(target_os = "macos")]
pub(crate) fn system_listeners() -> Option<Vec<Listener>> {
    let name = c"net.inet.tcp.pcblist64";
    for _ in 0..4 {
        let mut len: libc::size_t = 0;
        // SAFETY: a size query (null buffer) with a valid length pointer.
        let sized = unsafe {
            libc::sysctlbyname(
                name.as_ptr(),
                std::ptr::null_mut(),
                &mut len,
                std::ptr::null_mut(),
                0,
            )
        };
        if sized != 0 {
            return None;
        }
        // Room for sockets opened between the two calls.
        let mut buffer = vec![0u8; len + len / 4 + 4096];
        let mut filled = buffer.len();
        // SAFETY: the buffer is writable for `filled` bytes, which is passed.
        let read = unsafe {
            libc::sysctlbyname(
                name.as_ptr(),
                buffer.as_mut_ptr().cast(),
                &mut filled,
                std::ptr::null_mut(),
                0,
            )
        };
        if read == 0 {
            buffer.truncate(filled);
            return Some(parse_pcblist64(&buffer));
        }
        if std::io::Error::last_os_error().raw_os_error() != Some(libc::ENOMEM) {
            return None;
        }
    }
    None
}

/// The executables of this user's processes that hold `listener`.
#[cfg(target_os = "macos")]
pub(crate) fn system_holders(listener: &Listener) -> Holders {
    let Some(pids) = pids_of(listener.uid) else { return Holders::Unreadable };
    let mut paths = Vec::new();
    for pid in pids {
        // A process that exited meanwhile lists nothing.
        let Some(fds) = socket_fds(pid) else { continue };
        if fds.into_iter().any(|fd| holds(pid, fd, listener)) {
            match crate::egress_services::executable_path(pid) {
                Some(path) => paths.push(path),
                None => return Holders::Unreadable,
            }
        }
    }
    Holders::Found(paths)
}

#[cfg(target_os = "macos")]
fn pids_of(uid: u32) -> Option<Vec<i32>> {
    const PROC_UID_ONLY: u32 = 4;
    // SAFETY: a size query (null buffer).
    let bytes = unsafe { libc::proc_listpids(PROC_UID_ONLY, uid, std::ptr::null_mut(), 0) };
    if bytes <= 0 {
        return None;
    }
    let mut pids = vec![0i32; bytes as usize / 4 + 64];
    let size = (pids.len() * 4) as libc::c_int;
    // SAFETY: the buffer is writable for `size` bytes, which is passed.
    let filled = unsafe { libc::proc_listpids(PROC_UID_ONLY, uid, pids.as_mut_ptr().cast(), size) };
    if filled <= 0 {
        return None;
    }
    pids.truncate(filled as usize / 4);
    pids.retain(|pid| *pid > 0);
    Some(pids)
}

#[cfg(target_os = "macos")]
fn socket_fds(pid: i32) -> Option<Vec<i32>> {
    const PROX_FDTYPE_SOCKET: u32 = 2;
    // SAFETY: a size query (null buffer).
    let bytes =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
    if bytes <= 0 {
        return None;
    }
    let size = size_of::<libc::proc_fdinfo>();
    let mut fds =
        vec![libc::proc_fdinfo { proc_fd: 0, proc_fdtype: 0 }; bytes as usize / size + 16];
    let room = (fds.len() * size) as libc::c_int;
    // SAFETY: the buffer is writable for `room` bytes, which is passed.
    let filled =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, fds.as_mut_ptr().cast(), room) };
    if filled <= 0 {
        return None;
    }
    fds.truncate(filled as usize / size);
    Some(
        fds.into_iter()
            .filter(|fd| fd.proc_fdtype == PROX_FDTYPE_SOCKET)
            .map(|fd| fd.proc_fd)
            .collect(),
    )
}

/// Whether socket `fd` of `pid` is a TCP LISTEN socket on the listener's
/// address and port.
#[cfg(target_os = "macos")]
fn holds(pid: i32, fd: i32, listener: &Listener) -> bool {
    const PROC_PIDFDSOCKETINFO: libc::c_int = 3;
    const SOCKINFO_TCP: u32 = 2;
    const TSI_S_LISTEN: u32 = 1;
    let mut info = vec![0u8; SFI_SIZE];
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
    if filled as usize != SFI_SIZE || u32_at(&info, SFI_KIND) != Some(SOCKINFO_TCP) {
        return false;
    }
    let port = u16::from_be_bytes([info[SFI_LPORT], info[SFI_LPORT + 1]]);
    u32_at(&info, SFI_STATE) == Some(TSI_S_LISTEN)
        && port == listener.port
        && local_addr(info[SFI_VFLAG], &info[SFI_LADDR..SFI_LADDR + 16]) == Some(listener.addr)
}

#[cfg(test)]
#[path = "egress_listeners_tests.rs"]
mod tests;
