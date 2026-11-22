//! Bounded Unix descriptor transfer shared by private process channels.

use std::io::{self, Write as _};
use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;

/// An aligned control buffer for one descriptor.
#[repr(C, align(8))]
struct ControlBuffer([u8; 64]);

/// Send one descriptor with a bounded nonempty payload. The caller sets its socket deadline.
pub fn send(stream: &UnixStream, bytes: &[u8], descriptor: RawFd) -> io::Result<()> {
    if bytes.is_empty() || bytes.len() > 65_536 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid descriptor payload length",
        ));
    }
    let mut control = ControlBuffer([0; 64]);
    let mut iov =
        libc::iovec { iov_base: bytes.as_ptr() as *mut libc::c_void, iov_len: bytes.len() };
    // SAFETY: CMSG_SPACE/CMSG_LEN are pure size computations.
    let (space, length) = unsafe {
        (
            libc::CMSG_SPACE(size_of::<libc::c_int>() as u32) as usize,
            libc::CMSG_LEN(size_of::<libc::c_int>() as u32) as usize,
        )
    };
    if space > control.0.len() {
        return Err(io::Error::other("descriptor control buffer too small"));
    }
    // SAFETY: zeroed msghdr is a valid empty message.
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut iov;
    message.msg_iovlen = 1;
    message.msg_control = control.0.as_mut_ptr().cast();
    message.msg_controllen = space as _;
    // SAFETY: the message owns a control buffer of `space` aligned bytes, so
    // the first header and its one-descriptor payload are in bounds.
    unsafe {
        let header = libc::CMSG_FIRSTHDR(&message);
        if header.is_null() {
            return Err(io::Error::other("no room for SCM_RIGHTS"));
        }
        (*header).cmsg_level = libc::SOL_SOCKET;
        (*header).cmsg_type = libc::SCM_RIGHTS;
        (*header).cmsg_len = length as _;
        std::ptr::write_unaligned(libc::CMSG_DATA(header).cast::<libc::c_int>(), descriptor);
    }
    #[cfg(any(target_os = "linux", target_os = "android"))]
    let flags = libc::MSG_NOSIGNAL;
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    let flags = 0;
    let sent = loop {
        // SAFETY: a valid socket and a fully initialized message.
        let sent = unsafe { libc::sendmsg(stream.as_raw_fd(), &message, flags) };
        if sent >= 0 {
            break sent.unsigned_abs();
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    };
    if sent == 0 {
        return Err(io::Error::new(io::ErrorKind::WriteZero, "descriptor payload not sent"));
    }
    // The descriptor travelled with the first byte; the rest is plain data.
    let mut writer = stream;
    writer.write_all(bytes.get(sent..).unwrap_or_default())
}

/// Receive the exact bounded payload and at most one owned, close-on-exec descriptor.
pub fn receive(stream: &UnixStream, length: usize) -> io::Result<(Vec<u8>, Option<OwnedFd>)> {
    if length == 0 || length > 65_536 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid descriptor payload length",
        ));
    }
    let mut bytes = vec![0u8; length];
    let mut received = 0;
    let mut descriptor: Option<OwnedFd> = None;
    while received < length {
        let mut control = ControlBuffer([0; 64]);
        let rest = bytes.get_mut(received..).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "descriptor payload overran its buffer")
        })?;
        let mut iov = libc::iovec { iov_base: rest.as_mut_ptr().cast(), iov_len: rest.len() };
        // SAFETY: zeroed msghdr is a valid empty message.
        let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
        message.msg_iov = &mut iov;
        message.msg_iovlen = 1;
        message.msg_control = control.0.as_mut_ptr().cast();
        message.msg_controllen = control.0.len() as _;
        #[cfg(any(target_os = "linux", target_os = "android"))]
        let flags = libc::MSG_CMSG_CLOEXEC;
        #[cfg(not(any(target_os = "linux", target_os = "android")))]
        let flags = 0;
        // SAFETY: a valid socket, buffer and control buffer for the call.
        let count = unsafe { libc::recvmsg(stream.as_raw_fd(), &mut message, flags) };
        if count < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        for fd in take_descriptors(&message) {
            if descriptor.is_some() {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "more than one descriptor"));
            }
            set_cloexec(&fd)?;
            descriptor = Some(fd);
        }
        if message.msg_flags & libc::MSG_CTRUNC != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "truncated descriptor control data",
            ));
        }
        if count == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "closed before descriptor payload",
            ));
        }
        received += count.unsigned_abs();
    }
    Ok((bytes, descriptor))
}

/// Own every `SCM_RIGHTS` descriptor of a received message.
fn take_descriptors(message: &libc::msghdr) -> Vec<OwnedFd> {
    let mut descriptors = Vec::new();
    // SAFETY: the kernel filled the control buffer of `message`; the CMSG
    // macros walk only within msg_controllen.
    unsafe {
        let mut header = libc::CMSG_FIRSTHDR(message);
        while !header.is_null() {
            if (*header).cmsg_level == libc::SOL_SOCKET && (*header).cmsg_type == libc::SCM_RIGHTS {
                let data = libc::CMSG_DATA(header);
                let base = data.offset_from(header.cast::<u8>()).unsigned_abs();
                let payload = ((*header).cmsg_len as usize).saturating_sub(base);
                for index in 0..payload / size_of::<libc::c_int>() {
                    let fd = std::ptr::read_unaligned(
                        data.add(index * size_of::<libc::c_int>()).cast::<libc::c_int>(),
                    );
                    if fd >= 0 {
                        descriptors.push(OwnedFd::from_raw_fd(fd));
                    }
                }
            }
            header = libc::CMSG_NXTHDR(message, header);
        }
    }
    descriptors
}

fn set_cloexec(fd: &OwnedFd) -> io::Result<()> {
    // SAFETY: fcntl on a valid owned descriptor.
    let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFD) };
    // SAFETY: as above.
    if flags < 0
        || unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
