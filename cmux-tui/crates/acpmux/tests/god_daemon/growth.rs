//! A growth lab: the daemon of a host with many sessions and a mesh of peers that come and go,
//! as on a Linux host (2026-11-20) whose daemon grew about 55 MB a minute from its start, to
//! 4.4 GB in 79 minutes at 128% CPU, and then answered no hello. That host had about 100 agent
//! sessions, several `ssh://` peers, some down for long and some reconnecting, and agents running
//! `acpmux ls` and `acpmux send` every few seconds.
//!
//! The lab runs, for `ACPMUX_GROWTH_SECS`:
//!
//! - peers that stay up (`ACPMUX_GROWTH_STABLE`), peers whose link is cut every
//!   `ACPMUX_GROWTH_CUT_MS` and that restart every other cut (`ACPMUX_GROWTH_CHURN`), each listing
//!   `ACPMUX_GROWTH_ROWS` chats;
//! - peers that never answer: one whose listener refuses (its proxy closes each connection), one
//!   that takes the connection and never carries it, and `ssh://` peers on a closed port;
//! - the local chats (`ACPMUX_GROWTH_CHATS`), prompted in turn so stand-in agents run and stream;
//! - a client that reads everything (the app's list), and one that watches and never reads;
//! - short clients, `ACPMUX_GROWTH_CLIENTS` at a time, each every `ACPMUX_GROWTH_CLIENT_MS`:
//!   `acpmux ls`, a status read, and a prompt to a churning peer's chat (refused as
//!   `peer_unreachable` while it is down), then the connection closes.
//!
//! It prints the daemon's RSS every few seconds (`GROWTH-RSS secs rssMiB`), then the heap by
//! allocation site with `ACPMUX_GOD_DHAT=1` and a `dhat-heap` binary: held at the end
//! (`GROWTH-HEAP-END`), the bytes a run left behind. Two runs of different lengths name the site
//! that grows: its end bytes grow with the run.
//! Manual, on Linux CI:
//! `CARGO_PROFILE_RELEASE_DEBUG=line-tables-only ACPMUX_GOD_DHAT=1 cargo test -p acpmux --release
//! --features dhat-heap --test acpmux_all growth -- --ignored --nocapture`.

use super::*;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

fn knob<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// One peer's hub, restartable on a new port over the same rows and token.
struct Peer {
    name: String,
    rows: usize,
    auth: Arc<PeerAuth>,
    serving: Option<tokio::task::AbortHandle>,
}

