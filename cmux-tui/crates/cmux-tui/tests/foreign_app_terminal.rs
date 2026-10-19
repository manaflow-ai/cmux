//! A `cmux` bundled in one app, run in a terminal of another app (per-build
//! isolation S4, cx-is1kf.5): that terminal's `CMUX_BUNDLE_ID`, `CMUX_TAG`
//! and `CMUX_SOCKET_PATH` name the other app. The CLI acts for its own
//! bundle (its control socket, its Chief home), says so once on stderr with
//! both builds and the fix, and never refuses.
//!
//! Both builds are DEV tags of this test (`s4own`, `s4other`) under a temp
//! `HOME`: no case resolves a real build's names. Nothing here starts a
//! daemon; the one brain is a stand-in that holds the other app's lock.

#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const OWN_BUNDLE: &str = "com.cmuxterm.app.debug.s4own";
const OTHER_BUNDLE: &str = "com.cmuxterm.app.debug.s4other";

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

fn unique_temp_dir(name: &str) -> PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    PathBuf::from("/tmp").join(format!("cmux-s4-{name}-{}-{stamp}-{n}", std::process::id()))
}

fn text_of(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

/// A fake app bundle `dir/Own.app` with bundle id [`OWN_BUNDLE`] and this
/// CLI as its bundled `cmux`.
fn own_bundle_cli(dir: &Path) -> PathBuf {
    let contents = dir.join("Own.app/Contents");
    fs::create_dir_all(contents.join("Resources/bin")).unwrap();
    fs::write(
        contents.join("Info.plist"),
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\
             <key>CFBundleIdentifier</key><string>{OWN_BUNDLE}</string></dict></plist>\n"
        ),
    )
    .unwrap();
    let cli = contents.join("Resources/bin/cmux");
    fs::copy(bin(), &cli).unwrap();
    cli
}

/// `cli <args>` in a terminal of the other app, with what such a terminal
/// carries: the app's `CMUX_BUNDLE_ID`, `CMUX_TAG` and `CMUX_SOCKET_PATH`,
/// its daemon's `CMUX_TUI_SOCKET` (daemon_env.rs), its Chief's
/// `CMUX_CHIEF_HOME` (AppEnvironment.swift) and an agent's `ACPMUX_HOME`,
/// all under `other` (the other app's Chief home is the one under
/// `user_home`); nothing else that could pick an app, daemon or Chief.
fn in_other_apps_terminal(cli: &Path, user_home: &Path, other: &Path, args: &[&str]) -> Output {
    let mut command = Command::new(cli);
    command.args(args).env("LC_ALL", "C").env("HOME", user_home);
    for key in [
        "CMUX_MUX_SOCKET",
        "CMUX_TUI_SESSION",
        "CMUX_APP_DAEMON_SOCKET",
        "CMUX_CHIEF_OWNER_SOCKET",
        "XDG_RUNTIME_DIR",
        "ACPMUX_SOCKET",
        "CMUX_NEXT_CHIEF_HOME",
        "CMUX_NEXT_MUX_HOME",
        "CMUX_NEXT_CHIEF_ROOT",
        "CMUX_NEXT_CHIEF_ACCOUNT",
        "CMUX_NEXT_CHIEF_BUILD_ID",
        "CMUX_NEXT_CHIEF_ISOLATED",
        "CMUX_NEXT_NO_ACTIVATE",
        "CMUX_NEXT_SHOWCASE",
        "CMUX_NEXT_TEST_WINDOW_FRAME",
        "CMUX_NEXT_TEST_WINDOW_SCREEN",
    ] {
        command.env_remove(key);
    }
    command
        .env("CMUX_BUNDLE_ID", OTHER_BUNDLE)
        .env("CMUX_TAG", "s4other")
        .env("CMUX_SOCKET_PATH", other.join("other-app.sock"))
        .env("CMUX_TUI_SOCKET", other.join("other-daemon.sock"))
        .env("CMUX_CHIEF_HOME", user_home.join(".cmux/chief").join(OTHER_BUNDLE))
        .env("ACPMUX_HOME", other.join("other-acpmux"))
        .stdin(Stdio::null())
        .output()
        .unwrap()
}

/// The warning names both builds and the fix.
fn warns_of_both(text: &str) -> bool {
    text.contains("warning") && text.contains(OWN_BUNDLE) && text.contains(OTHER_BUNDLE)
}

