//! A cancel stops the real OpenSSH transfer: the hook kills the running
//! `scp` child, and `run` returns at once with an error. The OpenSSH
//! programs are stand-in scripts (no network).
#![cfg(unix)]

use cmux_cloud::app_env::AppEnv;
use cmux_cloud::fs::{Cancel, Direction, OpenSshTransfer, ScpEndpoint, Transfer, TransferJob};
use cmux_cloud::fs::TransferKey;
use std::path::{Path, PathBuf};
use std::sync::mpsc::channel;
use std::time::Duration;

fn dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-c12-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// ssh-agent and ssh-add as in a real run; scp writes part of the file to
/// its last argument (the pull's landing name), says so, and then never ends.
fn stand_in(tools: &Path) -> OpenSshTransfer {
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::create_dir_all(tools).unwrap();
    let d = tools.display();
    let scripts = [
        ("ssh-agent", "printf 'SSH_AUTH_SOCK=%s; export SSH_AUTH_SOCK;\\n' \"$3\"\nexec /bin/sleep 600\n".to_owned()),
        ("ssh-add", "/bin/cat > /dev/null\n".to_owned()),
        ("scp", format!("for a in \"$@\"; do last=\"$a\"; done\nprintf part > \"$last\"\n: > '{d}/scp.started'\nexec /bin/sleep 600\n")),
        ("ssh", "exit 1\n".to_owned()),
    ];
    for (name, body) in &scripts {
        let path = tools.join(name);
        std::fs::write(&path, format!("#!/bin/sh\n{body}")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    OpenSshTransfer {
        ssh: tools.join("ssh"),
        ssh_agent: tools.join("ssh-agent"),
        ssh_add: tools.join("ssh-add"),
        scp: tools.join("scp"),
    }
}

fn pull_job(data: &Path) -> TransferJob {
    let env = AppEnv::from_vars([("CMUX_APP_DATA_DIR", data.to_str().unwrap())]);
    TransferJob {
        machine: "vm-alpha01".into(),
        direction: Direction::Pull,
        local: data.join(".notes.txt.cmux-pull-0011223344556677"),
        guest: "/home/cmux/notes.txt".into(),
        endpoint: ScpEndpoint {
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
        temp_dir: std::env::temp_dir(),
    }
}

#[test]
fn a_cancel_kills_the_running_scp_and_run_returns() {
    let data = dir("kill");
    let tools = data.join("tools");
    let transfer = stand_in(&tools);
    let job = pull_job(&data);
    let cancel = Cancel::default();
    let (done, ended) = channel();
    let worker_cancel = cancel.clone();
    std::thread::spawn(move || {
        let key = TransferKey::generate().unwrap();
        let _ = done.send(transfer.run(&job, &key, &worker_cancel));
    });
    // scp runs (its marker file exists) before the cancel: the kill, not
    // an early check, has to stop it. The bound only ends a failed test.
    let started = tools.join("scp.started");
    let mut waited = Duration::ZERO;
    while !started.exists() && waited < Duration::from_secs(20) {
        std::thread::sleep(Duration::from_millis(20));
        waited += Duration::from_millis(20);
    }
    assert!(started.exists(), "scp started");
    cancel.cancel();
    let outcome = ended.recv_timeout(Duration::from_secs(20));
    assert!(matches!(outcome, Ok(Err(_))), "run returned an error after the kill: {outcome:?}");
}

#[test]
fn a_cancel_before_the_run_starts_no_child() {
    let data = dir("early");
    let tools = data.join("tools");
    let transfer = stand_in(&tools);
    let job = pull_job(&data);
    let cancel = Cancel::default();
    cancel.cancel();
    let (done, ended) = channel();
    std::thread::spawn(move || {
        let key = TransferKey::generate().unwrap();
        let _ = done.send(transfer.run(&job, &key, &cancel));
    });
    let outcome = ended.recv_timeout(Duration::from_secs(20));
    assert!(matches!(outcome, Ok(Err(_))), "{outcome:?}");
    assert!(!tools.join("scp.started").exists(), "no scp after a cancel");
}
