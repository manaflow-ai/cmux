//! Batched UDP for a [`crate::SocketPath`]: one syscall for many datagrams.
//!
//! Bulk through the tunnel cost 4.47 syscalls a datagram (one `sendto` or
//! `recvfrom` each, plus the wakeups around them) against kernel TCP's 0.06
//! (cmuxterm-hq `docs/design/wg-perf-layers.md`). A [`SendBatch`] holds what a
//! driver pass sends and leaves in one `sendmmsg` when the pass flushes, with
//! runs of equal-sized datagrams to one address joined into one UDP GSO
//! message (`UDP_SEGMENT`). A [`ReceiveBatch`] holds what one `recvmmsg`
//! read, each message possibly several datagrams the kernel joined (UDP GRO).
//! Other platforms, and sockets that are not the kernel's, keep one call a
//! datagram behind the same types.

use std::collections::VecDeque;
use std::net::SocketAddr;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};

/// How a datagram asks the networks it crosses to queue it (RFD 0142 T1).
/// The internet mostly bleaches the marking, but the first hop (a home Wi-Fi
/// access point's queue, the phone's own radio queue) is where a keystroke
/// and a download contend, and both honour it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Mark {
    /// The socket's default: best effort.
    #[default]
    Plain,
    /// Input and screen state: DSCP EF (46) on Linux; on macOS and iOS the
    /// voice service type, which puts it in Wi-Fi's voice queue (WMM AC_VO)
    /// and lets the system mark EF where its QoS policy allows.
    Voice,
}

/// DSCP EF (46) in the IPv4 TOS / IPv6 traffic class byte, ECN bits clear.
#[cfg(target_os = "linux")]
pub(crate) const EF_TOS: libc::c_int = 46 << 2;

/// The environment variable that turns marking off (`0`).
pub const MARK_ENV: &str = "CMUX_WG_DSCP";

/// Set once the kernel refused a marked send (EINVAL from a stack that
/// does not take the option per datagram): every later send goes unmarked.
static MARKS_OFF: AtomicBool = AtomicBool::new(false);

/// Whether sends carry their [`Mark`].
pub(crate) fn marking() -> bool {
    static ENV_ON: OnceLock<bool> = OnceLock::new();
    *ENV_ON.get_or_init(|| std::env::var(MARK_ENV).map_or(true, |value| value != "0"))
        && !MARKS_OFF.load(Ordering::Relaxed)
}

/// A marked send was refused as invalid: stop marking (the caller resends
/// unmarked). Returns whether it was the marking that was refused.
pub(crate) fn marks_refused(error: &std::io::Error, marked: bool) -> bool {
    #[cfg(unix)]
    let invalid = error.raw_os_error() == Some(libc::EINVAL);
    #[cfg(not(unix))]
    let invalid = error.kind() == std::io::ErrorKind::InvalidInput;
    if marked && invalid {
        if !MARKS_OFF.swap(true, Ordering::Relaxed) {
            eprintln!("wireguard UDP marking off: the kernel refused it ({error})");
        }
        return true;
    }
    false
}

/// Datagrams staged in one pass before they leave without waiting for its
/// flush: a bound on the copy kept, not a latency (the pass ends first).
pub(crate) const STAGE_LIMIT: usize = 64;

/// Datagrams waiting to leave, in order, their bytes back to back so a run to
/// one address is one GSO message without copying again. Index 0 is the
/// oldest not yet sent.
#[derive(Debug, Default)]
pub struct SendBatch {
    data: Vec<u8>,
    entries: Vec<(usize, usize, SocketAddr, Mark)>,
    /// Entries before this one have left.
    head: usize,
}

impl SendBatch {
    pub(crate) fn push(&mut self, datagram: &[u8], target: SocketAddr) {
        self.push_marked(datagram, target, Mark::Plain);
    }

    pub(crate) fn push_marked(&mut self, datagram: &[u8], target: SocketAddr, mark: Mark) {
        self.entries.push((self.data.len(), datagram.len(), target, mark));
        self.data.extend_from_slice(datagram);
    }

