//! SCRATCH probe v4 (pa-b10, not for landing): for each way to start a harness
//! at background class, how long until the spawn call returns and until the
//! harness is up (its first stdout line), 25 at once on an idle and a busy
//! Mac, and the class the harness and a tool it starts run at (`ps -o pri=`).
//! The test fails on purpose so the runner shows the table.
#![cfg(target_os = "macos")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use std::fmt::Write as _;
use std::io::BufRead;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::time::{Duration, Instant};

const PRIO_DARWIN_PROCESS: libc::c_int = 4;
const PRIO_DARWIN_BG: libc::c_int = 0x1000;
const SCRIPT: &str = "import subprocess,sys; p=subprocess.Popen(['/bin/sleep','60']); print(p.pid, flush=True); sys.stdin.read()";

fn python() -> String {
    std::env::var("ACPMUX_TEST_PYTHON").unwrap_or_else(|_| "python3".into())
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

#[derive(Clone, Copy, Debug)]
enum How {
    Normal,
    PreExecBg,
    TaskpolicyBg,
}

/// One harness: (spawn returned ms, up ms, harness pri, tool pri).
fn one(how: How) -> (f64, f64, String, String) {
    let mut cmd = match how {
        How::TaskpolicyBg => {
            let mut c = std::process::Command::new("/usr/sbin/taskpolicy");
            c.args(["-c", "background", "--"]).arg(python());
            c
        }
        _ => std::process::Command::new(python()),
    };
    cmd.args(["-c", SCRIPT])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .process_group(0);
    if matches!(how, How::PreExecBg) {
        // SAFETY: one async-signal-safe syscall in the child.
        unsafe {
            cmd.pre_exec(|| {
                libc::setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG);
                Ok(())
            });
        }
    }
    let t = Instant::now();
    let mut child = cmd.spawn().unwrap();
    let spawned = t.elapsed().as_secs_f64() * 1000.0;
    let mut line = String::new();
    std::io::BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
    let up = t.elapsed().as_secs_f64() * 1000.0;
    let tool: u32 = line.trim().parse().unwrap_or(0);
    let (hp, tp) = (pri(child.id()), pri(tool));
    // SAFETY: the group this probe started.
    unsafe { libc::killpg(child.id() as i32, libc::SIGKILL) };
    let _ = child.wait();
    (spawned, up, hp, tp)
}

async fn wave(tag: &str, n: usize, how: How) -> String {
    let mut set = tokio::task::JoinSet::new();
    for _ in 0..n {
        set.spawn_blocking(move || one(how));
    }
    let (mut sp, mut up, mut pris) = (Vec::new(), Vec::new(), std::collections::BTreeSet::new());
    while let Some(Ok((s, u, hp, tp))) = set.join_next().await {
        sp.push(s);
        up.push(u);
        pris.insert(format!("{hp}/{tp}"));
    }
    let q = |v: &mut Vec<f64>, p: f64| {
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        v[((v.len() - 1) as f64 * p).round() as usize]
    };
    format!(
        "{tag:<12} {how:<13?} n={n:<3} spawn p50={:>6.0} max={:>6.0} | up p50={:>6.0} p90={:>6.0} max={:>6.0} | pri harness/tool {pris:?} load1={:.0}",
        q(&mut sp, 0.5),
        q(&mut sp, 1.0),
        q(&mut up, 0.5),
        q(&mut up, 0.9),
        q(&mut up, 1.0),
        loadavg()
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
async fn host_start_probe_measure() {
    let ncpu: usize = sysctl("hw.ncpu").parse().unwrap_or(8);
    let dir = std::env::temp_dir().join(format!("ahp-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let mut out = format!(
        "\nncpu={ncpu} os={} load1-at-start={:.0}\n",
        sysctl("kern.osproductversion"),
        loadavg()
    );
    let mut say = |line: String| {
        eprintln!("{line}");
        writeln!(out, "{line}").unwrap();
    };
    let all = [How::Normal, How::PreExecBg, How::TaskpolicyBg];
    for how in all {
        say(wave("idle", 25, how).await);
    }
    for (load, cpu, disk) in [("cpu", ncpu * 10, 0), ("cpu+disk", ncpu * 10, 8)] {
        let _cpu = Load::cpu(cpu);
        let _disk = Load::disk(disk, &dir);
        tokio::time::sleep(Duration::from_secs(5)).await;
        for round in 0..3 {
            for how in all {
                say(wave(&format!("{load} r{round}"), 25, how).await);
            }
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
    panic!("PROBE TABLE (ms):{out}");
}
