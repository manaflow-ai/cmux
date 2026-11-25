use super::*;
use std::{sync::mpsc, time::Duration};

fn event() -> OwnedFd {
    let fd = unsafe { eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK) };
    assert!(fd >= 0);
    unsafe { OwnedFd::from_raw_fd(fd) }
}

// Files are independently opened, never dup'ed: flock tracks open descriptions.
fn files() -> (OwnedFd, OwnedFd) {
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let path = format!(
        "/tmp/acpmux-lock-test-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    );
    let first = open_at(AT_FDCWD, &path, O_CREAT | O_EXCL | O_RDWR, 0o600).unwrap();
    let second = open_at(AT_FDCWD, &path, O_RDWR, 0).unwrap();
    std::fs::remove_file(path).unwrap();
    (first, second)
}

/// Finite channel handshakes have deadlines; stop bounds lock acquisition.
#[test]
fn transaction_guard_serializes_threads_and_holds_flock() {
    let (first, second) = files();
    let stop = event();
    let listener = event();
    let guard = acquire(&first, stop.as_raw_fd(), listener.as_raw_fd()).unwrap();
    assert_eq!(unsafe { flock(second.as_raw_fd(), LOCK_EX | LOCK_NB) }, -1);
    assert_eq!(error(), EWOULDBLOCK);
    let stop_worker = stop.try_clone().unwrap();
    let (tx, rx) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        let _guard = acquire(&second, stop_worker.as_raw_fd(), listener.as_raw_fd());
        tx.send(()).unwrap();
    });
    assert!(rx.recv_timeout(Duration::from_millis(50)).is_err());
    drop(guard);
    rx.recv_timeout(Duration::from_secs(3)).unwrap();
    worker.join().unwrap();
}

#[test]
fn lock_file_is_owner_write_only() {
    if unsafe { geteuid() } == 0 {
        eprintln!("skipped: lock readability test requires a non-root uid");
        return;
    }
    let path = format!("/tmp/acpmux-lock-mode-{}", std::process::id());
    let file = open_at(AT_FDCWD, &path, O_CREAT | O_EXCL | O_RDWR, 0o200).unwrap();
    let info = stat(file.as_raw_fd()).unwrap();
    assert_eq!(info.st_mode & (S_IFMT | 0o777), S_IFREG | 0o200);
    drop(file);
    assert!(matches!(open_at(AT_FDCWD, &path, O_RDONLY, 0), Err(EACCES)));
    let _ = std::fs::remove_file(path);
}

#[test]
fn preexisting_lock_mode_is_refused() {
    let path = format!("/tmp/acpmux-lock-preexisting-{}", std::process::id());
    let file = open_at(AT_FDCWD, &path, O_CREAT | O_EXCL | O_RDWR, 0o600).unwrap();
    let info = stat(file.as_raw_fd()).unwrap();
    assert!(!valid_lock(&info, unsafe { getuid() }));
    drop(file);
    let _ = std::fs::remove_file(path);
}

/// A competing daemon's flock is held until the waiting thread observes stop.
#[test]
fn external_flock_blocks_until_stop() {
    let (first, second) = files();
    assert_eq!(unsafe { flock(first.as_raw_fd(), LOCK_EX | LOCK_NB) }, 0);
    let stop = event();
    let listener = event();
    let stop_worker = stop.try_clone().unwrap();
    let (tx, rx) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        let result = acquire(&second, stop_worker.as_raw_fd(), listener.as_raw_fd());
        tx.send(result.err()).unwrap();
    });
    let premature = rx.recv_timeout(Duration::from_millis(50));
    assert_eq!(unsafe { write(stop.as_raw_fd(), (&1u64 as *const u64).cast(), 8) }, 8);
    let outcome = premature
        .as_ref()
        .copied()
        .unwrap_or_else(|_| rx.recv_timeout(Duration::from_secs(3)).unwrap());
    worker.join().unwrap();
    assert!(premature.is_err(), "transaction bypassed external flock");
    assert_eq!(outcome, Some(ECANCELED));
}
