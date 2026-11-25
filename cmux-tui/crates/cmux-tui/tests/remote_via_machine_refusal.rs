//! `cmux remote connect|exec|cp --via-machine M` stops on the first refusal a retry cannot cure
//! and says what to do, and keeps a transient failure visible while it redials. Leo: "we need to
//! finish remote".
//!
//! Before this, a far machine whose owner had not granted control answered every circuit with
//! `consent_required`, and the CLI redialed it silently until it was killed (120 s with an
//! invitation, forever with `--headless` and none). Here a fake acpmux socket stands in for this
//! machine's daemon and answers the `_acpmux/remote.pipe` request as the daemon does today.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const ROUTE: &str = "ws://127.0.0.1:7781/";

/// The reply this machine's acpmux sends today when the far machine refused the circuit for
/// want of the owner's consent: the far reason rides at the end of the message.
const CONSENT_REFUSED: &str = r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"this machine's owner has not granted control from elsewhere (consent_required)","data":{"reason":"machine.unreachable"}}}"#;

/// A failure a redial can cure: the relay or the far slot is not there yet.
const RELAY_DOWN: &str = r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"relay connect failed: the relay did not answer","data":{"reason":"machine.unreachable"}}}"#;

/// Bounds the wait for a command that should have ended; a passing run never waits this long.
const HANG_GUARD: Duration = Duration::from_secs(20);

struct Scratch {
    dir: tempfile::TempDir,
}

impl Scratch {
    fn new() -> Self {
        let dir = tempfile::tempdir_in("/tmp").unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        for name in ["home", "state"] {
            let path = dir.path().join(name);
            fs::create_dir(&path).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        }
        Self { dir }
    }

    fn path(&self, name: &str) -> PathBuf {
        self.dir.path().join(name)
    }

    /// A fresh invitation from a far daemon whose route is [`ROUTE`], as `--invite-file` reads it.
    fn invitation(&self) -> PathBuf {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let uri = runtime.block_on(async {
            let auth =
                cmux_remote::identity::AuthDatabase::load_or_create(self.path("far"), "far", false)
                    .unwrap();
            let invitation =
                auth.create_invitation(Duration::from_secs(600), vec![ROUTE.into()]).await.unwrap();
            let uri = invitation.to_uri().unwrap();
            auth.shutdown().await.unwrap();
            uri
        });
        let file = self.path("invitation");
        fs::write(&file, format!("{uri}\n")).unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        file
    }

    /// A stand-in for this machine's acpmux: each connection reads the pipe request and gets
    /// `reply` (or, with None, no answer at all). Counts the dials.
    fn acpmux(&self, reply: Option<&'static str>) -> (PathBuf, Arc<AtomicUsize>) {
        let socket = self.path("acpmux.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let dials = Arc::new(AtomicUsize::new(0));
        let counted = dials.clone();
        std::thread::spawn(move || {
            let mut held = Vec::new();
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                counted.fetch_add(1, Ordering::AcqRel);
                let mut reader = BufReader::new(stream);
                let mut request = String::new();
                let _ = reader.read_line(&mut request);
                let mut stream = reader.into_inner();
                match reply {
                    Some(reply) => {
                        let _ = stream.write_all(format!("{reply}\n").as_bytes());
                    }
                    None => held.push(stream),
                }
            }
        });
        (socket, dials)
    }

    /// `cmux-tui remote ARGS --state-dir S --via-machine mac --invite-file F TAIL`: the connect
    /// options before `TAIL`, which holds `exec`'s `-- COMMAND`.
    fn command(&self, acpmux: &Path, invitation: &Path, args: &[&str], tail: &[&str]) -> Command {
        let home = self.path("home");
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .arg("remote")
            .args(args)
            .arg("--state-dir")
            .arg(self.path("state"))
            .args(["--via-machine", "mac", "--invite-file"])
            .arg(invitation)
            .args(tail)
            .env("ACPMUX_SOCKET", acpmux)
            .env("HOME", &home)
            .env("XDG_STATE_HOME", home.join("state"))
            .env("XDG_CONFIG_HOME", home.join("config"))
            .env_remove("XDG_RUNTIME_DIR")
            .env("CMUX_TUI_STATE_DIR", self.path("default-state"))
            .env("CMUX_TUI_CONFIG", self.path("config.json"))
            .env_remove("CMUX_REMOTE_STATE_DIR")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        command
    }
}

/// Every stderr line of `child` as it comes, and its whole stdout once it closes.
fn watch(child: &mut Child) -> (mpsc::Receiver<String>, std::thread::JoinHandle<String>) {
    let stderr = child.stderr.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let (lines, received) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            if lines.send(line).is_err() {
                return;
            }
        }
    });
    let stdout = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = std::io::Read::read_to_string(&mut BufReader::new(stdout), &mut text);
        text
    });
    (received, stdout)
}

