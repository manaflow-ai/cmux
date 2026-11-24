use super::{InstallError, MAX_COMPRESSED_BYTES, MAX_HEADER_BYTES, parse_response, split_url};

#[test]
fn other_statuses_chunked_bodies_and_short_bodies_are_refused() {
    let cases: [&[u8]; 5] = [
        b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n",
        b"HTTP/1.1 301 Moved\r\nLocation: http://x/\r\n\r\n",
        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
        b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort",
        b"not http at all",
    ];
    for raw in cases {
        assert!(
            matches!(parse_response(raw), Err(InstallError::Download(_))),
            "{}",
            String::from_utf8_lossy(raw)
        );
    }
}

#[test]
fn an_oversize_body_is_refused() {
    let mut raw = b"HTTP/1.1 200 OK\r\n\r\n".to_vec();
    raw.resize(raw.len() + MAX_COMPRESSED_BYTES + 1, 0);
    assert!(matches!(parse_response(&raw), Err(InstallError::TooLarge)));
    // The limit sits a little above Cisco's largest 2.6.0 file (634,264 bytes).
    const { assert!(MAX_COMPRESSED_BYTES > 634_264 && MAX_COMPRESSED_BYTES <= 2 << 20) };
}

#[test]
fn a_truncated_body_is_refused() {
    let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 634264\r\n\r\nBZh91AY&SY";
    assert!(matches!(parse_response(raw), Err(InstallError::Download(_))));
}

#[test]
fn an_oversize_header_is_refused() {
    let mut raw = b"HTTP/1.1 200 OK\r\nX-Pad: ".to_vec();
    raw.resize(raw.len() + MAX_HEADER_BYTES, b'a');
    raw.extend_from_slice(b"\r\n\r\nbody");
    assert!(matches!(parse_response(&raw), Err(InstallError::Download(_))));
}
