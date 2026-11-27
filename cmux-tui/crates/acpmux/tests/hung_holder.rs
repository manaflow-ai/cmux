//! A daemon that holds its home's lock while its socket accepts nothing is replaced, and starts
//! queued behind it do not pile up (`src/daemon/hung_holder.rs`). A Mac at load 48-86,
//! 2026-11-27: a holder refused its socket for 8 and 29 minutes with 4 and then 13 `daemon run`
//! starts queued behind it; `daemon restart` could not reach it.
//!
//! The holder is a debug daemon told to hang after its bind (`ACPMUX_TEST_HANG_AFTER_BIND`);
//! `ACPMUX_TEST_STALL_MS` shortens the stall bounds so a replace comes in seconds.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, BufReader};

const STALL_MS: &str = "1500";

fn scratch(tag: &str) -> daemon_env::Scratch {
    let dir = daemon_env::Scratch::new(&format!("amx-hh-{tag}"));
    std::fs::write(dir.join("config.json"), "{}").unwrap();
    std::fs::set_permissions(dir.path(), std::os::unix::fs::PermissionsExt::from_mode(0o700))
        .unwrap();
    dir
}

/// The socket the CLI of home `dir` dials.
fn socket(dir: &Path) -> PathBuf {
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let socket = PathBuf::from(cmux_agent_pane_policy::environment::socket_path(None, dir, uid));
    if let Some(parent) = socket.parent().filter(|p| *p != dir) {
        std::fs::create_dir_all(parent).unwrap();
        std::fs::set_permissions(parent, std::os::unix::fs::PermissionsExt::from_mode(0o700))
            .unwrap();
    }
    socket
}

fn daemon(dir: &Path, stall_ms: &str) -> tokio::process::Command {
    let mut cmd = daemon_env::acpmux(dir);
    cmd.args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--log", "info"])
        .args(["--ready-fd", "1"])
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_TEST_STALL_MS", stall_ms)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut cmd = tokio::process::Command::from(cmd);
    cmd.kill_on_drop(true);
    cmd
}

/// The first line of `child`'s stdout that is JSON, or `marker` itself, within `within`.
async fn line(child: &mut tokio::process::Child, marker: Option<&str>, within: Duration) -> Value {
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    tokio::time::timeout(within, async {
        while let Some(line) = lines.next_line().await.unwrap() {
            if marker.is_some_and(|m| line.trim() == m) {
                return Value::String(line);
            }
            if marker.is_none()
                && let Ok(value) = serde_json::from_str::<Value>(&line)
            {
                return value;
            }
        }
        panic!("the daemon exited before the line");
    })
    .await
    .expect("the line in time")
}

/// A holder that took the lock, bound its socket and then accepts nothing.
async fn hung_holder(dir: &Path, mode: &str) -> tokio::process::Child {
    let mut holder =
        daemon(dir, STALL_MS).env("ACPMUX_TEST_HANG_AFTER_BIND", mode).spawn().unwrap();
    line(&mut holder, Some("acpmux-test-hung"), Duration::from_secs(30)).await;
    holder
}

fn status(dir: &Path) -> std::process::Output {
    let mut cmd = daemon_env::acpmux(dir);
    cmd.args(["--json", "daemon", "status"]).env("ACPMUX_HOME", dir).env("ACPMUX_LOGIN_ENV", "0");
    cmd.output().unwrap()
}

fn shutdown(dir: &Path) {
    let mut cmd = daemon_env::acpmux(dir);
    cmd.args(["daemon", "shutdown"]).env("ACPMUX_HOME", dir).env("ACPMUX_LOGIN_ENV", "0");
    let _ = cmd.output();
}

// (a) A second `daemon run` replaces a holder whose socket accepts nothing and serves.
#[tokio::test(flavor = "multi_thread")]
async fn hung_holder_is_replaced_by_the_waiting_start_which_serves() {
    let dir = scratch("a");
    let _ = socket(&dir);
    let mut holder = hung_holder(&dir, "1").await;
    let held_by = holder.id().unwrap();
    let began = Instant::now();
    let mut waiter = daemon(&dir, STALL_MS).spawn().unwrap();
    let ready = line(&mut waiter, None, Duration::from_secs(60)).await;
    assert_eq!(ready["ready"], true, "{ready}");
    assert_eq!(ready["pid"], waiter.id().unwrap(), "the waiter serves itself: {ready}");
    let status = tokio::time::timeout(Duration::from_secs(20), holder.wait())
        .await
        .expect("the hung holder was stopped")
        .unwrap();
    assert!(!status.success(), "the hung holder {held_by} ended by a signal: {status:?}");
    eprintln!("replaced and served in {:?}", began.elapsed());
    let served = self::status(&dir);
    assert!(served.status.success(), "{}", String::from_utf8_lossy(&served.stderr));
    shutdown(&dir);
}

