//! Mounts the projection through the real kernel FUSE and reads it as any program would.

#![cfg(target_os = "linux")]

mod common;

use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use cmux_projfs::fuse::{MountConfig, Mounted, UNMOUNT_WAIT, Unmount, mount};
use cmux_projfs::{CHUNK, Config, Stat};
use common::{MemSource, T0, TempDir, bytes, core_for, file_stat};

fn fusermount_available() -> bool {
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join("fusermount3").is_file()))
        .unwrap_or(false)
}

/// The mount tests count this process's FUSE threads, so they run one at a time.
fn one_at_a_time() -> MutexGuard<'static, ()> {
    static LOCK: Mutex<()> = Mutex::new(());
    LOCK.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Why this host cannot mount, if it cannot.
fn cannot_mount() -> Option<&'static str> {
    if !Path::new("/dev/fuse").exists() {
        return Some("no /dev/fuse");
    }
    if !fusermount_available() {
        return Some("no fusermount3 on PATH");
    }
    None
}

/// The names of this process's threads that belong to a FUSE session.
fn fuse_threads() -> Vec<String> {
    let mut out = Vec::new();
    for task in std::fs::read_dir("/proc/self/task").unwrap() {
        let comm = std::fs::read_to_string(task.unwrap().path().join("comm")).unwrap_or_default();
        let comm = comm.trim();
        if comm.starts_with("fuser-") || comm.starts_with("projfs-") {
            out.push(comm.to_owned());
        }
    }
    out
}

fn mounted_here(mnt: &Path) -> bool {
    let table = std::fs::read_to_string("/proc/self/mountinfo").unwrap();
    let mnt = mnt.to_str().unwrap();
    table.lines().any(|l| l.split(' ').nth(4) == Some(mnt))
}

/// Waits (bounded, on the thread list itself) until no FUSE thread of this process is left.
fn no_fuse_threads_within(timeout: Duration) -> Vec<String> {
    let deadline = Instant::now() + timeout;
    loop {
        let left = fuse_threads();
        if left.is_empty() || Instant::now() >= deadline {
            return left;
        }
        std::thread::yield_now();
    }
}

fn mount_or_skip(
    test: &str,
    core: std::sync::Arc<cmux_projfs::Core>,
    mnt: &Path,
) -> Option<Mounted> {
    if let Some(why) = cannot_mount() {
        eprintln!("SKIPPED {test}: {why}");
        return None;
    }
    let owner = std::fs::metadata(mnt).unwrap();
    let mut config = MountConfig::new(owner.uid(), owner.gid());
    config.allow_other = false;
    match mount(core, mnt, &config) {
        Ok(m) => Some(m),
        Err(e) => {
            eprintln!("SKIPPED {test}: mount failed here ({e})");
            None
        }
    }
}

#[test]
fn a_mounted_projection_reads_lists_and_follows_changes() {
    let _one = one_at_a_time();
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
    let Some(mounted) =
        mount_or_skip("a_mounted_projection_reads_lists_and_follows_changes", core.clone(), &mnt)
    else {
        return;
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

    drop(f);
    let started = Instant::now();
    let result = mounted.unmount().unwrap();
    assert!(matches!(result, Unmount::Ended), "no file open, so the session ended: {result:?}");
    assert!(started.elapsed() < UNMOUNT_WAIT, "took {:?}", started.elapsed());
    assert!(!mounted_here(&mnt), "unmounted");
    assert!(std::fs::read_dir(&mnt).unwrap().next().is_none(), "unmounted");
    assert_eq!(no_fuse_threads_within(Duration::from_secs(5)), Vec::<String>::new());
}

/// An open file on the projection (as an agent's working directory or a reader would hold)
/// cannot hang the unmount: it detaches, answers "busy" within its bound, and the session ends
/// by itself, leaving no thread behind, once the file closes.
#[test]
fn unmounting_with_a_file_open_answers_busy_and_ends_when_it_closes() {
    let _one = one_at_a_time();
    let src = MemSource::new();
    src.put("a.txt", file_stat(5, T0), b"hello".to_vec());
    let tmp = TempDir::new("fuse-busy");
    let mnt = tmp.path().join("mnt");
    std::fs::create_dir(&mnt).unwrap();
    let core = core_for(&src, &tmp.path().join("cache"), Config::default());
    let Some(mounted) = mount_or_skip(
        "unmounting_with_a_file_open_answers_busy_and_ends_when_it_closes",
        core,
        &mnt,
    ) else {
        return;
    };
    let mut f = std::fs::File::open(mnt.join("a.txt")).unwrap();

    let bound = Duration::from_millis(500);
    let started = Instant::now();
    let result = mounted.unmount_within(bound).unwrap();
    let took = started.elapsed();
    assert!(took < bound + Duration::from_secs(2), "the unmount returned in {took:?}");
    let Unmount::Busy(ending) = result else {
        panic!("a file is open, so the unmount must say busy: {result:?}");
    };
    assert!(!mounted_here(&mnt), "detached from the namespace at once");
    assert!(ending.wait(Duration::from_millis(100)).is_none(), "the session goes on");
    // The open file still reads through the detached session.
    let mut got = String::new();
    f.read_to_string(&mut got).unwrap();
    assert_eq!(got, "hello");

    drop(f);
    let end = ending.wait(Duration::from_secs(10));
    assert!(matches!(end, Some(Ok(()))), "the session ended when the file closed: {end:?}");
    assert_eq!(no_fuse_threads_within(Duration::from_secs(5)), Vec::<String>::new());
}
