//! A `claude` launch in a cmux-tui pane runs in the user's project, so a
//! relative `XDG_DATA_HOME` (a quoted `"~/.local/share"` in a shell rc) must
//! not put the wrapper's settings under the project (#18468).
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixListener;
use std::process::Command;

#[test]
fn cmux_next_claude_launch_ignores_a_relative_xdg_data_home() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let project = root.path().join("project");
    let bin = root.path().join("bin");
    for dir in [&home, &project, &bin] {
        fs::create_dir_all(dir).unwrap();
    }
    let received = root.path().join("claude-args");
    let claude = bin.join("claude");
    fs::write(&claude, format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\n", received.display()))
        .unwrap();
    fs::set_permissions(&claude, fs::Permissions::from_mode(0o755)).unwrap();
    let socket = root.path().join("mux.sock");
    let _listener = UnixListener::bind(&socket).unwrap();

    let status = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["agent", "claude-wrapper", "fix the bug"])
        .current_dir(&project)
        .env("HOME", &home)
        .env("XDG_DATA_HOME", "~/.local/share")
        .env("PATH", &bin)
        .env("CMUX_TUI_SOCKET", &socket)
        .env("CMUX_TUI_TERMINAL_ID", "term_1")
        .env_remove("CMUX_TUI_HOOK")
        .env_remove("CMUX_TUI_CLAUDE_WRAPPER_ACTIVE")
        .env_remove("CMUX_TUI_CLAUDE_HOOKS_DISABLED")
        .status()
        .unwrap();
    assert!(status.success());

    let args = fs::read_to_string(&received).unwrap();
    assert!(args.lines().any(|arg| arg == "--settings"), "hooks were not injected: {args}");
    let leaked: Vec<_> =
        fs::read_dir(&project).unwrap().map(|entry| entry.unwrap().path()).collect();
    assert!(leaked.is_empty(), "the launch wrote into the project: {leaked:?}");
    let settings = home.join(".local/share/cmux-tui/claude-settings");
    assert!(fs::read_dir(&settings).is_ok_and(|mut dir| dir.next().is_some()), "{settings:?}");
}
