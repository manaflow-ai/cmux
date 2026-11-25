//! `handoff-gap` (RFD 0082, cmuxterm-hq docs/rfd/0082-make-before-break-handoffs.md, order step 2): how
//! long a connected client goes without an answer while a new daemon takes the home over (`daemon run
//! --take-over`, as every cmux NIGHTLY install and daemon update starts one). A client holds a
//! connection and asks the cheap `_acpmux/status` read every 10 ms, the way a client that reconnects
//! at once would: on a refused connect, a closed socket or an unanswered read it counts a failed
//! request and dials again. Each take-over's gap is the time from the last answer the old daemon gave
//! to the first answer from the new one (told apart by the pid `_acpmux/status` reports). The daemon
//! carries load meanwhile: agents inside a tool call and idle chats, as on a working Mac.
//!
//! Prints one `HANDOFF_GAP {...}` line (n, p50_ms, p95_ms, max_ms, failed_requests) so a run on the
//! base and one on a fix (RFD 0082 path 3, listener handover) compare from the same harness, and fails
//! only past a bound far above today's, so it catches a regression without flaking on noise.
//!
//! Leo, 2026-11-23: "how can you do better handoffs all around? restarting... ok what if you made a
//! f***ing new one and had that gracefully and quickly transition to it? similar to network drains."

use super::*;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

const RUNNING: usize = 2;
const IDLE: usize = 8;
const TAKE_OVERS: usize = 20;
const PROBE_EVERY: Duration = Duration::from_millis(10);
/// A read the daemon does not answer in this long counts as failed and the client dials again.
const READ_BOUND: Duration = Duration::from_secs(2);

/// One answer: when it came and which daemon (pid) gave it.
type Answer = (Instant, u64);

/// One `_acpmux/status` on `conn`; `None` when the connection broke or the read went unanswered.
async fn status_pid(conn: &mut Rpc) -> Option<u64> {
    let id = {
        conn.next += 1;
        conn.next
    };
    let line = json!({"jsonrpc": "2.0", "id": id, "method": "_acpmux/status", "params": {}});
    conn.wr.write_all(format!("{line}\n").as_bytes()).await.ok()?;
    let read = async {
        loop {
            let text = conn.lines.next_line().await.ok()??;
            let v: Value = serde_json::from_str(&text).ok()?;
            if v.get("id") == Some(&json!(id)) {
                return v["result"]["pid"].as_u64();
            }
        }
    };
    tokio::time::timeout(READ_BOUND, read).await.ok()?
}

async fn dial(socket: &Path) -> Option<Rpc> {
    let s = tokio::net::UnixStream::connect(socket).await.ok()?;
    let (rd, wr) = s.into_split();
    Some(Rpc { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0 })
}

/// The client: asks every [`PROBE_EVERY`] until `stop`, redialing at once after any failure.
async fn probe(socket: PathBuf, stop: Arc<AtomicBool>, failed: Arc<AtomicU64>) -> Vec<Answer> {
    let mut answers = Vec::new();
    let mut conn: Option<Rpc> = None;
    while !stop.load(Ordering::Relaxed) {
        if conn.is_none() {
            conn = dial(&socket).await;
        }
        let answered = match conn.as_mut() {
            Some(c) => status_pid(c).await,
            None => None,
        };
        match answered {
            Some(pid) => answers.push((Instant::now(), pid)),
            None => {
                failed.fetch_add(1, Ordering::Relaxed);
                conn = None;
            }
        }
        tokio::time::sleep(PROBE_EVERY).await;
    }
    answers
}

/// The gap of one take-over from `old` to `new`: last answer from `old`, first from `new`.
fn gap_ms(answers: &[Answer], old: u64, new: u64) -> Option<u128> {
    let last_old = answers.iter().rev().find(|(_, pid)| *pid == old)?.0;
    let first_new = answers.iter().find(|(_, pid)| *pid == new)?.0;
    Some(first_new.saturating_duration_since(last_old).as_millis())
}

fn percentile(sorted: &[u128], p: usize) -> u128 {
    sorted[((sorted.len() * p).div_ceil(100)).saturating_sub(1).min(sorted.len() - 1)]
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn handoff_gap_across_take_overs_under_load() {
    let mut daemon = Daemon::new("hgap", "approve-all");
    let mut running = Vec::new();
    let mut clients = Vec::new();
    for i in 0..RUNNING {
        let session = new_session(&daemon).await;
        let gate = daemon.home.join(format!("g{i}"));
        make_fifo(&gate);
        let mut client = daemon.rpc().await;
        client
            .send(
                "session/prompt",
                json!({"sessionId": session,
                       "prompt": [{"type": "text", "text": format!("work-gate: {}", gate.display())}]}),
            )
            .await;
        clients.push(client);
        running.push((session, gate));
    }
    for (session, _) in &running {
        daemon.wait_event(session, "the running tool call", |e| e["kind"] == "tool_call");
    }
    drop(clients);
    for i in 0..IDLE {
        let session = new_session(&daemon).await;
        let mut rpc = daemon.rpc().await;
        rpc.call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("idle chat {i}")}]}),
        )
        .await;
    }

    let stop = Arc::new(AtomicBool::new(false));
    let failed = Arc::new(AtomicU64::new(0));
    let prober = tokio::spawn(probe(daemon.socket.clone(), stop.clone(), failed.clone()));
    // The client is answered by the first daemon before any take-over starts.
    tokio::time::sleep(Duration::from_millis(200)).await;

    let mut pids = vec![daemon.child.as_ref().unwrap().id() as u64];
    for n in 0..TAKE_OVERS {
        tokio::task::block_in_place(|| daemon.take_over());
        pids.push(daemon.child.as_ref().unwrap().id() as u64);
        // The client must reach the new daemon before the next take-over, so each gap is its own.
        tokio::time::sleep(Duration::from_millis(300)).await;
        eprintln!("handoff_gap: take-over {n} done");
    }
    stop.store(true, Ordering::Relaxed);
    let answers = prober.await.unwrap();
    let failed_requests = failed.load(Ordering::Relaxed);

    let mut gaps = Vec::new();
    for (n, pair) in pids.windows(2).enumerate() {
        let gap = gap_ms(&answers, pair[0], pair[1])
            .unwrap_or_else(|| panic!("take-over {n}: the client never heard from both daemons"));
        eprintln!("handoff_gap: take-over {n}: {gap} ms");
        gaps.push(gap);
    }
    let mut sorted = gaps.clone();
    sorted.sort_unstable();
    let (p50, p95, max) =
        (percentile(&sorted, 50), percentile(&sorted, 95), sorted[sorted.len() - 1]);
    println!(
        "HANDOFF_GAP {}",
        json!({"path": "acpmux-take-over", "n": gaps.len(), "p50_ms": p50, "p95_ms": p95,
               "max_ms": max, "failed_requests": failed_requests, "gaps_ms": gaps})
    );

    for (_, gate) in &running {
        let mut writer = std::fs::OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(gate)
            .expect("the agent still waits on its gate");
        std::io::Write::write_all(&mut writer, b"go").unwrap();
    }
    for (session, _) in &running {
        daemon.wait_event(session, "the tool call's end", |e| chunk(e, "worked"));
    }
    // Far above today's handover, so this catches a regression and not noise. RFD 0082's target for
    // this path is under 0.2 s with 0 failed requests; tighten this once listener handover lands.
    assert!(max < 10_000, "a take-over left the client unanswered {max} ms: {gaps:?}");
}
