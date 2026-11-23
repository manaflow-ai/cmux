//! The stream cases: burst, reconnect, daemon-restart, full-disk, slow-link, fanout.

use super::Ctx;
use super::daemon::{Daemon, Sampler, Scratch};
use super::rpc::{self, Conn, FollowOpts, Followed, Follower, Rec};
use super::run::{Verdict, round};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// The scope every thread of a case runs in: each is joined before the case returns.
pub type Sc<'s, 'e> = &'s std::thread::Scope<'s, 'e>;

/// A scratch daemon, started, with its sampler.
pub struct Booted<'s> {
    pub s: Scratch,
    pub d: Daemon,
    pub sampler: Option<Sampler<'s>>,
    run_dir: PathBuf,
}

impl<'s> Booted<'s> {
    pub fn new<'e>(
        sc: Sc<'s, 'e>,
        ctx: &Ctx,
        tag: &str,
        home: Option<PathBuf>,
    ) -> Result<Booted<'s>, String> {
        let s = Scratch::new(&ctx.recipe, tag, home)?;
        Booted::start(sc, ctx, s)
    }

    pub fn start<'e>(sc: Sc<'s, 'e>, ctx: &Ctx, s: Scratch) -> Result<Booted<'s>, String> {
        let d = s.start()?;
        ctx.run.op("daemon_ready", d.ready_ms, true, json!({"pid": d.pid}));
        let sampler = Some(Sampler::start(sc, &ctx.run, &s.socket));
        Ok(Booted { s, d, sampler, run_dir: ctx.run.dir.clone() })
    }

    pub fn socket(&self) -> PathBuf {
        self.s.socket.clone()
    }

    /// (first, peak) RSS in KB; the sampler stops.
    pub fn rss(&mut self) -> (u64, u64) {
        self.sampler.take().map(Sampler::finish).unwrap_or((0, 0))
    }
}

impl Drop for Booted<'_> {
    fn drop(&mut self) {
        if let Some(s) = self.sampler.take() {
            s.finish();
        }
        self.d.stop(&self.s);
        // The daemon's own logs go with the samples, named by the scratch they came from.
        let tag =
            self.s.root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        for e in std::fs::read_dir(&self.s.root).into_iter().flatten().flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with("daemon-") {
                let _ = std::fs::copy(e.path(), self.run_dir.join(format!("{tag}-{name}")));
            }
        }
    }
}

pub fn opts(name: &str, socket: &Path) -> FollowOpts {
    FollowOpts {
        name: name.into(),
        reconnect_every: None,
        socket: socket.to_path_buf(),
        log_events: true,
    }
}

/// `session/prompt` on its own connection, until the turn ends: its duration in ms, or why not.
pub fn turn(socket: &Path, sid: &str, text: &str, within: Duration) -> Result<f64, String> {
    let t = Instant::now();
    let mut c = Conn::connect(socket)?;
    c.call(
        "session/prompt",
        json!({"sessionId": sid, "prompt": [{"type": "text", "text": text}]}),
        within,
    )?;
    Ok(t.elapsed().as_secs_f64() * 1000.0)
}

/// [`turn`] on a thread of the case's scope, for turns that run at once.
pub fn prompt<'s>(
    sc: Sc<'s, '_>,
    socket: &Path,
    sid: &str,
    text: &str,
    within: Duration,
) -> std::thread::ScopedJoinHandle<'s, Result<f64, String>> {
    let (socket, sid, text) = (socket.to_path_buf(), sid.to_owned(), text.to_owned());
    sc.spawn(move || turn(&socket, &sid, &text, within))
}

pub fn join<T>(h: std::thread::ScopedJoinHandle<'_, Result<T, String>>) -> Result<T, String> {
    h.join().map_err(|_| "a thread failed".to_owned())?
}

/// The `w<n>` words of the stand-in agent's `chunks: N` answer, with how often each is held.
pub fn words(truth: &[Rec]) -> HashMap<u64, u32> {
    let mut m = HashMap::new();
    for r in truth.iter().filter(|r| r.update.as_deref() == Some("agent_message_chunk")) {
        for w in r.text.as_deref().unwrap_or_default().split_whitespace() {
            if let Some(n) = w.strip_prefix('w').and_then(|n| n.parse::<u64>().ok()) {
                *m.entry(n).or_insert(0) += 1;
            }
        }
    }
    m
}

/// (missing, doubled) of words 0..n.
pub fn word_loss(w: &HashMap<u64, u32>, n: u64) -> (u64, u64) {
    let missing = (0..n).filter(|i| !w.contains_key(i)).count() as u64;
    let doubled = w.values().map(|c| u64::from(c.saturating_sub(1))).sum();
    (missing, doubled)
}

/// The dots of the stand-in agent's `thoughts: N` burst the daemon holds.
pub fn dots(truth: &[Rec]) -> u64 {
    truth
        .iter()
        .filter(|r| r.update.as_deref() == Some("agent_thought_chunk"))
        .map(|r| {
            r.text.as_deref().unwrap_or_default().bytes().filter(|b| *b == b'.').count() as u64
        })
        .sum()
}

pub fn quantile(v: &[f64], q: f64) -> f64 {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.total_cmp(b));
    let at = ((s.len() as f64 - 1.0) * q).round().max(0.0) as usize;
    s.get(at).copied().unwrap_or(0.0)
}

fn max_seq(truth: &[Rec]) -> u64 {
    truth.iter().map(|r| r.seq).max().unwrap_or(0)
}

