use std::error::Error as _;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};

use super::*;

/// A PTY child starts with default dispositions and an empty signal
/// mask even when its parent ignores or blocks signals (a terminal host
/// ignores HUP, INT and QUIT for itself). Ignored dispositions and the
/// mask survive `exec`, so without the reset a shell would not die on a
/// hangup or Ctrl-C. The probe runs in a re-executed copy of this test
/// binary, so the parent-side SIG_IGN never touches other tests.
///
/// The PTY child is a third copy of this binary that reads its own
/// dispositions (`sigaction`) and mask (`pthread_sigmask`) and prints
/// them as two hex bit sets. `ps -o ignored=,blocked=` cannot do this on
/// macOS: its ps has no `ignored` keyword and prints its keyword list.
#[test]
fn a_pty_child_gets_default_signals_and_an_empty_mask_from_an_ignoring_parent()
-> Result<(), Box<dyn std::error::Error>> {
    const PROBE: &str = "CMUX_PTY_SIGNAL_PROBE";
    const REPORT: &str = "CMUX_PTY_SIGNAL_REPORT";
    const NAME: &str =
        "tests::a_pty_child_gets_default_signals_and_an_empty_mask_from_an_ignoring_parent";
    let bit = |signal: libc::c_int| 1u64 << (signal - 1);
    if std::env::var_os(REPORT).is_some() {
        let (mut ignored, mut blocked) = (0u64, 0u64);
        // SAFETY: query-only sigaction and pthread_sigmask calls on
        // this process; null new-action and new-set pointers change
        // nothing.
        unsafe {
            let mut mask = std::mem::MaybeUninit::<libc::sigset_t>::uninit();
            libc::sigemptyset(mask.as_mut_ptr());
            assert_eq!(
                libc::pthread_sigmask(libc::SIG_BLOCK, std::ptr::null(), mask.as_mut_ptr()),
                0
            );
            // SIGKILL and SIGSTOP cannot be ignored, and macOS refuses
            // even a query of them with EINVAL.
            for signal in (1..32).filter(|&s| s != libc::SIGKILL && s != libc::SIGSTOP) {
                let mut action = std::mem::MaybeUninit::<libc::sigaction>::zeroed();
                assert_eq!(libc::sigaction(signal, std::ptr::null(), action.as_mut_ptr()), 0);
                if action.assume_init().sa_sigaction == libc::SIG_IGN {
                    ignored |= bit(signal);
                }
                if libc::sigismember(mask.as_ptr(), signal) == 1 {
                    blocked |= bit(signal);
                }
            }
        }
        println!("probe: {ignored:x} {blocked:x}");
        return Ok(());
    }
    if std::env::var_os(PROBE).is_some() {
        // SAFETY: SIG_IGN and sigprocmask on this probe process only.
        unsafe {
            for signal in [libc::SIGHUP, libc::SIGINT, libc::SIGQUIT, libc::SIGTERM] {
                libc::signal(signal, libc::SIG_IGN);
            }
            let mut set = std::mem::MaybeUninit::<libc::sigset_t>::uninit();
            libc::sigemptyset(set.as_mut_ptr());
            libc::sigaddset(set.as_mut_ptr(), libc::SIGHUP);
            libc::pthread_sigmask(libc::SIG_BLOCK, set.as_ptr(), std::ptr::null_mut());
        }
        let pair = open(PtySize { rows: 24, cols: 120, pixel_width: 0, pixel_height: 0 })?;
        let mut command = PtyCommand::new(std::env::current_exe()?.to_string_lossy());
        command.args(["--exact", NAME, "--nocapture", "--test-threads=1"]);
        command.env(REPORT, "1");
        let mut spawned = pair.spawn(command)?;
        let mut reader = spawned.master.try_clone_reader()?;
        let mut output = Vec::new();
        let mut buffer = [0u8; 4096];
        while let Ok(count) = io::Read::read(&mut reader, &mut buffer) {
            if count == 0 {
                break;
            }
            output.extend_from_slice(&buffer[..count]);
            if output.windows(6).any(|w| w == b"probe:") && output.ends_with(b"\n") {
                break;
            }
        }
        let _ = spawned.child.wait();
        println!("{}", String::from_utf8_lossy(&output).trim());
        return Ok(());
    }
    let output = std::process::Command::new(std::env::current_exe()?)
        .args(["--exact", NAME, "--nocapture", "--test-threads=1"])
        .env(PROBE, "1")
        .output()?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let line = stdout
        .lines()
        .find_map(|line| line.split("probe:").nth(1))
        .ok_or_else(|| format!("probe printed no masks: {stdout}{stderr}"))?;
    let masks = line
        .split_whitespace()
        .map(|hex| u64::from_str_radix(hex.trim_start_matches("0x"), 16))
        .collect::<Result<Vec<_>, _>>()?;
    assert_eq!(masks.len(), 2, "{line}");
    let (ignored, blocked) = (masks[0], masks[1]);
    let reset = [libc::SIGHUP, libc::SIGINT, libc::SIGQUIT, libc::SIGTERM];
    let reset = reset.into_iter().fold(0, |mask, signal| mask | bit(signal));
    assert_eq!(ignored & reset, 0, "child ignores {line}");
    assert_eq!(blocked, 0, "child blocks signals: {line}");
    Ok(())
}

