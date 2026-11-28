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

/// Datagrams staged in one pass before they leave without waiting for its
/// flush: a bound on the copy kept, not a latency (the pass ends first).
pub(crate) const STAGE_LIMIT: usize = 64;

/// Datagrams waiting to leave, in order, their bytes back to back so a run to
/// one address is one GSO message without copying again. Index 0 is the
/// oldest not yet sent.
#[derive(Debug, Default)]
pub struct SendBatch {
    data: Vec<u8>,
    entries: Vec<(usize, usize, SocketAddr)>,
    /// Entries before this one have left.
    head: usize,
}

impl SendBatch {
    pub(crate) fn push(&mut self, datagram: &[u8], target: SocketAddr) {
        self.entries.push((self.data.len(), datagram.len(), target));
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
        let (start, len, target) = *self.entries.get(self.head + index)?;
        Some((self.data.get(start..start + len)?, target))
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

    use super::{ReceiveBatch, SendBatch};

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
    /// Room for one `cmsghdr` carrying a `c_int` (aligned up generously).
    const CONTROL_BYTES: usize = 32;

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
    /// back to back, as GSO segments of `segment` bytes when `count > 1`.
    struct Message {
        first: usize,
        count: usize,
        segment: usize,
    }

    /// Group datagrams from `from` on into messages: a run to one address of
    /// one size (the last may be shorter) is one GSO message.
    fn plan(batch: &SendBatch, from: usize, gso: bool) -> Vec<Message> {
        let mut messages: Vec<Message> = Vec::new();
        let mut index = from;
        while index < batch.len() && messages.len() < MESSAGES {
            let Some((first, target)) = batch.get(index) else { break };
            let segment = first.len();
            let mut count = 1;
            let mut bytes = segment;
            while gso && count < GSO_SEGMENTS {
                let Some((next, next_target)) = batch.get(index + count) else { break };
                if next_target != target || next.len() > segment || bytes + next.len() > GSO_BYTES {
                    break;
                }
                count += 1;
                bytes += next.len();
                if next.len() < segment {
                    break; // A shorter segment ends the message.
                }
            }
            messages.push(Message { first: index, count, segment });
            index += count;
        }
        messages
    }

    /// Send datagrams `from..` of `batch` with one `sendmmsg`. Returns how
    /// many datagrams left (at least one), or the error of the first message.
    pub(crate) fn send(fd: RawFd, batch: &SendBatch, from: usize) -> io::Result<usize> {
        let gso = !GSO_OFF.load(Ordering::Relaxed);
        let messages = plan(batch, from, gso);
        match send_messages(fd, batch, &messages) {
            Err(error) if gso && error.raw_os_error() == Some(libc::EIO) => {
                // The device cannot checksum a GSO message: one a datagram.
                GSO_OFF.store(true, Ordering::Relaxed);
                send_messages(fd, batch, &plan(batch, from, false))
            }
            result => result,
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
            if message.count > 1 {
                hdr.msg_control = control.as_mut_ptr().cast();
                // SAFETY: CMSG_SPACE only computes a size.
                hdr.msg_controllen = unsafe { libc::CMSG_SPACE(size_of::<u16>() as u32) } as _;
                // SAFETY: the control buffer is CONTROL_BYTES, past
                // CMSG_SPACE(2), 8-byte aligned, and msg_controllen says so.
                unsafe {
                    let cmsg = libc::CMSG_FIRSTHDR(hdr);
                    (*cmsg).cmsg_level = libc::SOL_UDP;
                    (*cmsg).cmsg_type = libc::UDP_SEGMENT;
                    (*cmsg).cmsg_len = libc::CMSG_LEN(size_of::<u16>() as u32) as _;
                    let segment = u16::try_from(message.segment).unwrap_or(u16::MAX);
                    std::ptr::write_unaligned(libc::CMSG_DATA(cmsg).cast::<u16>(), segment);
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
            let plan = plan(&batch, 0, true);
            let shape: Vec<_> = plan.iter().map(|m| (m.first, m.count, m.segment)).collect();
            assert_eq!(shape, vec![(0, 4, 100), (4, 1, 100), (5, 1, 100)]);
            assert_eq!(super::plan(&batch, 0, false).len(), 6);
        }

        #[test]
        fn a_larger_datagram_starts_a_message() {
            let mut batch = SendBatch::default();
            batch.push(&[1; 50], addr(1));
            batch.push(&[1; 60], addr(1));
            assert_eq!(plan(&batch, 0, true).len(), 2);
        }

        #[test]
        fn gso_runs_stop_at_the_segment_and_byte_bounds() {
            let mut batch = SendBatch::default();
            for _ in 0..100 {
                batch.push(&[0; 1452], addr(1));
            }
            let plan = plan(&batch, 0, true);
            assert!(plan.iter().all(|m| m.count * 1452 <= GSO_BYTES && m.count <= GSO_SEGMENTS));
            assert_eq!(plan.iter().map(|m| m.count).sum::<usize>(), 100);
        }
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
