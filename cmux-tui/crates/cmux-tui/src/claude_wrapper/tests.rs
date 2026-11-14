use std::os::unix::net::UnixListener;
use std::process::Output;

use super::*;

/// Converts string literals into owned OS arguments.
fn os(args: &[&str]) -> Vec<OsString> {
    args.iter().map(OsString::from).collect()
}

/// Writes an executable (0755) script, creating its parent directory.
fn write_executable(path: &Path, content: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    crate::test_exec::write_executable(path, content);
}

/// The permission bits of `path`.
fn mode(path: &Path) -> u32 {
    fs::metadata(path).unwrap().permissions().mode() & 0o777
}

/// Reads and parses a JSON file.
fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

/// A launcher's `--settings` file and an inline `--settings` fold into one private file that keeps both.
#[test]
fn claude_wrapper_merges_launcher_settings_with_the_hooks() {
    let root = tempfile::tempdir().unwrap();
    // A launcher prepends its own --settings file.
    let launcher = root.path().join("launcher-settings.json");
    fs::write(
            &launcher,
            r#"{"apiKeyHelper":"launcher-helper","env":{"A":"1"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"user-stop"}]}]}}"#,
        )
        .unwrap();
    let args = os(&[
        "--settings",
        launcher.to_str().unwrap(),
        "--model",
        "opus",
        r#"--settings={"theme":"dark","env":{"B":"2"}}"#,
        "--",
        "--settings",
        "literal",
    ]);
    let cache = root.path().join("cache");
    let hooks = session_hook_settings(None, Path::new("/opt/cmux/cmux-tui")).unwrap();
    let out = args_with_hooks(&args, hooks.clone(), &cache).unwrap();

    assert_eq!(out[0], "--settings");
    assert_eq!(out[2..], os(&["--model", "opus", "--", "--settings", "literal"]));
    let path = PathBuf::from(&out[1]);
    assert_eq!(mode(&path), 0o600);
    assert_eq!(mode(&cache), 0o700);
    let settings = read_json(&path);
    assert_eq!(settings["apiKeyHelper"], "launcher-helper");
    assert_eq!(settings["theme"], "dark");
    assert_eq!(settings["env"], serde_json::json!({"A":"1","B":"2"}));
    assert_eq!(settings["preferredNotifChannel"], "notifications_disabled");
    let stop = settings["hooks"]["Stop"].as_array().unwrap();
    assert_eq!(stop.len(), 2, "{stop:?}");
    assert_eq!(stop[0]["hooks"][0]["command"], "user-stop");
    assert_eq!(stop[1], hooks["hooks"]["Stop"][0]);
    for event in ["SessionStart", "UserPromptSubmit", "Notification", "SessionEnd"] {
        assert!(settings["hooks"][event].is_array(), "{event} missing");
    }

    let again = args_with_hooks(&args, hooks, &cache).unwrap();
    assert_eq!(again[1], out[1], "identical launches reuse one settings file");
    assert_eq!(fs::read_dir(&cache).unwrap().count(), 1);
}

/// Hook commands match `agent hook install`, or call `agent hook emit` without a helper.
#[test]
fn claude_wrapper_hook_commands_match_the_installed_hooks_or_fall_back_to_emit() {
    let installed = session_hook_settings(None, Path::new("/opt/cmux/cmux-tui")).unwrap();
    let command = installed["hooks"]["Stop"][0]["hooks"][0]["command"].as_str().unwrap();
    assert!(command.contains("\"${h:-:}\" 'claude' 'Stop'"), "{command}");
    assert_eq!(installed["hooks"]["Stop"][0]["hooks"][0]["async"], true);

    let emit = session_hook_settings(
        Some(Path::new("/opt/cmux tui/cmux-tui")),
        Path::new("/opt/cmux/cmux-tui"),
    )
    .unwrap();
    let command = emit["hooks"]["Stop"][0]["hooks"][0]["command"].as_str().unwrap();
    assert!(
            command.starts_with(
                "'/opt/cmux tui/cmux-tui' agent hook emit --source 'claude' --event 'Stop' >/dev/null 2>&1||:;echo {};"
            ),
            "{command}"
        );
    assert_eq!(
        emit["hooks"].as_object().unwrap().keys().collect::<Vec<_>>(),
        installed["hooks"].as_object().unwrap().keys().collect::<Vec<_>>()
    );
}