    pub fn len(&self) -> usize {
        self.entries.len() - self.head
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The `index`th datagram still waiting and where it goes.
    pub fn get(&self, index: usize) -> Option<(&[u8], SocketAddr)> {
        let (start, len, target, _) = *self.entries.get(self.head + index)?;
        Some((self.data.get(start..start + len)?, target))
    }

    /// The `index`th waiting datagram's [`Mark`] (`Plain` past the end).
    pub fn mark(&self, index: usize) -> Mark {
        self.entries.get(self.head + index).map_or(Mark::Plain, |entry| entry.3)
    }

    /// The oldest `count` datagrams left (or were dropped).
    pub(crate) fn consume(&mut self, count: usize) {
        self.head = (self.head + count).min(self.entries.len());
        if self.head == self.entries.len() {
            self.clear();
        } else if self.head >= STAGE_LIMIT && self.head * 2 >= self.entries.len() {
            // A queue that never empties (a socket that stays full) keeps
            // only what still waits.
            let offset = self.entries.get(self.head).map_or(0, |entry| entry.0);
            self.entries.drain(..self.head);
            self.head = 0;
            self.data.drain(..offset);
            for entry in &mut self.entries {
                entry.0 -= offset;
            }
        }
    }

    pub(crate) fn clear(&mut self) {
        self.data.clear();
        self.entries.clear();
        self.head = 0;
    }
}

/// Datagrams one batched read took, handed out one at a time.
#[derive(Debug, Default)]
pub struct ReceiveBatch {
    data: Vec<u8>,
    entries: VecDeque<(usize, usize, SocketAddr)>,
}

impl ReceiveBatch {
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Add one datagram a socket read one at a time (the default read).
    pub fn push(&mut self, datagram: &[u8], from: SocketAddr) {
        if self.entries.is_empty() {
            self.data.clear();
        }
        self.entries.push_back((self.data.len(), datagram.len(), from));
        self.data.extend_from_slice(datagram);
    }

    /// Copy the oldest datagram into `buffer`. One longer than `buffer` is
    /// dropped (as `recv_from` truncates; WireGuard then refuses it).
    pub fn pop_into(&mut self, buffer: &mut [u8]) -> Option<(usize, SocketAddr)> {
        let (start, len, from) = self.entries.pop_front()?;
        let datagram = self.data.get(start..start + len)?;
        let slot = buffer.get_mut(..len)?;
        slot.copy_from_slice(datagram);
        Some((len, from))
    }
}

#[cfg(target_os = "linux")]
pub(crate) mod linux {
    //! `sendmmsg`/`recvmmsg` with UDP GSO and GRO (Linux 4.18 and 5.0).
    use std::io;
    use std::mem::{size_of, zeroed};
    use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};
    use std::os::fd::RawFd;
    use std::sync::atomic::{AtomicBool, Ordering};

    use super::{EF_TOS, Mark, ReceiveBatch, SendBatch};

    /// Messages one `sendmmsg` or `recvmmsg` carries.
    const MESSAGES: usize = 64;
    /// Receive slots: each holds one datagram, or up to 64 KiB of them that
    /// GRO joined, so one read takes up to about 350 full-sized datagrams.
    const RECEIVE_SLOTS: usize = 8;
    const SLOT_BYTES: usize = 1 << 16;
    /// Segments one GSO message carries (the kernel's `UDP_MAX_SEGMENTS`
    /// before 6.x) and its byte bound (the UDP payload maximum, IPv6 headers
    /// left out).
    const GSO_SEGMENTS: usize = 64;
    const GSO_BYTES: usize = 65_000;
    /// Room for two `cmsghdr`s carrying a `c_int` each (the GSO segment
    /// size and the traffic class), aligned up generously.
    const CONTROL_BYTES: usize = 64;

    /// Set once a GSO send failed with what a device without checksum offload
    /// answers (EIO), so every later send goes one datagram a message.
    static GSO_OFF: AtomicBool = AtomicBool::new(false);

