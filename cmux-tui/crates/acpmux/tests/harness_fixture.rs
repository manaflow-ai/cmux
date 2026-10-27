//! The capture fixture (`ACPMUX_HARNESS_FIXTURE`, src/harness_fixture.rs)
//! through the real daemon binary: `_acpmux/harnesses` lists the fixture's
//! harnesses, `_acpmux/harness/health` serves its rows as every check (a
//! refresh and a newest-version check included), an update is refused, the
//! fixture harness never starts (its command writes a marker first), and no
//! health copy is saved. A fixture file that cannot be read stops the start.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The fixture harness's command is a stand-in that only writes a marker.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-fx{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn daemon(dir: &Path, fixture: &Path) -> std::process::Command {
    let mut cmd = daemon_env::command(dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(["daemon", "run", "--ready-fd", "1", "--log", "warn", "--memory"])
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .env("ACPMUX_HARNESS_FIXTURE", fixture)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null());
    cmd
}

async fn call(
    lines: &mut tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: &mut tokio::net::unix::OwnedWriteHalf,
    id: i64,
    method: &str,
    params: Value,
) -> Value {
    let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
    wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(60), lines.next_line())
            .await
            .expect("daemon answered in time")
            .unwrap()
            .expect("daemon closed the socket");
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(id)) {
            return v;
        }
    }
}

#[tokio::test]
async fn the_daemon_serves_a_fixture_and_reads_nothing_live() {
    let dir = scratch("on");
    let marker = dir.join("harness-started");
    let argv = json!(["/bin/sh", "-c", "echo started >>\"$1\"", "sh", marker]);
    let row = json!({
        "id": "codex", "program": "codex-acp", "path": "/opt/fixture/bin/codex-acp",
        "channel": "npm", "package": "@zed-industries/codex-acp",
        "version": "0.9.0", "latest": "0.10.0", "latestCheckedAt": 1, "outdated": true,
        "auth": "signedIn", "authDetail": null, "login": "codex login",
        "update": {"argv": ["/bin/sh", "-c", "echo updated >>\"$0\"", marker],
                   "command": "npm install -g @zed-industries/codex-acp@latest", "elevated": false},
        "problem": null, "checkedAt": 1, "autoUpdate": false, "lastAutoUpdate": null
    });
    let fixture = dir.join("fixture.json");
    std::fs::write(
        &fixture,
        json!({"harnesses": {"codex": {"argv": argv, "description": "found on PATH"}}, "health": [row]})
            .to_string(),
    )
    .unwrap();
    let mut child = daemon(&dir, &fixture).spawn().unwrap();
    let stdout = child.stdout.take().unwrap();
    let ready = tokio::task::spawn_blocking(move || {
        BufReader::new(stdout)
            .lines()
            .map_while(Result::ok)
            .any(|line| serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true))
    });
    assert!(tokio::time::timeout(Duration::from_secs(20), ready).await.unwrap().unwrap());

    let stream = tokio::net::UnixStream::connect(dir.join("s.sock")).await.unwrap();
    let (rd, mut wr) = stream.into_split();
    let mut lines = tokio::io::BufReader::new(rd).lines();
    let harnesses = call(&mut lines, &mut wr, 1, "_acpmux/harnesses", json!({})).await;
    let ids: Vec<&String> =
        harnesses["result"]["harnesses"].as_object().expect("harnesses").keys().collect();
    assert_eq!(ids, ["codex"], "{harnesses}");
    for (n, params) in
        [json!({}), json!({"refresh": true}), json!({"checkLatest": true, "rescan": true})]
            .into_iter()
            .enumerate()
    {
        let health =
            call(&mut lines, &mut wr, 2 + n as i64, "_acpmux/harness/health", params).await;
        assert_eq!(health["result"]["harnesses"], json!([row]), "{health}");
    }
    let update =
        call(&mut lines, &mut wr, 9, "_acpmux/harness/update", json!({"ids": ["codex"]})).await;
    assert_eq!(update["result"]["results"][0]["ok"], false, "{update}");
    // A model refresh waits for every probe; a probe would start the harness.
    call(&mut lines, &mut wr, 10, "_acpmux/models", json!({"refresh": true})).await;
    let registry = call(&mut lines, &mut wr, 11, "_acpmux/registry", json!({})).await;
    assert!(registry.get("error").is_some(), "{registry}");
    assert!(!marker.exists(), "the fixture harness ran: {:?}", std::fs::read_to_string(&marker));
    assert!(!dir.join("harness-health.json").exists(), "a fixture's health was saved");

    unsafe {
        libc::kill(child.id() as i32, libc::SIGTERM);
    }
    let stop = Instant::now();
    while child.try_wait().unwrap().is_none() {
        assert!(stop.elapsed() < Duration::from_secs(8), "daemon still running after SIGTERM");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// A set variable whose file is missing, or that is empty, stops the start: no ready line.
#[test]
fn an_unreadable_fixture_stops_the_daemon() {
    let dir = scratch("bad");
    for fixture in [dir.join("missing.json"), PathBuf::new()] {
        let out = daemon(&dir, &fixture).output().unwrap();
        assert!(!out.status.success(), "{fixture:?}");
        assert!(!String::from_utf8_lossy(&out.stdout).contains("\"ready\""), "{fixture:?}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}
