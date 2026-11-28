//! Attachments from a browser page (`ws-attachments-v1`): a real headless
//! daemon with its WebSocket listener. A page that presented the daemon's
//! credential uploads a video with its poster, sends the message that names
//! them, reads the bytes back, and plays them through a download link
//! (`GET /attachments/<token>` with byte ranges, as a video element seeks).

use std::io::{Read, Write as _};
use std::net::TcpStream;

use base64::Engine;
use serde_json::json;
use sha2::{Digest, Sha256};

use super::super::*;
use super::{TOKEN, Ws, ws_addr};

fn hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// A video-sized payload (the owner checks type, size and hash, never frames).
fn video() -> Vec<u8> {
    (0..300_000_u32).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect()
}

const POSTER: &[u8] = b"\xff\xd8\xff\xe0 the first frame of the clip, as JPEG";

/// One HTTP/1.1 request on the listener: (status, lowercase headers, body).
fn http(
    addr: &str,
    method: &str,
    path: &str,
    range: Option<&str>,
) -> (u16, Vec<(String, String)>, Vec<u8>) {
    let mut stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut request = format!("{method} {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\n");
    if let Some(range) = range {
        request.push_str(&format!("Range: {range}\r\n"));
    }
    request.push_str("\r\n");
    stream.write_all(request.as_bytes()).unwrap();
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).unwrap();
    let end = raw.windows(4).position(|w| w == b"\r\n\r\n").expect("a response head");
    let head = String::from_utf8(raw[..end].to_vec()).unwrap();
    let mut lines = head.split("\r\n");
    let status = lines.next().unwrap().split(' ').nth(1).unwrap().parse().unwrap();
    let headers = lines
        .filter_map(|line| line.split_once(':'))
        .map(|(name, value)| (name.trim().to_ascii_lowercase(), value.trim().to_owned()))
        .collect();
    (status, headers, raw[end + 4..].to_vec())
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> &'a str {
    headers.iter().find(|(key, _)| key == name).map_or("", |(_, value)| value.as_str())
}

