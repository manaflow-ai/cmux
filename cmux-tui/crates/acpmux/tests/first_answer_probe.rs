//! SCRATCH probe v6 (pa-b10 / #28442, not for landing). Two questions, on ONE host, per start
//! method of a harness:
//! - start: how long until the harness answers (spawn returned, `initialize` = its first line,
//!   `session/new`, the first `session/prompt` answer), 20 at once, idle, under CPU load and
//!   under CPU+disk load (`probe6_start_<load>_<method>`);
//! - runtime: what the class buys while harnesses are busy: `ncpu` spinning harnesses beside
//!   (a) a 60 Hz user-interactive frame loop (how late its frames end) and (b) `ncpu`
//!   foreground spinner threads (their throughput, and the harnesses' CPU share)
//!   (`probe6_runtime_<method>`, and `probe6_runtime_none` without harnesses).
//!
//! Methods: `normal` (no change); `head_clamp` (the head's real `CpuClass::Background.apply`:
//! posix_spawn SETEXEC with the background QoS clamp); `utility_clamp` (the same exec with the
//! utility clamp, as `qos.rs` starts agent hosts); `normal_then_bg` (no change at the spawn,
//! then `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)` from this process once the
//! harness answered `initialize` / said it is up).
//! Every test is in one nextest group of one thread (`nextest.toml`), so they run one at a
//! time; each prints its `PROBE6` line and passes (`success-output = "final"`).
#![cfg(target_os = "macos")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use acpmux::cpu_class::CpuClass;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const PRIO_DARWIN_PROCESS: libc::c_int = 4;
const PRIO_DARWIN_BG: libc::c_int = 0x1000;
const POSIX_SPAWN_SETEXEC: libc::c_short = 0x0040;
const CLAMP_UTILITY: u64 = 1;
const WAVE: usize = 20;
/// One harness's whole start (all phases) longer than this is a hang.
const DEADLINE: Duration = Duration::from_secs(60);
const BUSY: &str = "import sys\nprint('up', flush=True)\nwhile True:\n    pass\n";

#[derive(Clone, Copy, Debug, PartialEq)]
enum How {
    Normal,
    HeadClamp,
    UtilityClamp,
    NormalThenBg,
}

fn loadavg() -> f64 {
    let mut l = [0f64; 3];
    // SAFETY: three doubles.
    unsafe { libc::getloadavg(l.as_mut_ptr(), 3) };
    l[0]
}

fn sysctl(name: &str) -> String {
    std::process::Command::new("/usr/sbin/sysctl")
        .args(["-n", name])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_default()
}

fn ncpu() -> usize {
    sysctl("hw.ncpu").parse().unwrap_or(8)
}

fn pri(pid: u32) -> String {
    std::process::Command::new("/bin/ps")
        .args(["-o", "pri=", "-p", &pid.to_string()])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_default()
}

/// CPU seconds of `pids` so far (`ps -o time=`: [[dd-]hh:]mm:ss.cc).
fn cpu_seconds(pids: &[u32]) -> f64 {
    if pids.is_empty() {
        return 0.0;
    }
    let list = pids.iter().map(u32::to_string).collect::<Vec<_>>().join(",");
    let out = std::process::Command::new("/bin/ps")
        .args(["-o", "time=", "-p", &list])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    out.lines()
        .map(|l| {
            let l = l.trim();
            let (days, rest) =
                l.split_once('-').map_or((0.0, l), |(d, r)| (d.parse().unwrap_or(0.0), r));
            let mut secs = 0.0;
            for part in rest.split(':') {
                secs = secs * 60.0 + part.parse::<f64>().unwrap_or(0.0);
            }
            days * 86400.0 + secs
        })
        .sum()
}

fn python3() -> PathBuf {
    let path = std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin".into());
    std::env::split_paths(&path)
        .map(|d| d.join("python3"))
        .find(|p| p.is_file())
        .unwrap_or_else(|| PathBuf::from("/usr/bin/python3"))
}

