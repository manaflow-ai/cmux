//! The host binary's command line. One MCP entry point (decision
//! BROWSER-MCP-ENTRY, 2026-10-04): `cmux mcp serve`, which cmux.json turns
//! on; the host binary has no MCP server of its own.

use std::process::{Command, Stdio};

#[test]
fn the_host_binary_refuses_mcp_and_names_cmux_mcp_serve() {
    let dir = std::env::temp_dir().join(format!("cmux-host-cli-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"))
        .arg("mcp")
        .env("CMUX_BROWSER_HOST_SOCKET", dir.join("host.sock"))
        .stdin(Stdio::null())
        .output()
        .expect("run cmux-browser-host mcp");
    let _ = std::fs::remove_dir_all(&dir);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(2), "stderr: {stderr}");
    assert!(stderr.contains("cmux mcp serve"), "stderr: {stderr}");
    assert!(out.stdout.is_empty(), "no MCP traffic: {}", String::from_utf8_lossy(&out.stdout));
}

/// `serve --supervised` (the daemon's host, browser-host.md step c2): the
/// host prints `ready` once the agent and the provider sockets listen, takes
/// the provider secret from an inherited fd, and exits when stdin ends, so no
/// host outlives the daemon that started it.
#[cfg(unix)]
#[test]
fn a_supervised_host_says_ready_after_both_sockets_listen_and_stops_at_the_end_of_stdin() {
    use std::io::{BufRead, BufReader, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::net::UnixStream;
    use std::os::unix::process::CommandExt;
    use std::time::{Duration, Instant};

    let dir = std::env::temp_dir().join(format!("cmux-host-sup-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("browser-host.sock");
    let (secret_read, mut secret_write) = std::io::pipe().unwrap();
    secret_write.write_all("s".repeat(64).as_bytes()).unwrap();
    drop(secret_write);
    let fd = secret_read.as_raw_fd();
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"));
    command
        .args(["serve", "--provider-secret-fd", "3", "--supervised", "--socket"])
        .arg(&socket)
        .env("CMUX_BROWSER_HOST_SOCKET", &socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    // SAFETY: only dup2 and fcntl between fork and exec.
    unsafe {
        command.pre_exec(move || {
            if libc::dup2(fd, 3) != 3 || libc::fcntl(3, libc::F_SETFD, 0) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command.spawn().expect("start the host");
    drop(secret_read);
    let mut line = String::new();
    BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
    assert_eq!(line, "ready\n");
    assert!(UnixStream::connect(&socket).is_ok(), "the agent socket listens at ready");
    assert!(
        UnixStream::connect(dir.join("browser-host-provider.sock")).is_ok(),
        "the provider socket listens at ready"
    );
    drop(child.stdin.take());
    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "the host must stop when stdin ends");
        std::thread::sleep(Duration::from_millis(20));
    };
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(status.code(), Some(0));
}

/// On a socket the cmux daemon owns (its terminals name it in
/// `CMUX_BROWSER_HOST_SOCKET` beside `CMUX_TUI_SOCKET`), a client never
/// starts a host of its own: that host would take the socket the daemon's
/// host (with the app's provider secret) needs. It fails after its wait.
#[cfg(unix)]
#[test]
fn a_client_never_starts_its_own_host_on_the_daemons_socket() {
    use std::os::unix::net::UnixStream;
    let dir = std::env::temp_dir().join(format!("cmux-host-owned-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("browser-host.sock");
    let out = Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"))
        .args(["list", "--socket"])
        .arg(&socket)
        .env("CMUX_BROWSER_HOST_SOCKET", &socket)
        .env("CMUX_TUI_SOCKET", dir.join("daemon.sock"))
        .stdin(Stdio::null())
        .output()
        .expect("run cmux-browser-host list");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_ne!(out.status.code(), Some(0), "stderr: {stderr}");
    assert!(stderr.contains("the cmux daemon's browser host does not answer"), "{stderr}");
    assert!(UnixStream::connect(&socket).is_err(), "no host was started on the daemon's socket");
    let _ = std::fs::remove_dir_all(&dir);
}