#[test]
fn pty_capacity_errors_preserve_an_actionable_classification() {
    for errno in [libc::ENXIO, libc::ENOSPC, libc::EMFILE, libc::ENFILE, libc::EAGAIN] {
        let error = PtyOpenError::from_io(io::Error::from_raw_os_error(errno));
        assert_eq!(error.kind(), PtyOpenErrorKind::CapacityExhausted);
        assert!(error.is_capacity_exhausted());
        assert!(error.to_string().contains("PTY capacity exhausted"));
        assert!(error.source().is_some());
    }
}

/// Restoring a session opens many PTYs at the same moment (170 kept agent
/// terminals after an app update). macOS refuses a PTY master open for a
/// moment under such a burst (`posix_openpt` fails with -6, a
/// kernel-internal code; 44 of 64 opens on macOS 26.5.2, 24 of 60 on
/// 27.0.1), far below `kern.tty.ptmx_max`. Every open must succeed.
#[test]
fn ptys_opened_at_the_same_moment_all_open() {
    const OPENS: usize = 64;
    let start = std::sync::Barrier::new(OPENS);
    let size = PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 };
    let failures = std::thread::scope(|scope| {
        let workers = (0..OPENS)
            .map(|_| {
                scope.spawn(|| {
                    start.wait();
                    open(size).map_err(|error| format!("{error:#}"))
                })
            })
            .collect::<Vec<_>>();
        // Every pair stays open until the last open ended.
        let opened = workers
            .into_iter()
            .map(|worker| worker.join().expect("an open panicked"))
            .collect::<Vec<_>>();
        opened.iter().filter_map(|pair| pair.as_ref().err().cloned()).collect::<Vec<_>>()
    });
    assert!(
        failures.is_empty(),
        "{} of {OPENS} PTYs opened at the same moment did not open: {}",
        failures.len(),
        failures[0]
    );
}

#[test]
fn unrelated_pty_open_errors_remain_distinguishable() {
    let error = PtyOpenError::from_io(io::Error::from_raw_os_error(libc::EBADF));
    assert_eq!(error.kind(), PtyOpenErrorKind::Other);
    assert!(!error.is_capacity_exhausted());
    assert!(error.to_string().contains("failed to open PTY"));
}

#[test]
fn missing_program_fails_before_the_child_is_published() {
    let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
    let result = pair.spawn(PtyCommand::new("/definitely/missing/cmux-pty-program"));

    if let Ok(mut spawned) = result {
        let status = spawned.child.wait().unwrap();
        panic!("missing PTY program was published as child status {status:?}");
    }
}

