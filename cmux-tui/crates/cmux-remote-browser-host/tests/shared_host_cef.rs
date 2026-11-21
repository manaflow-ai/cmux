//! Crash test of the shared remote browser host against the real CEF host
//! (cmuxterm-hq docs/design/process-sharing.md, "Remote and phone browser
//! tabs"; Leo approved one host for all remote tabs, not one cookie jar).
//! macOS, on the fleet (scripts/ci/cmux-remote-browser-host-build.sh runs it
//! with CEF_PATH set):
//!
//! - three remote tabs run in one host pid, and their cookie jars are
//!   separate: a cookie one tab sets is absent in the other two;
//! - a viewer's hello token picks its tab, and a wrong token is refused;
//! - SIGKILL the host by pid: every tab comes back in a new host at its last
//!   URL within a bound, and tabs lost = 0.
#![cfg(target_os = "macos")]

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

use cmux_rd_proto::control::Control as RdControl;
use cmux_rd_proto::{STREAM_CONTROL, StreamDeframer, encode_stream_frame};
use serde_json::{Value, json};

/// How long a tab may take to come back in a new host (a cold CEF start
/// plus the page loads).
const BACK_WITHIN: Duration = Duration::from_secs(30);

#[path = "common/bundle.rs"]
mod common_bundle;
use common_bundle::bundle;

/// What the test page server saw: each tab's requests with their cookie.
#[derive(Default)]
struct Seen {
    /// (tab, path, cookie header)
    requests: Vec<(String, String, String)>,
}

/// A loopback HTTP server: `/set?tab=T` sets a persistent cookie and
/// redirects to `/check?tab=T`; `/check?tab=T` records the cookie it got.
fn serve_pages(seen: Arc<(Mutex<Seen>, std::sync::Condvar)>) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for conn in listener.incoming() {
            let Ok(mut conn) = conn else { continue };
            let seen = seen.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(conn.try_clone().unwrap());
                let mut first = String::new();
                if reader.read_line(&mut first).is_err() {
                    return;
                }
                let mut cookie = String::new();
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                        break;
                    }
                    if let Some(v) =
                        line.strip_prefix("Cookie:").or_else(|| line.strip_prefix("cookie:"))
                    {
                        cookie = v.trim().to_string();
                    }
                }
                let path = first.split_whitespace().nth(1).unwrap_or("/").to_string();
                let tab = path.split("tab=").nth(1).unwrap_or("").to_string();
                let body = format!("<html><title>{tab}</title><body>{tab}</body></html>");
                let head = if path.starts_with("/set") {
                    format!(
                        "HTTP/1.1 302 Found\r\nSet-Cookie: rbtest={tab}; Path=/; Max-Age=3600\r\n\
                         Location: /check?tab={tab}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    )
                } else {
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\n\
                         Cache-Control: no-store\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    )
                };
                let _ = conn.write_all(head.as_bytes());
                if !path.starts_with("/favicon") {
                    let (lock, cv) = &*seen;
                    lock.lock().unwrap().requests.push((tab, path, cookie));
                    cv.notify_all();
                }
            });
        }
    });
    port
}

fn wait_seen(
    seen: &Arc<(Mutex<Seen>, std::sync::Condvar)>,
    what: &str,
    within: Duration,
    pred: impl Fn(&Seen) -> bool,
) {
    let (lock, cv) = &**seen;
    let until = Instant::now() + within;
    let mut guard = lock.lock().unwrap();
    while !pred(&guard) {
        let left = until.saturating_duration_since(Instant::now());
        assert!(!left.is_zero(), "the page server never saw {what}: {:?}", guard.requests);
        guard = cv.wait_timeout(guard, left).unwrap().0;
    }
}

struct Sup {
    child: Child,
    stdin: Option<std::process::ChildStdin>,
    lines: mpsc::Receiver<Value>,
    /// Every host pid the supervisor started, in order.
    hosts: std::cell::RefCell<Vec<u64>>,
    /// Lines no `next` took yet.
    seen: std::cell::RefCell<Vec<Value>>,
}

impl Sup {
    fn send(&mut self, v: Value) {
        let stdin = self.stdin.as_mut().unwrap();
        writeln!(stdin, "{v}").unwrap();
        stdin.flush().unwrap();
    }

