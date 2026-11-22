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
        // systemd knows no cmux-server.service here (tests answer otherwise).
        env.runner.answer_always(
            "--property=LoadState",
            Output {
                code: Some(0),
                stdout: b"LoadState=not-found\nFragmentPath=\nTransient=no\n".to_vec(),
                ..Output::default()
            },
        );
        // launchd has no com.cmux.server loaded here.
        env.runner
            .answer_always("launchctl print", Output { code: Some(113), ..Output::default() });
        // Every unit systemd is asked about is stopped.
        env.runner.answer_always(
            "--property=ActiveState",
            Output { code: Some(0), stdout: b"inactive\n".to_vec(), ..Output::default() },
        );
        env.runner.answer_always(
            "--property=ControlGroup,TasksCurrent",
            Output {
                code: Some(0),
                stdout: b"ControlGroup=\nTasksCurrent=[not set]\n".to_vec(),
                ..Output::default()
            },
        );
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

#[cfg(unix)]
#[test]
fn a_file_planted_next_to_the_binary_is_never_written_through() {
    if skip_as_root() {
        return;
    }
    let env = Env::new();
    let bin = env.home().join(".local/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let victim = env.home().join("victim");
    std::fs::write(&victim, b"keep me").unwrap();
    // The temporary name an older build used: predictable from the pid.
    let planted = bin.join(format!(".cmux-tui.{}.tmp", std::process::id()));
    std::os::unix::fs::symlink(&victim, &planted).unwrap();
    env.run("install --binary --json").unwrap();
    assert_eq!(std::fs::read(&victim).unwrap(), b"keep me");
    assert_eq!(std::fs::read(env.binary()).unwrap(), std::fs::read(env.exe()).unwrap());
    assert!(std::fs::symlink_metadata(env.binary()).unwrap().is_file());
}

#[cfg(unix)]
#[test]
fn a_directory_others_can_write_to_is_refused() {
    use std::os::unix::fs::PermissionsExt as _;
    if skip_as_root() {
        return;
    }
    let env = Env::new();
    let bin = env.home().join(".local/bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o777)).unwrap();
    let err = env.run("install --binary --json").unwrap_err();
    assert!(format!("{err:?}").contains("chmod go-w"), "{err:?}");
    assert!(!env.binary().exists());
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    let unit = env.run("install --binary --json").unwrap()["unit"].as_str().unwrap().to_owned();
    let dir = Path::new(&unit).parent().unwrap().to_owned();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o757)).unwrap();
    let err = env.run("install --binary --json").unwrap_err();
    assert!(format!("{err:?}").contains("chmod go-w"), "{err:?}");
}

#[test]
fn a_unit_cmux_did_not_write_is_refused_and_left_alone() {
    if skip_as_root() {
        return;
    }
    let env = Env::new();
    let unit = env.run("install --binary --json").unwrap()["unit"].as_str().unwrap().to_owned();
    env.run("uninstall").unwrap();
    // A forged header alone does not make a unit cmux's: it must also run cmux.
    for mine in [
        "[Service]\nExecStart=/usr/local/bin/my-own-server\n",
        "# Generated by cmux. Do not edit.\n[Service]\nExecStart=/usr/local/bin/my-own-server\n",
    ] {
        std::fs::write(&unit, mine).unwrap();
        // A new build: the refusal must come before the binary is replaced.
        std::fs::write(env.exe(), b"#!/bin/sh\necho cmux build C\n").unwrap();
        let before = env.runner.lines().len();
        let err = env.run("install --binary --json").unwrap_err();
        assert!(format!("{err:?}").contains("not written by cmux"), "{err:?}");
        assert_eq!(std::fs::read_to_string(&unit).unwrap(), mine);
        assert_eq!(std::fs::read(env.binary()).unwrap(), b"#!/bin/sh\necho cmux build A\n");
        // Uninstall changes nothing either: no stop, no disable, no removal.
        let err = env.run("uninstall --purge --json").unwrap_err();
        assert!(format!("{err:?}").contains("nothing was changed"), "{err:?}");
        assert_eq!(std::fs::read_to_string(&unit).unwrap(), mine);
        assert!(env.binary().exists());
        let lines = env.runner.lines()[before..].join("\n");
        for verb in ["enable", "start", "disable", "kill", "bootout", "bootstrap", "daemon-reload"]
        {
            assert!(!lines.contains(verb), "{verb}: {lines}");
        }
        std::fs::write(env.exe(), b"#!/bin/sh\necho cmux build A\n").unwrap();
    }
}

