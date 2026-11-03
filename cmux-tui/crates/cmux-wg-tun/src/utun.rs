//! The utun fd: finding it, and its framing (a 4-byte address family in
//! network byte order before every IP packet).

use std::io;
use std::os::fd::RawFd;

/// `SYSPROTO_CONTROL` from `<sys/sys_domain.h>`.
const SYSPROTO_CONTROL: libc::c_int = 2;
/// `UTUN_OPT_IFNAME` from `<net/if_utun.h>`.
const UTUN_OPT_IFNAME: libc::c_int = 2;
/// Highest fd scanned for the utun socket; a provider holds few fds.
const MAX_FD: RawFd = 1024;

/// The utun control socket NetworkExtension opened for this provider: the
/// one fd whose `UTUN_OPT_IFNAME` names a `utun` interface. `NEPacketTunnelFlow`
/// does not expose it; WireGuard's own Apple client finds it the same way.
pub fn find_utun_fd() -> Option<RawFd> {
    (0..=MAX_FD).find(|&fd| interface_name(fd).is_some_and(|name| name.starts_with("utun")))
}

/// The interface name of a utun control socket, or `None` for any other fd.
pub(crate) fn interface_name(fd: RawFd) -> Option<String> {
    let mut name = [0u8; libc::IFNAMSIZ];
    let mut length = name.len() as libc::socklen_t;
    // SAFETY: `name` is a writable buffer of `length` bytes; getsockopt
    // writes at most that many and fails cleanly on a non-socket fd.
    let result = unsafe {
        libc::getsockopt(
            fd,
            SYSPROTO_CONTROL,
            UTUN_OPT_IFNAME,
            name.as_mut_ptr().cast(),
            &mut length,
        )
    };
    if result != 0 {
        return None;
    }
    let used = name.get(..length as usize).unwrap_or(name.as_slice());
    // The name ends at its first NUL; `split` always yields a first part.
    let text = used.split(|&byte| byte == 0).next().unwrap_or_default();
    String::from_utf8(text.to_vec()).ok()
}

/// The utun header for an IP packet: its address family, big endian.
pub(crate) fn header_for(packet: &[u8]) -> Option<[u8; 4]> {
    let family = match packet.first()? >> 4 {
        4 => libc::AF_INET,
        6 => libc::AF_INET6,
        _ => return None,
    };
    Some((family as u32).to_be_bytes())
}

/// Reads one framed packet into `buffer`; returns the IP packet's range.
/// `Ok(None)` when nothing is waiting.
pub(crate) fn read_packet(
    fd: RawFd,
    buffer: &mut [u8],
) -> io::Result<Option<std::ops::Range<usize>>> {
    // SAFETY: `buffer` is valid for `buffer.len()` writable bytes.
    let read = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
    if read < 0 {
        let error = io::Error::last_os_error();
        return match error.kind() {
            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted => Ok(None),
            _ => Err(error),
        };
    }
    let read = read as usize;
    if read <= 4 {
        return Ok(Some(0..0));
    }
    Ok(Some(4..read))
}

/// Writes one IP packet with its utun header. A full queue drops it, as a
/// router would.
pub(crate) fn write_packet(fd: RawFd, packet: &[u8]) -> io::Result<()> {
    let Some(header) = header_for(packet) else { return Ok(()) };
    let parts = [
        libc::iovec { iov_base: header.as_ptr() as *mut _, iov_len: header.len() },
        libc::iovec { iov_base: packet.as_ptr() as *mut _, iov_len: packet.len() },
    ];
    // SAFETY: both iovecs point at live, readable buffers of the given length.
    let written = unsafe { libc::writev(fd, parts.as_ptr(), parts.len() as libc::c_int) };
    if written < 0 {
        let error = io::Error::last_os_error();
        return match error.raw_os_error() {
            Some(libc::EAGAIN | libc::ENOBUFS | libc::EINTR) => Ok(()),
            _ => Err(error),
        };
    }
    Ok(())
}

pub(crate) fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    // SAFETY: fcntl on a caller-owned fd; failure is reported, not UB.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: as above.
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
