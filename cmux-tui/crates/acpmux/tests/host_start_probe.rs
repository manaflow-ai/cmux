//! SCRATCH probe (pa-b10, not for landing): where the time of an agent host
//! start goes when a wave of chats opens at once on a busy Mac. Prints a table
//! (the test fails on purpose so the runner shows it).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::agent_host::link::{self, HostLauncher};
use acpmux::agent_host::{self, SpawnSpec};
use acpmux::cpu_class::CpuClass;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("ahp-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn launcher() -> HostLauncher {
    HostLauncher { exe: daemon_env::bin().into(), prefix: Vec::new() }
}

fn spec(dir: &Path, session: &str, program: &str, class: CpuClass) -> SpawnSpec {
    let hosts = dir.join("hosts");
    SpawnSpec {
        session_id: session.into(),
        program: program.into(),
        args: vec![FAKE.into()],
        env: daemon_env::vars(dir, daemon_env::Agents::StandIn, &[]),
        cwd: dir.to_path_buf(),
        translator: None,
        codex_bridge: false,
        socket: agent_host::socket_path(&hosts, session),
        hosts_dir: hosts,
        buffer_cap: agent_host::DEFAULT_BUFFER_CAP,
        router_owner_fifo: None,
        cwd_pin: None,
        cpu_class: class,
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

async fn wave(tag: &str, n: usize, program: &str, class: CpuClass) -> String {
    wave_gated(tag, n, program, class, 0).await
}

async fn wave_gated(tag: &str, n: usize, program: &str, class: CpuClass, gate: usize) -> String {
    let gate =
        std::sync::Arc::new(tokio::sync::Semaphore::new(if gate == 0 { 10_000 } else { gate }));
    let dir = scratch(tag);
    let python = std::env::var("ACPMUX_TEST_PYTHON").unwrap_or_else(|_| "python3".into());
    let program = if program == "python3" { python } else { program.to_owned() };
    let mut set = tokio::task::JoinSet::new();
    let begin = Instant::now();
    for i in 0..n {
        let spec = spec(&dir, &format!("s{i}"), &program, class);
        let gate = gate.clone();
        set.spawn(async move {
            let t = Instant::now();
            let _slot = gate.acquire_owned().await.unwrap();
            let r = link::spawn_within(&launcher(), &spec, Duration::from_secs(180)).await;
            (t.elapsed(), r)
        });
    }
    let mut times = Vec::new();
    let mut ok = 0;
    let mut errs = std::collections::BTreeMap::<String, usize>::new();
    while let Some(Ok((took, r))) = set.join_next().await {
        times.push(took.as_secs_f64() * 1000.0);
        match r {
            Ok(record) => {
                ok += 1;
                if let Some(pg) = record.harness_pid {
                    // SAFETY: the harness leads its own group.
                    unsafe { libc::killpg(pg as i32, libc::SIGKILL) };
                }
                // SAFETY: the host this probe started.
                unsafe { libc::kill(record.host_pid as i32, libc::SIGKILL) };
            }
            Err(e) => {
                let m = format!("{e:#}");
                *errs.entry(m.chars().take(60).collect()).or_default() += 1;
            }
        }
    }
    let wall = begin.elapsed().as_secs_f64() * 1000.0;
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let q = |p: f64| times[((times.len() - 1) as f64 * p).round() as usize];
    tokio::time::sleep(Duration::from_millis(500)).await;
    let _ = std::fs::remove_dir_all(&dir);
    format!(
        "{tag:<34} n={n:<3} ok={ok:<3} min={:>7.0} p50={:>7.0} p90={:>7.0} max={:>7.0} wall={wall:>7.0} load1={:.0} errs={errs:?}",
        q(0.0),
        q(0.5),
        q(0.9),
        q(1.0),
        loadavg()
    )
}

struct Load(Vec<std::process::Child>);
impl Load {
    fn start(n: usize) -> Self {
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
    /// `n` writers that write 4 MiB and fsync, in a loop (a busy disk).
    fn disk(n: usize, dir: &Path) -> Self {
        Self(
            (0..n)
                .map(|i| {
                    let f = dir.join(format!("disk-{i}"));
                    std::process::Command::new("/bin/sh")
                        .arg("-c")
                        .arg(format!(
                            "while :; do dd if=/dev/zero of={} bs=1m count=4 2>/dev/null; sync; done",
                            f.display()
                        ))
                        .spawn()
                        .unwrap()
                })
                .collect(),
        )
    }
}

/// The host's record write (write, F_FULLFSYNC, rename) done 25 at once, as 25
/// hosts of a wave do, from this process at its current I/O policy.
async fn fsync_wave(tag: &str, dir: &Path) -> String {
    let mut set = tokio::task::JoinSet::new();
    for i in 0..25 {
        let path = dir.join(format!("rec-{i}.json"));
        set.spawn_blocking(move || {
            use std::io::Write;
            let t = Instant::now();
            let mut f = std::fs::File::create(&path).unwrap();
            f.write_all(&[b'x'; 512]).unwrap();
            f.sync_all().unwrap();
            t.elapsed().as_secs_f64() * 1000.0
        });
    }
    let mut times = Vec::new();
    while let Some(Ok(t)) = set.join_next().await {
        times.push(t);
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    format!(
        "{tag:<34} fsync x25 min={:>7.0} p50={:>7.0} max={:>7.0}",
        times[0], times[12], times[24]
    )
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
async fn host_start_probe_measure() {
    let ncpu: usize = sysctl("hw.ncpu").parse().unwrap_or(8);
    let disk_dir = scratch("disk");
    let mut out = format!(
        "\nncpu={ncpu} perf0={} perf1={} mem={} os={} load1-at-start={:.0}\n",
        sysctl("hw.perflevel0.physicalcpu"),
        sysctl("hw.perflevel1.physicalcpu"),
        sysctl("hw.memsize"),
        sysctl("kern.osproductversion"),
        loadavg()
    );
    let mut say = |line: String| {
        eprintln!("{line}");
        writeln!(out, "{line}").unwrap();
    };
    let normal = CpuClass::Normal;
    for qos in ["default", "off"] {
        if qos == "off" {
            // SAFETY: set before any host of this pass starts.
            unsafe { std::env::set_var("ACPMUX_QOS", "off") };
        }
        say(wave(&format!("idle qos={qos} host"), 25, "/nonexistent/x", normal).await);
        say(fsync_wave(&format!("idle qos={qos}"), &disk_dir).await);
        for (load, cpu, disk) in [("cpu", ncpu * 10, 0), ("disk", 0, 8), ("cpu+disk", ncpu * 10, 8)]
        {
            let _cpu = Load::start(cpu);
            let _disk = Load::disk(disk, &disk_dir);
            tokio::time::sleep(Duration::from_secs(5)).await;
            let tag = format!("{load} qos={qos}");
            say(wave(&format!("{tag} host n=1"), 1, "/nonexistent/x", normal).await);
            say(wave(&format!("{tag} host"), 25, "/nonexistent/x", normal).await);
            say(wave_gated(&format!("{tag} host gate={ncpu}"), 25, "/nonexistent/x", normal, ncpu)
                .await);
            say(wave(&format!("{tag} harness"), 25, "python3", normal).await);
            say(wave_gated(&format!("{tag} harness gate={ncpu}"), 25, "python3", normal, ncpu)
                .await);
            say(fsync_wave(&tag, &disk_dir).await);
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    let _ = std::fs::remove_dir_all(&disk_dir);
    panic!("PROBE TABLE (ms):{out}");
}
