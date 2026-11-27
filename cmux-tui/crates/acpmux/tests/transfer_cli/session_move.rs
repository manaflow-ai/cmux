//! The actual CLI move path: SSH is a hermetic stand-in; transfer and both daemons are real.
use super::*;
use std::os::unix::fs::PermissionsExt;

/// Stand in only for the SSH operations the CLI needs. No host SSH, credentials or network are
/// used; the socket symlink reaches the other test daemon's real RPC server.
///
/// With `link` (the target's WebSocket port, a one-way delay in milliseconds) it also carries the
/// daemon's own peer link: `ssh -W` is a TCP connection to that port, each chunk held for the
/// delay in both directions as a link of that latency holds it, and the remote config read
/// answers with the target's `config.json` and peer token.
pub(super) fn fake_ssh(
    home: &Path,
    target_home: &Path,
    target_socket: &Path,
    link: Option<(u16, u64)>,
) -> String {
    let bin = home.join("bin");
    std::fs::create_dir(&bin).unwrap();
    let script = format!(
        r#"#!/usr/bin/env python3
import json, os, pathlib, signal, sys
home = {home}
socket = {socket}
link = {link}
args = sys.argv[1:]
# session_move.rs PLAIN_SCRIPT, the folder a move makes on the target, by its exact text:
# other scripts (the carry's APPLY_SCRIPT) also read `d` and `mkdir -p`.
PLAIN = 'read -r d || exit 2; mkdir -p -- "$d"'
if '-W' in args and link:
    import queue, socket as net, threading, time
    port, delay = link[0], link[1] / 1000
    peer = net.create_connection(('127.0.0.1', port))
    peer.setsockopt(net.IPPROTO_TCP, net.TCP_NODELAY, 1)
    def write_out(data):
        while data:
            data = data[os.write(1, data):]
    def pump(read, write, close):
        held = queue.Queue()
        def deliver():
            while True:
                item = held.get()
                if item is None:
                    close()
                    return
                wait = item[0] - time.monotonic()
                if wait > 0:
                    time.sleep(wait)
                write(item[1])
        out = threading.Thread(target=deliver, daemon=True)
        out.start()
        while True:
            try:
                data = read()
            except OSError:
                data = b''
            if not data:
                held.put(None)
                out.join()
                return
            held.put((time.monotonic() + delay, data))
    up = threading.Thread(
        target=pump,
        args=(lambda: os.read(0, 65536), peer.sendall, lambda: peer.shutdown(net.SHUT_WR)),
        daemon=True)
    up.start()
    pump(lambda: peer.recv(65536), write_out, lambda: None)
    os._exit(0)
if '-L' in args:
    local, remote = args[args.index('-L') + 1].split(':', 1)
    assert remote == socket
    os.symlink(socket, local)
    signal.pause()
    sys.exit(0)
if '-W' in args:
    # A daemon's own link to its peer (`peer.rs` `tunnel_argv`): this process's stdin and
    # stdout are the peer's WebSocket port, the one its config names whatever port was asked for.
    import socket as net, threading
    listen = json.loads(pathlib.Path(home, 'config.json').read_text()).get('websocket') or dict()
    at = listen.get('listen')
    if not at:
        sys.exit(1)
    host, port = at.rsplit(':', 1)
    link = net.create_connection((host, int(port)))
    link.setsockopt(net.IPPROTO_TCP, net.TCP_NODELAY, 1)
    # FAKE_SSH_DELAY_MS (the daemon's env): each chunk is held that long in both directions, as
    # a link of that one-way latency holds it (`view_latency.rs`).
    delay = int(os.environ.get('FAKE_SSH_DELAY_MS') or 0) / 1000
    def write_out(data):
        while data:
            data = data[os.write(1, data):]
    def pump(read, write, close):
        import queue, time
        held = queue.Queue()
        def deliver():
            while True:
                item = held.get()
                if item is None:
                    close()
                    return
                wait = item[0] - time.monotonic()
                if wait > 0:
                    time.sleep(wait)
                write(item[1])
        out = threading.Thread(target=deliver, daemon=True)
        out.start()
        while True:
            try:
                data = read()
            except OSError:
                data = b''
            if not data:
                held.put(None)
                out.join()
                return
            held.put((time.monotonic() + delay, data))
    threading.Thread(
        target=pump,
        args=(lambda: os.read(0, 65536), link.sendall, lambda: link.shutdown(net.SHUT_WR)),
        daemon=True).start()
    pump(lambda: link.recv(65536), write_out, lambda: None)
    sys.exit(0)
command = args[-1]
if link and 'cat ~/.acpmux/config.json' in command:
    sys.stdout.buffer.write(pathlib.Path(home, 'config.json').read_bytes() + b'\0')
    token = pathlib.Path(home, 'run', 'peer.token')
    if token.exists():
        sys.stdout.buffer.write(token.read_bytes())
    sys.stdout.buffer.flush()
elif 'acpmux daemon status --json' in command:
    print(home)
    print(json.dumps({{'socket': socket}}))
    print(500000000)
elif 'cat ~/.acpmux/config.json' in command:
    # A daemon's own link to its peer (`peer.rs` `read_config_argv`): the peer's config, a NUL,
    # its peer token of this launch. A peer that serves no WebSocket has no link, as before.
    config = pathlib.Path(home, 'config.json').read_bytes()
    if 'websocket' not in json.loads(config):
        sys.exit(1)
    sys.stdout.buffer.write(config + b'\0')
    token = pathlib.Path(home, 'run', 'peer.token')
    if token.exists():
        sys.stdout.buffer.write(token.read_bytes())
elif PLAIN in command:
    folder = pathlib.Path(sys.stdin.readline().strip())
    assert str(folder).startswith(home + '/')
    folder.mkdir(parents=True, exist_ok=True)
    print(folder.resolve())
else:
    sys.exit(1)
"#,
        home = serde_json::to_string(&target_home.to_string_lossy()).unwrap(),
        socket = serde_json::to_string(&target_socket.to_string_lossy()).unwrap(),
        link = link.map_or("None".to_owned(), |(port, delay)| format!("({port}, {delay})")),
    );
    let ssh = bin.join("ssh");
    std::fs::write(&ssh, script).unwrap();
    std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o700)).unwrap();
    format!("{}:{}", bin.display(), daemon_env::bare_path(&[]))
}

