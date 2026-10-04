//! The server reads only CMUX_APP_ID, CMUX_APP_DATA_DIR, TMPDIR and LANG,
//! and every child process (the link, ssh-agent, ssh-add, scp) starts
//! from an empty environment plus TMPDIR, LANG and a private HOME under
//! the app's data folder. Every scp names the app's OpenSSH config and
//! known_hosts and never the user's ~/.ssh.

mod attach_common;
mod common;
mod edge_common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::app_env::AppEnv;
use cmux_cloud::fs::{Direction, OpenSshTransfer, Transfer, TransferJob, TransferKey, scp_args};
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
fn a_transfer_job_carries_only_the_child_env_and_the_apps_ssh_files() {
    let data = data_dir("job");
    let local = local_file(&data);
    let mut rig = edge_common::rig_with_env(
        &["vm-get", "attach_endpoint_alpha", "scp-endpoint"],
        server_env(&data),
    );
    rig.server.handle(&push(&local)).expect("push");
    rig.server.wait_transfers();
    let job = rig.transfer.log().jobs[0].clone();
    assert_eq!(keys(&job.env), BTreeSet::from(["HOME", "LANG", "TMPDIR"]), "{:?}", job.env);
    assert_private_home(&job.env, &data);
    for (key, value) in &job.env {
        assert_no_marker(&format!("{key}={value}"), "the transfer environment");
    }
    assert_eq!(job.ssh.config, data.join("ssh/config"));
    assert_eq!(job.ssh.known_hosts, data.join("ssh/known_hosts"));
    let pinned = std::fs::read_to_string(data.join("ssh/known_hosts")).unwrap_or_default();
    assert!(
        pinned.lines().any(|l| l.starts_with("cmux-scp-vm-alpha01 ssh-ed25519 AAAA")),
        "the endpoint's host key is pinned in the app's known_hosts: {pinned:?}"
    );
}

fn job(data: &Path) -> TransferJob {
    let env = server_env(data);
    TransferJob {
        machine: "vm-alpha01".into(),
        direction: Direction::Push,
        local: local_file(data),
        guest: "/home/cmux/upload.txt".into(),
        endpoint: cmux_cloud::fs::ScpEndpoint {
            host: "10.200.0.2".into(),
            port: 22,
            username: "cmux".into(),
            host_public_key:
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBERERERERERERERERERERERERERERERERERERERERER"
                    .into(),
            expires_at_unix: 4_102_444_800,
        },
        route: "127.0.0.1:40022".parse().unwrap(),
        env: env.child_env().unwrap(),
        ssh: env.ssh_files().unwrap(),
        temp_dir: env.temp_dir(),
    }
}

/// `-F` and the three host key options appear exactly once with the
/// app's paths; nothing names ~/.ssh or the marker HOME.
fn assert_ssh_paths(argv: &[String], data: &Path) {
    let config = data.join("ssh/config").to_string_lossy().into_owned();
    let known = data.join("ssh/known_hosts").to_string_lossy().into_owned();
    let pairs: Vec<(&str, &str)> =
        argv.windows(2).map(|w| (w[0].as_str(), w[1].as_str())).collect();
    let count = |flag: &str, value: &str| pairs.iter().filter(|p| **p == (flag, value)).count();
    assert_eq!(count("-F", &config), 1, "{argv:?}");
    assert_eq!(pairs.iter().filter(|(f, _)| *f == "-F").count(), 1, "one -F: {argv:?}");
    assert_eq!(count("-o", &format!("UserKnownHostsFile=\"{known}\"")), 1, "{argv:?}");
    assert_eq!(count("-o", "GlobalKnownHostsFile=/dev/null"), 1, "{argv:?}");
    assert_eq!(count("-o", "StrictHostKeyChecking=yes"), 1, "{argv:?}");
    for option in ["UserKnownHostsFile=", "GlobalKnownHostsFile=", "StrictHostKeyChecking="] {
        let all = argv.iter().filter(|a| a.starts_with(option)).count();
        assert_eq!(all, 1, "{option} once: {argv:?}");
    }
    for arg in argv {
        assert_no_marker(arg, "the scp argv");
    }
}

#[test]
fn scp_names_the_apps_config_and_known_hosts_and_never_the_users() {
    let data = data_dir("argv");
    let job = job(&data);
    let argv = scp_args(&job, Path::new("/tmp/x/agent.sock"), Path::new("/tmp/x/transfer.pub"));
    assert_ssh_paths(&argv, &data);
    assert!(argv.iter().any(|a| a == "HostKeyAlias=cmux-scp-vm-alpha01"), "{argv:?}");
}