/// Loss and duplication of each follower against `truth`, into the verdict's numbers; (missed, dup) summed.
fn judge(
    v: &mut Verdict,
    label: &str,
    truth: &[Rec],
    got: &[Followed],
    upto: Option<u64>,
) -> (u64, u64) {
    let (mut missed, mut dup) = (0, 0);
    let mut rows = Vec::new();
    for g in got {
        let t = rpc::tally(truth, g, upto.unwrap_or_else(|| g.max_seq().max(max_seq(truth))));
        missed += t.missed;
        dup += t.dup(g);
        rows.push(json!({"truth": t.truth, "missed": t.missed, "first_missed": t.first_missed, "dup": t.dup(g),
            "page_live_overlap": g.page_live_overlap, "resent_below_cursor": g.resent_below_cursor,
            "attaches": g.attaches, "attach_errors": g.attach_errors, "bytes": g.bytes, "told_slow": g.told_slow, "lagged": g.lagged,
            "ends": g.ends}));
    }
    v.num(&format!("{label}_readers"), Value::Array(rows));
    // Each lag notice is a re-read the daemon caused by leaving records out of a live stream.
    v.num(&format!("{label}_lagged"), got.iter().map(|g| g.lagged).sum::<u64>());
    (missed, dup)
}

fn ms_since(t: Instant) -> f64 {
    t.elapsed().as_secs_f64() * 1000.0
}

/// The delivery of the last record a burst wrote, ms after `t0_ms` (run clock), by the slowest reader.
fn delivered_by(got: &[Followed], seq: u64, t0_ms: f64) -> Option<f64> {
    let mut worst: Option<f64> = None;
    for g in got {
        let at = g.first_ms.get(&seq)?;
        worst = Some(worst.map_or(*at, |w: f64| w.max(*at)));
    }
    worst.map(|w| w - t0_ms)
}

// ---------------------------------------------------------------------------------------------
// burst

pub fn burst(ctx: &mut Ctx) -> Result<Verdict, String> {
    std::thread::scope(|sc| burst_in(sc, ctx))
}

fn burst_in(sc: Sc<'_, '_>, ctx: &Ctx) -> Result<Verdict, String> {
    let events = ctx.scaled("--events", 50_000)?;
    let chats: usize = ctx.num("--chats", 20)?;
    let chat_events = ctx.scaled("--chat-events", 10_000)?;
    let bound_ms: f64 = ctx.num("--latency-bound-ms", 10_000.0)?;
    let rss_bound_mb: f64 = ctx.num("--rss-bound-mb", 1024.0)?;
    let mut v = Verdict::new("burst");
    let mut b = Booted::new(sc, ctx, "burst", None)?;
    let sock = b.socket();

    // One chat, one write of `events` updates.
    let sid = b.s.new_session("burst-one")?;
    let readers: Vec<Follower> = (0..ctx.coordinators.max(1))
        .map(|i| Follower::start(sc, &ctx.run, &sid, opts(&format!("one-{i}"), &sock)))
        .collect();
    std::thread::sleep(Duration::from_millis(300));
    let t0 = ctx.run.t_ms();
    let turn = turn(&sock, &sid, &format!("thoughts: {events}"), Duration::from_secs(300));
    ctx.run.op(
        "burst_turn",
        turn.as_ref().copied().unwrap_or(-1.0),
        turn.is_ok(),
        json!({"session": sid, "events": events}),
    );
    let truth = rpc::read_all(&sock, &sid)?;
    let top = max_seq(&truth);
    let caught = readers.iter().all(|r| r.wait_for(top, Duration::from_secs(60)));
    let got: Vec<Followed> = readers.into_iter().map(Follower::finish).collect::<Result<_, _>>()?;
    let (missed, dup) = judge(&mut v, "one", &truth, &got, Some(top));
    let held = dots(&truth);
    let deliver = delivered_by(&got, top, t0).unwrap_or(f64::INFINITY);
    v.num("one_turn_ms", round(turn.clone().unwrap_or(-1.0)));
    v.num("one_records", truth.len());
    v.num("one_deliver_all_ms", round(deliver));
    v.check(
        "one_turn_ended",
        turn.is_ok(),
        turn.err().unwrap_or_else(|| "ok".into()),
        "the burst turn ends",
    );
    v.check("one_events_held", held == events, held, &format!("== {events} thought chunks"));
    v.check("one_readers_caught_up", caught, caught, "every reader reaches the log's end");
    v.at_most("one_missed", missed as f64, 0.0);
    v.at_most("one_dup", dup as f64, 0.0);
    v.at_most("one_deliver_all_ms", deliver, bound_ms);

    // `chats` chats at once.
    let mut sids = Vec::new();
    for i in 0..chats {
        sids.push(b.s.new_session(&format!("burst-{i}"))?);
    }
    let readers: Vec<Follower> = sids
        .iter()
        .enumerate()
        .map(|(i, s)| {
            Follower::start(
                sc,
                &ctx.run,
                s,
                FollowOpts { log_events: false, ..opts(&format!("many-{i}"), &sock) },
            )
        })
        .collect();
    std::thread::sleep(Duration::from_millis(300));
    let t1 = ctx.run.t_ms();
    let turns: Vec<_> = sids
        .iter()
        .map(|s| {
            prompt(sc, &sock, s, &format!("thoughts: {chat_events}"), Duration::from_secs(300))
        })
        .collect();
    let turns: Vec<Result<f64, String>> = turns.into_iter().map(join).collect();
    let mut ended = 0;
    for (s, t) in sids.iter().zip(&turns) {
        ctx.run.op(
            "burst_turn",
            t.as_ref().copied().unwrap_or(-1.0),
            t.is_ok(),
            json!({"session": s, "events": chat_events}),
        );
        ended += usize::from(t.is_ok());
    }
    let (mut short, mut missed, mut dup, mut worst) = (0u64, 0u64, 0u64, 0f64);
    let mut caught_all = true;
    let mut gots = Vec::new();
    let mut truths = Vec::new();
    for (s, r) in sids.iter().zip(readers) {
        let truth = rpc::read_all(&sock, s)?;
        let top = max_seq(&truth);
        caught_all &= r.wait_for(top, Duration::from_secs(60));
        let g = r.finish()?;
        short += chat_events.saturating_sub(dots(&truth));
        worst = worst.max(delivered_by(std::slice::from_ref(&g), top, t1).unwrap_or(f64::INFINITY));
        truths.push(truth);
        gots.push(g);
    }
    for (t, g) in truths.iter().zip(&gots) {
        let tally = rpc::tally(t, g, max_seq(t));
        missed += tally.missed;
        dup += tally.dup(g);
    }
    let (first, peak) = b.rss();
    v.num("many_deliver_all_ms", round(worst));
    v.num("rss_first_mb", first / 1024);
    v.num("rss_peak_mb", peak / 1024);
    v.check("many_turns_ended", ended == chats, ended, &format!("== {chats}"));
    v.check("many_events_held", short == 0, short, "0 thought chunks short");
    v.check("many_readers_caught_up", caught_all, caught_all, "every reader reaches its log's end");
    v.at_most("many_missed", missed as f64, 0.0);
    v.at_most("many_dup", dup as f64, 0.0);
    v.at_most("many_deliver_all_ms", worst, bound_ms * 3.0);
    v.at_most("rss_growth_mb", (peak.saturating_sub(first) / 1024) as f64, rss_bound_mb);
    Ok(v)
}