/// Every wrapped launch adds one more `SessionStart` hook, after the
/// installed ones: this build's `agent session-context`, which tells the
/// model it runs in cmux, its ids and `cmux skill show`.
#[test]
fn claude_wrapper_adds_the_session_context_hook_of_this_build() {
    let hooks = session_hook_settings(None, Path::new("/opt/cmux tui/cmux-tui")).unwrap();
    let groups = hooks["hooks"]["SessionStart"].as_array().unwrap();
    let commands = groups
        .iter()
        .flat_map(|group| group["hooks"].as_array().cloned().unwrap_or_default())
        .filter_map(|hook| hook["command"].as_str().map(str::to_owned))
        .collect::<Vec<_>>();
    assert_eq!(
        commands.iter().filter(|command| command.ends_with(" agent session-context")).count(),
        1,
        "{commands:?}"
    );
    assert_eq!(
        commands.last().map(String::as_str),
        Some("'/opt/cmux tui/cmux-tui' agent session-context")
    );
    assert!(commands.len() >= 2, "the installed SessionStart hook stays: {commands:?}");
    let last = groups.last().unwrap();
    assert_eq!(last["hooks"][0]["timeout"], 10);
    assert!(last["hooks"][0].get("async").is_none(), "Claude must read its output");
}

/// Unreadable or malformed `--settings` values fail so the launch proceeds without hooks.
#[test]
fn claude_wrapper_skips_injection_for_bad_settings_arguments() {
    let root = tempfile::tempdir().unwrap();
    let hooks = session_hook_settings(None, Path::new("/opt/cmux/cmux-tui")).unwrap();
    for args in [
        os(&["--model", "opus", "--settings"]),
        os(&["--settings", "/nonexistent/settings.json"]),
        os(&["--settings", "[1]"]),
        os(&["--settings={not json"]),
    ] {
        assert!(args_with_hooks(&args, hooks.clone(), root.path()).is_err(), "{args:?}");
    }
    // A non-UTF-8 `--settings=` value is still read, not passed through
    // after the merged file where it would win and drop the hooks.
    let non_utf8 = OsStr::from_bytes(b"--settings=/nonexistent/\xff.json").to_owned();
    assert!(args_with_hooks(&[non_utf8], hooks, root.path()).is_err());
}

/// Resolution skips the shim directory, copies of the shim, and links to it.
#[test]
fn claude_wrapper_resolves_the_real_claude_past_the_shim() {
    let root = tempfile::tempdir().unwrap();
    let executable = root.path().join("bin/cmux-tui");
    write_executable(&executable, "#!/bin/sh\n");
    let shim_dir = root.path().join("data/shims");
    install_shim(&shim_dir, &executable).unwrap();
    // A copy of the shim elsewhere on PATH, and a link back to it.
    let copied = root.path().join("copied");
    write_executable(&copied.join("claude"), &fs::read_to_string(shim_dir.join("claude")).unwrap());
    let linked = root.path().join("linked");
    fs::create_dir_all(&linked).unwrap();
    std::os::unix::fs::symlink(shim_dir.join("claude"), linked.join("claude")).unwrap();
    // A searchable directory named `claude` satisfies access(X_OK) but
    // cannot be executed as the Claude binary.
    let directory_candidate = root.path().join("directory-candidate");
    fs::create_dir_all(directory_candidate.join("claude")).unwrap();
    // An owned file with only the "other execute" bit set looks
    // executable to a bitmask check but is not executable by its owner.
    let inaccessible = root.path().join("inaccessible");
    fs::create_dir_all(&inaccessible).unwrap();
    fs::write(inaccessible.join("claude"), "#!/bin/sh\n").unwrap();
    fs::set_permissions(inaccessible.join("claude"), fs::Permissions::from_mode(0o001)).unwrap();
    let real = root.path().join("real");
    write_executable(&real.join("claude"), "#!/bin/sh\n");

    let path = std::env::join_paths([
        &shim_dir,
        &copied,
        &linked,
        &directory_candidate,
        &inaccessible,
        &real,
    ])
    .unwrap();
    assert_eq!(find_real_claude(&path, Some(shim_dir.as_path())), Some(real.join("claude")));
    assert_eq!(
        path_without_shims(&path, Some(shim_dir.as_path())),
        std::env::join_paths([&directory_candidate, &inaccessible, &real]).unwrap()
    );
    let only_shims = std::env::join_paths([&shim_dir, &copied]).unwrap();
    assert_eq!(find_real_claude(&only_shims, Some(shim_dir.as_path())), None);
}

