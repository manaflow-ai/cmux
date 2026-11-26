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

fn unique_root() -> PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("cmux-ob-{}-{stamp}-{n}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    // macOS /tmp is a symlink; the daemon resolves its own path.
    root.canonicalize().unwrap()
}

/// A copy of this build under `dir`, as a second install would place it.
fn install_build(dir: &Path, name: &str, hook_log: &Path) -> PathBuf {
    fs::create_dir_all(dir).unwrap();
    let exe = dir.join("cmux-tui");
    let source = env!("CARGO_BIN_EXE_cmux-tui");
    if fs::hard_link(source, &exe).is_err() {
        cmux_test_exec::copy_executable(Path::new(source), &exe).unwrap();
    }
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o755)).unwrap();
    cmux_test_exec::write_executable(
        &dir.join("cmux-tui-hook"),
        format!("#!/bin/sh\nprintf '%s %s\\n' '{name}' \"$*\" >> '{}'\n", hook_log.display()),
    )
    .unwrap();
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
    cmux_test_exec::write_executable(
        &shared_helper,
        format!("#!/bin/sh\nprintf 'shared %s\\n' \"$*\" >> '{}'\n", hook_log.display()),
    )
    .unwrap();
    // The real `claude`: records what the wrapper gave it, then runs the
    // hook helper the way Claude Code runs a hook command.
    cmux_test_exec::write_executable(
        &fakebin.join("claude"),
        format!(
            "#!/bin/sh\nsettings=\nwhile [ $# -gt 0 ]; do [ \"$1\" = --settings ] && settings=$2; shift; done\n\
             \"$CMUX_TUI_HOOK\" claude SessionStart < /dev/null\n\
             out='{}/claude-'\"$OB_TAG\".txt\n\
             printf 'HOOK=%s\\nSETTINGS=%s\\n' \"$CMUX_TUI_HOOK\" \"$settings\" > \"$out.tmp\"\n\
             mv \"$out.tmp\" \"$out\"\n",
            root.display()
        ),
    ).unwrap();
    let user_helper = root.join("user-hook");
    cmux_test_exec::write_executable(
        &user_helper,
        format!("#!/bin/sh\nprintf 'user %s\\n' \"$*\" >> '{}'\n", hook_log.display()),
    )
    .unwrap();
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
