use super::*;
use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::{AsFd, FromRawFd, OwnedFd};
use std::os::unix::net::{UnixListener, UnixStream};

#[test]
fn a_program_name_with_a_nul_is_refused_without_exec() {
    let error = exec_replace(Path::new("bad\0name"), ["x"], [("K", "V")]);
    assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
}

#[test]
fn a_missing_program_returns_the_exec_error() {
    let error = exec_replace(
        Path::new("/nonexistent/cmux-process-exec-test"),
        std::iter::empty::<&str>(),
        std::iter::empty::<(&str, &str)>(),
    );
    assert_eq!(error.raw_os_error(), Some(libc::ENOENT));
}

#[test]
fn failed_exec_restores_explicit_descriptor_flags() {
    let with_cloexec = File::open("/dev/null").unwrap();
    let without_cloexec = File::open("/dev/null").unwrap();
    set_flags(with_cloexec.as_raw_fd(), libc::FD_CLOEXEC).unwrap();
    set_flags(without_cloexec.as_raw_fd(), 0).unwrap();
    let inherited = [with_cloexec.as_fd(), without_cloexec.as_fd()];
    let error = exec_replace_inheriting(
        Path::new("/nonexistent/cmux-process-exec-test"),
        std::iter::empty::<&str>(),
        std::iter::empty::<(&str, &str)>(),
        &inherited,
    );
    assert_eq!(error.raw_os_error(), Some(libc::ENOENT));
    assert_eq!(flags(with_cloexec.as_raw_fd()).unwrap(), libc::FD_CLOEXEC);
    assert_eq!(flags(without_cloexec.as_raw_fd()).unwrap(), 0);
    set_cloexec(&inherited).unwrap();
    assert_eq!(flags(without_cloexec.as_raw_fd()).unwrap(), libc::FD_CLOEXEC);
}

#[test]
fn descriptor_fallback_seals_fds_above_a_lowered_soft_limit() {
    const CHILD: &str = "CMUX_TEST_EXEC_LOWERED_LIMIT";
    const TEST: &str = "exec::tests::descriptor_fallback_seals_fds_above_a_lowered_soft_limit";
    if std::env::var_os(CHILD).is_none() {
        // The lowered process-wide limit must not affect other tests in this harness.
        let status = crate::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", TEST, "--nocapture"])
            .env(CHILD, "1")
            .status()
            .unwrap();
        assert!(status.success(), "lowered descriptor limit fixture exited {status}");
        return;
    }
    let file = File::open("/dev/null").unwrap();
    // SAFETY: this duplicates a live descriptor, which the OwnedFd below takes ownership of.
    let raw = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 200) };
    assert!(raw >= 200, "create a descriptor above the later soft limit");
    // SAFETY: successful F_DUPFD_CLOEXEC returned a new descriptor owned by this test.
    let high = unsafe { OwnedFd::from_raw_fd(raw) };
    set_flags(high.as_raw_fd(), 0).unwrap();
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: limit is writable storage of the correct type.
    assert_eq!(unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) }, 0);
    limit.rlim_cur = 64;
    // SAFETY: only this isolated child process's soft descriptor limit is reduced.
    assert_eq!(unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &limit) }, 0);
    assert_eq!(flags(high.as_raw_fd()).unwrap(), 0, "lowering the limit leaves high fds open");
    // Exercise enumeration even on Linux kernels that normally use close_range instead.
    mark_open_descriptors().unwrap();
    assert_ne!(flags(high.as_raw_fd()).unwrap() & libc::FD_CLOEXEC, 0);
}