#[cfg(target_os = "linux")]
#[test]
fn a_unit_systemd_loads_from_elsewhere_is_left_alone() {
    if skip_as_root() {
        return;
    }
    let env = Env::new();
    let elsewhere = || {
        Output {
        code: Some(0),
        stdout: b"LoadState=loaded\nFragmentPath=/usr/lib/systemd/user/cmux-server.service\nTransient=no\n"
            .to_vec(),
        ..Output::default()
    }
    };
    env.runner.answer("FragmentPath", elsewhere());
    let err = env.run("install --binary --json").unwrap_err();
    assert!(format!("{err:?}").contains("/usr/lib/systemd/user/cmux-server.service"), "{err:?}");
    assert!(!env.binary().exists(), "refused before the binary was placed");
    env.runner.answer("FragmentPath", elsewhere());
    assert!(env.run("uninstall --json").is_err());
    let lines = env.runner.lines().join("\n");
    assert!(!lines.contains("disable") && !lines.contains("enable "), "{lines}");
}

#[cfg(unix)]
#[test]
fn a_symlink_at_the_binary_path_is_replaced_by_a_file() {
    if skip_as_root() {
        return;
    }
    let env = Env::new();
    let elsewhere = env.home().join("elsewhere-cmux");
    std::fs::copy(env.exe(), &elsewhere).unwrap();
    std::fs::create_dir_all(env.binary().parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&elsewhere, env.binary()).unwrap();
    let out = env.run("install --binary --json").unwrap();
    assert_eq!(out["binary_changed"], true, "{out}");
    assert!(std::fs::symlink_metadata(env.binary()).unwrap().is_file());
    assert_eq!(std::fs::read(&elsewhere).unwrap(), std::fs::read(env.exe()).unwrap());
}

#[test]
fn install_user_leaves_linger_alone() {
    if skip_as_root() {
        return;
    }
    let env = Env::new();
    let out = env.run("install --binary --user --json").unwrap();
    assert_eq!(out["installed"], true, "{out}");
    let lines = env.runner.lines().join("\n");
    assert!(!lines.contains("enable-linger"), "{lines}");
    assert_eq!(env.run("install --user --system").unwrap_err().kind.code(), 2);
    assert_eq!(env.run("install --label studio").unwrap_err().kind.code(), 2);
}

#[test]
fn uninstall_says_what_stays_and_how_to_remove_it() {
    if skip_as_root() {
        return;
    }
    let env = Env::new();
    env.runner.answer(
        "show-user",
        Output { code: Some(0), stdout: b"yes\n".to_vec(), ..Output::default() },
    );
    env.run("install --binary").unwrap();
    env.runner.answer(
        "show-user",
        Output { code: Some(0), stdout: b"yes\n".to_vec(), ..Output::default() },
    );
    let out = env.run("uninstall --json").unwrap();
    let notes = out["notes"].to_string();
    assert!(notes.contains(&format!("rm {}", env.binary().display())), "{out}");
    if cfg!(target_os = "linux") {
        assert!(notes.contains("loginctl disable-linger"), "{out}");
    }
}

#[test]
fn logs_shows_the_service_log() {
    if skip_as_root() {
        return;
    }
    let env = Env::new();
    assert_eq!(env.run("logs --lines 0").unwrap_err().kind.code(), 2);
    assert_eq!(env.run("logs --lines many").unwrap_err().kind.code(), 2);
    if cfg!(target_os = "linux") {
        // Human output replaces this process with journalctl.
        let _ = env.run("logs --lines 5 --follow");
        let requests = env.exec.requests();
        let last = requests.last().expect("an exec");
        assert!(last.program.ends_with("journalctl"), "{last:?}");
        assert_eq!(
            last.args,
            ["--user", "--unit", "cmux-server.service", "--lines", "5", "--no-pager", "--follow"]
        );
    } else if cfg!(target_os = "macos") {
        let out = env.run("logs --json").unwrap();
        assert_eq!(out["lines"], serde_json::json!([]), "{out}");
    }
}
