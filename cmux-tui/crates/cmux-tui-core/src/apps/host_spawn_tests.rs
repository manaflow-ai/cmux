use std::os::fd::AsRawFd;
use std::sync::mpsc::channel;
use std::time::Duration;

use cmux_app_host::FromHost;

use super::HostProcess;

/// A host binary that cannot run is reported as an exit that never
/// started. The descriptor step used to close `Command::spawn`'s
/// exec-error pipe: the child aborted and the spawn looked successful.
#[test]
fn a_host_binary_that_cannot_run_is_a_spawn_error() {
    let missing = std::path::Path::new("/nonexistent/cmux-app-host");
    let (tx, rx) = channel();
    let started = HostProcess::spawn(
        missing,
        &[],
        "missing",
        |_| {},
        move |exit| {
            let _ = tx.send(exit);
        },
    );
    assert!(started.is_ok(), "the start happens on the host's thread");
    let exit = rx.recv_timeout(Duration::from_secs(30)).expect("an exit");
    let error = exit.expect_err("a missing binary does not start");
    assert_eq!(error.kind(), std::io::ErrorKind::NotFound, "{error}");
}

/// A host gets null stdio and its channel on fd 3, nothing else of the
/// daemon: not a descriptor some library opened without close-on-exec.
#[test]
fn a_host_inherits_only_its_channel_and_null_stdio() {
    let file = std::fs::File::open("/dev/null").unwrap();
    // SAFETY: duplicating our own open descriptor; F_DUPFD leaves the copy inheritable.
    let leaked = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_DUPFD, 200) };
    assert!(leaked >= 200, "an inheritable descriptor at 200 or above");
    let template =
        serde_json::to_string(&FromHost::Log { level: "info".into(), message: "FDS".into() })
            .unwrap()
            .replace('"', "\\\"");
    let line = template.replace("FDS", "$(ls /dev/fd | tr '\\n' ' ')");
    let script = format!("printf '%s\\n' \"{line}\" >&3; read -r _ <&3");
    let (tx, rx) = channel();
    let process = HostProcess::spawn(
        std::path::Path::new("/bin/sh"),
        &["-c".into(), script],
        "fds",
        move |message| {
            if let FromHost::Log { message, .. } = message {
                let _ = tx.send(message);
            }
        },
        |_| {},
    )
    .unwrap();
    let listing = rx.recv_timeout(Duration::from_secs(30)).expect("the host's descriptors");
    process.kill();
    // SAFETY: closing the descriptor this test made.
    unsafe { libc::close(leaked) };
    let fds: Vec<i32> = listing.split_whitespace().filter_map(|f| f.parse().ok()).collect();
    for fd in [0, 1, 2, 3] {
        assert!(fds.contains(&fd), "fd {fd} is open in the host: {listing}");
    }
    // macOS: CLOEXEC_DEFAULT keeps even an inheritable descriptor out.
    // Linux runs std's spawn, where descriptors are close-on-exec from
    // birth (pipe2, SOCK_CLOEXEC, MSG_CMSG_CLOEXEC), as `cmux_process`
    // documents, so only one made inheritable on purpose would pass.
    #[cfg(target_vendor = "apple")]
    assert!(!fds.contains(&leaked), "fd {leaked} reached the host: {listing}");
}
