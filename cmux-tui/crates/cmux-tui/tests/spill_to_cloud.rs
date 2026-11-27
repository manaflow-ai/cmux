//! `cmux spill` to the signed-in person's cmux Cloud machine: with no ROUTE (when this machine
//! is over budget) or `--to cloud`, the CLI reads the app's Cloud machines and a credential
//! from the app socket, dials its own carrier session to the machine (ticket and grant from the
//! platform, the relay, the pinned daemon key) and runs the command there with `remote exec`'s
//! protocol: output streams back and the exit status is the command's. Without a Cloud machine
//! or an app it runs here and names the one step that would let it spill.
//!
//! Stand-ins, all on loopback: a fake app socket (`CMUX_SOCKET_PATH`) answering
//! `cloud.machines` and `auth.token`, and `carrier_support`'s world (a fake platform carrier
//! route, a real cmux-relay, a real daemon serving workspaces behind it, owner grants for
//! `mux-control,workspace-rpc,process-stream` as cmux-platform signs them). No network, no
//! account.
#![cfg(target_os = "linux")]

mod carrier_support;

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Duration;

use carrier_support::*;
use serde_json::{Value, json};

/// Prints stdout and stderr lines and exits 7: what comes back must be the command's own.
const COMMAND: &str = "echo spilled-out; echo spilled-err >&2; exit 7";
const OWNER_SERVICES: &str = "mux-control,workspace-rpc,process-stream";

/// A fake app on `socket`: `machines` as its Cloud machines, a credential for the world's
/// platform. Serves until `done`.
fn fake_app(socket: &Path, machines: Value, platform: String, done: Arc<AtomicBool>) {
    let listener = UnixListener::bind(socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    std::thread::spawn(move || {
        while !done.load(Ordering::Relaxed) {
            let Ok((stream, _)) = listener.accept() else {
                std::thread::sleep(Duration::from_millis(10));
                continue;
            };
            stream.set_nonblocking(false).unwrap();
            let machines = machines.clone();
            let platform = platform.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut writer = stream;
                let mut line = String::new();
                while reader.read_line(&mut line).unwrap_or(0) > 0 {
                    let request: Value = serde_json::from_str(&line).unwrap();
                    line.clear();
                    let response = if request["cmd"] == "set-client-info" {
                        json!({"id": request["id"], "ok": true, "data": {}})
                    } else {
                        let result = match request["method"].as_str() {
                            Some("cloud.machines") => {
                                json!({"machines": machines, "creations": []})
                            }
                            Some("auth.token") => json!({"access_token": TOKEN, "team": TEAM,
                                                         "api_origin": platform}),
                            _ => json!({"pong": true}),
                        };
                        json!({"id": request["id"], "ok": true, "result": result})
                    };
                    if writeln!(writer, "{response}").is_err() {
                        break;
                    }
                }
            });
        }
    });
}

fn running_machine() -> Value {
    json!([{"id": MACHINE, "title": "spill-box", "team": TEAM, "status": "running",
            "daemon": "connected"}])
}

/// A fake `nproc` and `cat` for the room probe (the world's daemon inherits this PATH).
fn fake_probe_tools(dir: &Path) -> PathBuf {
    let bin = dir.join("fake-bin");
    let proc_dir = bin.join("proc");
    fs::create_dir_all(&proc_dir).unwrap();
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
    fs::write(proc_dir.join("nproc"), "64\n").unwrap();
    fs::write(proc_dir.join("loadavg"), "0.50 1.00 1.00 1/100 42\n").unwrap();
    fs::write(proc_dir.join("meminfo"), "MemTotal: 1000000 kB\nMemAvailable: 500000 kB\n").unwrap();
    fs::write(proc_dir.join("memory"), "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n").unwrap();
    bin
}

