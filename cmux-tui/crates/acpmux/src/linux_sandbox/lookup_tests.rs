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
    assert_eq!(XFS_IOC_FSGEOMETRY_V1, ((2u32 << 30) | (112u32 << 16) | ((b'X' as u32) << 8) | 100));
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
        let reason = classify(magic, Ok(0), Ok(0)).expect_err("unverifiable filesystem allowed");
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