/// A stand-in OpenSSH: each program records its environment (and scp its
/// argv) in `dir`, then behaves enough for the transfer to finish.
#[cfg(unix)]
fn fake_openssh(dir: &Path) -> OpenSshTransfer {
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::create_dir_all(dir).unwrap();
    let d = dir.display();
    let tools = [
        (
            "ssh-agent",
            format!(
                "/usr/bin/env > '{d}/ssh-agent.env'\nprintf 'SSH_AUTH_SOCK=%s; export SSH_AUTH_SOCK;\\n' \"$3\"\nexec /bin/sleep 30\n"
            ),
        ),
        ("ssh-add", format!("/usr/bin/env > '{d}/ssh-add.env'\n/bin/cat > /dev/null\n")),
        (
            "scp",
            format!(
                "/usr/bin/env > '{d}/scp.env'\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > '{d}/scp.argv'\n"
            ),
        ),
        ("ssh", "exit 1\n".to_owned()),
    ];
    for (name, body) in &tools {
        let path = dir.join(name);
        std::fs::write(&path, format!("#!/bin/sh\n{body}")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    OpenSshTransfer {
        ssh: dir.join("ssh"),
        ssh_agent: dir.join("ssh-agent"),
        ssh_add: dir.join("ssh-add"),
        scp: dir.join("scp"),
    }
}

/// Variables a child process recorded, without the ones /bin/sh adds by
/// itself (PWD, SHLVL, `_`, OLDPWD).
#[cfg(unix)]
fn recorded(file: &Path) -> Vec<(String, String)> {
    std::fs::read_to_string(file)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.split_once('='))
        .filter(|(k, _)| !matches!(*k, "PWD" | "SHLVL" | "_" | "OLDPWD"))
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect()
}

#[cfg(unix)]
#[test]
fn the_real_openssh_children_get_only_the_child_env() {
    let data = data_dir("real");
    let tools = data.with_extension("tools");
    let transfer = fake_openssh(&tools);
    let job = job(&data);
    let key = TransferKey::generate().unwrap();
    let copied = transfer.run(&job, &key, &cmux_cloud::fs::Cancel::default());
    assert!(copied.is_ok(), "{copied:?}");
    for (child, expected) in [
        ("ssh-agent", vec!["HOME", "LANG", "TMPDIR"]),
        ("ssh-add", vec!["HOME", "LANG", "SSH_AUTH_SOCK", "TMPDIR"]),
        ("scp", vec!["HOME", "LANG", "TMPDIR"]),
    ] {
        let env = recorded(&tools.join(format!("{child}.env")));
        assert_eq!(keys(&env), expected.into_iter().collect(), "{child}: {env:?}");
        assert_private_home(&env, &data);
        for (key, value) in &env {
            assert_no_marker(&format!("{key}={value}"), child);
        }
    }
    let argv: Vec<String> = std::fs::read_to_string(tools.join("scp.argv"))
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect();
    assert_ssh_paths(&argv, &data);
    let program = argv.windows(2).find(|w| w[0] == "-S").map(|w| PathBuf::from(&w[1]));
    assert_eq!(program, Some(tools.join("ssh")), "scp runs the configured ssh by absolute path");
}

#[cfg(unix)]
#[test]
fn the_real_link_spawner_passes_only_the_commands_env() {
    use cmux_cloud::link::{CarrierSpawner, LinkCommand, LinkSupervisor};
    let dir = PathBuf::from("/tmp").join(format!("cx-spawn-{}", std::process::id()));
    // cargo gives this test process HOME, PATH and CARGO_* variables.
    let script = r#"out=$(/usr/bin/env); case "$out" in *PATH=*|*CARGO_*|*USER=*) exit 3;; esac; test "$HOME" = "$1" && printf '%s\n' '{"ok":true,"path_state":"direct"}' >&2"#;
    let home = dir.join("home").display().to_string();
    let command = LinkCommand {
        binary: PathBuf::from("/bin/sh"),
        args: vec!["-c".into(), script.into(), "sh".into(), home.clone()],
        env: vec![("HOME".into(), home)],
        state_dir: dir.join("state"),
        local_socket: dir.join("link.sock"),
    };
    let mut supervisor = LinkSupervisor::new(Box::new(CarrierSpawner));
    let carrier = supervisor.spawn_and_wait("vm-env01", &command);
    assert!(carrier.is_ok(), "the child saw only the command's env: {carrier:?}");
    supervisor.disconnect("vm-env01");
}
