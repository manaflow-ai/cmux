//! A 529 storm, end to end (Leo, 2026-11-24: "fix 529s properly with better designs"). The
//! effort's stop condition: a chaos test of a 529 storm shows no dead or silent sessions and less
//! time lost than today. This is that test.
//!
//! A fake Anthropic upstream (a local HTTP server, [`Upstream`]) answers `/v1/messages`. For
//! [`STORM_MS`] it answers a share of the calls to the big model `529 overloaded_error`, with
//! `Retry-After` and `X-Subrouter-Alternate` (`account` when the gateway's reserved interactive
//! share could take the call elsewhere, `none` when nothing could), then recovers. The share
//! follows the call's `X-Subrouter-Priority`, as the SR2 gateway's reserve does: [`PCT_BACKGROUND`]
//! of the background calls, [`PCT_INTERACTIVE`] of the interactive ones. A call to the fallback
//! model (Sonnet) is not refused: the provider's overload is per model.
//!
//! [`SESSIONS`] acpmux chats run on Opus through the Python agent double (`fake_agent.py`
//! `upstream_turn`: one model call per turn, retried in the turn as Claude Code retries an
//! overload, then "API Error: 529 ..."). Their names give them their priority
//! (`subrouter_priority.rs`): coordinators, a dictator and ask lanes are interactive, the lanes
//! background. All prompts go in at the storm's start. Time runs [`SCALE`] times faster than a
//! real chat's: acpmux's configured waits are its defaults scaled ([`DELAYS_MS`]).
//!
//! What must hold:
//! 1. no session ends dead: every queued prompt completes after the recovery, within the bound;
//! 2. no session is silent: each one the storm cut shows, within [`NOTICE_MS`] of its cut, a
//!    scheduled retry (`auto_resume_scheduled`), a failover (`capacity_failover`) or the row's
//!    capacity retry with its time;
//! 3. the interactive sessions finish before the background ones (on average, and none last);
//! 4. the time lost (the sum over sessions of prompt-to-completion, in real seconds) stays below
//!    [`MAX_LOST_S`].
//!
//! One summary line goes to stdout: `529-storm: sessions=… dead=… silent=… lost_s=… parked=…
//! failovers=…`, and the upstream's own counts.
use super::*;
use std::sync::Mutex;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// How much faster than real time the test runs: 1 real second is `1000 / SCALE` ms here.
const SCALE: u64 = 50;
/// The storm: 90 s real.
const STORM_MS: u64 = 90_000 / SCALE;
/// acpmux's default continuation waits (10 s, 60 s, 300 s; capacity waits stop at 300 s), scaled.
const DELAYS_MS: [u64; 3] = [10_000 / SCALE, 60_000 / SCALE, 300_000 / SCALE];
/// Chats in the storm; the first [`INTERACTIVE`] names are interactive.
const SESSIONS: usize = 24;
const INTERACTIVE: [&str; 6] =
    ["claude-sr2-coord", "web-coord", "interim-coord", "ci-217x-dictator", "ask-gui", "ask-ios"];
/// The share of calls to the big model the storm refuses, per priority (percent).
const PCT_BACKGROUND: u64 = 90;
const PCT_INTERACTIVE: u64 = 50;
/// The `Retry-After` a refused call carries: 15 s real.
const RETRY_AFTER_MS: u64 = 15_000 / SCALE;
/// Claude Code's own retries of an overload inside one turn (scaled waits), before it ends the
/// turn on the 529.
const IN_TURN_RETRIES: u32 = 2;
/// A session the storm cut says so within this long (10 s real).
const NOTICE_MS: u64 = 10_000 / SCALE;
/// The time lost, summed over the sessions, may not pass this (real seconds). Today's number is
/// printed in the summary; this bound is today's with room for scheduling noise, so the test
/// catches a regression, and goes down as the design improves.
const MAX_LOST_S: u64 = 12_000;

/// One call the upstream answered.
#[derive(Clone, Debug)]
struct Call {
    at_ms: u64,
    priority: String,
    model: String,
    status: u16,
}

