//! Two ways a CLI command missed the app it could have reached.
//!
//! 2026-11-22, on a Mac reached over ssh: plain `cmux version` said "no app answered" while
//! `cmux --app-socket ~/.local/state/cmux/cmux-nightly.sock version` worked. A `cmux` outside
//! every app bundle, with no app named in its environment, now uses the one cmux NIGHTLY socket
//! that answers, and says so on stderr.
//!
//! The same day `cmux live status` printed the cmux Live setting as "unknown (... did not answer)"
//! even with `--app-socket`: its script asked the `cmux` on `PATH`, with no socket. The CLI now
//! reads the setting from the app it was pointed at and hands it to the script.
// Unix sockets only (UnixListener); Windows has no such listener.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// A new folder for one run (short: a socket path must fit `sun_path`).
fn temp_dir(name: &str) -> PathBuf {
    static RUNS: AtomicUsize = AtomicUsize::new(0);
    let run = RUNS.fetch_add(1, Ordering::Relaxed);
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let dir = Path::new("/tmp").join(format!("cmux-{name}-{}-{stamp}-{run}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// An app at `socket` that answers `settings.get` with `{"value": value}` and every other
/// request with an empty success, from a thread.
fn serve_app(socket: &Path, value: Value) {
    std::fs::create_dir_all(socket.parent().unwrap()).unwrap();
    let listener = UnixListener::bind(socket).unwrap();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let value = value.clone();
            std::thread::spawn(move || {
                let mut writer = stream.try_clone().unwrap();
                for line in BufReader::new(stream).lines() {
                    let Ok(line) = line else { return };
                    let request: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
                    let result = if request["method"] == "settings.get" {
                        json!({ "path": request["params"]["path"], "value": value })
                    } else {
                        json!({ "pong": true })
                    };
                    let answer = json!({ "id": request["id"], "ok": true, "result": result });
                    if writeln!(writer, "{answer}").is_err() {
                        return;
                    }
                }
            });
        }
    });
}

/// `cmux <args>` with `home` as `HOME` and no app named in the environment (an ssh shell).
fn cmux(home: &Path, args: &[&str]) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command.args(args).env("HOME", home).env("LC_ALL", "C").env("LANG", "C");
    for key in [
        "CMUX_SOCKET_PATH",
        "CMUX_BUNDLE_ID",
        "CMUX_TAG",
        "CMUX_TUI_SOCKET",
        "CMUX_MUX_SOCKET",
        "CMUX_TUI_TERMINAL_ID",
        "CMUX_AGENT_SESSION",
        "CMUX_SOCKET",
    ] {
        command.env_remove(key);
    }
    command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    command.output().unwrap()
}

/// Whether a NIGHTLY of this host answers at its old shared `/tmp` path, which a test `HOME`
/// does not move: then two sockets answer and the fallback rightly picks none.
fn host_nightly_answers() -> bool {
    UnixStream::connect("/tmp/cmux-nightly.sock").is_ok()
}

#[test]
fn with_no_app_named_the_one_answering_nightly_is_used_and_said() {
    if host_nightly_answers() {
        eprintln!("skipped: this host's cmux NIGHTLY answers at /tmp/cmux-nightly.sock");
        return;
    }
    let home = temp_dir("nfb");
    let socket = home.join(".local/state/cmux/cmux-nightly.sock");
    serve_app(&socket, json!(true));
    // Bare `settings get` is the app's (`settings get PATH` is the daemon's v2 owner, cli.rs
    // `daemon_settings_scope`), so it reaches the app socket the CLI picked.
    let output = cmux(&home, &["--json", "settings", "get"]);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(0), "stdout: {stdout}\nstderr: {stderr}");
    assert!(stdout.contains("true"), "{stdout}");
    assert!(stderr.contains("cmux NIGHTLY"), "{stderr}");
    assert!(stderr.contains(&socket.display().to_string()), "{stderr}");
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn with_no_app_named_and_no_nightly_answering_nothing_is_used() {
    if host_nightly_answers() {
        eprintln!("skipped: this host's cmux NIGHTLY answers at /tmp/cmux-nightly.sock");
        return;
    }
    let home = temp_dir("nfn");
    // A socket file an app left behind when it quit: nothing answers there.
    let socket = home.join(".local/state/cmux/cmux-nightly.sock");
    std::fs::create_dir_all(socket.parent().unwrap()).unwrap();
    drop(UnixListener::bind(&socket).unwrap());
    // Bare `settings get` is the app's (`settings get PATH` is the daemon's v2 owner, cli.rs
    // `daemon_settings_scope`), so it reaches the app socket the CLI picked.
    let output = cmux(&home, &["--json", "settings", "get"]);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_ne!(output.status.code(), Some(0), "{stderr}");
    assert!(!stderr.contains("cmux NIGHTLY"), "{stderr}");
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn live_status_reads_the_setting_from_the_app_socket_it_was_given() {
    let home = temp_dir("lst");
    let socket = home.join("app.sock");
    serve_app(&socket, json!(false));
    // A checkout whose web script prints what the CLI handed it.
    let tree = home.join("tree");
    let script = tree.join("scripts/cmux-next/web-overlay.sh");
    std::fs::create_dir_all(script.parent().unwrap()).unwrap();
    std::fs::write(&script, "echo \"setting=${CMUX_LIVE_WEB_RELOAD:-unset} args=$*\"\n").unwrap();
    let tree_arg = tree.display().to_string();
    let socket_arg = socket.display().to_string();
    let output =
        cmux(&home, &["--app-socket", &socket_arg, "live", "status", "--worktree", &tree_arg]);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(0), "stdout: {stdout}\nstderr: {stderr}");
    assert!(stdout.contains("setting=false args=status"), "stdout: {stdout}\nstderr: {stderr}");

    // No app at the socket: the script hears `unknown`, never a guess of its own.
    let gone = home.join("gone.sock").display().to_string();
    let output = cmux(&home, &["--app-socket", &gone, "live", "status", "--worktree", &tree_arg]);
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("setting=unknown"), "{stdout}");
    let _ = std::fs::remove_dir_all(&home);
}
