//! Signed installer -> content-addressed profile -> real managed worker.
//! Service-manager commands are recorded; only temporary fixture processes run.
#![cfg(unix)]

// Reuse the installer's signing, archive and fetch fixtures, not production keys.
#[path = "../../cmux-server/tests/common/mod.rs"]
mod common;

use std::time::{Duration, Instant};

use cmux_host::proc_roles::{RolePaths, Supervisor, load_roles};
use cmux_server::cli::{Context, dispatch, parse};
use cmux_server::exec::RecordingExec;
use cmux_server::host;
use cmux_server::process::RecordingRunner;
use cmux_server_core::InstallMode;
use cmux_server_core::layout::Layout;
use cmux_server_core::role_proc::RoleState;
use common::*;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

const CHANNEL: &str = "https://bootstrap.example.test";

struct Fixture {
    home: tempfile::TempDir,
    layout: Layout,
    runner: RecordingRunner,
    fetcher: MapFetcher,
    signer: Signer,
    exec: RecordingExec,
}

impl Fixture {
    fn new() -> Self {
        assert!(
            !cmux_server::sys::is_root(),
            "the user-mode journey requires an unprivileged worker"
        );
        let home = tempfile::Builder::new().prefix("srvboot").tempdir_in("/tmp").unwrap();
        let layout = host::layout_for(InstallMode::User, &env_for(home.path())).unwrap();
        Self {
            home,
            layout,
            runner: RecordingRunner::new(),
            fetcher: MapFetcher::default(),
            signer: Signer::new(3),
            exec: RecordingExec::default(),
        }
    }

    fn run(&self, command: &str) -> cmux_server::Result<serde_json::Value> {
        let mut args: Vec<String> = command.split_whitespace().map(str::to_owned).collect();
        args.extend(["--channel-url".to_owned(), CHANNEL.to_owned()]);
        let context = Context {
            runner: &self.runner,
            fetcher: Some(&self.fetcher),
            exec: &self.exec,
            keys: vec![self.signer.key("fixture")],
            running_cmux: "1.0.0".to_owned(),
            reexec_guard: None,
            env: env_for(self.home.path()),
            now_ms: NOW_MS,
        };
        dispatch(&context, &parse(&args)?).map(|output| output.json)
    }

    fn publish(&self, channel: &str, sequence: u64, version: &'static str, corrupt: bool) {
        let worker = format!(
            r#"#!/usr/bin/python3
import json, os, signal, socket, sys
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
connection.connect(os.environ['CMUX_BOOTSTRAP_TEST_SOCKET'])
def reply():
    connection.sendall((json.dumps({{'version':'{version}','pid':os.getpid()}})+'\n').encode())
reply()
for line in connection.makefile('r'):
    reply()
"#
        );
        let package = Pkg {
            name: "cmux",
            version,
            archive: files_package(&[
                ("cmux", b"#!/bin/sh\nexit 0\n"),
                ("fixture-worker", worker.as_bytes()),
            ]),
        };
        self.fetcher.serve(&package);
        let mut manifest: serde_json::Value = serde_json::from_slice(&manifest(
            sequence,
            "2027-01-01T00:00:00Z",
            "1.0.0",
            &[&package],
        ))
        .unwrap();
        manifest["channel"] = channel.into();
        let bytes = serde_json::to_vec(&manifest).unwrap();
        let url = format!("{CHANNEL}/{channel}/{}/latest.json", host::TARGET);
        self.fetcher.put(&format!("{url}.sig"), self.signer.sign(&bytes));
        self.fetcher.put(&url, bytes);
        if corrupt {
            self.fetcher.put(&package.url(), b"incomplete archive".to_vec());
        }
    }

    fn config(&self) -> std::path::PathBuf {
        self.layout.config_file.as_str().into()
    }

    fn roles(&self, socket: &std::path::Path) {
        let path = self.config();
        cmux_server::fsx::ensure_dir(path.parent().unwrap(), 0o700).unwrap();
        let config = serde_json::json!({
            "operator_notes": {"keep": true},
            "roles": {"fixture-worker": {"program": "fixture-worker", "restart": "never", "ready": "started",
                "env": {"CMUX_BOOTSTRAP_TEST_SOCKET": socket.to_str().unwrap()}}},
            "server": {"channel": "stable"}
        });
        cmux_server::fsx::atomic_write(&path, &serde_json::to_vec(&config).unwrap(), 0o600)
            .unwrap();
    }

