//! One acpmux home per build (per-build isolation S2, cx-is1kf.3): the
//! `cmux acp` CLI inside each app resolves the acpmux home of its own build
//! (schemas/build-identity/vectors.json `acpmux_home`), and a stop through the
//! CLI of one build never reaches the daemon of another. NIGHTLY
//! (`com.cmuxterm.app.nightly`) keeps `~/.acpmux` in place; every other build,
//! the untagged DEV build included, has `~/.acpmux/builds/<key>`.
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

fn assert_success(output: &Output) {
    assert!(
        output.status.success(),
        "expected success, got status {:?}\nstdout:\n{}\nstderr:\n{}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

/// The variables that could point the CLI at a home other than its build's.
const FOREIGN: [&str; 6] = [
    "ACPMUX_HOME",
    "ACPMUX_SOCKET",
    "CMUX_SOCKET_PATH",
    "CMUX_BUNDLE_ID",
    "CMUX_TAG",
    "CMUX_TUI_SOCKET",
];

/// `cmux acp <args>` as the CLI inside the build `bundle_id` (shipping
/// `bundled_tag`), for a person whose home directory is `user_home`.
fn acp_as(
    bundle_id: Option<&str>,
    bundled_tag: Option<&str>,
    user_home: &Path,
    args: &[&str],
) -> Output {
    let mut command = Command::new(bin());
    command.arg("acp").args(args).env("LC_ALL", "C").env("HOME", user_home);
    for key in FOREIGN {
        command.env_remove(key);
    }
    if let Some(bundle_id) = bundle_id {
        command.env("CMUX_BUNDLE_ID", bundle_id);
        if let Some(tag) = bundled_tag {
            command.env("CMUX_TAG", tag);
        }
    }
    command.stdin(Stdio::null()).output().unwrap()
}

fn json_of(output: &Output) -> Value {
    assert_success(output);
    serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
        panic!("not JSON ({error}): {}", String::from_utf8_lossy(&output.stdout))
    })
}

fn vectors() -> Value {
    let path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/build-identity/vectors.json");
    serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap()
}

/// Every build of the shared vectors: `cmux acp` uses the vector's acpmux
/// home, rebased onto this run's home directory.
#[test]
fn cmux_acp_uses_the_acpmux_home_of_its_own_build() {
    let vectors = vectors();
    let vector_home = vectors["user_home"].as_str().unwrap();
    let user_home = unique_temp_dir("acpmux-build-homes");
    fs::create_dir_all(&user_home).unwrap();
    let mut wrong = Vec::new();
    for case in vectors["cases"].as_array().unwrap() {
        let bundle_id = case["bundle_id"].as_str();
        // Outside any bundle no tag is shipped: the CLI sees none.
        let bundled_tag = bundle_id.and(case["bundled_tag"].as_str());
        let want = case["acpmux_home"].as_str().unwrap();
        let want = user_home.join(want.strip_prefix(vector_home).unwrap().trim_start_matches('/'));
        let config = json_of(&acp_as(bundle_id, bundled_tag, &user_home, &["config", "--json"]));
        let got = PathBuf::from(config["home"].as_str().unwrap_or_default());
        if got != want {
            wrong.push(format!("{}: {} (want {})", case["name"], got.display(), want.display()));
        }
    }
    // A terminal that sets only `CMUX_TAG` names that tag's DEV build
    // (`scripts/reload.sh`: tag `foo-bar` is `com.cmuxterm.app.debug.foo.bar`),
    // never NIGHTLY's shared home.
    let mut tag_only = Command::new(bin());
    tag_only.args(["acp", "config", "--json"]).env("LC_ALL", "C").env("HOME", &user_home);
    for key in FOREIGN {
        tag_only.env_remove(key);
    }
    let config =
        json_of(&tag_only.env("CMUX_TAG", "foo-bar").stdin(Stdio::null()).output().unwrap());
    let want = user_home.join(".acpmux/builds/com.cmuxterm.app.debug.foo.bar");
    if config["home"].as_str() != Some(want.to_str().unwrap()) {
        wrong.push(format!("CMUX_TAG=foo-bar only: {} (want {})", config["home"], want.display()));
    }
    let _ = fs::remove_dir_all(&user_home);
    assert!(wrong.is_empty(), "acpmux homes of the wrong build:\n{}", wrong.join("\n"));
}

/// Stops the acpmux daemons of `bundles` under `user_home` when dropped, so a
/// failed assertion never leaves one running.
struct StopDaemons<'a> {
    user_home: &'a Path,
    bundles: [&'static str; 2],
}