// ---------------------------------------------------------------------------------------------
// reconnect

pub fn reconnect(ctx: &mut Ctx) -> Result<Verdict, String> {
    std::thread::scope(|sc| reconnect_in(sc, ctx))
}

fn reconnect_in(sc: Sc<'_, '_>, ctx: &Ctx) -> Result<Verdict, String> {
    let turns: usize = ctx.num("--turns", 3)?;
    let chunks = ctx.scaled("--chunks", 20_000)?;
    let every: u64 = ctx.num("--reconnect-ms", 200)?;
    let mut v = Verdict::new("reconnect");
    let b = Booted::new(sc, ctx, "reconnect", None)?;
    let sock = b.socket();
    let sid = b.s.new_session("reconnect")?;
    let readers: Vec<Follower> = (0..ctx.coordinators.max(4))
        .map(|i| {
            Follower::start(
                sc,
                &ctx.run,
                &sid,
                FollowOpts {
                    reconnect_every: Some(Duration::from_millis(every)),
                    ..opts(&format!("r{i}"), &sock)
                },
            )
        })
        .collect();
    let steady = Follower::start(sc, &ctx.run, &sid, opts("steady", &sock));
    // At least `turns` turns, and on until `--seconds` of streaming: many reattachments mid-stream.
    let seconds: f64 = ctx.num("--seconds", 15.0)?;
    let t_stream = Instant::now();
    let (mut turn_ok, mut turns_run) = (0, 0);
    while turns_run < turns || t_stream.elapsed().as_secs_f64() < seconds {
        let t = turn(&sock, &sid, &format!("chunks: {chunks}"), Duration::from_secs(300));
        ctx.run.op(
            "turn",
            t.as_ref().copied().unwrap_or(-1.0),
            t.is_ok(),
            json!({"session": sid, "turn": turns_run, "detail": t.as_ref().err()}),
        );
        turn_ok += usize::from(t.is_ok());
        turns_run += 1;
    }
    let turns = turns_run;
    v.num("stream_s", round(t_stream.elapsed().as_secs_f64()));
    let truth = rpc::read_all(&sock, &sid)?;
    let top = max_seq(&truth);
    let caught = readers
        .iter()
        .chain(std::iter::once(&steady))
        .all(|r| r.wait_for(top, Duration::from_secs(60)));
    let got: Vec<Followed> = readers.into_iter().map(Follower::finish).collect::<Result<_, _>>()?;
    let steady = steady.finish()?;
    let (missed, dup) = judge(&mut v, "reconnecting", &truth, &got, Some(top));
    let (smissed, sdup) = judge(&mut v, "steady", &truth, std::slice::from_ref(&steady), Some(top));
    let w = words(&truth);
    let (lost_words, dup_words) = word_loss(&w, chunks);
    let attaches: u64 = got.iter().map(|g| g.attaches).sum();
    let resent: u64 = got.iter().map(|g| g.resent_below_cursor).sum();
    v.num("records", truth.len());
    v.num("attaches", attaches);
    v.num("resent_below_cursor", resent);
    v.check("turns_ended", turn_ok == turns, turn_ok, &format!("== {turns}"));
    v.check("readers_caught_up", caught, caught, "every reader reaches the log's end");
    v.at_most("missed_after_resync", missed as f64, 0.0);
    v.at_most("dup_after_resync", dup as f64, 0.0);
    v.at_most("steady_missed", smissed as f64, 0.0);
    v.at_most("steady_dup", sdup as f64, 0.0);
    // Every turn's words are held once per turn: missing from all turns, or more than `turns` times.
    v.at_most("words_missing", lost_words as f64, 0.0);
    v.at_most(
        "words_extra",
        dup_words.saturating_sub((turns as u64).saturating_sub(1) * chunks) as f64,
        0.0,
    );
    Ok(v)
}

// ---------------------------------------------------------------------------------------------
// daemon-restart

/// The session's status from `_acpmux/info`, or None.
fn status(sock: &Path, sid: &str) -> Option<String> {
    let mut c = Conn::connect(sock).ok()?;
    let i = c.call("_acpmux/info", json!({"sessionId": sid}), Duration::from_secs(30)).ok()?;
    i.get("status").and_then(Value::as_str).map(str::to_owned)
}

/// Waits until the log of `sid` stops growing for `quiet` and its status is not running; the truth then.
fn settle(
    sock: &Path,
    sid: &str,
    quiet: Duration,
    within: Duration,
) -> Result<(Vec<Rec>, bool), String> {
    let t = Instant::now();
    let (mut last, mut since) = (0u64, Instant::now());
    loop {
        let truth = rpc::read_all(sock, sid)?;
        let top = max_seq(&truth);
        if top != last {
            last = top;
            since = Instant::now();
        }
        let idle = !matches!(status(sock, sid).as_deref(), Some("running"));
        if idle && since.elapsed() >= quiet {
            return Ok((truth, true));
        }
        if t.elapsed() >= within {
            return Ok((truth, false));
        }
        std::thread::sleep(Duration::from_millis(250));
    }
}

