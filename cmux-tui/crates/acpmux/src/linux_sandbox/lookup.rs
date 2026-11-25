//! Filesystem lookup verification shared by the resolver and bubblewrap paths.
//!
//! Only filesystems whose case-sensitive lookup semantics can be verified are
//! accepted. Overlayfs and ZFS are deliberately refused because their lookup
//! behavior comes from backing layers or dataset properties outside this fd.
#![allow(dead_code)]

use libc::{self, c_long, c_void};
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd};

const EXT_MAGIC: u64 = 0xef53;
const TMPFS_MAGIC: u64 = 0x0102_1994;
const F2FS_MAGIC: u64 = 0xf2f5_2010;
const BTRFS_MAGIC: u64 = 0x9123_683e;
const XFS_MAGIC: u64 = 0x5846_5342;
const OVERLAY_MAGIC: u64 = 0x794c_7630;
const ZFS_MAGIC: u64 = 0x2fc1_2fc1;
const BCACHEFS_MAGIC: u64 = 0xca45_1a4e;
const FS_CASEFOLD_FL: c_long = 0x4000_0000;

const XFS_IOC_FSGEOMETRY_V1: u32 = 0x8070_5864;
const XFS_FSOP_GEOM_FLAGS_DIRV2CI: u32 = 0x1000;

#[repr(C)]
#[derive(Default)]
struct XfsFsopGeomV1 {
    blocksize: u32,
    rtextsize: u32,
    agblocks: u32,
    agcount: u32,
    logblocks: u32,
    sectsize: u32,
    inodesize: u32,
    imaxpct: u32,
    datablocks: u64,
    rtblocks: u64,
    rtextents: u64,
    logstart: u64,
    uuid: [u8; 16],
    sunit: u32,
    swidth: u32,
    version: i32,
    flags: u32,
    logsectsize: u32,
    rtsectsize: u32,
    dirblocksize: u32,
    logsunit: u32,
}

const _: () = assert!(std::mem::size_of::<XfsFsopGeomV1>() == 112);
const _: () = assert!(std::mem::offset_of!(XfsFsopGeomV1, flags) == 0x5c);

fn errno() -> i32 {
    io::Error::last_os_error().raw_os_error().unwrap_or(libc::EACCES)
}

/// Classify one directory's filesystem from its magic, inode flags, and XFS
/// geometry result. Errors include the magic so refusal diagnostics identify
/// the unverified filesystem. `flags` and `xfs_geometry` use errno values.
pub(crate) fn classify(
    magic: u64,
    flags: Result<c_long, i32>,
    xfs_geometry: Result<u32, i32>,
) -> Result<(), String> {
    match magic {
        EXT_MAGIC | TMPFS_MAGIC | F2FS_MAGIC | BCACHEFS_MAGIC => match flags {
            Ok(bits) if bits & FS_CASEFOLD_FL == 0 => Ok(()),
            _ => Err(format!("casefold or unverified directory flags on filesystem {magic:#x}")),
        },
        BTRFS_MAGIC => Ok(()),
        XFS_MAGIC => match xfs_geometry {
            Ok(bits) if bits & XFS_FSOP_GEOM_FLAGS_DIRV2CI == 0 => Ok(()),
            Ok(_) => Err(format!("case-insensitive XFS geometry on filesystem {magic:#x}")),
            Err(_) => Err(format!("unverified XFS geometry on filesystem {magic:#x}")),
        },
        OVERLAY_MAGIC => Err(format!(
            "overlay layer lookup semantics are unverifiable for filesystem {magic:#x}"
        )),
        ZFS_MAGIC => {
            Err(format!("ZFS dataset lookup semantics are unverifiable for filesystem {magic:#x}"))
        }
        _ => Err(format!("unsupported filesystem magic {magic:#x}")),
    }
}

/// Verify the filesystem mounted at a held directory fd. The fd is borrowed
/// only for these bounded fstatfs/ioctl calls; no path is reconstructed here.
pub(crate) fn verify_dir(fd: BorrowedFd<'_>) -> Result<(), String> {
    let mut fs: libc::statfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstatfs(fd.as_raw_fd(), &mut fs) } < 0 {
        return Err(format!("fstatfs failed for directory: errno {}", errno()));
    }
    let magic = fs.f_type as u64;
    // O_PATH is enough for fstatfs, but inode and XFS ioctls need a readable
    // directory description. Reopen the same held object without following a
    // mutable child name.
    let readable = unsafe {
        libc::openat(
            fd.as_raw_fd(),
            c".".as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NONBLOCK,
        )
    };
    if readable < 0 {
        return Err(format!("cannot reopen directory for lookup verification: errno {}", errno()));
    }
    let readable = unsafe { OwnedFd::from_raw_fd(readable) };
    let readable_fd = readable.as_raw_fd();
    let mut bits: c_long = 0;
    let flags = if unsafe { libc::ioctl(readable_fd, libc::FS_IOC_GETFLAGS as _, &mut bits) } < 0 {
        Err(errno())
    } else {
        Ok(bits)
    };
    let geometry = if magic == XFS_MAGIC {
        let mut geom = XfsFsopGeomV1::default();
        if unsafe {
            libc::ioctl(
                readable_fd,
                XFS_IOC_FSGEOMETRY_V1 as _,
                (&mut geom as *mut XfsFsopGeomV1).cast::<c_void>(),
            )
        } < 0
        {
            Err(errno())
        } else {
            Ok(geom.flags)
        }
    } else {
        Err(libc::ENOTTY)
    };
    classify(magic, flags, geometry)
}