/// Runs twice in one child PID, across a real exec. A held flock and a connect queued
/// before exec must survive continuously, while an unrelated non-CLOEXEC fd must close.
#[test]
fn exec_inheriting_keeps_pid_lock_and_listener() {
    const STAGE: &str = "CMUX_TEST_EXEC_INHERIT_STAGE";
    const DIR: &str = "CMUX_TEST_EXEC_INHERIT_DIR";
    const IDS: &str = "CMUX_TEST_EXEC_INHERIT_IDS";
    const TEST: &str = "exec::tests::exec_inheriting_keeps_pid_lock_and_listener";
    let stage = std::env::var(STAGE).unwrap_or_default();
    if stage.is_empty() {
        let nonce =
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir().join(format!("cmux-exec-{}-{nonce}", std::process::id()));
        std::fs::create_dir(&dir).unwrap();
        let status = crate::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", TEST, "--nocapture"])
            .env(STAGE, "before")
            .env(DIR, &dir)
            .status()
            .unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(status.success(), "real exec fixture exited {status}");
        return;
    }
    let dir = std::path::PathBuf::from(std::env::var_os(DIR).unwrap());
    if stage == "before" {
        let lock = File::create(dir.join("lock")).unwrap();
        // SAFETY: lock is this test's live file, and flock takes no pointer.
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
        let listener = UnixListener::bind(dir.join("socket")).unwrap();
        let mut queued = UnixStream::connect(dir.join("socket")).unwrap();
        queued.write_all(b"queued before exec").unwrap();
        let unrelated = File::open("/dev/null").unwrap();
        // Above the harness's ordinary descriptors, so one reopened after exec cannot mask a leak.
        // SAFETY: F_DUPFD_CLOEXEC duplicates the live file to a new owned descriptor.
        let raw = unsafe { libc::fcntl(unrelated.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 200) };
        assert!(raw >= 200);
        // SAFETY: successful F_DUPFD_CLOEXEC returned a new descriptor owned by this test.
        let unrelated = unsafe { OwnedFd::from_raw_fd(raw) };
        set_flags(unrelated.as_raw_fd(), 0).unwrap();
        let ids = format!(
            "{} {} {} {} {}",
            std::process::id(),
            lock.as_raw_fd(),
            listener.as_raw_fd(),
            queued.as_raw_fd(),
            unrelated.as_raw_fd(),
        );
        let env: Vec<(OsString, OsString)> = std::env::vars_os()
            .filter(|(key, _)| {
                key.as_os_str() != OsStr::new(STAGE) && key.as_os_str() != OsStr::new(IDS)
            })
            .chain([(STAGE.into(), "after".into()), (IDS.into(), ids.into())])
            .collect();
        let error = exec_replace_inheriting(
            &std::env::current_exe().unwrap(),
            ["--exact", TEST, "--nocapture"],
            env,
            &[lock.as_fd(), listener.as_fd(), queued.as_fd()],
        );
        panic!("exec failed: {error}");
    }
    assert_eq!(stage, "after");
    let ids: Vec<i32> =
        std::env::var(IDS).unwrap().split(' ').map(|id| id.parse().unwrap()).collect();
    assert_eq!(ids.len(), 5);
    assert_eq!(u32::try_from(ids[0]).unwrap(), std::process::id(), "exec retains the PID");
    assert_eq!(flags(ids[4]).unwrap_err().raw_os_error(), Some(libc::EBADF));
    // SAFETY: the previous image explicitly handed these live descriptors to this test,
    // and these are their first owning Rust values in the new image.
    let (lock, listener, queued) = unsafe {
        (
            File::from_raw_fd(ids[1]),
            UnixListener::from_raw_fd(ids[2]),
            UnixStream::from_raw_fd(ids[3]),
        )
    };
    set_cloexec(&[lock.as_fd(), listener.as_fd(), queued.as_fd()]).unwrap();
    let competing = File::open(dir.join("lock")).unwrap();
    // SAFETY: competing is an independently opened descriptor for the same test file.
    assert_eq!(unsafe { libc::flock(competing.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, -1);
    assert_eq!(io::Error::last_os_error().kind(), io::ErrorKind::WouldBlock);
    let (mut accepted, _) = listener.accept().unwrap();
    accepted.set_read_timeout(Some(std::time::Duration::from_secs(5))).unwrap();
    let mut bytes = [0; 18];
    accepted.read_exact(&mut bytes).unwrap();
    assert_eq!(&bytes, b"queued before exec");
}