// (b) Of several starts queued behind one holder only one waits; the rest answer and exit 0.
#[tokio::test(flavor = "multi_thread")]
async fn of_several_waiting_starts_only_one_stays() {
    let dir = scratch("b");
    let _ = socket(&dir);
    let mut holder = hung_holder(&dir, "1").await;
    // Bounds far beyond the test: nothing is replaced, so the first waiter keeps waiting.
    let mut first = daemon(&dir, "600000").spawn().unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    while !dir.join("daemon.wait.lock").exists() {
        assert!(Instant::now() < deadline, "the first waiter never stood");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    for _ in 0..4 {
        let child = daemon(&dir, "600000").spawn().unwrap();
        let out = tokio::time::timeout(Duration::from_secs(20), child.wait_with_output())
            .await
            .expect("a second waiter exits at once")
            .unwrap();
        assert!(out.status.success(), "exit 0, no launchd respawn storm: {:?}", out.status);
        let said = String::from_utf8_lossy(&out.stdout)
            .lines()
            .find_map(|l| serde_json::from_str::<Value>(l).ok())
            .expect("a readiness line");
        assert_eq!(said["waiterStands"], true, "{said}");
        assert_eq!(said["waiter"], first.id().unwrap(), "{said}");
    }
    assert!(first.try_wait().unwrap().is_none(), "the first waiter still waits");
    assert!(holder.try_wait().unwrap().is_none(), "nothing was replaced inside the bounds");
}

// (c) `daemon restart` succeeds while the holder's socket accepts nothing.
#[tokio::test(flavor = "multi_thread")]
async fn restart_replaces_a_holder_whose_socket_accepts_nothing() {
    let dir = scratch("c");
    let _ = socket(&dir);
    let mut holder = hung_holder(&dir, "1").await;
    let mut cmd = daemon_env::acpmux(&dir);
    cmd.args(["daemon", "restart"])
        .env("ACPMUX_HOME", dir.path())
        .env("ACPMUX_LOGIN_ENV", "0")
        .env("ACPMUX_TEST_STALL_MS", STALL_MS);
    let mut cmd = tokio::process::Command::from(cmd);
    let out = tokio::time::timeout(Duration::from_secs(90), cmd.output())
        .await
        .expect("restart ends in time")
        .unwrap();
    let said = format!(
        "{:?}\nstdout: {}\nstderr: {}",
        out.status,
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(out.status.success(), "restart: {said}");
    assert!(said.contains("held the lock without answering its socket"), "{said}");
    tokio::time::timeout(Duration::from_secs(20), holder.wait())
        .await
        .expect("the hung holder was stopped")
        .unwrap();
    let served = status(&dir);
    assert!(served.status.success(), "{}", String::from_utf8_lossy(&served.stderr));
    shutdown(&dir);
}

// (d) A holder that answers nothing but keeps making progress (beats) is never killed, on a
// machine whose every core is busy.
#[tokio::test(flavor = "multi_thread")]
async fn slow_but_alive_holder_is_not_replaced_under_load() {
    let dir = scratch("d");
    let _ = socket(&dir);
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let cores = std::thread::available_parallelism().map_or(4, |n| n.get());
    let burners: Vec<_> = (0..cores * 3)
        .map(|_| {
            let stop = stop.clone();
            std::thread::spawn(move || {
                let mut x = 0u64;
                while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                    x = std::hint::black_box(x.wrapping_mul(31).wrapping_add(7));
                }
            })
        })
        .collect();
    let mut holder = hung_holder(&dir, "beat").await;
    let mut waiter = daemon(&dir, STALL_MS).spawn().unwrap();
    // Four stall bounds with no answer: only the holder's beats keep it.
    tokio::time::sleep(Duration::from_millis(4 * 1500 + 2000)).await;
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    for b in burners {
        b.join().unwrap();
    }
    assert!(holder.try_wait().unwrap().is_none(), "a beating holder was killed");
    assert!(waiter.try_wait().unwrap().is_none(), "the waiter gave up on a live holder");
}
