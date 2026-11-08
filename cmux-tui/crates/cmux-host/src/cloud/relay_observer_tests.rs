//! Who owns a chat's turn (cmuxterm-hq#7086): acpmux runs it, and the relay socket only watches it. A socket that
//! drops or a cmux-host that restarts leaves the turn running, and the next socket sees its end; only a `cancel`
//! from the platform or a revocation (the Relay dropped by a rebind) ends it.
//!
//! A fake acpmux stands in for `cmux-tui`: a shell script that writes each command it ran to `$HOME/ran`, holds a
//! turn until `$HOME/release` exists, answers `new --reuse` for a session that exists with `reused: true` (acpmux
//! `cli/run/standard.rs`), and answers a second `send` with the same prompt id as acpmux does, with the first run's
//! outcome and no reply of its own (acpmux `hub/turns.rs`). `$HOME/reply` holds the first run's reply (default `4`).

use super::*;

const FAKE: &str = r#"#!/bin/sh
shift
[ "$1" = "--json" ] && shift
verb="$1"; shift
case "$verb" in
new) echo "new" >> "$HOME/ran"
  if [ -e "$HOME/turn" ]; then echo '{"sessionId":"relay-c1","reused":true}'; else echo '{"sessionId":"relay-c1"}'; fi ;;
tail) exec sleep 30 ;;
send)
  cat > /dev/null
  if [ -e "$HOME/turn" ]; then echo "send again" >> "$HOME/ran"; reply=""
  else echo "send" >> "$HOME/ran"; : > "$HOME/turn"; reply="$(cat "$HOME/reply" 2>/dev/null || echo 4)"; fi
  while [ ! -e "$HOME/release" ]; do sleep 0.02; done
  echo "{\"sessionId\":\"relay-c1\",\"reply\":\"$reply\",\"stopReason\":\"end_turn\"}" ;;
cancel) echo "cancel $1" >> "$HOME/ran" ;;
last) echo "last" >> "$HOME/ran"; echo '{"sessionId":"relay-c1","replies":["4"]}' ;;
esac
"#;

/// A home with the fake acpmux, and a runner for it as this user.
fn fake() -> (tempfile::TempDir, Runner) {
    use std::os::unix::fs::PermissionsExt as _;
    let home = tempfile::tempdir().unwrap();
    let bin = home.path().join("cmux-tui");
    std::fs::write(&bin, FAKE).unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    // SAFETY: geteuid and getegid have no preconditions.
    let (uid, gid) = unsafe { (libc::geteuid(), libc::getegid()) };
    let runner = Runner {
        bin,
        user: "me".into(),
        uid,
        gid,
        groups: Vec::new(),
        home: home.path().to_path_buf(),
    };
    (home, runner)
}

/// What the fake acpmux ran, in order.
fn ran(home: &tempfile::TempDir) -> Vec<String> {
    std::fs::read_to_string(home.path().join("ran"))
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

fn release(home: &tempfile::TempDir) {
    std::fs::write(home.path().join("release"), "").unwrap();
}

/// Waits up to 10 s for `cond`.
async fn until(what: &str, mut cond: impl FnMut() -> bool) {
    for _ in 0..500 {
        if cond() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("not within 10 s: {what}");
}

fn chat_frame() -> String {
    json!({"v": 1, "t": "chat", "id": "c1", "agent": "claude", "prompt": "What is 2+2?"})
        .to_string()
}

fn wall() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// A local platform end: each dial takes the next socket from `urls`.
struct Local {
    urls: std::collections::VecDeque<String>,
    runner: Runner,
}

impl Dial for Local {
    fn reset_transport(&mut self) {}

    fn serve(
        &mut self,
        rt: &tokio::runtime::Runtime,
        stop: &mut watch::Receiver<bool>,
        link: &mut Link,
        resumes: &mut watch::Receiver<u64>,
        seen: u64,
    ) -> Option<Result<Ended, String>> {
        let Some(url) = self.urls.pop_front() else {
            // No more sockets: wait for the stop.
            rt.block_on(or_stop(stop, std::future::pending::<()>()));
            return None;
        };
        let (_network, mut network) = watch::channel(0u64);
        let dial = Dialing { url: &url, token: "t", network: &mut network, changes: 0 };
        rt.block_on(or_stop(stop, serve(dial, &self.runner, link, resumes, seen, wall)))
    }
}

type Ws = tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>;

/// Accepts the next socket on `listener`.
async fn accept(listener: &tokio::net::TcpListener) -> Ws {
    let (tcp, _) = listener.accept().await.unwrap();
    tokio_tungstenite::accept_async(tcp).await.unwrap()
}

/// The next event of chat c1 on `ws`, skipping pings.
async fn next_event(ws: &mut Ws) -> Value {
    loop {
        let msg = tokio::time::timeout(Duration::from_secs(10), ws.next())
            .await
            .expect("an event within 10 s")
            .expect("the socket is open")
            .unwrap();
        let Message::Text(text) = msg else { continue };
        let v: Value = serde_json::from_str(text.as_str()).unwrap();
        if v["t"] == "event" {
            return v["event"].clone();
        }
    }
}

/// The event of `kind` on `ws`, skipping the others.
async fn event_of(ws: &mut Ws, kind: &str) -> Value {
    loop {
        let e = next_event(ws).await;
        if e["kind"] == kind {
            return e;
        }
    }
}

/// Runs a relay loop on its own thread, as `Relay::spawn` does, over `urls`.
struct Thread {
    stop: watch::Sender<bool>,
    _resume: watch::Sender<u64>,
    detached: Arc<AtomicBool>,
    done: std::thread::JoinHandle<()>,
}

fn relay_thread(urls: Vec<String>, runner: Runner) -> Thread {
    let (stop, mut stopping) = watch::channel(false);
    let (resume, mut resumes) = watch::channel(0u64);
    let detached = Arc::new(AtomicBool::new(false));
    let owned = detached.clone();
    let done = std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let mut dial = Local { urls: urls.into(), runner };
        let (_network, changes) = watch::channel(0u64);
        relay_loop(&rt, &mut dial, |_| {}, &mut stopping, &mut resumes, &changes, owned);
        drop(rt);
    });
    Thread { stop, _resume: resume, detached, done }
}