/// The fake Anthropic upstream.
struct Upstream {
    url: String,
    calls: Arc<Mutex<Vec<Call>>>,
    storm_end: Arc<Mutex<Option<tokio::time::Instant>>>,
    /// The whole pool is out: every model, every priority refused while the storm lasts.
    total: Arc<std::sync::atomic::AtomicBool>,
}

impl Upstream {
    async fn start() -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let calls: Arc<Mutex<Vec<Call>>> = Arc::default();
        let storm_end: Arc<Mutex<Option<tokio::time::Instant>>> = Arc::default();
        let started = tokio::time::Instant::now();
        let total: Arc<std::sync::atomic::AtomicBool> = Arc::default();
        let (log, storm, all) = (calls.clone(), storm_end.clone(), total.clone());
        tokio::spawn(async move {
            // Calls per priority, for a refusal share that is exact, not random.
            let counters: Arc<Mutex<BTreeMap<String, u64>>> = Arc::default();
            while let Ok((stream, _)) = listener.accept().await {
                let (log, storm, counters) = (log.clone(), storm.clone(), counters.clone());
                let all = all.load(std::sync::atomic::Ordering::SeqCst);
                tokio::spawn(async move {
                    let _ = serve(stream, started, log, storm, counters, all).await;
                });
            }
        });
        Self { url, calls, storm_end, total }
    }

    /// From now on a storm refuses every call, the fallback model's too.
    fn whole_pool(&self) {
        self.total.store(true, std::sync::atomic::Ordering::SeqCst);
    }

    fn storm_for(&self, ms: u64) {
        *self.storm_end.lock().unwrap() =
            Some(tokio::time::Instant::now() + Duration::from_millis(ms));
    }

    fn calls(&self) -> Vec<Call> {
        self.calls.lock().unwrap().clone()
    }
}

/// One HTTP/1.1 request on `stream`, answered and closed.
async fn serve(
    mut stream: tokio::net::TcpStream,
    started: tokio::time::Instant,
    log: Arc<Mutex<Vec<Call>>>,
    storm: Arc<Mutex<Option<tokio::time::Instant>>>,
    counters: Arc<Mutex<BTreeMap<String, u64>>>,
    total: bool,
) -> std::io::Result<()> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let header = |name: &str| {
        head.lines()
            .filter_map(|l| l.split_once(':'))
            .find(|(k, _)| k.trim().eq_ignore_ascii_case(name))
            .map(|(_, v)| v.trim().to_owned())
    };
    let len: usize = header("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
    while buf.len() < head_end + len {
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    let body: Value = serde_json::from_slice(&buf[head_end..]).unwrap_or(Value::Null);
    let model = body["model"].as_str().unwrap_or_default().to_owned();
    let priority = header("x-subrouter-priority").unwrap_or_default();
    let interactive = priority == subrouter_priority_interactive();
    let big = !model.contains("sonnet") && !model.contains("haiku");
    let storming = storm.lock().unwrap().is_some_and(|end| tokio::time::Instant::now() < end);
    let refuse = storming
        && (total
            || (big && {
                let mut counters = counters.lock().unwrap();
                let n = counters.entry(priority.clone()).or_default();
                *n += 1;
                // Spread over each hundred calls: call n is refused when (n * 37) mod 100 < pct.
                let pct = if interactive { PCT_INTERACTIVE } else { PCT_BACKGROUND };
                (*n * 37) % 100 < pct
            }));
    let (status, reply) = if refuse {
        let alternate = if interactive { "account" } else { "none" };
        let body = r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#;
        let retry_after = RETRY_AFTER_MS as f64 / 1000.0;
        (
            529,
            format!(
                "HTTP/1.1 529 Overloaded\r\ncontent-type: application/json\r\nretry-after: {retry_after}\r\n\
                 x-subrouter-alternate: {alternate}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            ),
        )
    } else {
        let body = json!({
            "id": "msg_fake", "type": "message", "role": "assistant", "model": model,
            "content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn",
            "usage": {"input_tokens": 1, "output_tokens": 1}
        })
        .to_string();
        (
            200,
            format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\
                 connection: close\r\n\r\n{body}",
                body.len()
            ),
        )
    };
    log.lock().unwrap().push(Call {
        at_ms: started.elapsed().as_millis() as u64,
        priority,
        model,
        status,
    });
    stream.write_all(reply.as_bytes()).await?;
    stream.shutdown().await
}

fn subrouter_priority_interactive() -> &'static str {
    acpmux::subrouter_priority::INTERACTIVE
}