/// Injection needs a live terminal and a session launch, and respects re-entry and the disable flag.
#[test]
fn claude_wrapper_injects_only_into_session_launches_in_a_live_terminal() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("mux.sock");
    let _listener = UnixListener::bind(&socket).unwrap();
    let env = |overrides: &'static [(&'static str, &'static str)]| {
        let socket = socket.clone();
        move |name: &str| -> Option<OsString> {
            if let Some((_, value)) = overrides.iter().find(|(key, _)| *key == name) {
                return Some(OsString::from(value));
            }
            match name {
                "CMUX_TUI_TERMINAL_ID" => Some("term_1".into()),
                "CMUX_TUI_SOCKET" => Some(socket.clone().into_os_string()),
                _ => None,
            }
        }
    };

    assert!(should_inject(&[], env(&[])));
    assert!(should_inject(&os(&["--model", "opus", "fix the bug"]), env(&[])));
    assert!(should_inject(&os(&["--resume"]), env(&[])));
    for args in [
        os(&["--version"]),
        os(&["-h"]),
        os(&["--model", "opus", "--help"]),
        os(&["mcp", "list"]),
        os(&["--verbose", "doctor"]),
        os(&["agents", "--json"]),
        os(&["daemon", "status"]),
    ] {
        assert!(!should_inject(&args, env(&[])), "{args:?} must pass through");
    }
    assert!(!should_inject(&[], env(&[(WRAPPER_ACTIVE_ENV, "1")])), "re-entry");
    assert!(!should_inject(&[], env(&[(HOOKS_DISABLED_ENV, "1")])), "disabled");
    assert!(!should_inject(&[], env(&[("CMUX_TUI_TERMINAL_ID", "")])), "no terminal");
    assert!(!should_inject(&[], env(&[("CMUX_TUI_SOCKET", "")])), "no socket");
    let missing = &[("CMUX_TUI_SOCKET", "/nonexistent/cmux-tui.sock")];
    assert!(!should_inject(&[], env(missing)), "dead socket");
}

/// Reuse restores private modes and refreshes the idle clock; idle copies are pruned.
#[test]
fn claude_wrapper_settings_cache_stays_private_and_prunes_idle_copies() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("settings");
    let data = br#"{"env":{"TOKEN":"x"}}"#;
    let now = SystemTime::now();
    let path = write_settings_file(&dir, data, now).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();

    let stale = dir.join("stale.json");
    let recent = dir.join("recent.json");
    let idle = now - SETTINGS_RETENTION - Duration::from_secs(3600);
    for (file, modified) in [(&stale, idle), (&recent, now), (&path, idle)] {
        if file != &path {
            fs::write(file, b"{}").unwrap();
        }
        fs::File::options().write(true).open(file).unwrap().set_modified(modified).unwrap();
    }

    assert_eq!(write_settings_file(&dir, data, now).unwrap(), path);
    assert_eq!(mode(&path), 0o600);
    assert_eq!(mode(&dir), 0o700);
    assert!(!stale.exists(), "idle copy was not pruned");
    assert!(recent.exists(), "recent copy was pruned");
    let modified = fs::metadata(&path).unwrap().modified().unwrap();
    assert!(modified >= now - Duration::from_secs(1), "reuse must refresh the idle clock");
}

