//! `cmux agent hook install codex` and the Cloud devbox shell-start merge
//! (web/services/vms/images/devbox/agent-config.sh) both rewrite
//! `~/.codex/config.toml`: the installer adds the hook trust state, the merge
//! adds the cmux model provider. Both take a flock on
//! `~/.codex/config.toml.cmux-lock` for their read-modify-rename, so neither
//! write is built on a read the other one replaced.
//!
//! The test plays the shell merge: it holds the lock, starts a real install,
//! sees that the install does not finish while the lock is held, writes the
//! provider block as the merge would, and releases. The install must then keep
//! the provider block and add its trust state.

#![cfg(unix)]

use std::os::fd::AsRawFd as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use wait_timeout::ChildExt as _;

/// The cmux-tui binary, linked into a folder of its own (see muse_agent_hooks.rs:
/// the install then writes the launcher that re-enters cmux-tui).
fn cli() -> &'static Path {
    static CLI: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    CLI.get_or_init(|| {
        let dir = tempfile::Builder::new().prefix("cmux-cfglock-cli").tempdir().unwrap().keep();
        let path = dir.join("cmux-tui");
        let original = Path::new(env!("CARGO_BIN_EXE_cmux-tui"));
        if std::fs::hard_link(original, &path).is_err() {
            std::fs::copy(original, &path).unwrap();
        }
        path
    })
}

/// Kills and reaps the install if the test panics before it exits, so no
/// writer outlives the temp HOME the test deletes.
struct Reap(Option<std::process::Child>);

impl Drop for Reap {
    fn drop(&mut self) {
        if let Some(mut child) = self.0.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

#[test]
fn codex_hook_install_waits_for_the_config_lock_and_keeps_the_provider_merge() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let codex = home.join(".codex");
    std::fs::create_dir_all(&codex).unwrap();
    let config = codex.join("config.toml");
    std::fs::write(&config, "# user settings\n").unwrap();

    let lock = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(codex.join("config.toml.cmux-lock"))
        .unwrap();
    // SAFETY: flock on a descriptor this test owns.
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);

    let install = Command::new(cli())
        .args(["--json", "agent", "hook", "install", "codex"])
        .env("HOME", &home)
        .env_remove("CODEX_HOME")
        .env_remove("XDG_CONFIG_HOME")
        .env_remove("XDG_DATA_HOME")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_SOCKET_PATH")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut install = Reap(Some(install));
    let child = install.0.as_mut().unwrap();

    // An unlocked install finishes in well under a second; one that waits for
    // the lock cannot finish at all while it is held. Load can only make an
    // unlocked install look like a waiting one, never the reverse.
    let early = child.wait_timeout(Duration::from_secs(5)).unwrap();
    if early.is_some() {
        let output = install.0.take().unwrap().wait_with_output().unwrap();
        panic!("the install wrote config.toml while another writer held the lock: {output:?}");
    }
    assert_eq!(std::fs::read_to_string(&config).unwrap(), "# user settings\n");

    // What the shell merge writes under the lock: the provider around the old text.
    let merged =
        "model_provider = \"cmux\"\n\n# user settings\n\n[model_providers.cmux]\nname = \"cmux\"\n";
    std::fs::write(&config, merged).unwrap();
    drop(lock);

    let child = install.0.as_mut().unwrap();
    let status = child.wait_timeout(Duration::from_secs(120)).unwrap();
    if status.is_none() {
        let _ = child.kill();
    }
    let output = install.0.take().unwrap().wait_with_output().unwrap();
    assert!(output.status.success(), "{output:?}");

    let text = std::fs::read_to_string(&config).unwrap();
    let parsed: toml::Table = text.parse().unwrap();
    assert_eq!(parsed.get("model_provider").and_then(toml::Value::as_str), Some("cmux"), "{text}");
    assert!(parsed.get("model_providers").and_then(|p| p.get("cmux")).is_some(), "{text}");
    assert!(text.contains("# user settings"), "{text}");
    let state = parsed
        .get("hooks")
        .and_then(|hooks| hooks.get("state"))
        .and_then(toml::Value::as_table)
        .unwrap_or_else(|| panic!("no hooks.state in {text}"));
    let hooks_json = codex.join("hooks.json");
    assert!(
        state.keys().any(|key| key.starts_with(&format!("{}:", hooks_json.display()))),
        "no trust entry for {} in {text}",
        hooks_json.display()
    );
}