/// A posix_spawn SETEXEC under a QoS clamp, built before the fork (the probe's own copy of the
/// head's `ClampedExec`, so the clamp level can be utility).
struct ClampExec {
    path: CString,
    _argv: Vec<CString>,
    _envp: Vec<CString>,
    argv: Vec<*mut libc::c_char>,
    envp: Vec<*mut libc::c_char>,
    attr: libc::posix_spawnattr_t,
}
// SAFETY: pointers into the value's own CStrings and attribute; read only in the forked child.
unsafe impl Send for ClampExec {}
// SAFETY: as above.
unsafe impl Sync for ClampExec {}

type ClampFn = unsafe extern "C" fn(*mut libc::posix_spawnattr_t, u64) -> libc::c_int;

fn clamp_exec(level: u64, program: &Path, args: &[&str]) -> &'static ClampExec {
    // SAFETY: dlsym with a NUL-terminated name.
    let sym =
        unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"posix_spawnattr_set_qos_clamp_np".as_ptr()) };
    assert!(!sym.is_null(), "no posix_spawnattr_set_qos_clamp_np on this macOS");
    // SAFETY: the symbol has this signature (spawn_private.h).
    let set_clamp: ClampFn = unsafe { std::mem::transmute::<*mut libc::c_void, ClampFn>(sym) };
    let path = CString::new(program.as_os_str().to_str().unwrap()).unwrap();
    let argv: Vec<CString> = std::iter::once("python3")
        .chain(args.iter().copied())
        .map(|a| CString::new(a).unwrap())
        .collect();
    let envp: Vec<CString> =
        std::env::vars().map(|(k, v)| CString::new(format!("{k}={v}")).unwrap()).collect();
    let ptrs = |v: &[CString]| -> Vec<*mut libc::c_char> {
        v.iter().map(|a| a.as_ptr().cast_mut()).chain([std::ptr::null_mut()]).collect()
    };
    let (argv_ptrs, envp_ptrs) = (ptrs(&argv), ptrs(&envp));
    let mut attr: libc::posix_spawnattr_t = std::ptr::null_mut();
    // SAFETY: initializes the attribute (leaked with the value, a scratch probe).
    unsafe {
        assert_eq!(libc::posix_spawnattr_init(&mut attr), 0);
        assert_eq!(set_clamp(&mut attr, level), 0);
        assert_eq!(libc::posix_spawnattr_setflags(&mut attr, POSIX_SPAWN_SETEXEC), 0);
    }
    Box::leak(Box::new(ClampExec {
        path,
        _argv: argv,
        _envp: envp,
        argv: argv_ptrs,
        envp: envp_ptrs,
        attr,
    }))
}

/// `python3 <args>` started by `how` (normal_then_bg is lowered later by the caller).
fn command(how: How, args: &[&str]) -> tokio::process::Command {
    let python = python3();
    let mut cmd = tokio::process::Command::new(&python);
    cmd.args(args)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    match how {
        How::Normal | How::NormalThenBg => {}
        How::HeadClamp => {
            let env: Vec<(String, String)> = std::env::vars().collect();
            CpuClass::Background.apply(&mut cmd, &env);
        }
        How::UtilityClamp => {
            let exec = clamp_exec(CLAMP_UTILITY, &python, args);
            // SAFETY: in the forked child, in place of std's execvp; every argument built
            // before the fork (as the head's ClampedExec).
            unsafe {
                cmd.pre_exec(move || {
                    let mut pid: libc::pid_t = 0;
                    let rc = libc::posix_spawn(
                        &mut pid,
                        exec.path.as_ptr(),
                        std::ptr::null(),
                        &exec.attr,
                        exec.argv.as_ptr(),
                        exec.envp.as_ptr(),
                    );
                    Err(std::io::Error::from_raw_os_error(if rc == 0 { libc::EINVAL } else { rc }))
                });
            }
        }
    }
    cmd
}

/// Lowers a running process to darwinbg; the errno on failure.
fn lower(pid: u32) -> Result<(), i32> {
    // SAFETY: plain syscall on a pid this probe started.
    let rc = unsafe { libc::setpriority(PRIO_DARWIN_PROCESS, pid as libc::id_t, PRIO_DARWIN_BG) };
    if rc == 0 { Ok(()) } else { Err(std::io::Error::last_os_error().raw_os_error().unwrap_or(-1)) }
}

