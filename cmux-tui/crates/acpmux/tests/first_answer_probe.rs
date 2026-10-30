//! SCRATCH probe v5 (pa-b10 / #28442, not for landing): where a background harness's time to
//! its first answer goes, by start mechanism, in ONE process on ONE host, interleaved:
//! - `normal`: no class change;
//! - `base-bg`: the base's mechanism (5a5aba66): `setpriority(PRIO_DARWIN_BG)` in pre_exec,
//!   then std's execvp;
//! - `head-clamp`: the head's real code, `CpuClass::Background.apply` (posix_spawn SETEXEC
//!   with the background QoS clamp in pre_exec).
//!
//! Each harness is `python3 tests/fake_agent.py` driven over ACP stdio. Phases, in ms from
//! just before `spawn()`: spawn returned, `initialize` answered (harness up and reading),
//! `session/new` answered, first `session/prompt` answered (the first answer). Waves of N at
//! once, idle and under CPU and CPU+disk load, the three mechanisms interleaved per round.
//! The test fails on purpose so the runner prints the table.
#![cfg(target_os = "macos")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use std::fmt::Write as _;
use std::path::Path;
use std::time::{Duration, Instant};

use acpmux::cpu_class::CpuClass;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const PRIO_DARWIN_PROCESS: libc::c_int = 4;
const PRIO_DARWIN_BG: libc::c_int = 0x1000;
const WAVE: usize = 10;
const ROUNDS: usize = 3;
/// A phase that takes longer than this counts as a hang (the subsession test's socket read).
const HANG: Duration = Duration::from_secs(60);

#[derive(Clone, Copy, Debug)]
enum How {
    Normal,
    BaseBg,
    HeadClamp,
}

impl How {
    fn name(self) -> &'static str {
        match self {
            How::Normal => "normal",
            How::BaseBg => "base-bg",
            How::HeadClamp => "head-clamp",
        }
    }
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

fn pri(pid: u32) -> String {
    std::process::Command::new("/bin/ps")
        .args(["-o", "pri=", "-p", &pid.to_string()])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_default()
}

/// Phases in ms: spawn returned, initialize, session/new, first answer; and the harness pri.
/// A phase that did not end within `HANG` is `f64::INFINITY` (and the later ones too).
#[derive(Clone, Debug)]
struct Phases {
    at: [f64; 4],
    pri: String,
}

async fn one(how: How) -> Phases {
    let mut cmd = tokio::process::Command::new("python3");
    cmd.arg(FAKE)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .process_group(0)
        .kill_on_drop(true);
    match how {
        How::Normal => {}
        How::BaseBg => {
            // SAFETY: one async-signal-safe syscall in the child (the base's hook, verbatim).
            unsafe {
                cmd.pre_exec(|| {
                    libc::setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG);
                    Ok(())
                });
            }
        }
        How::HeadClamp => {
            // The complete env the child starts with: this process's (no env_clear here).
            let env: Vec<(String, String)> = std::env::vars().collect();
            CpuClass::Background.apply(&mut cmd, &env);
        }
    }
    let mut at = [f64::INFINITY; 4];
    let t = Instant::now();
    let mut child = cmd.spawn().expect("spawn the fake harness");
    at[0] = t.elapsed().as_secs_f64() * 1000.0;
    let pid = child.id().unwrap_or(0);
    let mut stdin = child.stdin.take().unwrap();
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let mut session = String::new();
    let mut pri_seen = String::new();
    for (phase, id) in [(1usize, 1u64), (2, 2), (3, 3)] {
        let params = match phase {
            1 => json!({"protocolVersion": 1, "clientCapabilities": {}}),
            2 => json!({"cwd": std::env::temp_dir(), "mcpServers": []}),
            _ => json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]}),
        };
        let method = ["", "initialize", "session/new", "session/prompt"][phase];
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        if stdin.write_all(format!("{request}\n").as_bytes()).await.is_err() {
            break;
        }
        let answered = tokio::time::timeout(HANG, async {
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
            pri_seen = pri(pid);
        }
        if phase == 2 {
            session = message["result"]["sessionId"].as_str().unwrap_or_default().to_owned();
        }
    }
    // SAFETY: the process group this probe started.
    unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
    let _ = child.wait().await;
    Phases { at, pri: pri_seen }
}

