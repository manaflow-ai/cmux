//! A `claude` started in a cmux terminal gets what an agent chat's Claude gets (Leo
//! 2026-11-24: "in terminals and guis alike perhaps terminal simply needs to also have the fixes
//! and enhancements"): acpmux's Claude knobs, its autocompact window, and Claude Code's own
//! wait through a 529 outage, which stands in for the chat's capacity continuation. The
//! person's own values win.
#![cfg(unix)]

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::Path;
use std::process::Command;

/// Launches `claude` through the wrapper with `env` on top of a clean one and returns the
/// environment the (fake) Claude saw.
fn launched_env(root: &Path, env: &[(&str, &str)]) -> BTreeMap<String, String> {
    let home = root.join("home");
    let project = root.join("project");
    let bin = root.join("bin");
    for dir in [&home, &project, &bin, &home.join(".claude")] {
        fs::create_dir_all(dir).unwrap();
    }
    let received = root.join("claude-env");
    let claude = bin.join("claude");
    // `PATH` is only `bin`, so the fake names `env` by its full path.
    fs::write(&claude, format!("#!/bin/sh\n/usr/bin/env > '{}'\n", received.display())).unwrap();
    fs::set_permissions(&claude, fs::Permissions::from_mode(0o755)).unwrap();

    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .args(["agent", "claude-wrapper", "fix the bug"])
        .current_dir(&project)
        .env_clear()
        .env("HOME", &home)
        .env("PATH", &bin);
    for (key, value) in env {
        command.env(key, value);
    }
    let output = command.output().unwrap();
    assert!(output.status.success(), "{output:?}");
    fs::read_to_string(&received)
        .unwrap()
        .lines()
        .filter_map(|line| line.split_once('='))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

#[test]
fn a_terminal_claude_waits_out_a_529_and_gets_the_chats_knobs() {
    let root = tempfile::tempdir().unwrap();
    let env = launched_env(root.path(), &[]);
    for (key, value) in acpmux::harness_limits::CLAUDE_ENV
        .iter()
        .chain(acpmux::harness_limits::CLAUDE_TERMINAL_ENV)
        .chain([&acpmux::harness_limits::CLAUDE_AUTOCOMPACT_WINDOW])
    {
        assert_eq!(env.get(*key).map(String::as_str), Some(*value), "{key}: {env:?}");
    }
    assert_eq!(env.get("CLAUDE_CODE_RETRY_WATCHDOG_SCOPE").map(String::as_str), Some("capacity"));
}

#[test]
fn a_terminal_claude_keeps_the_persons_own_values() {
    let root = tempfile::tempdir().unwrap();
    let env = launched_env(
        root.path(),
        &[
            ("CLAUDE_CODE_MAX_RETRIES", "5"),
            ("CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY", "4"),
            ("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "80"),
        ],
    );
    // Their own retry choice decides: none of the capacity wait is added on top of it.
    assert_eq!(env["CLAUDE_CODE_MAX_RETRIES"], "5");
    for (key, _) in acpmux::harness_limits::CLAUDE_TERMINAL_ENV {
        assert!(!env.contains_key(*key), "{key}: {env:?}");
    }
    assert_eq!(env["CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY"], "4");
    assert!(!env.contains_key("CLAUDE_CODE_AUTO_COMPACT_WINDOW"), "{env:?}");
}

#[test]
fn a_terminal_claude_keeps_an_autocompact_its_settings_chose() {
    let root = tempfile::tempdir().unwrap();
    let settings = root.path().join("home/.claude");
    fs::create_dir_all(&settings).unwrap();
    fs::write(settings.join("settings.json"), r#"{"autoCompactWindow":200000}"#).unwrap();
    let env = launched_env(root.path(), &[]);
    assert!(!env.contains_key("CLAUDE_CODE_AUTO_COMPACT_WINDOW"), "{env:?}");
    assert_eq!(env["CLAUDE_CODE_RETRY_WATCHDOG"], "1");
}
