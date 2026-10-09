//! Terminals the daemon starts itself run the app's bundled `cmux`. The app
//! starts the daemon with `CMUX_BUNDLED_CLI_PATH` (`<Resources>/bin/cmux`)
//! and that bin dir first on `PATH` (`DaemonLauncher.forApp`). A shell from
//! `cmux workspace create` or `cmux tab create terminal` keeps it first after
//! user startup files that prepend another `cmux` (`~/.local/bin`), and an
//! agent-style command with its own caller `PATH` gets it first too. Each
//! case starts a real daemon and reads what the child sees.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

fn unique_temp_dir(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    PathBuf::from("/tmp").join(format!("cmux-bcli-{name}-{}-{stamp}", std::process::id()))
}

fn write_executable(path: impl AsRef<Path>, contents: &str) {
    fs::write(path.as_ref(), contents).unwrap();
    fs::set_permissions(path.as_ref(), fs::Permissions::from_mode(0o755)).unwrap();
}

fn assert_success(output: &Output) {
    assert!(
        output.status.success(),
        "status={:?}\nstdout={}\nstderr={}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

/// A headless daemon on its own socket and state; closes its terminals and
/// stops on drop.
struct HeadlessServer {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl HeadlessServer {
    fn start_with_options(name: &str, env: &[(&str, &str)]) -> Self {
        let dir = unique_temp_dir(name);
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        fs::write(dir.join("config.json"), "{}").unwrap();
        let child = Command::new(bin())
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .envs(env.iter().copied())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let server = Self { child, socket, dir };
        let deadline = Instant::now() + Duration::from_secs(15);
        while !server.socket.exists()
            || !cli(&server, &["--json", "workspace", "list"]).status.success()
        {
            assert!(Instant::now() < deadline, "headless daemon did not start");
            std::thread::sleep(Duration::from_millis(50));
        }
        server
    }
}

impl Drop for HeadlessServer {
    fn drop(&mut self) {
        let listed = cli(self, &["--json", "terminal", "list"]);
        let terminals: serde_json::Value =
            serde_json::from_slice(&listed.stdout).unwrap_or(serde_json::Value::Null);
        for terminal in terminals.as_array().into_iter().flatten() {
            if let Some(id) = terminal["id"].as_str() {
                let _ = cli(self, &["--quiet", "terminal", id, "close"]);
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn cli(server: &HeadlessServer, args: &[&str]) -> Output {
    let (flags, rest): (Vec<&str>, Vec<&str>) =
        args.iter().partition(|arg| matches!(**arg, "--json" | "--quiet"));
    Command::new(bin())
        .args(flags)
        .arg("--socket")
        .arg(&server.socket)
        .args(rest)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap()
}

fn json_socket_request(socket: &Path, request: serde_json::Value) -> serde_json::Value {
    let output = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(socket)
        .args(["raw", "command", "--request-json", &request.to_string()])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&output);
    serde_json::from_slice(&output.stdout).unwrap()
}

struct Fixture {
    dir: PathBuf,
    bundled: String,
    bin_dir: String,
    home: PathBuf,
    zdot: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let dir = unique_temp_dir("bundled-cli");
        let resources = dir.join("cmux DEV t.app/Contents/Resources");
        let bin = resources.join("bin");
        let home = dir.join("home");
        let zdot = dir.join("zdot");
        for path in [&bin, &home.join(".local/bin"), &zdot, &home.join(".config/fish")] {
            fs::create_dir_all(path).unwrap();
        }
        symlink(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Resources/cmux-cli-path"),
            resources.join("cmux-cli-path"),
        )
        .unwrap();
        write_executable(bin.join("cmux"), "#!/bin/sh\necho bundled\n");
        write_executable(home.join(".local/bin/cmux"), "#!/bin/sh\necho old\n");
        let prepend = "export PATH=\"$HOME/.local/bin:$PATH\"; export CMUX_TEST_RC_RAN=1\n";
        for file in [
            zdot.join(".zshrc"),
            zdot.join(".zprofile"),
            home.join(".bashrc"),
            home.join(".bash_profile"),
        ] {
            fs::write(file, prepend).unwrap();
        }
        fs::write(
            home.join(".config/fish/config.fish"),
            "set -gx PATH $HOME/.local/bin $PATH; set -gx CMUX_TEST_RC_RAN 1\n",
        )
        .unwrap();
        let bundled = bin.join("cmux").to_string_lossy().into_owned();
        let bin_dir = bin.to_string_lossy().into_owned();
        Self { dir, bundled, bin_dir, home, zdot }
    }

    /// The daemon as the app starts it, with `shell` as the default shell.
    fn server(&self, name: &str, shell: &str) -> HeadlessServer {
        let home = self.home.to_string_lossy().into_owned();
        let zdot = self.zdot.to_string_lossy().into_owned();
        let config = self.home.join(".config").to_string_lossy().into_owned();
        let path = format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", self.bin_dir);
        let env = [
            ("SHELL", shell),
            ("HOME", home.as_str()),
            ("ZDOTDIR", zdot.as_str()),
            ("XDG_CONFIG_HOME", config.as_str()),
            ("PATH", path.as_str()),
            ("CMUX_BUNDLED_CLI_PATH", self.bundled.as_str()),
        ];
        HeadlessServer::start_with_options(&format!("bundled-cli-{name}"), &env)
    }

    /// The env lines and `command -v cmux` that the probe in `out` wrote.
    fn lines(out: &Path, what: &str) -> Vec<String> {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if let Ok(text) = fs::read_to_string(out) {
                return text.lines().map(str::to_string).collect();
            }
            assert!(Instant::now() < deadline, "{what} never answered the probe");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn check(&self, label: &str, lines: &[String]) {
        assert_eq!(lines.last(), Some(&self.bundled), "{label}: plain cmux\n{lines:#?}");
        assert!(
            lines.contains(&format!("CMUX_BUNDLED_CLI_PATH={}", self.bundled)),
            "{label}: CMUX_BUNDLED_CLI_PATH\n{lines:#?}"
        );
        let leaked = lines.iter().filter(|line| line.starts_with("CMUX_CLI_")).collect::<Vec<_>>();
        assert!(leaked.is_empty(), "{label}: leaked {leaked:?}");
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn probe_text(out: &Path) -> String {
    format!(
        "env > '{out}.tmp'; command -v cmux >> '{out}.tmp'; mv '{out}.tmp' '{out}'",
        out = out.display()
    )
}

fn find_shell(name: &str) -> Option<String> {
    let path = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        .iter()
        .map(|dir| format!("{dir}/{name}"))
        .find(|path| Path::new(path).is_file())?;
    // Ghostty does not integrate Apple's bash 3.2, so its layer cannot either.
    (!(cfg!(target_os = "macos") && path == "/bin/bash")).then_some(path)
}

fn surface_ids(server: &HeadlessServer) -> Vec<u64> {
    let tree =
        json_socket_request(&server.socket, serde_json::json!({"id": 1, "cmd": "list-workspaces"}));
    let mut ids = tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .filter_map(|tab| tab["surface"].as_u64())
        .collect::<Vec<_>>();
    ids.sort_unstable();
    ids.dedup();
    ids
}

#[test]
fn daemon_started_shells_run_the_bundled_cli_after_user_startup_files() {
    let fixture = Fixture::new();
    let mut ran = Vec::new();
    for name in ["zsh", "bash", "fish"] {
        let Some(shell) = find_shell(name) else {
            eprintln!("SKIP: {name} not installed");
            continue;
        };
        let server = fixture.server(name, &shell);
        let creations: [&[&str]; 2] =
            [&["workspace", "create", "--name", "bundled"], &["tab", "create", "terminal"]];
        for (index, create) in creations.into_iter().enumerate() {
            let before = surface_ids(&server);
            assert_success(&cli(&server, create));
            let created = surface_ids(&server)
                .into_iter()
                .filter(|id| !before.contains(id))
                .collect::<Vec<_>>();
            assert_eq!(created.len(), 1, "{name} {create:?}: new surfaces {created:?}");
            let out = fixture.dir.join(format!("{name}-{index}.out"));
            let text = format!("{}\n", probe_text(&out));
            let send =
                serde_json::json!({"id": 2, "cmd": "send", "surface": created[0], "text": text});
            json_socket_request(&server.socket, send);
            let label = format!("{name} {create:?}");
            let lines = Fixture::lines(&out, &label);
            fixture.check(&label, &lines);
            assert!(
                lines.iter().any(|line| line == "CMUX_TEST_RC_RAN=1"),
                "{label}: startup files did not run"
            );
        }
        ran.push(name);
    }
    assert!(!ran.is_empty(), "no zsh, bash or fish to test with");
}

/// An agent terminal: a command with the caller's own `PATH`, which lists
/// `~/.local/bin` (an older `cmux`) first.
#[test]
fn a_daemon_started_command_with_a_caller_path_runs_the_bundled_cli() {
    let fixture = Fixture::new();
    let server = fixture.server("agent", "/bin/sh");
    assert_success(&cli(&server, &["workspace", "create", "--empty", "--name", "agent"]));
    let tree =
        json_socket_request(&server.socket, serde_json::json!({"id": 1, "cmd": "list-workspaces"}));
    let key = tree["workspaces"][0]["key"].as_str().expect("a workspace key").to_string();
    let out = fixture.dir.join("agent.out");
    let caller_path = format!("{}/.local/bin:/usr/bin:/bin", fixture.home.display());
    let request = serde_json::json!({
        "id": 2, "cmd": "create-terminal", "key": key, "cols": 80, "rows": 24,
        "argv": ["/bin/sh", "-c", probe_text(&out)],
        "env": {"PATH": caller_path},
    });
    json_socket_request(&server.socket, request);
    let lines = Fixture::lines(&out, "agent command");
    fixture.check("agent command", &lines);
    let path = lines.iter().find_map(|line| line.strip_prefix("PATH=")).unwrap_or_default();
    assert!(
        path.split(':').position(|dir| dir == fixture.bin_dir)
            < path.split(':').position(|dir| dir.ends_with("/.local/bin")),
        "agent command: bundled bin dir is not ahead of ~/.local/bin: {path}"
    );
}
