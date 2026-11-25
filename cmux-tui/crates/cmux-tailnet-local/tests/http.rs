//! Sans-I/O HTTP: request bytes and response framing.

use cmux_tailnet_local::Error;
use cmux_tailnet_local::http::{Endpoint, Progress, ResponseReader, request};

#[test]
fn request_has_localapi_headers_and_basic_token() {
    let req = String::from_utf8(request(&Endpoint::Status, Some("abc123"))).unwrap();
    assert!(req.starts_with("GET /localapi/v0/status HTTP/1.1\r\n"));
    assert!(req.contains("Host: local-tailscaled.sock\r\n"));
    assert!(req.contains("Sec-Tailscale: localapi\r\n"));
    // base64(":abc123")
    assert!(req.contains("Authorization: Basic OmFiYzEyMw==\r\n"));
    assert!(req.ends_with("\r\n\r\n"));
    let plain = String::from_utf8(request(&Endpoint::Prefs, None)).unwrap();
    assert!(!plain.contains("Authorization"));
    assert_eq!(
        Endpoint::WhoIs("100.64.0.2:22".into()).path(),
        "/localapi/v0/whois?addr=100.64.0.2%3A22"
    );
}

fn feed_all(raw: &[u8], max: usize, step: usize) -> Result<Progress, Error> {
    let mut r = ResponseReader::new(max);
    for chunk in raw.chunks(step) {
        if let Progress::Done { status, body } = r.feed(chunk, false)? {
            return Ok(Progress::Done { status, body });
        }
    }
    r.feed(&[], true)
}

#[test]
fn content_length_body_in_any_split() {
    let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    for step in 1..raw.len() {
        assert_eq!(
            feed_all(raw, 1024, step).unwrap(),
            Progress::Done { status: 200, body: b"hello".to_vec() }
        );
    }
}

#[test]
fn chunked_body_is_decoded() {
    let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3;x=y\r\n:1}\r\n0\r\n\r\n";
    for step in 1..raw.len() {
        assert_eq!(
            feed_all(raw, 1024, step).unwrap(),
            Progress::Done { status: 200, body: b"{\"a\":1}".to_vec() }
        );
    }
}

#[test]
fn read_to_close_body() {
    let raw = b"HTTP/1.1 403 Forbidden\r\n\r\ndenied";
    assert_eq!(
        feed_all(raw, 1024, 7).unwrap(),
        Progress::Done { status: 403, body: b"denied".to_vec() }
    );
}

#[test]
fn oversized_bodies_are_refused() {
    let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 2000\r\n\r\n";
    assert_eq!(ResponseReader::new(1000).feed(raw, false), Err(Error::TooLarge));
    let chunked = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n800\r\n";
    assert_eq!(ResponseReader::new(1000).feed(chunked, false), Err(Error::TooLarge));
    let mut r = ResponseReader::new(10);
    assert_eq!(r.feed(b"HTTP/1.1 200 OK\r\n\r\n", false), Ok(Progress::More));
    assert_eq!(r.feed(&[b'x'; 11], false), Err(Error::TooLarge));
}

#[test]
fn malformed_responses_are_errors() {
    assert!(ResponseReader::new(10).feed(b"SSH-2.0-x\r\n\r\n", false).is_err());
    assert!(ResponseReader::new(10).feed(b"HTTP/1.1 200 OK\r\nContent-Le", true).is_err());
    assert!(ResponseReader::new(10).feed(&vec![b'a'; 20_000], false).is_err());
    let mut r = ResponseReader::new(100);
    r.feed(b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc", false).unwrap();
    assert!(r.feed(&[], true).is_err(), "closed mid-body");
}
