//! `cmux hosts check` through the CLI entry against 1, 10, 50 and 200
//! declared hosts: a third answer with an ssh greeting on a local port, a third
//! refuse the connection, and a third are a non-routable address that never
//! answers. The pass's wall time stays within its timeout at every count
//! (run with `--nocapture` for the numbers the PR quotes).
#![cfg(unix)]

use std::io::Write as _;
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// A local server that writes an ssh greeting to each connection.
fn ssh_server() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("addr").port();
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let _ = stream.write_all(b"SSH-2.0-OpenSSH_9.9\r\n");
        }
    });
    port
}

fn closed_port() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    listener.local_addr().expect("addr").port()
}

fn scratch(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = std::env::temp_dir()
        .join(format!("cmux-hosts-check-{name}-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(dir.join("home")).unwrap();
    dir
}

fn check(count: usize, timeout_secs: f64) -> (Value, Duration) {
    let dir = scratch(&count.to_string());
    let (open, closed) = (ssh_server(), closed_port());
    let hosts: Vec<Value> = (0..count)
        .map(|i| {
            let endpoint = match i % 3 {
                0 => format!("ssh://127.0.0.1:{open}"),
                1 => format!("ssh://127.0.0.1:{closed}"),
                _ => "ssh://10.255.255.1:22".to_owned(),
            };
            json!({ "label": format!("h{i}"), "endpoints": [endpoint] })
        })
        .collect();
    let config = dir.join("cmux-next.json");
    std::fs::write(&config, json!({ "machines": { "hosts": hosts } }).to_string()).unwrap();
    let started = Instant::now();
    let out = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--json", "hosts", "check", "--timeout", &timeout_secs.to_string()])
        .env("HOME", dir.join("home"))
        .env("CMUX_NEXT_CONFIG_FILE", &config)
        .output()
        .expect("run cmux hosts check");
    let wall = started.elapsed();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let reply: Value = serde_json::from_slice(&out.stdout).expect("json");
    (reply, wall)
}

#[test]
fn the_check_holds_its_timeout_at_1_10_50_and_200_hosts() {
    for count in [1usize, 10, 50, 200] {
        let (reply, wall) = check(count, 3.0);
        let hosts = reply["hosts"].as_array().expect("hosts");
        assert_eq!(hosts.len(), count, "{reply}");
        let tally = |status: &str| hosts.iter().filter(|h| h["status"] == status).count();
        println!(
            "hosts-check-wall hosts={count} wall_ms={} pass_ms={} reachable={} unreachable={}",
            wall.as_millis(),
            reply["wallMs"],
            tally("reachable"),
            tally("unreachable"),
        );
        assert_eq!(hosts[0]["status"], "reachable", "{reply}");
        assert!(wall < Duration::from_millis(4500), "{count} hosts took {wall:?}");
    }
}

#[test]
fn a_short_timeout_ends_the_pass_early_at_200_hosts() {
    let (reply, wall) = check(200, 0.5);
    println!("hosts-check-wall hosts=200 timeout=0.5s wall_ms={}", wall.as_millis());
    assert_eq!(reply["hosts"].as_array().map(Vec::len), Some(200));
    assert!(wall < Duration::from_millis(2000), "took {wall:?}");
}
