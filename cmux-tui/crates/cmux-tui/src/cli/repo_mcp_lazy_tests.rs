use super::*;
use std::io::BufReader;
use std::os::unix::net::UnixStream;
use std::sync::mpsc;
use std::time::Duration;

/// A stdio MCP server in sh: it notes each `initialize` id it gets in `initialize-ids` (in its
/// folder), lists one tool, and answers a call with its folder. `exit` after `initialized`: it
/// ends with that code.
const SERVER: &str = r#"
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([^,}]*\).*/\1/p')
  method=$(printf '%s' "$line" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p')
  case "$method" in
    initialize)
      printf '%s\n' "$id" >> initialize-ids
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake"}}}\n' "$id" ;;
    notifications/initialized) [ -n "$1" ] && exit "$1" ;;
    tools/list) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo"}]}}\n' "$id" ;;
    tools/call) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s"}]}}\n' "$id" "$(pwd -P)" ;;
  esac
done
"#;

struct Client {
    to: UnixStream,
    from: BufReader<UnixStream>,
    ready: mpsc::Sender<io::Result<()>>,
    ended: mpsc::Receiver<i32>,
    proxy: std::thread::JoinHandle<i32>,
}

impl Client {
    fn start(dir: &Path, exit: Option<&str>) -> Self {
        Self::start_script(dir, SERVER, exit)
    }

    /// As `start`, the server `script` in sh, `$1` its `exit`.
    fn start_script(dir: &Path, script: &str, exit: Option<&str>) -> Self {
        let (to, input) = UnixStream::pair().unwrap();
        let (output, from) = UnixStream::pair().unwrap();
        from.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let (ready, waits) = mpsc::channel::<io::Result<()>>();
        let (ends, ended) = mpsc::channel::<i32>();
        let cmd: Vec<String> =
            ["sh", "-c", script, "server"].into_iter().chain(exit).map(str::to_owned).collect();
        let dir = dir.to_path_buf();
        let proxy = std::thread::spawn(move || {
            let out: Out = Arc::new(Mutex::new(output));
            // As `whole`: a bounded wait, again until the barrier says or the client left.
            let ready = move |closed: &AtomicBool| loop {
                match waits.recv_timeout(Duration::from_millis(10)) {
                    Ok(done) => return done,
                    Err(mpsc::RecvTimeoutError::Timeout) if !closed.load(Ordering::SeqCst) => {}
                    Err(_) => return Err(io::Error::other("the client left")),
                }
            };
            let ended = Box::new(move |code: i32| {
                let _ = ends.send(code);
            });
            proxy(BufReader::new(input), out, &dir, &cmd, ready, ended)
        });
        Self { to, from: BufReader::new(from), ready, ended, proxy }
    }

    fn send(&mut self, message: Value) {
        writeln!(self.to, "{message}").unwrap();
    }

    fn read(&mut self) -> Value {
        let mut line = String::new();
        self.from.read_line(&mut line).expect("a line from the proxy");
        serde_json::from_str(&line).unwrap()
    }

    /// Nothing comes for a moment.
    fn quiet(&mut self) -> bool {
        self.from.get_ref().set_read_timeout(Some(Duration::from_millis(300))).unwrap();
        let mut line = String::new();
        let quiet = self.from.read_line(&mut line).is_err();
        self.from.get_ref().set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        quiet
    }

    fn request(&mut self, id: u64, method: &str) {
        self.send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": {}}));
    }

