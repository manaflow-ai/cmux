//! End-to-end issue-link action: fake `gh` metadata, an existing fixture repo,
//! a real worktree, and a started chat.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE_AGENT]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

async fn call(hub: &Arc<Hub>, method: &str, params: Value) -> Value {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::LocalApp));
    in_tx.send(Message::request(1, method, params).to_line()).await.unwrap();
    loop {
        let line =
            tokio::time::timeout(Duration::from_secs(30), out_rx.recv()).await.unwrap().unwrap();
        let value: Value = serde_json::from_str(&line).unwrap();
        if value.get("id") == Some(&json!(1)) {
            return value;
        }
    }
}

fn git(dir: &Path, args: &[&str]) {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
        .args(args)
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
}

#[tokio::test]
async fn issue_link_creates_fix_worktree_and_chat() {
    let root = std::env::temp_dir().join(format!("acpmux-fix-link-{}", uuid::Uuid::now_v7()));
    let home = root.join("home");
    let bin = root.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    let gh = bin.join("gh");
    std::fs::write(
        &gh,
        "#!/bin/sh\nprintf '%s' '{\"title\":\"Fix widget\",\"body\":\"It breaks\"}'\n",
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
    let old_path = std::env::var_os("PATH").unwrap_or_default();
    let path =
        std::ffi::OsString::from(format!("{}:{}", bin.display(), old_path.to_string_lossy()));
    // SAFETY: this test owns its hermetic environment and does not run in the app process.
    unsafe {
        std::env::set_var("HOME", &home);
        std::env::set_var("PATH", path);
        std::env::set_var("ACPMUX_HOME", root.join("acpmux"));
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", root.join("cmux-next.json"));
    }
    let repo = root.join("widget");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["remote", "add", "origin", "https://github.com/acme/widget.git"]);
    git(&repo, &["commit", "-q", "--allow-empty", "-m", "first"]);

    let daemon = hub();
    let trust = acpmux::trust::Paths {
        claude_json: home.join("claude.json"),
        codex_config: home.join("codex.toml"),
        record: home.join("trust.json"),
        agent_home: None,
        cmux_worktrees: Some(home.join(".cmux/worktrees")),
        peer_scratch: None,
    };
    daemon.set_trust_gate(Some(trust.clone()));
    let params = json!({"url": "https://github.com/acme/widget/issues/12", "cwd": repo});
    let pending = call(&daemon, "chat.fix_from_link.prepare", params.clone()).await;
    assert_eq!(pending["error"]["data"]["reason"], "trust.pending", "{pending}");
    assert!(!home.join(".cmux/worktrees").exists());
    acpmux::trust::set(&trust, repo.to_str().unwrap(), "untrusted").unwrap();
    let declined = call(&daemon, "chat.fix_from_link.prepare", params.clone()).await;
    assert_eq!(declined["error"]["data"]["reason"], "trust.untrusted", "{declined}");
    assert!(!home.join(".cmux/worktrees").exists());
    acpmux::trust::set(&trust, repo.to_str().unwrap(), "trusted").unwrap();
    let prepared = call(&daemon, "chat.fix_from_link.prepare", params.clone()).await;
    assert_eq!(prepared["result"]["cwd"], json!(repo), "{prepared}");
    assert!(!home.join(".cmux/worktrees").exists(), "preparation must not create a worktree");
    // Launch rechecks trust independently, even after a successful preparation.
    acpmux::trust::set(&trust, repo.to_str().unwrap(), "untrusted").unwrap();
    let revoked = call(&daemon, "chat.fix_from_link", params.clone()).await;
    assert_eq!(revoked["error"]["data"]["reason"], "trust.untrusted", "{revoked}");
    assert!(!home.join(".cmux/worktrees").exists());
    acpmux::trust::set(&trust, repo.to_str().unwrap(), "trusted").unwrap();
    let result = call(&daemon, "chat.fix_from_link", params).await;
    assert!(result.get("error").is_none(), "{result}");
    assert_eq!(result["result"]["branch"], "fix/12-fix-widget");
    assert!(result["result"]["sessionId"].as_str().is_some());
    assert!(result["result"]["worktree"].as_str().is_some());
    assert!(root.join("home/.cmux/worktrees/widget/12-fix-widget").is_dir());
    let _ = std::fs::remove_dir_all(root);
}