/// ms from just before spawn: spawn returned, initialize, session/new, first answer
/// (INFINITY = not within DEADLINE); the harness pri after its start; a lowering error.
struct Phases {
    at: [f64; 4],
    pri: String,
    lower_err: Option<i32>,
}

async fn start_one(how: How) -> Phases {
    let mut cmd = command(how, &[FAKE]);
    let mut at = [f64::INFINITY; 4];
    let t = Instant::now();
    let mut child = cmd.spawn().expect("spawn the fake harness");
    at[0] = t.elapsed().as_secs_f64() * 1000.0;
    let pid = child.id().unwrap_or(0);
    let mut stdin = child.stdin.take().unwrap();
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let (mut session, mut pri_seen, mut lower_err) = (String::new(), String::new(), None);
    let deadline = tokio::time::Instant::now() + DEADLINE;
    for phase in 1..=3usize {
        let params = match phase {
            1 => json!({"protocolVersion": 1, "clientCapabilities": {}}),
            2 => json!({"cwd": std::env::temp_dir(), "mcpServers": []}),
            _ => json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]}),
        };
        let method = ["", "initialize", "session/new", "session/prompt"][phase];
        let id = phase as u64;
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        if stdin.write_all(format!("{request}\n").as_bytes()).await.is_err() {
            break;
        }
        let answered = tokio::time::timeout_at(deadline, async {
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
                if message["id"] == id && message.get("method").is_none() {
                    return Some(message);
                }
            }
            None
        })
        .await;
        let Ok(Some(message)) = answered else { break };
        at[phase] = t.elapsed().as_secs_f64() * 1000.0;
        if phase == 1 {
            if how == How::NormalThenBg {
                lower_err = lower(pid).err();
            }
            pri_seen = pri(pid);
        }
        if phase == 2 {
            session = message["result"]["sessionId"].as_str().unwrap_or_default().to_owned();
        }
    }
    let _ = child.kill().await;
    Phases { at, pri: pri_seen, lower_err }
}

/// Nearest-rank quantile; INFINITY sorts last.
fn q(v: &[f64], p: f64) -> f64 {
    let mut v = v.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let i = ((p * v.len() as f64).ceil() as usize).clamp(1, v.len()) - 1;
    v[i]
}

fn ms(x: f64) -> String {
    if x.is_finite() { format!("{x:.0}") } else { "HANG".into() }
}