#[test]
fn empty_program_is_rejected_before_platform_spawn() {
    let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
    let error = match pair.spawn(PtyCommand::new("")) {
        Ok(_) => panic!("empty PTY program was spawned"),
        Err(error) => error,
    };
    assert!(error.to_string().contains("program must not be empty"));
}

#[test]
fn whitespace_only_program_is_rejected_before_platform_spawn() {
    let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
    let error = match pair.spawn(PtyCommand::new(" \t\n")) {
        Ok(_) => panic!("whitespace-only PTY program was spawned"),
        Err(error) => error,
    };
    assert!(error.to_string().contains("program must not be empty"));
}

#[test]
fn successful_exec_does_not_inherit_unmarked_parent_descriptors() {
    let source = File::open("/dev/null").unwrap();
    let descriptor = unsafe { libc::fcntl(source.as_raw_fd(), libc::F_DUPFD, 200) };
    assert!(descriptor >= 200);
    let inherited = unsafe { File::from_raw_fd(descriptor) };
    let flags = unsafe { libc::fcntl(inherited.as_raw_fd(), libc::F_GETFD) };
    assert_eq!(flags & libc::FD_CLOEXEC, 0);

    let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
    let mut command = PtyCommand::new("/bin/sh");
    command.args(["-c", &format!("test ! -e /dev/fd/{descriptor}")]);
    let mut spawned = pair.spawn(command).unwrap();
    let status = spawned.child.wait().unwrap();

    assert!(status.success(), "child inherited parent descriptor {descriptor}: {status:?}");
    let parent_flags = unsafe { libc::fcntl(inherited.as_raw_fd(), libc::F_GETFD) };
    assert_eq!(parent_flags & libc::FD_CLOEXEC, 0, "child cleanup changed the parent descriptor");
}

#[cfg(target_os = "linux")]
#[test]
fn close_range_seccomp_fallback_keeps_pty_spawn_working() {
    const CHILD_ENV: &str = "CMUX_PTY_CLOSE_RANGE_SECCOMP_CHILD";
    if std::env::var_os(CHILD_ENV).is_none() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("tests::close_range_seccomp_fallback_keeps_pty_spawn_working")
            .arg("--exact")
            .arg("--nocapture")
            .env(CHILD_ENV, "1")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "PTY spawn failed when seccomp denied close_range:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    install_close_range_eperm_filter();
    let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
    let mut command = PtyCommand::new("/bin/sh");
    command.args(["-c", "exit 0"]);
    let mut spawned = pair.spawn(command).expect("seccomp-compatible PTY spawn");
    assert!(spawned.child.wait().unwrap().success());
}

#[cfg(target_os = "linux")]
fn install_close_range_eperm_filter() {
    let mut filter = [
        libc::sock_filter {
            code: (libc::BPF_LD | libc::BPF_W | libc::BPF_ABS) as u16,
            jt: 0,
            jf: 0,
            k: 0,
        },
        libc::sock_filter {
            code: (libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K) as u16,
            jt: 0,
            jf: 1,
            k: libc::SYS_close_range as u32,
        },
        libc::sock_filter {
            code: (libc::BPF_RET | libc::BPF_K) as u16,
            jt: 0,
            jf: 0,
            k: libc::SECCOMP_RET_ERRNO | libc::EPERM as u32,
        },
        libc::sock_filter {
            code: (libc::BPF_RET | libc::BPF_K) as u16,
            jt: 0,
            jf: 0,
            k: libc::SECCOMP_RET_ALLOW,
        },
    ];
    let program = libc::sock_fprog { len: filter.len() as u16, filter: filter.as_mut_ptr() };

    let no_new_privileges = unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) };
    assert_eq!(no_new_privileges, 0, "PR_SET_NO_NEW_PRIVS failed: {}", io::Error::last_os_error());
    let installed = unsafe {
        libc::prctl(
            libc::PR_SET_SECCOMP,
            libc::SECCOMP_MODE_FILTER,
            &program as *const libc::sock_fprog,
        )
    };
    assert_eq!(installed, 0, "seccomp filter installation failed: {}", io::Error::last_os_error());
}
