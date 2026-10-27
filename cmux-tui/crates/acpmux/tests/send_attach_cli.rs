//! `acpmux send --attach FILE` from a terminal or an agent's shell, against a real daemon: the
//! receiving lane's agent gets the image, the file is saved owner-only in the lane's uploads,
//! `--no-wait` (the outbox) carries it too, and files of any size and number go by reference
//! (`src/attach.rs`, claude-sr2's screenshots to big-red, 2026-10-25; Leo, 2026-10-26: "I ALREADY
//! SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE").
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

/// Every file named `name` under the daemon's uploads (`<session>/<prompt id>/<name>`).
fn uploads_named(dir: &Path, name: &str) -> Vec<PathBuf> {
    let entries = |d: &Path| fs::read_dir(d).into_iter().flatten().flatten().map(|e| e.path());
    let sessions: Vec<_> = entries(&dir.join("uploads")).collect();
    let folders: Vec<_> = sessions.iter().flat_map(|s| entries(s)).collect();
    folders.iter().map(|f| f.join(name)).filter(|p| p.is_file()).collect()
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
    assert!(
        String::from_utf8_lossy(&last.stdout).contains(&format!("image:{sha}")),
        "{}",
        text(&last)
    );
    assert_eq!(uploads_named(&dir, "screen.txt").len(), 2);
}

fn sha(bytes: &[u8]) -> String {
    sha2::Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// Past what one message holds (a 24 MiB file, 20 screenshots, an image too large to show inline):
/// every file is uploaded to the lane first and named by reference, so nothing is refused for its
/// size or number. The screenshots reach the agent as images, the rest by path, bytes intact.
#[test]
fn send_attach_sends_files_of_any_size_and_number_by_reference() {
    let dir = scratch("r");
    let _shutdown = Shutdown(&dir);
    let made = cli(&dir, &["run", "-n", "lane", "warm up"]);
    assert!(made.status.success(), "the session: {}", text(&made));
    let big: Vec<u8> = (0..24usize << 20).map(|i| (i as u8) ^ (i >> 12) as u8).collect();
    fs::write(dir.join("p/big.bin"), &big).unwrap();
    let mut large = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
    large.resize(6 << 20, 9);
    fs::write(dir.join("p/large.png"), &large).unwrap();
    let mut args = vec!["send", "-q", "lane", "all of these", "--attach", "big.bin"];
    args.extend(["--attach", "large.png"]);
    let mut shots = Vec::new();
    for n in 0..20u8 {
        let mut shot = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        shot.resize(64 << 10, n);
        fs::write(dir.join(format!("p/shot{n}.png")), &shot).unwrap();
        shots.push(shot);
    }
    let names: Vec<String> = (0..20).map(|n| format!("shot{n}.png")).collect();
    for name in &names {
        args.extend(["--attach", name.as_str()]);
    }
    let sent = cli(&dir, &args);
    assert!(sent.status.success(), "{}", text(&sent));
    let reply = String::from_utf8_lossy(&sent.stdout);
    for shot in &shots {
        assert!(reply.contains(&format!("image:{}", sha(shot))), "{}", text(&sent));
    }
    assert!(reply.contains("resource_link:big.bin:"), "{}", text(&sent));
    assert!(reply.contains("resource_link:large.png:image/png:"), "{}", text(&sent));
    for (name, bytes) in [("big.bin", &big), ("large.png", &large)] {
        let saved = uploads_named(&dir, name);
        assert_eq!(saved.len(), 1, "{name}: {saved:?}");
        assert_eq!(sha(&fs::read(&saved[0]).unwrap()), sha(bytes), "{name}");
        assert_eq!(fs::metadata(&saved[0]).unwrap().permissions().mode() & 0o777, 0o600);
    }

    // Text and a file that together pass one JSON-RPC message (15 MiB) go the same way.
    fs::write(dir.join("p/eight.bin"), vec![7u8; 8 << 20]).unwrap();
    let mut cmd = daemon_env::command(&dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(["send", "-q", "lane", "-", "--attach", "eight.bin"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_LOGIN_ENV", "0")
        .current_dir(dir.join("p"))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut child = cmd.spawn().unwrap();
    use std::io::Write;
    let _ = child.stdin.take().unwrap().write_all("x".repeat(5 << 20).as_bytes());
    let sent = child.wait_with_output().unwrap();
    assert!(sent.status.success(), "{}", text(&sent));
    let saved = uploads_named(&dir, "eight.bin");
    assert_eq!(saved.len(), 1, "{saved:?}");
    assert_eq!(fs::read(&saved[0]).unwrap(), vec![7u8; 8 << 20]);
}
