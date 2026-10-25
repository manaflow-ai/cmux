//! `acpmux send --attach FILE` from a terminal or an agent's shell, against a real daemon: the
//! receiving lane's agent gets the image, the file is saved owner-only in the lane's uploads,
//! `--no-wait` (the outbox) carries it too, and a file over the cap is refused before anything is
//! sent (`src/attach.rs`, claude-sr2's screenshots to big-red, 2026-10-25).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::json;
use sha2::Digest;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Output;

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-att-{tag}-{}", std::process::id()));
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

fn cli(dir: &Path, args: &[&str]) -> Output {
    let mut cmd = daemon_env::command(dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(args).env("ACPMUX_HOME", dir).env("ACPMUX_LOGIN_ENV", "0").current_dir(dir.join("p"));
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
        let _ = cli(self.0, &["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(self.0);
    }
}

/// Every file named `name` under the daemon's uploads.
fn uploads_named(dir: &Path, name: &str) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![dir.join("uploads")];
    while let Some(d) = stack.pop() {
        for entry in fs::read_dir(&d).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.file_name().and_then(|n| n.to_str()) == Some(name) {
                out.push(path);
            }
        }
    }
    out
}

#[test]
fn send_attach_delivers_an_image_to_the_lane_and_saves_it_owner_only() {
    let dir = scratch("s");
    let _shutdown = Shutdown(&dir);
    let made = cli(&dir, &["run", "-n", "lane", "warm up"]);
    assert!(made.status.success(), "the session: {}", text(&made));
    let mut shot = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
    shot.resize(2048, 3);
    let sha: String = sha2::Sha256::digest(&shot).iter().map(|b| format!("{b:02x}")).collect();
    // Named .txt: the type comes from the bytes.
    fs::write(dir.join("p/screen.txt"), &shot).unwrap();
    fs::write(dir.join("p/notes.md"), b"# notes\n").unwrap();

    let sent = cli(
        &dir,
        &["send", "-q", "lane", "look at this", "--attach", "screen.txt", "--attach", "notes.md"],
    );
    assert!(sent.status.success(), "{}", text(&sent));
    let reply = String::from_utf8_lossy(&sent.stdout);
    assert!(reply.contains(&format!("image:{sha}")), "the agent got no image: {}", text(&sent));
    assert!(reply.contains("resource_link:notes.md:"), "{}", text(&sent));
    let saved = uploads_named(&dir, "screen.txt");
    assert_eq!(saved.len(), 1, "{saved:?}");
    assert_eq!(fs::read(&saved[0]).unwrap(), shot);
    assert_eq!(fs::metadata(&saved[0]).unwrap().permissions().mode() & 0o777, 0o600);

    // Through the outbox (`--no-wait`) too.
    let queued = cli(&dir, &["send", "--no-wait", "lane", "again", "--attach", "screen.txt"]);
    assert!(queued.status.success(), "{}", text(&queued));
    let waited = cli(&dir, &["wait", "lane", "--timeout", "20"]);
    assert!(waited.status.success(), "{}", text(&waited));
    let last = cli(&dir, &["last", "lane"]);
    assert!(String::from_utf8_lossy(&last.stdout).contains(&format!("image:{sha}")), "{}", text(&last));
    assert_eq!(uploads_named(&dir, "screen.txt").len(), 2);

    // Over the cap (8 MiB a file): refused before anything is sent, saying the cap.
    fs::write(dir.join("p/huge.png"), vec![0u8; (8 << 20) + 1]).unwrap();
    let big = cli(&dir, &["send", "-q", "lane", "big", "--attach", "huge.png"]);
    assert!(!big.status.success(), "{}", text(&big));
    assert!(text(&big).contains("8 MiB"), "{}", text(&big));
    assert!(uploads_named(&dir, "huge.png").is_empty());
    // A file that is not there names itself.
    let missing = cli(&dir, &["send", "-q", "lane", "gone", "--attach", "gone.png"]);
    assert!(!missing.status.success(), "{}", text(&missing));
    assert!(text(&missing).contains("gone.png"), "{}", text(&missing));
}