fn q(v: &mut [f64], p: f64) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[((v.len() - 1) as f64 * p).round() as usize]
}

fn ms(x: f64) -> String {
    if x.is_finite() { format!("{x:.0}") } else { "HANG".into() }
}

async fn wave(tag: &str, how: How) -> String {
    let load = loadavg();
    let mut set = tokio::task::JoinSet::new();
    for _ in 0..WAVE {
        set.spawn(one(how));
    }
    let mut phases = Vec::new();
    while let Some(Ok(p)) = set.join_next().await {
        phases.push(p);
    }
    let hangs = phases.iter().filter(|p| !p.at[3].is_finite()).count();
    let pris: std::collections::BTreeSet<_> = phases.iter().map(|p| p.pri.clone()).collect();
    let mut cols = String::new();
    for (i, name) in ["spawn", "init", "new", "answer"].iter().enumerate() {
        let mut v: Vec<f64> = phases.iter().map(|p| p.at[i]).collect();
        let (p50, p90, max) = (q(&mut v, 0.5), q(&mut v, 0.9), q(&mut v, 1.0));
        write!(cols, " | {name} p50={:>6} p90={:>6} max={:>6}", ms(p50), ms(p90), ms(max)).unwrap();
    }
    format!(
        "PROBE {tag:<11} {:<10} n={WAVE} hang={hangs}{cols} | pri {pris:?} load1-before={load:.0}",
        how.name()
    )
}

struct Load(Vec<std::process::Child>);
impl Load {
    fn cpu(n: usize) -> Self {
        Self(
            (0..n)
                .map(|_| {
                    std::process::Command::new("/usr/bin/yes")
                        .stdout(std::process::Stdio::null())
                        .spawn()
                        .unwrap()
                })
                .collect(),
        )
    }
    fn disk(n: usize, dir: &Path) -> Self {
        Self(
            (0..n)
                .map(|i| {
                    std::process::Command::new("/bin/sh")
                        .arg("-c")
                        .arg(format!(
                            "while :; do dd if=/dev/zero of={} bs=1m count=4 2>/dev/null; sync; done",
                            dir.join(format!("disk-{i}")).display()
                        ))
                        .spawn()
                        .unwrap()
                })
                .collect(),
        )
    }
}
impl Drop for Load {
    fn drop(&mut self) {
        for c in &mut self.0 {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn first_answer_probe_measure() {
    let _ = &HERMETIC;
    let ncpu: usize = sysctl("hw.ncpu").parse().unwrap_or(8);
    let dir = std::env::temp_dir().join(format!("fap-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let mut out = format!(
        "\nncpu={ncpu} perflevels={} os={} load1-at-start={:.0}\n",
        sysctl("hw.nperflevels"),
        sysctl("kern.osproductversion"),
        loadavg()
    );
    let mut say = |line: String| {
        eprintln!("{line}");
        writeln!(out, "{line}").unwrap();
    };
    let all = [How::Normal, How::BaseBg, How::HeadClamp];
    // Rotate the order each round so no mechanism always runs first after a pause.
    for round in 0..ROUNDS {
        for k in 0..all.len() {
            say(wave(&format!("idle r{round}"), all[(round + k) % all.len()]).await);
        }
    }
    for (load, cpu, disk) in [("cpu", ncpu * 10, 0), ("cpu+disk", ncpu * 10, 8)] {
        let _cpu = Load::cpu(cpu);
        let _disk = Load::disk(disk, &dir);
        tokio::time::sleep(Duration::from_secs(5)).await;
        for round in 0..ROUNDS {
            for k in 0..all.len() {
                say(wave(&format!("{load} r{round}"), all[(round + k) % all.len()]).await);
            }
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
    panic!("PROBE TABLE (ms from spawn):{out}");
}
