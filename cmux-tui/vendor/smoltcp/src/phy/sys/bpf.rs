use std::io;
use std::mem;
use std::os::unix::io::{AsRawFd, RawFd};

use libc;

use super::{ifreq, ifreq_for};
use crate::phy::Medium;
use crate::wire::ETHERNET_HEADER_LEN;

/// set interface
#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "netbsd",
    target_os = "openbsd",
    target_os = "freebsd"
))]
const BIOCSETIF: libc::c_ulong = 0x8020426c;
/// get buffer length
#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "netbsd",
    target_os = "openbsd",
    target_os = "freebsd"
))]
const BIOCGBLEN: libc::c_ulong = 0x40044266;
/// set immediate/nonblocking read
#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "netbsd",
    target_os = "openbsd",
    target_os = "freebsd"
))]
const BIOCIMMEDIATE: libc::c_ulong = 0x80044270;
/// set bpf_hdr struct size
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "netbsd"))]
const SIZEOF_BPF_HDR: usize = 18;
/// set bpf_hdr struct size
#[cfg(any(target_os = "openbsd", target_os = "freebsd"))]
const SIZEOF_BPF_HDR: usize = 24;
/// The actual header length may be larger than the bpf_hdr struct due to aligning
/// see <https://github.com/openbsd/src/blob/37ecb4d066e5566411cc16b362d3960c93b1d0be/sys/net/bpf.c#L1649>
/// and <https://github.com/apple/darwin-xnu/blob/8f02f2a044b9bb1ad951987ef5bab20ec9486310/bsd/net/bpf.c#L3580>
/// and <https://github.com/NetBSD/src/blob/13d937d9ba3db87c9a898a40a8ed9d2aab2b1b95/sys/net/bpf.c#L1988>
/// for FreeBSD, core::mem::size_of::<libc::bpf_hdr>() = 32 when run on a FreeBSD system.
#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "netbsd",
    target_os = "openbsd",
    target_os = "freebsd"
))]
const BPF_HDRLEN: usize = (((SIZEOF_BPF_HDR + ETHERNET_HEADER_LEN) + mem::align_of::<u32>() - 1)
    & !(mem::align_of::<u32>() - 1))
    - ETHERNET_HEADER_LEN;

macro_rules! try_ioctl {
    ($fd:expr,$cmd:expr,$req:expr) => {
        unsafe {
            if libc::ioctl($fd, $cmd, $req) == -1 {
                return Err(io::Error::last_os_error());
            }
        }
    };
}

#[derive(Debug)]
pub struct BpfDevice {
    fd: libc::c_int,
    ifreq: ifreq,
}

impl AsRawFd for BpfDevice {
    fn as_raw_fd(&self) -> RawFd {
        self.fd
    }
}

fn open_device() -> io::Result<libc::c_int> {
    unsafe {
        for i in 0..256 {
            let dev = format!("/dev/bpf{}\0", i);
            match libc::open(
                dev.as_ptr() as *const libc::c_char,
                libc::O_RDWR | libc::O_NONBLOCK,
            ) {
                -1 => continue,
                fd => return Ok(fd),
            };
        }
    }
    // at this point, all 256 BPF devices were busy and we weren't able to open any
    Err(io::Error::last_os_error())
}

impl BpfDevice {
    pub fn new(name: &str, _medium: Medium) -> io::Result<BpfDevice> {
        Ok(BpfDevice {
            fd: open_device()?,
            ifreq: ifreq_for(name),
        })
    }

    pub fn bind_interface(&mut self) -> io::Result<()> {
        try_ioctl!(self.fd, BIOCSETIF, &mut self.ifreq);

        Ok(())
    }

    /// This in fact does not return the interface's mtu,
    /// but it returns the size of the buffer that the app needs to allocate
    /// for the BPF device
    ///
    /// The `SIOGIFMTU` cant be called on a BPF descriptor. There is a workaround
    /// to get the actual interface mtu, but this should work better
    ///
    /// To get the interface MTU, you would need to create a raw socket first,
    /// and then call `SIOGIFMTU` for the same interface your BPF device is "bound" to.
    /// This MTU that you would get would not include the length of `struct bpf_hdr`
    /// which gets prepended to every packet by BPF,
    /// and your packet will be truncated if it has the length of the MTU.
    ///
    /// The buffer size for BPF is usually 4096 bytes, MTU is typically 1500 bytes.
    /// You could do something like `mtu += BPF_HDRLEN`,
    /// but you must change the buffer size the BPF device expects using `BIOCSBLEN` accordingly,
    /// and you must set it before setting the interface with the `BIOCSETIF` ioctl.
    ///
    /// The reason I said this should work better is because you might see some unexpected behavior,
    /// truncated/unaligned packets, I/O errors on read()
    /// if you change the buffer size to the actual MTU of the interface.
    pub fn interface_mtu(&mut self) -> io::Result<usize> {
        let mut bufsize: libc::c_int = 1;
        try_ioctl!(self.fd, BIOCIMMEDIATE, &mut bufsize as *mut libc::c_int);
        try_ioctl!(self.fd, BIOCGBLEN, &mut bufsize as *mut libc::c_int);

        Ok(bufsize as usize)
    }

    pub fn recv(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        unsafe {
            let len = libc::read(
                self.fd,
                buffer.as_mut_ptr() as *mut libc::c_void,
                buffer.len(),
            );

            if len == -1 || len < BPF_HDRLEN as isize {
                return Err(io::Error::last_os_error());
            }

            let len = len as usize;

            libc::memmove(
                buffer.as_mut_ptr() as *mut libc::c_void,
                &buffer[BPF_HDRLEN] as *const u8 as *const libc::c_void,
                len - BPF_HDRLEN,
            );

            Ok(len)
        }
    }

    pub fn send(&mut self, buffer: &[u8]) -> io::Result<usize> {
        unsafe {
            let len = libc::write(
                self.fd,
                buffer.as_ptr() as *const libc::c_void,
                buffer.len(),
            );

            if len == -1 {
                panic!("{:?}", io::Error::last_os_error())
            }

            Ok(len as usize)
        }
    }
}

impl Drop for BpfDevice {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.fd);
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    #[cfg(any(target_os = "macos", target_os = "netbsd"))]
    fn test_aligned_bpf_hdr_len() {
        assert_eq!(18, BPF_HDRLEN);
    }

    #[test]
    #[cfg(target_os = "openbsd")]
    fn test_aligned_bpf_hdr_len() {
        assert_eq!(26, BPF_HDRLEN);
    }
}