impl Thread {
    /// A revocation: the Relay dropped (a rebind).
    fn revoke(self) {
        self.stop.send_replace(true);
        self.done.join().unwrap();
    }

    /// cmux-host shutting down: [`Relay::detach`].
    fn detach(self) {
        self.detached.store(true, Ordering::SeqCst);
        self.stop.send_replace(true);
        self.done.join().unwrap();
    }
}

#[test]
fn a_socket_drop_mid_turn_leaves_the_turn_running_and_the_next_socket_sees_its_end() {
    let (home, runner) = fake();
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    rt.block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}/relay", listener.local_addr().unwrap());
        let relay = relay_thread(vec![url.clone(), url], runner);
        let mut first = accept(&listener).await;
        first.send(Message::text(chat_frame())).await.unwrap();
        assert_eq!(event_of(&mut first, "started").await["session"], "relay-c1");
        until("the prompt went in", || ran(&home).contains(&"send".to_owned())).await;
        // The socket drops mid-turn, with no close.
        drop(first);
        let mut second = accept(&listener).await;
        // The platform sends the chat it was waiting on again: the running chat answers it, once.
        second.send(Message::text(chat_frame())).await.unwrap();
        release(&home);
        let done = event_of(&mut second, "done").await;
        assert_eq!(done["reply"], "4", "{done}");
        assert_eq!(ran(&home), ["new", "send"], "no cancel, and the prompt went in once");
        relay.revoke();
    });
}

#[test]
fn a_cancel_from_the_platform_ends_the_turn() {
    let (home, runner) = fake();
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    rt.block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}/relay", listener.local_addr().unwrap());
        let relay = relay_thread(vec![url], runner);
        let mut ws = accept(&listener).await;
        ws.send(Message::text(chat_frame())).await.unwrap();
        event_of(&mut ws, "started").await;
        until("the prompt went in", || ran(&home).contains(&"send".to_owned())).await;
        ws.send(Message::text(json!({"v": 1, "t": "cancel", "id": "c1"}).to_string()))
            .await
            .unwrap();
        until("the turn is cancelled", || ran(&home).contains(&"cancel relay-c1".to_owned())).await;
        relay.revoke();
    });
}

#[test]
fn a_revocation_ends_the_turn() {
    let (home, runner) = fake();
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    rt.block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}/relay", listener.local_addr().unwrap());
        let relay = relay_thread(vec![url], runner);
        let mut ws = accept(&listener).await;
        ws.send(Message::text(chat_frame())).await.unwrap();
        event_of(&mut ws, "started").await;
        until("the prompt went in", || ran(&home).contains(&"send".to_owned())).await;
        // A rebind drops the Relay.
        relay.revoke();
        until("the turn is cancelled", || ran(&home).contains(&"cancel relay-c1".to_owned())).await;
    });
}

#[test]
fn a_host_restart_leaves_the_turn_running_and_the_next_host_reattaches() {
    let (home, runner) = fake();
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    rt.block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}/relay", listener.local_addr().unwrap());
        let before = relay_thread(vec![url.clone()], runner.clone());
        let mut ws = accept(&listener).await;
        ws.send(Message::text(chat_frame())).await.unwrap();
        event_of(&mut ws, "started").await;
        until("the prompt went in", || ran(&home).contains(&"send".to_owned())).await;
        // cmux-host stops for its restart: no cancel, the turn runs on in acpmux.
        before.detach();
        drop(ws);
        // A moment for a cancel that should not come.
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(ran(&home), ["new", "send"], "the restart cancelled the turn");
        // The next cmux-host: the platform sends the chat again, and it reattaches to the same turn.
        let after = relay_thread(vec![url], runner);
        let mut ws = accept(&listener).await;
        ws.send(Message::text(chat_frame())).await.unwrap();
        assert_eq!(event_of(&mut ws, "started").await["session"], "relay-c1");
        release(&home);
        let done = event_of(&mut ws, "done").await;
        assert_eq!(done["reply"], "4", "the first run's reply: {done}");
        let ran = ran(&home);
        assert!(!ran.iter().any(|r| r.starts_with("cancel")), "{ran:?}");
        assert_eq!(ran.iter().filter(|r| *r == "send").count(), 1, "the prompt ran once: {ran:?}");
        after.revoke();
    });
}

#[test]
fn a_fresh_turn_with_no_reply_never_takes_an_older_reply() {
    // Only a reattached chat (its session reused) reads `acp last`: a new turn that ends with no reply stays empty.
    let (home, runner) = fake();
    std::fs::write(home.path().join("reply"), "").unwrap();
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    rt.block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}/relay", listener.local_addr().unwrap());
        let relay = relay_thread(vec![url], runner);
        let mut ws = accept(&listener).await;
        ws.send(Message::text(chat_frame())).await.unwrap();
        event_of(&mut ws, "started").await;
        release(&home);
        let done = event_of(&mut ws, "done").await;
        assert_eq!(done["reply"], "", "{done}");
        assert_eq!(ran(&home), ["new", "send"], "no `acp last` for a new turn");
        relay.revoke();
    });
}
