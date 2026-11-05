//! CLI JSON permission replies retain the daemon's person-only allow rule.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Output;

struct Fixture(PathBuf);

impl Fixture {
    fn pending(tag: &str, prompt: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("amx-pjson-{tag}-{}", std::process::id()));
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        let fixture = Self(dir);
        fs::create_dir(fixture.0.join("work")).unwrap();
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        fs::write(
            fixture.0.join("config.json"),
            json!({"harnesses": {"fake": {"argv": ["python3", fake]}},
                "defaultHarness": "fake", "permissionPolicy": "ask"})
            .to_string(),
        )
        .unwrap();
        fs::set_permissions(fixture.0.join("config.json"), fs::Permissions::from_mode(0o600))
            .unwrap();
        let made =
            fixture.run(&["new", "-d", "-n", "lane", "-m", "fake", "--policy", "ask", prompt]);
        assert!(made.status.success(), "{}", diagnostic(&made));
        let waiting = fixture.run(&["wait", "lane", "--until", "permission", "--timeout", "20"]);
        assert_eq!(waiting.status.code(), Some(2), "{}", diagnostic(&waiting));
        fixture
    }

    fn run(&self, args: &[&str]) -> Output {
        daemon_env::command(&self.0, daemon_env::Agents::StandIn, &[])
            .args(args)
            .env("ACPMUX_HOME", &self.0)
            .env("ACPMUX_SOCKET", self.0.join("s.sock"))
            .env("ACPMUX_LOGIN_ENV", "0")
            .current_dir(self.0.join("work"))
            .output()
            .unwrap()
    }

    fn info(&self) -> Value {
        let out = self.run(&["session", "info", "lane", "--json"]);
        assert!(out.status.success(), "{}", diagnostic(&out));
        parse(&out.stdout, &out)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.run(&["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn diagnostic(out: &Output) -> String {
    format!(
        "status {:?}\nstdout: {}\nstderr: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

fn parse(bytes: &[u8], out: &Output) -> Value {
    serde_json::from_slice(bytes).unwrap_or_else(|e| panic!("not JSON: {e}\n{}", diagnostic(out)))
}

#[test]
fn session_deny_json_reports_the_rejected_option() {
    let fixture = Fixture::pending("deny", "ask: echo permission-json");
    let before = fixture.info();
    let out = fixture.run(&["session", "deny", "lane", "--json"]);
    assert!(out.status.success(), "{}", diagnostic(&out));
    let reply = parse(&out.stdout, &out);
    assert_eq!(reply["sessionId"], before["sessionId"]);
    assert_eq!(reply["permissionId"], before["pending"][0]["permissionId"]);
    assert_eq!(reply["optionId"], "no");
    assert_eq!(reply["kind"], "reject_once");
    assert!(fixture.info()["pending"].as_array().unwrap().is_empty());
}

#[test]
fn session_allow_json_refuses_without_person_proof_and_keeps_the_prompt() {
    let fixture = Fixture::pending("allow", "ask: echo permission-json");
    let before = fixture.info();
    let out = fixture.run(&["session", "allow", "lane", "--json"]);
    assert_eq!(out.status.code(), Some(1), "{}", diagnostic(&out));
    assert!(out.stdout.is_empty(), "{}", diagnostic(&out));
    let error = parse(&out.stderr, &out);
    assert_eq!(error["error"]["exit"], 1);
    assert_eq!(error["error"]["detail"], "person_required");
    assert_eq!(error["error"]["data"]["reason"], "permission.person_required");
    assert_eq!(fixture.info()["pending"][0]["permissionId"], before["pending"][0]["permissionId"]);
    // An explicit reject through `allow` is still a deny, and JSON describes it honestly.
    let denied = fixture.run(&["session", "allow", "lane", "no", "--json"]);
    assert!(denied.status.success(), "{}", diagnostic(&denied));
    assert_eq!(parse(&denied.stdout, &denied)["kind"], "reject_once");
}

#[test]
fn session_answer_json_usage_carries_the_question_without_stdout_text() {
    let fixture = Fixture::pending("answer", "question: Which option?");
    let before = fixture.info();
    let out = fixture.run(&["session", "answer", "lane", "--json"]);
    assert_eq!(out.status.code(), Some(2), "{}", diagnostic(&out));
    assert!(out.stdout.is_empty(), "{}", diagnostic(&out));
    let error = parse(&out.stderr, &out);
    assert_eq!(error["error"]["code"], "usage");
    assert_eq!(error["error"]["exit"], 2);
    assert_eq!(error["error"]["data"]["sessionId"], before["sessionId"]);
    assert_eq!(error["error"]["data"]["question"]["items"][0]["prompt"], "Which option?");
    assert_eq!(fixture.info()["pending"][0]["permissionId"], before["pending"][0]["permissionId"]);
}
