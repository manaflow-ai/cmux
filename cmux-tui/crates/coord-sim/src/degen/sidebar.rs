//! sidebar-10k: a daemon holding 10,000 sessions (written on disk in acpmux's format), against the
//! same daemon holding 100. Measured on each: start to ready, the whole list (latency, pages, bytes),
//! its first page, RSS, and what one session's change costs a watching client (bytes and time to
//! its notice). A change must cost the same at 10,000 as at 100 (O(1)), and a `send --no-wait`
//! must return in milliseconds while other clients page the list.

use super::Ctx;
use super::cases::{Booted, Pagers, quantile, sends_at_once, whole_list};
use super::daemon::{Scratch, private_dir, private_file};
use super::rpc::Conn;
use super::run::{Verdict, round};
use serde_json::{Value, json};
use std::path::Path;
use std::time::{Duration, Instant};

const AT: u64 = 1_791_000_000_000;

/// One session record shaped like a coordinator host's: options, modes, tools, a preview, a last turn.
/// Its harness is not configured here, so no agent starts for it.
fn meta(i: usize) -> Value {
    let id = sid(i);
    let options: Vec<Value> = (0..3)
        .map(|o| json!({"category": if o == 0 { "model" } else { "other" }, "currentValue": "v0", "id": format!("opt{o}"),
            "name": format!("Option {o}"), "type": "select",
            "options": (0..8).map(|c| json!({"name": format!("Choice {c}"), "value": format!("v{c}")})).collect::<Vec<_>>()}))
        .collect();
    let at = AT + (i as u64) * 1000;
    json!({
        "schema": "acpmux.session.v1", "id": id, "name": format!("side-{i}"), "harness": "parked",
        "harnessArgv": ["parked"], "cwd": "/tmp", "agentSessionId": format!("agent-{id}"), "status": "idle",
        "createdAt": at, "updatedAt": at + 5000, "lastSeq": 1, "eventCount": 1, "turnCount": 1,
        "hibernatedMs": at + 6000,
        "agentInfo": {"name": "parked", "title": "Parked", "version": null},
        "modes": {"availableModes": [{"id": "default", "name": "Default"}], "currentModeId": "default"},
        "configOptions": options,
        "title": format!("Chat {i} of the sidebar"), "lastPrompt": "x".repeat(120), "preview": "y".repeat(300),
        "lastTurn": {"endedAt": at + 5000, "status": "completed", "stopReason": "end_turn", "turnId": format!("t-{id}")},
    })
}

fn sid(i: usize) -> String {
    format!("side{i:08}")
}

fn write_sessions(home: &Path, n: usize) -> Result<(), String> {
    let sessions = home.join("sessions");
    private_dir(&sessions)?;
    for i in 0..n {
        let dir = sessions.join(sid(i));
        private_dir(&dir)?;
        private_dir(&dir.join("events"))?;
        private_file(&dir.join("session.json"), &meta(i).to_string())?;
        let line = json!({"seq": 1, "at": AT, "dir": "mux", "kind": "created", "msg": {"harness": "parked"}});
        private_file(&dir.join("events").join("000001.ndjson"), &format!("{line}\n"))?;
    }
    Ok(())
}

