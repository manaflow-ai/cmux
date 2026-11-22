//! Two cmux-tui installs on one machine (the npm package, the app bundle, a
//! dev build) share the user's XDG data home. A pane of one daemon must run
//! the `claude` wrapper and the agent hook helper of that daemon's own build,
//! never the copy another build wrote last, and never an older helper that
//! some install placed at the shared `cmux-tui/bin/cmux-tui-hook` path.
//!
//! Each "build" here is this test binary under its own path, with a
//! recording `cmux-tui-hook` beside it, so every hook call names the build
//! whose helper ran.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[path = "support/private_state.rs"]
mod private_state;

fn unique_root() -> PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("cmux-ob-{}-{stamp}-{n}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    // macOS /tmp is a symlink; the daemon resolves its own path.
    root.canonicalize().unwrap()
}

/// Writes `contents` as an executable file through a short-lived `sh`, so no
/// fork of this test process holds a write descriptor to it (ETXTBSY).
fn write_executable(path: &Path, contents: &str) {
    let mut child = Command::new("/bin/sh")
        .args(["-c", "cat > \"$1\" && chmod 755 \"$1\"", "sh"])
        .arg(path)
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(contents.as_bytes()).unwrap();
    assert!(child.wait().unwrap().success(), "write {}", path.display());
}

/// A copy of this build under `dir`, as a second install would place it.
fn install_build(dir: &Path, name: &str, hook_log: &Path) -> PathBuf {
    fs::create_dir_all(dir).unwrap();
    let exe = dir.join("cmux-tui");
    let source = env!("CARGO_BIN_EXE_cmux-tui");
    if fs::hard_link(source, &exe).is_err() {
        fs::copy(source, &exe).unwrap();
    }
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o755)).unwrap();
    write_executable(
        &dir.join("cmux-tui-hook"),
        &format!("#!/bin/sh\nprintf '%s %s\\n' '{name}' \"$*\" >> '{}'\n", hook_log.display()),
    );
    exe
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    exe: PathBuf,
    terminals: Vec<(String, String)>,
    surfaces: Vec<(String, u64)>,
}