impl Rpc {
    pub(super) async fn send_prompt(&mut self, id: &str, prompt_id: &str, text: &str) {
        self.next += 1;
        let request = json!({"jsonrpc": "2.0", "id": self.next, "method": "session/prompt",
            "params": prompt(id, prompt_id, text)});
        self.wr.write_all(format!("{request}\n").as_bytes()).await.unwrap();
    }

    pub(super) async fn notification(&mut self, method: &str, predicate: impl Fn(&Value) -> bool) {
        tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                let line = self.lines.next_line().await.unwrap().expect("daemon connected");
                let message: Value = serde_json::from_str(&line).unwrap();
                if message["method"] == method && predicate(&message["params"]) {
                    break;
                }
            }
        })
        .await
        .unwrap_or_else(|_| panic!("did not receive {method}"));
    }

    pub(super) async fn texts(&mut self, id: &str, kind: &str) -> Vec<String> {
        let page = self
            .call("_acpmux/events", json!({"sessionId": id, "afterSeq": 0, "limit": 5000}))
            .await;
        page["events"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|event| event["kind"] == kind)
            .filter_map(|event| {
                event["msg"]["text"]
                    .as_str()
                    .or_else(|| {
                        event["msg"].pointer("/params/update/content/text").and_then(Value::as_str)
                    })
                    .map(str::to_owned)
            })
            .collect()
    }
}

pub(super) fn prompt(id: &str, prompt_id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": prompt_id}}})
}

#[tokio::test]
async fn session_move_to_an_added_ssh_machine_preserves_history_queue_and_draft() {
    let target = Daemon::start("move-target").await;
    let source = Daemon::with_peer("move-source", Some(&target)).await;
    let cwd = source.home.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let mut src = Rpc::connect(&source.socket).await;
    let made = src.call("session/new", json!({"cwd": cwd, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap();
    src.call("session/prompt", prompt(id, "p-hi", "hi")).await;
    let original_replies = src.texts(id, "agent_message_chunk").await;
    assert!(!original_replies.is_empty(), "the source conversation has an agent reply");
    src.call("_acpmux/draft_set", json!({"sessionId": id, "text": "unsent words"})).await;
    src.send_prompt(id, "p-turn", "until-cancel").await;
    src.notification("session/update", |p| p["update"]["content"]["text"] == "running").await;
    for (prompt_id, text) in [("p-a", "a"), ("p-b", "b")] {
        src.send_prompt(id, prompt_id, text).await;
        src.notification("_acpmux/prompt_accepted", |p| {
            p["promptId"] == prompt_id && p["queued"] == true
        })
        .await;
    }
    let destination = target.home.join("arrived");
    let mut command = daemon_env::tokio_command(&source.home, daemon_env::Agents::Deny);
    command
        .args(["--json", "session", "move", id, "--machine", "target", "--interrupt", "--cwd"])
        .arg(&destination)
        .env(
            "PATH",
            format!("{}:{}", source.home.join("bin").display(), daemon_env::bare_path(&[])),
        )
        .env("ACPMUX_HOME", &source.home)
        .env("ACPMUX_SOCKET", &source.socket)
        .kill_on_drop(true);
    let out = tokio::time::timeout(Duration::from_secs(45), command.output())
        .await
        .expect("session move completed")
        .expect("run session move");
    assert!(
        out.status.success(),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let receipt: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(receipt["moves"][0]["moved"], true, "{receipt}");
    assert_eq!(receipt["moves"][0]["targetSessionId"], id, "{receipt}");

    let mut dst = Rpc::connect(&target.socket).await;
    let ready = dst
        .call(
            "_acpmux/wait",
            json!({"sessions": [id], "until": ["ready"], "all": true, "timeoutMs": 20000}),
        )
        .await;
    assert_eq!(ready["timedOut"], false, "the moved queue finished: {ready}");
    let prompts = dst.texts(id, "user_message").await;
    assert_eq!(prompts.len(), 5, "history, continuation, queue: {prompts:?}");
    assert_eq!(prompts[..2], ["hi", "until-cancel"]);
    assert_eq!(prompts[3..], ["a", "b"], "each queued prompt runs once, in order");
    let replies = dst.texts(id, "agent_message_chunk").await;
    assert_eq!(replies[..original_replies.len()], original_replies);
    assert_eq!(src.texts(id, "user_message").await, ["hi", "until-cancel"]);
    let draft = dst.call("_acpmux/draft_get", json!({"sessionId": id})).await;
    assert_eq!(draft["draft"], "unsent words");
    let info = dst.call("_acpmux/info", json!({"sessionId": id})).await;
    assert_eq!(info["cwd"], destination.to_string_lossy().as_ref());
    // The row the source keeps: a plain `{sessionId}` info follows the chat to its copy.
    let kept = src.call("_acpmux/info", json!({"sessionIds": [id], "row": true})).await;
    let left = &kept["rows"][0];
    assert_eq!(left["status"], "closed");
    assert_eq!(left["movedTo"]["host"], "target");
}
