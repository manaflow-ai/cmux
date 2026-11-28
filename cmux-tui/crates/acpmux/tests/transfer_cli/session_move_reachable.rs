//! A moved chat is reachable from the machine it left the moment the move commits. Leo,
//! 2026-11-23: "if it can "move to cloud" in the BACKEND but i still am able to interact with
//! it with no percievable lag or whatever here ... that's gold."
//!
//! Both daemons are real, and so is the peer link between them: the target listens on a
//! loopback port and the source's ssh peer `target` reaches it through a stand-in `ssh` that
//! carries the tunnel, reads the peer token and does the three operations of a move. A move
//! keeps the chat's id, so the source holds two rows with it after the commit: the closed one
//! it keeps (`movedTo`) and the target's mirrored one, `target/ID`.
use super::*;
use std::io::BufRead;
use std::os::unix::fs::PermissionsExt;

/// A daemon that also listens on a loopback port, and that port.
fn listening(tag: &str) -> (Daemon, String) {
    let home = PathBuf::from("/tmp").join(format!("amx-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).expect("home");
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let config = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"});
    std::fs::write(home.join("config.json"), config.to_string()).expect("config");
    let socket = home.join("s.sock");
    let mut child = daemon_env::command(&home, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--ready-fd", "1", "--listen", "127.0.0.1:0", "--log", "warn"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_AGENT_HOSTS", "0")
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("spawn daemon");
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for line in std::io::BufReader::new(stdout).lines().map_while(Result::ok) {
            if line.starts_with('{') {
                let _ = tx.send(line);
            }
        }
    });
    let daemon = Daemon { home, socket, child };
    let ready = rx.recv_timeout(Duration::from_secs(20)).expect("daemon ready");
    let ready: Value = serde_json::from_str(&ready).unwrap();
    let port = ready["listen"].as_str().expect("listen").rsplit(':').next().unwrap().to_owned();
    (daemon, port)
}

/// `ssh` for the source: the peer link's tunnel and token read, and a move's forward, status
/// and folder. No host SSH, credentials or network beyond loopback.
fn peer_ssh(home: &Path, target: &Daemon) -> String {
    let bin = home.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let script = format!(
        r#"#!/usr/bin/env python3
import json, os, pathlib, signal, socket as net, sys, threading
home = {home}
socket = {socket}
args = sys.argv[1:]
# session_move.rs PLAIN_SCRIPT, the folder a move makes on the target, by its exact text:
# other scripts (the carry's APPLY_SCRIPT) also read `d` and `mkdir -p`.
PLAIN = 'read -r d || exit 2; mkdir -p -- "$d"'
if '-W' in args:
    host, port = args[args.index('-W') + 1].rsplit(':', 1)
    s = net.create_connection((host, int(port)))
    def up():
        while True:
            b = os.read(0, 65536)
            if not b:
                break
            s.sendall(b)
        s.shutdown(net.SHUT_WR)
    threading.Thread(target=up, daemon=True).start()
    while True:
        b = s.recv(65536)
        if not b:
            break
        os.write(1, b)
    sys.exit(0)
if '-L' in args:
    local, remote = args[args.index('-L') + 1].split(':', 1)
    assert remote == socket
    os.symlink(socket, local)
    signal.pause()
    sys.exit(0)
command = args[-1]
if 'acpmux daemon status --json' in command:
    print(home)
    print(json.dumps({{'socket': socket}}))
    print(500000000)
elif PLAIN in command:
    folder = pathlib.Path(sys.stdin.readline().strip())
    assert str(folder).startswith(home + '/')
    folder.mkdir(parents=True, exist_ok=True)
    print(folder.resolve())
elif 'peer.token' in command:
    out = open(os.path.join(home, 'config.json'), 'rb').read() + b'\0'
    os.write(1, out + open(os.path.join(home, 'run', 'peer.token'), 'rb').read())
else:
    sys.exit(1)
"#,
        home = serde_json::to_string(&target.home.to_string_lossy()).unwrap(),
        socket = serde_json::to_string(&target.socket.to_string_lossy()).unwrap(),
    );
    let ssh = bin.join("ssh");
    std::fs::write(&ssh, script).unwrap();
    std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o700)).unwrap();
    format!("{}:{}", bin.display(), daemon_env::bare_path(&[]))
}

