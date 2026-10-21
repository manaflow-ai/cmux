//! A DEV build's daemon stops once its app is gone (`src/daemon/dev_orphan.rs`).
//! Dead DEV apps left their daemons running under launchd forever, about 10%
//! of a core each (23 on one Mac, 2026-10-21). The daemon runs from a fake
//! `cmux DEV` bundle with the debug-only short intervals; NIGHTLY's daemon,
//! and a DEV daemon whose app runs, keep serving.
#![cfg(target_os = "macos")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// The test delay; the daemon looks for its app every [`RECHECK_MS`].
const DELAY_MS: &str = "400";
const RECHECK_MS: &str = "100";
/// Well past the delay: a daemon that should stop has stopped by then.
const STOPS_WITHIN: Duration = Duration::from_secs(20);
/// Many delays long: a daemon that should keep serving is still up.
const KEEPS_FOR: Duration = Duration::from_secs(4);

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// `<dir>/<name>.app` with `bundle_id`, the acpmux under test in
/// `Contents/Resources/bin` and `Contents/MacOS` empty.
fn bundle(dir: &Path, name: &str, bundle_id: &str) -> PathBuf {
    let bundle = dir.join(format!("{name}.app"));
    let bin = bundle.join("Contents/Resources/bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(bundle.join("Contents/MacOS")).unwrap();
    std::fs::write(
        bundle.join("Contents/Info.plist"),
        format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>{bundle_id}</string></dict></plist>
"#
        ),
    )
    .unwrap();
    let acpmux = bin.join("acpmux");
    let source = daemon_env::bin();
    if std::fs::hard_link(source, &acpmux).is_err() {
        std::fs::copy(source, &acpmux).unwrap();
    }
    bundle
}

/// The bundle's acpmux as a daemon on its own home and socket.
fn start_daemon(dir: &Path, bundle: &Path) -> Child {
    let mut cmd = Command::new(bundle.join("Contents/Resources/bin/acpmux"));
    daemon_env::apply(&mut cmd, dir, daemon_env::Agents::Deny, &[]);
    cmd.args(["daemon", "run", "--memory", "--log", "warn"])
        .env("ACPMUX_HOME", dir.join("h"))
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .env("ACPMUX_TEST_DEV_ORPHAN_DELAY_MS", DELAY_MS)
        .env("ACPMUX_TEST_DEV_ORPHAN_RECHECK_MS", RECHECK_MS)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap()
}

/// A stand-in app: a copy of `sleep` in the bundle's `Contents/MacOS`.
fn start_app(bundle: &Path) -> Child {
    let app = bundle.join("Contents/MacOS/cmux DEV");
    std::fs::copy("/bin/sleep", &app).unwrap();
    Command::new(&app).arg("600").stdin(Stdio::null()).spawn().unwrap()
}

/// Waits up to `limit` for `child` to exit; whether it did.
fn exits_within(child: &mut Child, limit: Duration) -> bool {
    let started = Instant::now();
    while started.elapsed() < limit {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success(), "the daemon stopped with {status}");
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

fn stop(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn a_dev_daemon_whose_app_is_gone_stops_itself() {
    let dir = scratch("orph");
    let bundle = bundle(&dir, "cmux DEV orphan-test", "com.cmuxterm.app.debug.orphan.test");
    let mut daemon = start_daemon(&dir, &bundle);
    let stopped = exits_within(&mut daemon, STOPS_WITHIN);
    stop(&mut daemon);
    assert!(stopped, "the DEV daemon kept running with no app for {STOPS_WITHIN:?}");
    assert!(!dir.join("s.sock").exists(), "the orderly shutdown removes the socket");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_dev_daemon_keeps_serving_while_its_app_runs_and_stops_after() {
    let dir = scratch("orpa");
    let bundle = bundle(&dir, "cmux DEV orphan-app", "com.cmuxterm.app.debug.orphan.app");
    let mut app = start_app(&bundle);
    let mut daemon = start_daemon(&dir, &bundle);
    let stopped_early = exits_within(&mut daemon, KEEPS_FOR);
    stop(&mut app);
    let stopped_after = stopped_early || exits_within(&mut daemon, STOPS_WITHIN);
    stop(&mut daemon);
    assert!(!stopped_early, "the DEV daemon stopped while its app ran");
    assert!(stopped_after, "the DEV daemon kept running {STOPS_WITHIN:?} after its app quit");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_nightly_daemon_never_stops_for_a_missing_app() {
    let dir = scratch("orpn");
    let bundle = bundle(&dir, "cmux NIGHTLY", "com.cmuxterm.app.nightly");
    let mut daemon = start_daemon(&dir, &bundle);
    let stopped = exits_within(&mut daemon, KEEPS_FOR);
    stop(&mut daemon);
    assert!(!stopped, "a NIGHTLY daemon stopped without its app");
    let _ = std::fs::remove_dir_all(&dir);
}
