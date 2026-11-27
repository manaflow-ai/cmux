//! `acpmux session move` with `ACPMUX_MOVE_HISTORY_LATER` set (`cli/run/transfer.rs`
//! `history_follows`, `hub/transfer_history.rs`): the chat moves with its last turn, and its
//! history follows as a session pack, less the chunks the target says it holds. Leo,
//! 2026-11-24: "i want ultra good compression and being able to rapidly partially decompact".
//!
//! The path is versioned by `transfer-history-later-v1`. A daemon one version older does not
//! list it; a debug build hides it with `ACPMUX_TEST_HIDE_CAPABILITIES` (`capabilities.rs`
//! `ids`). With either side older the move is the full pre-copy, and the target's log is the same.
use super::session_move::prompt;
use super::session_move_live::events;
use super::*;

const HIDE: &str = "ACPMUX_TEST_HIDE_CAPABILITIES";
const LATER: &str = "transfer-history-later-v1";
/// Turns before the last: the history that follows.
const TURNS: usize = 6;

/// A chat moved from `source` to `target` by the CLI with its history set to follow.
struct Moved {
    source: Daemon,
    target: Daemon,
    id: String,
    /// The source's log before the move.
    before: Vec<Value>,
    stderr: String,
}

/// `(seq, kind, msg)` of every record.
fn records(events: &[Value]) -> Vec<(u64, String, Value)> {
    events
        .iter()
        .map(|e| {
            let seq = e["seq"].as_u64().expect("a record has a seq");
            (seq, e["kind"].as_str().unwrap_or_default().to_owned(), e["msg"].clone())
        })
        .collect()
}