/// The target, and a source whose peer `target` is linked to it and connected.
async fn linked(tag: &str) -> (Daemon, Daemon, Rpc) {
    let (target, port) = listening(&format!("{tag}t"));
    let home = PathBuf::from("/tmp").join(format!("amx-{tag}s-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).expect("home");
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let config = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all",
        "peers": {"target": {"url": format!("ssh://target:{port}")}}});
    std::fs::write(home.join("config.json"), config.to_string()).expect("config");
    let socket = home.join("s.sock");
    let child = daemon_env::command(&home, daemon_env::Agents::StandIn, &[])
        .env("PATH", peer_ssh(&home, &target))
        .args(["daemon", "run", "--log", "warn"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_AGENT_HOSTS", "0")
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("spawn daemon");
    let source = Daemon { home, socket, child };
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while tokio::net::UnixStream::connect(&source.socket).await.is_err() {
        assert!(tokio::time::Instant::now() < deadline, "daemon {tag} never listened");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let mut src = Rpc::connect(&source.socket).await;
    loop {
        let peers = src.call("_acpmux/peers", json!({})).await;
        if peers["peers"][0]["state"] == "connected" {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "the peer link never came up: {peers}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    (target, source, src)
}

fn text_prompt(session: &str, prompt_id: &str, text: &str) -> Value {
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": prompt_id}}})
}

fn acpmux(source: &Daemon) -> tokio::process::Command {
    let mut command = daemon_env::tokio_command(&source.home, daemon_env::Agents::Deny);
    command
        .env(
            "PATH",
            format!("{}:{}", source.home.join("bin").display(), daemon_env::bare_path(&[])),
        )
        .env("ACPMUX_HOME", &source.home)
        .env("ACPMUX_SOCKET", &source.socket)
        .kill_on_drop(true);
    command
}

/// A chat on `source` with one finished turn, and the folder it gets on `target`.
async fn chat(source: &Daemon, target: &Daemon, src: &mut Rpc) -> (String, PathBuf) {
    let cwd = source.home.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let made = src.call("session/new", json!({"cwd": cwd, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    src.call("session/prompt", text_prompt(&id, "p-hi", "hi")).await;
    (id, target.home.join("arrived"))
}

fn move_command(source: &Daemon, id: &str, to: &Path) -> tokio::process::Command {
    let mut command = acpmux(source);
    command.args(["--json", "session", "move", id, "--machine", "target", "--cwd"]).arg(to);
    command
}

/// The source's own row of `id` once the move committed: closed, with where it went.
async fn committed(src: &mut Rpc, id: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(45);
    loop {
        // The row this machine keeps: a plain `{sessionId}` info of a chat that moved to a
        // connected peer is answered from its copy there (`MOVED_FORWARDED`, #52853).
        let listed = src.call("_acpmux/info", json!({"sessionIds": [id], "row": true})).await;
        let info = &listed["rows"][0];
        if info["status"] == "closed" && info["movedTo"]["host"] == "target" {
            return;
        }
        assert!(tokio::time::Instant::now() < deadline, "the move never committed: {info}");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

async fn user_messages(rpc: &mut Rpc, id: &str) -> Vec<String> {
    let page =
        rpc.call("_acpmux/events", json!({"sessionId": id, "afterSeq": 0, "limit": 5000})).await;
    page["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|event| event["kind"] == "user_message")
        .filter_map(|event| event["msg"]["text"].as_str().map(str::to_owned))
        .collect()
}

/// The move ends when this machine lists the chat reachable on the target, and says so in its
/// receipt. It asked for the bare id before, which names the closed row the source keeps: every
/// move then waited out the whole 20 s bound and warned "not listed here yet".
#[tokio::test]
async fn a_move_ends_as_soon_as_the_source_lists_the_chat_on_the_target() {
    let (target, source, mut src) = linked("mr1").await;
    let (id, to) = chat(&source, &target, &mut src).await;

    let started = std::time::Instant::now();
    let moving = tokio::spawn(move_command(&source, &id, &to).output());
    committed(&mut src, &id).await;
    let at_commit = std::time::Instant::now();
    let out = tokio::time::timeout(Duration::from_secs(45), moving)
        .await
        .expect("session move completed")
        .unwrap()
        .expect("run session move");
    let (took, after_commit) = (started.elapsed(), at_commit.elapsed());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        out.status.success(),
        "stdout={} stderr={stderr}",
        String::from_utf8_lossy(&out.stdout)
    );
    let receipt: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(receipt["moves"][0]["moved"], true, "{receipt}");
    assert_eq!(receipt["moves"][0]["reachable"], true, "{receipt} stderr={stderr}");
    assert!(!stderr.contains("does not list it reachable"), "{stderr}");

    // What the receipt says is what this machine lists: the target's row, its link up.
    let key = format!("target/{id}");
    let listed = src.call("_acpmux/info", json!({"sessionIds": [key], "row": true})).await;
    let row = &listed["rows"][0];
    assert_eq!(row["peer"], "target", "{listed}");
    assert_ne!(row["stale"], true, "{listed}");
    assert_ne!(row["status"], "closed", "{listed}");
    // The bare id is the row this machine keeps, which no wait turns into the target's.
    let kept = src.call("_acpmux/info", json!({"sessionIds": [id], "row": true})).await;
    assert_eq!(kept["rows"][0]["status"], "closed", "{kept}");

    eprintln!("session move: {took:?} in all, receipt {after_commit:?} after the commit");
    assert!(
        after_commit < Duration::from_secs(3),
        "the receipt came {after_commit:?} after the commit ({took:?} in all): {stderr}"
    );
}

/// A prompt sent through the source the moment the move commits starts a turn on the target:
/// by the peer's row key over the daemon's link, and by the CLI, with no "queued here" detour.
#[tokio::test]
async fn a_prompt_sent_through_the_source_at_the_commit_runs_on_the_target_at_once() {
    let (target, source, mut src) = linked("mr2").await;
    let (id, to) = chat(&source, &target, &mut src).await;
    let key = format!("target/{id}");

    let moving = tokio::spawn(move_command(&source, &id, &to).output());
    committed(&mut src, &id).await;
    // Within the 5 ms poll of the commit, while the move's own client is still up.
    let sent = std::time::Instant::now();
    let done = src.call("session/prompt", text_prompt(&key, "p-at-commit", "at commit")).await;
    let first = sent.elapsed();
    assert_eq!(done["stopReason"], "end_turn", "{done}");

    let out = tokio::time::timeout(Duration::from_secs(45), moving)
        .await
        .expect("session move completed")
        .unwrap()
        .expect("run session move");
    assert!(out.status.success(), "stderr={}", String::from_utf8_lossy(&out.stderr));

    // And straight after the move's client has gone, as a person's send from the source.
    let sent = std::time::Instant::now();
    let out = tokio::time::timeout(
        Duration::from_secs(45),
        acpmux(&source).args(["send", &key, "--quiet", "after the move"]).output(),
    )
    .await
    .expect("send completed")
    .expect("run send");
    let second = sent.elapsed();
    let (stdout, stderr) =
        (String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    assert!(out.status.success(), "stdout={stdout} stderr={stderr}");
    assert!(!stderr.contains("queued here"), "{stderr}");
    assert!(!stderr.contains("unreachable"), "{stderr}");
    assert!(stdout.contains("echo: after the move"), "the reply is streamed: {stdout}");

    let mut dst = Rpc::connect(&target.socket).await;
    let prompts = user_messages(&mut dst, &id).await;
    let ran: Vec<&str> =
        prompts.iter().map(String::as_str).filter(|p| !p.starts_with("This chat moved")).collect();
    assert_eq!(ran, ["hi", "at commit", "after the move"], "{prompts:?}");
    eprintln!("after a move: the prompt at the commit took {first:?}, the send after {second:?}");
    for took in [first, second] {
        assert!(took < Duration::from_secs(5), "a send after a move took {took:?}");
    }
}
