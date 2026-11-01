//! A daemon stops once its cmux app is gone (`src/daemon/app_orphan.rs`).
//! Dead DEV apps left their daemons running under launchd forever, about 10%
//! of a core each (23 on one Mac, 2026-10-21), and so did deleted NIGHTLY and
//! Release apps. The daemon runs from a fake cmux bundle with the debug-only
//! short intervals and the app's control socket (`CMUX_SOCKET_PATH`) stood in
//! for by a listener. A DEV daemon stops when its app quits or its binary is
//! gone; a NIGHTLY or Release one only when its binary is gone. A daemon whose
//! app answers or only quit (NIGHTLY), and any daemon off macOS, keep serving.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use std::io::{BufRead, BufReader};
#[cfg(target_os = "macos")]
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
#[cfg(target_os = "macos")]
use std::sync::Arc;
#[cfg(target_os = "macos")]
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

/// The test delay; the daemon looks for its app every [`RECHECK_MS`].
const DELAY_MS: &str = "400";
const RECHECK_MS: &str = "100";
/// Well past the delay: a daemon that should stop has stopped by then.
#[cfg(target_os = "macos")]
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

/// `<dir>/<name>.app` with `bundle_id` and the acpmux under test in
/// `Contents/Resources/bin`.
fn bundle(dir: &Path, name: &str, bundle_id: &str) -> PathBuf {
    let bundle = dir.join(format!("{name}.app"));
    let bin = bundle.join("Contents/Resources/bin");
    std::fs::create_dir_all(&bin).unwrap();
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
    // A copy, never a hard link: a deleted bundle must leave its binary with no name.
    let source = daemon_env::bin();
    std::fs::copy(source, &acpmux).unwrap();
    bundle
}

/// The app's control socket, as the app names it in the daemon's environment.
fn app_socket(dir: &Path) -> PathBuf {
    dir.join("app.sock")
}

/// The bundle's acpmux as a daemon on its own home and socket, once it is
/// ready (it has read its bundle by then).
fn start_daemon(dir: &Path, bundle: &Path) -> Child {
    let mut cmd = Command::new(bundle.join("Contents/Resources/bin/acpmux"));
    daemon_env::apply(&mut cmd, dir, daemon_env::Agents::Deny, &[]);
    let mut child = cmd
        .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", dir.join("h"))
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .env("CMUX_SOCKET_PATH", app_socket(dir))
        .env("ACPMUX_TEST_APP_ORPHAN_DELAY_MS", DELAY_MS)
        .env("ACPMUX_TEST_APP_ORPHAN_RECHECK_MS", RECHECK_MS)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let ready = BufReader::new(stdout)
        .lines()
        .map_while(Result::ok)
        .any(|line| line.contains("\"ready\":true"));
    assert!(ready, "the daemon exited without a readiness line");
    child
}

/// A stand-in app: a listener on the app's control socket that accepts every
/// connect and closes it, as the app does with a client that sends nothing.
/// Accepting matters: connects left in the backlog would fill it (128, one
/// per recheck) and start failing, so a daemon could stop on a refusing socket
/// while the test means the app to be answering. Dropping it stops accepting
/// and closes the listener; the socket file stays, as after a real quit.
#[cfg(target_os = "macos")]
struct App {
    stop: Arc<AtomicBool>,
    accepted: Arc<AtomicUsize>,
    thread: Option<std::thread::JoinHandle<()>>,
}

#[cfg(target_os = "macos")]
impl App {
    /// Connects the app accepted so far.
    fn accepted(&self) -> usize {
        self.accepted.load(Ordering::SeqCst)
    }
}

#[cfg(target_os = "macos")]
impl Drop for App {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

#[cfg(target_os = "macos")]
fn start_app(dir: &Path) -> App {
    let listener = UnixListener::bind(app_socket(dir)).unwrap();
    listener.set_nonblocking(true).unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let accepted = Arc::new(AtomicUsize::new(0));
    let thread = {
        let (stop, accepted) = (Arc::clone(&stop), Arc::clone(&accepted));
        std::thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        drop(stream);
                        accepted.fetch_add(1, Ordering::SeqCst);
                    }
                    Err(_) => std::thread::sleep(Duration::from_millis(5)),
                }
            }
        })
    };
    App { stop, accepted, thread: Some(thread) }
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

