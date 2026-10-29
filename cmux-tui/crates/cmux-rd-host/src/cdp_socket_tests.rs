//! Tests for the owner-only CDP socket (cdp_socket.rs). A fake browser pipe (a socketpair)
//! stands in for Chrome's fds 3 and 4.

use super::*;
use std::fs;
use std::io::{Read, Write};
use std::os::fd::OwnedFd;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::time::{Duration, Instant};

/// A new directory under /tmp (short paths fit sun_path), removed on drop.
struct Dir(PathBuf);

impl Dir {
    fn new(tag: &str, mode: u32) -> Self {
        static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let path = PathBuf::from(format!("/tmp/rdcdp-{tag}-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
        Self(path)
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = fs::set_permissions(&self.0, fs::Permissions::from_mode(0o700));
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The test's side of a fake browser: what the bridge writes to "Chrome" arrives on
/// `from_host`; what the test writes to `to_host` is what "Chrome" sends.
struct FakeBrowser {
    from_host: UnixStream,
    to_host: UnixStream,
}

fn fake_browser() -> (BrowserPipe, FakeBrowser) {
    let (to_browser, from_host) = UnixStream::pair().unwrap();
    let (from_browser, to_host) = UnixStream::pair().unwrap();
    for s in [&from_host, &to_host] {
        s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    }
    let pipe = BrowserPipe {
        to_browser: File::from(OwnedFd::from(to_browser)),
        from_browser: File::from(OwnedFd::from(from_browser)),
    };
    (pipe, FakeBrowser { from_host, to_host })
}

/// Reads one NUL-terminated message; None when the stream ends or fails first.
fn read_msg(s: &mut UnixStream) -> Option<String> {
    let mut out = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        match s.read(&mut byte) {
            Ok(1) if byte[0] == 0 => return Some(String::from_utf8(out).unwrap()),
            Ok(1) => out.push(byte[0]),
            _ => return None,
        }
    }
}

fn connect(path: &Path) -> UnixStream {
    let s = UnixStream::connect(path).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    s
}

/// True when the bridge closed `s` within 5 s (a read ends, or fails as the peer reset it).
fn closed_by_host(s: &mut UnixStream) -> bool {
    closed_within(s, Duration::from_secs(5))
}

/// True when the bridge closed `s` within `wait`; a client still open then counts as served.
fn closed_within(s: &mut UnixStream, wait: Duration) -> bool {
    s.set_read_timeout(Some(wait)).unwrap();
    let mut byte = [0u8; 1];
    let closed = match s.read(&mut byte) {
        Ok(0) => true,
        Ok(_) => false,
        Err(e) => !matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut),
    };
    s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    closed
}

/// A client that the bridge serves: one message reaches the fake browser.
fn served(client: &mut UnixStream, browser: &mut FakeBrowser, id: u32) {
    client.write_all(format!("{{\"id\":{id}}}\0").as_bytes()).unwrap();
    assert_eq!(
        read_msg(&mut browser.from_host).as_deref(),
        Some(format!("{{\"id\":{id}}}").as_str())
    );
}

#[test]
fn the_cdp_socket_is_owner_only_in_a_private_directory() {
    let dir = Dir::new("mode", 0o700);
    let path = dir.0.join("cdp.sock");
    let _listener = bind_owner_only(&path).expect("bind in a private directory");
    let meta = fs::symlink_metadata(&path).unwrap();
    assert!(meta.file_type().is_socket(), "{path:?} is not a socket");
    assert_eq!(meta.permissions().mode() & 0o777, 0o600, "socket mode");
    // The 0700 staging directory is gone: only the socket is left.
    let names: Vec<_> = fs::read_dir(&dir.0).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert_eq!(names, vec![std::ffi::OsString::from("cdp.sock")]);
}

#[test]
fn the_cdp_socket_refuses_a_parent_another_user_can_write() {
    for mode in [0o777, 0o1777, 0o770, 0o722] {
        let dir = Dir::new("shared", mode);
        let path = dir.0.join("cdp.sock");
        let err = bind_owner_only(&path).expect_err(&format!("bind in a {mode:o} directory"));
        assert_eq!(err.kind(), io::ErrorKind::PermissionDenied, "mode {mode:o}: {err}");
        assert!(fs::symlink_metadata(&path).is_err(), "mode {mode:o}: the socket was created");
        assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 0, "mode {mode:o}: files were left");
    }
}

#[test]
fn a_live_cdp_socket_is_not_replaced_and_a_stale_one_is() {
    let dir = Dir::new("live", 0o700);
    let path = dir.0.join("cdp.sock");
    let first = bind_owner_only(&path).unwrap();
    let err = bind_owner_only(&path).expect_err("a second server on a live socket");
    assert_eq!(err.kind(), io::ErrorKind::AddrInUse, "{err}");
    drop(first);
    // The first server is gone (its file stays): a new one takes the path.
    let _second = bind_owner_only(&path).expect("replace a stale socket");
    // A path that is not a socket is never replaced.
    let file = dir.0.join("not-a-socket");
    fs::write(&file, b"x").unwrap();
    assert!(bind_owner_only(&file).is_err());
    assert_eq!(fs::read(&file).unwrap(), b"x");
}

#[test]
fn the_peer_check_admits_only_the_hosts_uid() {
    assert!(peer_allowed(1000, 1000));
    assert!(!peer_allowed(1001, 1000));
    // Root is another user too: the host serves only its own uid.
    assert!(!peer_allowed(0, 1000));
    let (a, _b) = UnixStream::pair().unwrap();
    assert_eq!(peer_uid(&a).unwrap(), host_uid());
}

#[test]
fn a_client_of_another_uid_is_refused() {
    let dir = Dir::new("uid", 0o700);
    let path = dir.0.join("cdp.sock");
    // The bridge serves uid + 1: this process is "another user" to it.
    let bridge = CdpBridge::serve_for_uid(&path, host_uid().wrapping_add(1)).unwrap();
    let (pipe, mut browser) = fake_browser();
    bridge.attach(pipe);
    let mut client = connect(&path);
    let _ = client.write_all(b"{\"id\":1}\0");
    assert!(closed_by_host(&mut client), "a client of another uid was served");
    browser.from_host.set_read_timeout(Some(Duration::from_millis(300))).unwrap();
    assert_eq!(
        read_msg(&mut browser.from_host),
        None,
        "a refused client's message reached the browser"
    );
}

#[test]
fn the_bridge_forwards_one_nul_framed_message_each_way() {
    let dir = Dir::new("fwd", 0o700);
    let path = dir.0.join("cdp.sock");
    let bridge = CdpBridge::serve(&path).unwrap();
    let (pipe, mut browser) = fake_browser();
    bridge.attach(pipe);
    let mut client = connect(&path);
    served(&mut client, &mut browser, 1);
    browser.to_host.write_all(b"{\"id\":1,\"result\":{}}\0").unwrap();
    assert_eq!(read_msg(&mut client).as_deref(), Some("{\"id\":1,\"result\":{}}"));
    // A message the browser writes in pieces reaches the client whole.
    browser.to_host.write_all(b"{\"method\":").unwrap();
    browser.to_host.write_all(b"\"Page.loadEventFired\"}\0").unwrap();
    assert_eq!(read_msg(&mut client).as_deref(), Some("{\"method\":\"Page.loadEventFired\"}"));
}

#[test]
fn a_second_client_is_refused_while_one_is_connected() {
    let dir = Dir::new("two", 0o700);
    let path = dir.0.join("cdp.sock");
    let bridge = CdpBridge::serve(&path).unwrap();
    let (pipe, mut browser) = fake_browser();
    bridge.attach(pipe);
    let mut first = connect(&path);
    served(&mut first, &mut browser, 1);
    let mut second = connect(&path);
    assert!(closed_by_host(&mut second), "a second client was served");
    // The first client keeps working; once it leaves, a new client is served.
    served(&mut first, &mut browser, 2);
    drop(first);
    let t0 = Instant::now();
    let mut third = loop {
        let mut c = connect(&path);
        if c.write_all(b"{\"id\":3}\0").is_ok() {
            browser.from_host.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
            if read_msg(&mut browser.from_host).as_deref() == Some("{\"id\":3}") {
                break c;
            }
        }
        assert!(t0.elapsed() < Duration::from_secs(10), "no client served after the first left");
    };
    browser.to_host.write_all(b"{\"id\":3,\"result\":{}}\0").unwrap();
    assert_eq!(read_msg(&mut third).as_deref(), Some("{\"id\":3,\"result\":{}}"));
}

#[test]
fn a_client_that_drops_mid_message_leaves_nothing_in_the_pipe() {
    let dir = Dir::new("part", 0o700);
    let path = dir.0.join("cdp.sock");
    let bridge = CdpBridge::serve(&path).unwrap();
    let (pipe, mut browser) = fake_browser();
    bridge.attach(pipe);
    let mut first = connect(&path);
    first.write_all(b"{\"id\":1,\"method\":\"Runtime.eval").unwrap();
    drop(first);
    let t0 = Instant::now();
    let mut next = loop {
        let mut c = connect(&path);
        if c.write_all(b"{\"id\":2}\0").is_ok()
            && !closed_within(&mut c, Duration::from_millis(200))
        {
            break c;
        }
        assert!(t0.elapsed() < Duration::from_secs(10), "no client served after the first left");
    };
    // The browser sees exactly the second client's message: no fragment before it.
    assert_eq!(read_msg(&mut browser.from_host).as_deref(), Some("{\"id\":2}"));
    browser.to_host.write_all(b"{\"id\":2,\"result\":{}}\0").unwrap();
    assert_eq!(read_msg(&mut next).as_deref(), Some("{\"id\":2,\"result\":{}}"));
}

#[test]
fn a_new_browser_closes_the_connected_client() {
    let dir = Dir::new("gen", 0o700);
    let path = dir.0.join("cdp.sock");
    let bridge = CdpBridge::serve(&path).unwrap();
    let (pipe, mut first_browser) = fake_browser();
    bridge.attach(pipe);
    let mut client = connect(&path);
    served(&mut client, &mut first_browser, 1);
    // The supervisor restarted the browser: the client of the old one is closed.
    let (pipe, mut second_browser) = fake_browser();
    bridge.attach(pipe);
    assert!(closed_by_host(&mut client), "a client survived a browser restart");
    // A late message from the old browser reaches nobody; a new client reaches the new one.
    let _ = first_browser.to_host.write_all(b"{\"id\":1,\"result\":{}}\0");
    let mut fresh = connect(&path);
    served(&mut fresh, &mut second_browser, 7);
    second_browser.to_host.write_all(b"{\"id\":7,\"result\":{}}\0").unwrap();
    assert_eq!(read_msg(&mut fresh).as_deref(), Some("{\"id\":7,\"result\":{}}"));
}

#[test]
fn dropping_the_bridge_removes_its_socket() {
    let dir = Dir::new("drop", 0o700);
    let path = dir.0.join("cdp.sock");
    let bridge = CdpBridge::serve(&path).unwrap();
    assert!(path.exists());
    drop(bridge);
    assert!(fs::symlink_metadata(&path).is_err(), "the socket file stayed");
}

#[test]
fn a_browser_message_over_the_limit_is_dropped_and_the_next_one_still_reads() {
    let mut input = io::Cursor::new(b"0123456789\0ok\0".to_vec());
    let mut buf = Vec::new();
    // Over the 4-byte limit: skipped whole, never buffered past the limit.
    assert_eq!(next_browser_message(&mut input, &mut buf, 4).unwrap(), BrowserMessage::TooLarge);
    assert!(buf.len() <= 4 + (1 << 16));
    assert_eq!(next_browser_message(&mut input, &mut buf, 4).unwrap(), BrowserMessage::Whole);
    assert_eq!(buf, b"ok");
    assert_eq!(next_browser_message(&mut input, &mut buf, 4).unwrap(), BrowserMessage::End);
}
