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

/// A supervised host serving listening sockets bound here (as the daemon
/// does), with the provider secret on fd 3; `env` is added to its
/// environment. Returns the child, the agent socket and the listeners (kept
/// open like the daemon keeps them).
#[cfg(unix)]
fn spawn_activated_host(
    dir: &std::path::Path,
    idle_exit_ms: u64,
    env: &[(&str, &std::ffi::OsStr)],
) -> (
    std::process::Child,
    std::path::PathBuf,
    (std::os::unix::net::UnixListener, std::os::unix::net::UnixListener),
) {
    spawn_host(dir, idle_exit_ms, env, None)
}

/// [`spawn_activated_host`], and `stray` (when set) also reaches the host
/// as fd 9 without close-on-exec, as a descriptor that a launcher leaked
/// (a terminal, an SSH session, a CI runner) does.
#[cfg(unix)]
fn spawn_host(
    dir: &std::path::Path,
    idle_exit_ms: u64,
    env: &[(&str, &std::ffi::OsStr)],
    stray: Option<std::os::fd::RawFd>,
) -> (
    std::process::Child,
    std::path::PathBuf,
    (std::os::unix::net::UnixListener, std::os::unix::net::UnixListener),
) {
    use std::io::{BufRead, BufReader, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::net::UnixListener;
    use std::os::unix::process::CommandExt;

    let socket = dir.join("browser-host.sock");
    let agent = UnixListener::bind(&socket).unwrap();
    let provider = UnixListener::bind(dir.join("browser-host-provider.sock")).unwrap();
    let (secret_read, mut secret_write) = std::io::pipe().unwrap();
    secret_write.write_all("s".repeat(64).as_bytes()).unwrap();
    drop(secret_write);
    let fds = [secret_read.as_raw_fd(), agent.as_raw_fd(), provider.as_raw_fd()];
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"));
    command
        .args(["serve", "--supervised", "--provider-secret-fd", "3"])
        .args(["--agent-listen-fd", "4", "--provider-listen-fd", "5", "--idle-exit-ms"])
        .arg(idle_exit_ms.to_string())
        .arg("--socket")
        .arg(&socket)
        .env("CMUX_BROWSER_HOST_SOCKET", &socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    for (key, value) in env {
        command.env(key, value);
    }
    // SAFETY: only fcntl and dup2 between fork and exec.
    unsafe {
        command.pre_exec(move || {
            // Move the sources out of 3..=5 first, then into place, without
            // close-on-exec (as the daemon passes them).
            let mut high = [0; 3];
            for (i, fd) in fds.iter().enumerate() {
                high[i] = libc::fcntl(*fd, libc::F_DUPFD, 10);
                if high[i] < 0 {
                    return Err(std::io::Error::last_os_error());
                }
            }
            let stray = match stray {
                Some(fd) => match libc::fcntl(fd, libc::F_DUPFD, 10) {
                    high if high < 0 => return Err(std::io::Error::last_os_error()),
                    high => Some(high),
                },
                None => None,
            };
            for (i, fd) in high.iter().enumerate() {
                let target = 3 + i as i32;
                if libc::dup2(*fd, target) != target || libc::fcntl(target, libc::F_SETFD, 0) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
            }
            // As the daemon does: nothing else beyond 3..=5 reaches the host.
            for fd in high {
                libc::close(fd);
            }
            if let Some(stray) = stray {
                if libc::dup2(stray, 9) != 9 || libc::fcntl(9, libc::F_SETFD, 0) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                libc::close(stray);
            }
            Ok(())
        });
    }
    let mut child = command.spawn().expect("start the host");
    drop(secret_read);
    let mut line = String::new();
    BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
    assert_eq!(line, "ready\n");
    (child, socket, (agent, provider))
}

/// Socket activation and the idle stop (browser-host.md, step c2
/// follow-up): the host serves listening sockets the daemon bound and keeps
/// (`--agent-listen-fd`, `--provider-listen-fd`), stays while an agent
/// connection is open, and exits with code 0 after `--idle-exit-ms` with
/// nothing to serve. The sockets stay bound by their owner after the exit.
#[cfg(unix)]
#[test]
fn a_supervised_host_serves_inherited_sockets_and_exits_when_idle() {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;
    use std::time::{Duration, Instant};

    let dir = std::env::temp_dir().join(format!("cmux-host-act-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let (mut child, socket, _listeners) = spawn_activated_host(&dir, 300, &[]);

    // An open agent connection keeps the host past the idle delay.
    let mut connection = UnixStream::connect(&socket).unwrap();
    writeln!(connection, r#"{{"id":1,"method":"browser.repl.list","params":{{}}}}"#).unwrap();
    let mut reply = String::new();
    BufReader::new(connection.try_clone().unwrap()).read_line(&mut reply).unwrap();
    assert!(reply.contains(r#""result":[]"#), "the host answers on the inherited socket: {reply}");
    std::thread::sleep(Duration::from_millis(900));
    assert!(child.try_wait().unwrap().is_none(), "a served connection keeps the host");
    drop(connection);

    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "an idle host must exit");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(status.code(), Some(0), "the idle stop exits with code 0");
    assert!(
        UnixStream::connect(&socket).is_ok(),
        "the owner keeps the socket bound after the host's exit (the next connect waits for a new host)"
    );
    drop(child.stdin.take());
    let _ = std::fs::remove_dir_all(&dir);
}

/// The inherited listening sockets close on exec: a browser the host starts
/// (and its children) never holds the provider socket, so a compromised
/// renderer cannot accept the app's provider connection and read the secret.
/// No other inherited socket reaches it either: the host gets a stray socket
/// on fd 9 (a launcher's leak), and the browser must not hold it. The fake
/// Chromium records its open descriptors and exits.
#[cfg(target_os = "linux")]
#[test]
fn a_browser_the_host_starts_holds_none_of_the_inherited_sockets() {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixStream;
    use std::time::{Duration, Instant};

    let dir = std::env::temp_dir().join(format!("cmux-host-cloexec-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let listing = dir.join("chromium-fds");
    let chromium = dir.join("fake-chromium.sh");
    std::fs::write(
        &chromium,
        format!(
            "#!/bin/sh\nfor f in /proc/$$/fd/*; do readlink \"$f\"; done > '{}.tmp'\nmv '{}.tmp' '{}'\nexit 1\n",
            listing.display(),
            listing.display(),
            listing.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&chromium, std::fs::Permissions::from_mode(0o755)).unwrap();
    let (stray, _stray_peer) = UnixStream::pair().unwrap();
    let (mut child, socket, _listeners) = spawn_host(
        &dir,
        60_000,
        &[("CMUX_BROWSER_HOST_CHROMIUM", chromium.as_os_str())],
        Some(std::os::fd::AsRawFd::as_raw_fd(&stray)),
    );
    let request = |line: &str| {
        let mut connection = UnixStream::connect(&socket).unwrap();
        connection.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        writeln!(connection, "{line}").unwrap();
        let mut reply = String::new();
        let _ = BufReader::new(connection).read_line(&mut reply);
        reply
    };
    let _ = request(
        r#"{"id":1,"method":"browser.repl.open","params":{"session":"fds","engine":"headless"}}"#,
    );
    let _ = request(
        r#"{"id":2,"method":"browser.repl.eval","params":{"session":"fds","code":"await tabs.open(); 1"}}"#,
    );
    let deadline = Instant::now() + Duration::from_secs(20);
    while !listing.exists() {
        assert!(Instant::now() < deadline, "the host never started the browser");
        std::thread::sleep(Duration::from_millis(20));
    }
    let fds = std::fs::read_to_string(&listing).unwrap();
    drop(child.stdin.take());
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
    let sockets: Vec<&str> = fds.lines().filter(|target| target.starts_with("socket:")).collect();
    assert!(sockets.is_empty(), "the browser inherited sockets {sockets:?}; all fds: {fds}");
}

/// `serve` takes `--panic-log <path>` (the daemon
/// passes it) and serves; the hook itself is tested in tests/panic_log.rs.
#[cfg(unix)]
#[test]
fn serve_takes_a_panic_log_and_serves() {
    use std::os::unix::net::UnixStream;
    use std::time::{Duration, Instant};

    let dir = std::env::temp_dir().join(format!("cmux-host-panic-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("browser-host.sock");
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"))
        .args(["serve", "--panic-log"])
        .arg(dir.join("browser-host-panics.jsonl"))
        .arg("--socket")
        .arg(&socket)
        .env("CMUX_BROWSER_HOST_SOCKET", &socket)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("start the host");
    let deadline = Instant::now() + Duration::from_secs(10);
    while UnixStream::connect(&socket).is_err() {
        assert!(child.try_wait().unwrap().is_none(), "the host refused --panic-log");
        assert!(Instant::now() < deadline, "the host never listened");
        std::thread::sleep(Duration::from_millis(20));
    }
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
}

/// The stop rule with a real owner app (cmux-owner-liveness): a fake app
/// process connects as the provider, so the host follows that process
/// (the provider socket's peer pid). The app's process keeps the host also
/// with its provider link down, past the idle delay; once the process is
/// gone and nothing uses the host, it exits at once, not after the delay.
#[cfg(unix)]
#[test]
fn owner_liveness_a_host_follows_its_fake_provider_app_and_stops_after_it_is_gone() {
    use std::io::{BufRead, BufReader, Write};
    use std::time::{Duration, Instant};

    fn stop(app: &mut std::process::Child, host: &mut std::process::Child) {
        let _ = app.kill();
        let _ = app.wait();
        let _ = host.kill();
        let _ = host.wait();
    }

    let dir = std::env::temp_dir().join(format!("cmux-host-own-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    // A delay the test never waits out: an exit within it is the owner's.
    let (mut host, _socket, _listeners) = spawn_activated_host(&dir, 120_000, &[]);
    let mut app = Command::new("python3")
        .arg(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_provider.py"))
        .arg(dir.join("browser-host-provider.sock"))
        .arg("s".repeat(64))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("a fake app (python3)");
    let mut said = BufReader::new(app.stdout.take().unwrap());
    let mut line = String::new();
    said.read_line(&mut line).unwrap();
    assert_eq!(line, "acked\n", "the host did not ack the fake app's provider");
    // The app drops its provider link and keeps running.
    writeln!(app.stdin.as_mut().unwrap(), "close").unwrap();
    line.clear();
    said.read_line(&mut line).unwrap();
    assert_eq!(line, "closed\n");
    std::thread::sleep(Duration::from_secs(3));
    if host.try_wait().unwrap().is_some() {
        stop(&mut app, &mut host);
        panic!("the host exited while its app runs (its provider link down)");
    }
    // What an idle host costs while its app runs (the price of the rule).
    let rss = Command::new("ps").args(["-o", "rss=", "-p"]).arg(host.id().to_string()).output();
    let rss = rss.map(|out| String::from_utf8_lossy(&out.stdout).trim().to_owned());
    eprintln!("owner_liveness: idle cmux-browser-host RSS {} KiB", rss.unwrap_or_default());
    // The app is gone: nothing keeps the host.
    let _ = app.kill();
    let _ = app.wait();
    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        if let Some(status) = host.try_wait().unwrap() {
            break Some(status);
        }
        if Instant::now() > deadline {
            break None;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    if status.is_none() {
        stop(&mut app, &mut host);
    }
    let _ = std::fs::remove_dir_all(&dir);
    let status = status.expect("the host ran 10 s after its app was gone, with nothing to serve");
    assert_eq!(status.code(), Some(0), "the stop exits with code 0");
}
