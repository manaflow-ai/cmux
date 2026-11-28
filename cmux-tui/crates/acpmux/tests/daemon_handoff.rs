//! A restart nobody notices (`acpmux.v2` `start`, `daemon/handoff.rs`): `_acpmux/shutdown
//! {restart: true}` execs the installed build in place. The same pid serves again with the same
//! listening socket (its inode unchanged) and the same WebSocket listener, a dial during the
//! restart waits in the kept socket's backlog instead of being refused, and the status counts the
//! restarts. A build at the installed path that fails its check leaves the daemon serving and the
//! request answered with why. Without `start` the request exits the process as before. The real
//! binary, on Unix.
//!
//! The pause over a god home and a small one, in one harness (an `#[ignore]` bench, for the PR's
//! numbers): `ACPMUX_HANDOFF_RUNS` restarts on each (default 5), the god home at
//! `ACPMUX_HANDOFF_GOD_SCALE` of `Shape::god` (default 0.02). The measured run, on Linux CI:
//! `ACPMUX_HANDOFF_RUNS=20 ACPMUX_HANDOFF_GOD_SCALE=1 cargo test -p acpmux --release --test
//! daemon_handoff -- --ignored --nocapture`.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The bench's sizes hold no credential.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::deny().keep(&["ACPMUX_HANDOFF_RUNS", "ACPMUX_HANDOFF_GOD_SCALE"]);

use acpmux::god_fixture::{self, Shape};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// `config.json` in `home`, with `acpmux.v2` set to `surfaces`.
fn config(home: &Path, surfaces: &[&str]) {
    let path = home.join("config.json");
    std::fs::write(&path, json!({"acpmux.v2": surfaces}).to_string()).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

/// `daemon run --memory` of `cmd` in `home`, ready: its stdout (the ready line, then its log)
/// drained on a thread so a full pipe never holds it.
fn start(cmd: Command, home: &Path, socket: &Path) -> (Child, Value) {
    start_with(cmd, home, socket, true, "warn")
}

/// The daemon's `handoff timing: <mark>` lines (`daemon::HANDOFF_TIMING`), each with the instant
/// its line arrived: the bench's timeline of a restart inside the daemon.
static MARKS: std::sync::Mutex<Vec<(Instant, String)>> = std::sync::Mutex::new(Vec::new());

/// [`start`], its store in memory or, without `memory`, the home's own on disk, logging at `log`.
fn start_with(
    mut cmd: Command,
    home: &Path,
    socket: &Path,
    memory: bool,
    log: &str,
) -> (Child, Value) {
    cmd.args(["daemon", "run"]);
    if memory {
        cmd.arg("--memory");
    }
    cmd.args(["--log", log, "--listen", "127.0.0.1:0", "--token", "test-token", "--ready-fd", "1"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", socket)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    let mut child = cmd.spawn().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let ready = loop {
        let mut line = String::new();
        if stdout.read_line(&mut line).unwrap() == 0 {
            let _ = child.kill();
            let _ = child.wait();
            panic!("the daemon exited before it was ready");
        }
        if let Ok(value) = serde_json::from_str::<Value>(&line)
            && value["ready"] == true
        {
            break value;
        }
    };
    std::thread::spawn(move || {
        // Its log (warnings and up), shown with the test's own output: a handoff that fell back
        // says why there.
        let mut line = String::new();
        while stdout.read_line(&mut line).is_ok_and(|n| n > 0) {
            match line.split_once("handoff timing: ") {
                Some((_, mark)) => MARKS
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .push((Instant::now(), mark.trim().to_owned())),
                None => eprint!("daemon: {line}"),
            }
            line.clear();
        }
    });
    (child, ready)
}

/// What the daemon at `socket` answers to `method`: Ok(result), Err(error), or None when the
/// connection could be made but ended without an answer (the old image's last moment).
fn call(stream: UnixStream, method: &str, params: Value) -> Option<Result<Value, Value>> {
    stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    let mut writer = stream.try_clone().unwrap();
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});
    writer.write_all(format!("{line}\n").as_bytes()).ok()?;
    let mut reader = BufReader::new(stream);
    loop {
        let mut text = String::new();
        if reader.read_line(&mut text).ok()? == 0 {
            return None;
        }
        let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
        if v["id"] == 1 {
            return Some(match v.get("error") {
                Some(error) => Err(error.clone()),
                None => Ok(v["result"].clone()),
            });
        }
    }
}

