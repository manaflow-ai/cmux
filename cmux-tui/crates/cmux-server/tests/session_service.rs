//! `cmux server install` on a machine the signed server channel does not
//! serve (or with `--binary`): the session service keeps this binary's cmux
//! session daemon running, so cmux reaches it over SSH after logouts and
//! reboots.

mod common;

use std::path::{Path, PathBuf};

use cmux_server::cli::{Context, dispatch, parse};
use cmux_server::exec::RecordingExec;
use cmux_server::process::{Output, RecordingRunner};
use cmux_server_core::units::parse_session_unit;
use common::*;

struct Env {
    tmp: tempfile::TempDir,
    runner: RecordingRunner,
    fetcher: MapFetcher,
    exec: RecordingExec,
    keys: bool,
}

impl Env {
    fn new() -> Env {
        let env = Env {
            tmp: tempfile::tempdir().unwrap(),
            runner: RecordingRunner::new(),
            fetcher: MapFetcher::default(),
            exec: RecordingExec::default(),
            keys: true,
        };
        std::fs::write(env.exe(), b"#!/bin/sh\necho cmux build A\n").unwrap();
        env
    }

    fn exe(&self) -> PathBuf {
        self.tmp.path().join("downloaded-cmux")
    }

    fn home(&self) -> &Path {
        self.tmp.path()
    }

    fn ctx(&self) -> Context<'_> {
        Context {
            runner: &self.runner,
            fetcher: Some(&self.fetcher),
            exec: &self.exec,
            keys: if self.keys { vec![Signer::new(3).key("current")] } else { Vec::new() },
            running_cmux: "1.0.0".to_owned(),
            reexec_guard: None,
            env: env_for(self.home()),
            now_ms: NOW_MS,
            self_exe: Some(self.exe()),
        }
    }

    fn run(&self, line: &str) -> cmux_server::Result<serde_json::Value> {
        let words: Vec<String> = line.split_whitespace().map(str::to_owned).collect();
        dispatch(&self.ctx(), &parse(&words)?).map(|o| o.json)
    }

    fn binary(&self) -> PathBuf {
        self.home().join(".local/bin/cmux-tui")
    }
}

fn skip_as_root() -> bool {
    let root = cmux_server::sys::is_root();
    if root {
        eprintln!("skipped: user-mode install refuses root");
    }
    root
}

#[test]
fn no_published_channel_installs_the_session_service() {
    if skip_as_root() {
        return;
    }
    let env = Env::new();
    env.runner.answer(
        "show-user",
        Output { code: Some(0), stdout: b"yes\n".to_vec(), ..Output::default() },
    );
    let out = env.run("install --json").unwrap();
    assert_eq!(out["source"], "binary", "{out}");
    assert_eq!(out["session"], "main");
    assert_eq!(out["binary_changed"], true);
    assert!(out["note"].as_str().unwrap().contains("no release for this machine"), "{out}");
    // The binary is a copy at the path cmux clients use over SSH, executable.
    assert_eq!(std::fs::read(env.binary()).unwrap(), std::fs::read(env.exe()).unwrap());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        assert_eq!(std::fs::metadata(env.binary()).unwrap().permissions().mode() & 0o777, 0o755);
    }
    // `cmux` in an SSH session runs it.
    let shim = env.home().join(".local/bin/cmux");
    assert_eq!(std::fs::read_link(&shim).unwrap(), Path::new("cmux-tui"));
    // The unit runs that binary's session daemon.
    let unit = std::fs::read_to_string(out["unit"].as_str().unwrap()).unwrap();
    let parsed = parse_session_unit(&unit).expect("a session unit");
    assert_eq!(Path::new(&parsed.binary), env.binary());
    assert_eq!(parsed.session, "main");
    let lines = env.runner.lines().join("\n");
    if cfg!(target_os = "linux") {
        assert!(lines.contains("systemctl --user enable cmux-server.service"), "{lines}");
        // `start`, or `restart` when the (recorded) manager reports it active.
        assert!(lines.contains("start cmux-server.service"), "{lines}");
        assert_eq!(out["linger"], true, "{out}");
    } else {
        assert!(lines.contains("launchctl bootstrap"), "{lines}");
    }
    // Nothing of the store was fetched beyond the channel's one 404.
    let hits = env.fetcher.hits.lock().unwrap().clone();
    assert_eq!(hits.len(), 1, "{hits:?}");
    assert!(hits[0].ends_with("/latest.json"), "{hits:?}");
}

