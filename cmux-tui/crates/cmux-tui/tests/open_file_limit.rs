//! A terminal owner started with a small open-file soft limit (256, the macOS
//! default) runs hundreds of terminals, and the programs in those terminals
//! still see the limit the owner was started with.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use std::os::unix::net::UnixStream;

const SOFT_LIMIT: libc::rlim_t = 256;
const TERMINALS: usize = 300;
const CREATORS: usize = 8;

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    fn start_with_soft_limit(soft: libc::rlim_t) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!("cmux-nofile-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        // SAFETY: getrlimit/setrlimit are async-signal-safe and only change
        // the daemon child's own soft limit (never above its hard limit).
        unsafe {
            command.pre_exec(move || {
                let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
                if libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut limit) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                limit.rlim_cur = soft.min(limit.rlim_max);
                if libc::setrlimit(libc::RLIMIT_NOFILE, &raw const limit) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = command.spawn().unwrap();
        let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
        while UnixStream::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, dir }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // End every terminal through the owner; never signal a host.
        if let Some(identify) = try_request(&self.socket, &serde_json::json!({"cmd": "identify"})) {
            let _ = try_request_with_timeout(
                &self.socket,
                &serde_json::json!({
                    "cmd": "shutdown-daemon",
                    "pid": identify["data"]["pid"],
                    "generation": identify["data"]["generation"],
                    "end_terminals": true,
                }),
                Duration::from_secs(300),
            );
        }
        let deadline = Instant::now() + Duration::from_secs(120);
        while self.child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn try_request_with_timeout(
    path: &Path,
    value: &serde_json::Value,
    timeout: Duration,
) -> Option<serde_json::Value> {
    let stream = UnixStream::connect(path).ok()?;
    stream.set_read_timeout(Some(timeout)).ok()?;
    let mut writer = stream.try_clone().ok()?;
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").ok()?;
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}

fn try_request(path: &Path, value: &serde_json::Value) -> Option<serde_json::Value> {
    try_request_with_timeout(path, value, test_timeout(Duration::from_secs(60)))
}

fn request(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let response = try_request(path, &value).unwrap_or_else(|| panic!("{value}: no response"));
    assert_eq!(response["ok"], true, "{value} failed: {response}");
    response["data"].clone()
}

#[test]
fn cmux_next_owner_runs_300_terminals_with_a_256_open_file_soft_limit() {
    let daemon = Daemon::start_with_soft_limit(SOFT_LIMIT);
    request(&daemon.socket, serde_json::json!({"cmd": "new-workspace", "name": "nofile"}));
    let tree = request(&daemon.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let key = tree["workspaces"]
        .as_array()
        .and_then(|workspaces| workspaces.last())
        .and_then(|workspace| workspace["key"].as_str())
        .expect("workspace key")
        .to_owned();

    // One terminal reports the limit its program sees.
    let probe = daemon.dir.join("probe-limit");
    let script = format!("ulimit -n > '{}'; exec cat", probe.display());
    request(
        &daemon.socket,
        serde_json::json!({"cmd": "create-terminal", "key": key, "argv": ["/bin/sh", "-c", script]}),
    );

    let next = Arc::new(AtomicUsize::new(1));
    let creators = (0..CREATORS)
        .map(|_| {
            let socket = daemon.socket.clone();
            let key = key.clone();
            let next = next.clone();
            std::thread::spawn(move || {
                loop {
                    let index = next.fetch_add(1, Ordering::Relaxed);
                    if index >= TERMINALS {
                        return Ok(());
                    }
                    let value = serde_json::json!({
                        "cmd": "create-terminal", "key": key, "argv": ["/bin/sh"],
                    });
                    match try_request(&socket, &value) {
                        Some(response) if response["ok"] == true => {}
                        other => return Err(format!("terminal {index}: {other:?}")),
                    }
                }
            })
        })
        .collect::<Vec<_>>();
    for creator in creators {
        creator.join().unwrap().unwrap();
    }

    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    let seen = loop {
        if let Ok(text) = fs::read_to_string(&probe)
            && !text.trim().is_empty()
        {
            break text.trim().to_owned();
        }
        assert!(Instant::now() < deadline, "probe terminal never wrote {}", probe.display());
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(seen, SOFT_LIMIT.to_string(), "a terminal program must see the original limit");

    let tree = request(&daemon.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let tabs = tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|workspace| workspace["key"] == key)
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .map(|pane| pane["tabs"].as_array().map_or(0, Vec::len))
        .sum::<usize>();
    assert!(tabs > TERMINALS, "expected more than {TERMINALS} tabs, found {tabs}");
}