    fn supervisor(&self) -> Supervisor {
        let supervisor = Supervisor::start(RolePaths::from_layout(&self.layout)).unwrap();
        let roles = load_roles(&self.config());
        assert!(roles.invalid.is_empty(), "{:?}", roles.invalid);
        supervisor.apply(roles);
        supervisor
    }
}

async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(5), future).await.expect("bounded bootstrap fixture")
}

async fn worker(listener: &UnixListener, version: &str) -> BufReader<UnixStream> {
    let (stream, _) = within(listener.accept()).await.unwrap();
    let mut stream = BufReader::new(stream);
    let mut line = String::new();
    within(stream.read_line(&mut line)).await.unwrap();
    let hello: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(hello["version"], version);
    assert!(hello["pid"].as_u64().is_some_and(|pid| pid > 1));
    stream
}

#[tokio::test]
async fn signed_server_install_bootstrap_rejected_first_install_does_not_persist_an_identity() {
    let fixture = Fixture::new();
    fixture.publish("stable", 1, "1.0.0", true);
    assert!(fixture.run("install").is_err());
    assert!(!fixture.config().exists(), "a rejected package cannot commit a new install identity");
    assert!(!std::path::Path::new(fixture.layout.current.as_str()).exists());
    assert!(fixture.runner.commands().is_empty(), "no service command before verification");
}

#[tokio::test]
async fn signed_server_install_bootstrap_rejected_reinstall_preserves_config_and_the_running_role()
{
    let fixture = Fixture::new();
    let socket = fixture.home.path().join("worker.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    fixture.roles(&socket);
    fixture.publish("stable", 1, "1.0.0", false);
    fixture.run("install").unwrap();
    let supervisor = fixture.supervisor();
    let mut running = worker(&listener, "1.0.0").await;
    let before = std::fs::read(fixture.config()).unwrap();
    let service_commands = fixture.runner.commands().len();
    fixture.publish("beta", 2, "2.0.0", true);
    assert!(fixture.run("install --channel beta").is_err());
    assert_eq!(std::fs::read(fixture.config()).unwrap(), before, "keep the last successful config");
    assert_eq!(
        fixture.runner.commands().len(),
        service_commands,
        "no restart after a rejected package"
    );
    running.get_mut().write_all(b"still-running\n").await.unwrap();
    let mut line = String::new();
    within(running.read_line(&mut line)).await.unwrap();
    assert_eq!(serde_json::from_str::<serde_json::Value>(&line).unwrap()["version"], "1.0.0");
    assert!(supervisor.stop_all(Instant::now() + Duration::from_secs(3)).is_empty());
}

#[tokio::test]
async fn signed_server_install_bootstrap_upgrade_starts_the_verified_profile_and_preserves_configuration()
 {
    let fixture = Fixture::new();
    let socket = fixture.home.path().join("worker.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    fixture.roles(&socket);
    fixture.publish("stable", 1, "1.0.0", false);
    let first = fixture.run("install").unwrap();
    assert_eq!(first["installed"], true);
    let before: serde_json::Value =
        serde_json::from_slice(&std::fs::read(fixture.config()).unwrap()).unwrap();
    let first_supervisor = fixture.supervisor();
    let mut first_worker = worker(&listener, "1.0.0").await;
    assert_eq!(first_supervisor.health()[0].state, RoleState::Ready);
    assert!(first_supervisor.stop_all(Instant::now() + Duration::from_secs(3)).is_empty());
    let mut closed = String::new();
    assert_eq!(within(first_worker.read_line(&mut closed)).await.unwrap(), 0);
    drop(first_supervisor);

    fixture.publish("stable", 2, "2.0.0", false);
    let upgrade = fixture.run("install").unwrap();
    assert_eq!(
        upgrade["restarted"], true,
        "the installer requests a service restart for the new profile"
    );
    assert_ne!(upgrade["generation"], first["generation"]);
    let after: serde_json::Value =
        serde_json::from_slice(&std::fs::read(fixture.config()).unwrap()).unwrap();
    assert_eq!(after["installId"], before["installId"]);
    assert_eq!(after["roles"], before["roles"]);
    assert_eq!(after["operator_notes"], before["operator_notes"]);
    let second_supervisor = fixture.supervisor();
    let mut second_worker = worker(&listener, "2.0.0").await;
    assert_eq!(second_supervisor.health()[0].state, RoleState::Ready);
    assert!(second_supervisor.stop_all(Instant::now() + Duration::from_secs(3)).is_empty());
    assert_eq!(within(second_worker.read_line(&mut closed)).await.unwrap(), 0);
}
