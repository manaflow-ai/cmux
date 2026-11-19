//! Idle sub-sessions stay asleep across a daemon restart and the reads that follow it: an agent
//! starts only when someone opens a chat or sends to it (Leo, 2026-11-14, on idle cost: "let's do
//! all those").
//!
//! On cmux NIGHTLY (2026-11-15) 31 Chief sub-sessions (`optchat-sub-6b68ac4a-*`) sat idle next to
//! the Chief. Each restart and every few minutes after, about 11 of them got a Claude process
//! back for two minutes (`woke ... cause="click"` in the daemon log), with about 20 other idle
//! chats: tools that read lanes with `acpmux session tail` attach without saying `visible`, and
//! the daemon took each attach for a person opening the chat. Here `ACPMUX_IDLE_SUBS` (default
//! 30) chats each answer one prompt and hibernate; the daemon restarts; the CLI reads every one
//! (`session tail --last`, `session tail --since`, `last`, `history`). No agent may start. Then
//! a person's open (`_acpmux/attach` with `visible: true`) and a send each start exactly one.
//!
//! The harness runs under a shell that appends its pid to `spawns`, so every agent start counts,
//! a short-lived one too (a woken agent hibernates again after the idle period).

use super::*;

/// No model probe (`hub/live_models.rs`): a probe runs the harness for its model list, which is
/// no chat's agent, and every start counted here must be a sub-session's.
const NO_PROBE: (&str, &str) = ("ACPMUX_PROBE_HARNESSES", "none");

/// The harness shell: records its pid, then runs the fake agent.
fn counted_harness(spawns: &Path) -> Value {
    let script =
        format!("echo $$ >> {}; exec python3 {FAKE}", daemon_env::sh_quote(spawns.display()));
    json!(["sh", "-c", script])
}

fn spawns(path: &Path) -> usize {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.trim().is_empty())
        .count()
}