impl Daemon {
    /// Starts `exe` for `session` with the user's shared `home` and `data`.
    fn start(root: &Path, exe: &Path, session: &str, home: &Path, data: &Path, path: &str) -> Self {
        let dir = root.join(format!("daemon-{session}"));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("s.sock");
        let config = dir.join("config.json");
        let mut command = Command::new(exe);
        command
            .args(["--headless", "--session", session, "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("HOME", home)
            .env("XDG_DATA_HOME", data)
            .env("PATH", path)
            .env("SHELL", "/bin/sh")
            .env("CMUX_TUI_SHELL_INTEGRATION", "none")
            .env("CMUX_TUI_CONFIG", &config)
            .env("CMUX_TUI_HOST_EXE_DIR", dir.join("host-exe"))
            .env_remove("CMUX_TUI_HOOK")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_TUI_AGENT_SHIMS")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .env_remove("CMUX_BUNDLED_CLI_PATH")
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        private_state::use_private_state(&mut command, &dir);
        let child = command.spawn().unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        while UnixStream::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "{session} never served {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, exe: exe.to_path_buf(), terminals: Vec::new(), surfaces: Vec::new() }
    }

    fn request(&self, value: serde_json::Value) -> serde_json::Value {
        let stream = UnixStream::connect(&self.socket).unwrap();
        let mut writer = stream.try_clone().unwrap();
        writeln!(writer, "{value}").unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        let response: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["ok"], true, "request failed: {response}");
        response["data"].clone()
    }

    /// Waits until the server answers lifecycle commands (`server status`):
    /// its socket accepts before that, and status then says "still starting".
    /// The server's own `lifecycle_ready` flag is the signal, as in cli.rs.
    fn wait_for_lifecycle_ready(&self) {
        let deadline = Instant::now() + Duration::from_secs(30);
        while self.request(serde_json::json!({"id": 3, "cmd": "identify"}))["lifecycle_ready"]
            != true
        {
            assert!(
                Instant::now() < deadline,
                "{} never became lifecycle-ready",
                self.exe.display()
            );
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    /// Runs `script` (sh) in a new terminal named `name`, with `OB_TAG` set
    /// to `name` for the fake `claude`; returns `name`.
    fn run(&mut self, name: &str, script: &str) -> String {
        let script = format!("OB_TAG='{name}'; export OB_TAG; {script}");
        let created = self.request(serde_json::json!({
            "id": 1, "cmd": "run", "argv": ["/bin/sh", "-c", script],
            "new_workspace": true, "name": name, "cols": 100, "rows": 20,
        }));
        let terminal = created["terminal_id"].as_str().unwrap().to_owned();
        let incarnation = created["terminal_incarnation"].as_str().unwrap().to_owned();
        self.terminals.push((terminal, incarnation));
        if let Some(surface) = created["surface"].as_u64() {
            self.surfaces.push((name.to_owned(), surface));
        }
        name.to_owned()
    }

    /// The screen of the terminal named `name`, for a failure message.
    fn screen(&self, name: &str) -> String {
        let Some(&(_, surface)) = self.surfaces.iter().find(|(tag, _)| tag == name) else {
            return String::from("(no surface)");
        };
        let Ok(stream) = UnixStream::connect(&self.socket) else { return String::new() };
        let mut writer = stream.try_clone().unwrap();
        let read = serde_json::json!({"id": 2, "cmd": "read-screen", "surface": surface});
        let _ = writeln!(writer, "{read}");
        let mut line = String::new();
        let _ = BufReader::new(stream).read_line(&mut line);
        serde_json::from_str::<serde_json::Value>(&line)
            .ok()
            .and_then(|response| response["data"]["text"].as_str().map(str::to_owned))
            .unwrap_or(line)
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        for (terminal, incarnation) in std::mem::take(&mut self.terminals) {
            let _ = UnixStream::connect(&self.socket).map(|mut stream| {
                let close = serde_json::json!({"id": 9, "cmd": "close-terminal",
                    "terminal_id": terminal, "terminal_incarnation": incarnation});
                let _ = writeln!(stream, "{close}");
                let _ = BufReader::new(stream).read_line(&mut String::new());
            });
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// What the fake `claude` recorded in the terminal named `tag`, once it ran.
fn launch_record(root: &Path, daemon: &Daemon, tag: &str) -> (String, serde_json::Value) {
    let path = root.join(format!("claude-{tag}.txt"));
    let deadline = Instant::now() + Duration::from_secs(30);
    while !path.exists() {
        assert!(Instant::now() < deadline, "claude never ran in {tag}: {}", daemon.screen(tag));
        std::thread::sleep(Duration::from_millis(50));
    }
    let text = fs::read_to_string(&path).unwrap();
    let field = |name: &str| {
        text.lines()
            .find_map(|line| line.strip_prefix(&format!("{name}=")))
            .unwrap_or_default()
            .to_owned()
    };
    let settings = field("SETTINGS");
    assert!(!settings.is_empty(), "the wrapper passed no --settings: {text}");
    let settings = serde_json::from_slice(&fs::read(&settings).unwrap()).unwrap();
    (field("HOOK"), settings)
}

/// Every hook command of `event` in a Claude settings file.
fn hook_commands(settings: &serde_json::Value, event: &str) -> Vec<String> {
    settings["hooks"][event]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|group| group["hooks"].as_array().into_iter().flatten())
        .filter_map(|hook| hook["command"].as_str().map(str::to_owned))
        .collect()
}

#[test]
fn own_build_wrapper_and_hook_serve_each_daemons_panes() {
    let root = unique_root();
    let home = root.join("home");
    let data = root.join("data");
    let fakebin = root.join("fakebin");
    for dir in [&home, &data, &fakebin] {
        fs::create_dir_all(dir).unwrap();
    }
    let hook_log = root.join("hook.log");
    // An older install's helper at the shared path (the app writes one that
    // execs its own bundled CLI): no pane of these builds may run it.
    let shared_helper = data.join("cmux-tui/bin/cmux-tui-hook");
    fs::create_dir_all(shared_helper.parent().unwrap()).unwrap();
    write_executable(
        &shared_helper,
        &format!("#!/bin/sh\nprintf 'shared %s\\n' \"$*\" >> '{}'\n", hook_log.display()),
    );
    // The real `claude`: records what the wrapper gave it, then runs the
    // hook helper the way Claude Code runs a hook command.
    write_executable(
        &fakebin.join("claude"),
        &format!(
            "#!/bin/sh\nsettings=\nwhile [ $# -gt 0 ]; do [ \"$1\" = --settings ] && settings=$2; shift; done\n\
             \"$CMUX_TUI_HOOK\" claude SessionStart < /dev/null\n\
             out='{}/claude-'\"$OB_TAG\".txt\n\
             printf 'HOOK=%s\\nSETTINGS=%s\\n' \"$CMUX_TUI_HOOK\" \"$settings\" > \"$out.tmp\"\n\
             mv \"$out.tmp\" \"$out\"\n",
            root.display()
        ),
    );
    let user_helper = root.join("user-hook");
    write_executable(
        &user_helper,
        &format!("#!/bin/sh\nprintf 'user %s\\n' \"$*\" >> '{}'\n", hook_log.display()),
    );
    let path = format!("{}:/usr/bin:/bin", fakebin.display());
    let exe_a = install_build(&root.join("build-a"), "build-a", &hook_log);
    let exe_b = install_build(&root.join("build-b"), "build-b", &hook_log);

    // Both run at once; b starts last, as the last writer of shared files.
    let mut a = Daemon::start(&root, &exe_a, "ob-a", &home, &data, &path);
    let mut b = Daemon::start(&root, &exe_b, "ob-b", &home, &data, &path);
    let in_a = a.run("ob-a", "claude hi; sleep 600");
    let in_b = b.run("ob-b", "claude hi; sleep 600");
    // A hook the person sets for one launch is kept.
    let user_in_a = a.run(
        "ob-a-user",
        &format!("CMUX_TUI_HOOK='{}' claude hi; sleep 600", user_helper.display()),
    );

    for (daemon, terminal, own, other) in [(&a, &in_a, &exe_a, &exe_b), (&b, &in_b, &exe_b, &exe_a)]
    {
        let (hook, settings) = launch_record(&root, daemon, terminal);
        assert_ne!(Path::new(&hook), shared_helper, "{terminal} ran the shared helper");
        let session_start = hook_commands(&settings, "SessionStart").join("\n");
        let own_text = own.display().to_string();
        let other_text = other.display().to_string();
        assert!(
            session_start.contains(&own_text) && !session_start.contains(&other_text),
            "{terminal} of {} ran another build's claude wrapper: {session_start}",
            daemon.exe.display()
        );
    }
    let (hook, _) = launch_record(&root, &a, &user_in_a);
    assert_eq!(Path::new(&hook), user_helper, "the wrapper replaced the person's CMUX_TUI_HOOK");

    let log = fs::read_to_string(&hook_log).unwrap_or_default();
    let mut lines: Vec<&str> = log.lines().collect();
    lines.sort_unstable();
    assert_eq!(
        lines,
        ["build-a claude SessionStart", "build-b claude SessionStart", "user claude SessionStart"],
        "each pane's hook must be its own build's helper (or the person's): {log}"
    );
    // The new builds leave the shared per-user shim folder alone.
    assert!(!data.join("cmux-tui/shims/claude").exists(), "a build wrote the shared claude shim");
    drop(a);
    drop(b);
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn own_build_status_says_where_it_looked_for_screen_detection() {
    let root = unique_root();
    let home = root.join("home");
    let data = root.join("data");
    for dir in [&home, &data] {
        fs::create_dir_all(dir).unwrap();
    }
    // A build without the plugin beside it, as the round 3 bench binary was.
    let exe = install_build(&root.join("build-s"), "build-s", &root.join("hook.log"));
    let daemon = Daemon::start(&root, &exe, "ob-s", &home, &data, "/usr/bin:/bin");
    let cli = |cli: &Path, verb: &str| {
        Command::new(cli)
            .args(["--json", "server", verb, "--session", "ob-s", "--socket"])
            .arg(&daemon.socket)
            .env("HOME", &home)
            .env("XDG_DATA_HOME", &data)
            .env("CMUX_TUI_CONFIG", root.join("daemon-ob-s/config.json"))
            .env("LC_ALL", "C")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET")
            .output()
            .unwrap()
    };
    daemon.wait_for_lifecycle_ready();
    let status = |build: &Path| -> serde_json::Value {
        let output = cli(build, "status");
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        serde_json::from_slice(&output.stdout).unwrap()
    };
    // Another build's CLI reports the daemon's own folder, not its own.
    let missing = status(Path::new(env!("CARGO_BIN_EXE_cmux-tui")));
    let detection = &missing["screen_detection"];
    assert_eq!(detection["state"], "not-installed", "{missing}");
    let expected = root.join("build-s/cmux-agent-screen-detection").display().to_string();
    assert!(
        detection["looked_in"]
            .as_array()
            .is_some_and(|paths| paths.iter().any(|p| p == &*expected)),
        "{detection}"
    );
    let message = detection["message"].as_str().unwrap_or_default();
    assert!(message.starts_with("screen detection: not installed (looked in "), "{message}");
    // Once the plugin is there, status says it runs from there.
    let plugin = root.join("build-s/cmux-agent-screen-detection");
    write_executable(&plugin, "#!/bin/sh\nexit 0\n");
    let installed = status(&exe);
    assert_eq!(installed["screen_detection"]["state"], "installed", "{installed}");
    assert_eq!(installed["screen_detection"]["path"], plugin.display().to_string());
    drop(daemon);
    let _ = fs::remove_dir_all(&root);
}

/// W5-Q (bench round 4 orchestration #3): every pane names this daemon's
/// own `cmux` in `CMUX_TUI_CLI`, an absolute path that runs this build as
/// `cmux` (the `cmux` on PATH can be an older install without `skill
/// show`). A build whose file is `cmux-tui` gets a `cmux` link of its own; a
/// build with a `cmux` beside it that is the same file uses that one.
#[test]
fn w5q_pane_env_names_this_builds_cmux() {
    let root = unique_root();
    let home = root.join("home");
    let data = root.join("data");
    for dir in [&home, &data] {
        fs::create_dir_all(dir).unwrap();
    }
    let log = root.join("hook.log");
    // The npm shape: only `cmux-tui`.
    let bare = install_build(&root.join("build-bare"), "build-bare", &log);
    // The app shape: `cmux` and `cmux-tui` are one file.
    let paired = install_build(&root.join("build-pair"), "build-pair", &log);
    let sibling = root.join("build-pair/cmux");
    std::os::unix::fs::symlink(&paired, &sibling).unwrap();

    for (exe, session) in [(&bare, "ob-cli-bare"), (&paired, "ob-cli-pair")] {
        let mut daemon = Daemon::start(&root, exe, session, &home, &data, "/usr/bin:/bin");
        let out = root.join(format!("{session}.txt"));
        let tag = daemon.run(
            session,
            &format!(
                "printf '%s\\n' \"$CMUX_TUI_CLI\" > '{out}.tmp'; \
                 \"$CMUX_TUI_CLI\" skill show 2>&1 | head -3 >> '{out}.tmp'; mv '{out}.tmp' '{out}'; \
                 sleep 600",
                out = out.display()
            ),
        );
        let deadline = Instant::now() + Duration::from_secs(30);
        while !out.exists() {
            assert!(Instant::now() < deadline, "{tag} never wrote: {}", daemon.screen(&tag));
            std::thread::sleep(Duration::from_millis(50));
        }
        let text = fs::read_to_string(&out).unwrap();
        let cli = PathBuf::from(text.lines().next().unwrap_or_default());
        assert!(cli.is_absolute(), "{session}: CMUX_TUI_CLI is not an absolute path: {text:?}");
        assert_eq!(
            cli.file_name().and_then(|name| name.to_str()),
            Some("cmux"),
            "{session}: CMUX_TUI_CLI must run this build as `cmux`: {text:?}"
        );
        assert_eq!(
            fs::canonicalize(&cli).ok(),
            fs::canonicalize(exe).ok(),
            "{session}: CMUX_TUI_CLI runs another build: {text:?}"
        );
        if exe == &paired {
            assert_eq!(cli, sibling, "the build's own `cmux` beside it is the one: {text:?}");
        }
        // The bench's old `cmux` said `unknown resource scope "skill"`.
        assert!(
            text.lines().count() > 1 && !text.contains("unknown"),
            "{session}: `$CMUX_TUI_CLI skill show` failed: {text:?}"
        );
        drop(daemon);
    }
    let _ = fs::remove_dir_all(&root);
}

/// A terminal an older build started keeps the shared shim folder
/// (`<data>/cmux-tui/shims`) in `CMUX_TUI_AGENT_SHIMS` and first on PATH for
/// as long as it lives: terminal hosts outlive app updates, so such terminals
/// run for days next to a new daemon. That folder's `claude` names whichever
/// build wrote it last; once that build is gone (a deleted dev build), the
/// shim silently started the real Claude with no hooks and no cmux tools.
/// A new daemon rewrites the shared shims to start the agent through the
/// terminal's own cmux, here the app's bundled CLI (the terminal has no
/// `CMUX_TUI_CLI`), also behind the person's `claude` shell function and a
/// launcher that execs `claude` with its own `--settings` (as `claude-sr2`).
#[test]
fn shared_shim_of_a_gone_build_starts_claude_through_the_terminals_own_cmux() {
    let root = unique_root();
    let home = root.join("home");
    let data = root.join("data");
    let fakebin = root.join("fakebin");
    let launcher = root.join("launcher");
    for dir in [&home, &data, &fakebin, &launcher] {
        fs::create_dir_all(dir).unwrap();
    }
    let settings_file = home.join(".config/cmux/cmux-next.json");
    fs::create_dir_all(settings_file.parent().unwrap()).unwrap();
    fs::write(&settings_file, "{\"agents.cmuxMcp\": \"on\"}\n").unwrap();
    let hook_log = root.join("hook.log");
    // The real `claude`: records its hook helper, the merged settings and
    // whether it was given cmux's MCP server.
    write_executable(
        &fakebin.join("claude"),
        &format!(
            "#!/bin/sh\nsettings=\nmcp=\nfor arg in \"$@\"; do\n  case $arg in *'\"cmux\"'*) mcp=cmux ;; esac\ndone\n\
             while [ $# -gt 0 ]; do [ \"$1\" = --settings ] && settings=$2; shift; done\n\
             out='{}/claude-'\"$OB_TAG\".txt\n\
             printf 'HOOK=%s\\nSETTINGS=%s\\nMCP=%s\\n' \"$CMUX_TUI_HOOK\" \"$settings\" \"$mcp\" > \"$out.tmp\"\n\
             mv \"$out.tmp\" \"$out\"\n",
            root.display()
        ),
    );
    // A launcher like `claude-sr2`: its own settings, then `exec claude`.
    write_executable(
        &launcher.join("claude-sr2"),
        "#!/bin/sh\nexec claude --settings '{\"env\":{\"OB_LAUNCHER\":\"sr2\"}}' \"$@\"\n",
    );
    let exe_a = install_build(&root.join("build-a"), "build-a", &hook_log);
    // The app bundle's `cmux` beside its `cmux-tui`.
    let bundled_cli = root.join("build-a/cmux");
    std::os::unix::fs::symlink(&exe_a, &bundled_cli).unwrap();

    // The shared folder as an older build left it: its shims name a build
    // that is gone, and its helper is the shared one.
    let shared = data.join("cmux-tui/shims");
    fs::create_dir_all(&shared).unwrap();
    let gone = root.join("gone/cmux DEV old.app/Contents/Resources/bin/cmux");
    for (name, marker, verb) in [
        ("claude", "# cmux-tui-claude-shim", "claude-wrapper"),
        ("codex", "# cmux-tui-codex-shim", "codex-wrapper"),
    ] {
        write_executable(
            &shared.join(name),
            &format!(
                "#!/bin/sh\n{marker}\nif [ -x '{gone}' ]; then\n  exec '{gone}' agent {verb} \"$@\"\nfi\n\
                 set -f\nIFS=:\nkept=\nfor entry in $PATH; do\n  [ \"$entry\" = '{dir}' ] || kept=\"${{kept:+$kept:}}$entry\"\ndone\n\
                 unset IFS\nset +f\nPATH=$kept\nexport PATH\nexec {name} \"$@\"\n",
                gone = gone.display(),
                dir = shared.display(),
            ),
        );
    }
    let shared_helper = data.join("cmux-tui/bin/cmux-tui-hook");
    fs::create_dir_all(shared_helper.parent().unwrap()).unwrap();
    write_executable(
        &shared_helper,
        &format!("#!/bin/sh\nprintf 'shared %s\\n' \"$*\" >> '{}'\n", hook_log.display()),
    );

    let path = format!("{}:{}:/usr/bin:/bin", launcher.display(), fakebin.display());
    let mut a = Daemon::start(&root, &exe_a, "ob-old", &home, &data, &path);
    a.wait_for_lifecycle_ready();
    // The older terminal's environment: the shared folder and helper, the
    // app's bundled CLI, no CMUX_TUI_CLI, and the person's `claude` function.
    let old_terminal = a.run(
        "ob-old-term",
        &format!(
            "unset CMUX_TUI_CLI; CMUX_TUI_AGENT_SHIMS='{shared}'; CMUX_TUI_HOOK='{helper}'; \
             CMUX_BUNDLED_CLI_PATH='{cli}'; CMUX_NEXT_CONFIG_FILE='{settings}'; PATH='{shared}:{path}'; \
             export CMUX_TUI_AGENT_SHIMS CMUX_TUI_HOOK CMUX_BUNDLED_CLI_PATH CMUX_NEXT_CONFIG_FILE PATH; \
             claude() {{ command claude-sr2 \"$@\"; }}; claude hi; sleep 600",
            shared = shared.display(),
            helper = shared_helper.display(),
            cli = bundled_cli.display(),
            settings = settings_file.display(),
        ),
    );

    let record = root.join(format!("claude-{old_terminal}.txt"));
    let deadline = Instant::now() + Duration::from_secs(30);
    while !record.exists() {
        assert!(Instant::now() < deadline, "claude never ran: {}", a.screen(&old_terminal));
        std::thread::sleep(Duration::from_millis(50));
    }
    let text = fs::read_to_string(&record).unwrap();
    assert!(
        text.contains("MCP=cmux"),
        "claude in the older terminal got no cmux MCP server (the shared shim of a gone build \
         started it without cmux): {text}"
    );
    let (hook, settings) = launch_record(&root, &a, &old_terminal);
    assert_eq!(
        Path::new(&hook),
        root.join("build-a/cmux-tui-hook"),
        "the older terminal's claude ran another helper"
    );
    assert_eq!(settings["env"]["OB_LAUNCHER"], "sr2", "the launcher's own settings were dropped");
    let session_start = hook_commands(&settings, "SessionStart").join("\n");
    assert!(
        session_start.contains(&exe_a.display().to_string()),
        "the older terminal's claude ran no hooks of this build: {session_start}"
    );
    // The rewritten shims never name the daemon that wrote them, so no last
    // writer decides; the older shim's own target stays only as a checked
    // fallback.
    for name in ["claude", "codex"] {
        let script = fs::read_to_string(shared.join(name)).unwrap();
        assert!(!script.contains(&exe_a.display().to_string()), "{name}: {script}");
        assert!(script.contains(&format!("if [ -x '{}' ]", gone.display())), "{name}: {script}");
    }
    drop(a);
    let _ = fs::remove_dir_all(&root);
}

/// What a shared shim a new daemon rewrote runs: the terminal's
/// `CMUX_TUI_CLI`, else the app's bundled CLI when it is a cmux-next bundle
/// (its `cmux-tui` is the same file as its `cmux`; a classic app ships two
/// different binaries), else the agent itself with the shared folder left
/// out of its PATH.
#[test]
fn shared_shims_follow_the_terminals_own_cmux() {
    let root = unique_root();
    let home = root.join("home");
    let data = root.join("data");
    for dir in [&home, &data] {
        fs::create_dir_all(dir).unwrap();
    }
    let shared = data.join("cmux-tui/shims");
    fs::create_dir_all(&shared).unwrap();
    // The older shims name a writer that is still installed (a classic app's
    // or an npm install's `cmux-tui` at a fixed path).
    let writer = root.join("writer dir/cmux-tui");
    for (name, marker, verb) in [
        ("claude", "# cmux-tui-claude-shim", "claude-wrapper"),
        ("codex", "# cmux-tui-codex-shim", "codex-wrapper"),
    ] {
        write_executable(
            &shared.join(name),
            &format!(
                "#!/bin/sh\n{marker}\nif [ -x '{w}' ]; then\n  exec '{w}' agent {verb} \"$@\"\nfi\nexec {name} \"$@\"\n",
                w = writer.display()
            ),
        );
    }
    let exe = install_build(&root.join("build-s"), "build-s", &root.join("hook.log"));
    let daemon = Daemon::start(&root, &exe, "ob-shared", &home, &data, "/usr/bin:/bin");
    daemon.wait_for_lifecycle_ready();
    drop(daemon);

    let echo = |label: &str| format!("#!/bin/sh\nprintf '{label}|%s\\n' \"$*\"\n");
    let tui_cli = root.join("tui/cmux");
    let bundle_cli = root.join("bundle/cmux");
    let classic_cli = root.join("classic/cmux");
    for (path, label) in [
        (&tui_cli, "tui"),
        (&bundle_cli, "bundle"),
        (&classic_cli, "classic"),
        (&root.join("classic/cmux-tui"), "classic-tui"),
    ] {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        write_executable(path, &echo(label));
    }
    // A cmux-next bundle: `cmux-tui` is a link to `cmux`.
    std::os::unix::fs::symlink("cmux", root.join("bundle/cmux-tui")).unwrap();
    let real = root.join("real");
    fs::create_dir_all(&real).unwrap();
    for name in ["claude", "codex"] {
        write_executable(&real.join(name), "#!/bin/sh\nprintf 'real %s|%s\\n' \"$*\" \"$PATH\"\n");
    }
    let path = format!("{}:{}", shared.display(), real.display());
    let run = |name: &str, env: &[(&str, &Path)]| {
        let mut command = Command::new("/bin/sh");
        command.arg(shared.join(name)).arg("hi").env_clear().env("PATH", &path);
        for (key, value) in env {
            command.env(key, value);
        }
        String::from_utf8(command.output().unwrap().stdout).unwrap()
    };
    let gone = root.join("gone/cmux");
    let both =
        [("CMUX_TUI_CLI", tui_cli.as_path()), ("CMUX_BUNDLED_CLI_PATH", bundle_cli.as_path())];
    assert_eq!(run("claude", &both), "tui|agent claude-wrapper hi\n");
    assert_eq!(run("codex", &both), "tui|agent codex-wrapper hi\n");
    let bundled =
        [("CMUX_TUI_CLI", gone.as_path()), ("CMUX_BUNDLED_CLI_PATH", bundle_cli.as_path())];
    assert_eq!(run("claude", &bundled), "bundle|agent claude-wrapper hi\n");
    assert_eq!(run("codex", &bundled), "bundle|agent codex-wrapper hi\n");
    // A classic bundled CLI is never run; the older shim's own writer is,
    // while it exists, else the agent itself.
    let classic = [("CMUX_BUNDLED_CLI_PATH", classic_cli.as_path())];
    assert_eq!(run("claude", &classic), format!("real hi|{}\n", real.display()));
    assert_eq!(run("codex", &[]), format!("real hi|{}\n", real.display()));
    fs::create_dir_all(writer.parent().unwrap()).unwrap();
    write_executable(&writer, &echo("writer"));
    assert_eq!(run("claude", &classic), "writer|agent claude-wrapper hi\n");
    assert_eq!(run("codex", &[]), "writer|agent codex-wrapper hi\n");
    assert_eq!(run("claude", &both), "tui|agent claude-wrapper hi\n");
    let _ = fs::remove_dir_all(&root);
}
