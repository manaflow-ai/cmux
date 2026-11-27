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

/// Launches `claude ARGS` through the wrapper as `sr2 claude` would, with the person's default
/// chat harness `claude-sr2` naming `--autocompact 157125`, and returns Claude's arguments.
fn launched_args(root: &Path, args: &[&str], env: &[(&str, &str)]) -> Vec<String> {
    let home = root.join("home");
    let bin = root.join("bin");
    let acpmux = root.join("acpmux");
    let harnesses = root.join("config").join(cmux_config::NEXT_DIR).join("harnesses");
    for dir in [&home, &bin, &acpmux, &harnesses, &home.join(".claude")] {
        fs::create_dir_all(dir).unwrap();
    }
    fs::write(acpmux.join("config.json"), r#"{"defaultHarness":"claude-sr2"}"#).unwrap();
    fs::write(
        harnesses.join("claude-sr2.toml"),
        "schema = 1\nid = \"claude-sr2\"\nname = \"Claude (sr2)\"\nprotocol = \"claude-stdio\"\n\
         command = \"/bin/sr2\"\nargs = [\"claude2\", \"--autocompact\", \"157125\"]\n",
    )
    .unwrap();
    let received = root.join("claude-args");
    let claude = bin.join("claude");
    fs::write(&claude, format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\n", received.display()))
        .unwrap();
    fs::set_permissions(&claude, fs::Permissions::from_mode(0o755)).unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .args(["agent", "claude-wrapper"])
        .args(args)
        .current_dir(&home)
        .env_clear()
        .env("HOME", &home)
        .env("PATH", &bin)
        .env("ACPMUX_HOME", &acpmux)
        .env("XDG_CONFIG_HOME", root.join("config"))
        .env("SR2_CLAUDE2_HOOK_SOCKET", "/tmp/sr2-claude2-7/hook.sock");
    for (key, value) in env {
        command.env(key, value);
    }
    let output = command.output().unwrap();
    assert!(output.status.success(), "{output:?}");
    fs::read_to_string(&received).unwrap().lines().map(str::to_owned).collect()
}

/// Leo 2026-11-25, of a Claude Code CLI session in a cmux terminal: "for claude code cli
/// sessions e.g. kumquat do our fixes get in? for efficiency. i hope it does. it's still at
/// 400k it seems like". `sr2 claude` prepends its own 380k-420k draw; the terminal now compacts
/// where the person's agent chats do.
#[test]
fn a_terminal_claude_compacts_where_the_persons_chats_do() {
    let sr2 = [
        "--autocompact",
        "385829",
        "--settings",
        "/tmp/sr2-claude2-7/settings.json",
        "--resume",
        "6e0bad7d",
    ];
    let root = tempfile::tempdir().unwrap();
    let args = launched_args(root.path(), &sr2, &[]);
    assert_eq!(
        args,
        [
            "--autocompact",
            "157125",
            "--settings",
            "/tmp/sr2-claude2-7/settings.json",
            "--resume",
            "6e0bad7d"
        ]
    );

    // A plain `claude` gets it first.
    let root = tempfile::tempdir().unwrap();
    let args = launched_args(root.path(), &["fix the bug"], &[]);
    assert_eq!(args, ["--autocompact", "157125", "fix the bug"]);

    // The person's own flag after sr2's, or their env, still wins.
    let root = tempfile::tempdir().unwrap();
    let mut typed = sr2.to_vec();
    typed.extend(["--autocompact", "300000"]);
    assert_eq!(launched_args(root.path(), &typed, &[]), typed);
    let root = tempfile::tempdir().unwrap();
    let own = [("CLAUDE_CODE_AUTO_COMPACT_WINDOW", "500000")];
    assert_eq!(launched_args(root.path(), &sr2, &own), sr2);
}
