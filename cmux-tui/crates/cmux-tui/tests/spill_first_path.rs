//! `cmux spill`, the first automatic spill path (cmuxterm-hq RFD 0032 "Place"): a command
//! started while this machine is over its budget runs on another machine, its output streams
//! back and its exit status is the command's.
//!
//! The CLI under test is "here"; in-process trusted-carrier daemons on loopback stand in for
//! the machines it may spill to. This machine's budget is forced by the meter's own override
//! file (`ACPMUX_HOST_BUDGET`), and the far machine's room by a fake `nproc` and `cat` first on
//! the daemons' PATH, which the room probe runs. No network, no account.
#![cfg(target_os = "linux")]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use cmux_remote::daemon::{
    DirectWebSocketOptions, DirectWebSocketServer, RemoteDaemon,
    serve_direct_websocket_with_options,
};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use serde_json::Value;
use tokio::process::Command;
use tokio::task::LocalSet;

const RUN_TIMEOUT: Duration = Duration::from_secs(60);

/// Prints stdout and stderr lines and exits 7: what comes back must be the command's own.
const COMMAND: &str = "echo spilled-out; echo spilled-err >&2; exit 7";

/// A trusted-carrier daemon serving one client: one machine to spill to.
async fn start_daemon(state: &Path, name: &str) -> (String, DirectWebSocketServer) {
    let auth = AuthDatabase::load_or_create(state.join(name), name, true).unwrap();
    let (daemon, mut accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let websocket = serve_direct_websocket_with_options(
        daemon,
        "127.0.0.1:0".parse().unwrap(),
        65_535,
        DirectWebSocketOptions { trusted_carrier: true, ..Default::default() },
    )
    .await
    .unwrap();
    let endpoint = format!("ws://{}/v1/link", websocket.local_addr());
    let services = DaemonServices::new(WorkspaceService::new(), None);
    tokio::task::spawn_local(async move {
        let connection = accepted.recv().await.expect("daemon stopped accepting");
        services.serve_client(connection).await
    });
    (endpoint, websocket)
}

/// A fake `nproc` and `cat` for the room probe; `cat` of a `/proc` file prints the readings in
/// `fake/proc`, anything else is the real `cat`.
fn fake_probe_tools(fixture: &Path) -> std::path::PathBuf {
    let bin = fixture.join("fake-bin");
    fs::create_dir_all(bin.join("proc")).unwrap();
    let proc_dir = bin.join("proc");
    let write = |name: &str, body: String| {
        let path = bin.join(name);
        fs::write(&path, body).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    };
    write("nproc", format!("#!/bin/sh\nexec /bin/cat {}/nproc\n", proc_dir.display()));
    write(
        "cat",
        format!(
            "#!/bin/sh\ncase \"$1\" in /proc/*) exec /bin/cat {}/\"$(basename \"$1\")\";; esac\n\
             exec /bin/cat \"$@\"\n",
            proc_dir.display()
        ),
    );
    bin
}

/// The far machine's readings: `load1` on `cpus` cores, half its RAM free, no pressure.
fn set_far_room(bin: &Path, cpus: u32, load1: f64) {
    let proc_dir = bin.join("proc");
    fs::write(proc_dir.join("nproc"), format!("{cpus}\n")).unwrap();
    fs::write(proc_dir.join("loadavg"), format!("{load1:.2} 1.00 1.00 1/100 42\n")).unwrap();
    fs::write(proc_dir.join("meminfo"), "MemTotal: 1000000 kB\nMemAvailable: 500000 kB\n").unwrap();
    fs::write(proc_dir.join("memory"), "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n").unwrap();
}

/// This machine's budget file: `over` asks for all RAM free (never true), else nothing binds.
fn here_budget(fixture: &Path, over: bool) -> std::path::PathBuf {
    let path = fixture.join(if over { "budget-over.json" } else { "budget-within.json" });
    let formula = if over {
        r#"{"formula":{"min_available_ram_fraction":1.0}}"#
    } else {
        r#"{"formula":{"load1_per_core":1000000,"psi_some_avg10":1000,"min_available_ram_fraction":0,"swap_growth_mb_per_min":1000000000}}"#
    };
    fs::write(&path, formula).unwrap();
    path
}

struct Run {
    code: i32,
    stdout: String,
    stderr: String,
    timings: Value,
}

async fn spill(fixture: &Path, client: &str, endpoint: &str, budget: &Path) -> Run {
    let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["spill", endpoint, "--carrier", "--lanes", "single", "--state-dir"])
        .arg(fixture.join(client))
        .arg("--local-socket")
        .arg(fixture.join(format!("{client}.sock")))
        .args(["--timings", "--", "sh", "-c", COMMAND])
        .env("HOME", fixture)
        .env("XDG_STATE_HOME", fixture.join("xdg"))
        .env("CMUX_TUI_CONFIG", fixture.join("config.json"))
        .env("ACPMUX_HOST_BUDGET", budget)
        .env("PATH", "/usr/local/bin:/usr/bin:/bin")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let output = tokio::time::timeout(RUN_TIMEOUT, child.wait_with_output())
        .await
        .expect("cmux spill did not end")
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let timings = stderr
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .find(|value| value.get("spill_start_ms").is_some())
        .unwrap_or_else(|| panic!("no --timings line in stderr:\n{stderr}"));
    Run { code: output.status.code().unwrap_or(-1), stdout, stderr, timings }
}

