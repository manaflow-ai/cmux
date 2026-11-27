//! `acpmux watch` and the `acpmux` MCP server's watch tools against a real daemon: a coordinator
//! outside the worker is woken once by the worker's blocker with no polling, irrelevant turns wake
//! nobody, a removed watch still delivers the wake it owes, exactly once across restarts, and the
//! wake's latency from the worker's turn end to the outbox acceptance (ACK) and the recipient's
//! turn, idle and busy.
#![cfg(unix)]
#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();
// These helpers are shared with durable_watch_lifecycle.rs, which uses all of them; this test
// uses only part of each, so the rest would be dead code here.
#[allow(dead_code)]
#[path = "durable_watch_lifecycle/daemon.rs"]
mod daemon;
#[allow(dead_code)]
#[path = "durable_watch_lifecycle/peer.rs"]
mod peer;
use acpmux::rpc::{Message, method};
use daemon::{Daemon, next_wake, observe, quiet};
use peer::Peer;
use serde_json::{Value, json};
use std::{process::Stdio, sync::atomic::Ordering, time::Duration};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

/// `acpmux ARGS` on the daemon's socket: success, stdout, stderr.
async fn cli(a: &Daemon, args: &[&str]) -> (bool, String, String) {
    let out = tokio::time::timeout(
        Duration::from_secs(30),
        daemon_env::tokio_command(a.dir.path(), daemon_env::Agents::StandIn)
            .env("ACPMUX_SOCKET", &a.socket)
            .args(args)
            .kill_on_drop(true)
            .output(),
    )
    .await
    .expect("acpmux exits")
    .unwrap();
    let text = |b: &[u8]| String::from_utf8_lossy(b).into_owned();
    (out.status.success(), text(&out.stdout), text(&out.stderr))
}

/// One `tools/call` to a fresh `acpmux acpmux-mcp` process for chat `session`; its result.
async fn mcp(a: &Daemon, session: &str, name: &str, arguments: Value) -> Value {
    let mut child = daemon_env::tokio_command(a.dir.path(), daemon_env::Agents::StandIn)
        .env("ACPMUX_SOCKET", &a.socket)
        .env("ACPMUX_SESSION_ID", session)
        .arg("acpmux-mcp")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    for line in [
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18",
            "capabilities": {}, "clientInfo": {"name": "watch-test", "version": "0"}}}),
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": name, "arguments": arguments}}),
    ] {
        stdin.write_all(format!("{line}\n").as_bytes()).await.unwrap();
    }
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let result = tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let line = lines.next_line().await.unwrap().expect("an MCP reply");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v["id"] == 2 {
                break v["result"].clone();
            }
        }
    })
    .await
    .expect("the MCP server answers");
    drop(stdin);
    let _ = child.kill().await;
    result
}

fn empty(v: &Value) -> bool {
    v["watches"].as_array().unwrap().is_empty() && v["deliveries"].as_array().unwrap().is_empty()
}

#[tokio::test]
async fn cli_watch_wakes_a_coordinator_session_once_and_drops_irrelevant_turns() {
    let mut a = Daemon::new().await;
    let coord = a.chat("coordinator").await;
    let worker = a.chat("worker").await;
    let bystander = a.chat("bystander").await;
    let mut notes = observe(&a, &coord).await;
    let (ok, out, err) = cli(
        &a,
        &[
            "--json",
            "watch",
            "add",
            "worker",
            "--to",
            "coordinator",
            "--until",
            "ready",
            "--match",
            "BLOCKER",
        ],
    )
    .await;
    assert!(ok, "{err}");
    let watch: Value = serde_json::from_str(&out).unwrap();
    let id = watch["id"].as_str().unwrap().to_owned();
    // Names are bound to session ids once: a rename cannot retarget the watch.
    assert_eq!((&watch["to"], &watch["sessions"]), (&json!(&coord), &json!([&worker])));
    let (ok, listed, _) = cli(&a, &["watch", "ls"]).await;
    assert!(ok && listed.contains(&id) && listed.contains("matching \"BLOCKER\""), "{listed}");
    // The CLI process is gone; the daemon alone holds the watch. Neither a watched turn without
    // the text nor the text on an unwatched session wakes anyone.
    a.prompt(&worker, "routine progress").await;
    a.prompt(&bystander, "BLOCKER somewhere else").await;
    quiet(&mut notes).await;
    a.prompt(&worker, "BLOCKER: needs a review").await;
    let wake = next_wake(&mut notes).await;
    assert!(wake.contains(&worker) && wake.contains("BLOCKER: needs a review"), "{wake}");
    a.settled(empty).await;
    // One-shot: the next blocker wakes nobody, and the watch is gone.
    a.prompt(&worker, "BLOCKER again").await;
    quiet(&mut notes).await;
    assert_eq!(a.wakes(&coord).await.len(), 1);
    let (ok, _, err) = cli(&a, &["watch", "rm", &id]).await;
    assert!(!ok && err.contains("_acpmux/watch_ls"), "{err}");
    a.stop().await;
}

