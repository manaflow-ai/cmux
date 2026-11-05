//! A plain `acpmux send` from an agent harness's own shell outside acpmux (the Codex desktop app,
//! Claude Code in a terminal), with no `--from` and no `ACPMUX_FROM`, against a real daemon: the
//! receiver records it as that agent's message (`agent_message`, `fromHarness`), so its chat draws
//! the agent's card, never the person's bubble (Leo, 2026-11-05: "why is it sending it as if it
//! were me?"). The same send from the person's own terminal stays the person's.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Output;

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-ah-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    // The daemon refuses a state folder others may write to.
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
               "permissionPolicy": "approve-all"})
        .to_string(),
    )
    .unwrap();
    fs::set_permissions(dir.join("config.json"), fs::Permissions::from_mode(0o600)).unwrap();
    dir
}

fn cli(dir: &Path, args: &[&str], env: &[(&str, &str)]) -> Output {
    let mut cmd = daemon_env::command(dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(args).env("ACPMUX_HOME", dir).env("ACPMUX_LOGIN_ENV", "0").current_dir(dir.join("p"));
    cmd.envs(env.iter().copied());
    cmd.output().unwrap()
}

fn text(o: &Output) -> String {
    format!(
        "status {:?}\nstdout: {}\nstderr: {}",
        o.status,
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    )
}

struct Shutdown<'a>(&'a Path);

impl Drop for Shutdown<'_> {
    fn drop(&mut self) {
        let _ = cli(self.0, &["daemon", "shutdown", "--end-agents"], &[]);
        let _ = fs::remove_dir_all(self.0);
    }
}

/// The `_meta.provenance` of the `user_message` whose text is `said`, from the daemon's logs.
fn provenance_of(dir: &Path, said: &str) -> Option<Value> {
    let mut pending = vec![dir.to_path_buf()];
    while let Some(folder) = pending.pop() {
        for entry in fs::read_dir(&folder).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.is_dir() {
                pending.push(path);
                continue;
            }
            if path.extension().and_then(|e| e.to_str()) != Some("ndjson") {
                continue;
            }
            for line in fs::read_to_string(&path).unwrap_or_default().lines() {
                let Ok(record) = serde_json::from_str::<Value>(line) else { continue };
                if record["kind"] == "user_message" && record.to_string().contains(said) {
                    return Some(record["msg"]["_meta"]["provenance"].clone());
                }
            }
        }
    }
    None
}

#[test]
fn a_plain_send_from_a_codex_shell_is_that_agents_message_and_the_persons_stays_theirs() {
    let dir = scratch("s");
    let _shutdown = Shutdown(&dir);
    let made = cli(&dir, &["run", "-n", "coord", "warm up"], &[]);
    assert!(made.status.success(), "the session: {}", text(&made));

    let agent = "Message from desktop-recovery-audit agent: scope corrected";
    let sent = cli(&dir, &["send", "coord", agent], &[("CODEX_THREAD_ID", "thread-1")]);
    assert!(sent.status.success(), "the agent's send: {}", text(&sent));
    let provenance = provenance_of(&dir, agent).expect("the agent's prompt is recorded");
    assert_eq!(provenance["kind"], "agent_message", "{provenance}");
    assert_eq!(provenance["from"], "fromAgent", "{provenance}");
    assert!(
        provenance["fromName"].as_str().is_some_and(|name| name.starts_with("codex@")),
        "{provenance}"
    );
    assert_eq!(provenance["fromHarness"], "codex", "{provenance}");

    let own = "the person's own words from a terminal";
    let sent = cli(&dir, &["send", "coord", own], &[]);
    assert!(sent.status.success(), "the person's send: {}", text(&sent));
    let provenance = provenance_of(&dir, own).expect("the person's prompt is recorded");
    assert!(
        provenance.is_null() || provenance["kind"] == "person_message",
        "the person's send stays theirs: {provenance}"
    );
}