/// The classifier tests use finite tables; the real checks cover tmpfs and
/// ext4 when available on the runner and report unsupported runner mounts.
#[cfg(test)]
mod tests {
    use super::*;
    use libc::{EACCES, EIO, ENOTTY, EOPNOTSUPP};
    use std::os::fd::AsFd;

    #[test]
    fn refuses_unverified_filesystems() {
        for magic in [
            0x4d44,
            0x2011_bab0,
            0x5346_544e,
            0x517b,
            0xff53_4d42,
            0xfe53_4d42,
            0x482b,
            0,
            0x1234_5678,
            0x9fa0,
            0x1cd1,
        ] {
            let reason = classify(magic, Ok(0), Ok(0)).expect_err("unsupported filesystem allowed");
            assert!(reason.contains(&format!("{magic:#x}")));
        }
    }

    #[test]
    fn casefold_capable_filesystems_require_flags() {
        for magic in [EXT_MAGIC, F2FS_MAGIC, TMPFS_MAGIC, BCACHEFS_MAGIC] {
            assert!(classify(magic, Ok(0), Err(ENOTTY)).is_ok());
            for flags in [Ok(FS_CASEFOLD_FL), Err(ENOTTY), Err(EOPNOTSUPP), Err(EIO), Err(EACCES)] {
                assert!(classify(magic, flags, Err(ENOTTY)).is_err());
            }
        }
        assert!(classify(BTRFS_MAGIC, Err(ENOTTY), Err(ENOTTY)).is_ok());
    }

    #[test]
    fn xfs_geometry_request_matches_uapi_encoding() {
        assert_eq!(
            XFS_IOC_FSGEOMETRY_V1,
            ((2u32 << 30) | (112u32 << 16) | ((b'X' as u32) << 8) | 100)
        );
    }

    #[test]
    fn xfs_requires_case_sensitive_geometry() {
        assert!(classify(XFS_MAGIC, Err(ENOTTY), Ok(0)).is_ok());
        assert!(classify(XFS_MAGIC, Err(ENOTTY), Ok(0x10)).is_ok());
        for geometry in [Ok(XFS_FSOP_GEOM_FLAGS_DIRV2CI), Ok(0x1010), Err(ENOTTY), Err(EIO)] {
            assert!(classify(XFS_MAGIC, Ok(0), geometry).is_err());
        }
    }

    #[test]
    fn overlay_and_zfs_are_refused_with_reasons() {
        for (magic, text) in [(OVERLAY_MAGIC, "layer"), (ZFS_MAGIC, "dataset")] {
            let reason =
                classify(magic, Ok(0), Ok(0)).expect_err("unverifiable filesystem allowed");
            assert!(reason.contains(&format!("{magic:#x}")));
            assert!(reason.contains(text));
        }
    }

    #[test]
    fn real_tmpfs_and_ext4_directories_verify_when_present() {
        let tmpfs = unsafe {
            libc::open(c"/dev/shm".as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC)
        };
        assert!(tmpfs >= 0);
        let tmpfs = unsafe { std::os::fd::OwnedFd::from_raw_fd(tmpfs) };
        verify_dir(tmpfs.as_fd()).expect("runner tmpfs lookup semantics");

        let ext = unsafe {
            libc::open(c"/tmp".as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC)
        };
        assert!(ext >= 0);
        let ext = unsafe { std::os::fd::OwnedFd::from_raw_fd(ext) };
        let mut fs: libc::statfs = unsafe { std::mem::zeroed() };
        assert_eq!(unsafe { libc::fstatfs(ext.as_raw_fd(), &mut fs) }, 0);
        if fs.f_type as u64 == EXT_MAGIC {
            verify_dir(ext.as_fd()).expect("runner ext4 lookup semantics");
        } else {
            eprintln!("skipped: /tmp is not ext4 (magic {:#x})", fs.f_type as u64);
        }
    }
}