#[tokio::test]
async fn mcp_watch_tools_wake_the_coordinator_and_refuse_bad_calls() {
    let mut a = Daemon::new().await;
    let coord = a.chat("coordinator").await;
    let worker = a.chat("worker").await;
    let mut notes = observe(&a, &coord).await;
    let added = mcp(
        &a,
        &coord,
        "watch_add",
        json!({"sessions": ["worker"], "to": "coordinator", "match": "done-via-mcp"}),
    )
    .await;
    assert_eq!(added["isError"], false, "{added}");
    let id = added["structuredContent"]["id"].as_str().unwrap().to_owned();
    assert!(added["content"][0]["text"].as_str().unwrap().contains("wakes"), "{added}");
    let listed = mcp(&a, &coord, "watch_ls", json!({})).await;
    assert_eq!(listed["structuredContent"]["watches"][0]["id"], json!(&id), "{listed}");
    a.prompt(&worker, "done-via-mcp").await;
    assert!(next_wake(&mut notes).await.contains(&worker));
    a.settled(empty).await;
    for (name, arguments, expected) in [
        ("watch_add", json!({"sessions": []}), "sessions is required"),
        ("watch_add", json!({"sessions": "worker"}), "array of strings"),
        ("watch_add", json!({"sessions": ["worker"]}), "to is required"),
        ("watch_rm", json!({"id": id}), "no watch"),
    ] {
        let refused = mcp(&a, &coord, name, arguments).await;
        assert_eq!(refused["isError"], true, "{refused}");
        let text = refused["content"][0]["text"].as_str().unwrap();
        assert!(text.contains(expected), "{name}: {text}");
    }
    a.stop().await;
}

/// The seam: a wake is owed until the recipient's daemon accepts it (Delivered), and a refused
/// one is listed as failed, never as delivered. Removing the watch keeps what it owes; the owed
/// wake survives a daemon restart and arrives once, and a restart after the ACK sends nothing.
#[tokio::test]
async fn removing_a_watch_keeps_the_wake_it_owes_and_delivers_it_once() {
    let mut a = Daemon::new().await;
    let peer = Peer::new(Duration::ZERO, 1).await;
    peer.reject.store(true, Ordering::SeqCst);
    peer.connect(&a).await;
    let source = a.chat("source").await;
    let (ok, out, err) = cli(
        &a,
        &["--json", "watch", "add", "source", "--to", "scripted/job-0", "--match", "finished"],
    )
    .await;
    assert!(ok, "{err}");
    let id = serde_json::from_str::<Value>(&out).unwrap()["id"].as_str().unwrap().to_owned();
    a.prompt(&source, "finished").await;
    a.settled(|v| v["deliveries"].as_array().unwrap().iter().any(|d| d["status"] == "failed"))
        .await;
    let (_, listed, _) = cli(&a, &["watch", "ls"]).await;
    assert!(listed.contains("Wakes owed:") && listed.contains(": failed (attempt"), "{listed}");
    let (ok, out, err) = cli(&a, &["--json", "watch", "rm", &id]).await;
    assert!(ok, "{err}");
    assert_eq!(serde_json::from_str::<Value>(&out).unwrap(), json!({"removed": id, "owed": 1}));
    assert_eq!(peer.accepted.load(Ordering::SeqCst), 0);
    a.restart().await;
    let saved = a.list().await;
    assert!(saved["watches"].as_array().unwrap().is_empty(), "{saved}");
    assert_eq!(saved["deliveries"].as_array().unwrap().len(), 1, "{saved}");
    peer.reject.store(false, Ordering::SeqCst);
    peer.connect(&a).await;
    a.settled(empty).await;
    assert_eq!(peer.accepted.load(Ordering::SeqCst), 1);
    a.restart().await;
    peer.connect(&a).await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(peer.accepted.load(Ordering::SeqCst), 1, "no wake again after its ACK");
    a.stop().await;
}