/// The acpmux CLI at the owner's plain terminal, on this daemon.
fn cli(daemon: &Daemon, args: &[&str]) {
    let mut cmd = daemon_env::command(&daemon.home, daemon_env::Agents::StandIn, &[]);
    cmd.env("ACPMUX_HOME", &daemon.home)
        .env("ACPMUX_SOCKET", &daemon.socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .args(args);
    let out = cmd.output().expect("run acpmux");
    assert!(
        out.status.success(),
        "acpmux {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

async fn live_agents(rpc: &mut Rpc) -> u64 {
    rpc.call("_acpmux/status", json!({})).await["liveAgents"].as_u64().unwrap_or(u64::MAX)
}

/// The person trusts the sub-sessions' folder, as the app asks before a chat's first prompt: a
/// wake starts no agent in a folder with no trust answer (`hub/warm.rs`), so without it neither
/// a read nor an open could start one and the test would prove nothing.
async fn trust(rpc: &mut Rpc, folder: &Path) {
    rpc.call("acp.trust.set", json!({"cwd": folder, "level": "trusted"})).await;
}

async fn until(what: &str, mut done: impl AsyncFnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(60);
    while !done().await {
        assert!(Instant::now() < deadline, "{what}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn restored_idle_subsessions_start_no_agent_until_opened_or_sent_to() {
    let n: usize =
        std::env::var("ACPMUX_IDLE_SUBS").ok().and_then(|v| v.parse().ok()).unwrap_or(30);
    // No spare agent (`hub/pool/spare.rs`): the one warm agent per harness a daemon start keeps
    // ready is no chat's, and every start here must be a sub-session's.
    let mut daemon = Daemon::with_env(
        "idlesub",
        "approve-all",
        &[("ACPMUX_IDLE_CHILD_SECS", "1"), ("ACPMUX_SPARE_HARNESS", "0"), NO_PROBE],
    );
    daemon.sigterm();
    let spawn_log = daemon.home.join("spawns");
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": counted_harness(&spawn_log)}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
    )
    .unwrap();
    daemon.start();

    // N sub-sessions of a Chief, each with one finished turn.
    let mut rpc = daemon.rpc().await;
    trust(&mut rpc, &daemon.home).await;
    let mut ids = Vec::new();
    for i in 0..n {
        let name = format!("optchat-sub-test-a{i}");
        let created = rpc
            .call(
                "session/new",
                json!({"cwd": daemon.home, "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
            )
            .await;
        let id = created["sessionId"].as_str().unwrap().to_owned();
        rpc.call(
            "_acpmux/tag",
            json!({"sessionId": id, "set": {"mux.parent": "optchat-chief:test"}}),
        )
        .await;
        rpc.call(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
        ids.push(id);
    }
    until("the idle sub-sessions never hibernated", async || live_agents(&mut rpc).await == 0)
        .await;
    let before_restart = spawns(&spawn_log);
    assert!(before_restart >= n, "each sub-session's turn ran on an agent: {before_restart} < {n}");

    // The app relaunches: a new daemon over the same home.
    drop(rpc);
    daemon.sigterm();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    until("the restarted daemon never settled", async || {
        rpc.call("_acpmux/status", json!({})).await["ready"] == true
    })
    .await;
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert_eq!(
        spawns(&spawn_log),
        before_restart,
        "the restart started an idle sub-session's agent"
    );

    // The reads lane tools run every few minutes.
    for id in &ids {
        cli(&daemon, &["--json", "--suppress-reads", "session", "tail", "--last", "5", id]);
        cli(&daemon, &["--json", "--suppress-reads", "session", "tail", "--since", "1", id]);
        cli(&daemon, &["--json", "last", id]);
        cli(&daemon, &["--json", "history", id]);
        rpc.call("_acpmux/events", json!({"sessionId": id, "limit": 20})).await;
        rpc.call("_acpmux/info", json!({"sessionId": id})).await;
    }
    // A wake runs on its own task: give one the time it would take to show.
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert_eq!(
        spawns(&spawn_log) - before_restart,
        0,
        "reading {n} restored idle sub-sessions started their agents"
    );

    // A person opens one: an earlier daemon hibernated it, so the open alone starts nothing
    // (`hub/idle.rs` `wake_for`).
    let mut person = daemon.rpc().await;
    person.call("_acpmux/attach", json!({"sessionId": ids[0], "limit": 0, "visible": true})).await;
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert_eq!(
        spawns(&spawn_log),
        before_restart,
        "opening a restored idle sub-session started its agent"
    );
    // A send starts its agent, and only its.
    person
        .call(
            "session/prompt",
            json!({"sessionId": ids[1], "prompt": [{"type": "text", "text": "again"}]}),
        )
        .await;
    until("a send to a sub-session did not start its agent", async || {
        spawns(&spawn_log) == before_restart + 1
    })
    .await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(spawns(&spawn_log), before_restart + 1, "a send starts one agent");
}

/// CPU seconds `ps` shows for `pid` (`[[dd-]hh:]mm:ss`), or None once it ended.
fn cpu_secs(pid: &str) -> Option<f64> {
    let out = std::process::Command::new("ps").args(["-o", "time=", "-p", pid]).output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout).trim().to_owned();
    if text.is_empty() {
        return None;
    }
    let (days, rest) =
        text.split_once('-').map_or((0.0, text.as_str()), |(d, r)| (d.parse().unwrap_or(0.0), r));
    let secs =
        rest.split(':').fold(0.0, |acc, part| acc * 60.0 + part.parse::<f64>().unwrap_or(0.0));
    Some(days * 86_400.0 + secs)
}

/// The bench behind the numbers in the pull request: `ACPMUX_IDLE_SUBS` idle sub-sessions, a
/// third of them with their agents up (opened lately), an update's relaunch, then two minutes in
/// which lane tools read every chat each 30 s (as the sidebar and stall reconcilers do on cmux
/// NIGHTLY). Agents a third of them kept up are adopted and counted as before (no new start). It prints `acpmux-idle-subs: {...}`:
/// agent starts, the most agents at once, and the agents' CPU seconds (sampled each 250 ms, the
/// most each pid showed). Run on the base build and on this one with `--ignored`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "a two-minute bench; run with --ignored"]
async fn bench_idle_subsessions_two_minutes_after_a_restart() {
    let n: usize =
        std::env::var("ACPMUX_IDLE_SUBS").ok().and_then(|v| v.parse().ok()).unwrap_or(30);
    let window = Duration::from_secs(
        std::env::var("ACPMUX_IDLE_SUBS_WINDOW_S").ok().and_then(|v| v.parse().ok()).unwrap_or(120),
    );
    let mut daemon = Daemon::with_env("idlebench", "approve-all", &[NO_PROBE]);
    daemon.sigterm();
    let spawn_log = daemon.home.join("spawns");
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": counted_harness(&spawn_log)}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
    )
    .unwrap();
    // A short idle period while seeding, so every chat hibernates before the restart.
    daemon.env.push(("ACPMUX_IDLE_CHILD_SECS".into(), "1".into()));
    daemon.start();
    let mut rpc = daemon.rpc().await;
    trust(&mut rpc, &daemon.home).await;
    let mut ids = Vec::new();
    for i in 0..n {
        let name = format!("optchat-sub-bench-a{i}");
        let created = rpc
            .call(
                "session/new",
                json!({"cwd": daemon.home, "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
            )
            .await;
        let id = created["sessionId"].as_str().unwrap().to_owned();
        rpc.call(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
        ids.push(id);
    }
    until("the idle sub-sessions never hibernated", async || live_agents(&mut rpc).await == 0)
        .await;
    drop(rpc);
    daemon.sigterm();
    // The real idle period from now on (Leo's 2 minutes), as the app runs it, and the daemon on
    // an installed copy an update can replace.
    daemon.env.retain(|(k, _)| k != "ACPMUX_IDLE_CHILD_SECS");
    let installed = daemon.home.join("app").join("acpmux");
    std::fs::create_dir_all(installed.parent().unwrap()).unwrap();
    std::fs::copy(daemon_env::bin(), &installed).unwrap();
    daemon.exe = installed.clone();
    daemon.start();
    // A third were opened lately, so their agents are up when the app quits, as on NIGHTLY.
    let mut rpc = daemon.rpc().await;
    let up = n.div_ceil(3);
    for id in ids.iter().take(up) {
        rpc.call("_acpmux/attach", json!({"sessionId": id, "limit": 0, "visible": true})).await;
        rpc.call("_acpmux/detach", json!({"sessionId": id})).await;
    }
    until("the opened sub-sessions never woke", async || live_agents(&mut rpc).await == up as u64)
        .await;
    drop(rpc);
    daemon.sigterm();
    // The relaunch is an update's: the old bundle moves aside, a new build takes its path.
    std::fs::rename(&installed, daemon.home.join("app").join("acpmux.old")).unwrap();
    std::fs::copy(daemon_env::bin(), &installed).unwrap();
    let seeded = spawns(&spawn_log);
    daemon.start();
    let started = Instant::now();
    let mut rpc = daemon.rpc().await;
    let mut cpu: std::collections::HashMap<String, f64> = Default::default();
    let (mut peak, mut next_read) = (0u64, started);
    while started.elapsed() < window {
        if Instant::now() >= next_read {
            for id in &ids {
                cli(
                    &daemon,
                    &["--json", "--suppress-reads", "session", "tail", "--since", "1", id],
                );
            }
            next_read += Duration::from_secs(30);
        }
        peak = peak.max(live_agents(&mut rpc).await);
        let log = std::fs::read_to_string(&spawn_log).unwrap_or_default();
        for pid in log.lines().skip(seeded).map(str::trim).filter(|p| !p.is_empty()) {
            if let Some(secs) = cpu_secs(pid) {
                let seen = cpu.entry(pid.to_owned()).or_default();
                *seen = seen.max(secs);
            }
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    let starts = spawns(&spawn_log) - seeded;
    let cpu_total: f64 = cpu.values().sum();
    let line = format!(
        "acpmux-idle-subs: {}",
        json!({"subsessions": n, "windowS": window.as_secs(), "agentStarts": starts,
               "peakLiveAgents": peak, "agentCpuS": (cpu_total * 100.0).round() / 100.0})
    );
    println!("{line}");
    // Also to a file a bench script reads (the runner may hold the test's stdout).
    if let Some(out) = std::env::var_os("ACPMUX_IDLE_SUBS_OUT") {
        std::fs::write(out, format!("{line}\n")).unwrap();
    }
}

/// An app update moves the bundle every agent host was started from (`hub/stale_host_respawn.rs`):
/// the next daemon restarted each adopted agent on the new binary at once, idle ones too, so
/// every sub-session up at an update got a new Claude process (30 at one cmux NIGHTLY relaunch,
/// 2026-11-15). An idle one now ends and stays asleep; a send starts it on the new binary.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_update_ends_idle_subsessions_on_the_old_binary_and_starts_none() {
    let n = 5;
    let mut daemon =
        Daemon::with_env("idlestale", "approve-all", &[("ACPMUX_SPARE_HARNESS", "0"), NO_PROBE]);
    daemon.sigterm();
    let spawn_log = daemon.home.join("spawns");
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": counted_harness(&spawn_log)}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
    )
    .unwrap();
    let installed = daemon.home.join("app").join("acpmux");
    std::fs::create_dir_all(installed.parent().unwrap()).unwrap();
    std::fs::copy(daemon_env::bin(), &installed).unwrap();
    daemon.exe = installed.clone();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let mut ids = Vec::new();
    for i in 0..n {
        let created = rpc
            .call(
                "session/new",
                json!({"cwd": daemon.home, "mcpServers": [], "_meta": {"acpmux": {"name": format!("optchat-sub-stale-a{i}")}}}),
            )
            .await;
        let id = created["sessionId"].as_str().unwrap().to_owned();
        rpc.call(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
        ids.push(id);
    }
    // Idle, with their agents still up (the idle period has not passed).
    assert_eq!(live_agents(&mut rpc).await, n as u64);
    let before = spawns(&spawn_log);
    drop(rpc);
    daemon.sigterm();
    // The update: the old bundle moves aside, a new build takes its path.
    std::fs::rename(&installed, daemon.home.join("app").join("acpmux.old")).unwrap();
    std::fs::copy(daemon_env::bin(), &installed).unwrap();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    until("the idle agents on the replaced binary kept running", async || {
        live_agents(&mut rpc).await == 0
    })
    .await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(spawns(&spawn_log), before, "the update restarted idle sub-sessions' agents");
    // A send starts one, on the installed binary, and is answered.
    rpc.call(
        "session/prompt",
        json!({"sessionId": ids[0], "prompt": [{"type": "text", "text": "again"}]}),
    )
    .await;
    assert_eq!(spawns(&spawn_log), before + 1, "a send starts its agent");
}
