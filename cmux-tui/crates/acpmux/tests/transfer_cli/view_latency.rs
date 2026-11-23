//! What a moved chat costs the person still looking at it. Leo, 2026-11-23: "if it can "move to
//! cloud" in the BACKEND but i still am able to interact with it with no percievable lag or
//! whatever here ... that's gold."
//!
//! One client stays attached to the first daemon. The same code measures the chat while it runs
//! on that daemon and again after `acpmux session move` put it on the peer, when every request
//! and every update crosses the daemon's peer link (`server/peer_forward.rs`, over the stand-in
//! `ssh -W` of `session_move.rs`):
//!
//! - first token: from writing `session/prompt` to the first `agent_message_chunk` of its reply;
//! - draft: one `_acpmux/draft_set` round trip, what the composer sends as a person types. The
//!   typed character itself is drawn by the composer and never crosses the network.
//!
//! Run: `cargo test -p acpmux --test transfer_cli -- --ignored --nocapture view_latency`.
//! `LATENCY_DELAY_MS` is the round trip of the second, delayed link (default 20).
use super::session_move::prompt;
use super::session_move_live::{Side, move_to_the_other};
use super::*;
use std::time::Instant;

const SAMPLES: usize = 200;

impl Rpc {
    /// [`Rpc::call`] that hands a refusal back instead of failing the test.
    async fn try_call(&mut self, method: &str, params: Value) -> Result<Value, Value> {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.expect("send");
        loop {
            let v = self.message().await;
            if v.get("id") == Some(&json!(id)) {
                return match v.get("error") {
                    Some(error) => Err(error.clone()),
                    None => Ok(v["result"].clone()),
                };
            }
        }
    }