#[test]
fn a_browser_page_uploads_sends_and_plays_a_video_through_a_download_link() {
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let server = HeadlessServer::start_with_config("ws-attachments", Some(&config));
    let created = json_socket_request(
        &server.socket,
        json!({"id": 1, "cmd": "conversation-create", "idempotency_key": "ws-att", "title": "Clips",
               "participants": [
                   {"id": "user_local", "kind": "human", "display_name": "Tester"},
                   {"id": "agent_mux", "kind": "agent", "display_name": "mux", "agent_class": "mux"}]}),
    );
    let conversation = created["conversation"]["id"].as_str().unwrap().to_owned();
    let addr = ws_addr(&server);
    let mut page = Ws::open(&addr);
    let identity = page.request("identify", json!({}));
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "ws-attachments-v1"), "{identity}");
    page.request("subscribe", json!({}));

    // Upload: the video in two chunks and its poster, over the WebSocket.
    let bytes = video();
    let poster =
        json!({"sha256": hex(POSTER), "byte_count": POSTER.len(), "mime_type": "image/jpeg"});
    let begun = page.request(
        "conversation-attachment-upload",
        json!({"op": "begin", "conversation": conversation, "sha256": hex(&bytes),
               "byte_count": bytes.len(), "mime_type": "video/mp4", "name": "clip.mp4",
               "width": 1280, "height": 720, "duration_ms": 4200, "poster": poster}),
    );
    assert_eq!(begun["needs"], json!(["original", "poster"]), "{begun}");
    let upload = begun["upload"].as_str().unwrap().to_owned();
    let b64 = |data: &[u8]| base64::engine::general_purpose::STANDARD.encode(data);
    let half = bytes.len() / 2;
    for (offset, data) in [(0, &bytes[..half]), (half, &bytes[half..])] {
        page.request(
            "conversation-attachment-upload",
            json!({"op": "chunk", "upload": upload, "piece": "original", "offset": offset, "data": b64(data)}),
        );
    }
    page.request(
        "conversation-attachment-upload",
        json!({"op": "chunk", "upload": upload, "piece": "poster", "offset": 0, "data": b64(POSTER)}),
    );
    let stored =
        page.request("conversation-attachment-upload", json!({"op": "commit", "upload": upload}));
    assert_eq!(stored["stored"]["hash"], hex(&bytes), "{stored}");
    assert_eq!(stored["stored"]["poster"]["hash"], hex(POSTER), "{stored}");

    // Send: the attachment part names the record; every subscriber sees it.
    let part = json!({"type": "attachment", "hash": hex(&bytes), "name": "clip.mp4",
                      "mime_type": "video/mp4", "byte_count": bytes.len(), "width": 1280,
                      "height": 720, "duration_ms": 4200,
                      "poster": {"hash": hex(POSTER), "mime_type": "image/jpeg", "byte_count": POSTER.len()}});
    page.request(
        "conversation-op",
        json!({"conversation": conversation, "idempotency_key": "att-1",
               "op": {"kind": "message.send", "client_msg_id": "att-1", "parts": [part]}}),
    );
    let event = page.message_event();
    assert_eq!(event["parts"][0], part, "{event}");

    // Read back over the WebSocket, at an offset.
    let read = page.request(
        "conversation-attachment-read",
        json!({"conversation": conversation, "hash": hex(&bytes), "offset": 1000, "length": 16}),
    );
    let data =
        base64::engine::general_purpose::STANDARD.decode(read["data"].as_str().unwrap()).unwrap();
    assert_eq!(data, bytes[1000..1016], "{read}");
    assert_eq!(read["eof"], false);

    // A download link, read the way a video element reads it.
    let link = page.request(
        "conversation-attachment-link",
        json!({"conversation": conversation, "hash": hex(&bytes), "name": "clip.mp4"}),
    );
    let path = link["path"].as_str().unwrap().to_owned();
    assert!(
        path.starts_with("/attachments/") && path.len() == "/attachments/".len() + 64,
        "{link}"
    );
    assert_eq!(link["expires_in_ms"], 600_000, "{link}");
    assert!(
        !path.contains(&conversation) && !path.contains(&hex(&bytes)),
        "the link names nothing: {path}"
    );

    let (status, headers, body) = http(&addr, "GET", &path, None);
    assert_eq!(status, 200);
    assert_eq!(body, bytes, "the whole video");
    assert_eq!(header(&headers, "content-type"), "video/mp4");
    assert_eq!(header(&headers, "accept-ranges"), "bytes");
    assert_eq!(header(&headers, "x-content-type-options"), "nosniff");
    assert!(
        header(&headers, "content-disposition").starts_with("attachment; filename=\"clip.mp4\"")
    );

    let (status, headers, body) = http(&addr, "GET", &path, Some("bytes=100-199"));
    assert_eq!(status, 206);
    assert_eq!(header(&headers, "content-range"), format!("bytes 100-199/{}", bytes.len()));
    assert_eq!(body, bytes[100..200]);
    let (status, _, body) = http(&addr, "GET", &path, Some("bytes=-10"));
    assert_eq!(status, 206);
    assert_eq!(body, bytes[bytes.len() - 10..]);
    let (status, headers, _) = http(&addr, "GET", &path, Some(&format!("bytes={}-", bytes.len())));
    assert_eq!(status, 416);
    assert_eq!(header(&headers, "content-range"), format!("bytes */{}", bytes.len()));
    let (status, headers, body) = http(&addr, "HEAD", &path, None);
    assert_eq!((status, body.len()), (200, 0));
    assert_eq!(header(&headers, "content-length"), bytes.len().to_string());

    // The poster through its own link: an inline JPEG.
    let poster_link = page.request(
        "conversation-attachment-link",
        json!({"conversation": conversation, "hash": hex(&bytes), "variant": "poster"}),
    );
    let (status, headers, body) = http(&addr, "GET", poster_link["path"].as_str().unwrap(), None);
    assert_eq!((status, body.as_slice()), (200, POSTER));
    assert_eq!(header(&headers, "content-type"), "image/jpeg");
    assert!(header(&headers, "content-disposition").starts_with("inline"));

    // A token the daemon never gave, or a changed one, reads nothing.
    let forged = format!("/attachments/{}", "0".repeat(64));
    assert_eq!(http(&addr, "GET", &forged, None).0, 404);
    let mut changed = path.into_bytes();
    let last = changed.len() - 1;
    changed[last] = if changed[last] == b'a' { b'b' } else { b'a' };
    assert_eq!(http(&addr, "GET", std::str::from_utf8(&changed).unwrap(), None).0, 404);
    // A hash this conversation does not hold gets no link.
    let unknown = page.reply(
        "conversation-attachment-link",
        json!({"conversation": conversation, "hash": hex(b"nothing")}),
    );
    assert_eq!(unknown["ok"], false, "{unknown}");
    assert_eq!(unknown["error_code"], "attachment_rejected", "{unknown}");
}