    /// The first line, seen or still to come, that `pred` accepts. Lines it
    /// skips stay for a later call: the supervisor's lines for different
    /// tabs arrive in any order.
    fn next(&self, what: &str, within: Duration, pred: impl Fn(&Value) -> bool) -> Value {
        let mut seen = self.seen.borrow_mut();
        if let Some(i) = seen.iter().position(&pred) {
            return seen.remove(i);
        }
        let until = Instant::now() + within;
        loop {
            match self.lines.recv_timeout(until.saturating_duration_since(Instant::now())) {
                Ok(v) => {
                    if let Some(pid) = v["host"]["pid"].as_u64() {
                        self.hosts.borrow_mut().push(pid);
                    }
                    if pred(&v) {
                        return v;
                    }
                    seen.push(v);
                }
                Err(_) => panic!("the supervisor never said {what}"),
            }
        }
    }
}

impl Drop for Sup {
    fn drop(&mut self) {
        // The lifeline: the supervisor stops its host and quits.
        drop(self.stdin.take());
        if std::thread::panicking() {
            // A failed run may hold a process that never reads its lifeline.
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
    }
}

fn start(host: &Path, root: &Path) -> Sup {
    let mut child = Command::new(host)
        .args(["--supervise"])
        .env("CMUX_RB_CACHE_DIR", root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("supervisor");
    let out = child.stdout.take().unwrap();
    let stdin = child.stdin.take();
    let (tx, lines) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(out).lines().map_while(Result::ok) {
            if let Ok(v) = serde_json::from_str::<Value>(&line) {
                eprintln!("supervisor: {v}");
                let _ = tx.send(v);
            }
        }
    });
    Sup { child, stdin, lines, hosts: Default::default(), seen: Default::default() }
}

fn hello(token: &str) -> Vec<u8> {
    let hello: RdControl = serde_json::from_value(json!({
        "t": "hello", "user": "u", "install": "i", "class": "c", "interactive": true,
        "udp_port": null, "max_datagram": 1200, "token": token, "service": "rb/1",
        "caps": ["input.service"],
    }))
    .expect("hello");
    let mut out = Vec::new();
    encode_stream_frame(STREAM_CONTROL, &serde_json::to_vec(&hello).unwrap(), &mut out).unwrap();
    out
}

/// The host's first rd control reply to a hello with `token`.
fn first_reply(port: u16, token: &str) -> RdControl {
    let mut s = TcpStream::connect(("127.0.0.1", port)).expect("connect");
    s.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    s.write_all(&hello(token)).unwrap();
    let mut deframer = StreamDeframer::default();
    let mut buf = [0u8; 4096];
    loop {
        if let Ok(Some((kind, payload))) = deframer.next_frame()
            && kind == STREAM_CONTROL
        {
            return serde_json::from_slice(&payload).expect("control");
        }
        let n = s.read(&mut buf).expect("read");
        assert!(n > 0, "the host closed before replying");
        deframer.extend(&buf[..n]);
    }
}

fn host_pid(v: &Value) -> u64 {
    v["host"]["pid"].as_u64().unwrap()
}