#[cfg(target_os = "macos")]
#[test]
fn app_orphan_exit_stops_a_dev_daemon_after_its_app_quits() {
    let dir = scratch("orpa");
    let bundle = bundle(&dir, "cmux DEV orphan-app", "com.cmuxterm.app.debug.orphan.app");
    let app = start_app(&dir);
    let mut daemon = start_daemon(&dir, &bundle);
    let stopped_early = exits_within(&mut daemon, KEEPS_FOR);
    // The app quits: its socket file stays, nobody listens on it.
    drop(app);
    let stopped_after = stopped_early || exits_within(&mut daemon, STOPS_WITHIN);
    stop(&mut daemon);
    assert!(!stopped_early, "the DEV daemon stopped while its app ran");
    assert!(stopped_after, "the DEV daemon kept running {STOPS_WITHIN:?} after its app quit");
    assert!(!dir.join("s.sock").exists(), "the orderly shutdown removes the socket");
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(target_os = "macos")]
#[test]
fn app_orphan_exit_stops_a_dev_daemon_whose_bundle_is_deleted() {
    let dir = scratch("orph");
    let bundle = bundle(&dir, "cmux DEV orphan-test", "com.cmuxterm.app.debug.orphan.test");
    let mut daemon = start_daemon(&dir, &bundle);
    // A script deletes the tag bundle; the app was never reachable.
    std::fs::remove_dir_all(&bundle).unwrap();
    let stopped = exits_within(&mut daemon, STOPS_WITHIN);
    stop(&mut daemon);
    assert!(stopped, "the DEV daemon kept running {STOPS_WITHIN:?} after its bundle was deleted");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A rebuild replaced this build's binary while an app (a same-tag DEV built
/// elsewhere) still listens on the socket: the old daemon stops anyway.
#[cfg(target_os = "macos")]
#[test]
fn app_orphan_exit_stops_a_dev_daemon_whose_binary_is_replaced() {
    let dir = scratch("orpr");
    let bundle = bundle(&dir, "cmux DEV orphan-rebuilt", "com.cmuxterm.app.debug.orphan.rebuilt");
    let app = start_app(&dir);
    let mut daemon = start_daemon(&dir, &bundle);
    let acpmux = bundle.join("Contents/Resources/bin/acpmux");
    let next = bundle.join("Contents/Resources/bin/acpmux.next");
    // A new file at the same path: a fresh inode, as a rebuild writes it
    // (the build scripts remove a binary before they copy its successor in).
    std::fs::copy(&acpmux, &next).unwrap();
    std::fs::rename(&next, &acpmux).unwrap();
    let stopped = exits_within(&mut daemon, STOPS_WITHIN);
    stop(&mut daemon);
    // The app answered all along: the daemon's tries were accepted, and the
    // socket still takes a connect after the daemon stopped. A daemon that
    // only watched the socket would have had no reason to stop.
    let accepted = app.accepted();
    let answers = UnixStream::connect(app_socket(&dir)).is_ok();
    drop(app);
    assert!(stopped, "the DEV daemon kept running {STOPS_WITHIN:?} after its binary was replaced");
    assert!(accepted > 0, "the app never accepted the daemon's tries");
    assert!(answers, "the app's socket stopped answering");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Socket control off: the app runs but never listens. The daemon keeps it.
#[cfg(target_os = "macos")]
#[test]
fn app_orphan_exit_keeps_a_dev_daemon_whose_app_never_listens() {
    let dir = scratch("orpq");
    let bundle = bundle(&dir, "cmux DEV orphan-quiet", "com.cmuxterm.app.debug.orphan.quiet");
    let mut daemon = start_daemon(&dir, &bundle);
    let stopped = exits_within(&mut daemon, KEEPS_FOR);
    stop(&mut daemon);
    assert!(!stopped, "the DEV daemon stopped for an app that never listened");
    let _ = std::fs::remove_dir_all(&dir);
}

/// NIGHTLY's app quits: its daemon keeps serving (remote peers and phones
/// still reach its sessions), even with the socket refusing.
#[cfg(target_os = "macos")]
#[test]
fn app_orphan_exit_keeps_a_nightly_daemon_after_its_app_quits() {
    let dir = scratch("orpn");
    let bundle = bundle(&dir, "cmux NIGHTLY", "com.cmuxterm.app.nightly");
    let app = start_app(&dir);
    let mut daemon = start_daemon(&dir, &bundle);
    let stopped_early = exits_within(&mut daemon, KEEPS_FOR);
    drop(app);
    let stopped_after = stopped_early || exits_within(&mut daemon, KEEPS_FOR);
    stop(&mut daemon);
    assert!(!stopped_after, "a NIGHTLY daemon stopped because its app quit");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The person deletes NIGHTLY (or moves to another channel and deletes it).
#[cfg(target_os = "macos")]
#[test]
fn app_orphan_exit_stops_a_nightly_daemon_whose_bundle_is_deleted() {
    let dir = scratch("orpd");
    let bundle = bundle(&dir, "cmux NIGHTLY", "com.cmuxterm.app.nightly");
    let mut daemon = start_daemon(&dir, &bundle);
    std::fs::remove_dir_all(&bundle).unwrap();
    let stopped = exits_within(&mut daemon, STOPS_WITHIN);
    stop(&mut daemon);
    assert!(stopped, "the NIGHTLY daemon kept running {STOPS_WITHIN:?} after its app was deleted");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A Release update replaced the binary and the app was not opened since.
#[cfg(target_os = "macos")]
#[test]
fn app_orphan_exit_stops_a_release_daemon_whose_binary_is_replaced() {
    let dir = scratch("orpu");
    let bundle = bundle(&dir, "cmux", "com.cmuxterm.app");
    let mut daemon = start_daemon(&dir, &bundle);
    let acpmux = bundle.join("Contents/Resources/bin/acpmux");
    let next = bundle.join("Contents/Resources/bin/acpmux.next");
    std::fs::copy(&acpmux, &next).unwrap();
    std::fs::rename(&next, &acpmux).unwrap();
    let stopped = exits_within(&mut daemon, STOPS_WITHIN);
    stop(&mut daemon);
    assert!(
        stopped,
        "the Release daemon kept running {STOPS_WITHIN:?} after an update replaced it"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// An unchanged NIGHTLY build keeps its daemon, with or without its app.
#[test]
fn app_orphan_exit_keeps_a_nightly_daemon_whose_binary_stays() {
    let dir = scratch("orpk");
    let bundle = bundle(&dir, "cmux NIGHTLY", "com.cmuxterm.app.nightly");
    let mut daemon = start_daemon(&dir, &bundle);
    let stopped = exits_within(&mut daemon, KEEPS_FOR);
    stop(&mut daemon);
    assert!(!stopped, "a NIGHTLY daemon stopped with its binary in place");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Not a cmux bundle: no watch, even when its binary is deleted.
#[test]
fn app_orphan_exit_never_stops_a_daemon_outside_a_cmux_bundle() {
    let dir = scratch("orpo");
    let bundle = bundle(&dir, "Other", "com.example.other");
    let mut daemon = start_daemon(&dir, &bundle);
    std::fs::remove_dir_all(&bundle).unwrap();
    let stopped = exits_within(&mut daemon, KEEPS_FOR);
    stop(&mut daemon);
    assert!(!stopped, "a daemon outside a cmux bundle stopped");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The watcher runs on macOS only; elsewhere it never starts.
#[cfg(not(target_os = "macos"))]
#[test]
fn app_orphan_exit_never_stops_a_daemon_off_macos() {
    let dir = scratch("orpl");
    let bundle = bundle(&dir, "cmux DEV orphan-linux", "com.cmuxterm.app.debug.orphan.linux");
    let mut daemon = start_daemon(&dir, &bundle);
    let stopped = exits_within(&mut daemon, KEEPS_FOR);
    stop(&mut daemon);
    assert!(!stopped, "a daemon off macOS stopped for a missing app");
    let _ = std::fs::remove_dir_all(&dir);
}
