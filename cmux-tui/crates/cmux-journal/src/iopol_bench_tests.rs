//! R-DURABILITY S2c measurement (lead rule 2026-11-04: a reply the person waits for never waits on
//! a throttled disk sync): what one acknowledged journal append costs, append to durable, with the
//! process's disk I/O policy at its default and at `IOPOL_UTILITY` (acpmux's `qos.rs` sets the
//! daemon process to utility), each light and under disk stress from another process at the
//! default policy (the person's own apps). macOS only: Linux has no process I/O policy here.
//!
//! A measurement, not a test of behavior: it runs only in a fleet step whose key names it
//! (`CMUX_CI_STEP_KEY` contains `iopol-bench`), and elsewhere it prints `IOPOL-BENCH SKIP` and
//! passes (no CI test, CLAUDE.md). Each line is
//! `IOPOL-BENCH <light|stress> <default|utility> round=<k> n=<n> p50=<us> p95=<us> p99=<us>
//! max=<us>`, and a `summary` line per condition and policy over all its rounds. The policies
//! alternate round by round, so a drift of the host hits both.

use std::io::Write;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::{Class, Config, FsStorage, Journal, Storage};

/// Acknowledged appends per round (at most: a round also ends after `ROUND_TIME`), and rounds
/// per condition and policy.
const ACKS: usize = 1500;
const ROUND_TIME: Duration = Duration::from_secs(15);
const ROUNDS: usize = 3;
/// One acknowledged record: about one event-log line.
const PAYLOAD: usize = 512;
/// The stress child's write between two full syncs.
const STRESS_CHUNK: usize = 4 * 1024 * 1024;
/// The environment variable that makes this test binary the stress child.
const STRESS_ENV: &str = "CMUX_JOURNAL_IOPOL_STRESS_DIR";

const IOPOL_TYPE_DISK: libc::c_int = 0;
const IOPOL_SCOPE_PROCESS: libc::c_int = 0;
const IOPOL_DEFAULT: libc::c_int = 0;
const IOPOL_UTILITY: libc::c_int = 4;

unsafe extern "C" {
    fn setiopolicy_np(iotype: libc::c_int, scope: libc::c_int, policy: libc::c_int) -> libc::c_int;
    fn getiopolicy_np(iotype: libc::c_int, scope: libc::c_int) -> libc::c_int;
}

fn enabled() -> bool {
    std::env::var("CMUX_CI_STEP_KEY").is_ok_and(|key| key.contains("iopol-bench"))
}

/// Sets this process's disk I/O policy; panics when the kernel refuses it.
fn set_process_policy(policy: libc::c_int) {
    // SAFETY: a plain syscall wrapper with constant arguments.
    let rc = unsafe { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, policy) };
    assert_eq!(rc, 0, "setiopolicy_np({policy}): {}", std::io::Error::last_os_error());
    // SAFETY: as above.
    let now = unsafe { getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS) };
    // The kernel may read the default back as `IOPOL_IMPORTANT` (1), which is the same tier.
    assert!(now == policy || (policy == IOPOL_DEFAULT && now == 1), "policy {policy} reads {now}");
}

/// Microseconds at p50, p95, p99 and max (nearest rank).
fn percentiles(samples: &mut [Duration]) -> [u128; 4] {
    samples.sort_unstable();
    let last = samples.len().saturating_sub(1);
    let at = |permille: usize| {
        let rank = last.saturating_mul(permille).checked_div(1000).unwrap_or(0);
        samples.get(rank).map_or(0, Duration::as_micros)
    };
    [at(500), at(950), at(990), at(1000)]
}

fn line(what: &str, samples: &mut [Duration]) {
    let n = samples.len();
    let [p50, p95, p99, max] = percentiles(samples);
    println!("IOPOL-BENCH {what} n={n} p50={p50} p95={p95} p99={p99} max={max}");
}