/// What one chat went through.
#[derive(Debug, Default, Clone)]
struct Fate {
    name: String,
    interactive: bool,
    cut_at: Option<u64>,
    noticed_at: Option<u64>,
    done_at: Option<u64>,
}

fn records(hub: &Hub, id: &str) -> Vec<acpmux::store::EventRecord> {
    hub.events(id, 0, 100_000).unwrap()
}

/// `name`'s fate so far; times in ms from `t0` (an `EventRecord::at`, epoch ms).
fn fate_of(hub: &Hub, id: &str, name: &str, t0: u64, fate: &mut Fate) {
    fate.name = name.to_owned();
    fate.interactive = INTERACTIVE.contains(&name);
    let rel = |at: u64| at.saturating_sub(t0);
    for e in records(hub, id) {
        match e.kind.as_str() {
            "turn_result" if e.msg["status"] == "completed" => {
                fate.done_at.get_or_insert(rel(e.at));
            }
            "turn_result" if e.msg["status"] == "failed" => {
                fate.cut_at.get_or_insert(rel(e.at));
            }
            "auto_resume_scheduled" | "capacity_failover" => {
                fate.noticed_at.get_or_insert(rel(e.at));
            }
            _ => {}
        }
    }
    // The row's own notice: a capacity retry waiting, with its time.
    if fate.noticed_at.is_none() && fate.cut_at.is_some() {
        let row = hub.session_summary(&hub.resolve(id).unwrap());
        if row["retry"]["reason"] == "capacity" && row["retry"]["nextAt"].as_u64().is_some() {
            fate.noticed_at = Some(rel(acpmux::store::now_ms()));
        }
    }
}

fn count_kind(hub: &Hub, ids: &[(String, String)], kind: &str) -> usize {
    ids.iter().map(|(id, _)| records(hub, id).iter().filter(|e| e.kind == kind).count()).sum()
}

/// A connection from inside session `sid` (its caller token): an agent's, not the person's.
async fn agent_in(hub: &Arc<Hub>, sid: &str) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    let token = acpmux::hub::person::caller_token(sid);
    let init = json!({"protocolVersion": 1,
        "_meta": {"acpmux": {"callerSession": {"sessionId": sid, "token": token}}}});
    c.request(method::INITIALIZE, init).await.unwrap();
    c
}

