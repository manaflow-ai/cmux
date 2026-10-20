//! Bring your own harness through the real binaries (BRING-YOUR-OWN-HARNESS,
//! cx-00p): with a daemon already running, `harness add` writes a profile for
//! a sample ACP agent and the daemon picks it up, `harness doctor` passes
//! every step, and a chat on that harness answers. A program that is missing
//! or not executable fails the doctor's command step with the exact fix.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A private user: own HOME, XDG config (the user harness folder) and
/// acpmux home, and one daemon on its own socket.
struct User {
    root: PathBuf,
    daemon: Option<Child>,
}

impl User {
    fn new(tag: &str) -> Self {
        // Short: the socket path must stay under the macOS limit. One root
        // per test: the tests of this binary run at the same time.
        let root = std::env::temp_dir().join(format!("byoh-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for dir in ["home", "xdg", "amx", "work"] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
        let root = std::fs::canonicalize(&root).unwrap();
        std::fs::write(
            root.join("amx").join("config.json"),
            json!({"permissionPolicy": "approve-all"}).to_string(),
        )
        .unwrap();
        Self { root, daemon: None }
    }

    fn cmd(&self) -> Command {
        // The daemon runs the sample agent; `harness add` and `doctor` too.
        let mut cmd = daemon_env::command(&self.root, daemon_env::Agents::StandIn, &[]);
        cmd.current_dir(self.root.join("work"))
            .env("XDG_CONFIG_HOME", self.root.join("xdg"))
            .env("ACPMUX_HOME", self.root.join("amx"))
            .env("ACPMUX_SOCKET", self.root.join("s.sock"))
            .env("ACPMUX_LOGIN_ENV", "0")
            .stdin(Stdio::null());
        cmd
    }

    fn start_daemon(&mut self) {
        let mut child = self
            .cmd()
            .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--ready-fd", "1"])
            .args(["--log", "warn"])
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("start daemon");
        // Log lines (a warning when no harness is found on PATH) may come
        // before the readiness line on stdout.
        let mut out = BufReader::new(child.stdout.take().unwrap());
        let mut seen = String::new();
        loop {
            let mut line = String::new();
            let n = out.read_line(&mut line).unwrap();
            assert!(n > 0, "daemon exited before it was ready: {seen}");
            if line.contains("\"ready\":true") {
                break;
            }
            seen.push_str(&line);
        }
        self.daemon = Some(child);
    }

    fn run(&self, args: &[&str]) -> Output {
        self.cmd().args(args).output().expect("run acpmux")
    }

    /// A copy of the fake ACP agent at `name` in the scratch root.
    fn agent(&self, name: &str, mode: u32) -> PathBuf {
        let path = self.root.join(name);
        std::fs::copy(FAKE, &path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
        path
    }

    fn doctor(&self, id: &str) -> (Output, Value) {
        let out = self.run(&["--json", "harness", "doctor", id, "--timeout", "30"]);
        let text = String::from_utf8_lossy(&out.stdout).into_owned();
        let report = serde_json::from_str(&text).unwrap_or_else(|e| {
            panic!("doctor printed no JSON ({e}): {text} {}", String::from_utf8_lossy(&out.stderr))
        });
        (out, report)
    }
}

impl Drop for User {
    fn drop(&mut self) {
        if let Some(mut child) = self.daemon.take() {
            let _ = self.run(&["daemon", "shutdown", "--end-agents"]);
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn step<'a>(report: &'a Value, name: &str) -> &'a Value {
    report["steps"]
        .as_array()
        .and_then(|s| s.iter().find(|s| s["step"] == name))
        .unwrap_or_else(|| panic!("no step {name}: {report}"))
}

fn text(out: &Output) -> String {
    format!("{} {}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr))
}

#[test]
fn a_user_adds_a_sample_acp_harness_checks_it_and_chats_with_it() {
    let mut user = User::new("chat");
    user.start_daemon();
    let agent = user.agent("sample-acp", 0o755);

    // Add: the profile lands in the user's harness folder and the running
    // daemon reads it again.
    let out =
        user.run(&["--json", "harness", "add", "sample", "--command", agent.to_str().unwrap()]);
    assert!(out.status.success(), "add failed: {}", text(&out));
    let added: Value = serde_json::from_slice(&out.stdout).unwrap();
    let file = user.root.join("xdg").join("cmux").join("harnesses").join("sample.toml");
    assert_eq!(added["path"], json!(file), "{added}");
    assert_eq!(added["daemonReloaded"], json!(true), "{added}");
    assert!(added["diagnostics"].as_array().is_some_and(Vec::is_empty), "{added}");

    let out = user.run(&["--json", "harness", "list"]);
    assert!(out.status.success(), "list failed: {}", text(&out));
    let list: Value = serde_json::from_slice(&out.stdout).unwrap();
    let row = list["harnesses"]
        .as_array()
        .and_then(|rows| rows.iter().find(|r| r["id"] == "sample"))
        .unwrap_or_else(|| panic!("sample not listed: {list}"));
    assert_eq!(row["source"], "user-file", "{row}");
    assert_eq!(row["kind"], "acp", "{row}");

    // Doctor: every step passes and the agent answered the prompt.
    let (out, report) = user.doctor("sample");
    assert!(out.status.success(), "doctor failed: {report}");
    assert_eq!(report["ok"], json!(true), "{report}");
    for name in ["profile", "command", "env", "launch", "initialize", "session", "prompt"] {
        assert_eq!(step(&report, name)["status"], "pass", "{name}: {report}");
    }
    assert!(report["reply"].as_str().is_some_and(|r| !r.is_empty()), "{report}");

    // A chat on the new harness answers.
    let out = user.run(&["exec", "-m", "sample", "--timeout", "60", "byoh-sample-marker"]);
    assert!(out.status.success(), "chat failed: {}", text(&out));
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("byoh-sample-marker"),
        "no reply from the sample harness: {}",
        text(&out)
    );
}

#[test]
fn doctor_names_the_exact_fix_when_the_program_cannot_start() {
    let user = User::new("fix");

    // The file exists but has no execute bit.
    let script = user.agent("not-exec-acp", 0o644);
    let out = user.run(&["harness", "add", "noexec", "--command", script.to_str().unwrap()]);
    assert!(out.status.success(), "add failed: {}", text(&out));
    let (out, report) = user.doctor("noexec");
    assert!(!out.status.success(), "doctor passed a program with no execute bit: {report}");
    let command = step(&report, "command");
    assert_eq!(command["status"], "fail", "{report}");
    assert!(command["detail"].as_str().unwrap().contains("not executable"), "{report}");
    let fix = format!("chmod +x {}", script.display());
    assert!(command["fix"].as_str().unwrap().contains(&fix), "{report}");

    // No file at the path at all.
    let missing = user.root.join("no-such-agent");
    let out = user.run(&["harness", "add", "gone", "--command", missing.to_str().unwrap()]);
    assert!(out.status.success(), "add failed: {}", text(&out));
    let (out, report) = user.doctor("gone");
    assert!(!out.status.success(), "doctor passed a missing program: {report}");
    let command = step(&report, "command");
    assert_eq!(command["status"], "fail", "{report}");
    let detail = command["detail"].as_str().unwrap();
    assert!(detail.contains("no file") && detail.contains("no-such-agent"), "{report}");
    let profile = user.root.join("xdg").join("cmux").join("harnesses").join("gone.toml");
    assert!(
        command["fix"].as_str().unwrap().contains(&profile.display().to_string()),
        "the fix does not name the profile file: {report}"
    );
}

#[test]
fn byo_endpoint_cli_adds_an_endpoint_profile_with_keychain_refs() {
    let user = User::new("byoe");
    let dir = user.root.join("xdg").join("cmux").join("harnesses");

    // Anthropic-compatible: Claude Code with the endpoint, the model and a
    // Keychain reference for the token.
    let out = user.run(&[
        "--json",
        "harness",
        "add",
        "acme",
        "--example",
        "anthropic-endpoint",
        "--base-url",
        "https://llm.example.com",
        "--model",
        "acme-1",
        "--keychain-item",
        "acme-key",
        "--name",
        "Acme",
    ]);
    assert!(out.status.success(), "add failed: {}", text(&out));
    let added: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(added["path"], json!(dir.join("acme.toml")), "{added}");
    assert_eq!(added["secret"]["key"], "ANTHROPIC_AUTH_TOKEN", "{added}");
    let file = std::fs::read_to_string(dir.join("acme.toml")).unwrap();
    assert!(file.contains(r#"ANTHROPIC_AUTH_TOKEN = { keychain = "acme-key" }"#), "{file}");
    assert!(file.contains(r#"ANTHROPIC_BASE_URL = "https://llm.example.com""#), "{file}");
    assert!(file.contains(r#"protocol = "claude-stdio""#), "{file}");

    // OpenAI-compatible: OpenCode, its key from the default Keychain item.
    let out = user.run(&[
        "harness",
        "add",
        "local-oai",
        "--example",
        "openai-endpoint",
        "--base-url",
        "http://127.0.0.1:11434/v1",
        "--model",
        "qwen3",
    ]);
    assert!(out.status.success(), "add failed: {}", text(&out));
    assert!(
        text(&out).contains("cmux harness secret set local-oai CMUX_BYO_API_KEY"),
        "no next step: {}",
        text(&out)
    );
    let file = std::fs::read_to_string(dir.join("local-oai.toml")).unwrap();
    assert!(
        file.contains(r#"CMUX_BYO_API_KEY = { keychain = "cmux-harness/local-oai/CMUX_BYO_API_KEY" }"#),
        "{file}"
    );

    // Plain http to another host is refused, and nothing is written.
    let out = user.run(&[
        "harness",
        "add",
        "plain",
        "--example",
        "openai-endpoint",
        "--base-url",
        "http://llm.example.com/v1",
        "--model",
        "m",
    ]);
    assert!(!out.status.success(), "plain http was accepted: {}", text(&out));
    assert!(text(&out).contains("https"), "{}", text(&out));
    assert!(!dir.join("plain.toml").exists());

    // The endpoint flags go only with an endpoint example.
    let out = user.run(&["harness", "add", "x", "--command", "x", "--base-url", "https://a.example"]);
    assert!(!out.status.success(), "{}", text(&out));

    // The help names both kinds, in English and in Japanese.
    let out = user.run(&["harness", "add", "--help"]);
    let help = text(&out);
    for want in ["anthropic-endpoint", "openai-endpoint", "--base-url", "--keychain-item"] {
        assert!(help.contains(want), "{want} missing: {help}");
    }
    let out = user.cmd().env("LC_ALL", "ja_JP.UTF-8").args(["harness", "add", "--help"]).output().unwrap();
    let help = text(&out);
    assert!(help.contains("キーチェーン"), "no Japanese help: {help}");
}