/// One round: a fresh journal, `ACKS` acknowledged appends, each waited for until durable (as a
/// reply waits in the daemon), on the journal's own writer thread.
fn round(dir: &Path) -> Vec<Duration> {
    let storage: Arc<dyn Storage> = Arc::new(FsStorage);
    let (journal, _) = Journal::open(storage, dir, Config::default(), 0, &mut |_| Ok(()))
        .unwrap_or_else(|error| panic!("open: {error}"));
    let payload = vec![0x3Cu8; PAYLOAD];
    let mut samples = Vec::with_capacity(ACKS);
    let began = Instant::now();
    for _ in 0..ACKS {
        if began.elapsed() >= ROUND_TIME {
            break;
        }
        let start = Instant::now();
        let lsn = journal
            .append(1, Class::Ack, &payload)
            .unwrap_or_else(|error| panic!("append: {error}"));
        journal
            .wait_durable(lsn, Duration::from_secs(60))
            .unwrap_or_else(|error| panic!("wait: {error}"));
        samples.push(start.elapsed());
    }
    samples
}

/// The stress child: this test binary again, running [`iopol_stress_child`] at the default
/// policy (a new process starts at it), writing and fully syncing until it is killed.
fn start_stress(dir: &Path) -> Child {
    let exe = std::env::current_exe().unwrap_or_else(|error| panic!("current exe: {error}"));
    Command::new(exe)
        .args(["--exact", "iopol_bench_tests::iopol_stress_child", "--nocapture"])
        .env(STRESS_ENV, dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap_or_else(|error| panic!("start the stress child: {error}"))
}

#[test]
fn iopol_stress_child() {
    let Some(dir) = std::env::var_os(STRESS_ENV).map(PathBuf::from) else { return };
    let path = dir.join("stress.bin");
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&path)
        .unwrap_or_else(|error| panic!("open {}: {error}", path.display()));
    let chunk = vec![0x77u8; STRESS_CHUNK];
    let mut written = 0usize;
    loop {
        file.write_all(&chunk).unwrap_or_else(|error| panic!("write: {error}"));
        // SAFETY: an open descriptor and a constant command.
        let _ = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_FULLFSYNC) };
        written = written.saturating_add(STRESS_CHUNK);
        // Start over at 256 MiB so the file does not fill the disk.
        if written >= 256 * 1024 * 1024 {
            file.set_len(0).unwrap_or_else(|error| panic!("truncate: {error}"));
            file = std::fs::OpenOptions::new()
                .write(true)
                .open(&path)
                .unwrap_or_else(|error| panic!("reopen: {error}"));
            written = 0;
        }
    }
}

#[test]
fn iopol_bench_measures_acked_appends_by_policy() {
    if !enabled() {
        println!("IOPOL-BENCH SKIP (runs in a fleet step whose key contains iopol-bench)");
        return;
    }
    // In the step's checkout: the disk the daemons use on this host, not a tmpfs.
    let root = std::env::current_dir()
        .unwrap_or_else(|error| panic!("current dir: {error}"))
        .join("target")
        .join("iopol-bench");
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap_or_else(|error| panic!("mkdir: {error}"));
    let version = Command::new("sw_vers")
        .arg("-productVersion")
        .output()
        .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_owned())
        .unwrap_or_default();
    println!("IOPOL-BENCH host os=macos version={version} root={}", root.display());
    let policies = [("default", IOPOL_DEFAULT), ("utility", IOPOL_UTILITY)];
    for condition in ["light", "stress"] {
        let mut child = (condition == "stress").then(|| {
            let child = start_stress(&root);
            // Let the stress reach a steady state.
            std::thread::sleep(Duration::from_secs(3));
            child
        });
        let mut all: Vec<Vec<Duration>> = vec![Vec::new(); policies.len()];
        for k in 0..ROUNDS {
            for (index, (name, policy)) in policies.iter().enumerate() {
                set_process_policy(*policy);
                let dir = root.join(format!("journal-{condition}-{name}-{k}"));
                let mut samples = round(&dir);
                let _ = std::fs::remove_dir_all(&dir);
                if let Some(pooled) = all.get_mut(index) {
                    pooled.extend_from_slice(&samples);
                }
                line(&format!("{condition} {name} round={k}"), &mut samples);
            }
        }
        set_process_policy(IOPOL_DEFAULT);
        for (index, (name, _)) in policies.iter().enumerate() {
            if let Some(pooled) = all.get_mut(index) {
                line(&format!("summary {condition} {name}"), pooled);
            }
        }
        if let Some(child) = child.as_mut() {
            // The child this test started.
            let _ = child.kill();
            let _ = child.wait();
        }
    }
    let _ = std::fs::remove_dir_all(&root);
}