    /// Ask the kernel to join arriving datagrams (GRO). A kernel that
    /// refuses keeps one datagram a message; both read the same way.
    pub(crate) fn enable_gro(fd: RawFd) {
        let on: libc::c_int = 1;
        // SAFETY: `fd` is open for the caller's borrow, and the value points
        // at a live `c_int` of the length passed.
        unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_UDP,
                libc::UDP_GRO,
                (&raw const on).cast(),
                size_of::<libc::c_int>() as libc::socklen_t,
            );
        }
    }

    fn encode(addr: SocketAddr, storage: &mut libc::sockaddr_storage) -> libc::socklen_t {
        match addr {
            SocketAddr::V4(v4) => {
                // SAFETY: sockaddr_storage is larger than and aligned for sockaddr_in.
                let sin = unsafe { &mut *(&raw mut *storage).cast::<libc::sockaddr_in>() };
                sin.sin_family = libc::AF_INET as libc::sa_family_t;
                sin.sin_port = v4.port().to_be();
                sin.sin_addr = libc::in_addr { s_addr: u32::from_ne_bytes(v4.ip().octets()) };
                size_of::<libc::sockaddr_in>() as libc::socklen_t
            }
            SocketAddr::V6(v6) => {
                // SAFETY: as above, for sockaddr_in6.
                let sin6 = unsafe { &mut *(&raw mut *storage).cast::<libc::sockaddr_in6>() };
                sin6.sin6_family = libc::AF_INET6 as libc::sa_family_t;
                sin6.sin6_port = v6.port().to_be();
                sin6.sin6_flowinfo = v6.flowinfo();
                sin6.sin6_addr = libc::in6_addr { s6_addr: v6.ip().octets() };
                sin6.sin6_scope_id = v6.scope_id();
                size_of::<libc::sockaddr_in6>() as libc::socklen_t
            }
        }
    }

    fn decode(storage: &libc::sockaddr_storage) -> Option<SocketAddr> {
        match libc::c_int::from(storage.ss_family) {
            libc::AF_INET => {
                // SAFETY: the kernel wrote a sockaddr_in for AF_INET.
                let sin = unsafe { &*(&raw const *storage).cast::<libc::sockaddr_in>() };
                let ip = Ipv4Addr::from(sin.sin_addr.s_addr.to_ne_bytes());
                Some(SocketAddr::V4(SocketAddrV4::new(ip, u16::from_be(sin.sin_port))))
            }
            libc::AF_INET6 => {
                // SAFETY: the kernel wrote a sockaddr_in6 for AF_INET6.
                let sin6 = unsafe { &*(&raw const *storage).cast::<libc::sockaddr_in6>() };
                Some(SocketAddr::V6(SocketAddrV6::new(
                    Ipv6Addr::from(sin6.sin6_addr.s6_addr),
                    u16::from_be(sin6.sin6_port),
                    sin6.sin6_flowinfo,
                    sin6.sin6_scope_id,
                )))
            }
            _ => None,
        }
    }

    /// One message: datagrams `first..first + count` of the batch, which sit
    /// back to back, as GSO segments of `segment` bytes when `count > 1`,
    /// all with one `mark`.
    struct Message {
        first: usize,
        count: usize,
        segment: usize,
        mark: Mark,
    }

    /// Group datagrams from `from` on into messages: a run to one address of
    /// one size (the last may be shorter) and one mark is one GSO message.
    /// `marks`: whether marks are sent at all (a run ignores them when not).
    fn plan(batch: &SendBatch, from: usize, gso: bool, marks: bool) -> Vec<Message> {
        let mark_of = |index| if marks { batch.mark(index) } else { Mark::Plain };
        let mut messages: Vec<Message> = Vec::new();
        let mut index = from;
        while index < batch.len() && messages.len() < MESSAGES {
            let Some((first, target)) = batch.get(index) else { break };
            let mark = mark_of(index);
            let segment = first.len();
            let mut count = 1;
            let mut bytes = segment;
            while gso && count < GSO_SEGMENTS {
                let Some((next, next_target)) = batch.get(index + count) else { break };
                if next_target != target
                    || mark_of(index + count) != mark
                    || next.len() > segment
                    || bytes + next.len() > GSO_BYTES
                {
                    break;
                }
                count += 1;
                bytes += next.len();
                if next.len() < segment {
                    break; // A shorter segment ends the message.
                }
            }
            messages.push(Message { first: index, count, segment, mark });
            index += count;
        }
        messages
    }

    /// Send datagrams `from..` of `batch` with one `sendmmsg`. Returns how
    /// many datagrams left (at least one), or the error of the first message.
    pub(crate) fn send(fd: RawFd, batch: &SendBatch, from: usize) -> io::Result<usize> {
        let gso = !GSO_OFF.load(Ordering::Relaxed);
        let marks = super::marking();
        let messages = plan(batch, from, gso, marks);
        let marked = messages.iter().any(|message| message.mark != Mark::Plain);
        match send_messages(fd, batch, &messages) {
            Err(error) if gso && error.raw_os_error() == Some(libc::EIO) => {
                // The device cannot checksum a GSO message: one a datagram.
                GSO_OFF.store(true, Ordering::Relaxed);
                send_messages(fd, batch, &plan(batch, from, false, marks))
            }
            Err(error) if super::marks_refused(&error, marked) => {
                send_messages(fd, batch, &plan(batch, from, gso, false))
            }
            result => result,
        }
    }

    /// The traffic class option for a datagram to `target`: `IP_TOS` for an
    /// IPv4 destination (a v4-mapped send on a v6 socket takes it too),
    /// `IPV6_TCLASS` for an IPv6 one.
    fn class_option(target: SocketAddr) -> (libc::c_int, libc::c_int) {
        match target {
            SocketAddr::V4(_) => (libc::IPPROTO_IP, libc::IP_TOS),
            SocketAddr::V6(_) => (libc::IPPROTO_IPV6, libc::IPV6_TCLASS),
        }
    }

    fn send_messages(fd: RawFd, batch: &SendBatch, messages: &[Message]) -> io::Result<usize> {
        let count = messages.len();
        // SAFETY: all-zero is a valid value of these C structs.
        let mut names: Vec<libc::sockaddr_storage> = vec![unsafe { zeroed() }; count];
        let mut name_lens: Vec<libc::socklen_t> = Vec::with_capacity(count);
        let mut iovecs: Vec<libc::iovec> = Vec::with_capacity(count);
        let mut controls = vec![[0u64; CONTROL_BYTES / 8]; count];
        // SAFETY: as above.
        let mut headers: Vec<libc::mmsghdr> = vec![unsafe { zeroed() }; count];
        for (message, name) in messages.iter().zip(&mut names) {
            let Some((first, target)) = batch.get(message.first) else {
                return Err(io::ErrorKind::InvalidInput.into());
            };
            let bytes: usize = (0..message.count)
                .filter_map(|i| batch.get(message.first + i))
                .map(|(datagram, _)| datagram.len())
                .sum();
            name_lens.push(encode(target, name));
            iovecs.push(libc::iovec { iov_base: first.as_ptr().cast_mut().cast(), iov_len: bytes });
        }
        for (i, header) in headers.iter_mut().enumerate() {
            let (Some(message), Some(name), Some(&name_len), Some(iovec), Some(control)) = (
                messages.get(i),
                names.get_mut(i),
                name_lens.get(i),
                iovecs.get_mut(i),
                controls.get_mut(i),
            ) else {
                break;
            };
            let hdr = &mut header.msg_hdr;
            hdr.msg_name = (&raw mut *name).cast();
            hdr.msg_namelen = name_len;
            hdr.msg_iov = iovec;
            hdr.msg_iovlen = 1;
            let gso = message.count > 1;
            let class = (message.mark == Mark::Voice)
                .then(|| batch.get(message.first).map(|(_, target)| class_option(target)))
                .flatten();
            if !gso && class.is_none() {
                continue;
            }
            // SAFETY: CMSG_SPACE only computes a size.
            let space = unsafe {
                (if gso { libc::CMSG_SPACE(size_of::<u16>() as u32) } else { 0 })
                    + (if class.is_some() {
                        libc::CMSG_SPACE(size_of::<libc::c_int>() as u32)
                    } else {
                        0
                    })
            };
            hdr.msg_control = control.as_mut_ptr().cast();
            hdr.msg_controllen = space as _;
            // SAFETY: the control buffer is CONTROL_BYTES, past the
            // CMSG_SPACE of both messages, 8-byte aligned, and
            // msg_controllen says how much is used, so FIRSTHDR and NXTHDR
            // stay within it.
            unsafe {
                let mut cmsg = libc::CMSG_FIRSTHDR(hdr);
                if gso {
                    (*cmsg).cmsg_level = libc::SOL_UDP;
                    (*cmsg).cmsg_type = libc::UDP_SEGMENT;
                    (*cmsg).cmsg_len = libc::CMSG_LEN(size_of::<u16>() as u32) as _;
                    let segment = u16::try_from(message.segment).unwrap_or(u16::MAX);
                    std::ptr::write_unaligned(libc::CMSG_DATA(cmsg).cast::<u16>(), segment);
                    cmsg = libc::CMSG_NXTHDR(hdr, cmsg);
                }
                if let Some((level, kind)) = class
                    && !cmsg.is_null()
                {
                    (*cmsg).cmsg_level = level;
                    (*cmsg).cmsg_type = kind;
                    (*cmsg).cmsg_len = libc::CMSG_LEN(size_of::<libc::c_int>() as u32) as _;
                    std::ptr::write_unaligned(libc::CMSG_DATA(cmsg).cast::<libc::c_int>(), EF_TOS);
                }
            }
        }
        // SAFETY: every header points at a name, an iovec and a control
        // buffer that live until the call returns, and the iovecs at the
        // batch's bytes, borrowed for the call.
        let sent = unsafe { libc::sendmmsg(fd, headers.as_mut_ptr(), count as libc::c_uint, 0) };
        if sent < 0 {
            return Err(io::Error::last_os_error());
        }
        let sent = usize::try_from(sent).unwrap_or(0);
        Ok(messages.iter().take(sent).map(|message| message.count).sum())
    }

    /// Read what waits on `fd` with one `recvmmsg` into `batch` (empty on
    /// entry), splitting each message GRO joined at its segment size.
    pub(crate) fn recv(fd: RawFd, batch: &mut ReceiveBatch) -> io::Result<()> {
        batch.entries.clear();
        batch.data.resize(RECEIVE_SLOTS * SLOT_BYTES, 0);
        // SAFETY: all-zero is a valid value of these C structs.
        let mut names: Vec<libc::sockaddr_storage> = vec![unsafe { zeroed() }; RECEIVE_SLOTS];
        let mut controls = vec![[0u64; CONTROL_BYTES / 8]; RECEIVE_SLOTS];
        let mut iovecs: Vec<libc::iovec> = batch
            .data
            .chunks_exact_mut(SLOT_BYTES)
            .map(|slot| libc::iovec { iov_base: slot.as_mut_ptr().cast(), iov_len: SLOT_BYTES })
            .collect();
        // SAFETY: as above.
        let mut headers: Vec<libc::mmsghdr> = vec![unsafe { zeroed() }; RECEIVE_SLOTS];
        for (((header, name), iovec), control) in
            headers.iter_mut().zip(&mut names).zip(&mut iovecs).zip(&mut controls)
        {
            let hdr = &mut header.msg_hdr;
            hdr.msg_name = (&raw mut *name).cast();
            hdr.msg_namelen = size_of::<libc::sockaddr_storage>() as libc::socklen_t;
            hdr.msg_iov = iovec;
            hdr.msg_iovlen = 1;
            hdr.msg_control = control.as_mut_ptr().cast();
            hdr.msg_controllen = CONTROL_BYTES as _;
        }
        // SAFETY: every header points at buffers that live until the call
        // returns; a null timeout with MSG_DONTWAIT never blocks.
        let read = unsafe {
            libc::recvmmsg(
                fd,
                headers.as_mut_ptr(),
                RECEIVE_SLOTS as libc::c_uint,
                // glibc types the flags c_int, musl c_uint.
                libc::MSG_DONTWAIT as _,
                std::ptr::null_mut(),
            )
        };
        if read < 0 {
            return Err(io::Error::last_os_error());
        }
        let read = usize::try_from(read).unwrap_or(0);
        for (slot, (header, name)) in headers.iter().zip(&names).take(read).enumerate() {
            let len = header.msg_len as usize;
            if header.msg_hdr.msg_flags & libc::MSG_TRUNC != 0 {
                continue;
            }
            let Some(from) = decode(name) else { continue };
            let segment = gro_segment(&header.msg_hdr).filter(|s| *s > 0).unwrap_or(len.max(1));
            let start = slot * SLOT_BYTES;
            let mut offset = 0;
            while offset < len {
                let take = segment.min(len - offset);
                batch.entries.push_back((start + offset, take, from));
                offset += take;
            }
        }
        Ok(())
    }

    fn gro_segment(hdr: &libc::msghdr) -> Option<usize> {
        // SAFETY: the kernel filled msg_control up to msg_controllen, and
        // the CMSG macros walk only within it.
        unsafe {
            let mut cmsg = libc::CMSG_FIRSTHDR(hdr);
            while !cmsg.is_null() {
                if (*cmsg).cmsg_level == libc::SOL_UDP && (*cmsg).cmsg_type == libc::UDP_GRO {
                    let size =
                        std::ptr::read_unaligned(libc::CMSG_DATA(cmsg).cast::<libc::c_int>());
                    return usize::try_from(size).ok();
                }
                cmsg = libc::CMSG_NXTHDR(hdr, cmsg);
            }
        }
        None
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn addr(port: u16) -> SocketAddr {
            SocketAddr::from(([127, 0, 0, 1], port))
        }

        #[test]
        fn runs_to_one_address_of_one_size_are_one_message() {
            let mut batch = SendBatch::default();
            for _ in 0..3 {
                batch.push(&[1; 100], addr(1));
            }
            batch.push(&[2; 40], addr(1)); // the shorter tail joins
            batch.push(&[3; 100], addr(1)); // after a short one: new message
            batch.push(&[4; 100], addr(2)); // another address
            let plan = plan(&batch, 0, true, true);
            let shape: Vec<_> = plan.iter().map(|m| (m.first, m.count, m.segment)).collect();
            assert_eq!(shape, vec![(0, 4, 100), (4, 1, 100), (5, 1, 100)]);
            assert_eq!(super::plan(&batch, 0, false, true).len(), 6);
        }

        #[test]
        fn a_mark_change_starts_a_message_unless_marks_are_off() {
            let mut batch = SendBatch::default();
            batch.push(&[1; 100], addr(1));
            batch.push_marked(&[1; 100], addr(1), Mark::Voice);
            batch.push_marked(&[1; 100], addr(1), Mark::Voice);
            batch.push(&[1; 100], addr(1));
            let shape = |marks| {
                plan(&batch, 0, true, marks)
                    .iter()
                    .map(|m| (m.first, m.count, m.mark))
                    .collect::<Vec<_>>()
            };
            assert_eq!(
                shape(true),
                vec![(0, 1, Mark::Plain), (1, 2, Mark::Voice), (3, 1, Mark::Plain)]
            );
            assert_eq!(shape(false), vec![(0, 4, Mark::Plain)]);
        }

        /// The traffic class byte of the next datagram on `socket`, which
        /// asked to see it (`IP_RECVTOS` / `IPV6_RECVTCLASS`).
        fn received_class(socket: &std::net::UdpSocket) -> u8 {
            use std::os::fd::AsRawFd;
            let mut buffer = [0u8; 2048];
            let mut iovec =
                libc::iovec { iov_base: buffer.as_mut_ptr().cast(), iov_len: buffer.len() };
            let mut control = [0u64; CONTROL_BYTES / 8];
            // SAFETY: all-zero is a valid msghdr; every pointer set below
            // outlives the call, and the CMSG walk stays in msg_controllen.
            unsafe {
                let mut hdr: libc::msghdr = zeroed();
                hdr.msg_iov = &raw mut iovec;
                hdr.msg_iovlen = 1;
                hdr.msg_control = control.as_mut_ptr().cast();
                hdr.msg_controllen = CONTROL_BYTES as _;
                assert!(libc::recvmsg(socket.as_raw_fd(), &raw mut hdr, 0) > 0);
                let mut cmsg = libc::CMSG_FIRSTHDR(&raw const hdr);
                while !cmsg.is_null() {
                    let (level, kind) = ((*cmsg).cmsg_level, (*cmsg).cmsg_type);
                    if level == libc::IPPROTO_IP && kind == libc::IP_TOS {
                        return *libc::CMSG_DATA(cmsg);
                    }
                    if level == libc::IPPROTO_IPV6 && kind == libc::IPV6_TCLASS {
                        return std::ptr::read_unaligned(libc::CMSG_DATA(cmsg).cast::<libc::c_int>())
                            as u8;
                    }
                    cmsg = libc::CMSG_NXTHDR(&raw const hdr, cmsg);
                }
            }
            panic!("no traffic class on the received datagram");
        }

        fn receiver(v6: bool) -> Option<std::net::UdpSocket> {
            use std::os::fd::AsRawFd;
            let socket =
                std::net::UdpSocket::bind(if v6 { "[::1]:0" } else { "127.0.0.1:0" }).ok()?;
            let on: libc::c_int = 1;
            let (level, option) = if v6 {
                (libc::IPPROTO_IPV6, libc::IPV6_RECVTCLASS)
            } else {
                (libc::IPPROTO_IP, libc::IP_RECVTOS)
            };
            // SAFETY: the descriptor is open and the value a live c_int.
            let set = unsafe {
                libc::setsockopt(
                    socket.as_raw_fd(),
                    level,
                    option,
                    (&raw const on).cast(),
                    size_of::<libc::c_int>() as libc::socklen_t,
                )
            };
            assert_eq!(set, 0);
            Some(socket)
        }

        #[test]
        fn voice_datagrams_leave_marked_ef_and_plain_ones_unmarked() {
            use std::os::fd::AsRawFd;
            for v6 in [false, true] {
                // A host without IPv6 loopback skips that half.
                let Some(to) = receiver(v6) else { continue };
                let from =
                    std::net::UdpSocket::bind(if v6 { "[::1]:0" } else { "127.0.0.1:0" }).unwrap();
                let target = to.local_addr().unwrap();
                let mut batch = SendBatch::default();
                batch.push_marked(&[1; 100], target, Mark::Voice);
                batch.push(&[2; 100], target);
                batch.push_marked(&[3; 40], target, Mark::Voice);
                let mut sent = 0;
                while sent < batch.len() {
                    sent += send(from.as_raw_fd(), &batch, sent).unwrap();
                }
                let classes: Vec<u8> = (0..3).map(|_| received_class(&to)).collect();
                let ef = EF_TOS as u8;
                assert_eq!(classes, vec![ef, 0, ef], "v6: {v6}");
            }
        }

        #[test]
        fn a_larger_datagram_starts_a_message() {
            let mut batch = SendBatch::default();
            batch.push(&[1; 50], addr(1));
            batch.push(&[1; 60], addr(1));
            assert_eq!(plan(&batch, 0, true, true).len(), 2);
        }

        #[test]
        fn gso_runs_stop_at_the_segment_and_byte_bounds() {
            let mut batch = SendBatch::default();
            for _ in 0..100 {
                batch.push(&[0; 1452], addr(1));
            }
            let plan = plan(&batch, 0, true, true);
            assert!(plan.iter().all(|m| m.count * 1452 <= GSO_BYTES && m.count <= GSO_SEGMENTS));
            assert_eq!(plan.iter().map(|m| m.count).sum::<usize>(), 100);
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
pub(crate) mod apple {
    //! One marked datagram with `sendmsg`: the voice service type rides as
    //! an ancillary `SO_NET_SERVICE_TYPE` (xnu reads it per send, as it reads
    //! `SO_TRAFFIC_CLASS`), so one socket, and so one NAT mapping, carries
    //! every class.
    use std::io;
    use std::mem::{size_of, zeroed};
    use std::net::SocketAddr;
    use std::os::fd::RawFd;

    /// `<sys/socket.h>`: not in the libc crate.
    const SO_NET_SERVICE_TYPE: libc::c_int = 0x1116;
    /// `NET_SERVICE_TYPE_VO`: interactive voice, Wi-Fi's voice queue, DSCP EF
    /// where the system's QoS marking policy allows.
    const NET_SERVICE_TYPE_VO: libc::c_int = 4;
    const CONTROL_BYTES: usize = 32;

    fn encode(addr: SocketAddr, storage: &mut libc::sockaddr_storage) -> libc::socklen_t {
        match addr {
            SocketAddr::V4(v4) => {
                // SAFETY: sockaddr_storage is larger than and aligned for sockaddr_in.
                let sin = unsafe { &mut *(&raw mut *storage).cast::<libc::sockaddr_in>() };
                sin.sin_len = size_of::<libc::sockaddr_in>() as u8;
                sin.sin_family = libc::AF_INET as libc::sa_family_t;
                sin.sin_port = v4.port().to_be();
                sin.sin_addr = libc::in_addr { s_addr: u32::from_ne_bytes(v4.ip().octets()) };
                size_of::<libc::sockaddr_in>() as libc::socklen_t
            }
            SocketAddr::V6(v6) => {
                // SAFETY: as above, for sockaddr_in6.
                let sin6 = unsafe { &mut *(&raw mut *storage).cast::<libc::sockaddr_in6>() };
                sin6.sin6_len = size_of::<libc::sockaddr_in6>() as u8;
                sin6.sin6_family = libc::AF_INET6 as libc::sa_family_t;
                sin6.sin6_port = v6.port().to_be();
                sin6.sin6_flowinfo = v6.flowinfo();
                sin6.sin6_addr = libc::in6_addr { s6_addr: v6.ip().octets() };
                sin6.sin6_scope_id = v6.scope_id();
                size_of::<libc::sockaddr_in6>() as libc::socklen_t
            }
        }
    }

    /// Send `datagram` to `target` in the voice service type.
    pub(crate) fn send_voice(fd: RawFd, datagram: &[u8], target: SocketAddr) -> io::Result<usize> {
        // SAFETY: all-zero is a valid value of these C structs.
        let mut name: libc::sockaddr_storage = unsafe { zeroed() };
        let name_len = encode(target, &mut name);
        let mut iovec =
            libc::iovec { iov_base: datagram.as_ptr().cast_mut().cast(), iov_len: datagram.len() };
        let mut control = [0u64; CONTROL_BYTES / 8];
        // SAFETY: as above.
        let mut hdr: libc::msghdr = unsafe { zeroed() };
        hdr.msg_name = (&raw mut name).cast();
        hdr.msg_namelen = name_len;
        hdr.msg_iov = &raw mut iovec;
        hdr.msg_iovlen = 1;
        hdr.msg_control = control.as_mut_ptr().cast();
        // SAFETY: CMSG_SPACE only computes a size.
        hdr.msg_controllen = unsafe { libc::CMSG_SPACE(size_of::<libc::c_int>() as u32) } as _;
        // SAFETY: the control buffer is CONTROL_BYTES, past CMSG_SPACE(4),
        // 8-byte aligned, and msg_controllen says so; name, iovec and
        // control live until the call returns, the iovec at the borrowed
        // datagram.
        let sent = unsafe {
            let cmsg = libc::CMSG_FIRSTHDR(&raw const hdr);
            (*cmsg).cmsg_level = libc::SOL_SOCKET;
            (*cmsg).cmsg_type = SO_NET_SERVICE_TYPE;
            (*cmsg).cmsg_len = libc::CMSG_LEN(size_of::<libc::c_int>() as u32) as _;
            std::ptr::write_unaligned(
                libc::CMSG_DATA(cmsg).cast::<libc::c_int>(),
                NET_SERVICE_TYPE_VO,
            );
            libc::sendmsg(fd, &raw const hdr, 0)
        };
        if sent < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(usize::try_from(sent).unwrap_or(0))
    }
}

#[cfg(test)]
mod send_batch_tests {
    use super::*;

    #[test]
    fn consumed_datagrams_leave_the_front_in_order() {
        let target = SocketAddr::from(([127, 0, 0, 1], 9));
        let mut batch = SendBatch::default();
        for n in 0..200u8 {
            batch.push(&[n; 3], target);
            if n % 2 == 1 {
                batch.consume(1);
            }
        }
        assert_eq!(batch.len(), 100);
        assert_eq!(batch.get(0), Some((&[100u8; 3][..], target)));
        assert!(batch.entries.len() < 200, "consumed entries were compacted away");
        batch.consume(100);
        assert!(batch.is_empty() && batch.data.is_empty());
    }
}
