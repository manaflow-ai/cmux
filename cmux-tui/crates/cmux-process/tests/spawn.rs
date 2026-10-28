//! `cmux_process::Command` behaves as `std::process::Command` for what the
//! daemon uses, and on macOS a child inherits no descriptor it was not given.

#![cfg(unix)]

#[path = "support/open_descriptors.rs"]
mod support;

/// One module name in every spawn test, so a fleet step can select them all
/// (`--arg test --arg daemon_spawn::`).
mod daemon_spawn {
    #[cfg(target_vendor = "apple")]
    use super::support::open_descriptors;
    use cmux_process::{Command, Stdio};
    use std::io::{Read, Write};
    use std::os::fd::AsRawFd;
    use std::os::fd::{AsFd, FromRawFd, OwnedFd};
    use std::time::{Duration, Instant};

    /// A pipe whose ends are inheritable (no close-on-exec), as a descriptor is
    /// on macOS between `recvmsg` and the `fcntl` after it.
    fn inheritable_pipe() -> (OwnedFd, OwnedFd) {
        let mut fds = [0; 2];
        // SAFETY: pipe fills two descriptors.
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        // SAFETY: two new descriptors the test owns.
        unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) }
    }

    #[test]
    fn output_captures_both_streams_and_the_exit_code() {
        let output = Command::new("/bin/sh")
            .args(["-c", "echo out; echo err >&2; exit 3"])
            .output()
            .unwrap();
        assert_eq!(output.stdout, b"out\n");
        assert_eq!(output.stderr, b"err\n");
        assert_eq!(output.status.code(), Some(3));
    }

    #[test]
    fn a_piped_stdin_reaches_the_child_and_closes_at_wait() {
        let mut child =
            Command::new("cat").stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
        child.stdin.as_mut().unwrap().write_all(b"through the pipe").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"through the pipe");
    }

    #[test]
    fn the_environment_is_cleared_set_and_removed_as_asked() {
        let output = Command::new("/usr/bin/env")
            .env_clear()
            .env("A", "1")
            .env("B", "2")
            .env_remove("B")
            .output()
            .unwrap();
        assert_eq!(String::from_utf8_lossy(&output.stdout), "A=1\n");
        let output = Command::new("/bin/sh")
            .args(["-c", "echo $CMUX_PROCESS_T"])
            .env("CMUX_PROCESS_T", "x")
            .output()
            .unwrap();
        assert_eq!(output.stdout, b"x\n");
    }

    /// A program name is looked up as std does (finding 4 of PL-daemon's
    /// review): in the `PATH` the builder gives the child, and after an
    /// `env_clear` that sets none, in this process's `PATH`.
    #[test]
    fn a_program_name_is_found_in_the_childs_path_as_std_finds_it() {
        let dir = std::env::temp_dir().join(format!(
            "cmux-process-path-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir(&dir).unwrap();
        // A link to `echo`, not a script this test writes: a file still
        // open for writing when another test thread forks cannot be run
        // (ETXTBSY) until that child execs.
        std::os::unix::fs::symlink("/bin/echo", dir.join("cmux-process-path-probe")).unwrap();

        let output = Command::new("cmux-process-path-probe")
            .arg("found-in-child-path")
            .env_clear()
            .env("PATH", &dir)
            .output()
            .unwrap();
        assert_eq!(output.stdout, b"found-in-child-path\n");
        let output = Command::new("cmux-process-path-probe")
            .arg("found-in-child-path")
            .env("PATH", &dir)
            .output()
            .unwrap();
        assert_eq!(output.stdout, b"found-in-child-path\n");
        // Not in this process's PATH: only the child's PATH finds it.
        assert!(Command::new("cmux-process-path-probe").spawn().is_err());
        // env_clear with no PATH: this process's PATH finds `sh`.
        let output =
            Command::new("sh").env_clear().args(["-c", "echo via-parent-path"]).output().unwrap();
        assert_eq!(output.stdout, b"via-parent-path\n");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A new PTY: its master (close-on-exec) and its slave's path.
    fn open_pty() -> (OwnedFd, std::path::PathBuf) {
        // SAFETY: posix_openpt returns a new descriptor or -1.
        let master = unsafe { libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY) };
        assert!(master >= 0, "posix_openpt: {}", std::io::Error::last_os_error());
        // SAFETY: a new descriptor the test owns.
        let master = unsafe { OwnedFd::from_raw_fd(master) };
        let raw = master.as_raw_fd();
        // SAFETY: plain calls on the master the test owns; ptsname's static
        // buffer is copied at once (one PTY test in this binary).
        let name = unsafe {
            assert_eq!(libc::fcntl(raw, libc::F_SETFD, libc::FD_CLOEXEC), 0);
            assert_eq!(libc::grantpt(raw), 0);
            assert_eq!(libc::unlockpt(raw), 0);
            let name = libc::ptsname(raw);
            assert!(!name.is_null(), "ptsname");
            std::ffi::CStr::from_ptr(name).to_string_lossy().into_owned()
        };
        (master, std::path::PathBuf::from(name))
    }

    /// `open_stdin_path` with `new_session` (the shell spawn of a PTY):
    /// the child's 0, 1 and 2 are the PTY slave and the slave is its
    /// controlling terminal (`/dev/tty` opens and writing to it reaches the
    /// master), as `cmux-mux2`'s `spawn_pty` makes it.
    #[test]
    fn a_pty_slave_opened_as_stdin_is_the_new_sessions_controlling_terminal() {
        let (master, slave) = open_pty();
        let mut child = Command::new("/bin/sh")
            .args(["-c", "tty; echo via-ctty > /dev/tty && echo ctty-ok; echo err-on-pty >&2"])
            .new_session()
            .open_stdin_path(&slave)
            .spawn()
            .unwrap();
        // Read the master until the child's last line (the deadline only
        // fails a child that never writes it).
        let (sent, got) = std::sync::mpsc::channel();
        // The reader gets a copy: the master stays open here until the
        // child ended (closing a PTY master hangs up its session, so a shell
        // still exiting would die of SIGHUP).
        let mut reader = std::fs::File::from(master.try_clone().unwrap());
        std::thread::spawn(move || {
            let mut all = Vec::new();
            let mut chunk = [0u8; 4096];
            loop {
                match reader.read(&mut chunk) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        all.extend_from_slice(&chunk[..n]);
                        if String::from_utf8_lossy(&all).contains("err-on-pty") {
                            break;
                        }
                    }
                }
            }
            let _ = sent.send(String::from_utf8_lossy(&all).into_owned());
        });
        let text =
            got.recv_timeout(Duration::from_secs(30)).expect("the child never wrote to its PTY");
        assert!(child.wait().unwrap().success(), "{text}");
        drop(master);
        let lines: Vec<&str> = text.lines().map(str::trim_end).collect();
        assert_eq!(
            lines.first().copied(),
            Some(slave.to_str().unwrap()),
            "stdin is not the slave: {text}"
        );
        assert!(lines.contains(&"via-ctty"), "/dev/tty did not reach this PTY: {text}");
        assert!(lines.contains(&"ctty-ok"), "/dev/tty did not open: {text}");
        assert!(lines.contains(&"err-on-pty"), "stderr is not the PTY: {text}");
    }

    #[test]
    fn the_child_runs_in_its_working_directory() {
        let dir = std::fs::canonicalize(std::env::temp_dir()).unwrap();
        let output = Command::new("/bin/pwd").current_dir(&dir).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), dir.to_string_lossy());
    }

    #[test]
    fn a_program_that_is_missing_or_not_executable_fails_the_spawn() {
        let missing = Command::new("cmux-process-no-such-program").spawn().unwrap_err();
        assert_eq!(missing.kind(), std::io::ErrorKind::NotFound);
        assert!(Command::new("/etc/hosts").spawn().is_err(), "a non-executable file ran");
    }

    #[test]
    fn wait_timeout_returns_none_for_a_running_child_and_the_status_once_it_ends() {
        let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let started = Instant::now();
        assert_eq!(child.wait_timeout(Duration::from_millis(200)).unwrap(), None);
        assert!(started.elapsed() >= Duration::from_millis(200), "returned before the limit");
        child.kill().unwrap();
        let status =
            child.wait_timeout(Duration::from_secs(20)).unwrap().expect("the killed child ended");
        use std::os::unix::process::ExitStatusExt;
        assert_eq!(status.signal(), Some(libc::SIGKILL));
        child.kill().unwrap();
        assert_eq!(child.wait().unwrap(), status, "a reaped child keeps its status");

        let mut quick = Command::new("/usr/bin/true").spawn().unwrap();
        let status = quick.wait_timeout(Duration::from_secs(20)).unwrap().expect("true ended");
        assert!(status.success());
    }

    #[test]
    fn a_child_gets_its_own_process_group_or_session_when_asked() {
        let mut grouped = Command::new("/bin/sleep").arg("30").process_group(0).spawn().unwrap();
        let pid = grouped.id() as libc::pid_t;
        // SAFETY: getpgid reads a child of this process.
        assert_eq!(unsafe { libc::getpgid(pid) }, pid);
        grouped.kill().unwrap();
        grouped.wait().unwrap();

        let mut leader = Command::new("/bin/sleep").arg("30").new_session().spawn().unwrap();
        let pid = leader.id() as libc::pid_t;
        // SAFETY: getsid reads a child of this process.
        assert_eq!(unsafe { libc::getsid(pid) }, pid);
        leader.kill().unwrap();
        leader.wait().unwrap();
    }

    #[test]
    fn an_inherited_descriptor_reaches_the_child_at_its_number() {
        let (read, write) = inheritable_pipe();
        let mut child = Command::new("/bin/sh")
            .args(["-c", "echo through-five >&5"])
            .inherit_fd(write.as_fd(), 5)
            .unwrap()
            .spawn()
            .unwrap();
        drop(write);
        assert!(child.wait().unwrap().success());
        let mut got = String::new();
        std::fs::File::from(read).read_to_string(&mut got).unwrap();
        assert_eq!(got, "through-five\n");
    }

    /// The fix for the macOS race (review 1 and 2 of pl-holder-11): a
    /// descriptor this process has open without close-on-exec, as a received
    /// PTY master or ring segment is between `recvmsg` and its `fcntl`, does not
    /// reach a child. Red with `std::process::Command` (checked here too, so the
    /// detector is known to see such a descriptor).
    #[cfg(target_vendor = "apple")]
    #[test]
    fn a_child_inherits_no_descriptor_it_was_not_given() {
        let (read, write) = inheritable_pipe();
        let leaked = [read.as_raw_fd(), write.as_raw_fd()];

        // Read once the shell runs its script: while a program starts, the
        // dynamic loader holds libc open on a descriptor of its own.
        use std::io::BufRead;
        let mut child = Command::new("/bin/sh")
            .args(["-c", "echo ready; read line; exit 0"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        std::io::BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
        let open = open_descriptors(child.id()).unwrap();
        assert!(child.wait().unwrap().success());
        assert_eq!(
            open,
            [0, 1, 2],
            "the child has more than its 0-2: {open:?} (leaked {leaked:?})"
        );

        #[allow(clippy::disallowed_methods)] // the detector's control: std passes it on
        let mut control = std::process::Command::new("/bin/sh")
            .args(["-c", "echo ready; read line; exit 0"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        std::io::BufReader::new(control.stdout.take().unwrap()).read_line(&mut line).unwrap();
        let open = open_descriptors(control.id()).unwrap();
        drop(control.stdin.take());
        assert!(control.wait().unwrap().success());
        assert!(
            leaked.iter().all(|fd| open.contains(fd)),
            "std's child should have inherited {leaked:?} (the detector sees nothing): {open:?}"
        );
    }
}