#[test]
fn a_second_install_changes_nothing_and_status_names_the_session() {
    if skip_as_root() {
        return;
    }
    let env = Env::new();
    env.run("install --binary").unwrap();
    let again = env.run("install --binary --json").unwrap();
    assert_eq!(again["changed"], false, "{again}");
    assert_eq!(again["binary_changed"], false);
    assert_eq!(again["restarted"], false);
    let status = env.run("status --json").unwrap();
    assert_eq!(status["service"]["session"]["session"], "main", "{status}");
    assert_eq!(Path::new(status["service"]["session"]["binary"].as_str().unwrap()), env.binary());
}

#[test]
fn a_new_binary_replaces_the_old_and_restarts_the_service() {
    if skip_as_root() {
        return;
    }
    let env = Env::new();
    env.run("install --binary").unwrap();
    std::fs::write(env.exe(), b"#!/bin/sh\necho cmux build B\n").unwrap();
    let out = env.run("install --binary --json").unwrap();
    assert_eq!(out["binary_changed"], true, "{out}");
    assert_eq!(std::fs::read(env.binary()).unwrap(), b"#!/bin/sh\necho cmux build B\n");
    if cfg!(target_os = "linux") {
        let lines = env.runner.lines();
        assert!(lines.iter().any(|l| l.contains("is-active")), "{lines:?}");
    }
}

#[test]
fn a_build_without_release_keys_installs_the_session_service() {
    if skip_as_root() {
        return;
    }
    let mut env = Env::new();
    env.keys = false;
    let out = env.run("install --json").unwrap();
    assert_eq!(out["source"], "binary", "{out}");
    assert!(env.fetcher.hits.lock().unwrap().is_empty());
    // Asking for the store still refuses as before (exit 7).
    let err = env.run("install --channel-url=https://chan.example.test").unwrap_err();
    assert_eq!(err.kind.code(), 7, "{err:?}");
}

#[test]
fn session_flags_are_checked() {
    if skip_as_root() {
        return;
    }
    let env = Env::new();
    let other = env.run("install --session-name agents --json").unwrap();
    assert_eq!(other["session"], "agents");
    for bad in [
        "install --session-name -x",
        "install --session-name a/b",
        "install --binary --version 1.0.0",
    ] {
        assert_eq!(env.run(bad).unwrap_err().kind.code(), 2, "{bad}");
    }
    // ssh:// endpoints run from the cmux CLI, never from this crate.
    assert_eq!(env.run("install ssh://ana@build").unwrap_err().kind.code(), 2);
    assert_eq!(env.run("install --yes").unwrap_err().kind.code(), 2);
    assert_eq!(env.run("uninstall ssh://ana@build").unwrap_err().kind.code(), 2);
}

#[test]
fn someone_elses_cmux_is_left_alone() {
    if skip_as_root() {
        return;
    }
    let env = Env::new();
    let shim = env.home().join(".local/bin/cmux");
    std::fs::create_dir_all(shim.parent().unwrap()).unwrap();
    std::fs::write(&shim, b"mine").unwrap();
    let out = env.run("install --binary --json").unwrap();
    assert_eq!(std::fs::read(&shim).unwrap(), b"mine");
    assert!(out["warnings"].to_string().contains("not a link"), "{out}");
}

#[test]
fn uninstall_removes_the_session_unit_and_keeps_the_binary() {
    if skip_as_root() {
        return;
    }
    let env = Env::new();
    let unit = env.run("install --binary --json").unwrap()["unit"].as_str().unwrap().to_owned();
    assert!(Path::new(&unit).exists());
    env.run("uninstall").unwrap();
    assert!(!Path::new(&unit).exists());
    assert!(env.binary().exists(), "the binary stays: cmux clients reuse it over SSH");
}