/// A chat of `TURNS` long turns and a short last one on a daemon with `source_vars`, moved to one
/// with `target_vars` by `acpmux session move` with `ACPMUX_MOVE_HISTORY_LATER=1`.
async fn moved(tag: &str, source_vars: &[(&str, &str)], target_vars: &[(&str, &str)]) -> Moved {
    let policy = "approve-all";
    let target = Daemon::with_env(&format!("{tag}t"), None, json!({}), target_vars, policy).await;
    let source =
        Daemon::with_env(&format!("{tag}s"), Some(&target), json!({}), source_vars, policy).await;
    let cwd = source.home.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let mut src = Rpc::connect(&source.socket).await;
    let made = src.call("session/new", json!({"cwd": cwd, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    for n in 0..TURNS {
        src.call("session/prompt", prompt(&id, &format!("p-{n}"), "chunks: 2000")).await;
    }
    src.call("session/prompt", prompt(&id, "p-last", "last")).await;
    let before = events(&mut src, &id).await;

    let mut command = daemon_env::tokio_command(&source.home, daemon_env::Agents::Deny);
    command
        .args(["--json", "session", "move", &id, "--machine", "target", "--cwd"])
        .arg(target.home.join("arrived"))
        .env(
            "PATH",
            format!("{}:{}", source.home.join("bin").display(), daemon_env::bare_path(&[])),
        )
        .env("ACPMUX_HOME", &source.home)
        .env("ACPMUX_SOCKET", &source.socket)
        .env("ACPMUX_MOVE_HISTORY_LATER", "1")
        .kill_on_drop(true);
    let out = tokio::time::timeout(Duration::from_secs(90), command.output())
        .await
        .expect("session move completed")
        .expect("run session move");
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    assert!(
        out.status.success(),
        "stdout={} stderr={stderr}",
        String::from_utf8_lossy(&out.stdout)
    );
    let receipt: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(receipt["moves"][0]["moved"], true, "{receipt}");
    assert_eq!(receipt["moves"][0]["targetSessionId"], id.as_str(), "{receipt}");
    Moved { source, target, id, before, stderr }
}

/// The target's log holds every record the source held before the move, at its seq, as it was;
/// and the chat left the source. Returns the target's log.
async fn whole_on_the_target(moved: &Moved) -> Vec<Value> {
    let mut dst = Rpc::connect(&moved.target.socket).await;
    let there = events(&mut dst, &moved.id).await;
    let had = records(&moved.before);
    let last = had.last().expect("the source held records").0;
    let has: Vec<_> = records(&there).into_iter().filter(|(seq, ..)| *seq <= last).collect();
    assert_eq!(has.len(), had.len(), "records through seq {last} on the target");
    for (has, had) in has.iter().zip(&had) {
        assert_eq!(has, had, "the target's record at seq {} differs", had.0);
    }
    let mut src = Rpc::connect(&moved.source.socket).await;
    let left = src.call("_acpmux/info", json!({"sessionId": moved.id})).await;
    assert_eq!(left["status"], "closed", "{left}");
    there
}

fn history_arrived(log: &[Value]) -> Option<&Value> {
    log.iter().find(|e| e["kind"] == "history_arrived")
}

/// Both sides new: the history followed as a pack, and the log on the target is the source's.
/// A second export of it to the same target sends only what the target lacks.
#[tokio::test]
async fn a_history_later_move_sends_a_second_export_only_what_the_target_lacks() {
    let moved = moved("hln", &[], &[]).await;
    let line = moved
        .stderr
        .lines()
        .find(|l| l.contains("history arrived"))
        .unwrap_or_else(|| panic!("the history did not follow: {}", moved.stderr));
    let there = whole_on_the_target(&moved).await;
    let arrived = history_arrived(&there).expect("the target took the history");
    let through = arrived["msg"]["throughSeq"].clone();
    assert!(through.as_u64().unwrap() > 0, "{arrived}");
    // "..., {sent} bytes sent for {raw} of log (...)" (`history_follows`).
    let words: Vec<&str> = line.split_whitespace().collect();
    let at = words.iter().position(|w| *w == "bytes").expect("bytes sent");
    let first: u64 = words[at - 1].parse().unwrap_or_else(|_| panic!("{line}"));
    let raw: u64 = words[at + 3].parse().unwrap_or_else(|_| panic!("{line}"));
    assert!(first > 0 && first < raw, "{line}");

    // A second export to the same target: the target says what it holds, the source leaves it out.
    let (mut src, mut dst) =
        (Rpc::connect(&moved.source.socket).await, Rpc::connect(&moved.target.socket).await);
    let have = dst.call("_acpmux/transfer_history_have", json!({"sessionId": moved.id})).await;
    assert!(!have["have"].as_array().unwrap().is_empty(), "{have}");
    let ask = json!({"sessionId": moved.id, "throughSeq": through, "have": have["have"]});
    let second = src.call("_acpmux/transfer_history_export", ask).await;
    let second_bytes = second["packed"]["bundleBytes"].as_u64().unwrap();
    assert_eq!(second["packed"]["rawBytes"].as_u64(), Some(raw), "{second}");
    assert!(second_bytes * 10 < first, "a second export sent {second_bytes} of {first} bytes");
    eprintln!(
        "history-later move by the CLI: {raw} bytes of log through seq {through}; the first move \
         sent {first} bytes, a second export to the same target {second_bytes} bytes"
    );
}

/// A new source, a target one version older: the full pre-copy, and the same log there.
#[tokio::test]
async fn a_history_later_move_to_an_older_target_moves_whole() {
    let moved = moved("hlo", &[], &[(HIDE, LATER)]).await;
    assert!(!moved.stderr.contains("history arrived"), "{}", moved.stderr);
    let there = whole_on_the_target(&moved).await;
    assert!(history_arrived(&there).is_none(), "no history followed");
}

/// A source one version older, a new target: the full pre-copy, and the same log there.
#[tokio::test]
async fn a_history_later_move_from_an_older_source_moves_whole() {
    let moved = moved("hls", &[(HIDE, LATER)], &[]).await;
    assert!(!moved.stderr.contains("history arrived"), "{}", moved.stderr);
    let there = whole_on_the_target(&moved).await;
    assert!(history_arrived(&there).is_none(), "no history followed");
}