impl Drop for StopDaemons<'_> {
    fn drop(&mut self) {
        for bundle in self.bundles {
            let _ =
                acp_as(Some(bundle), None, self.user_home, &["daemon", "shutdown", "--end-agents"]);
        }
    }
}

/// NIGHTLY and the untagged DEV build run acpmux daemons at the same time:
/// two processes, two sockets, each in its own build's home. Stopping the
/// DEV build's daemon through its CLI leaves NIGHTLY's running. NIGHTLY's
/// config (harness and model defaults) keeps every setting, and the DEV
/// build's new home neither copies nor links anything of NIGHTLY's home.
#[test]
fn stopping_one_builds_acpmux_leaves_nightlys_running() {
    const NIGHTLY: &str = "com.cmuxterm.app.nightly";
    const DEV: &str = "com.cmuxterm.app.debug";
    let user_home = unique_temp_dir("acpmux-build-stop");
    // NIGHTLY's ~/.acpmux under the temp home: an ephemeral port, never the
    // shared home's fixed one (this host may run a real acpmux).
    let nightly_home = user_home.join(".acpmux");
    fs::create_dir_all(&nightly_home).unwrap();
    fs::write(
        nightly_home.join("config.json"),
        r#"{"defaultHarness": "codex", "webAskingModes": {"codex": ["nightly-own-mode"]},
            "websocket": {"listen": "127.0.0.1:0", "token": "acpmux-build-homes-test"}}"#,
    )
    .unwrap();
    let nightly_config = || -> Value {
        serde_json::from_str(&fs::read_to_string(nightly_home.join("config.json")).unwrap())
            .unwrap()
    };
    let before = nightly_config();
    let guard = StopDaemons { user_home: &user_home, bundles: [DEV, NIGHTLY] };
    let shutdown = |bundle: &str| acp_as(Some(bundle), None, &user_home, &["daemon", "shutdown"]);
    let nightly = json_of(&acp_as(Some(NIGHTLY), None, &user_home, &["daemon", "start", "--json"]));
    let dev = json_of(&acp_as(Some(DEV), None, &user_home, &["daemon", "start", "--json"]));
    let pid = |status: &Value| status["pid"].as_u64().unwrap_or(0) as i32;
    // SAFETY: kill with signal 0 only checks that the process exists.
    let running = |pid: i32| pid > 0 && unsafe { libc::kill(pid, 0) } == 0;
    let homes =
        (nightly["home"].as_str().map(PathBuf::from), dev["home"].as_str().map(PathBuf::from));
    let sockets =
        (nightly["socket"].as_str().map(str::to_owned), dev["socket"].as_str().map(str::to_owned));
    let stop_dev = shutdown(DEV);
    let nightly_after = running(pid(&nightly));
    drop(guard);
    let after = nightly_config();
    // Every file of the DEV home: no link anywhere, no NIGHTLY setting in any file.
    let dev_home = user_home.join(".acpmux/builds").join(DEV);
    let mut links = Vec::new();
    let mut copied = Vec::new();
    let mut pending = vec![dev_home];
    while let Some(dir) = pending.pop() {
        for entry in fs::read_dir(&dir).into_iter().flatten().flatten() {
            let kind = entry.file_type().unwrap();
            if kind.is_symlink() {
                links.push(entry.path());
            } else if kind.is_dir() {
                pending.push(entry.path());
            } else if fs::read(entry.path())
                .is_ok_and(|bytes| String::from_utf8_lossy(&bytes).contains("nightly-own-mode"))
            {
                copied.push(entry.path());
            }
        }
    }
    let _ = fs::remove_dir_all(&user_home);
    assert_eq!(homes.0.as_deref(), Some(nightly_home.as_path()), "NIGHTLY's daemon home");
    assert_eq!(
        homes.1.as_deref(),
        Some(user_home.join(".acpmux/builds").join(DEV).as_path()),
        "the untagged DEV build's daemon home"
    );
    assert_ne!(pid(&nightly), pid(&dev), "one daemon served both builds");
    assert_ne!(sockets.0, sockets.1, "both builds' daemons share one socket");
    assert_success(&stop_dev);
    for key in ["defaultHarness", "webAskingModes"] {
        assert_eq!(after[key], before[key], "NIGHTLY's config lost or changed {key}");
    }
    assert_eq!(
        after["websocket"]["listen"], before["websocket"]["listen"],
        "NIGHTLY's listen address"
    );
    assert!(links.is_empty(), "the DEV build's home links elsewhere: {links:?}");
    assert!(copied.is_empty(), "the DEV build's home holds NIGHTLY's settings: {copied:?}");
    assert!(nightly_after, "the DEV build's `cmux acp daemon shutdown` stopped NIGHTLY's acpmux");
}