fn mean(xs: &[u64]) -> u64 {
    if xs.is_empty() { 0 } else { xs.iter().sum::<u64>() / xs.len() as u64 }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn a_529_storm_leaves_no_session_dead_or_silent_and_bounds_the_time_lost() {
    let upstream = Upstream::start().await;
    let env = BTreeMap::from([
        ("FAKE_UPSTREAM_URL".to_owned(), upstream.url.clone()),
        // A gateway's route: only one gets the priority header (`subrouter_priority.rs`).
        ("ANTHROPIC_BASE_URL".to_owned(), upstream.url.clone()),
        ("FAKE_UPSTREAM_RETRIES".to_owned(), IN_TURN_RETRIES.to_string()),
        ("FAKE_UPSTREAM_BACKOFF_MS".to_owned(), (2_000 / SCALE).to_string()),
        ("FAKE_PICKER".to_owned(), "1".to_owned()),
        ("FAKE_PICKER_MODES".to_owned(), "claude".to_owned()),
    ]);
    let (hub, mut c) = setup_inbox(PermissionPolicy::ApproveAll, env, BTreeMap::new(), false).await;
    {
        let mut cfg = hub.config.write().await;
        cfg.auto_resume_delays_ms = Some(DELAYS_MS.to_vec());
        // The storm measures the opt-in failover (off by default since cmux#57784).
        cfg.capacity_fallback_after = Some(1);
    }

    // The chats, each on Opus.
    // The interactive chats are the person's; the lanes are the coordinator's, made from inside
    // its chat as a coordinator starts them, so acpmux records an agent as their creator and their
    // requests say background (`subrouter_priority.rs`).
    let mut ids: Vec<(String, String)> = Vec::new();
    let mut from_coord: Option<TestClient> = None;
    for n in 0..SESSIONS {
        let name = INTERACTIVE.get(n).map_or_else(|| format!("lane-{n:02}"), |s| (*s).to_owned());
        let id = if n < INTERACTIVE.len() {
            new_session(&mut c, &name).await
        } else {
            if from_coord.is_none() {
                from_coord = Some(agent_in(&hub, &ids[0].0).await);
            }
            new_session(from_coord.as_mut().unwrap(), &name).await
        };
        hub.set_model(&hub.resolve(&id).unwrap(), "claude-opus-5-5").await.unwrap();
        ids.push((id, name));
    }

    // The storm starts; every chat's prompt goes in at once.
    upstream.storm_for(STORM_MS);
    let t0 = acpmux::store::now_ms();
    let start = tokio::time::Instant::now();
    for (n, (id, name)) in ids.iter().enumerate() {
        c.send(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("work item {n} for {name}")}],
                   "_meta": {"acpmux": {"promptId": format!("p-{n}")}}}),
        )
        .await;
    }

    // Watch until every chat completed, or the bound: the storm, then the longest wait twice
    // over (with its jitter), then slack.
    let bound = STORM_MS + 2 * (DELAYS_MS[2] + DELAYS_MS[2] / 5) + 5_000;
    let mut fates: Vec<Fate> = vec![Fate::default(); ids.len()];
    while start.elapsed() < Duration::from_millis(bound) {
        while c.rx.try_recv().is_ok() {}
        for ((id, name), fate) in ids.iter().zip(fates.iter_mut()) {
            fate_of(&hub, id, name, t0, fate);
        }
        if fates.iter().all(|f| f.done_at.is_some()) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    // The numbers.
    let dead: Vec<&Fate> = fates.iter().filter(|f| f.done_at.is_none()).collect();
    let silent: Vec<&Fate> = fates
        .iter()
        .filter(|f| f.cut_at.is_some_and(|cut| f.noticed_at.is_none_or(|n| n > cut + NOTICE_MS)))
        .collect();
    let cut = fates.iter().filter(|f| f.cut_at.is_some()).count();
    let done = |interactive: bool| -> Vec<u64> {
        fates.iter().filter(|f| f.interactive == interactive).filter_map(|f| f.done_at).collect()
    };
    let (fg, bg) = (done(true), done(false));
    let lost_ms: u64 = fates.iter().map(|f| f.done_at.unwrap_or(bound)).sum();
    let lost_s = lost_ms * SCALE / 1000;
    let after_recovery_s =
        fates.iter().map(|f| f.done_at.unwrap_or(bound).saturating_sub(STORM_MS)).sum::<u64>()
            * SCALE
            / 1000;
    let parked = count_kind(&hub, &ids, "rate_limit_parked");
    let failovers = count_kind(&hub, &ids, "capacity_failover");
    let exhausted = count_kind(&hub, &ids, "auto_resume_exhausted");
    let calls = upstream.calls();
    let refused = calls.iter().filter(|c| c.status == 529).count();
    let to_fallback = calls.iter().filter(|c| c.model.contains("sonnet")).count();
    let last_call_s = calls.iter().map(|c| c.at_ms).max().unwrap_or(0) * SCALE / 1000;
    let priorities: std::collections::BTreeSet<&str> =
        calls.iter().map(|c| c.priority.as_str()).collect();
    println!(
        "529-storm: sessions={} dead={} silent={} lost_s={lost_s} lost_after_recovery_s={after_recovery_s} \
         parked={parked} failovers={failovers} exhausted={exhausted} cut={cut} \
         interactive_mean_s={} background_mean_s={} upstream_calls={} refused_529={refused} \
         to_fallback={to_fallback} last_call_s={last_call_s} storm_s={} scale={SCALE}",
        fates.len(),
        dead.len(),
        silent.len(),
        mean(&fg) * SCALE / 1000,
        mean(&bg) * SCALE / 1000,
        calls.len(),
        STORM_MS * SCALE / 1000,
    );

    // The double carried each chat's priority to the upstream.
    assert!(
        priorities.contains("interactive") && priorities.contains("background"),
        "the upstream saw priorities {priorities:?}"
    );
    assert!(refused > 0 && cut > 0, "the storm cut no turn: {refused} refused, {cut} cut");
    // 1. Nobody dead.
    assert!(dead.is_empty(), "{} sessions never completed: {dead:?}", dead.len());
    assert_eq!(exhausted, 0, "a capacity chain gave up");
    // 2. Nobody silent.
    assert!(
        silent.is_empty(),
        "{} sessions cut with no notice within {NOTICE_MS} ms: {silent:?}",
        silent.len()
    );
    // 3. Interactive first: on average, and the last to finish is a background chat.
    let (last_fg, last_bg) = (fg.iter().max().copied(), bg.iter().max().copied());
    assert!(
        mean(&fg) < mean(&bg) && last_fg <= last_bg,
        "interactive chats did not finish first: interactive {fg:?}, background {bg:?} (ms)"
    );
    // 4. The time lost stays under the bound.
    assert!(lost_s <= MAX_LOST_S, "time lost {lost_s} s > {MAX_LOST_S} s: {fates:?}");

    hub.shutdown_all().await;
}