    fn initialize(&mut self) -> Value {
        let params = json!({"protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "claude-code", "version": "2.1.305"}});
        self.send(json!({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": params}));
        let answer = self.read();
        self.send(json!({"jsonrpc": "2.0", "method": "notifications/initialized"}));
        answer
    }

    fn close(self) -> i32 {
        drop(self.to);
        self.proxy.join().unwrap()
    }
}

#[test]
fn it_answers_at_once_and_serves_the_tools_once_the_checkout_is_whole() {
    let dir = tempfile::tempdir().unwrap();
    let dir = dir.path().canonicalize().unwrap();
    let mut client = Client::start(&dir, None);
    let answer = client.initialize();
    assert_eq!(answer["id"], 0);
    assert_eq!(answer["result"]["capabilities"]["tools"]["listChanged"], true);
    assert_eq!(answer["result"]["protocolVersion"], "2025-06-18");
    client.request(1, "tools/list");
    assert_eq!(client.read(), json!({"jsonrpc": "2.0", "id": 1, "result": {"tools": []}}));
    client.request(2, "prompts/list");
    assert_eq!(client.read()["result"], json!({"prompts": []}));
    client.request(3, "tools/call");
    assert!(client.quiet(), "a call waits for the checkout");
    assert!(!dir.join("initialize-ids").exists(), "no server before the checkout is whole");

    client.ready.send(Ok(())).unwrap();
    assert_eq!(client.read()["method"], "notifications/tools/list_changed");
    let called = client.read();
    assert_eq!(called["id"], 3, "the call that waited goes to the server: {called}");
    assert_eq!(called["result"]["content"][0]["text"], dir.to_str().unwrap(), "it runs in DIR");
    client.request(4, "tools/list");
    assert_eq!(client.read()["result"]["tools"][0]["name"], "echo");
    // The server got one initialize, under the proxy's own id; the client's was answered here.
    let ids = std::fs::read_to_string(dir.join("initialize-ids")).unwrap();
    assert_eq!(ids, format!("\"{INIT_ID}\"\n"));
    assert!(client.quiet(), "no second answer to the client's initialize");
    assert_eq!(client.close(), 0, "it ends with the server once stdin closes");
}

#[test]
fn a_failed_checkout_keeps_the_lists_empty_and_refuses_calls() {
    let dir = tempfile::tempdir().unwrap();
    let mut client = Client::start(dir.path(), None);
    client.initialize();
    client.request(1, "tools/call");
    client.ready.send(Err(io::Error::other("repository synchronization failed"))).unwrap();
    let refused = client.read();
    assert_eq!(refused["id"], 1);
    assert!(refused["error"]["message"].as_str().unwrap().contains("did not finish"));
    client.request(2, "tools/list");
    assert_eq!(client.read()["result"], json!({"tools": []}));
    client.request(3, "tools/call");
    assert_eq!(client.read()["id"], 3);
    assert!(!dir.path().join("initialize-ids").exists(), "the server never ran");
    assert_eq!(client.close(), 0);
}

#[test]
fn it_ends_with_the_server() {
    let dir = tempfile::tempdir().unwrap();
    let mut client = Client::start(dir.path(), Some("3"));
    client.initialize();
    client.ready.send(Ok(())).unwrap();
    assert_eq!(client.ended.recv_timeout(Duration::from_secs(10)), Ok(3));
}

/// The client leaves before the checkout is whole: the wait for it ends, the server never runs,
/// and the proxy returns (its server thread joined).
#[test]
fn a_client_that_leaves_before_ready_ends_the_wait() {
    let dir = tempfile::tempdir().unwrap();
    let mut client = Client::start(dir.path(), None);
    client.initialize();
    client.request(1, "tools/call");
    let Client { to, ready, proxy, .. } = client;
    drop(to);
    assert_eq!(proxy.join().unwrap(), 0);
    assert!(ready.send(Ok(())).is_err(), "nothing waits on the barrier any more");
    assert!(!dir.path().join("initialize-ids").exists(), "the server never ran");
}

/// The client leaves after the server started but before it answered `initialize`: the server
/// (one that never reads stdin) ends, and the proxy returns.
#[test]
fn a_client_that_leaves_before_the_server_answers_ends_it() {
    let dir = tempfile::tempdir().unwrap();
    let script = "echo started > started; exec sleep 1000";
    let mut client = Client::start_script(dir.path(), script, None);
    client.initialize();
    client.ready.send(Ok(())).unwrap();
    let started = dir.path().join("started");
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !started.exists() {
        assert!(std::time::Instant::now() < deadline, "the server never started");
        std::thread::sleep(Duration::from_millis(10));
    }
    let (done, returned) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = done.send(client.close());
    });
    assert_eq!(returned.recv_timeout(Duration::from_secs(10)), Ok(0), "the proxy returns");
}

/// The client's `initialize` is answered with the version it asked for, never the server's, and
/// with no `instructions`: the server's would come too late.
#[test]
fn the_answer_echoes_the_clients_version() {
    let dir = tempfile::tempdir().unwrap();
    let mut client = Client::start(dir.path(), None);
    let params = json!({"protocolVersion": "2099-01-01", "capabilities": {}});
    client.send(json!({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": params}));
    let answer = client.read();
    assert_eq!(answer["result"]["protocolVersion"], "2099-01-01");
    assert!(answer["result"].get("instructions").is_none());
    assert_eq!(answer["result"]["serverInfo"]["name"], "cmux-mcp-lazy");
    assert_eq!(client.close(), 0);
}

/// What the server's answer holds that the client never sees is said on stderr.
#[test]
fn a_lower_version_or_instructions_are_noted() {
    let requested = json!("2025-06-18");
    let same = json!({"protocolVersion": "2025-06-18", "capabilities": {}});
    assert!(unrelayed(Some(&requested), &same).is_empty());
    let lower = json!({"protocolVersion": "2024-11-05", "instructions": "Use search first."});
    let notes = unrelayed(Some(&requested), &lower);
    assert_eq!(notes.len(), 2, "{notes:?}");
    assert!(notes[0].contains("2024-11-05"));
    assert!(notes[1].contains("instructions"));
}

/// A server that pings before it answers `initialize` gets its answer from the proxy (the
/// client's answers wait until it is live), then serves its tools.
#[test]
fn a_ping_during_initialize_is_answered() {
    const PINGS_FIRST: &str = r#"
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([^,}]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*)
      printf '{"jsonrpc":"2.0","id":"server-ping","method":"ping"}\n'
      IFS= read -r pong
      case "$pong" in *'"id":"server-ping"'*) ;; *) exit 3 ;; esac
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}}}}\n' "$id" ;;
    *'"method":"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo"}]}}\n' "$id" ;;
  esac
done
"#;
    let dir = tempfile::tempdir().unwrap();
    let dir = dir.path().canonicalize().unwrap();
    let mut client = Client::start_script(&dir, PINGS_FIRST, None);
    client.initialize();
    client.ready.send(Ok(())).unwrap();
    assert_eq!(client.read()["method"], "notifications/tools/list_changed");
    client.request(1, "tools/list");
    assert_eq!(client.read()["result"]["tools"][0]["name"], "echo");
    assert_eq!(client.close(), 0);
}