/// One test: the fake tools live on this process's PATH, which the daemons' commands inherit.
#[tokio::test(flavor = "current_thread")]
async fn an_over_budget_command_spills_streams_back_and_keeps_its_exit_code() {
    let fixture = tempfile::tempdir_in("/tmp").unwrap();
    let bin = fake_probe_tools(fixture.path());
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());
    // SAFETY: the only test in this binary, set before any daemon or thread starts.
    unsafe { std::env::set_var("PATH", path) };
    let over = here_budget(fixture.path(), true);
    let within = here_budget(fixture.path(), false);
    LocalSet::new()
        .run_until(async {
            // Over budget, the far machine has room: spilled.
            set_far_room(&bin, 64, 0.5);
            let (endpoint, _first) = start_daemon(fixture.path(), "far-a").await;
            let run = spill(fixture.path(), "client-a", &endpoint, &over).await;
            assert_eq!(run.code, 7, "stderr:\n{}", run.stderr);
            assert_eq!(run.stdout, "spilled-out\n");
            assert!(run.stderr.contains("spilled-err\n"), "{}", run.stderr);
            let line = format!("cmux spill: running on {endpoint}: this machine is over budget");
            assert!(run.stderr.lines().next().unwrap_or("").starts_with(&line), "{}", run.stderr);
            assert_eq!(run.timings["placement"]["at"], "there", "{}", run.timings);
            assert_eq!(run.timings["reason"]["code"], "over_budget");
            assert_eq!(run.timings["exit"], 7);
            let start = run.timings["spill_start_ms"].as_u64().expect("spill_start_ms");
            assert!(start <= run.timings["total_ms"].as_u64().unwrap());
            eprintln!("--- stdout\n{}--- stderr\n{}---", run.stdout, run.stderr);
            eprintln!("spill_start_ms={start}");
            // `SPILL_BENCH_RUNS=N` repeats the spill N times on fresh daemons and prints
            // spill_start_ms' p50 and p95 (unset in CI: one run).
            let runs: usize =
                std::env::var("SPILL_BENCH_RUNS").ok().and_then(|n| n.parse().ok()).unwrap_or(0);
            if runs > 0 {
                let mut starts = Vec::new();
                for index in 0..runs {
                    let (endpoint, _daemon) =
                        start_daemon(fixture.path(), &format!("bench-{index}")).await;
                    let client = format!("bench-client-{index}");
                    let run = spill(fixture.path(), &client, &endpoint, &over).await;
                    assert_eq!(run.code, 7, "{}", run.stderr);
                    starts.push(run.timings["spill_start_ms"].as_u64().unwrap());
                }
                starts.sort_unstable();
                let at = |q: f64| starts[((starts.len() as f64 * q).ceil() as usize).max(1) - 1];
                eprintln!(
                    "spill_start_ms n={} p50={} p95={} max={} all={starts:?}",
                    starts.len(),
                    at(0.50),
                    at(0.95),
                    starts[starts.len() - 1]
                );
            }

            // Over budget, the far machine is over its own: kept here, and said so.
            set_far_room(&bin, 1, 50.0);
            let (endpoint, _second) = start_daemon(fixture.path(), "far-b").await;
            let run = spill(fixture.path(), "client-b", &endpoint, &over).await;
            assert_eq!(run.code, 7, "stderr:\n{}", run.stderr);
            assert_eq!(run.stdout, "spilled-out\n");
            assert!(run.stderr.starts_with("cmux spill: running here: "), "{}", run.stderr);
            assert!(run.stderr.contains("no other machine has room"), "{}", run.stderr);
            assert_eq!(run.timings["placement"]["at"], "here");
            assert_eq!(run.timings["reason"]["code"], "no_room");
            assert!(run.timings["spill_start_ms"].is_null());

            // Within budget: here, silently, and the far machine is never dialed.
            let run = spill(fixture.path(), "client-c", "ws://127.0.0.1:9/v1/link", &within).await;
            assert_eq!(run.code, 7, "stderr:\n{}", run.stderr);
            assert_eq!(run.stdout, "spilled-out\n");
            assert!(!run.stderr.contains("cmux spill:"), "{}", run.stderr);
            assert_eq!(run.timings["reason"]["code"], "within_budget");
            assert!(run.timings["phases"].get("connect").is_none());
        })
        .await;
}