struct Load(Vec<std::process::Child>, PathBuf);
impl Load {
    fn new(load: &str) -> Self {
        let n = ncpu();
        let dir = std::env::temp_dir().join(format!("fap6-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let (cpu, disk) = match load {
            "cpu" => (n * 10, 0),
            "cpudisk" => (n * 10, 8),
            _ => (0, 0),
        };
        let mut kids = Vec::new();
        for _ in 0..cpu {
            kids.push(
                std::process::Command::new("/usr/bin/yes")
                    .stdout(std::process::Stdio::null())
                    .spawn()
                    .unwrap(),
            );
        }
        for i in 0..disk {
            kids.push(
                std::process::Command::new("/bin/sh")
                    .arg("-c")
                    .arg(format!(
                        "while :; do dd if=/dev/zero of={} bs=1m count=4 2>/dev/null; sync; done",
                        dir.join(format!("disk-{i}")).display()
                    ))
                    .spawn()
                    .unwrap(),
            );
        }
        Self(kids, dir)
    }
}
impl Drop for Load {
    fn drop(&mut self) {
        for c in &mut self.0 {
            let _ = c.kill();
            let _ = c.wait();
        }
        let _ = std::fs::remove_dir_all(&self.1);
    }
}

async fn start_case(load: &str, how: How) {
    let _ = &HERMETIC;
    let load1_start = loadavg();
    let _load = Load::new(load);
    tokio::time::sleep(Duration::from_secs(if load == "idle" { 1 } else { 5 })).await;
    let load1 = loadavg();
    let mut set = tokio::task::JoinSet::new();
    for _ in 0..WAVE {
        set.spawn(start_one(how));
    }
    let mut all = Vec::new();
    while let Some(Ok(p)) = set.join_next().await {
        all.push(p);
    }
    let hangs = all.iter().filter(|p| !p.at[3].is_finite()).count();
    let pris: std::collections::BTreeSet<_> = all.iter().map(|p| p.pri.clone()).collect();
    let lower_errs: std::collections::BTreeSet<_> =
        all.iter().filter_map(|p| p.lower_err).collect();
    let mut cols = String::new();
    for (i, name) in ["spawn", "first_line", "new", "answer"].iter().enumerate() {
        let v: Vec<f64> = all.iter().map(|p| p.at[i]).collect();
        cols.push_str(&format!(
            " | {name} med={} p95={} max={}",
            ms(q(&v, 0.5)),
            ms(q(&v, 0.95)),
            ms(q(&v, 1.0))
        ));
    }
    println!(
        "PROBE6 START {load:<7} {how:<12?} n={WAVE} hang={hangs}{cols} | pri {pris:?} lower_errno {lower_errs:?} | ncpu={} load1 start={load1_start:.0} wave={load1:.0}",
        ncpu()
    );
}

/// The probe's frame work: `iters` dependent multiply-adds (calibrated to about 2 ms idle).
fn work(iters: u64) -> u64 {
    let mut x = 1u64;
    for i in 0..iters {
        x = std::hint::black_box(x.wrapping_mul(6364136223846793005).wrapping_add(i));
    }
    x
}

fn calibrate() -> u64 {
    let mut iters = 100_000u64;
    loop {
        let t = Instant::now();
        work(iters);
        let e = t.elapsed();
        if e >= Duration::from_millis(2) {
            return iters;
        }
        iters *= 2;
    }
}

/// A 60 Hz user-interactive frame loop for `secs`: each frame wakes at its slot and does
/// `iters` of work; returns how late each frame ENDED past its slot plus its idle work time,
/// in ms (0 = on time with the CPU to itself).
fn frames(secs: u64, iters: u64, idle_work_ms: f64) -> Vec<f64> {
    std::thread::spawn(move || {
        // SAFETY: sets this thread's own QoS class.
        unsafe {
            libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0)
        };
        let period = Duration::from_micros(16_667);
        let start = Instant::now() + period;
        let mut late = Vec::new();
        for k in 0..(secs * 60) as u32 {
            let slot = start + period * k;
            if let Some(d) = slot.checked_duration_since(Instant::now()) {
                std::thread::sleep(d);
            }
            work(iters);
            let end = Instant::now().duration_since(slot).as_secs_f64() * 1000.0;
            late.push((end - idle_work_ms).max(0.0));
        }
        late
    })
    .join()
    .unwrap()
}

/// `n` default-QoS spinner threads for `secs`: iterations per second per thread (millions).
fn spinners(n: usize, secs: u64) -> f64 {
    let stop = Arc::new(AtomicBool::new(false));
    let total = Arc::new(AtomicU64::new(0));
    let threads: Vec<_> = (0..n)
        .map(|_| {
            let (stop, total) = (stop.clone(), total.clone());
            std::thread::spawn(move || {
                let mut count = 0u64;
                while !stop.load(Ordering::Relaxed) {
                    work(10_000);
                    count += 10_000;
                }
                total.fetch_add(count, Ordering::Relaxed);
            })
        })
        .collect();
    std::thread::sleep(Duration::from_secs(secs));
    stop.store(true, Ordering::Relaxed);
    for t in threads {
        let _ = t.join();
    }
    total.load(Ordering::Relaxed) as f64 / (n as f64 * secs as f64) / 1e6
}

