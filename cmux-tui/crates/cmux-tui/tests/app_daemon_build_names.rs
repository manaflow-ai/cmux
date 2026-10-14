//! One app daemon session and one control socket per build (per-build
//! isolation S3, cx-is1kf.4): the `cmux` CLI of each build reaches the
//! control socket and the daemon session of its own build
//! (schemas/build-identity/vectors.json `app_daemon`).
//!
//! A build keeps its current names where they belong to exactly one build
//! (NIGHTLY, cmux NEXT, release, RC, staging, a `scripts/reload.sh` DEV
//! build), so no state moves. Every other build (the untagged DEV build, a
//! DEV build tagged with a channel's name, a bundle that ships another tag)
//! gets names of its own build key (`cmux-app--<key hash>`,
//! `/tmp/cmux-<kind>--<key hash>.sock`). The untagged DEV build and release
//! never share a session or a socket again.
//!
//! The CLI learns its build the way it does inside an app's terminal:
//! `CMUX_BUNDLE_ID` and `CMUX_TAG`. Every case runs under a temp `HOME`.

#![cfg(unix)]

use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

fn unique_temp_dir(name: &str) -> PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    PathBuf::from("/tmp").join(format!("cmux-cli-{name}-{}-{stamp}-{n}", std::process::id()))
}

/// The variables that could point the CLI at an app or daemon other than
/// its build's.
const FOREIGN: [&str; 9] = [
    "CMUX_SOCKET_PATH",
    "CMUX_BUNDLE_ID",
    "CMUX_TAG",
    "CMUX_TUI_SOCKET",
    "CMUX_MUX_SOCKET",
    "CMUX_TUI_SESSION",
    "CMUX_CHIEF_HOME",
    "CMUX_NEXT_CHIEF_HOME",
    "XDG_RUNTIME_DIR",
];

/// `cmux <args>` as the CLI inside an app terminal of the build `bundle_id`
/// (shipping `bundled_tag`), for a person whose home directory is `user_home`.
fn cmux_as(
    bundle_id: &str,
    bundled_tag: Option<&str>,
    user_home: &Path,
    args: &[&str],
) -> Output {
    let mut command = Command::new(bin());
    command.args(args).env("LC_ALL", "C").env("HOME", user_home);
    for key in FOREIGN {
        command.env_remove(key);
    }
    command.env("CMUX_BUNDLE_ID", bundle_id);
    if let Some(tag) = bundled_tag {
        command.env("CMUX_TAG", tag);
    }
    command.stdin(Stdio::null()).output().unwrap()
}

fn text_of(output: &Output) -> String {
    format!("{}{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr))
}

fn vectors() -> Value {
    let path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/build-identity/vectors.json");
    serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap()
}

/// A vector path under the vectors' `user_home`, rebased onto `user_home`.
fn rebased(path: &str, vector_home: &str, user_home: &Path) -> PathBuf {
    match path.strip_prefix(vector_home) {
        Some(rest) => user_home.join(rest.trim_start_matches('/')),
        None => PathBuf::from(path),
    }
}

/// Every bundled build of the shared vectors: `cmux identify` (an app
/// command) tries the vector's control socket and no other. No app runs, so
/// the command fails and names the socket it tried. Builds of different keys
/// reach different sockets: the untagged DEV build is not release.
#[test]
fn cmux_reaches_the_control_socket_of_its_own_build() {
    let vectors = vectors();
    let vector_home = vectors["user_home"].as_str().unwrap();
    let user_home = unique_temp_dir("app-daemon-names");
    fs::create_dir_all(&user_home).unwrap();
    let mut wrong = Vec::new();
    let mut reached = std::collections::BTreeMap::<PathBuf, String>::new();
    for case in vectors["cases"].as_array().unwrap() {
        let Some(bundle_id) = case["bundle_id"].as_str() else { continue };
        let key = case["key"].as_str().unwrap();
        let want = case["app_daemon"]["control_socket"].as_str().unwrap();
        let want = rebased(want, vector_home, &user_home);
        let output =
            cmux_as(bundle_id, case["bundled_tag"].as_str(), &user_home, &["--json", "identify"]);
        let text = text_of(&output);
        if output.status.success() || !text.contains(want.to_str().unwrap()) {
            wrong.push(format!("{}: {} (want {})", case["name"], text.trim(), want.display()));
        } else if let Some(other) = reached.insert(want.clone(), key.to_owned())
            && other != key
        {
            wrong.push(format!("{key} and {other} share {}", want.display()));
        }
    }
    let _ = fs::remove_dir_all(&user_home);
    assert!(wrong.is_empty(), "control sockets of the wrong build:\n{}", wrong.join("\n"));
}

/// The app's daemon session (macOS: the app starts it under the Darwin
/// per-user temp directory). `cmux server stop` with no daemon names the
/// socket it tried: for every build that gets names of its own key (the
/// untagged DEV build among them), that is `<session>.sock` of the vector,
/// never release's `cmux-app.sock`. Only key names are tried, which no real
/// app on this host owns.
#[cfg(target_os = "macos")]
#[test]
fn cmux_reaches_the_daemon_session_of_its_own_build() {
    let vectors = vectors();
    let user_home = unique_temp_dir("app-daemon-sessions");
    fs::create_dir_all(&user_home).unwrap();
    let mut wrong = Vec::new();
    for case in vectors["cases"].as_array().unwrap() {
        let Some(bundle_id) = case["bundle_id"].as_str() else { continue };
        let session = case["app_daemon"]["session"].as_str().unwrap();
        if !session.starts_with("cmux-app--") {
            continue;
        }
        let output = cmux_as(
            bundle_id,
            case["bundled_tag"].as_str(),
            &user_home,
            &["--json", "server", "stop"],
        );
        let reply: Value = serde_json::from_slice(&output.stdout).unwrap_or(Value::Null);
        let socket = reply["socket"].as_str().unwrap_or_default();
        let file = Path::new(socket).file_name().and_then(|name| name.to_str());
        if reply["status"] != "not_running" || file != Some(&format!("{session}.sock")) {
            wrong.push(format!("{}: {} (want {session}.sock)", case["name"], text_of(&output)));
        }
    }
    let _ = fs::remove_dir_all(&user_home);
    assert!(wrong.is_empty(), "daemon sessions of the wrong build:\n{}", wrong.join("\n"));
}
