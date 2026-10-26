use std::io::{Read, Write};

use super::*;

/// An in-memory peer: reads return what it sent, writes are its answer.
struct Peer {
    sent: std::io::Cursor<Vec<u8>>,
    answered: Vec<u8>,
}

impl Peer {
    fn sending(bytes: &[u8]) -> Self {
        Self { sent: std::io::Cursor::new(bytes.to_vec()), answered: Vec::new() }
    }
}

impl Read for Peer {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        self.sent.read(buffer)
    }
}

impl Write for Peer {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.answered.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
fn a_well_formed_head_parses() {
    let mut peer = Peer::sending(
        b"GET /pages/home/ HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nUpgrade: websocket\r\n\r\nrest",
    );
    let (bytes, head) = read_request_head(&mut peer).expect("a well-formed head");
    assert!(bytes.ends_with(b"rest"));
    assert_eq!((head.method.as_str(), head.target.as_str()), ("GET", "/pages/home/"));
    assert_eq!(head.values("host"), ["127.0.0.1:7777"]);
    assert_eq!(head.names().collect::<Vec<_>>(), ["Host", "Upgrade"]);
    assert!(head.is_websocket_upgrade());
}

/// A head with no blank line in REQUEST_HEAD_MAX_BYTES gets 431, and one
/// that ends just inside the limit parses.
#[test]
fn a_head_past_the_limit_gets_431() {
    let mut endless = b"GET / HTTP/1.1\r\nCookie: ".to_vec();
    endless.resize(REQUEST_HEAD_MAX_BYTES + 1, b'a');
    let mut peer = Peer::sending(&endless);
    assert!(read_request_head(&mut peer).is_none());
    assert!(peer.answered.starts_with(b"HTTP/1.1 431 "));

    let mut fits = endless[..REQUEST_HEAD_MAX_BYTES - 4].to_vec();
    fits.extend_from_slice(b"\r\n\r\n");
    let mut peer = Peer::sending(&fits);
    assert!(read_request_head(&mut peer).is_some());
    assert!(peer.answered.is_empty());
}

/// Optional whitespace around a field value is not part of it (RFC 9112
/// section 5.1), and HTTP/1.0 is a request line version like HTTP/1.1.
#[test]
fn a_field_value_drops_its_optional_whitespace() {
    let mut peer = Peer::sending(
        b"GET /pages/home/ HTTP/1.0\r\nHost:\t 127.0.0.1:7777 \t\r\nOrigin:x\r\n\r\n",
    );
    let (_, head) = read_request_head(&mut peer).expect("a well-formed head");
    assert_eq!(head.values("host"), ["127.0.0.1:7777"]);
    assert_eq!(head.values("origin"), ["x"]);
}

/// A bare CR or LF is not a line end of the head (RFC 9112 section 2.2), and
/// neither a method nor a target holds a control byte: such a head is
/// malformed, not a request whose method swallowed a header line
/// (cmux-tui/fuzz `page_request_head`). So is a request line that is not
/// exactly `method SP target SP HTTP/1.x`, and a field line that is not
/// `token ":" OWS value OWS` (whitespace before the colon, obs-fold).
#[test]
fn a_head_with_a_bare_line_break_or_control_byte_is_malformed() {
    for head in [
        &b"GE\0T /pages/home/ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"[..],
        b"GET /pages/home/ HTTP/1.1\nHost: evil\r\nHost: 127.0.0.1\r\n\r\n",
        b"GET\r/pages/home/ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        b"GET /pages/home/ HTTP/1.1\r\nHost: 127.0.0.1\nUpgrade: websocket\r\n\r\n",
        b"GET /pages/\x7fhome/ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        b" /pages/home/ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        // RFC 9112 section 5.1: no whitespace between a field name and its colon.
        b"GET /pages/home/ HTTP/1.1\r\nHost : evil\r\nHost: 127.0.0.1\r\n\r\n",
        b"GET /pages/home/ HTTP/1.1\r\nHost\t: evil\r\n\r\n",
        // RFC 9112 section 5.2: obs-fold, a field line that starts with whitespace.
        b"GET /pages/home/ HTTP/1.1\r\nHost: 127.0.0.1\r\n Host: evil\r\n\r\n",
        b"GET /pages/home/ HTTP/1.1\r\nHost: 127.0.0.1\r\n\tevil\r\n\r\n",
        // A field name is a non-empty token (RFC 9110 section 5.1).
        b"GET /pages/home/ HTTP/1.1\r\n: evil\r\nHost: 127.0.0.1\r\n\r\n",
        b"GET /pages/home/ HTTP/1.1\r\nHo(st: evil\r\n\r\n",
        b"GET /pages/home/ HTTP/1.1\r\nHost 127.0.0.1\r\n\r\n",
        // RFC 9112 section 3: method SP request-target SP HTTP-version.
        b"GET  HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        b"GET /pages/home/\r\nHost: 127.0.0.1\r\n\r\n",
        b"GET /pages/home/ HTTP/1.1 extra\r\nHost: 127.0.0.1\r\n\r\n",
        b"GET /pages/home/  HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        b"GET /pages/home/ HTTP/2.0\r\nHost: 127.0.0.1\r\n\r\n",
        b"GET /pages/home/ http/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        b"GET /pages/home/ HTTP/1.11\r\nHost: 127.0.0.1\r\n\r\n",
    ] {
        let mut peer = Peer::sending(head);
        assert!(
            read_request_head(&mut peer).is_none(),
            "accepted {:?}",
            String::from_utf8_lossy(head)
        );
        assert!(peer.answered.is_empty());
    }
}

/// A page names its shared chunks by `cmux-page://cmux.shared/` (the app's
/// shared origin, build-pages.mjs); a browser on the listener gets the same
/// chunks at `/pages/_shared/`, in pages and scripts only, with the
/// Content-Length of what it receives.
#[test]
fn a_page_gets_its_shared_chunks_at_the_listeners_shared_path() {
    let root = std::env::temp_dir().join(format!(
        "cmux-page-files-shared-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("history")).unwrap();
    std::fs::create_dir_all(root.join("_shared")).unwrap();
    std::fs::write(
        root.join("history/index.html"),
        "<link rel=\"modulepreload\" href=\"cmux-page://cmux.shared/react-1.js\" />",
    )
    .unwrap();
    std::fs::write(
        root.join("history/app-H.js"),
        "import\"cmux-page://cmux.shared/react-1.js\";import(\"cmux-page://cmux.shared/lazy-2.js\");",
    )
    .unwrap();
    std::fs::write(root.join("_shared/react-1.js"), "export const React = 1;").unwrap();
    std::fs::write(root.join("history/data.json"), "\"cmux-page://cmux.shared/x.js\"").unwrap();

    let policy = cmux_local_auth::ListenerPolicy::loopback(7777);
    let get = |target: &str| {
        let head = format!("GET {target} HTTP/1.1\r\nHost: 127.0.0.1:7777\r\n\r\n");
        let (_, head) = read_request_head(&mut Peer::sending(head.as_bytes())).unwrap();
        String::from_utf8(respond(&head, &policy, Some(&root))).unwrap()
    };
    let body = |reply: &str| reply.split_once("\r\n\r\n").unwrap().1.to_owned();
    let length = |reply: &str| {
        reply
            .lines()
            .find_map(|line| line.strip_prefix("Content-Length: "))
            .and_then(|value| value.parse::<usize>().ok())
            .unwrap()
    };

    let page = get("/pages/history/");
    assert_eq!(body(&page), "<link rel=\"modulepreload\" href=\"/pages/_shared/react-1.js\" />");
    assert_eq!(length(&page), body(&page).len());
    let script = get("/pages/history/app-H.js");
    assert_eq!(
        body(&script),
        "import\"/pages/_shared/react-1.js\";import(\"/pages/_shared/lazy-2.js\");"
    );
    assert_eq!(length(&script), body(&script).len());
    assert_eq!(body(&get("/pages/_shared/react-1.js")), "export const React = 1;");
    assert_eq!(body(&get("/pages/history/data.json")), "\"cmux-page://cmux.shared/x.js\"");

    let _ = std::fs::remove_dir_all(&root);
}