async fn runtime_case(how: Option<How>) {
    let _ = &HERMETIC;
    let n = ncpu();
    let iters = calibrate();
    let t = Instant::now();
    work(iters);
    let idle_work_ms = t.elapsed().as_secs_f64() * 1000.0;
    let mut kids = Vec::new();
    let (mut up, mut lower_errs) = (0usize, std::collections::BTreeSet::new());
    let mut up_ms = Vec::new();
    if let Some(how) = how {
        let mut set = tokio::task::JoinSet::new();
        for _ in 0..n {
            set.spawn(async move {
                let t = Instant::now();
                let mut child = command(how, &["-c", BUSY]).spawn().expect("spawn a busy harness");
                let pid = child.id().unwrap_or(0);
                let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
                let ok = matches!(
                    tokio::time::timeout(DEADLINE, lines.next_line()).await,
                    Ok(Ok(Some(_)))
                );
                let ms = t.elapsed().as_secs_f64() * 1000.0;
                let err = if ok && how == How::NormalThenBg { lower(pid).err() } else { None };
                (child, lines, pid, ok, ms, err)
            });
        }
        while let Some(Ok((child, lines, pid, ok, ms, err))) = set.join_next().await {
            up += ok as usize;
            up_ms.push(if ok { ms } else { f64::INFINITY });
            lower_errs.extend(err);
            kids.push((child, lines, pid));
        }
    }
    tokio::time::sleep(Duration::from_secs(1)).await;
    let pids: Vec<u32> = kids.iter().map(|k| k.2).collect();
    let pris: std::collections::BTreeSet<_> = pids.iter().map(|p| pri(*p)).collect();
    // (a) frames beside the busy harnesses.
    let c0 = cpu_seconds(&pids);
    let w0 = Instant::now();
    let late = tokio::task::spawn_blocking(move || frames(5, iters, idle_work_ms)).await.unwrap();
    let share_a = (cpu_seconds(&pids) - c0) / (w0.elapsed().as_secs_f64() * n as f64);
    // (b) n foreground spinner threads beside them.
    let c1 = cpu_seconds(&pids);
    let w1 = Instant::now();
    let rate = tokio::task::spawn_blocking(move || spinners(n, 5)).await.unwrap();
    let share_b = (cpu_seconds(&pids) - c1) / (w1.elapsed().as_secs_f64() * n as f64);
    for (mut child, _, _) in kids {
        let _ = child.kill().await;
    }
    let missed = late.iter().filter(|l| **l > 16.667).count();
    let name = how.map_or("none".to_owned(), |h| format!("{h:?}"));
    println!(
        "PROBE6 RUNTIME {name:<12} busy={}/{n} up med={} max={} | frame late med={:.2} p95={:.2} p99={:.2} max={:.1} missed={missed}/{} (work {idle_work_ms:.2} ms) | harness cpu share beside frames={:.0}% beside {n} spinners={:.0}% | spinner rate={rate:.1} Mi/s/thread | pri {pris:?} lower_errno {lower_errs:?} | load1={:.0}",
        up,
        if up_ms.is_empty() { "-".into() } else { ms(q(&up_ms, 0.5)) },
        if up_ms.is_empty() { "-".into() } else { ms(q(&up_ms, 1.0)) },
        q(&late, 0.5),
        q(&late, 0.95),
        q(&late, 0.99),
        q(&late, 1.0),
        late.len(),
        share_a * 100.0,
        share_b * 100.0,
        loadavg()
    );
}

macro_rules! start_tests {
    ($($name:ident: $load:literal, $how:expr;)*) => {$(
        #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
        async fn $name() {
            start_case($load, $how).await;
        }
    )*};
}

start_tests! {
    probe6_start_idle_normal: "idle", How::Normal;
    probe6_start_idle_head_clamp: "idle", How::HeadClamp;
    probe6_start_idle_utility_clamp: "idle", How::UtilityClamp;
    probe6_start_idle_normal_then_bg: "idle", How::NormalThenBg;
    probe6_start_cpu_normal: "cpu", How::Normal;
    probe6_start_cpu_head_clamp: "cpu", How::HeadClamp;
    probe6_start_cpu_utility_clamp: "cpu", How::UtilityClamp;
    probe6_start_cpu_normal_then_bg: "cpu", How::NormalThenBg;
    probe6_start_cpudisk_normal: "cpudisk", How::Normal;
    probe6_start_cpudisk_head_clamp: "cpudisk", How::HeadClamp;
    probe6_start_cpudisk_utility_clamp: "cpudisk", How::UtilityClamp;
    probe6_start_cpudisk_normal_then_bg: "cpudisk", How::NormalThenBg;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn probe6_runtime_none() {
    runtime_case(None).await;
}
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn probe6_runtime_normal() {
    runtime_case(Some(How::Normal)).await;
}
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn probe6_runtime_head_clamp() {
    runtime_case(Some(How::HeadClamp)).await;
}
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn probe6_runtime_utility_clamp() {
    runtime_case(Some(How::UtilityClamp)).await;
}
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn probe6_runtime_normal_then_bg() {
    runtime_case(Some(How::NormalThenBg)).await;
}