pub fn daemon_restart(ctx: &mut Ctx) -> Result<Verdict, String> {
    std::thread::scope(|sc| daemon_restart_in(sc, ctx))
}

fn daemon_restart_in(sc: Sc<'_, '_>, ctx: &Ctx) -> Result<Verdict, String> {
    let chunks = ctx.scaled("--chunks", 100_000)?;
    let gap_bound: f64 = ctx.num("--gap-bound-ms", 5_000.0)?;
    let mut v = Verdict::new("daemon-restart");
    let mut b = Booted::new(sc, ctx, "restart", None)?;
    let sock = b.socket();
    let sid = b.s.new_session("restart")?;
    let reader = Follower::start(sc, &ctx.run, &sid, opts("reader", &sock));
    std::thread::sleep(Duration::from_millis(300));
    let base = reader.seen();
    let turn = prompt(sc, &sock, &sid, &format!("chunks: {chunks}"), Duration::from_secs(300));
    // Mid-stream: once a few thousand records went out.
    let mid = reader.wait_for(base + 2_000, Duration::from_secs(60));
    let before = reader.seen();
    let t_stop = Instant::now();
    let stop = b.d.term(Duration::from_secs(20));
    let stop_ms = stop.clone().unwrap_or(-1.0);
    ctx.run.op("daemon_stop", stop_ms, stop.is_ok(), json!({"detail": stop.err()}));
    let started = b.s.start();
    let restarted = started.is_ok();
    match started {
        Ok(d) => {
            ctx.run.op("daemon_ready", d.ready_ms, true, json!({"pid": d.pid, "restart": true}));
            b.d = d;
        }
        Err(e) => ctx.run.op("daemon_ready", -1.0, false, json!({"detail": e})),
    }
    let restart_ms = ms_since(t_stop);
    // The gap: from the stop to the first record past `before` the reader got from the new daemon.
    let resumed = reader.wait_for(before + 1, Duration::from_secs(60));
    let gap_ms = if resumed { ms_since(t_stop) } else { f64::INFINITY };
    let turn = join(turn);
    ctx.run.op(
        "turn",
        turn.as_ref().copied().unwrap_or(-1.0),
        turn.is_ok(),
        json!({"detail": turn.as_ref().err()}),
    );
    let (truth, settled) = if restarted {
        settle(&sock, &sid, Duration::from_secs(3), Duration::from_secs(120))?
    } else {
        (Vec::new(), false)
    };
    let top = max_seq(&truth);
    let caught = reader.wait_for(top, Duration::from_secs(30));
    let got = reader.finish()?;
    let (missed, dup) = judge(&mut v, "reader", &truth, std::slice::from_ref(&got), Some(top));
    let w = words(&truth);
    let (lost_words, dup_words) = word_loss(&w, chunks);
    v.num("records_before_stop", before);
    v.num("stop_ms", round(stop_ms));
    v.num("restart_ms", round(restart_ms));
    v.num("gap_ms", round(gap_ms));
    v.num("words_held", w.len());
    v.num("prompt_reply", turn.as_ref().err().cloned().unwrap_or_else(|| "ok".into()));
    v.check("stopped_mid_stream", mid, before, "the stop came while the turn streamed");
    v.check("restarted", restarted, restarted, "the daemon starts again on the same home");
    v.check("stream_resumed", resumed, resumed, "records flow again after the restart");
    v.at_most("gap_ms", gap_ms, gap_bound);
    v.check("settled", settled, settled, "the turn ends and the log stops growing");
    v.check("reader_caught_up", caught, caught, "the reader reaches the log's end");
    v.at_most("missed", missed as f64, 0.0);
    v.at_most("dup", dup as f64, 0.0);
    v.at_most("words_lost", lost_words as f64, 0.0);
    v.at_most("words_dup", dup_words as f64, 0.0);
    Ok(v)
}

// ---------------------------------------------------------------------------------------------
// full-disk

/// A small filesystem for the daemon's home and how to release it.
struct SmallFs {
    dir: PathBuf,
    mounted: bool,
    ballast: PathBuf,
    how: String,
}

fn avail_bytes(p: &Path) -> Option<u64> {
    let out =
        std::process::Command::new("df").args(["-B1", "--output=avail"]).arg(p).output().ok()?;
    String::from_utf8_lossy(&out.stdout).lines().nth(1)?.trim().parse().ok()
}

fn fallocate(p: &Path, bytes: u64) -> Result<(), String> {
    let ok = std::process::Command::new("fallocate")
        .args(["-l", &bytes.to_string()])
        .arg(p)
        .status()
        .map_err(|e| e.to_string())?;
    if ok.success() { Ok(()) } else { Err(format!("fallocate {} {bytes} failed", p.display())) }
}

impl SmallFs {
    /// A tmpfs of `mb` (with `sudo -n`, when this host allows it), else, with `allow_fill`, the
    /// scratch filesystem filled to `free_mb` free with a ballast file this case made.
    fn make(root: &Path, mb: u64, free_mb: u64, allow_fill: bool) -> Result<SmallFs, String> {
        let dir = root.with_extension("fs");
        super::daemon::private_dir(&dir)?;
        let uid = String::from_utf8_lossy(
            &std::process::Command::new("id").arg("-u").output().map_err(|e| e.to_string())?.stdout,
        )
        .trim()
        .to_owned();
        let mounted = std::process::Command::new("sudo")
            .args([
                "-n",
                "mount",
                "-t",
                "tmpfs",
                "-o",
                &format!("size={mb}m,uid={uid},mode=0700"),
                "coordsim",
            ])
            .arg(&dir)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !mounted && !allow_fill {
            let _ = std::fs::remove_dir(&dir);
            return Err("no small filesystem: sudo -n mount tmpfs is refused here and --allow-fill was not given".into());
        }
        let ballast = dir.join("ballast");
        let avail = avail_bytes(&dir).ok_or("df failed")?;
        let fill = avail.saturating_sub(free_mb << 20);
        fallocate(&ballast, fill)?;
        let how = if mounted {
            format!("tmpfs {mb} MB")
        } else {
            format!("filled scratch fs ({} MB ballast)", fill >> 20)
        };
        Ok(SmallFs { dir, mounted, ballast, how })
    }