/// A dial of `socket` that must not be refused: the listener stays open through a handoff.
fn dial(socket: &Path) -> UnixStream {
    UnixStream::connect(socket)
        .unwrap_or_else(|e| panic!("a dial of {} refused: {e}", socket.display()))
}

/// The daemon's status, dialed again while the old image ends a connection it took (at most
/// `within`); every dial must connect.
fn status_after(socket: &Path, within: Duration, want: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + within;
    loop {
        if let Some(Ok(status)) = call(dial(socket), "_acpmux/status", json!({}))
            && want(&status)
        {
            return status;
        }
        assert!(Instant::now() < deadline, "the daemon did not serve again within {within:?}");
        // Short: the bench's pauses are tens of ms, and a longer wait here was a third of them.
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn restart_request() -> Value {
    json!({"restart": true, "reason": "test: daemon_handoff"})
}

fn inode(path: &Path) -> (u64, u64) {
    let meta = std::fs::metadata(path).unwrap();
    (meta.dev(), meta.ino())
}

fn stop(mut child: Child) {
    // SAFETY: the pid is this test's own child.
    unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
    let _ = child.wait();
}

#[test]
fn three_restarts_in_a_row_are_each_an_exec_in_place() {
    let _ = HERMETIC;
    let dir = cmux_unix_socket::short_test_dir("amx-hof");
    let home = dir.path();
    let socket = home.join("s.sock");
    config(home, &["start"]);
    let (mut child, ready) = start(daemon_env::acpmux(home), home, &socket);
    let pid = u64::from(child.id());
    assert_eq!(ready["pid"].as_u64(), Some(pid));
    let first = status_after(&socket, Duration::from_secs(30), |_| true);
    assert_eq!(first["handoffs"], 0, "{first}");
    let listen = first["listen"].clone();
    let socket_id = inode(&socket);

    for n in 1..=3u64 {
        let asked = Instant::now();
        let answer = call(dial(&socket), "_acpmux/shutdown", restart_request())
            .expect("the restart request was answered")
            .unwrap_or_else(|e| panic!("restart {n} refused: {e}"));
        assert_eq!(answer["handoff"], true, "restart {n}: {answer}");
        // Dialed during the handoff: never refused; answered by the new image, or by the old one
        // in its last moment (answered, or ended and then answered on the next dial).
        std::thread::sleep(Duration::from_millis(100));
        // The WebSocket listener too: the stop leaves it listening for the next image, so a
        // connect during the handoff waits in its queue and is never refused.
        let web = listen.as_str().expect("the daemon reports its WebSocket listener");
        if let Err(e) = std::net::TcpStream::connect(web) {
            panic!("restart {n}: a connect to {web} during the handoff was refused: {e}");
        }
        let during = dial(&socket);
        if let Some(reply) = call(during, "_acpmux/status", json!({})) {
            let status = reply.unwrap_or_else(|e| panic!("restart {n}: status refused: {e}"));
            let count = status["handoffs"].as_u64();
            assert!(count == Some(n) || count == Some(n - 1), "restart {n}: {status}");
        }
        let status = status_after(&socket, Duration::from_secs(30), |s| s["handoffs"] == n);
        // The pause a client saw, for the PR's numbers (not a bound): the request sent to the
        // new image's first answer.
        println!("HANDOFF-PAUSE restart={n} ms={}", asked.elapsed().as_millis());
        #[cfg(target_os = "linux")]
        if let Ok(argv) = std::fs::read(format!("/proc/{pid}/cmdline")) {
            println!(
                "HANDOFF-ARGS restart={n} {}",
                String::from_utf8_lossy(&argv).replace('\0', " ")
            );
        }
        assert_eq!(status["pid"].as_u64(), Some(pid), "restart {n}: {status}");
        assert_eq!(status["listen"], listen, "restart {n}: {status}");
        assert_eq!(inode(&socket), socket_id, "restart {n}: the socket was bound again");
        assert!(child.try_wait().unwrap().is_none(), "restart {n}: the daemon process exited");
    }
    stop(child);
}

/// How long the bench waits for a daemon over a god home to serve (its first status, or again
/// after a restart) before it fails.
const BENCH_WITHIN: Duration = Duration::from_secs(120);

fn env_or<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// The small shape, and `Shape::god` at `scale`, neither with peers (a restart does not dial
/// them).
fn shapes(scale: f64) -> [Shape; 2] {
    let god = Shape::god();
    let by = |n: usize| ((n as f64 * scale).ceil() as usize).max(1);
    let god = Shape {
        chats: by(god.chats),
        god_messages: by(god.god_messages),
        god_bytes: (god.god_bytes as f64 * scale) as u64,
        peers: 0,
        ..god
    };
    [Shape { peers: 0, ..Shape::small() }, god]
}

/// p50, p95 and max of `samples`.
fn spread(samples: &[f64]) -> (f64, f64, f64) {
    let mut sorted = samples.to_vec();
    sorted.sort_by(f64::total_cmp);
    let at = |q: f64| sorted[((sorted.len() - 1) as f64 * q).round() as usize];
    (at(0.5), at(0.95), sorted[sorted.len() - 1])
}

/// The bench's `config.json`: `start` on, as [`config`] writes it, and the fixture home's
/// harness (`tests/stop_under_load.rs`), which never starts here: agent launches stay denied.
fn bench_config(home: &Path) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let config = json!({
        "acpmux.v2": ["start"],
        "harnesses": {"claude": {"argv": ["python3", fake]}},
        "defaultHarness": "claude",
        "permissionPolicy": "approve-all",
    });
    let path = home.join("config.json");
    std::fs::write(&path, config.to_string()).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

/// One restart's pause in ms, timed as `three_restarts_in_a_row_are_each_an_exec_in_place` times
/// it (the request sent to the new image's first status), and its parts, which add up to it.
#[derive(Clone, Copy, Default)]
struct Pause {
    total: f64,
    /// The request sent to its answer: the installed build's `daemon handoff-check`.
    request: f64,
    /// Of `request`: sent until the check's child runs.
    dispatch: f64,
    /// The daemon's threads running or in an uninterruptible wait 20 ms into the request.
    busy: f64,
    /// The old image's thread count as the request was sent.
    threads: f64,
    /// Of `request`: the check's child, from its start to its reaping.
    check: f64,
    /// The old image's resident MiB as the request was sent.
    rss_mib: f64,
    /// The check's child's nice value.
    check_nice: f64,
    /// The answer to the exec: the old image's stop.
    stop: f64,
    /// The exec to `daemon::run` (the new image's gauges are born there).
    init: f64,
    /// `daemon::run` to its `requests ready` mark: the new image's start until it serves.
    start: f64,
    /// That mark to the first status the bench read.
    status: f64,
}

impl Pause {
    const PARTS: [&'static str; 11] = [
        "request", "dispatch", "busy", "check", "stop", "init", "start", "status", "rss_mib",
        "threads", "nice",
    ];

    fn part(&self, name: &str) -> f64 {
        match name {
            "request" => self.request,
            "dispatch" => self.dispatch,
            "busy" => self.busy,
            "threads" => self.threads,
            "check" => self.check,
            "rss_mib" => self.rss_mib,
            "nice" => self.check_nice,
            "stop" => self.stop,
            "init" => self.init,
            "start" => self.start,
            _ => self.status,
        }
    }
}

/// What a thread saw of the daemon at `pid` during restart `n` (Linux `/proc`; all None without
/// it).
#[derive(Default)]
struct Seen {
    /// The `daemon handoff-check` child first listed under one of the daemon's threads.
    check_from: Option<Instant>,
    /// That child no longer listed: it ended and was reaped.
    check_to: Option<Instant>,
    /// The child's nice value, as it ran.
    check_nice: Option<i64>,
    /// The pid's command line names handoff count `n`: the exec of restart `n`.
    exec: Option<Instant>,
    /// The daemon's threads running or in an uninterruptible wait (`R` or `D`) 20 ms into the
    /// request.
    busy: Option<u64>,
}

/// How many of `pid`'s threads are running or in an uninterruptible wait now.
fn busy_threads(pid: u64) -> u64 {
    let Ok(tasks) = std::fs::read_dir(format!("/proc/{pid}/task")) else { return 0 };
    let state = |stat: &str| stat.rsplit_once(')').and_then(|(_, r)| r.trim_start().chars().next());
    tasks
        .flatten()
        .filter_map(|task| std::fs::read_to_string(task.path().join("stat")).ok())
        .filter(|stat| matches!(state(stat), Some('R' | 'D')))
        .count() as u64
}

/// The daemon's children now: every thread's `children` list.
fn children(pid: u64) -> Vec<u64> {
    let Ok(tasks) = std::fs::read_dir(format!("/proc/{pid}/task")) else { return Vec::new() };
    tasks
        .flatten()
        .filter_map(|task| std::fs::read_to_string(task.path().join("children")).ok())
        .flat_map(|list| {
            list.split_whitespace().filter_map(|c| c.parse().ok()).collect::<Vec<u64>>()
        })
        .collect()
}

/// [`Seen`] for restart `n`, read from a thread until the exec (at most [`BENCH_WITHIN`]).
fn watch_restart(pid: u64, n: u64) -> std::thread::JoinHandle<Seen> {
    let want = format!("--handoff-count\0{n}\0").into_bytes();
    std::thread::spawn(move || {
        let mut seen = Seen::default();
        // No `/proc` (macOS): the stop and the new image's init read as one part.
        if !Path::new("/proc/self/cmdline").exists() {
            return seen;
        }
        let began = Instant::now();
        let deadline = began + BENCH_WITHIN;
        while Instant::now() < deadline {
            if seen.busy.is_none() && began.elapsed() >= Duration::from_millis(20) {
                seen.busy = Some(busy_threads(pid));
            }
            if seen.check_to.is_none() {
                let now = children(pid);
                match (seen.check_from, now.first()) {
                    (None, Some(child)) => {
                        seen.check_from = Some(Instant::now());
                        seen.check_nice = std::fs::read_to_string(format!("/proc/{child}/stat"))
                            .ok()
                            .and_then(|stat| {
                                let after = stat.rsplit_once(')')?.1.to_owned();
                                after.split_whitespace().nth(16)?.parse().ok()
                            });
                    }
                    (Some(_), None) => seen.check_to = Some(Instant::now()),
                    _ => {}
                }
            }
            if let Ok(argv) = std::fs::read(format!("/proc/{pid}/cmdline"))
                && argv.windows(want.len()).any(|w| w == want)
            {
                seen.exec = Some(Instant::now());
                return seen;
            }
            std::thread::sleep(Duration::from_micros(200));
        }
        seen
    })
}

/// A number field of `pid`'s `/proc/<pid>/status` (`VmRSS` in KiB, `Threads`), on Linux.
fn proc_status(pid: u64, field: &str) -> Option<u64> {
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    let line =
        status.lines().find(|l| l.strip_prefix(field).is_some_and(|r| r.starts_with(':')))?;
    line.split_whitespace().nth(1)?.parse().ok()
}

/// The new image's `daemon::run` start and its `requests ready` mark, from a status it answered
/// at `got`: its gauges' uptime and that mark's offset.
fn born_and_ready(status: &Value, got: Instant) -> Option<(Instant, Instant)> {
    let gauges = &status["gauges"];
    let born = got.checked_sub(Duration::from_millis(gauges["uptimeMs"].as_u64()?))?;
    let ready =
        gauges["startup"].as_array()?.iter().find(|p| p["name"] == "requests ready")?["atMs"]
            .as_u64()?;
    Some((born, born + Duration::from_millis(ready)))
}

/// Whether the startup `status` reports has ended: its last phases began, and none runs.
fn settled(status: &Value) -> bool {
    let Some(phases) = status["gauges"]["startup"].as_array() else { return false };
    let named = |name: &str| phases.iter().any(|p| p["name"] == name);
    named("finish startup") && named("all chat logs") && phases.iter().all(|p| !p["ms"].is_null())
}

/// `shape`'s home, its store on disk, restarted in place `runs` times right after it serves, then
/// `runs` times more once its startup ended ([`settled`]): each series' pauses, and each series'
/// marks ([`MARKS`]) in ms from each request (`next <mark>`: the new image's).
fn pauses(shape: &Shape, runs: u64) -> ([Vec<Pause>; 2], [Marks; 2]) {
    let scratch = daemon_env::Scratch::new(&format!("hof-{}", shape.name));
    let home = scratch.join("acpmux");
    let claude = daemon_env::home(&scratch).join(".claude");
    god_fixture::write_home(&home, &claude, &scratch.join("work"), shape).unwrap();
    bench_config(&home);
    // The socket in a short folder: the scratch folder's path may be too long for one.
    let dir = cmux_unix_socket::short_test_dir("amx-hofb");
    let socket = dir.path().join("s.sock");
    let mut cmd = daemon_env::acpmux(&scratch);
    cmd.env("ACPMUX_CATALOG_FETCH", "0").env("ACPMUX_LOGIN_ENV", "0");
    let (mut child, ready) = start_with(cmd, &home, &socket, false, "warn,handoff_timing=debug");
    let pid = u64::from(child.id());
    assert_eq!(ready["pid"].as_u64(), Some(pid));
    let first = status_after(&socket, BENCH_WITHIN, |_| true);
    assert_eq!(first["handoffs"], 0, "{}: {first}", shape.name);
    let mut series = [Vec::new(), Vec::new()];
    let mut marks: [Marks; 2] = Default::default();
    let mut since = Instant::now();
    let ms = |from: Instant, to: Instant| {
        let (later, sign) = if to >= from { (to - from, 1.0) } else { (from - to, -1.0) };
        sign * later.as_secs_f64() * 1000.0
    };
    for n in 1..=runs * 2 {
        let after_startup = n > runs;
        if after_startup {
            let deadline = Instant::now() + Duration::from_secs(30);
            let mut last = status_after(&socket, BENCH_WITHIN, |_| true);
            while !settled(&last) {
                if Instant::now() > deadline {
                    println!("HANDOFF-SETTLE-TIMEOUT home={} restart={n}", shape.name);
                    break;
                }
                std::thread::sleep(Duration::from_millis(20));
                last = status_after(&socket, BENCH_WITHIN, |_| true);
            }
            // A whole startup's phases, once: what a start of this home costs once it ended.
            if n == runs + 1 {
                println!(
                    "HANDOFF-SETTLED-PHASES home={} phases={}",
                    shape.name, last["gauges"]["startup"]
                );
            }
            since = Instant::now();
        }
        let watch = watch_restart(pid, n);
        let rss = proc_status(pid, "VmRSS").map_or(-1.0, |kib| kib as f64 / 1024.0);
        let threads = proc_status(pid, "Threads").map_or(-1.0, |n| n as f64);
        let asked = Instant::now();
        let answer = call(dial(&socket), "_acpmux/shutdown", restart_request())
            .expect("the restart request was answered")
            .unwrap_or_else(|e| panic!("{} restart {n} refused: {e}", shape.name));
        let answered = Instant::now();
        assert_eq!(answer["handoff"], true, "{} restart {n}: {answer}", shape.name);
        let status = status_after(&socket, BENCH_WITHIN, |s| s["handoffs"] == n);
        let got = Instant::now();
        let seen = watch.join().unwrap();
        let exec = seen.exec.unwrap_or(answered);
        let check_from = seen.check_from.unwrap_or(asked);
        let check_to = seen.check_to.unwrap_or(check_from);
        let (born, ready) = born_and_ready(&status, got).unwrap_or((exec, got));
        {
            let lines = MARKS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let window: Vec<_> =
                lines.iter().filter(|(at, _)| *at >= since && *at <= got).collect();
            let exec_mark = window.iter().find(|(_, name)| name == "exec").map(|(at, _)| *at);
            let mut first: std::collections::BTreeMap<String, f64> = Default::default();
            for (at, name) in window {
                let name = if exec_mark.is_some_and(|e| *at > e) {
                    format!("next {name}")
                } else {
                    name.clone()
                };
                first.entry(name).or_insert_with(|| ms(asked, *at));
            }
            for (name, at) in first {
                marks[usize::from(after_startup)].entry(name).or_default().push(at);
            }
        }
        since = got;
        // The new image's startup phases, once per series: where its start spent the time.
        if n == runs || n == runs * 2 {
            println!(
                "HANDOFF-STARTUP home={} restart={n} phases={}",
                shape.name, status["gauges"]["startup"]
            );
        }
        series[usize::from(after_startup)].push(Pause {
            total: ms(asked, got),
            request: ms(asked, answered),
            dispatch: ms(asked, check_from),
            busy: seen.busy.map_or(-1.0, |n| n as f64),
            threads,
            check: ms(check_from, check_to),
            rss_mib: rss,
            check_nice: seen.check_nice.map_or(-99.0, |nice| nice as f64),
            stop: ms(answered, exec),
            init: ms(exec, born),
            start: ms(born, ready),
            status: ms(ready, got),
        });
        assert_eq!(status["pid"].as_u64(), Some(pid), "{} restart {n}: {status}", shape.name);
        assert!(
            child.try_wait().unwrap().is_none(),
            "{} restart {n}: the daemon exited",
            shape.name
        );
    }
    stop(child);
    (series, marks)
}

/// Each mark's ms from its request, one per restart that logged it.
type Marks = std::collections::BTreeMap<String, Vec<f64>>;

#[test]
#[ignore = "a bench: run with --ignored on Linux CI"]
fn a_restart_in_place_pauses_a_god_home_no_longer_than_a_small_one() {
    let _ = HERMETIC;
    let runs = env_or("ACPMUX_HANDOFF_RUNS", 5u64).max(1);
    let scale = env_or("ACPMUX_HANDOFF_GOD_SCALE", 0.02f64).clamp(0.001, 1.0);
    let mut p95s = Vec::new();
    for shape in shapes(scale) {
        let ([first, later], marks) = pauses(&shape, runs);
        // `when=served`: each restart as soon as the image before it served; `when=settled`: each
        // once that image's startup ended (every chat log read).
        for (when, series) in [("served", &first), ("settled", &later)] {
            let total: Vec<f64> = series.iter().map(|p| p.total).collect();
            let (p50, p95, max) = spread(&total);
            let line = if when == "served" { "SPREAD" } else { "SPREAD-SETTLED" };
            println!(
                "HANDOFF-PAUSE-{line} home={} n={runs} p50={p50:.0} p95={p95:.0} max={max:.0}",
                shape.name
            );
            for part in Pause::PARTS {
                let ms: Vec<f64> = series.iter().map(|p| p.part(part)).collect();
                let (p50, p95, max) = spread(&ms);
                println!(
                    "HANDOFF-PAUSE-SPLIT home={} when={when} part={part} p50={p50:.1} p95={p95:.1} max={max:.1}",
                    shape.name
                );
            }
        }
        // The daemon's own timeline of each restart, in ms from the request, in order.
        for (when, series) in [("served", &marks[0]), ("settled", &marks[1])] {
            let mut rows: Vec<_> =
                series.iter().map(|(name, ms)| (spread(ms), name, ms.len())).collect();
            rows.sort_by(|a, b| a.0.0.total_cmp(&b.0.0));
            for ((p50, p95, max), name, n) in rows {
                println!(
                    "HANDOFF-PAUSE-MARK home={} when={when} mark={name:?} n={n} p50={p50:.1} p95={p95:.1} max={max:.1}",
                    shape.name
                );
            }
        }
        p95s.push(spread(&first.iter().map(|p| p.total).collect::<Vec<_>>()).1);
    }
    let god = &shapes(scale)[1];
    println!(
        "HANDOFF-PAUSE-GOD scale={scale} chats={} messages={} bytes={}",
        god.chats, god.god_messages, god.god_bytes
    );
    let (small_p95, god_p95) = (p95s[0], p95s[1]);
    // The 25 ms floor: under it a ratio of two pauses of a few milliseconds is the scheduler's
    // jitter, not the home.
    assert!(
        god_p95 <= (small_p95 * 1.2).max(small_p95 + 25.0),
        "the god home's restart p95 {god_p95:.0} ms is over 1.2x the small one's {small_p95:.0} ms \
         (or it + 25 ms)"
    );
}

#[test]
fn a_failed_check_leaves_the_daemon_serving_and_answers_the_request() {
    let _ = HERMETIC;
    let dir = cmux_unix_socket::short_test_dir("amx-hofc");
    let home = dir.path();
    let socket = home.join("s.sock");
    config(home, &["start"]);
    // The daemon runs from its own copy, which this test then replaces at the installed path.
    let copy = home.join("acpmux");
    std::fs::copy(daemon_env::bin(), &copy).unwrap();
    std::fs::set_permissions(&copy, std::fs::Permissions::from_mode(0o755)).unwrap();
    let cmd = daemon_env::command_at(&copy, home, daemon_env::Agents::Deny, &[]);
    let (child, _) = start(cmd, home, &socket);
    let pid = u64::from(child.id());

    // A program that takes no handoff, put in place by a rename: the running copy is busy. It
    // stays executable; the update watch's own readiness check fails on it too and keeps this one.
    let script = home.join("acpmux.next");
    std::fs::write(&script, "#!/bin/sh\nexit 1\n").unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::rename(&script, &copy).unwrap();

    let refused = call(dial(&socket), "_acpmux/shutdown", restart_request())
        .expect("the restart request was answered")
        .expect_err("a restart past a failed check");
    assert_eq!(refused["data"]["reason"], "restart.handoff_check_failed", "{refused}");
    let status = status_after(&socket, Duration::from_secs(10), |_| true);
    assert_eq!(status["pid"].as_u64(), Some(pid), "{status}");
    assert_eq!(status["handoffs"], 0, "{status}");
    stop(child);
}

#[test]
fn without_start_a_restart_request_exits_as_before() {
    let _ = HERMETIC;
    let dir = cmux_unix_socket::short_test_dir("amx-hofv");
    let home = dir.path();
    let socket = home.join("s.sock");
    config(home, &["list"]);
    let (mut child, _) = start(daemon_env::acpmux(home), home, &socket);
    let answer = call(dial(&socket), "_acpmux/shutdown", restart_request())
        .expect("the restart request was answered")
        .unwrap_or_else(|e| panic!("refused: {e}"));
    assert!(answer.get("handoff").is_none(), "{answer}");
    let deadline = Instant::now() + Duration::from_secs(30);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "the daemon did not exit after the restart request");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(status.success(), "{status:?}");
    assert!(!socket.exists(), "the stop left its socket");
}