/// Waits for `child` to exit within [`HANG_GUARD`]; kills it and answers None when it does not.
fn exit_within_guard(child: &mut Child) -> Option<std::process::ExitStatus> {
    let deadline = Instant::now() + HANG_GUARD;
    while Instant::now() < deadline {
        if let Some(status) = child.try_wait().unwrap() {
            return Some(status);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = child.kill();
    let _ = child.wait();
    None
}

/// The far machine refuses for want of its owner's consent: connect, exec and cp each stop after
/// the one dial, exit non-zero, and say what to do there; with `--json` the refusal is a
/// structured line naming the reason.
#[test]
fn a_consent_refusal_stops_connect_exec_and_cp_after_one_dial() {
    let cases: [(&str, &[&str], &[&str], bool); 3] = [
        ("connect", &["connect", ROUTE, "--headless", "--json"], &[], true),
        ("exec", &["exec", ROUTE], &["--", "true"], false),
        ("cp", &["cp", ROUTE, "--json", "remote:/etc/hostname", "/tmp/never-written"], &[], true),
    ];
    for (name, args, tail, json) in cases {
        let scratch = Scratch::new();
        let (acpmux, dials) = scratch.acpmux(Some(CONSENT_REFUSED));
        let invitation = scratch.invitation();
        let started = Instant::now();
        let mut child = scratch.command(&acpmux, &invitation, args, tail).spawn().unwrap();
        let (lines, stdout) = watch(&mut child);
        let status = exit_within_guard(&mut child);
        let took = started.elapsed();
        let stderr: Vec<String> = lines.try_iter().collect();
        let stdout = stdout.join().unwrap();
        let dialed = dials.load(Ordering::Acquire);

        let status = status.unwrap_or_else(|| {
            panic!("{name}: still running after {HANG_GUARD:?}, {dialed} dials; stderr: {stderr:?}")
        });
        assert!(!status.success(), "{name}: exited 0; stderr: {stderr:?}");
        assert_eq!(dialed, 1, "{name}: dialed {dialed} times; stderr: {stderr:?}");
        assert!(took < Duration::from_secs(10), "{name}: took {took:?}");
        let said = stderr.join("\n");
        assert!(
            said.contains("the owner of that machine has not allowed control from elsewhere")
                && said.contains("Settings > Devices"),
            "{name}: stderr does not say what to do: {said}"
        );
        if json {
            let refused = stdout
                .lines()
                .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
                .find(|value| value["event"] == "refused")
                .unwrap_or_else(|| panic!("{name}: no refused event on stdout: {stdout:?}"));
            assert_eq!(refused["reason"], "consent_required", "{name}: {refused}");
            assert_eq!(refused["machine"], "mac", "{name}: {refused}");
            assert!(
                refused["error"].as_str().is_some_and(|e| e.contains("Settings > Devices")),
                "{name}: {refused}"
            );
        }
    }
}

/// A failure a redial can cure keeps the startup redialing, and it says so on stderr: a first
/// line soon, then at most one every few seconds, never silent past about five.
#[test]
fn a_transient_failure_redials_and_says_so_every_few_seconds() {
    let scratch = Scratch::new();
    let (acpmux, dials) = scratch.acpmux(Some(RELAY_DOWN));
    let invitation = scratch.invitation();
    let connect = ["connect", ROUTE, "--headless", "--json"];
    let mut child = scratch.command(&acpmux, &invitation, &connect, &[]).spawn().unwrap();
    let (lines, _stdout) = watch(&mut child);
    let watched = Duration::from_secs(11);
    let started = Instant::now();
    let mut progress = Vec::new();
    while let Some(left) = watched.checked_sub(started.elapsed()) {
        match lines.recv_timeout(left) {
            // The one-time reminder of how to stop rides with a progress line; it is not one.
            Ok(line) if line.contains("Ctrl-C stops waiting") => {}
            Ok(line) if line.starts_with("remote connect:") => {
                progress.push((started.elapsed(), line));
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    let exited = child.try_wait().unwrap();
    let _ = child.kill();
    let _ = child.wait();
    let dialed = dials.load(Ordering::Acquire);

    assert!(exited.is_none(), "a transient failure ended the command: {exited:?}; {progress:?}");
    assert!(dialed >= 2, "dialed {dialed} times in {watched:?}; {progress:?}");
    let first = progress.first().unwrap_or_else(|| panic!("silent for {watched:?}"));
    assert!(first.0 < Duration::from_secs(6), "first progress line at {:?}", first.0);
    assert!(
        progress.iter().any(|(_, line)| line.contains("the relay did not answer")),
        "no progress line names the failure: {progress:?}"
    );
    for pair in progress.windows(2) {
        let gap = pair[1].0 - pair[0].0;
        assert!(gap < Duration::from_secs(6), "silent for {gap:?}: {progress:?}");
        assert!(gap > Duration::from_secs(2), "progress lines {gap:?} apart: {progress:?}");
    }
}

/// A first dial that never answers is not silent either: a line says it is still connecting.
#[test]
fn a_stalled_first_dial_says_it_is_still_connecting() {
    let scratch = Scratch::new();
    let (acpmux, _dials) = scratch.acpmux(None);
    let invitation = scratch.invitation();
    let connect = ["connect", ROUTE, "--headless", "--json"];
    let mut child = scratch.command(&acpmux, &invitation, &connect, &[]).spawn().unwrap();
    let (lines, _stdout) = watch(&mut child);
    let deadline = Instant::now() + Duration::from_secs(7);
    let mut seen = Vec::new();
    let found = loop {
        let left = deadline.saturating_duration_since(Instant::now());
        match lines.recv_timeout(left) {
            Ok(line) if line.contains("still connecting") => break true,
            Ok(line) => seen.push(line),
            Err(_) => break false,
        }
    };
    let _ = child.kill();
    let _ = child.wait();
    assert!(found, "no `still connecting` line within 7 s; stderr: {seen:?}");
}
