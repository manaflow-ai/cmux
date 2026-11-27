//! The TCP LISTEN sockets of macOS's `net.inet.tcp.pcblist64` sysctl
//! table, read without spawning a process. Shared by the browser host's
//! egress service check and acpmux's port inventory.
//!
//! The struct offsets are `offsetof` values from the SDK headers
//! (`netinet/tcp_var.h` `xtcpcb64`), measured equal on macOS 26.5 and
//! 27.0.1; a table of another layout is unreadable (`None`).

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

pub const XINPGEN_SIZE: usize = 24;
pub const XTCPCB64_SIZE: usize = 472;
pub const XT_LPORT: usize = 22;
pub const XT_FLAGS: usize = 88;
pub const XT_VFLAG: usize = 96;
pub const XT_LADDR: usize = 116;
pub const XT_UID: usize = 252;
pub const XT_STATE: usize = 292;
pub const TCPS_LISTEN: i32 = 1;
pub const INP_IPV4: u8 = 0x1;
pub const INP_IPV6: u8 = 0x2;
pub const IN6P_IPV6_V6ONLY: i32 = 0x8000;
/// One TCP socket in LISTEN.
#[derive(Clone, Debug, PartialEq)]
pub struct Listener {
    pub addr: IpAddr,
    pub port: u16,
    pub uid: u32,
    /// An IPv6 socket that accepts IPv4 too (dual stack).
    pub v4_too: bool,
}

/// A little-endian u32 at `at`.
pub fn u32_at(data: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(data.get(at..at + 4)?.try_into().ok()?))
}

/// A socket's local address from its vflag and 16-byte address union
/// (IPv4 in the last 4 bytes); a v4-mapped IPv6 address is IPv4.
pub fn local_addr(vflag: u8, laddr: &[u8]) -> Option<IpAddr> {
    let bytes: [u8; 16] = laddr.try_into().ok()?;
    if vflag & INP_IPV6 != 0 {
        let v6 = Ipv6Addr::from(bytes);
        return Some(v6.to_ipv4_mapped().map_or(IpAddr::V6(v6), IpAddr::V4));
    }
    (vflag & INP_IPV4 != 0)
        .then(|| IpAddr::V4(Ipv4Addr::new(bytes[12], bytes[13], bytes[14], bytes[15])))
}

/// The LISTEN sockets in a `net.inet.tcp.pcblist64` answer: an `xinpgen`
/// header, `xtcpcb64` records, an `xinpgen` trailer. `None` when the layout
/// is not the measured one.
pub fn parse_pcblist64(data: &[u8]) -> Option<Vec<Listener>> {
    let trailer = data.len().checked_sub(XINPGEN_SIZE)?;
    if u32_at(data, 0)? as usize != XINPGEN_SIZE || u32_at(data, trailer)? as usize != XINPGEN_SIZE
    {
        return None;
    }
    let mut out = Vec::new();
    let mut at = XINPGEN_SIZE;
    while at < trailer {
        if u32_at(data, at)? as usize != XTCPCB64_SIZE || at + XTCPCB64_SIZE > trailer {
            return None;
        }
        let record = &data[at..at + XTCPCB64_SIZE];
        at += XTCPCB64_SIZE;
        let vflag = record[XT_VFLAG];
        if u32_at(record, XT_STATE)? as i32 != TCPS_LISTEN {
            continue;
        }
        let Some(addr) = local_addr(vflag, &record[XT_LADDR..XT_LADDR + 16]) else { continue };
        let flags = u32_at(record, XT_FLAGS)? as i32;
        let dual =
            vflag & INP_IPV6 != 0 && (vflag & INP_IPV4 != 0 || flags & IN6P_IPV6_V6ONLY == 0);
        out.push(Listener {
            addr,
            port: u16::from_be_bytes([record[XT_LPORT], record[XT_LPORT + 1]]),
            uid: u32_at(record, XT_UID)?,
            v4_too: dual && addr.is_unspecified(),
        });
    }
    Some(out)
}

/// The LISTEN sockets in `net.inet.tcp.pcblist64` (maybe filtered to the
/// caller's own); `None` when the table cannot be read.
#[cfg(target_os = "macos")]
pub fn system_listeners() -> Option<Vec<Listener>> {
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
            return parse_pcblist64(&buffer);
        }
        if std::io::Error::last_os_error().raw_os_error() != Some(libc::ENOMEM) {
            return None;
        }
    }
    None
}

/// The distinct port numbers of `listeners`, sorted.
pub fn ports(listeners: &[Listener]) -> Vec<u16> {
    let mut out: Vec<u16> = listeners.iter().map(|l| l.port).collect();
    out.sort_unstable();
    out.dedup();
    out
}

#[cfg(test)]
#[path = "lib_tests.rs"]
mod tests;
