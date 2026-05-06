//! E2E: `cmx server` + `cmx attach` wrap a shell over a Unix socket.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::thread;
use std::time::{Duration, Instant};

use portable_pty::{CommandBuilder, PtySize, native_pty_system};

const SENTINEL: &str = "CMX_M3_OK_7B2F";

#[test]
fn server_plus_attach_wraps_shell() {
    let cmx_bin = env!("CARGO_BIN_EXE_cmx");

    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("server.sock");
    let lib_dir = find_libghostty_dir().expect("locate libghostty-vt build dir");

    // Start the server in a background child. stdout/stderr merged to /dev/null
    // since this test doesn't care about server logs.
    let mut server = std::process::Command::new(cmx_bin)
        .arg("server")
        .arg("--socket")
        .arg(&socket)
        .env("SHELL", "/bin/sh")
        .env("PS1", "$ ")
        .env("TERM", "xterm-256color")
        .env("DYLD_LIBRARY_PATH", &lib_dir)
        .env("LD_LIBRARY_PATH", &lib_dir)
        .env("HOME", dir.path())
        .env("ENV", "/dev/null")
        .current_dir(dir.path())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("spawn cmx server");

    // Wait for the socket to appear.
    let deadline = Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        if Instant::now() > deadline {
            server.kill().ok();
            panic!("server socket did not appear within 5s");
        }
        thread::sleep(Duration::from_millis(50));
    }

    // Launch the client inside a nested PTY so crossterm can latch on.
    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            cols: 80,
            rows: 24,
            pixel_width: 0,
            pixel_height: 0,
        })
        .expect("openpty");

    let mut cmd = CommandBuilder::new(cmx_bin);
    cmd.arg("attach");
    cmd.arg("--socket");
    cmd.arg(&socket);
    cmd.env("TERM", "xterm-256color");
    cmd.env("PS1", "$ ");
    cmd.env("DYLD_LIBRARY_PATH", &lib_dir);
    cmd.env("LD_LIBRARY_PATH", &lib_dir);
    cmd.cwd(dir.path());

    let mut child = pair.slave.spawn_command(cmd).expect("spawn cmx attach");
    drop(pair.slave);

    let mut reader = pair.master.try_clone_reader().expect("clone reader");
    let mut writer = pair.master.take_writer().expect("take writer");

    let out = std::sync::Arc::new(std::sync::Mutex::new(Vec::<u8>::new()));
    let out_clone = out.clone();
    let reader_thread = thread::spawn(move || {
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => out_clone.lock().unwrap().extend_from_slice(&buf[..n]),
            }
        }
    });

    // Give the shell + welcome handshake a moment.
    thread::sleep(Duration::from_millis(400));

    writer
        .write_all(format!("echo {SENTINEL}\n").as_bytes())
        .expect("write echo");
    writer.flush().ok();
    thread::sleep(Duration::from_millis(250));
    writer.write_all(b"exit\n").expect("write exit");
    writer.flush().ok();

    // Client should exit shortly after the shell exits.
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Ok(Some(_)) = child.try_wait() {
            break;
        }
        if Instant::now() > deadline {
            child.kill().ok();
            server.kill().ok();
            panic!("cmx attach did not exit within 10s");
        }
        thread::sleep(Duration::from_millis(50));
    }

    drop(writer);
    drop(pair.master);
    reader_thread.join().ok();

    // Clean up the server.
    server.kill().ok();
    server.wait().ok();

    let output = String::from_utf8_lossy(&out.lock().unwrap()).into_owned();
    assert!(
        output.contains(SENTINEL),
        "expected sentinel in attach output; got:\n{output}"
    );
}

fn find_libghostty_dir() -> Option<PathBuf> {
    let target = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()?
        .parent()?
        .join("target")
        .join("debug")
        .join("build");
    let mut best: Option<PathBuf> = None;
    let mut best_mtime = std::time::SystemTime::UNIX_EPOCH;
    for entry in std::fs::read_dir(&target).ok()? {
        let Ok(entry) = entry else { continue };
        let path = entry.path();
        if !path
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.starts_with("libghostty-vt-sys-"))
        {
            continue;
        }
        let lib = path.join("out").join("ghostty-install").join("lib");
        if !lib.exists() {
            continue;
        }
        let mtime = entry
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
        if mtime >= best_mtime {
            best_mtime = mtime;
            best = Some(lib);
        }
    }
    best
}
