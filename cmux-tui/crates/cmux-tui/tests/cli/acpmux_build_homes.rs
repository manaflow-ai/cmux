//! One acpmux home per build (per-build isolation S2, cx-is1kf.3): the
//! `cmux acp` CLI inside each app resolves the acpmux home of its own build
//! (schemas/build-identity/vectors.json `acpmux_home`), and a stop through the
//! CLI of one build never reaches the daemon of another. NIGHTLY
//! (`com.cmuxterm.app.nightly`) keeps `~/.acpmux` in place; every other build,
//! the untagged DEV build included, has `~/.acpmux/builds/<key>`.
//!
//! The CLI learns its build the way it does inside an app's terminal:
//! `CMUX_BUNDLE_ID` and `CMUX_TAG`. Every case runs under a temp `HOME`.

use super::*;
use serde_json::Value;
use std::path::Path;

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
    let _ = fs::remove_dir_all(&user_home);
    assert!(wrong.is_empty(), "acpmux homes of the wrong build:\n{}", wrong.join("\n"));
}

/// NIGHTLY and the untagged DEV build run acpmux daemons at the same time:
/// two processes, two sockets, each in its own build's home. Stopping the
/// DEV build's daemon through its CLI leaves NIGHTLY's running.
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
        r#"{"websocket": {"listen": "127.0.0.1:0", "token": "acpmux-build-homes-test"}}"#,
    )
    .unwrap();
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
    let _ = shutdown(NIGHTLY);
    let _ = shutdown(DEV);
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
    assert!(nightly_after, "the DEV build's `cmux acp daemon shutdown` stopped NIGHTLY's acpmux");
}