/// `cmux identify` (an app command) tries its own app's control socket, not
/// the one the other app's terminal names, and warns.
#[test]
fn a_bundled_cmux_in_another_apps_terminal_reaches_its_own_app() {
    let dir = unique_temp_dir("identify");
    let user_home = dir.join("home");
    fs::create_dir_all(&user_home).unwrap();
    let cli = own_bundle_cli(&dir);
    let output = in_other_apps_terminal(&cli, &user_home, &dir, &["--json", "identify"]);
    let text = text_of(&output);
    let _ = fs::remove_dir_all(&dir);
    assert!(!output.status.success(), "an app answered: {text}");
    assert!(
        !text.contains("other-app.sock") && !text.contains("other-daemon.sock"),
        "the CLI of {OWN_BUNDLE} tried the other app's socket: {text}"
    );
    assert!(
        text.contains("cmux-debug-s4own.sock"),
        "the CLI did not try its own app's socket: {text}"
    );
    assert!(warns_of_both(&text), "no warning naming both builds: {text}");
}

/// A daemon command (`cmux workspace list`) never goes to the other app's
/// daemon (`CMUX_TUI_SOCKET` of its terminal), and warns.
#[test]
fn a_bundled_cmux_in_another_apps_terminal_never_reaches_that_apps_daemon() {
    let dir = unique_temp_dir("daemon");
    let user_home = dir.join("home");
    fs::create_dir_all(&user_home).unwrap();
    let cli = own_bundle_cli(&dir);
    let output = in_other_apps_terminal(&cli, &user_home, &dir, &["--json", "workspace", "list"]);
    let text = text_of(&output);
    let _ = fs::remove_dir_all(&dir);
    assert!(!output.status.success(), "a daemon answered: {text}");
    assert!(
        !text.contains("other-daemon.sock"),
        "the CLI of {OWN_BUNDLE} tried the other app's daemon: {text}"
    );
    assert!(warns_of_both(&text), "no warning naming both builds: {text}");
}

/// A process that holds `lock` as a brain does (`pid`, generation, `flock`)
/// until it gets a signal.
fn stand_in_brain(lock: &Path) -> Child {
    fs::create_dir_all(lock.parent().unwrap()).unwrap();
    let brain = Command::new("python3")
        .arg("-c")
        .arg(
            "import fcntl, os, sys, time\n\
             f = open(sys.argv[1], 'w'); fcntl.flock(f, fcntl.LOCK_EX)\n\
             f.write(f'{os.getpid()}\\n1\\nflock\\n'); f.flush()\n\
             open(sys.argv[1] + '.ready', 'w').close()\n\
             time.sleep(600)\n",
        )
        .arg(lock)
        .spawn()
        .unwrap();
    let ready = lock.with_extension("lock.ready");
    let deadline = Instant::now() + Duration::from_secs(10);
    while !ready.exists() {
        assert!(Instant::now() < deadline, "the stand-in brain never took the lock");
        std::thread::sleep(Duration::from_millis(20));
    }
    brain
}

/// `cmux chief shutdown` stops its own build's Chief, never the Chief of the
/// app whose terminal it runs in (named there by `CMUX_CHIEF_HOME` too).
#[test]
fn a_bundled_cmux_in_another_apps_terminal_never_stops_that_apps_chief() {
    let dir = unique_temp_dir("chief");
    let user_home = dir.join("home");
    let lock = user_home.join(".cmux/chief").join(OTHER_BUNDLE).join("state/host.lock");
    let mut brain = stand_in_brain(&lock);
    let cli = own_bundle_cli(&dir);
    let output = in_other_apps_terminal(&cli, &user_home, &dir, &["chief", "shutdown"]);
    // A shutdown returns once the lock is free; give a wrong one time to end it.
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut status = brain.try_wait().unwrap();
    while status.is_none() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
        status = brain.try_wait().unwrap();
    }
    let _ = brain.kill();
    let _ = brain.wait();
    let _ = fs::remove_dir_all(&dir);
    let text = text_of(&output);
    assert!(status.is_none(), "the CLI of {OWN_BUNDLE} stopped {OTHER_BUNDLE}'s brain: {text}");
    assert!(warns_of_both(&text), "no warning naming both builds: {text}");
}