impl Peer {
    async fn start(&mut self) -> u16 {
        if let Some(old) = self.serving.take() {
            old.abort();
        }
        let mut cfg = Config::default();
        cfg.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        for i in 0..self.rows {
            store
                .save(&serde_json::from_value(god_fixture::peer_meta(&self.name, i)).unwrap())
                .unwrap();
        }
        let hub = Hub::new(cfg, store);
        let listener = bind_ws("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let auth = WsAuth { local_app: None, peer: Some(self.auth.clone()) };
        self.serving =
            Some(tokio::spawn(serve_ws_with(hub, listener, "tok".into(), auth)).abort_handle());
        port
    }
}

/// A port nothing listens on.
fn closed_port() -> u16 {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    l.local_addr().unwrap().port()
}

#[derive(Default)]
struct Counts {
    clients: AtomicU64,
    client_errors: AtomicU64,
    cli: AtomicU64,
    cli_failed: AtomicU64,
    refused: AtomicU64,
    prompts: AtomicU64,
    cuts: AtomicU64,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "manual: a growth lab; run on Linux CI"]
async fn growth_under_mesh_churn_and_short_clients() {
    let secs: u64 = knob("ACPMUX_GROWTH_SECS", 300);
    let rows: usize = knob("ACPMUX_GROWTH_ROWS", 100);
    let stable: usize = knob("ACPMUX_GROWTH_STABLE", 2);
    let churn: usize = knob("ACPMUX_GROWTH_CHURN", 2);
    let ssh_down: usize = knob("ACPMUX_GROWTH_SSH_DOWN", 2);
    let cut_every = Duration::from_millis(knob("ACPMUX_GROWTH_CUT_MS", 5_000));
    let chats: usize = knob("ACPMUX_GROWTH_CHATS", 20);
    let clients: usize = knob("ACPMUX_GROWTH_CLIENTS", 4);
    let client_every = Duration::from_millis(knob("ACPMUX_GROWTH_CLIENT_MS", 1_000));

    let scratch = daemon_env::Scratch::new("god-growth");
    let home = scratch.join("acpmux");
    let claude = daemon_env::home(&scratch).join(".claude");
    let shape = Shape { name: "growth", peers: 0, chats, god_messages: 200, ..Shape::small() };
    let made = god_fixture::write_home(&home, &claude, &scratch.join("work"), &shape).unwrap();

    // The peers.
    let mut config = serde_json::Map::new();
    let mut churning: Vec<(Peer, Proxy)> = vec![];
    let mut kept: Vec<(Peer, Proxy)> = vec![];
    for p in 0..stable + churn {
        let name = format!("peer{p:02}");
        let peer_home = scratch.join(format!("peer-{p}"));
        std::fs::create_dir_all(&peer_home).unwrap();
        let auth = Arc::new(PeerAuth::create(&peer_home).unwrap());
        let token =
            std::fs::read_to_string(acpmux::server::peer_auth::token_path(&peer_home)).unwrap();
        let mut peer = Peer { name: name.clone(), rows, auth, serving: None };
        let proxy = Proxy::start(peer.start().await).await;
        config.insert(
            name,
            json!({"url": format!("ws://127.0.0.1:{}", proxy.port), "token": "tok",
                   "peerToken": token.trim()}),
        );
        if p < stable { kept.push((peer, proxy)) } else { churning.push((peer, proxy)) }
    }
    // Down: a proxy whose peer refuses every connection, one held shut (takes the connection and
    // carries nothing), and ssh peers on a closed port.
    let refusing = Proxy::start(closed_port()).await;
    config.insert(
        "refusing".into(),
        json!({"url": format!("ws://127.0.0.1:{}", refusing.port), "token": "tok"}),
    );
    let (_shut_tx, shut) = tokio::sync::watch::channel(false);
    let hanging = Proxy::gated(closed_port(), shut).await;
    config.insert(
        "hanging".into(),
        json!({"url": format!("ws://127.0.0.1:{}", hanging.port), "token": "tok"}),
    );
    for s in 0..ssh_down {
        config.insert(
            format!("sshdown{s}"),
            json!({"url": format!("ssh://127.0.0.1:{}", closed_port())}),
        );
    }
    write_config(&home, Value::Object(config));

    let profile = std::env::var("ACPMUX_GOD_DHAT")
        .is_ok_and(|v| v == "1")
        .then(|| scratch.join("dhat-heap.json"));
    let mut daemon = Daemon::start(&scratch, &home, profile.as_deref());
    let socket = daemon.socket.clone();
    let mut rpc = Rpc::connect(&socket);
    rpc.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "growth-app"}}))
        .unwrap();
    rpc.call("_acpmux/watch", json!({"enabled": true})).unwrap();
    let listed = wait_listed(&mut rpc, stable + churn, (stable + churn) * rows);
    rpc.notes.clear();
    let (rss_listed, _) = daemon.rss();
    println!("GROWTH-START listedMs={listed:?} rss={}", rss_listed >> 20);

    // Clients that watch and never read (`ACPMUX_GROWTH_SLOW`): an agent's MCP bridge or a
    // stopped app holding its connection.
    let slow: Vec<UnixStream> = (0..knob("ACPMUX_GROWTH_SLOW", 1usize))
        .map(|n| {
            let mut slow = UnixStream::connect(&socket).unwrap();
            for (id, (m, p)) in [
                ("initialize",
                 json!({"protocolVersion": 1, "clientInfo": {"name": format!("growth-slow-{n}")}})),
                ("_acpmux/watch", json!({"enabled": true})),
            ]
            .into_iter()
            .enumerate()
            {
                let line = json!({"jsonrpc": "2.0", "id": id + 1, "method": m, "params": p});
                slow.write_all(format!("{line}\n").as_bytes()).unwrap();
            }
            slow
        })
        .collect();

    let stop = Arc::new(AtomicBool::new(false));
    let counts = Arc::new(Counts::default());

    // The churn: cut each churning peer's link every `cut_every`, restarting it every other cut.
    let cutter = {
        let (stop, counts) = (stop.clone(), counts.clone());
        tokio::spawn(async move {
            let mut n = 0u64;
            while !stop.load(Ordering::Relaxed) {
                for (peer, proxy) in &mut churning {
                    if n % 2 == 1 {
                        proxy.repoint(peer.start().await);
                    }
                    proxy.cut();
                    counts.cuts.fetch_add(1, Ordering::Relaxed);
                }
                n += 1;
                tokio::time::sleep(cut_every).await;
            }
            churning
        })
    };

    // Short clients: `acpmux ls`, a status read, a prompt to a churning peer's chat.
    let mut short = vec![];
    for c in 0..clients {
        let (stop, counts, socket) = (stop.clone(), counts.clone(), socket.clone());
        let (home, scratch) = (home.clone(), scratch.to_path_buf());
        let target = format!("peer{:02}-{:05}", stable + c % churn.max(1), c % rows.max(1));
        short.push(std::thread::spawn(move || {
            let mut round = 0u64;
            while !stop.load(Ordering::Relaxed) {
                round += 1;
                {
                    // `acpmux ls`, or an agent's `acpmux send` to a churning peer's chat (a
                    // delivery the daemon keeps and retries while the peer is down).
                    // Every other send goes to a chat on a down ssh peer, as an agent does to a
                    // machine that is off.
                    let text = format!("note {c} {round}");
                    let down = format!("sshdown{}/lane-{c}", c % ssh_down.max(1));
                    let args: Vec<&str> = match round % 4 {
                        0 | 2 => vec!["ls", "--json"],
                        1 => vec!["send", "--no-wait", &target, &text],
                        _ if ssh_down > 0 => vec!["send", "--no-wait", &down, &text],
                        _ => vec!["send", "--no-wait", &target, &text],
                    };
                    let out = daemon_env::command(&scratch, daemon_env::Agents::StandIn, &[])
                        .args(&args)
                        .env("ACPMUX_HOME", &home)
                        .env("ACPMUX_SOCKET", &socket)
                        .stdin(Stdio::null())
                        .stdout(Stdio::null())
                        .stderr(Stdio::piped())
                        .output();
                    counts.cli.fetch_add(1, Ordering::Relaxed);
                    match out {
                        Ok(o) if o.status.success() => {}
                        Ok(o) => {
                            if counts.cli_failed.fetch_add(1, Ordering::Relaxed) < 4 {
                                println!(
                                    "GROWTH-CLI-FAIL {} {}",
                                    args[0],
                                    String::from_utf8_lossy(&o.stderr).lines().next().unwrap_or("")
                                );
                            }
                        }
                        Err(e) => {
                            counts.cli_failed.fetch_add(1, Ordering::Relaxed);
                            println!("GROWTH-CLI-FAIL {e}");
                        }
                    }
                }
                let Ok(s) = UnixStream::connect(&socket) else {
                    counts.client_errors.fetch_add(1, Ordering::Relaxed);
                    continue;
                };
                s.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
                let mut r = Rpc {
                    reader: BufReader::new(s.try_clone().unwrap()),
                    writer: s,
                    next: 0,
                    notes: vec![],
                    line: String::new(),
                    read_bytes: 0,
                    longest_line: 0,
                    flood: Flood::default(),
                    batch_notes: vec![],
                };
                counts.clients.fetch_add(1, Ordering::Relaxed);
                let init = r.call(
                    "initialize",
                    json!({"protocolVersion": 1, "clientInfo": {"name": format!("growth-{c}")}}),
                );
                if init.is_err() {
                    counts.client_errors.fetch_add(1, Ordering::Relaxed);
                    continue;
                }
                let _ = r.call("_acpmux/status", json!({}));
                let prompt = json!({"sessionId": target,
                                    "prompt": [{"type": "text", "text": format!("hi {round}")}]});
                let id = r.request("session/prompt", prompt);
                // Not the turn's end: the reply or an error, or a short wait.
                let deadline = Instant::now() + Duration::from_secs(2);
                if let Ok(v) = r.wait_note_until(|v| is_response(v, id), Some(deadline))
                    && v.get("error").is_some()
                {
                    counts.refused.fetch_add(1, Ordering::Relaxed);
                }
                drop(r);
                std::thread::sleep(client_every);
            }
        }));
    }

    // The app: prompts the local chats in turn, reads everything, samples the RSS.
    let mut ids = vec![made.god.clone()];
    ids.extend(made.others.iter().cloned());
    let started = Instant::now();
    let mut samples: Vec<(u64, u64)> = vec![];
    let mut next_sample = Duration::ZERO;
    let mut turn = 0usize;
    while started.elapsed() < Duration::from_secs(secs) {
        let id = &ids[turn % ids.len()];
        turn += 1;
        let prompt =
            json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("go {turn}")}]});
        let req = rpc.request("session/prompt", prompt);
        let _ = rpc.wait_note_until(
            |v| is_response(v, req),
            Some(Instant::now() + Duration::from_secs(10)),
        );
        rpc.writer.set_read_timeout(Some(STEP)).unwrap();
        counts.prompts.fetch_add(1, Ordering::Relaxed);
        rpc.notes.clear();
        if started.elapsed() >= next_sample {
            next_sample += Duration::from_secs(5);
            let (rss, _) = daemon.rss();
            let at = started.elapsed().as_secs();
            samples.push((at, rss));
            let status = rpc.call("_acpmux/status", json!({})).unwrap_or_default();
            rpc.notes.clear();
            println!(
                "GROWTH-RSS {at} {} outbox={} cuts={} clients={} cli={} refused={} prompts={}",
                rss >> 20,
                status["outboxPending"],
                counts.cuts.load(Ordering::Relaxed),
                counts.clients.load(Ordering::Relaxed),
                counts.cli.load(Ordering::Relaxed),
                counts.refused.load(Ordering::Relaxed),
                counts.prompts.load(Ordering::Relaxed),
            );
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    stop.store(true, Ordering::Relaxed);
    let status = rpc.call("_acpmux/status", json!({})).unwrap_or_default();
    rpc.notes.clear();
    for t in short {
        let _ = t.join();
    }
    let _churning = cutter.await.unwrap();
    let (rss_end, peak_rss) = daemon.rss();
    drop(slow);
    drop(rpc);
    daemon.stop();

    // The slope over the run's second half, MiB a minute.
    let half: Vec<&(u64, u64)> = samples.iter().filter(|(t, _)| *t >= secs / 2).collect();
    let slope = match (half.first(), half.last()) {
        (Some((t0, r0)), Some((t1, r1))) if t1 > t0 => {
            (*r1 as f64 - *r0 as f64) / 1_048_576.0 / ((t1 - t0) as f64 / 60.0)
        }
        _ => 0.0,
    };
    let heap = profile.as_deref().map(attribute);
    // The blocks held at the end, by whole stack: the largest few, every frame (a site's first
    // acpmux frames may all be inlined into one task's future).
    if let Some(path) = profile.as_deref()
        && let Ok(text) = std::fs::read_to_string(path)
        && let Ok(doc) = serde_json::from_str::<Value>(&text)
    {
        let ftbl: Vec<&str> = doc["ftbl"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|f| f.as_str().unwrap_or(""))
            .collect();
        let mut pps: Vec<&Value> = doc["pps"].as_array().into_iter().flatten().collect();
        pps.sort_by_key(|pp| std::cmp::Reverse(pp["eb"].as_u64().unwrap_or(0)));
        for (n, pp) in pps.iter().take(knob("ACPMUX_GROWTH_STACKS", 6)).enumerate() {
            println!("GROWTH-STACK {n} endBytes={} endBlocks={}", pp["eb"], pp["ebk"]);
            for f in pp["fs"].as_array().into_iter().flatten() {
                let frame = ftbl.get(f.as_u64().unwrap_or(0) as usize).copied().unwrap_or("");
                println!("GROWTH-STACK {n}   {}", short_frame(frame));
            }
        }
    }
    let result = json!({
        "secs": secs, "rows": rows, "stable": stable, "churn": churn, "sshDown": ssh_down,
        "chats": chats, "clients": clients,
        "cuts": counts.cuts.load(Ordering::Relaxed),
        "shortClients": counts.clients.load(Ordering::Relaxed),
        "clientErrors": counts.client_errors.load(Ordering::Relaxed),
        "cli": counts.cli.load(Ordering::Relaxed),
        "cliFailed": counts.cli_failed.load(Ordering::Relaxed),
        "refused": counts.refused.load(Ordering::Relaxed),
        "prompts": counts.prompts.load(Ordering::Relaxed),
        "rssListedMiB": rss_listed >> 20, "rssEndMiB": rss_end >> 20, "peakRssMiB": peak_rss >> 20,
        "slopeMiBPerMin": slope,
        "heapEndBytes": heap.as_ref().map(|h| h["endBytes"].clone()),
        "heapPeakBytes": heap.as_ref().map(|h| h["peakBytes"].clone()),
        "queueBytes": status["gauges"]["queues"]["bytes"],
        "outboxPending": status["outboxPending"],
    });
    println!("GROWTH {result}");
    for (list, rows) in heap.iter().flat_map(|h| [("END", &h["byEnd"]), ("PEAK", &h["byPeak"])]) {
        for row in rows.as_array().into_iter().flatten() {
            println!(
                "GROWTH-HEAP-{list} {} {} {} {} {}",
                row["endBytes"], row["peakBytes"], row["totalBytes"], row["site"], row["via"]
            );
        }
    }
}