/// Runs the shim script through `/bin/sh` with the given `PATH`.
fn run_shim(shim: &Path, path: &OsStr, args: &[&str]) -> Output {
    Command::new("/bin/sh").arg(shim).args(args).env("PATH", path).output().unwrap()
}

/// The shim execs the wrapper, rewrites idempotently, and falls back when the binary is gone.
#[test]
fn claude_wrapper_shim_execs_the_wrapper_and_falls_back_to_the_real_claude() {
    let root = tempfile::tempdir().unwrap();
    let executable = root.path().join("cmux tui/cmux-tui");
    write_executable(&executable, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
    let shim_dir = root.path().join("data/shims");
    let shim = install_shim(&shim_dir, &executable).unwrap();
    assert_eq!(shim, shim_dir.join("claude"));
    assert_eq!(mode(&shim), 0o700);
    assert_eq!(mode(&shim_dir), 0o700);
    let script = fs::read_to_string(&shim).unwrap();
    assert!(script.starts_with(&format!("#!/bin/sh\n{SHIM_MARKER}\n")), "{script}");
    assert!(is_claude_shim(&shim));

    fs::set_permissions(&shim, fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(install_shim(&shim_dir, &executable).unwrap(), shim);
    assert_eq!(fs::read_to_string(&shim).unwrap(), script, "rewrite is idempotent");
    assert_eq!(mode(&shim), 0o700);

    let real = root.path().join("real");
    write_executable(&real.join("claude"), "#!/bin/sh\nprintf 'real %s|%s\\n' \"$*\" \"$PATH\"\n");
    let path = std::env::join_paths([
        shim_dir.as_path(),
        real.as_path(),
        Path::new("/usr/bin"),
        Path::new("/bin"),
    ])
    .unwrap();
    let output = run_shim(&shim, &path, &["--model", "a b"]);
    assert!(output.status.success(), "{output:?}");
    assert_eq!(String::from_utf8_lossy(&output.stdout), "agent\nclaude-wrapper\n--model\na b\n");

    fs::remove_file(&executable).unwrap();
    let output = run_shim(&shim, &path, &["--model", "a b"]);
    assert!(output.status.success(), "{output:?}");
    let expected_path = format!("{}:/usr/bin:/bin", real.display());
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        format!("real --model a b|{expected_path}\n")
    );
}

/// The pane PATH starts with the shim directory exactly once.
#[test]
fn claude_wrapper_pane_path_puts_the_shim_first_once() {
    let shim = Path::new("/data/cmux-tui/shims");
    assert_eq!(
        path_with_shim_first(OsStr::new("/usr/bin:/data/cmux-tui/shims:/bin"), shim).unwrap(),
        "/data/cmux-tui/shims:/usr/bin:/bin"
    );
    assert_eq!(path_with_shim_first(OsStr::new(""), shim).unwrap(), "/data/cmux-tui/shims");
}

/// Only `agent claude-wrapper` argv selects the wrapper.
#[test]
fn claude_wrapper_invocation_selects_only_the_hidden_verb() {
    let args = os(&["agent", "claude-wrapper", "--settings", "x"]);
    assert_eq!(invocation(&args), Some(&args[2..]));
    assert_eq!(invocation(&os(&["agent", "claude-wrapper"])), Some(&[][..]));
    assert_eq!(invocation(&os(&["agent", "list"])), None);
    assert_eq!(invocation(&os(&["claude-wrapper"])), None);
}