/// This machine's budget file: `over` asks for all RAM free (never true), else nothing binds.
fn here_budget(dir: &Path, over: bool) -> PathBuf {
    let path = dir.join(if over { "budget-over.json" } else { "budget-within.json" });
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

fn spill(dir: &Path, app: &Path, budget: &Path, route: &[&str]) -> Run {
    let mut command = Command::new(BIN);
    command.arg("spill").args(route).args(["--timings", "--", "sh", "-c", COMMAND]);
    for key in ["CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET", "CMUX_BUNDLE_ID", "CMUX_TAG"] {
        command.env_remove(key);
    }
    for key in ["CMUX_AGENT_SESSION", "CMUX_CLOUD_API_URL", "CMUX_CLOUD_ACCESS_TOKEN"] {
        command.env_remove(key);
    }
    let output = command
        .env("HOME", dir)
        .env("XDG_STATE_HOME", dir.join("xdg"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_SOCKET_PATH", app)
        .env("ACPMUX_HOST_BUDGET", budget)
        .stdin(Stdio::null())
        .output()
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

fn assert_spilled(run: &Run, reason: &str) {
    assert_eq!(run.code, 7, "stderr:\n{}", run.stderr);
    assert_eq!(run.stdout, "spilled-out\n");
    assert!(run.stderr.contains("spilled-err\n"), "{}", run.stderr);
    let first = run.stderr.lines().next().unwrap_or("");
    assert!(
        first.starts_with("cmux spill: running on Cloud machine spill-box: "),
        "{}",
        run.stderr
    );
    assert_eq!(run.timings["placement"]["at"], "there", "{}", run.timings);
    assert_eq!(run.timings["reason"]["code"], reason, "{}", run.timings);
    assert_eq!(run.timings["exit"], 7);
    let start = run.timings["spill_start_ms"].as_u64().expect("spill_start_ms");
    assert!(start <= run.timings["total_ms"].as_u64().unwrap());
    eprintln!("--- stderr\n{}---\nspill_start_ms={start}", run.stderr);
}

fn assert_kept_here_naming(run: &Run, step: &str) {
    assert_eq!(run.code, 7, "stderr:\n{}", run.stderr);
    assert_eq!(run.stdout, "spilled-out\n");
    let first = run.stderr.lines().next().unwrap_or("");
    assert!(first.starts_with("cmux spill: running here: "), "{}", run.stderr);
    assert!(first.ends_with(step), "{}", run.stderr);
    assert_eq!(run.timings["placement"]["at"], "here", "{}", run.timings);
    assert_eq!(run.timings["place_error"], step, "{}", run.timings);
    assert!(run.timings["spill_start_ms"].is_null());
}

/// One test: the fake probe tools go on this process's PATH, which the world's daemon inherits.
#[test]
fn spill_runs_on_the_signed_in_persons_cloud_machine_or_says_the_step() {
    let dir = tempfile::tempdir_in("/tmp").unwrap();
    let bin = fake_probe_tools(dir.path());
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());
    // SAFETY: the only test in this binary, set before the world's daemon or any thread starts.
    unsafe { std::env::set_var("PATH", path) };
    let asked = Arc::new(AtomicUsize::new(0));
    let world = world_granting(200, asked.clone(), OWNER_SERVICES);
    let platform = format!("http://{}", world.platform);
    let over = here_budget(dir.path(), true);
    let within = here_budget(dir.path(), false);
    let done = Arc::new(AtomicBool::new(false));
    let app = dir.path().join("app.sock");
    fake_app(&app, running_machine(), platform.clone(), done.clone());

    // `--to cloud` within budget: forced there.
    let run = spill(dir.path(), &app, &within, &["--to", "cloud"]);
    assert_spilled(&run, "asked_there");
    assert!(asked.load(Ordering::SeqCst) >= 1, "the platform was never asked for a ticket");

    // No ROUTE, over budget, the Cloud machine has room: spilled there on its own.
    let run = spill(dir.path(), &app, &over, &[]);
    assert_spilled(&run, "over_budget");
    assert!(run.timings["phases"]["probe"].is_u64(), "{}", run.timings);

    // No ROUTE within budget: here, nothing dialed, nothing said.
    let before = asked.load(Ordering::SeqCst);
    let run = spill(dir.path(), &app, &within, &[]);
    assert_eq!(run.code, 7);
    assert_eq!(run.timings["placement"]["at"], "here");
    assert_eq!(asked.load(Ordering::SeqCst), before);

    // Signed in, no Cloud machine: here, naming the step.
    let empty = dir.path().join("empty.sock");
    fake_app(&empty, json!([]), platform.clone(), done.clone());
    let run = spill(dir.path(), &empty, &over, &[]);
    assert_kept_here_naming(&run, "make a Cloud machine: cmux vm new");
    let run = spill(dir.path(), &empty, &within, &["--to", "cloud"]);
    assert_kept_here_naming(&run, "make a Cloud machine: cmux vm new");

    // A paused one: here, naming the resume.
    let paused = dir.path().join("paused.sock");
    let asleep = json!([{"id": MACHINE, "title": "spill-box", "team": TEAM, "status": "paused"}]);
    fake_app(&paused, asleep, platform, done.clone());
    let run = spill(dir.path(), &paused, &over, &[]);
    assert_kept_here_naming(&run, &format!("start your Cloud machine: cmux vm resume {MACHINE}"));

    // No app answers: here, naming the step.
    let run = spill(dir.path(), &dir.path().join("no-app.sock"), &over, &[]);
    assert_kept_here_naming(&run, "open the cmux app and sign in");
    done.store(true, Ordering::Relaxed);
}
