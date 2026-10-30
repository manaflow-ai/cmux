//! SCRATCH probe (pa-b10, not for landing): how long a harness spawn takes on a
//! busy Mac by the way its CPU class is set, and whether a class set on a
//! running process is inherited by what it starts later. Prints a table (the
//! test fails on purpose so the runner shows it).
#![cfg(target_os = "macos")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use std::ffi::CString;
use std::fmt::Write as _;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const PRIO_DARWIN_PROCESS: libc::c_int = 4;
const PRIO_DARWIN_BG: libc::c_int = 0x1000;

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

#[derive(Clone, Copy, Debug)]
enum How {
    Normal,
    PreExecBg,
    DemoteAfter,
    ClampUtility,
    ClampBackground,
}

type ClampFn = unsafe extern "C" fn(*mut libc::posix_spawnattr_t, u64) -> libc::c_int;

fn clamp_fn() -> ClampFn {
    // SAFETY: dlsym of a NUL-terminated name.
    let sym =
        unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"posix_spawnattr_set_qos_clamp_np".as_ptr()) };
    assert!(!sym.is_null());
    // SAFETY: that function's signature.
    unsafe { std::mem::transmute::<*mut libc::c_void, ClampFn>(sym) }
}

/// Starts `argv` the way `how` says; returns the pid once the spawn returned.
fn start(how: How, argv: &[String]) -> libc::pid_t {
    match how {
        How::Normal | How::PreExecBg | How::DemoteAfter => {
            let mut cmd = std::process::Command::new(&argv[0]);
            cmd.args(&argv[1..])
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null());
            if matches!(how, How::PreExecBg) {
                // SAFETY: one async-signal-safe syscall in the child.
                unsafe {
                    cmd.pre_exec(|| {
                        libc::setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG);
                        Ok(())
                    });
                }
            }
            let child = cmd.spawn().unwrap();
            let pid = child.id() as libc::pid_t;
            std::mem::forget(child);
            if matches!(how, How::DemoteAfter) {
                // SAFETY: our child.
                unsafe { libc::setpriority(PRIO_DARWIN_PROCESS, pid as _, PRIO_DARWIN_BG) };
            }
            pid
        }
        How::ClampUtility | How::ClampBackground => {
            let clamp = if matches!(how, How::ClampUtility) { 1 } else { 2 };
            let args: Vec<CString> =
                argv.iter().map(|a| CString::new(a.as_str()).unwrap()).collect();
            let mut ptrs: Vec<*mut libc::c_char> =
                args.iter().map(|a| a.as_ptr().cast_mut()).chain([std::ptr::null_mut()]).collect();
            let env: Vec<CString> =
                std::env::vars().map(|(k, v)| CString::new(format!("{k}={v}")).unwrap()).collect();
            let mut envp: Vec<*mut libc::c_char> =
                env.iter().map(|a| a.as_ptr().cast_mut()).chain([std::ptr::null_mut()]).collect();
            // SAFETY: attr initialized and destroyed; vectors NUL-terminated.
            unsafe {
                let mut attr: libc::posix_spawnattr_t = std::ptr::null_mut();
                assert_eq!(libc::posix_spawnattr_init(&mut attr), 0);
                assert_eq!(clamp_fn()(&mut attr, clamp), 0);
                let mut pid = 0;
                let rc = libc::posix_spawn(
                    &mut pid,
                    args[0].as_ptr(),
                    std::ptr::null(),
                    &attr,
                    ptrs.as_mut_ptr(),
                    envp.as_mut_ptr(),
                );
                libc::posix_spawnattr_destroy(&mut attr);
                assert_eq!(rc, 0);
                pid
            }
        }
    }
}

fn reap(pid: libc::pid_t) {
    // SAFETY: our child.
    unsafe {
        libc::kill(pid, libc::SIGKILL);
        let mut status = 0;
        libc::waitpid(pid, &mut status, 0);
    }
}

async fn wave(tag: &str, n: usize, how: How) -> String {
    let argv = vec![python(), FAKE.to_owned()];
    let mut set = tokio::task::JoinSet::new();
    let begin = Instant::now();
    for _ in 0..n {
        let argv = argv.clone();
        set.spawn_blocking(move || {
            let t = Instant::now();
            let pid = start(how, &argv);
            (t.elapsed().as_secs_f64() * 1000.0, pid)
        });
    }
    let mut times = Vec::new();
    let mut pids = Vec::new();
    while let Some(Ok((t, pid))) = set.join_next().await {
        times.push(t);
        pids.push(pid);
    }
    let wall = begin.elapsed().as_secs_f64() * 1000.0;
    for pid in pids {
        reap(pid);
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let q = |p: f64| times[((times.len() - 1) as f64 * p).round() as usize];
    format!(
        "{tag:<28} {how:<16?} n={n:<3} min={:>6.0} p50={:>6.0} p90={:>6.0} max={:>6.0} wall={wall:>6.0} load1={:.0}",
        q(0.0),
        q(0.5),
        q(0.9),
        q(1.0),
        loadavg()
    )
}

/// Whether a process `how` started passes its class on to a child it starts
/// later (after the demotion), as read by that child.
fn inheritance(how: How, dir: &Path) -> String {
    let out = dir.join(format!("inherit-{how:?}"));
    let script = format!(
        "sleep 1; {py} -c 'import ctypes,os; l=ctypes.CDLL(None); open(\"{out}\",\"w\").write(str(l.getpriority(4,0)))'",
        py = python(),
        out = out.display()
    );
    let pid = start(how, &["/bin/sh".into(), "-c".into(), script]);
    // SAFETY: read our child's class now.
    let own = unsafe { libc::getpriority(PRIO_DARWIN_PROCESS, pid as _) };
    let mut status = 0;
    // SAFETY: our child.
    unsafe { libc::waitpid(pid, &mut status, 0) };
    let child = std::fs::read_to_string(&out).unwrap_or_else(|e| format!("({e})"));
    format!("inherit {how:<16?} started-process darwin-bg={own} its-later-child darwin-bg={child}")
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
    let dir: PathBuf = std::env::temp_dir().join(format!("ahp-{}", std::process::id()));
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
    let all =
        [How::Normal, How::PreExecBg, How::DemoteAfter, How::ClampUtility, How::ClampBackground];
    for how in all {
        say(inheritance(how, &dir));
    }
    for how in all {
        say(wave("idle", 25, how).await);
    }
    for (load, cpu, disk) in [("cpu", ncpu * 10, 0), ("cpu+disk", ncpu * 10, 8)] {
        let _cpu = Load::cpu(cpu);
        let _disk = Load::disk(disk, &dir);
        tokio::time::sleep(Duration::from_secs(5)).await;
        for round in 0..2 {
            for how in all {
                say(wave(&format!("{load} r{round}"), 25, how).await);
            }
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
    panic!("PROBE TABLE (ms):{out}");
}