    fn release(&self) {
        let _ = std::fs::remove_file(&self.ballast);
    }
}

impl Drop for SmallFs {
    fn drop(&mut self) {
        self.release();
        if self.mounted {
            let _ =
                std::process::Command::new("sudo").args(["-n", "umount"]).arg(&self.dir).status();
        } else {
            let _ = std::fs::remove_dir_all(self.dir.join("amx"));
        }
        let _ = std::fs::remove_dir(&self.dir);
    }
}

/// Every line of every `events/*.ndjson` of `sid` under `home`: (lines, unparsable, seq out of order, torn last line).
fn check_logs(home: &Path, sid: &str) -> (u64, u64, u64, u64) {
    let dir = home.join("sessions").join(sid).join("events");
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
        .map(|d| d.filter_map(Result::ok).map(|e| e.path()).collect())
        .unwrap_or_default();
    files.sort();
    let (mut lines, mut bad, mut order, mut torn, mut last) = (0, 0, 0, 0, 0u64);
    for f in files {
        let text = std::fs::read(&f).unwrap_or_default();
        if !text.is_empty() && text.last() != Some(&b'\n') {
            torn += 1;
        }
        for l in text.split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
            lines += 1;
            match serde_json::from_slice::<Value>(l)
                .ok()
                .and_then(|v| v.get("seq").and_then(Value::as_u64))
            {
                Some(seq) => {
                    if seq <= last {
                        order += 1;
                    }
                    last = seq;
                }
                None => bad += 1,
            }
        }
    }
    (lines, bad, order, torn)
}

pub fn full_disk(ctx: &mut Ctx) -> Result<Verdict, String> {
    std::thread::scope(|sc| full_disk_in(sc, ctx))
}

fn full_disk_in(sc: Sc<'_, '_>, ctx: &Ctx) -> Result<Verdict, String> {
    let mb: u64 = ctx.num("--fs-mb", 96)?;
    let free_mb: u64 = ctx.num("--free-mb", 24)?;
    let prompts: usize = ctx.num("--prompts", 60)?;
    let allow_fill = ctx.args.iter().any(|a| a == "--allow-fill");
    let rss_bound_mb: f64 = ctx.num("--rss-bound-mb", 512.0)?;
    let mut v = Verdict::new("full-disk");
    let probe = Scratch::new(&ctx.recipe, "fullprobe", None)?;
    let fs = SmallFs::make(&probe.root, mb, free_mb, allow_fill)?;
    v.num("filesystem", fs.how.clone());
    let home = fs.dir.join("amx");
    let mut b = Booted::start(sc, ctx, Scratch::new(&ctx.recipe, "full", Some(home.clone()))?)?;
    drop(probe);
    let sock = b.socket();
    let sid = b.s.new_session("full")?;
    let reader = Follower::start(
        sc,
        &ctx.run,
        &sid,
        FollowOpts { log_events: false, ..opts("reader", &sock) },
    );
    // 1 MiB answers until the disk is full and past it.
    let (mut ok, mut failed, mut slowest) = (0, 0, 0f64);
    let mut first_fail = None;
    for i in 0..prompts {
        let t = turn(&sock, &sid, "big-output:1", Duration::from_secs(60));
        let ms = t.as_ref().copied().unwrap_or(-1.0);
        ctx.run.op(
            "big_turn",
            ms,
            t.is_ok(),
            json!({"i": i, "avail": avail_bytes(&fs.dir), "detail": t.as_ref().err()}),
        );
        match t {
            Ok(ms) => {
                ok += 1;
                slowest = slowest.max(ms);
            }
            Err(e) => {
                failed += 1;
                first_fail.get_or_insert(format!("#{i}: {e}"));
            }
        }
        // A daemon whose journal cannot be written stops for a restart (acpmux
        // `a reply waited 10s for the event journal ... the daemon stops so that its restart
        // writes the logs again`): its socket goes first.
        if !b.d.alive() || !sock.exists() {
            break;
        }
    }
    let alive_full = b.d.alive();
    let serving_full = alive_full && sock.exists();
    let unserved_at = Instant::now();
    let avail_at_full = avail_bytes(&fs.dir).unwrap_or(0);
    // Space comes back.
    fs.release();
    // This case is the daemon's supervisor: one that stopped itself must end (bounded), and a new
    // one on the same home must serve the chat whole; the marker prompt must go through and be held.
    let mut exit_ms = None;
    let mut wedged = false;
    let mut supervisor_restarts = 0u64;
    if !serving_full {
        exit_ms = b.d.wait_exit(Duration::from_secs(60));
        if exit_ms.is_none() {
            wedged = true;
            let _ = b.d.term(Duration::from_secs(10));
        }
        b.d = b.s.start()?;
        supervisor_restarts += 1;
    }
    let unserved_ms = if serving_full { 0.0 } else { ms_since(unserved_at) };
    let t = Instant::now();
    let marker = "recovered-after-full-disk";
    let after = turn(&sock, &sid, marker, Duration::from_secs(60));
    ctx.run.op(
        "recovery_turn",
        ms_since(t),
        after.is_ok(),
        json!({"detail": after.as_ref().err()}),
    );
    let truth = rpc::read_all(&sock, &sid).unwrap_or_default();
    let held = truth.iter().any(|r| r.text.as_deref().is_some_and(|x| x.contains(marker)));
    let top = max_seq(&truth);
    let caught = reader.wait_for(top, Duration::from_secs(30));
    let got = reader.finish()?;
    let (missed, dup) = judge(&mut v, "reader", &truth, std::slice::from_ref(&got), Some(top));
    let (first, peak) = b.rss();
    // No corruption: every log line parses, in order, and a new daemon reads the chat whole.
    b.d.stop(&b.s);
    let (lines, bad, order, torn) = check_logs(&home, &sid);
    let again = b.s.start();
    let reread = match &again {
        Ok(_) => rpc::read_all(&sock, &sid)
            .map(|t| t.iter().any(|r| r.text.as_deref().is_some_and(|x| x.contains(marker))))
            .unwrap_or(false),
        Err(_) => false,
    };
    if let Ok(d) = again {
        b.d = d;
    }
    v.num("prompts_ok", ok);
    v.num("prompts_failed", failed);
    v.num("first_failure", first_fail.unwrap_or_default());
    v.num("slowest_ok_turn_ms", round(slowest));
    v.num("avail_at_full_bytes", avail_at_full);
    v.num("log_lines", lines);
    v.num("rss_first_mb", first / 1024);
    v.num("rss_peak_mb", peak / 1024);
    v.check(
        "disk_filled",
        failed > 0 || avail_at_full < (4 << 20),
        avail_at_full,
        "the disk was full during the run",
    );
    v.num("serving_when_full", serving_full);
    v.num("alive_when_full", alive_full);
    v.num("supervisor_restarts", supervisor_restarts);
    v.num("unserved_ms", round(unserved_ms));
    v.num("self_stop_exit_ms_after_space", exit_ms.map(round));
    // Bounded failure: a daemon that cannot write either serves on or ends, never sits alive
    // without its socket once space is back.
    v.check(
        "bounded_failure",
        !wedged,
        exit_ms.map(round).map_or("still running 60 s after space came back".into(), |m| {
            if serving_full {
                "served on".into()
            } else {
                format!("stopped itself, exited {m} ms after space")
            }
        }),
        "serves on, or stops and exits within 60 s of space returning",
    );
    v.at_most("rss_growth_mb", (peak.saturating_sub(first) / 1024) as f64, rss_bound_mb);
    v.at_most("unparsable_lines", bad as f64, 0.0);
    v.at_most("seq_out_of_order", order as f64, 0.0);
    v.at_most("torn_files", torn as f64, 0.0);
    v.check(
        "recovered",
        after.is_ok() && held,
        after.err().unwrap_or_else(|| format!("held={held}")),
        "a prompt after space returns is answered and held",
    );
    v.check("restart_reads_chat", reread, reread, "a new daemon reads the chat and its marker");
    v.check("reader_caught_up", caught, caught, "the reader reaches the log's end");
    v.at_most("missed", missed as f64, 0.0);
    v.at_most("dup", dup as f64, 0.0);
    Ok(v)
}