/// The whole pool out (every model, both priorities) for 10 min real, [`OUTAGE_LANES`]
/// background lanes on one host (`capacity_gate.rs`). Without the gate each lane resent its
/// whole context on its own timer (10 s, 60 s, then every 300 s): about four failed turns a lane
/// in 10 min. With it the host sends one probe per back-off after the first wave.
const OUTAGE_MS: u64 = 600_000 / SCALE;
const OUTAGE_LANES: usize = 30;

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn a_dead_pool_gets_one_probe_at_a_time_and_every_lane_comes_back_after_it() {
    let upstream = Upstream::start().await;
    upstream.whole_pool();
    let env = BTreeMap::from([
        ("FAKE_UPSTREAM_URL".to_owned(), upstream.url.clone()),
        // A gateway's route: only one gets the priority header (`subrouter_priority.rs`).
        ("ANTHROPIC_BASE_URL".to_owned(), upstream.url.clone()),
        ("FAKE_UPSTREAM_RETRIES".to_owned(), IN_TURN_RETRIES.to_string()),
        ("FAKE_UPSTREAM_BACKOFF_MS".to_owned(), (2_000 / SCALE).to_string()),
        ("FAKE_PICKER".to_owned(), "1".to_owned()),
        ("FAKE_PICKER_MODES".to_owned(), "claude".to_owned()),
    ]);
    let (hub, mut c) = setup_inbox(PermissionPolicy::ApproveAll, env, BTreeMap::new(), false).await;
    {
        let mut cfg = hub.config.write().await;
        cfg.auto_resume_delays_ms = Some(DELAYS_MS.to_vec());
        // The storm measures the opt-in failover (off by default since cmux#57784).
        cfg.capacity_fallback_after = Some(1);
    }

    // A coordinator (no prompt of its own) starts the lanes, so they are background.
    let coord = new_session(&mut c, INTERACTIVE[0]).await;
    let mut from_coord = agent_in(&hub, &coord).await;
    let mut ids: Vec<(String, String)> = Vec::new();
    for n in 0..OUTAGE_LANES {
        let name = format!("lane-{n:02}");
        let id = new_session(&mut from_coord, &name).await;
        hub.set_model(&hub.resolve(&id).unwrap(), "claude-opus-5-5").await.unwrap();
        ids.push((id, name));
    }

    upstream.storm_for(OUTAGE_MS);
    let t0 = acpmux::store::now_ms();
    let start = tokio::time::Instant::now();
    let first_call = upstream.calls().len();
    for (n, (id, name)) in ids.iter().enumerate() {
        c.send(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("work item {n} for {name}")}],
                   "_meta": {"acpmux": {"promptId": format!("o-{n}")}}}),
        )
        .await;
    }

    // The outage, then the longest back-off with its jitter, the recovery stream, and slack.
    let bound = OUTAGE_MS + DELAYS_MS[2] + DELAYS_MS[2] / 5 + 10 * DELAYS_MS[0] + 5_000;
    let mut fates: Vec<Fate> = vec![Fate::default(); ids.len()];
    let mut outage_calls = None;
    while start.elapsed() < Duration::from_millis(bound) {
        while c.rx.try_recv().is_ok() {}
        if outage_calls.is_none() && start.elapsed() >= Duration::from_millis(OUTAGE_MS) {
            outage_calls = Some(upstream.calls().len() - first_call);
        }
        for ((id, name), fate) in ids.iter().zip(fates.iter_mut()) {
            fate_of(&hub, id, name, t0, fate);
        }
        if fates.iter().all(|f| f.done_at.is_some()) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    let outage_calls = outage_calls.unwrap_or_else(|| upstream.calls().len() - first_call);
    let calls = upstream.calls();
    let refused = calls.iter().filter(|c| c.status == 529).count();
    let dead: Vec<&Fate> = fates.iter().filter(|f| f.done_at.is_none()).collect();
    let silent: Vec<&Fate> = fates
        .iter()
        .filter(|f| f.cut_at.is_some_and(|cut| f.noticed_at.is_none_or(|n| n > cut + NOTICE_MS)))
        .collect();
    let done: Vec<u64> = fates.iter().filter_map(|f| f.done_at).collect();
    let (first_done, last_done) =
        (done.iter().min().copied().unwrap_or(bound), done.iter().max().copied().unwrap_or(bound));
    let held = count_kind(&hub, &ids, "capacity_gate_held");
    let probes = count_kind(&hub, &ids, "capacity_gate_probe");
    let exhausted = count_kind(&hub, &ids, "auto_resume_exhausted");
    // One attempt is the turn's call and the harness's own retries of it.
    let per_attempt = 1 + IN_TURN_RETRIES as usize;
    // The first wave (every lane once), then one probe per back-off: 1, 2, 4 ... first waits,
    // at most the last; doubled for scheduling and a failover's extra attempt.
    let probe_budget = {
        let (mut t, mut d, mut n) = (0, DELAYS_MS[0], 0usize);
        while t < OUTAGE_MS {
            t += d;
            d = (d * 2).min(DELAYS_MS[2]);
            n += 1;
        }
        2 * n
    };
    let max_outage_calls = (OUTAGE_LANES + probe_budget) * per_attempt;
    // What the lanes sent before the gate: each on its own timer.
    let ungated = {
        let (mut t, mut n) = (0, 0usize);
        for d in DELAYS_MS.iter().copied().chain(std::iter::repeat(DELAYS_MS[2])) {
            n += 1;
            t += d;
            if t >= OUTAGE_MS {
                break;
            }
        }
        OUTAGE_LANES * n * per_attempt
    };
    println!(
        "529-outage: lanes={OUTAGE_LANES} dead={} silent={} outage_calls={outage_calls} \
         max_outage_calls={max_outage_calls} ungated_estimate={ungated} refused_529={refused} \
         held={held} probes={probes} exhausted={exhausted} first_done_after_outage_s={} \
         recovery_spread_s={} outage_s={} scale={SCALE}",
        dead.len(),
        silent.len(),
        first_done.saturating_sub(OUTAGE_MS) * SCALE / 1000,
        last_done.saturating_sub(first_done) * SCALE / 1000,
        OUTAGE_MS * SCALE / 1000,
    );

    assert!(refused >= OUTAGE_LANES, "the outage cut too few turns: {refused} refused");
    // The gate held the lanes and probed for them.
    assert!(held > 0 && probes > 0, "the gate never engaged: held={held} probes={probes}");
    // A dead pool got about one probe per back-off, not every lane's resend.
    assert!(
        outage_calls <= max_outage_calls,
        "{outage_calls} calls into a dead pool > {max_outage_calls} (ungated about {ungated})"
    );
    // Nobody dead, nobody silent, no chain given up.
    assert!(dead.is_empty(), "{} lanes never completed: {dead:?}", dead.len());
    assert_eq!(exhausted, 0, "a capacity chain gave up");
    assert!(silent.is_empty(), "{} lanes cut with no notice: {silent:?}", silent.len());
    // Every lane is back within the recovery stream's width of the first one.
    let ramp = 10 * (DELAYS_MS[0] / 2) + 2_000;
    assert!(
        last_done - first_done <= ramp,
        "the lanes came back over {} ms > {ramp} ms: {done:?}",
        last_done - first_done
    );

    hub.shutdown_all().await;
}
