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
//! never share a socket again; the session follows the same names
//! (`BuildIdentity::app_session`, proven live by chief-per-build-live.py).
//!
//! The CLI learns its build the way it does inside an app's terminal
//! (`CMUX_BUNDLE_ID` and `CMUX_TAG`), or from a fake bundle around it. Every
//! case runs under a temp `HOME`, and no case resolves the names of a real
//! build (NIGHTLY, cmux NEXT, release, RC, staging): `refuse_real_name`.
//! Nothing here starts or stops a daemon.

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

/// Builds a person runs for real (NIGHTLY, cmux NEXT, release, RC, staging):
/// no test here resolves their names (hq-6d, 2026-10-14). Their kept names
/// are the vectors' and do not change with per-build isolation.
fn is_real_build(bundle_id: &str) -> bool {
    bundle_id.starts_with("com.cmuxterm.app.nightly")
        || ["com.cmuxterm.app", "com.cmuxterm.app.rc", "com.cmuxterm.app.staging"].contains(&bundle_id)
}

/// Refuses a socket path or session name of a real build.
fn refuse_real_name(name: &str) {
    let real = ["/tmp/cmux-nightly", "/tmp/cmux-rc.sock", "/tmp/cmux-staging.sock", "/tmp/cmux-debug.sock"];
    assert!(
        !real.iter().any(|prefix| name.contains(prefix))
            && !["cmux-app", "cmux-app-nightly", "cmux-app-cmux-next"].contains(&name),
        "this test refuses to resolve a real build's name: {name}"
    );
}

/// `cmux --json identify` (an app command) by `cli`: no app runs, so it
/// fails and names the control socket it tried.
fn tried_socket(output: &Output) -> String {
    assert!(!output.status.success(), "an app answered: {}", text_of(output));
    text_of(output)
}

/// Every test build of the shared vectors (every DEV, unknown and tagged RC
/// or staging bundle; no real build): `cmux identify` tries the vector's
/// control socket and no other. The untagged DEV build reaches its own
/// key's socket, never release's or `/tmp/cmux-debug.sock`, and builds of
/// different DEV tags never share one.
#[test]
fn cmux_reaches_the_control_socket_of_its_own_build() {
    let vectors = vectors();
    let vector_home = vectors["user_home"].as_str().unwrap();
    let user_home = unique_temp_dir("app-daemon-names");
    fs::create_dir_all(&user_home).unwrap();
    let mut wrong = Vec::new();
    let mut reached = std::collections::BTreeMap::<PathBuf, String>::new();
    let mut release = None;
    for case in vectors["cases"].as_array().unwrap() {
        let Some(bundle_id) = case["bundle_id"].as_str() else { continue };
        let want = case["app_daemon"]["control_socket"].as_str().unwrap();
        let want = rebased(want, vector_home, &user_home);
        if bundle_id == "com.cmuxterm.app" {
            release = Some(want.clone());
        }
        if is_real_build(bundle_id) {
            continue;
        }
        refuse_real_name(want.to_str().unwrap());
        refuse_real_name(case["app_daemon"]["session"].as_str().unwrap());
        let tag = case["tag"].as_str().unwrap_or("untagged");
        let output =
            cmux_as(bundle_id, case["bundled_tag"].as_str(), &user_home, &["--json", "identify"]);
        let text = tried_socket(&output);
        if !text.contains(want.to_str().unwrap()) {
            wrong.push(format!("{}: {} (want {})", case["name"], text.trim(), want.display()));
        } else if let Some(other) = reached.insert(want.clone(), tag.to_owned())
            && other != tag
        {
            wrong.push(format!("tags {tag} and {other} share {}", want.display()));
        }
    }
    let untagged = rebased("/tmp/cmux-debug--650e93e3.sock", vector_home, &user_home);
    if !reached.contains_key(&untagged) || release.as_ref() == Some(&untagged) {
        wrong.push(format!("the untagged DEV build is not on its own socket (release {release:?})"));
    }
    let _ = fs::remove_dir_all(&user_home);
    assert!(wrong.is_empty(), "control sockets of the wrong build:\n{}", wrong.join("\n"));
}

/// A fake app bundle at `dir/<name>` with bundle id `bundle_id`, no
/// `LSEnvironment`, and this CLI as its bundled `cmux`.
fn fake_bundle(dir: &Path, name: &str, bundle_id: &str) -> PathBuf {
    let contents = dir.join(name).join("Contents");
    fs::create_dir_all(contents.join("Resources/bin")).unwrap();
    fs::write(
        contents.join("Info.plist"),
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\
             <key>CFBundleIdentifier</key><string>{bundle_id}</string></dict></plist>\n"
        ),
    )
    .unwrap();
    let cli = contents.join("Resources/bin/cmux");
    fs::copy(bin(), &cli).unwrap();
    cli
}

/// The `cmux` bundled in an app, outside any app terminal: the bundle
/// decides, as in the app (CmuxNext `LaunchIdentity`). A copy named
/// `cmux DEV <tag>.app` that lost `LSEnvironment` ships its name's tag (the
/// fleet's staged copies); a copy with no tag anywhere is the untagged DEV
/// build, on its key's socket.
#[test]
fn the_bundled_cli_reads_its_build_from_the_bundle_as_the_app_does() {
    let dir = unique_temp_dir("app-daemon-bundles");
    let user_home = dir.join("home");
    fs::create_dir_all(&user_home).unwrap();
    let mut wrong = Vec::new();
    for (name, want) in [
        ("cmux DEV s3name.app", "/tmp/cmux-debug-s3name.sock"),
        ("B.app", "/tmp/cmux-debug--650e93e3.sock"),
    ] {
        refuse_real_name(want);
        let cli = fake_bundle(&dir, name, "com.cmuxterm.app.debug");
        let mut command = Command::new(&cli);
        command.args(["--json", "identify"]).env("LC_ALL", "C").env("HOME", &user_home);
        for key in FOREIGN {
            command.env_remove(key);
        }
        let text = tried_socket(&command.stdin(Stdio::null()).output().unwrap());
        if !text.contains(want) {
            wrong.push(format!("{name}: {} (want {want})", text.trim()));
        }
    }
    let _ = fs::remove_dir_all(&dir);
    assert!(wrong.is_empty(), "bundled CLIs on the wrong socket:\n{}", wrong.join("\n"));
}