// ---------------------------------------------------------------------------------------------
// slow-link

pub fn slow_link(ctx: &mut Ctx) -> Result<Verdict, String> {
    std::thread::scope(|sc| slow_link_in(sc, ctx))
}

fn slow_link_in(sc: Sc<'_, '_>, ctx: &Ctx) -> Result<Verdict, String> {
    let slow: usize = ctx.num("--slow-readers", 4)?;
    let rounds: usize = ctx.num("--rounds", 40)?;
    let rate: u64 = ctx.num("--rate-bps", 65_536)?;
    let latency: u64 = ctx.num("--latency-ms", 300)?;
    let per_reader_mb: f64 = ctx.num("--per-reader-mb", 64.0)?;
    let mut v = Verdict::new("slow-link");
    let mut b = Booted::new(sc, ctx, "slow", None)?;
    let sock = b.socket();
    let sid = b.s.new_session("slow")?;
    let proxy = super::proxy::Proxy::start(
        sc,
        &b.s.root.join("slow.sock"),
        &sock,
        super::proxy::Link { rate_bps: rate, latency: Duration::from_millis(latency) },
    )?;
    let slows: Vec<Follower> = (0..slow)
        .map(|i| {
            Follower::start(
                sc,
                &ctx.run,
                &sid,
                FollowOpts { log_events: false, ..opts(&format!("slow{i}"), &proxy.listen) },
            )
        })
        .collect();
    let fast = Follower::start(
        sc,
        &ctx.run,
        &sid,
        FollowOpts { log_events: false, ..opts("fast", &sock) },
    );
    std::thread::sleep(Duration::from_millis(500));
    // Each round: a 2 MiB answer and a burst of 2,000 small updates.
    let mut lags = Vec::new();
    let mut ok = 0;
    for i in 0..rounds {
        for text in ["big-output:2", "thoughts: 2000"] {
            let t = turn(&sock, &sid, text, Duration::from_secs(120));
            ctx.run.op(
                "turn",
                t.as_ref().copied().unwrap_or(-1.0),
                t.is_ok(),
                json!({"i": i, "prompt": text}),
            );
            ok += usize::from(t.is_ok());
        }
        // How far behind the fast reader is right after the turn: the time it takes to reach the log's end.
        let top = rpc::read_all(&sock, &sid).map(|t| max_seq(&t)).unwrap_or(0);
        let t = Instant::now();
        let got = fast.wait_for(top, Duration::from_secs(30));
        lags.push(if got { ms_since(t) } else { f64::INFINITY });
    }
    let truth = rpc::read_all(&sock, &sid)?;
    let top = max_seq(&truth);
    let fast_caught = fast.wait_for(top, Duration::from_secs(30));
    let (max_queued, overruns) = b.sampler.as_ref().map_or((0, 0), |s| {
        (
            s.max_queued.load(std::sync::atomic::Ordering::SeqCst),
            s.overruns.load(std::sync::atomic::Ordering::SeqCst),
        )
    });
    let (first, peak) = b.rss();
    v.num("daemon_max_queued_bytes", max_queued);
    v.num("daemon_reader_overruns", overruns);
    let fast = fast.finish()?;
    let slows: Vec<Followed> = slows.into_iter().map(Follower::finish).collect::<Result<_, _>>()?;
    let (fmissed, fdup) = judge(&mut v, "fast", &truth, std::slice::from_ref(&fast), Some(top));
    // A slow reader is judged on what it reached: no gap below its own cursor.
    let mut smissed = 0;
    let mut sdup = 0;
    let mut rows = Vec::new();
    for g in &slows {
        let t = rpc::tally(&truth, g, g.max_seq());
        smissed += t.missed;
        sdup += t.dup(g);
        rows.push(json!({"reached": g.max_seq(), "missed": t.missed, "first_missed": t.first_missed, "dup": t.dup(g),
            "bytes": g.bytes, "attaches": g.attaches, "told_slow": g.told_slow, "ends": g.ends}));
    }
    v.num("slow_readers", Value::Array(rows));
    let growth_mb = (peak.saturating_sub(first) / 1024) as f64;
    let bound = per_reader_mb * slow as f64 + 256.0;
    v.num("proxy_down_bytes", proxy.down_bytes.load(std::sync::atomic::Ordering::Relaxed));
    v.num("records", truth.len());
    v.num("fast_lag_p50_ms", round(quantile(&lags, 0.5)));
    v.num("rss_first_mb", first / 1024);
    v.num("rss_peak_mb", peak / 1024);
    let p99 = quantile(&lags, 0.99);
    v.check("turns_ended", ok == rounds * 2, ok, &format!("== {}", rounds * 2));
    v.at_most("rss_growth_mb", growth_mb, bound);
    // The daemon names each connection's bound (64 MiB): all of them together stay under one per reader.
    v.at_most("daemon_max_queued_mb", (max_queued >> 20) as f64, per_reader_mb * (slow + 1) as f64);
    v.at_most("fast_lag_p99_ms", p99, 2_000.0);
    v.check("fast_caught_up", fast_caught, fast_caught, "the direct reader reaches the log's end");
    v.at_most("fast_missed", fmissed as f64, 0.0);
    v.at_most("fast_dup", fdup as f64, 0.0);
    v.at_most("slow_missed_below_cursor", smissed as f64, 0.0);
    v.at_most("slow_dup", sdup as f64, 0.0);
    drop(proxy);
    Ok(v)
}