#[test]
fn three_remote_tabs_share_one_host_keep_their_own_cookies_and_survive_its_sigkill() {
    let dir = std::env::temp_dir().join(format!("rb-shared-cef-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let host = bundle(&dir);
    let seen = Arc::new((Mutex::new(Seen::default()), std::sync::Condvar::new()));
    let pages = serve_pages(seen.clone());
    let mut sup = start(&host, &dir.join("cache"));
    let listening =
        sup.next("listening", Duration::from_secs(20), |v| v.get("listening").is_some());
    let port: u16 =
        listening["listening"].as_str().unwrap().rsplit(':').next().unwrap().parse().unwrap();

    // Tab a sets its cookie first; b and c open after it is set.
    let url = |path: &str, tab: &str| format!("http://127.0.0.1:{pages}/{path}?tab={tab}");
    sup.send(json!({"open": {"tab": "a", "url": url("set", "a")}}));
    let first_host = sup.next("the host", Duration::from_secs(10), |v| v.get("host").is_some());
    let pid = host_pid(&first_host);
    wait_seen(&seen, "tab a's cookie come back", Duration::from_secs(60), |s| {
        s.requests
            .iter()
            .any(|(t, p, c)| t == "a" && p.starts_with("/check") && c.contains("rbtest=a"))
    });
    sup.send(json!({"open": {"tab": "b", "url": url("check", "b")}}));
    sup.send(json!({"open": {"tab": "c", "url": url("check", "c")}}));
    let mut tokens = BTreeMap::new();
    for id in ["a", "b", "c"] {
        let reply = sup.next("a tab's token", Duration::from_secs(30), |v| {
            v["tab"] == id && v.get("token").is_some()
        });
        tokens.insert(id, reply["token"].as_str().unwrap().to_string());
    }
    wait_seen(&seen, "tabs b and c load", Duration::from_secs(30), |s| {
        ["b", "c"].iter().all(|id| s.requests.iter().any(|(t, _, _)| t == id))
    });
    {
        let s = seen.0.lock().unwrap();
        for (t, p, c) in &s.requests {
            if t != "a" {
                assert!(!c.contains("rbtest"), "tab {t} got tab a's cookie at {p}: {c}");
            }
        }
    }
    // No second host started: one pid serves the three tabs.
    while let Ok(v) = sup.lines.try_recv() {
        if let Some(p) = v["host"]["pid"].as_u64() {
            sup.hosts.borrow_mut().push(p);
        }
    }
    assert_eq!(*sup.hosts.borrow(), vec![pid], "two tabs, one host pid");
    // Each tab's profile is on disk in its own directory. CEF falls back to
    // an in-memory profile, which loses the cookies a restart keeps, when a
    // tab's cache path is not directly under the root it resolved (/tmp is
    // /private/tmp on macOS). Tab directories are looked for one and two
    // levels down, so an old layout (`tabs/N`) counts too.
    let cache = dir.join("cache");
    let tab_dirs = |at: &Path| -> Vec<std::path::PathBuf> {
        std::fs::read_dir(at)
            .map(|d| d.filter_map(Result::ok).map(|e| e.path()).filter(|p| p.is_dir()).collect())
            .unwrap_or_default()
    };
    let on_disk = tab_dirs(&cache)
        .into_iter()
        .flat_map(|p| if p.ends_with("tabs") { tab_dirs(&p) } else { vec![p] })
        // Chrome's own directories in the root (Crashpad, caches) are not tabs.
        .filter(|p| {
            p.parent().is_some_and(|d| d.ends_with("tabs"))
                || p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("tab-"))
        })
        .filter(|p| std::fs::read_dir(p).is_ok_and(|mut d| d.next().is_some()))
        .count();
    assert!(on_disk >= 3, "{on_disk} of 3 tab profiles are on disk");
    // A viewer's token picks its tab; a wrong token is refused.
    assert!(matches!(first_reply(port, &tokens["b"]), RdControl::Welcome { .. }));
    assert!(matches!(first_reply(port, &"0".repeat(64)), RdControl::Refused { .. }));

    // SIGKILL the host by pid.
    let before = seen.0.lock().unwrap().requests.len();
    let killed = Instant::now();
    assert!(Command::new("kill").args(["-KILL", &pid.to_string()]).status().unwrap().success());
    let next = sup.next("a new host", BACK_WITHIN, |v| v.get("host").is_some());
    assert_ne!(host_pid(&next), pid);
    for id in ["a", "b", "c"] {
        let left = BACK_WITHIN.saturating_sub(killed.elapsed());
        sup.next("the tab reopened", left, |v| v["tab"] == id && v.get("reopened").is_some());
    }
    // Every page loads again, at its last URL (a redirected to /check).
    wait_seen(&seen, "every tab reload", BACK_WITHIN.saturating_sub(killed.elapsed()), |s| {
        let after = &s.requests[before..];
        ["a", "b", "c"]
            .iter()
            .all(|id| after.iter().any(|(t, p, _)| t == id && p.starts_with("/check")))
    });
    let back = killed.elapsed();
    {
        let s = seen.0.lock().unwrap();
        for (t, p, c) in &s.requests[before..] {
            assert!(!p.starts_with("/set"), "tab {t} reloaded its first URL, not its last");
            if t != "a" {
                assert!(!c.contains("rbtest"), "tab {t} got tab a's cookie after the restart");
            }
        }
    }
    assert!(
        matches!(first_reply(port, &tokens["c"]), RdControl::Welcome { .. }),
        "same port, same token"
    );
    eprintln!("RB-SHARED-CRASH tabs=3 lost=0 back_ms={}", back.as_millis());
    drop(sup);
    let _ = std::fs::remove_dir_all(&dir);
}