    async fn message(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
            .await
            .expect("daemon answered in time")
            .expect("read")
            .expect("daemon closed the socket");
        serde_json::from_str(&line).expect("json line")
    }
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

/// Two daemons, each the other's ssh peer `target`, their peer links `one_way_ms` slow each way.
async fn linked_pair(tag: &str, one_way_ms: u64) -> [Side; 2] {
    let (a, b) = (format!("{tag}a"), format!("{tag}b"));
    let (port_a, port_b) = (free_port(), free_port());
    let first = Daemon::spawn_linked(
        &a,
        Some(Daemon::place(&b)),
        json!({}),
        Some((port_a, port_b, one_way_ms)),
    )
    .await;
    let second = Daemon::spawn_linked(
        &b,
        Some(Daemon::place(&a)),
        json!({}),
        Some((port_b, port_a, one_way_ms)),
    )
    .await;
    [first, second].map(|daemon| {
        let folder = daemon.home.join("project");
        std::fs::create_dir(&folder).unwrap();
        Side { daemon, folder }
    })
}

/// Milliseconds for `SAMPLES` draft writes and `SAMPLES` first tokens, on a client of `socket`
/// that addresses the chat as `key`. Local and moved run exactly this.
async fn measure(socket: &Path, key: &str, tag: &str) -> (Vec<f64>, Vec<f64>) {
    let mut rpc = Rpc::connect(socket).await;
    rpc.call("_acpmux/attach", json!({"sessionId": key, "limit": 0})).await;
    let mut drafts = Vec::with_capacity(SAMPLES);
    for n in 0..SAMPLES {
        let draft = json!({"sessionId": key, "text": format!("typing {tag} {n}")});
        let started = Instant::now();
        rpc.call("_acpmux/draft_set", draft).await;
        drafts.push(started.elapsed().as_secs_f64() * 1000.0);
    }
    let mut tokens = Vec::with_capacity(SAMPLES);
    for n in 0..SAMPLES {
        let text = format!("{tag} {n}");
        let echo = format!("echo: {text}");
        rpc.next += 1;
        let id = rpc.next;
        let request = json!({"jsonrpc": "2.0", "id": id, "method": "session/prompt",
            "params": prompt(key, &format!("lat-{tag}-{n}"), &text)});
        let line = format!("{request}\n");
        let started = Instant::now();
        rpc.wr.write_all(line.as_bytes()).await.unwrap();
        let (mut first, mut answered) = (None, false);
        while first.is_none() || !answered {
            let message = rpc.message().await;
            let update = &message["params"]["update"];
            if first.is_none()
                && update["sessionUpdate"] == "agent_message_chunk"
                && update["content"]["text"] == echo.as_str()
            {
                first = Some(started.elapsed().as_secs_f64() * 1000.0);
            }
            if message.get("id") == Some(&json!(id)) {
                assert!(message.get("error").is_none(), "prompt {text}: {message}");
                answered = true;
            }
        }
        tokens.push(first.unwrap());
    }
    (drafts, tokens)
}

/// p50, p95 and max of `samples`.
fn spread(samples: &[f64]) -> [f64; 3] {
    let mut sorted = samples.to_vec();
    sorted.sort_by(f64::total_cmp);
    let at =
        |q: f64| sorted[((sorted.len() as f64 * q).ceil() as usize).clamp(1, sorted.len()) - 1];
    [at(0.50), at(0.95), sorted[sorted.len() - 1]]
}

/// One pair at one link delay: the chat measured local, moved, measured again from the same
/// daemon. Returns the JSON row.
async fn run(tag: &str, round_trip_ms: u64) -> Value {
    let sides = linked_pair(tag, round_trip_ms / 2).await;
    let here = &sides[0].daemon.socket;
    let mut rpc = Rpc::connect(here).await;
    let made = rpc.call("session/new", json!({"cwd": sides[0].folder, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    rpc.call("session/prompt", prompt(&id, "p-hi", "hi")).await;

    let (local_draft, local_token) = measure(here, &id, "local").await;
    let moved_in = move_to_the_other(&sides[0], &sides[1], &id, &[]).await;

    // What the first daemon answers a prompt for the chat's own id once the chat has left.
    let plain = rpc.try_call("session/prompt", prompt(&id, "p-plain", "plain")).await;
    let key = match &plain {
        Ok(_) => id.clone(),
        Err(_) => format!("target/{id}"),
    };
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut refused;
    loop {
        match rpc.try_call("_acpmux/attach", json!({"sessionId": key, "limit": 0})).await {
            Ok(_) => break,
            Err(error) => refused = error,
        }
        assert!(
            Instant::now() < deadline,
            "{key} never reachable from the first daemon: {refused}"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let (moved_draft, moved_token) = measure(here, &key, "moved").await;

    // The moved chat really ran on the peer: its own log holds the replies.
    let mut there = Rpc::connect(&sides[1].daemon.socket).await;
    let replies = there.texts(&id, "agent_message_chunk").await;
    let last = format!("echo: moved {}", SAMPLES - 1);
    assert!(replies.contains(&last), "the peer ran the moved chat's prompts");

    let row = |local: &[f64], moved: &[f64]| {
        let (l, m) = (spread(local), spread(moved));
        json!({"local": {"p50": l[0], "p95": l[1], "max": l[2]},
            "moved": {"p50": m[0], "p95": m[1], "max": m[2]},
            "added": {"p50": m[0] - l[0], "p95": m[1] - l[1], "max": m[2] - l[2]}})
    };
    json!({
        "linkRoundTripMs": round_trip_ms,
        "samples": SAMPLES,
        "moveMs": moved_in.as_secs_f64() * 1000.0,
        "movedKey": key.replace(&id, "ID"),
        "plainIdAnswer": match plain { Ok(v) => json!({"ok": v}), Err(e) => json!({"error": e}) },
        "firstTokenMs": row(&local_token, &moved_token),
        "draftSetMs": row(&local_draft, &moved_draft),
    })
}

#[tokio::test]
#[ignore = "a measurement: cargo test -p acpmux --test transfer_cli -- --ignored --nocapture view_latency"]
async fn view_latency_of_a_chat_local_and_moved_to_the_peer() {
    let delayed: u64 =
        std::env::var("LATENCY_DELAY_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(20);
    let rows = [run("vl0", 0).await, run("vld", delayed).await];
    println!("view_latency {}", json!({"bench": "view_latency", "runs": rows}));
    println!(
        "\nOne client on the first daemon; ms over {SAMPLES} samples. The typed character is drawn\n\
         by the composer and never crosses the network: draft_set is what a keystroke sends.\n"
    );
    println!(
        "{:<14} {:<12} {:>24} {:>24} {:>24}",
        "link", "measure", "local p50/p95/max", "moved p50/p95/max", "added p50/p95/max"
    );
    for run in &rows {
        for (name, field) in [("first token", "firstTokenMs"), ("draft_set", "draftSetMs")] {
            let cell = |side: &str| {
                let s = &run[field][side];
                format!(
                    "{:.1}/{:.1}/{:.1}",
                    s["p50"].as_f64().unwrap(),
                    s["p95"].as_f64().unwrap(),
                    s["max"].as_f64().unwrap()
                )
            };
            println!(
                "{:<14} {:<12} {:>24} {:>24} {:>24}",
                format!("{} ms RTT", run["linkRoundTripMs"]),
                name,
                cell("local"),
                cell("moved"),
                cell("added")
            );
        }
    }
    for run in &rows {
        println!(
            "{} ms RTT: moved in {:.0} ms, addressed as {}; the chat's own id answers {}",
            run["linkRoundTripMs"], run["moveMs"], run["movedKey"], run["plainIdAnswer"]
        );
    }
}