/// Polls `_acpmux/status` until startup and log loading are done: ms from the daemon's ready line.
fn loaded(sock: &Path, within: Duration) -> Result<(f64, Value), String> {
    let t = Instant::now();
    let mut c = Conn::connect(sock)?;
    loop {
        let s = c.call("_acpmux/status", json!({}), Duration::from_secs(60))?;
        let l = s.get("loading").cloned().unwrap_or(Value::Null);
        if l.get("phase").and_then(Value::as_str) == Some("ready")
            && l.get("startupDone") == Some(&Value::Bool(true))
        {
            return Ok((t.elapsed().as_secs_f64() * 1000.0, l));
        }
        if t.elapsed() > within {
            return Err(format!("not loaded after {} s: {l}", within.as_secs()));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// One rename seen by a watching client: (ms to its first notice, bytes it was sent within 1 s).
fn one_change(sock: &Path, watch: &mut Conn, i: usize, rep: usize) -> Result<(f64, u64), String> {
    // Drain anything pending first.
    while watch.read(Duration::from_millis(30))?.is_some() {}
    let before = watch.bytes_in;
    let mut c = Conn::connect(sock)?;
    let t = Instant::now();
    c.call(
        "_acpmux/rename",
        json!({"sessionId": sid(i), "newName": format!("side-{i}-r{rep}")}),
        Duration::from_secs(30),
    )?;
    let mut first = None;
    while t.elapsed() < Duration::from_secs(1) {
        if let Some(v) = watch.read(Duration::from_millis(20))?
            && first.is_none()
            && v.get("method").and_then(Value::as_str).is_some_and(|m| m.contains("session"))
        {
            first = Some(t.elapsed().as_secs_f64() * 1000.0);
        }
    }
    Ok((first.unwrap_or(f64::INFINITY), watch.bytes_in - before))
}

struct Side {
    n: usize,
    ready_ms: f64,
    loaded_ms: f64,
    list: Vec<f64>,
    first_page: Vec<f64>,
    pages: usize,
    list_bytes: u64,
    rows: usize,
    rss_kb: u64,
    peak_kb: u64,
    change_ms: Vec<f64>,
    change_bytes: Vec<f64>,
    send_ms: Vec<f64>,
    send_failed: usize,
    paged_during_sends: usize,
}

/// One daemon holding `n` sessions, measured; its threads joined before it returns.
fn measure(ctx: &Ctx, n: usize, reps: usize, sends: usize) -> Result<Side, String> {
    std::thread::scope(|sc| measure_in(sc, ctx, n, reps, sends))
}

fn measure_in(
    sc: super::cases::Sc<'_, '_>,
    ctx: &Ctx,
    n: usize,
    reps: usize,
    sends: usize,
) -> Result<Side, String> {
    let s = Scratch::new(&ctx.recipe, &format!("side{n}"), None)?;
    let t = Instant::now();
    write_sessions(&s.home, n)?;
    ctx.run.op("write_sessions", t.elapsed().as_secs_f64() * 1000.0, true, json!({"sessions": n}));
    let mut b = Booted::start(sc, ctx, s)?;
    let sock = b.socket();
    let ready_ms = b.d.ready_ms;
    let (loaded_ms, loading) = loaded(&sock, Duration::from_secs(600))?;
    ctx.run.op("loaded", loaded_ms, true, json!({"sessions": n, "loading": loading}));
    let (mut list, mut first_page) = (Vec::new(), Vec::new());
    let (mut pages, mut list_bytes, mut rows) = (0, 0, 0);
    for rep in 0..reps {
        let t = Instant::now();
        let l = whole_list(&sock)?;
        let ms = t.elapsed().as_secs_f64() * 1000.0;
        ctx.run.op("list_whole", ms, true, json!({"sessions": n, "rep": rep, "pages": l.pages, "rows": l.rows, "bytes": l.bytes, "first_page_ms": l.first_page_ms}));
        list.push(ms);
        first_page.push(l.first_page_ms);
        (pages, list_bytes, rows) = (l.pages, l.bytes, l.rows);
    }
    let rss_kb = Conn::connect(&sock)
        .and_then(|mut c| super::daemon::sample(&mut c))
        .map(|p| p.rss_kb)
        .unwrap_or(0);
    // A watching client, then one rename at a time.
    let mut watch = Conn::connect(&sock)?;
    watch.call("_acpmux/watch", json!({}), Duration::from_secs(120))?;
    let (mut change_ms, mut change_bytes) = (Vec::new(), Vec::new());
    for rep in 0..reps {
        let i = (rep * 7919) % n.max(1);
        let (ms, bytes) = one_change(&sock, &mut watch, i, rep)?;
        ctx.run.op(
            "one_change",
            ms,
            ms.is_finite(),
            json!({"sessions": n, "session": sid(i), "bytes": bytes}),
        );
        change_ms.push(ms);
        change_bytes.push(bytes as f64);
    }
    drop(watch);
    // Sends to a live chat while four clients page the list.
    let live = b.s.new_session("side-live")?;
    let _ = live;
    std::thread::sleep(Duration::from_millis(500));
    let pg = Pagers::start(sc, ctx, &sock, 4);
    std::thread::sleep(Duration::from_millis(300));
    let mut send_ms = Vec::new();
    let mut send_failed = 0;
    for k in 0..sends {
        let r = sends_at_once(sc, &b.s, &[("side-live".to_owned(), format!("while-paging-{k}"))]);
        for (ms, ok, err) in r {
            ctx.run.op(
                "send_no_wait",
                ms,
                ok,
                json!({"sessions": n, "detail": if ok { Value::Null } else { json!(err) }}),
            );
            send_ms.push(ms);
            send_failed += usize::from(!ok);
        }
    }
    let paged = pg.finish().len();
    let (_, peak) = b.rss();
    Ok(Side {
        n,
        ready_ms,
        loaded_ms,
        list,
        first_page,
        pages,
        list_bytes,
        rows,
        rss_kb,
        peak_kb: peak,
        change_ms,
        change_bytes,
        send_ms,
        send_failed,
        paged_during_sends: paged,
    })
}

pub fn sidebar(ctx: &mut Ctx) -> Result<Verdict, String> {
    let big: usize = ctx.num("--sessions", 10_000)?;
    let small: usize = ctx.num("--small", 100)?;
    let reps: usize = ctx.num("--reps", 10)?;
    let sends: usize = ctx.num("--sends", 20)?;
    let mut v = Verdict::new("sidebar-10k");
    let a = measure(ctx, small, reps, sends)?;
    let g = measure(ctx, big, reps, sends)?;
    for s in [&a, &g] {
        let k = if s.n == big { "god" } else { "small" };
        v.num(&format!("{k}_sessions"), s.n);
        v.num(&format!("{k}_rows_listed"), s.rows);
        v.num(&format!("{k}_ready_ms"), round(s.ready_ms));
        v.num(&format!("{k}_loaded_ms"), round(s.loaded_ms));
        v.num(&format!("{k}_list_whole_p50_ms"), round(quantile(&s.list, 0.5)));
        v.num(&format!("{k}_list_whole_p95_ms"), round(quantile(&s.list, 0.95)));
        v.num(&format!("{k}_first_page_p50_ms"), round(quantile(&s.first_page, 0.5)));
        v.num(&format!("{k}_pages"), s.pages);
        v.num(&format!("{k}_list_bytes"), s.list_bytes);
        v.num(&format!("{k}_rss_mb"), s.rss_kb / 1024);
        v.num(&format!("{k}_rss_peak_mb"), s.peak_kb / 1024);
        v.num(&format!("{k}_change_p50_ms"), round(quantile(&s.change_ms, 0.5)));
        v.num(&format!("{k}_change_bytes_p50"), quantile(&s.change_bytes, 0.5));
        v.num(&format!("{k}_send_p50_ms"), round(quantile(&s.send_ms, 0.5)));
        v.num(&format!("{k}_send_p95_ms"), round(quantile(&s.send_ms, 0.95)));
        v.num(&format!("{k}_send_max_ms"), round(quantile(&s.send_ms, 1.0)));
        v.num(&format!("{k}_list_reads_during_sends"), s.paged_during_sends);
    }
    let ratio = |x: f64, y: f64| if y > 0.0 { x / y } else { f64::INFINITY };
    v.check("god_rows_listed", g.rows >= big, g.rows, &format!(">= {big}"));
    v.at_most(
        "change_bytes_god_over_small",
        ratio(quantile(&g.change_bytes, 0.5), quantile(&a.change_bytes, 0.5)),
        1.5,
    );
    // Latency of one change: a floor of 5 ms so two fast numbers do not make a large ratio.
    v.at_most(
        "change_ms_god_over_small",
        ratio(quantile(&g.change_ms, 0.5).max(5.0), quantile(&a.change_ms, 0.5).max(5.0)),
        3.0,
    );
    v.at_most(
        "first_page_ms_god_over_small",
        ratio(quantile(&g.first_page, 0.5).max(5.0), quantile(&a.first_page, 0.5).max(5.0)),
        3.0,
    );
    v.at_most("god_list_whole_p95_ms", quantile(&g.list, 0.95), 2_000.0);
    v.at_most("god_loaded_ms", g.loaded_ms, 30_000.0);
    v.at_most("god_rss_mb", (g.rss_kb / 1024) as f64, 1_024.0);
    v.at_most("god_send_p95_ms_while_paging", quantile(&g.send_ms, 0.95), 500.0);
    v.at_most("god_send_max_ms_while_paging", quantile(&g.send_ms, 1.0), 2_000.0);
    v.at_most("sends_failed", (a.send_failed + g.send_failed) as f64, 0.0);
    Ok(v)
}