// ---------------------------------------------------------------------------------------------
// fanout

/// Whole-list readers paging `_acpmux/sessions` until stopped: each read's ms into ops.ndjson.
/// Its threads are the case scope's: stopped when dropped, joined by the scope.
pub struct Pagers<'s> {
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    handles: Vec<std::thread::ScopedJoinHandle<'s, Vec<f64>>>,
}

impl Drop for Pagers<'_> {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::SeqCst);
    }
}

impl<'s> Pagers<'s> {
    pub fn start(sc: Sc<'s, '_>, ctx: &Ctx, sock: &Path, n: usize) -> Pagers<'s> {
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let handles = (0..n)
            .map(|i| {
                let (stop, sock, run) = (stop.clone(), sock.to_path_buf(), ctx.run.clone());
                sc.spawn(move || {
                    let mut out = Vec::new();
                    while !stop.load(std::sync::atomic::Ordering::SeqCst) {
                        let t = Instant::now();
                        let r = whole_list(&sock);
                        let ms = ms_since(t);
                        run.op("list_whole", ms, r.is_ok(), json!({"pager": i, "pages": r.as_ref().map(|p| p.pages).ok(), "detail": r.as_ref().err()}));
                        out.push(ms);
                    }
                    out
                })
            })
            .collect();
        Pagers { stop, handles }
    }

    pub fn finish(mut self) -> Vec<f64> {
        self.stop.store(true, std::sync::atomic::Ordering::SeqCst);
        std::mem::take(&mut self.handles)
            .into_iter()
            .filter_map(|h| h.join().ok())
            .flatten()
            .collect()
    }
}

pub struct Listed {
    pub rows: usize,
    pub pages: usize,
    pub bytes: u64,
    pub first_page_ms: f64,
}

/// The whole session list, page by page, as every whole-list reader follows `nextCursor`.
pub fn whole_list(sock: &Path) -> Result<Listed, String> {
    let mut c = Conn::connect(sock)?;
    let mut l = Listed { rows: 0, pages: 0, bytes: 0, first_page_ms: 0.0 };
    let mut cursor = Value::Null;
    let t = Instant::now();
    loop {
        let params = if cursor.is_null() { json!({}) } else { json!({"cursor": cursor}) };
        let page = c.call("_acpmux/sessions", params, Duration::from_secs(120))?;
        if l.pages == 0 {
            l.first_page_ms = ms_since(t);
        }
        l.pages += 1;
        l.rows += page.get("sessions").and_then(Value::as_array).map_or(0, Vec::len);
        let next = page.get("nextCursor").cloned().unwrap_or(Value::Null);
        if next.is_null() || next == cursor || l.pages > 100_000 {
            break;
        }
        cursor = next;
    }
    l.bytes = c.bytes_in;
    Ok(l)
}

/// `acpmux send --no-wait NAME TEXT` for each (name, text) at once: each one's return ms and success.
pub fn sends_at_once(
    sc: Sc<'_, '_>,
    s: &Scratch,
    msgs: &[(String, String)],
) -> Vec<(f64, bool, String)> {
    let gate = std::sync::Arc::new(std::sync::Barrier::new(msgs.len()));
    let handles: Vec<_> = msgs
        .iter()
        .map(|(name, text)| {
            let mut cmd = s.cmd();
            cmd.args(["send", "--no-wait", name, text]);
            let gate = gate.clone();
            sc.spawn(move || {
                gate.wait();
                let t = Instant::now();
                let out = cmd.output();
                let ms = ms_since(t);
                match out {
                    Ok(o) => (
                        ms,
                        o.status.success(),
                        String::from_utf8_lossy(&o.stderr).chars().take(200).collect(),
                    ),
                    Err(e) => (ms, false, e.to_string()),
                }
            })
        })
        .collect();
    handles
        .into_iter()
        .map(|h| h.join().unwrap_or((f64::INFINITY, false, "thread failed".into())))
        .collect()
}

