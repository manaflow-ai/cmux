//! Mounts the projection through the real kernel FUSE and reads it as any program would.

#![cfg(target_os = "linux")]

mod common;

use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::time::Duration;

use cmux_projfs::fuse::{MountConfig, mount};
use cmux_projfs::{CHUNK, Config, Stat};
use common::{MemSource, T0, TempDir, bytes, core_for, file_stat};

fn fusermount_available() -> bool {
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join("fusermount3").is_file()))
        .unwrap_or(false)
}

#[test]
fn a_mounted_projection_reads_lists_and_follows_changes() {
    if !Path::new("/dev/fuse").exists() {
        eprintln!("SKIPPED a_mounted_projection_reads_lists_and_follows_changes: no /dev/fuse");
        return;
    }
    if !fusermount_available() {
        eprintln!(
            "SKIPPED a_mounted_projection_reads_lists_and_follows_changes: no fusermount3 on PATH"
        );
        return;
    }
    let src = MemSource::new();
    let big = bytes(5, 9 << 20);
    src.put("src/a.txt", file_stat(5, T0), b"hello".to_vec());
    src.put("src/big.bin", file_stat(big.len(), T0), big.clone());
    let mut secret = file_stat(4, T0);
    secret.withheld = true;
    src.put("certs/test.key", secret, b"keys".to_vec());
    let tmp = TempDir::new("fuse");
    let mnt = tmp.path().join("mnt");
    std::fs::create_dir(&mnt).unwrap();
    let core = core_for(&src, &tmp.path().join("cache"), Config::default());
    core.apply_delta("src", cmux_projfs::Delta::Stat(Stat::dir(0o750, T0, T0))).unwrap();
    let owner = std::fs::metadata(tmp.path()).unwrap();
    let mut config = MountConfig::new(owner.uid(), owner.gid());
    config.allow_other = false;
    let mounted = match mount(core.clone(), &mnt, &config) {
        Ok(m) => m,
        Err(e) => {
            eprintln!(
                "SKIPPED a_mounted_projection_reads_lists_and_follows_changes: mount failed here ({e})"
            );
            return;
        }
    };

    let mut names: Vec<String> = std::fs::read_dir(mnt.join("src"))
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert_eq!(names, ["a.txt", "big.bin"]);

    let md = std::fs::metadata(mnt.join("src/big.bin")).unwrap();
    assert_eq!(md.len(), big.len() as u64);
    assert_eq!(md.mtime() * 1_000_000_000 + md.mtime_nsec(), T0);
    assert_eq!(md.mode() & 0o7777, 0o644);
    assert_eq!(md.uid(), owner.uid());
    assert_eq!(std::fs::metadata(mnt.join("src")).unwrap().mode() & 0o7777, 0o750);

    assert_eq!(std::fs::read(mnt.join("src/big.bin")).unwrap(), big, "full read");
    let mut f = std::fs::File::open(mnt.join("src/big.bin")).unwrap();
    let at = CHUNK - 100;
    f.seek(SeekFrom::Start(at)).unwrap();
    let mut ranged = vec![0u8; 300];
    f.read_exact(&mut ranged).unwrap();
    assert_eq!(ranged, &big[at as usize..at as usize + 300], "ranged read across a chunk boundary");

    let err = std::fs::File::open(mnt.join("certs/test.key")).unwrap_err();
    assert_eq!(err.raw_os_error(), Some(libc::EACCES), "withheld");
    let err = std::fs::write(mnt.join("src/new.txt"), b"x").unwrap_err();
    assert_eq!(err.raw_os_error(), Some(libc::EROFS));

    // The file changes on the Mac before its first read, and nothing told the machine. The
    // kernel still believes the old size, so the first read faults, the Mac says "changed", the
    // core retries at the new version, and the kernel is told to drop the old attributes.
    let new = b"hello, changed on the Mac".to_vec();
    src.put("src/a.txt", file_stat(new.len(), T0 + 1), new.clone());
    assert_eq!(
        std::fs::metadata(mnt.join("src/a.txt")).unwrap().len(),
        5,
        "the kernel's view before the read"
    );
    let before = mounted.invalidations_sent();
    let first = std::fs::read(mnt.join("src/a.txt")).unwrap();
    assert!(new.starts_with(&first) && !first.is_empty(), "never stale bytes: {first:?}");
    assert!(mounted.wait_invalidations(before + 1, Duration::from_secs(10)), "invalidation sent");
    assert_eq!(std::fs::metadata(mnt.join("src/a.txt")).unwrap().len(), new.len() as u64);
    assert_eq!(std::fs::read(mnt.join("src/a.txt")).unwrap(), new, "new bytes through the mount");
    assert_eq!(core.stats().changed, 1);

    mounted.unmount().unwrap();
    assert!(std::fs::read_dir(&mnt).unwrap().next().is_none(), "unmounted");
}