/// The next event of `session` of one of `kinds` on the stream, as its record.
async fn next_event(notes: &mut mpsc::Receiver<Message>, session: &str, kinds: &[&str]) -> Value {
    tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            if let Message::Notification { method: m, params: Some(p) } =
                notes.recv().await.expect("notification stream")
                && m == method::MUX_EVENT
                && p["sessionId"] == session
                && kinds.iter().any(|k| p["kind"] == *k)
            {
                break p;
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("{session}: no {kinds:?}"))
}

fn table(name: &str, mut ms: Vec<u64>) -> String {
    ms.sort_unstable();
    let at = |q: f64| ms[((ms.len() - 1) as f64 * q).round() as usize];
    format!("| {name} | {} | {} | {} | {} |", ms.len(), at(0.5), at(0.95), ms[ms.len() - 1])
}

/// Latency on the daemon's own clock (ms), from the watched worker's turn end (generation) to
/// the wake's outbox record (enqueue), its acceptance by the recipient (ACK, outbox `delivered`)
/// and the recipient's log of it as its prompt. Busy: the coordinator is mid-turn, so its ACK
/// and its reading of the wake are two different moments. Every wake arrives exactly once.
#[tokio::test]
async fn wake_latency_from_turn_end_to_ack_and_recipient_idle_and_busy() {
    const IDLE: usize = 30;
    const BUSY: usize = 15;
    let mut a = Daemon::new().await;
    let coord = a.chat("coordinator").await;
    let worker = a.chat("worker").await;
    let mut notes = observe(&a, &coord).await;
    a.call(
        method::MUX_ATTACH,
        json!({"sessionId": &worker, "limit": 0, "eventStream": true, "visible": false}),
    )
    .await;
    let mut seen = std::collections::HashSet::new();
    let (mut rows, mut busy_rows) = (Vec::new(), Vec::new());
    for i in 0..IDLE + BUSY {
        let busy = i >= IDLE;
        // The previous round's trailing events (its turn ends) are not this round's.
        while notes.try_recv().is_ok() {}
        let slow = busy.then(|| {
            let client = a.client.clone();
            let coord = coord.clone();
            tokio::spawn(async move {
                client
                    .request(
                        method::SESSION_PROMPT,
                        json!({"sessionId": coord, "prompt": [{"type": "text", "text": "slow"}]}),
                    )
                    .await
            })
        });
        if busy {
            next_event(&mut notes, &coord, &["turn_started"]).await;
        }
        let text = format!("finished-{i}");
        a.watch(&coord, vec![worker.clone()], "ready", true, Some(text.as_str())).await;
        a.prompt(&worker, &text).await;
        let generated =
            next_event(&mut notes, &worker, &["turn_result"]).await["at"].as_u64().unwrap();
        let read = loop {
            let e = next_event(&mut notes, &coord, &["user_message"]).await;
            if e["msg"]["text"].as_str().is_some_and(|t| t.starts_with("acpmux watch ")) {
                break e["at"].as_u64().unwrap();
            }
        };
        next_event(&mut notes, &coord, &["turn_result"]).await;
        if let Some(slow) = slow {
            slow.await.unwrap().unwrap();
        }
        let list = a.call(method::MUX_SEND_STATUS, json!({"list": true, "limit": 200})).await;
        let d = list["deliveries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|d| d["target"] == coord && !seen.contains(d["deliveryId"].as_str().unwrap()))
            .cloned()
            .expect("the wake's outbox record");
        assert_eq!(d["status"], "delivered", "{d}");
        seen.insert(d["deliveryId"].as_str().unwrap().to_owned());
        let at = |k: &str| d[k].as_u64().unwrap().saturating_sub(generated);
        let row = (at("createdAt"), at("updatedAt"), read.saturating_sub(generated));
        if busy { busy_rows.push(row) } else { rows.push(row) }
    }
    assert_eq!(a.wakes(&coord).await.len(), IDLE + BUSY, "every wake exactly once");
    let cores = std::thread::available_parallelism().map_or(0, usize::from);
    println!(
        "watch wake latency, ms ({} {}, {cores} cores)",
        std::env::consts::OS,
        std::env::consts::ARCH
    );
    println!("| path | n | p50 | p95 | max |\n| --- | --- | --- | --- | --- |");
    for (label, set) in [("idle", &rows), ("busy", &busy_rows)] {
        println!(
            "{}",
            table(&format!("{label}: turn end to enqueue"), set.iter().map(|r| r.0).collect())
        );
        println!(
            "{}",
            table(&format!("{label}: turn end to ACK"), set.iter().map(|r| r.1).collect())
        );
        println!(
            "{}",
            table(
                &format!("{label}: turn end to recipient prompt"),
                set.iter().map(|r| r.2).collect()
            )
        );
    }
    a.stop().await;
}
