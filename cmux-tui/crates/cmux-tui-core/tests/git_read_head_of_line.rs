#![cfg(unix)]
//! A git read does not hold its connection (perf-lead.md rule D1: no child
//! process on a request path). `git.diff` runs git as a child process, which
//! takes seconds in a large repository on a loaded Mac. While git runs, the
//! requests the same connection sends after it (a liveness `ping`, a list, a
//! key) are still read and answered.
//!
//! The git here is a stand-in on `PATH` that waits at a gate the test holds,
//! then runs the real git: a reply that arrives while the gate is held was
//! given while git ran. No sleep decides the result.

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

/// The real git, as an absolute path, before the stand-in goes on `PATH`.
fn real_git() -> PathBuf {
    let path = std::env::var_os("PATH").expect("PATH is set");
    std::env::split_paths(&path)
        .map(|dir| dir.join("git"))
        .find(|candidate| candidate.is_file())
        .expect("git is on PATH")
}

fn git(real: &Path, repo: &Path, arguments: &[&str]) {
    let status = Command::new(real)
        .arg("-C")
        .arg(repo)
        .args(["-c", "maintenance.auto=false", "-c", "user.name=t", "-c", "user.email=t@e.test"])
        .args(arguments)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .status()
        .unwrap();
    assert!(status.success(), "git {arguments:?} failed");
}

/// A `git` that, while `hold` exists beside it, says so in `held` and waits
/// (15 s at most, under the daemon's own 20 s limit for one git run), then
/// runs the real git with the same arguments.
fn install_gated_git(dir: &Path, real: &Path) {
    let script = format!(
        "#!/bin/sh\n\
         dir=$(dirname \"$0\")\n\
         if [ -e \"$dir/hold\" ]; then\n\
         \x20 : > \"$dir/held\"\n\
         \x20 n=0\n\
         \x20 while [ -e \"$dir/hold\" ] && [ \"$n\" -lt 300 ]; do sleep 0.05; n=$((n+1)); done\n\
         fi\n\
         exec \"{}\" \"$@\"\n",
        real.display()
    );
    let shim = dir.join("git");
    std::fs::write(&shim, script).unwrap();
    std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut path = dir.as_os_str().to_owned();
    if let Some(old) = std::env::var_os("PATH") {
        path.push(":");
        path.push(old);
    }
    // This file has one test, so no other thread reads the environment now.
    unsafe { std::env::set_var("PATH", path) };
}

/// The reply with `id` among the lines the connection sends until `deadline`;
/// `None` when it did not come by then. Other replies go to `seen`.
fn reply_by(
    reader: &mut BufReader<UnixStream>,
    id: &Value,
    seen: &mut Vec<Value>,
    deadline: Instant,
) -> Option<Value> {
    if let Some(index) = seen.iter().position(|reply| &reply["id"] == id) {
        return Some(seen.remove(index));
    }
    loop {
        let left = deadline.checked_duration_since(Instant::now())?;
        reader.get_ref().set_read_timeout(Some(left.max(Duration::from_millis(1)))).unwrap();
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => panic!("the connection closed before the reply {id}"),
            Ok(_) => {}
            Err(_) => return None,
        }
        let reply: Value = serde_json::from_str(&line).unwrap();
        if &reply["id"] == id {
            return Some(reply);
        }
        if reply.get("id").is_some() {
            seen.push(reply);
        }
    }
}

fn v2(id: &str, operation: &str, mut params: Value) -> Value {
    params["machine"] = json!("current");
    params["session"] = json!("current");
    json!({"protocol":"cmux.protocol/2","type":"request","id":id,"operation":operation,"params":params})
}

#[test]
fn cmux_next_requests_behind_a_running_git_diff_are_answered_while_git_runs() {
    let dir = std::env::temp_dir().join(format!("ghol-{}", std::process::id()));
    let repo = dir.join("repo");
    let bin = dir.join("bin");
    std::fs::create_dir_all(&repo).unwrap();
    std::fs::create_dir_all(&bin).unwrap();
    let real = real_git();
    git(&real, &repo, &["init", "--quiet"]);
    std::fs::write(repo.join("a.txt"), "one\n").unwrap();
    git(&real, &repo, &["add", "."]);
    git(&real, &repo, &["commit", "--quiet", "-m", "one"]);
    std::fs::write(repo.join("a.txt"), "two\n").unwrap();
    install_gated_git(&bin, &real);

    let mux = Mux::new(format!("git-hol-{}", std::process::id()), SurfaceOptions::default());
    let socket = dir.join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    let stream = UnixStream::connect(&socket).unwrap();
    let mut writer = stream.try_clone().unwrap();
    let mut reader = BufReader::new(stream);
    let mut seen = Vec::new();

    // The connection works before git is held.
    writeln!(writer, "{}", json!({"id": 1, "cmd": "ping"})).unwrap();
    let long = Instant::now() + Duration::from_secs(30);
    assert!(reply_by(&mut reader, &json!(1), &mut seen, long).is_some(), "no first ping reply");

    // git.diff starts; its git waits at the gate.
    let hold = bin.join("hold");
    let held = bin.join("held");
    std::fs::write(&hold, "").unwrap();
    let path = repo.to_string_lossy();
    writeln!(writer, "{}", v2("diff", "git.diff", json!({"path": path, "scope": "uncommitted"})))
        .unwrap();
    while !held.exists() {
        assert!(Instant::now() < long, "git.diff never started git");
        std::thread::sleep(Duration::from_millis(5));
    }

    // Behind it, on the same connection: a liveness ping and a list.
    let asked = Instant::now();
    writeln!(writer, "{}", json!({"id": 2, "cmd": "ping"})).unwrap();
    writeln!(writer, "{}", v2("list", "workspace.list", json!({}))).unwrap();
    let while_held = asked + Duration::from_secs(4);
    let ping = reply_by(&mut reader, &json!(2), &mut seen, while_held);
    let ping_ms = asked.elapsed().as_millis();
    let list = reply_by(&mut reader, &json!("list"), &mut seen, while_held);
    let list_ms = asked.elapsed().as_millis();
    let diff_early = seen.iter().any(|reply| reply["id"] == json!("diff"));

    // The gate opens: git runs, and every reply still comes.
    std::fs::remove_file(&hold).unwrap();
    let diff = reply_by(&mut reader, &json!("diff"), &mut seen, long).expect("no git.diff reply");
    let late_ping = ping.is_none() && reply_by(&mut reader, &json!(2), &mut seen, long).is_some();
    let late_list =
        list.is_none() && reply_by(&mut reader, &json!("list"), &mut seen, long).is_some();
    let after_ms = asked.elapsed().as_millis();
    eprintln!(
        "git-hol: ping answered while git ran: {} (waited {ping_ms} ms); list answered while git \
         ran: {} (waited {list_ms} ms); answered only after git ended: ping {late_ping}, list \
         {late_list} ({after_ms} ms after they were sent)",
        ping.is_some(),
        list.is_some(),
    );

    assert!(!diff_early, "git.diff answered while its git was held");
    assert_eq!(diff["ok"], true, "git.diff failed: {diff}");
    assert_eq!(diff["result"]["files"][0]["path"], "a.txt", "{diff}");
    assert!(
        ping.is_some(),
        "a ping behind a running git.diff waited for git (answered after git ended: {late_ping})"
    );
    let list = list.unwrap_or_else(|| {
        panic!(
            "workspace.list behind a running git.diff waited for git (answered after git ended: \
             {late_list})"
        )
    });
    assert_eq!(list["ok"], true, "workspace.list failed: {list}");
    let _ = std::fs::remove_dir_all(&dir);
}
