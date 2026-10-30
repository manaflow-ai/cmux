//! MEASUREMENT PROBE (pa-b1, never merge): where a hook's connection waits
//! under a wave, on this daemon's admission. Not a gate: it prints
//! `PROBE-RESULT` lines and always passes.
//!
//! A served session whose registry lock is held 21 ms of every 25 ms (Austin's
//! day: the lock was held 85 % of the time), and a wave of child processes,
//! each in its own process session like a detached hook child, that connect,
//! write one `identify` and read the reply. Each child reports when its
//! connect returned, how many connects failed first, when its write
//! completed, and when and what the reply was.

use super::*;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

const CHILD: &str = "CMUX_HOOK_WAVE_PROBE_SOCKET";
const PROBE_TEST: &str = "server::tests::hook_wave_probe::hook_wave_probe";
/// Children started per second, and for how long.
const RATE: u64 = 50;
const SECONDS: u64 = 8;
/// The hook child's own deadline (cmux-tui-hook SOCKET_TIMEOUT).
const DEADLINE: Duration = Duration::from_secs(4);

fn now_ms() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64() * 1000.0
}

#[cfg(unix)]
fn child(socket: &Path) {
    let started = now_ms();
    let deadline = Instant::now() + DEADLINE;
    let mut connect_errors = 0_u64;
    let mut last_error = String::new();
    let stream = loop {
        match std::os::unix::net::UnixStream::connect(socket) {
            Ok(stream) => break Some(stream),
            Err(error) => {
                connect_errors += 1;
                last_error = format!("{:?}", error.kind());
                if Instant::now() >= deadline {
                    break None;
                }
                std::thread::yield_now();
            }
        }
    };
    let connected = now_ms();
    let mut written = None;
    let mut replied = None;
    let mut reply_kind = String::from("none");
    if let Some(mut stream) = stream {
        let _ = stream.set_write_timeout(Some(DEADLINE));
        if writeln!(stream, "{}", json!({"id": 1, "cmd": "identify"})).is_ok() {
            written = Some(now_ms());
            let _ = stream.set_read_timeout(Some(Duration::from_secs(15)));
            let mut line = String::new();
            match BufReader::new(stream).read_line(&mut line) {
                Ok(0) => reply_kind = "eof".into(),
                Ok(_) => {
                    replied = Some(now_ms());
                    let value: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
                    reply_kind = if value["type"] == "refused" {
                        "refused".into()
                    } else if value["ok"] == true {
                        "ok".into()
                    } else {
                        "error".into()
                    };
                }
                Err(error) => reply_kind = format!("read-{:?}", error.kind()),
            }
        } else {
            reply_kind = "write-failed".into();
        }
    }
    println!(
        "PROBE-CHILD {}",
        json!({
            "started": started, "connect_ms": connected - started, "connect_errors": connect_errors,
            "last_connect_error": last_error,
            "write_ms": written.map(|t| t - started), "reply_ms": replied.map(|t| t - started),
            "reply": reply_kind,
        })
    );
}

/// The daemon's own `server-stats` connection counts.
fn server_connections(mux: &Arc<Mux>) -> Value {
    let client = mux.control_clients.register(ClientTransport::Unix, test_writer());
    handle_command(mux, client, Command::ServerStats { include: None }, &test_writer())
        .map(|stats| stats["connections"].clone())
        .unwrap_or(Value::Null)
}

fn quantile(values: &mut [f64], q: f64) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(|a, b| a.partial_cmp(b).unwrap());
    Some(values[((values.len() - 1) as f64 * q).round() as usize])
}

#[cfg(unix)]
#[test]
fn hook_wave_probe() {
    if let Some(socket) = std::env::var_os(CHILD) {
        child(Path::new(&socket));
        return;
    }
    use std::os::unix::process::CommandExt;
    let dir = TestSocketDir::create("hook-wave");
    let path = dir.path().join("mux.sock");
    let mux = test_mux();
    let served = serve_paused(mux.clone(), Some(path.clone())).unwrap().mark_ready().unwrap();

    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let throttle = {
        let (mux, stop) = (mux.clone(), stop.clone());
        std::thread::spawn(move || {
            while !stop.load(std::sync::atomic::Ordering::Acquire) {
                let held = mux.workspace_registry.lock().unwrap();
                std::thread::sleep(Duration::from_millis(21));
                drop(held);
                std::thread::sleep(Duration::from_millis(4));
            }
        })
    };

    let exe = std::env::current_exe().unwrap();
    let mut children = Vec::new();
    let begin = Instant::now();
    for index in 0..RATE * SECONDS {
        let due = Duration::from_millis(index * 1000 / RATE);
        if let Some(wait) = due.checked_sub(begin.elapsed()) {
            std::thread::sleep(wait);
        }
        let mut command = Command::new(&exe);
        command
            .args(["--exact", PROBE_TEST, "--nocapture", "--test-threads", "1"])
            .env(CHILD, &path)
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        // Its own process session, as the hook's detached child.
        // SAFETY: setsid is async-signal-safe.
        unsafe {
            command.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
        children.push(command.spawn().unwrap());
    }
    let mut records = Vec::new();
    for child in children {
        let output = child.wait_with_output().unwrap();
        let text = String::from_utf8_lossy(&output.stdout);
        if let Some(record) =
            text.lines().find_map(|line| line.split_once("PROBE-CHILD ").map(|(_, rest)| rest))
        {
            records.push(serde_json::from_str::<Value>(record).unwrap());
        }
    }
    stop.store(true, std::sync::atomic::Ordering::Release);
    throttle.join().unwrap();

    let field = |name: &str| -> Vec<f64> {
        records.iter().filter_map(|record| record[name].as_f64()).collect()
    };
    let mut connect = field("connect_ms");
    let mut write = field("write_ms");
    let mut reply = field("reply_ms");
    let written_late = records
        .iter()
        .filter(|record| record["write_ms"].as_f64().is_none_or(|ms| ms > 4000.0))
        .count();
    let connect_failed =
        records.iter().filter(|record| record["connect_errors"].as_u64() > Some(0)).count();
    let mut kinds = std::collections::BTreeMap::<String, u64>::new();
    for record in &records {
        *kinds.entry(record["reply"].as_str().unwrap_or("?").to_owned()).or_default() += 1;
    }
    let mut errors = std::collections::BTreeMap::<String, u64>::new();
    for record in &records {
        if let Some(error) = record["last_connect_error"].as_str().filter(|e| !e.is_empty()) {
            *errors.entry(error.to_owned()).or_default() += 1;
        }
    }
    println!(
        "PROBE-RESULT {}",
        json!({
            "children": records.len(),
            "write_not_done_within_4s": written_late,
            "children_with_connect_errors": connect_failed,
            "connect_error_kinds": errors,
            "reply_kinds": kinds,
            "connect_ms": {"p50": quantile(&mut connect, 0.5), "p90": quantile(&mut connect, 0.9), "max": quantile(&mut connect, 1.0)},
            "write_ms": {"p50": quantile(&mut write, 0.5), "p90": quantile(&mut write, 0.9), "max": quantile(&mut write, 1.0)},
            "reply_ms": {"p50": quantile(&mut reply, 0.5), "p90": quantile(&mut reply, 0.9), "max": quantile(&mut reply, 1.0)},
            "server": server_connections(&mux),
        })
    );
    cleanup(&served);
}