/// Waits until every session in `want` (id, text) holds an answer echoing its text; how many did, and when.
fn answered(sock: &Path, want: &[(String, String)], within: Duration) -> (usize, f64) {
    let t = Instant::now();
    let mut done = vec![false; want.len()];
    loop {
        for (i, (sid, text)) in want.iter().enumerate() {
            if done.get(i) == Some(&true) {
                continue;
            }
            let held = rpc::read_all(sock, sid)
                .map(|t| {
                    t.iter().any(|r| {
                        r.update.as_deref() == Some("agent_message_chunk")
                            && r.text.as_deref().is_some_and(|x| x.contains(text.as_str()))
                    })
                })
                .unwrap_or(false);
            if let Some(d) = done.get_mut(i) {
                *d = held;
            }
        }
        let n = done.iter().filter(|d| **d).count();
        if n == want.len() || t.elapsed() > within {
            return (n, ms_since(t));
        }
        std::thread::sleep(Duration::from_millis(250));
    }
}

/// Waits until `n` sessions are live (their harness runs); how many were.
fn wait_live(s: &Scratch, n: usize, within: Duration) -> usize {
    let t = Instant::now();
    loop {
        let live = s
            .cli_json(&["ls"])
            .ok()
            .and_then(|v| v.get("sessions").and_then(Value::as_array).cloned())
            .unwrap_or_default()
            .iter()
            .filter(|r| {
                matches!(
                    r.get("status").and_then(Value::as_str),
                    Some("ready" | "running" | "waiting" | "idle")
                )
            })
            .count();
        if live >= n || t.elapsed() > within {
            return live;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

pub fn fanout(ctx: &mut Ctx) -> Result<Verdict, String> {
    std::thread::scope(|sc| fanout_in(sc, ctx))
}

fn fanout_in(sc: Sc<'_, '_>, ctx: &Ctx) -> Result<Verdict, String> {
    let n: usize = ctx.num("--sessions", 200)?;
    let pagers: usize = ctx.num("--pagers", 4)?;
    let send_p95_bound: f64 = ctx.num("--send-p95-bound-ms", 500.0)?;
    let mut v = Verdict::new("fanout");
    let mut b = Booted::new(sc, ctx, "fanout", None)?;
    let sock = b.socket();
    // Made 16 at a time.
    let mut ids: Vec<(String, String)> = Vec::new();
    for chunk in (0..n).collect::<Vec<_>>().chunks(16) {
        let hs: Vec<_> = chunk
            .iter()
            .map(|i| {
                let name = format!("fan-{i}");
                let mut cmd = b.s.cmd();
                cmd.args(["--json", "new", "-d", "-n", &name]);
                sc.spawn(move || {
                    let t = Instant::now();
                    let out = cmd.output().map_err(|e| e.to_string())?;
                    let id = serde_json::from_slice::<Value>(&out.stdout).ok().and_then(|v| {
                        v.get("sessionId").and_then(Value::as_str).map(str::to_owned)
                    });
                    id.map(|id| (name, id, ms_since(t))).ok_or(
                        String::from_utf8_lossy(&out.stderr).chars().take(200).collect::<String>(),
                    )
                })
            })
            .collect();
        for h in hs {
            let (name, id, ms) = join(h)?;
            ctx.run.op("create", ms, true, json!({"session": id}));
            ids.push((name, id));
        }
    }
    let live = wait_live(&b.s, n, Duration::from_secs(180));
    let pg = Pagers::start(sc, ctx, &sock, pagers);
    std::thread::sleep(Duration::from_millis(500));
    let msgs: Vec<(String, String)> = ids
        .iter()
        .enumerate()
        .map(|(i, (name, _))| (name.clone(), format!("fanout-{i}-msg")))
        .collect();
    let t = Instant::now();
    let sent = sends_at_once(sc, &b.s, &msgs);
    let all_sent_ms = ms_since(t);
    for ((name, _), (ms, ok, err)) in msgs.iter().zip(&sent) {
        ctx.run.op(
            "send_no_wait",
            *ms,
            *ok,
            json!({"session": name, "detail": if *ok { Value::Null } else { json!(err) }}),
        );
    }
    let want: Vec<(String, String)> =
        ids.iter().zip(&msgs).map(|((_, id), (_, text))| (id.clone(), text.clone())).collect();
    let (n_answered, answered_ms) = answered(&sock, &want, Duration::from_secs(180));
    let lists = pg.finish();
    let (first, peak) = b.rss();
    let lat: Vec<f64> = sent.iter().map(|s| s.0).collect();
    let failed = sent.iter().filter(|s| !s.1).count();
    v.num("live_sessions", live);
    v.num("send_p50_ms", round(quantile(&lat, 0.5)));
    v.num("all_sent_ms", round(all_sent_ms));
    v.num("all_answered_ms", round(answered_ms + all_sent_ms));
    v.num("list_reads_during", lists.len());
    v.num("list_whole_p50_ms", round(quantile(&lists, 0.5)));
    v.num("list_whole_p95_ms", round(quantile(&lists, 0.95)));
    v.num("rss_first_mb", first / 1024);
    v.num("rss_peak_mb", peak / 1024);
    v.check("sessions_live", live >= n, live, &format!(">= {n}"));
    v.at_most("sends_failed", failed as f64, 0.0);
    v.at_most("send_p95_ms", quantile(&lat, 0.95), send_p95_bound);
    v.at_most("send_max_ms", quantile(&lat, 1.0), send_p95_bound * 4.0);
    v.check("all_answered", n_answered == n, n_answered, &format!("== {n} within 180 s"));
    v.at_most("rss_growth_mb", (peak.saturating_sub(first) / 1024) as f64, 1024.0);
    Ok(v)
}
