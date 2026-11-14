use super::*;
use std::fs;

fn fast() -> Backoff {
    Backoff {
        min: Duration::from_millis(20),
        max: Duration::from_millis(80),
        healthy: Duration::from_secs(5),
    }
}

/// A fake browser: appends its pid to `log`, then runs `then`.
fn fake(log: &std::path::Path, then: &str) -> BrowserCommand {
    BrowserCommand {
        program: "/bin/sh".into(),
        args: vec!["-c".into(), format!("echo $$ >> '{}'; {then}", log.display())],
        env: vec![("DISPLAY".into(), ":99".into())],
    }
}

fn wait_until(what: &str, f: impl Fn() -> bool) {
    let t0 = Instant::now();
    while !f() {
        assert!(t0.elapsed() < Duration::from_secs(30), "timed out waiting for {what}");
        // Test-only wait for real child processes; the code under test uses no polling.
        thread::sleep(Duration::from_millis(10));
    }
}

fn alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

#[test]
fn a_crashed_browser_is_restarted_and_the_session_survives() {
    let dir = std::env::temp_dir().join(format!("cmux-rd-browser-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let log = dir.join("starts");
    let _ = fs::remove_file(&log);
    let sup = BrowserSupervisor::start(fake(&log, "exec sleep 30"), fast()).expect("start");
    wait_until("first start", || fs::read_to_string(&log).unwrap_or_default().lines().count() == 1);
    let first = sup.pid();
    assert_eq!(sup.starts(), 1);
    // The browser crashes (or a person quits it): the supervisor starts a new one.
    unsafe { libc::kill(first as libc::pid_t, libc::SIGKILL) };
    wait_until("restart", || sup.starts() == 2 && sup.pid() != 0 && sup.pid() != first);
    let second = sup.pid();
    assert!(alive(second));
    wait_until("second browser running", || {
        fs::read_to_string(&log).unwrap_or_default().lines().count() == 2
    });
    drop(sup);
    // Stopping the host stops the browser and starts no other.
    wait_until("browser stopped", || !alive(second));
    let lines = fs::read_to_string(&log).unwrap().lines().count();
    assert_eq!(lines, 2, "exactly two browser starts");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn a_browser_that_keeps_crashing_backs_off() {
    let dir = std::env::temp_dir().join(format!("cmux-rd-browser-crash-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let log = dir.join("starts");
    let _ = fs::remove_file(&log);
    let sup = BrowserSupervisor::start(fake(&log, "exit 1"), fast()).expect("start");
    // 20 + 40 + 80 + 80 ms of delay after the first start: 5 starts take at least 220 ms.
    let t0 = Instant::now();
    wait_until("five starts", || sup.starts() >= 5);
    assert!(
        t0.elapsed() >= Duration::from_millis(200),
        "restarts did not back off: {:?}",
        t0.elapsed()
    );
    drop(sup);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn a_missing_browser_is_a_start_error() {
    let cmd = BrowserCommand { program: "/nonexistent/chrome".into(), args: vec![], env: vec![] };
    assert!(BrowserSupervisor::start(cmd, fast()).is_err());
}

/// Real Chrome, real CDP: an agent on the host drives the page the person watches.
/// Needs Google Chrome and Xvfb (the cloud browser VM image); run on a Linux VM with
/// `cargo test -- --ignored cdp`. `CMUX_RD_TEST_CHROME` names another Chrome binary.
#[test]
#[ignore = "needs Google Chrome and Xvfb; run with --ignored on a Linux VM"]
fn cdp_an_agent_drives_the_cloud_browser_on_loopback_only() {
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream, UdpSocket};

    let chrome = std::env::var("CMUX_RD_TEST_CHROME").unwrap_or_else(|_| "google-chrome".into());
    let display = format!(":{}", 50 + std::process::id() % 40);
    let mut xvfb = std::process::Command::new("Xvfb")
        .args([display.as_str(), "-screen", "0", "1280x800x24", "-nolisten", "tcp"])
        .spawn()
        .expect("Xvfb");
    let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let dir = std::env::temp_dir().join(format!("cmux-rd-cdp-{}", std::process::id()));
    let cmd =
        BrowserCommand::chrome(&chrome, &display, "about:blank", 1280, 800, &dir.to_string_lossy())
            .with_cdp_port(port);
    let sup = BrowserSupervisor::start(cmd, fast()).expect("start chrome");

    let http = |method: &str, path: &str| -> Option<String> {
        let mut s = TcpStream::connect(("127.0.0.1", port)).ok()?;
        s.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
        write!(s, "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n").ok()?;
        // Chrome may keep the connection open: read the head, then Content-Length bytes.
        let mut buf = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            let n = s.read(&mut chunk).ok()?;
            if n == 0 {
                return None;
            }
            buf.extend_from_slice(&chunk[..n]);
            let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") else { continue };
            let head = String::from_utf8_lossy(&buf[..end]).to_ascii_lowercase();
            let len: usize = head
                .lines()
                .find_map(|l| l.strip_prefix("content-length:"))
                .and_then(|v| v.trim().parse().ok())?;
            if buf.len() >= end + 4 + len {
                return Some(String::from_utf8_lossy(&buf[end + 4..end + 4 + len]).into_owned());
            }
        }
    };
    let pages = || -> Vec<serde_json::Value> {
        http("GET", "/json/list")
            .and_then(|b| serde_json::from_str::<Vec<serde_json::Value>>(&b).ok())
            .unwrap_or_default()
            .into_iter()
            .filter(|t| t["type"] == "page")
            .collect()
    };
    wait_until("CDP answers on the cdp port", || !pages().is_empty());

    // Drive the page over the DevTools WebSocket: run script in it and read the result.
    let ws_url = pages()[0]["webSocketDebuggerUrl"].as_str().expect("ws url").to_string();
    let path = &ws_url[ws_url.find("/devtools/").expect("devtools path")..];
    let mut ws = TcpStream::connect(("127.0.0.1", port)).unwrap();
    ws.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    write!(
            ws,
            "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
             Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        .unwrap();
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        ws.read_exact(&mut byte).unwrap();
        head.push(byte[0]);
    }
    assert!(String::from_utf8_lossy(&head).starts_with("HTTP/1.1 101"), "no WebSocket upgrade");
    let call = serde_json::json!({
        "id": 1, "method": "Runtime.evaluate",
        "params": {"expression": "document.title = 'driven by cdp'; 6 * 7", "returnByValue": true}
    })
    .to_string();
    // One masked text frame (clients must mask; mask 0 keeps the payload as is).
    let mut frame = vec![0x81u8];
    let n = call.len();
    if n < 126 {
        frame.push(0x80 | n as u8);
    } else {
        frame.push(0x80 | 126);
        frame.extend_from_slice(&(n as u16).to_be_bytes());
    }
    frame.extend_from_slice(&[0, 0, 0, 0]);
    frame.extend_from_slice(call.as_bytes());
    ws.write_all(&frame).unwrap();
    let reply = loop {
        let mut h = [0u8; 2];
        ws.read_exact(&mut h).unwrap();
        let mut len = u64::from(h[1] & 0x7f);
        if len == 126 {
            let mut b = [0u8; 2];
            ws.read_exact(&mut b).unwrap();
            len = u64::from(u16::from_be_bytes(b));
        } else if len == 127 {
            let mut b = [0u8; 8];
            ws.read_exact(&mut b).unwrap();
            len = u64::from_be_bytes(b);
        }
        let mut body = vec![0u8; len as usize];
        ws.read_exact(&mut body).unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap_or_default();
        if v["id"] == 1 {
            break v;
        }
    };
    assert_eq!(reply["result"]["result"]["value"], 42, "CDP reply: {reply}");
    wait_until("the page title the agent set", || {
        pages().iter().any(|p| p["title"] == "driven by cdp")
    });

    // Loopback only: the port is not reachable on the machine's network address.
    let probe = UdpSocket::bind("0.0.0.0:0").unwrap();
    if probe.connect("1.1.1.1:53").is_ok() {
        let ip = probe.local_addr().unwrap().ip();
        if !ip.is_loopback() && !ip.is_unspecified() {
            assert!(
                TcpStream::connect_timeout(&(ip, port).into(), Duration::from_secs(2)).is_err(),
                "CDP port {port} answered on {ip}"
            );
        }
    }

    drop(ws);
    drop(sup);
    let _ = xvfb.kill();
    let _ = xvfb.wait();
    let _ = fs::remove_dir_all(&dir);
}
