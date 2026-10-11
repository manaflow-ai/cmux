//! The server reads only CMUX_APP_ID, CMUX_APP_DATA_DIR, TMPDIR and LANG,
//! and every child process (each `cmux link dial`, for the carrier and for
//! daemon file ops) starts from an empty environment plus TMPDIR, LANG and
//! a private HOME under the app's data folder.

mod attach_common;
mod common;
mod edge_common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::app_env::AppEnv;
use cmux_cloud::{Origin, Request, Server};
use common::FakeControlPlane;
use serde_json::json;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

const SENTINEL: &str = "r71-sentinel-value";
const MARKER_HOME: &str = "/marker-home-r71";
const MARKER_PATH: &str = "/marker-path-r71";

fn data_dir(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-c10-{name}-{}", std::process::id()))
}

/// The server's environment as the host starts it, plus variables it
/// must ignore.
fn server_env(data: &Path) -> AppEnv {
    AppEnv::from_vars([
        ("CMUX_APP_ID", "cmux/cloud"),
        ("CMUX_APP_DATA_DIR", data.to_str().unwrap()),
        ("TMPDIR", "/tmp/c10-tmpdir"),
        ("LANG", "ja_JP.UTF-8"),
        ("CMUX_R71_SENTINEL", SENTINEL),
        ("HOME", MARKER_HOME),
        ("PATH", MARKER_PATH),
    ])
}

fn keys(env: &[(String, String)]) -> BTreeSet<&str> {
    env.iter().map(|(k, _)| k.as_str()).collect()
}

fn assert_no_marker(text: &str, what: &str) {
    for marker in [SENTINEL, MARKER_HOME, MARKER_PATH, "/.ssh"] {
        assert!(!text.contains(marker), "{what} mentions {marker}: {text}");
    }
}

fn assert_private_home(env: &[(String, String)], data: &Path) {
    let home = env.iter().find(|(k, _)| k == "HOME").map(|(_, v)| PathBuf::from(v));
    assert_eq!(home, Some(data.join("home")), "HOME is the private folder: {env:?}");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(data.join("home")).map(|m| m.permissions().mode() & 0o777);
        assert_eq!(mode.ok(), Some(0o700), "the private HOME is owner-only");
    }
}

#[test]
fn the_link_child_gets_only_tmpdir_lang_and_a_private_home() {
    let data = data_dir("link");
    let spawner = FakeSpawner::default();
    let mut s = Server::with_attach(
        FakeControlPlane::with(&["vm-get"]),
        attach(&spawner, &FakeTransport::default()).with_env(server_env(&data)),
    );
    let request =
        Request::new("cloud.machine.connect", json!({ "machine": "vm-alpha01" })).key("c-1");
    let up = s.handle(&request).map(|r| r["state"].clone());
    assert_eq!(up.as_ref().ok(), Some(&json!("up")), "{up:?}");
    let command = spawner.log().commands[0].clone();
    assert!(command.binary.is_absolute(), "the link binary by absolute path");
    assert_eq!(
        keys(&command.env),
        BTreeSet::from(["HOME", "LANG", "TMPDIR"]),
        "exactly these variables: {:?}",
        command.env
    );
    assert_private_home(&command.env, &data);
    assert!(command.env.contains(&("LANG".into(), "ja_JP.UTF-8".into())));
    assert!(command.env.contains(&("TMPDIR".into(), "/tmp/c10-tmpdir".into())));
    for (key, value) in &command.env {
        assert_no_marker(&format!("{key}={value}"), "the link environment");
    }
    for arg in &command.args {
        assert_no_marker(arg, "the link argv");
    }
}

fn push(local: &Path) -> Request {
    Request::new(
        "cloud.file.push",
        json!({"machine": "vm-alpha01", "localPath": local, "path": "/home/cmux/upload.txt"}),
    )
    .key("p-1")
    .origin(Origin::User)
}

fn local_file(data: &Path) -> PathBuf {
    let dir = data.with_extension("files");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("upload.txt");
    std::fs::write(&file, b"payload").unwrap();
    file
}

#[test]
fn a_transfer_job_carries_only_the_child_env() {
    let data = data_dir("job");
    let local = local_file(&data);
    let mut rig = edge_common::rig_with_env(&["vm-get", "connect-info-fs"], server_env(&data));
    rig.server.handle(&push(&local)).expect("push");
    rig.server.wait_transfers();
    let job = rig.transfer.log().jobs[0].clone();
    let env = &job.target.env;
    assert_eq!(keys(env), BTreeSet::from(["HOME", "LANG", "TMPDIR"]), "{env:?}");
    assert_private_home(env, &data);
    for (key, value) in env {
        assert_no_marker(&format!("{key}={value}"), "the transfer environment");
    }
    assert!(job.target.binary.is_absolute(), "the dial binary by absolute path");
}

#[cfg(unix)]
#[test]
fn the_real_link_spawner_passes_only_the_commands_env() {
    use cmux_cloud::link::{CarrierSpawner, LinkCommand, LinkSupervisor};
    let dir = PathBuf::from("/tmp").join(format!("cx-spawn-{}", std::process::id()));
    // cargo gives this test process HOME, PATH and CARGO_* variables.
    let script = r#"out=$(/usr/bin/env); case "$out" in *PATH=*|*CARGO_*|*USER=*) exit 3;; esac; test "$HOME" = "$1" && printf '%s\n' '{"ok":true,"path_state":"direct"}' >&2 && printf clean"#;
    let home = dir.join("home").display().to_string();
    let command = LinkCommand {
        binary: PathBuf::from("/bin/sh"),
        args: vec!["-c".into(), script.into(), "sh".into(), home.clone()],
        env: vec![("HOME".into(), home)],
        state_dir: dir.join("state"),
        local_socket: dir.join("link.sock"),
    };
    let mut supervisor = LinkSupervisor::new(Box::new(CarrierSpawner));
    let carrier = supervisor.spawn_and_wait("vm-env01", &command).expect("carrier");
    let mut stream = std::os::unix::net::UnixStream::connect(&carrier.socket).expect("dial");
    stream.shutdown(std::net::Shutdown::Write).expect("half close");
    let mut out = Vec::new();
    let _ = std::io::Read::read_to_end(&mut stream, &mut out);
    assert_eq!(out, b"clean", "the child saw only the command's env");
    supervisor.disconnect("vm-env01");
}
