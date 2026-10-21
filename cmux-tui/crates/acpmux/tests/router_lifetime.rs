//! The local router (`acpmux router serve`) lives exactly as long as a
//! process that may use it: the daemon or a kept agent host. `acpmux daemon
//! shutdown` with no kept agent stops it before the daemon exits, a daemon
//! killed with SIGKILL takes it along, and after `daemon shutdown
//! --keep-agents` the next daemon adopts it, so the kept agent's model calls
//! still go through. Real binaries, real sockets, a temporary home.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket paths must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
    )
    .unwrap();
    dir
}

/// A daemon in `dir` with the local router on; returns after its readiness line.
fn start_daemon(dir: &Path) -> Child {
    start_daemon_at(dir, dir)
}

/// A daemon with the acpmux home `home` and its socket in `dir`.
fn start_daemon_at(dir: &Path, home: &Path) -> Child {
    let mut child = daemon_env::command(dir, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .env("ACPMUX_LOCAL_ROUTER", "1")
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    for line in BufReader::new(stdout).lines() {
        let line = line.unwrap();
        if serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true) {
            return child;
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    panic!("daemon exited without a readiness line");
}

/// `acpmux daemon shutdown` as the CLI runs it, against the daemon in `dir`.
fn cli_shutdown(dir: &Path, extra: &[&str]) {
    cli_shutdown_at(dir, dir, extra);
}

/// `cli_shutdown` for a daemon with the acpmux home `home` and its socket in `dir`.
fn cli_shutdown_at(dir: &Path, home: &Path, extra: &[&str]) {
    let out = daemon_env::acpmux(dir)
        .args(["daemon", "shutdown"])
        .args(extra)
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
}

/// The router admin socket of the acpmux home `home`, by the rule the router,
/// acpmux and the cmux app share (cmux-coderouter admin_socket.rs, Swift
/// `LocalRouterClient.socketPath`): `<home>/router/router.sock` when it fits a
/// Unix socket address (103 bytes), else `/tmp/acpmux-<uid>/<fnv1a64(home)>-router.sock`.
fn router_socket(home: &Path) -> PathBuf {
    use std::os::unix::ffi::OsStrExt;
    let preferred = home.join("router").join("router.sock");
    if preferred.as_os_str().len() <= 103 {
        return preferred;
    }
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in home.as_os_str().as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("/tmp/acpmux-{uid}/{hash:016x}-router.sock"))
}

/// An acpmux home in `dir` whose `router/router.sock` is 140 bytes, past
/// every platform's Unix socket limit (104 bytes with the NUL on macOS, 108 on
/// Linux), with the stand-in agent config.
fn long_home(dir: &Path) -> PathBuf {
    let pad = 140 - "/router/router.sock".len() - dir.join("long-home-").as_os_str().len();
    let home = dir.join(format!("long-home-{}", "h".repeat(pad)));
    std::fs::create_dir_all(&home).unwrap();
    std::fs::copy(dir.join("config.json"), home.join("config.json")).unwrap();
    assert_eq!(home.join("router").join("router.sock").as_os_str().len(), 140);
    home
}

/// One admin request to the router in `dir`.
fn ask_router(dir: &Path, request: Value) -> Value {
    let mut stream = UnixStream::connect(router_socket(dir)).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    stream.write_all(format!("{request}\n").as_bytes()).unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

/// The router's pid from its admin socket (it starts after the daemon is
/// ready), and an idle admin connection that reads EOF when the router
/// process is gone.
fn router(dir: &Path) -> (i32, UnixStream) {
    let socket = router_socket(dir);
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Ok(mut stream) = UnixStream::connect(&socket) {
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            stream.write_all(b"{\"op\":\"status\"}\n").unwrap();
            let mut line = String::new();
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
            let status: Value = serde_json::from_str(&line).unwrap();
            let pid = i32::try_from(status["pid"].as_u64().expect("status names the pid")).unwrap();
            return (pid, stream);
        }
        assert!(Instant::now() < deadline, "the daemon started no router");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

fn gone_within(pid: i32, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while alive(pid) {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    true
}

fn wait_exit(child: &mut Child, within: Duration) {
    let deadline = Instant::now() + within;
    while child.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon still running");
        std::thread::sleep(Duration::from_millis(20));
    }
}

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
}

impl Rpc {
    async fn connect(dir: &Path) -> Self {
        let s = tokio::net::UnixStream::connect(dir.join("s.sock")).await.unwrap();
        let (rd, wr) = s.into_split();
        Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0 }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
                .await
                .expect("daemon answered in time")
                .unwrap()
                .expect("daemon closed the socket");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }

    /// Prompts `session` and returns the last agent text of the session.
    async fn prompt(&mut self, session: &str, text: &str) -> String {
        self.call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
        let events = self
            .call("_acpmux/events", json!({"sessionId": session, "kinds": ["agent_message_chunk"]}))
            .await;
        events["events"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|e| e.pointer("/msg/params/update/content/text").and_then(Value::as_str))
            .next_back()
            .unwrap_or_default()
            .to_owned()
    }
}

#[test]
fn daemon_shutdown_stops_its_router_before_it_exits() {
    let dir = scratch("rtst");
    let mut daemon = start_daemon(&dir);
    let (pid, _held) = router(&dir);
    assert!(alive(pid));
    cli_shutdown(&dir, &["--end-agents"]);
    wait_exit(&mut daemon, Duration::from_secs(15));
    // The daemon reaps the router it started before it exits: the pid is
    // gone now, with no wait (a leaked router would live on with parent pid 1).
    assert!(!alive(pid), "router pid {pid} outlived `acpmux daemon shutdown`");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn router_exits_when_its_daemon_is_killed() {
    let dir = scratch("rkil");
    let mut daemon = start_daemon(&dir);
    let (pid, mut held) = router(&dir);
    assert!(alive(pid));
    // SIGKILL: no shutdown path runs; only the owner FIFO can stop the router.
    daemon.kill().unwrap();
    daemon.wait().unwrap();
    held.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut rest = Vec::new();
    held.read_to_end(&mut rest).expect("the router closed its admin connection in time");
    // EOF: the router process closed its sockets. Its new parent reaps it.
    assert!(
        gone_within(pid, Duration::from_secs(5)),
        "router pid {pid} outlived its killed daemon"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// A long acpmux home (cx-8iw6m: the cmux app trapped on a router socket path
/// past `sun_path`): the router binds the short path of the shared rule, and the
/// daemon reaches it there. A router started by hand answers at that path; the
/// daemon finds it at the same path, stops it (another build: no
/// CMUX_ROUTER_BUILD; no owner FIFO) and starts its own router, which answers
/// there too.
#[test]
fn a_long_home_gets_a_router_that_the_daemon_and_clients_reach() {
    let dir = scratch("rlng");
    let home = long_home(&dir);
    let socket = router_socket(&home);
    assert!(socket.as_os_str().len() <= 103, "{}", socket.display());
    // Ended on every path: a router started by hand has no owner to outlive.
    struct Reaped(Child);
    impl Drop for Reaped {
        fn drop(&mut self) {
            if self.0.try_wait().ok().flatten().is_none() {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
    }
    let mut by_hand = Reaped(
        daemon_env::acpmux(&dir)
            .args(["router", "serve"])
            .env("ACPMUX_HOME", &home)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap(),
    );
    let first = loop {
        if let Ok(stream) = UnixStream::connect(&socket) {
            break stream;
        }
        if let Some(status) = by_hand.0.try_wait().unwrap() {
            let mut stderr = String::new();
            by_hand.0.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();
            panic!(
                "the router exited ({status}) and never answered at {}: {stderr}",
                socket.display()
            );
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    drop(first);
    let first_pid =
        ask_router(&home, json!({"op": "status"}))["pid"].as_u64().expect("status names the pid");
    assert_eq!(first_pid, u64::from(by_hand.0.id()));

    let mut daemon = start_daemon_at(&dir, &home);
    wait_exit(&mut by_hand.0, Duration::from_secs(15));
    let (pid, _held) = router(&home);
    assert_ne!(u64::try_from(pid).unwrap(), first_pid, "the daemon kept the hand-started router");
    assert!(ask_router(&home, json!({"op": "status"}))["port"].as_u64().is_some());

    cli_shutdown_at(&dir, &home, &["--end-agents"]);
    wait_exit(&mut daemon, Duration::from_secs(15));
    assert!(gone_within(pid, Duration::from_secs(10)), "the router outlived its daemon");
    // The short socket is outside the scratch folder.
    let _ = std::fs::remove_file(&socket);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_kept_agent_keeps_its_router_and_the_next_daemon_adopts_it() {
    let dir = scratch("radp");
    let mut first = start_daemon(&dir);
    let (router_pid, _held) = router(&dir);
    let port = ask_router(&dir, json!({"op": "status"}))["port"].as_u64().unwrap();
    // The key a harness holds (a route mints one at spawn).
    let minted = ask_router(
        &dir,
        json!({"op": "mint_key", "scope": {"harness": "fake", "session": "kept", "surfaces": [], "families": ["open_ai_chat"], "expires_at": 0}}),
    );
    let key = minted["key"].as_str().expect("a minted key").to_owned();
    let mut rpc = Rpc::connect(&dir).await;
    let created = rpc.call("session/new", json!({"cwd": dir, "mcpServers": []})).await;
    let session = created["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(rpc.prompt(&session, "hello").await, "echo: hello");
    let record = std::fs::read(dir.join("hosts").join(format!("{session}.json"))).unwrap();
    let record: Value = serde_json::from_slice(&record).unwrap();
    let host_pid = i32::try_from(record["host_pid"].as_i64().unwrap()).unwrap();
    drop(rpc);

    // A restart that keeps the agent: its host holds the router.
    let call = format!("http: http://127.0.0.1:{port}/v1/chat/completions {key}");
    cli_shutdown(&dir, &["--keep-agents"]);
    wait_exit(&mut first, Duration::from_secs(15));
    assert!(alive(host_pid), "--keep-agents ended the agent host");
    assert!(alive(router_pid), "the router stopped while a kept agent still uses it");

    // The next daemon adopts the same router: one router, the same port and keys.
    let mut second = start_daemon(&dir);
    assert_eq!(ask_router(&dir, json!({"op": "status"}))["pid"], json!(router_pid));
    let mut rpc = Rpc::connect(&dir).await;
    let reply = rpc.prompt(&session, &call).await;
    // The relay checked the kept agent's key and answered; with no hosted
    // upstream signed in (the test has no https upstream) that answer is
    // `router.no_upstream`, never 401 (an unknown key) or a refused connection.
    assert!(reply.starts_with("HTTP 503") && reply.contains("router.no_upstream"), "{reply}");
    assert_eq!(ask_router(&dir, json!({"op": "status"}))["pid"], json!(router_pid));
    drop(rpc);

    // Ending every agent ends the router too.
    cli_shutdown(&dir, &["--end-agents"]);
    wait_exit(&mut second, Duration::from_secs(15));
    assert!(gone_within(host_pid, Duration::from_secs(10)), "the agent host outlived the shutdown");
    assert!(gone_within(router_pid, Duration::from_secs(10)), "the router outlived its last agent");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Ended on every path: a router started by hand has no owner to outlive.
struct Reaped(Child);

impl Drop for Reaped {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
}

/// An update with a kept agent: a daemon of this build ran one agent and
/// stopped keeping it (its host still holds the owner FIFO), and the router
/// that runs now is one of an older build on that same owner FIFO. Returns
/// the scratch folder, the kept session, its host pid and the old router.
async fn kept_agent_and_an_older_router(tag: &str) -> (PathBuf, String, i32, Reaped, i32) {
    let dir = scratch(tag);
    let mut first = start_daemon(&dir);
    let (router_pid, _held) = router(&dir);
    let mut rpc = Rpc::connect(&dir).await;
    let created = rpc.call("session/new", json!({"cwd": dir, "mcpServers": []})).await;
    let session = created["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(rpc.prompt(&session, "hello").await, "echo: hello");
    let record = std::fs::read(dir.join("hosts").join(format!("{session}.json"))).unwrap();
    let record: Value = serde_json::from_slice(&record).unwrap();
    let host_pid = i32::try_from(record["host_pid"].as_i64().unwrap()).unwrap();
    drop(rpc);
    cli_shutdown(&dir, &["--keep-agents"]);
    wait_exit(&mut first, Duration::from_secs(15));
    assert!(alive(host_pid), "--keep-agents ended the agent host");
    assert_eq!(ask_router(&dir, json!({"op": "shutdown"}))["stopping"], json!(true));
    assert!(gone_within(router_pid, Duration::from_secs(10)), "the router did not stop");
    let old = Reaped(
        daemon_env::acpmux(&dir)
            .args(["router", "serve"])
            .env("ACPMUX_HOME", &dir)
            .env("CMUX_ROUTER_BUILD", "an-older-build")
            .env("CMUX_ROUTER_OWNER_FIFO", dir.join("router").join("owner.fifo"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let (old_pid, _old_held) = router(&dir);
    assert_eq!(u32::try_from(old_pid).unwrap(), old.0.id());
    assert_eq!(ask_router(&dir, json!({"op": "status"}))["build"], json!("an-older-build"));
    (dir, session, host_pid, old, old_pid)
}

/// cmux issue 23089: after an update, a kept agent that does not use the
/// local router (its own subscription, an API key, the subrouter) must not
/// keep the router of the old build alive forever. The next daemon replaces
/// that router with one of its own build, and the kept agent still answers.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_router_of_another_build_is_replaced_when_no_kept_agent_uses_it() {
    let (dir, session, host_pid, mut old, old_pid) = kept_agent_and_an_older_router("rold").await;
    // The next daemon (this build) replaces it: no kept agent uses it.
    let mut second = start_daemon(&dir);
    let deadline = Instant::now() + Duration::from_secs(15);
    while old.0.try_wait().unwrap().is_none() {
        assert!(
            Instant::now() < deadline,
            "the router of the older build still runs: the new daemon kept it for an agent that never used it"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let (new_pid, _new_held) = router(&dir);
    assert_ne!(new_pid, old_pid);
    let status = ask_router(&dir, json!({"op": "status"}));
    assert_ne!(status["build"], json!("an-older-build"), "{status}");
    assert!(status["port"].as_u64().is_some(), "{status}");

    // Its host said so itself: its record says it does not use the router.
    let record = std::fs::read(dir.join("hosts").join(format!("{session}.json"))).unwrap();
    let record: Value = serde_json::from_slice(&record).unwrap();
    assert_eq!(record["uses_local_router"], json!(false), "{record}");
    // The kept agent was adopted and still answers.
    assert!(alive(host_pid), "replacing the router ended the kept agent host");
    let mut rpc = Rpc::connect(&dir).await;
    assert_eq!(rpc.prompt(&session, "again").await, "echo: again");
    drop(rpc);

    cli_shutdown(&dir, &["--end-agents"]);
    wait_exit(&mut second, Duration::from_secs(15));
    assert!(gone_within(host_pid, Duration::from_secs(10)), "the agent host outlived the shutdown");
    assert!(gone_within(new_pid, Duration::from_secs(10)), "the router outlived its last agent");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A kept agent whose host cannot say it does not use the router (a host
/// of an older build has no `uses_local_router`) keeps the router of the
/// older build: its harness may hold that router's port and key.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_router_of_another_build_stays_for_a_kept_agent_that_may_use_it() {
    let (dir, session, host_pid, mut old, old_pid) = kept_agent_and_an_older_router("rkep").await;
    let path = dir.join("hosts").join(format!("{session}.json"));
    let mut record: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    record.as_object_mut().unwrap().remove("uses_local_router");
    std::fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();

    let mut second = start_daemon(&dir);
    assert!(old.0.try_wait().unwrap().is_none(), "the router a kept agent may use was stopped");
    let status = ask_router(&dir, json!({"op": "status"}));
    assert_eq!(status["pid"], json!(old_pid), "{status}");
    assert_eq!(status["build"], json!("an-older-build"), "{status}");
    let mut rpc = Rpc::connect(&dir).await;
    assert_eq!(rpc.prompt(&session, "again").await, "echo: again");
    drop(rpc);

    cli_shutdown(&dir, &["--end-agents"]);
    wait_exit(&mut second, Duration::from_secs(15));
    assert!(gone_within(host_pid, Duration::from_secs(10)), "the agent host outlived the shutdown");
    // The test started that router, so its exit is reaped here.
    let deadline = Instant::now() + Duration::from_secs(10);
    while old.0.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "the router outlived its last agent");
        std::thread::sleep(Duration::from_millis(20));
    }
    let _ = std::fs::remove_dir_all(&dir);
}
