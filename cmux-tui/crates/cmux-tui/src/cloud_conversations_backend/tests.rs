use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::mpsc;

use serde_json::json;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;

use super::*;

/// The declared part length is a hard boundary even when it is not a
/// 64 KiB multiple. A server must never receive the next part's bytes.
#[test]
fn streamed_put_stops_at_a_non_aligned_declared_length() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let (seen, received) = mpsc::channel();
    let declared = UPLOAD_CHUNK_BYTES as u64 + 17;
    std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(socket.try_clone().unwrap());
        let mut length = None;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                length = Some(value.trim().parse::<usize>().unwrap());
            }
            if line == "\r\n" {
                break;
            }
        }
        let length = length.unwrap();
        let mut body = vec![0; length];
        reader.read_exact(&mut body).unwrap();
        reader.get_mut().set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        let mut extra = [0; 1];
        let extra_byte = reader.read(&mut extra).unwrap_or(0) != 0;
        socket
                .write_all(b"HTTP/1.1 200 OK\r\netag: \"part-etag\"\r\ncontent-length: 11\r\nconnection: close\r\n\r\n{\"ok\":true}")
                .unwrap();
        seen.send((body, extra_byte)).unwrap();
    });
    let path = std::env::temp_dir().join(format!("cmux-stream-boundary-{}", std::process::id()));
    let mut source = std::fs::File::create(&path).unwrap();
    source.write_all(&vec![b'a'; declared as usize]).unwrap();
    source.write_all(b"NEXT-PART").unwrap();
    drop(source);
    let file = std::fs::File::open(&path).unwrap();
    let backend = RemoteCloudBackend::new().unwrap();
    let (_, etag) = backend
        .put_with_etag(&format!("{origin}/upload"), &[], PutBody::File { file, len: declared })
        .unwrap();
    assert_eq!(etag.as_deref(), Some("\"part-etag\""));
    let (body, extra) = received.recv().unwrap();
    let _ = std::fs::remove_file(path);
    assert_eq!(body.len(), declared as usize);
    assert!(body.iter().all(|byte| *byte == b'a'));
    assert!(!extra, "streamed body crossed the declared part boundary");
}

/// Review of #26498: a slow uplink or a slow final answer is not a stall.
/// One read of the body is small enough that hyper asks for the next one
/// within the window at a few KB/s, and the wait for the reply after the
/// last byte has its own, longer window.
#[test]
fn a_slow_upload_or_a_slow_reply_is_not_a_stall() {
    // 64 KiB at 1 KB/s is about 64 s between reads: inside the window.
    const { assert!(UPLOAD_CHUNK_BYTES <= 64 * 1024, "one read is at most 64 KiB") };
    let read_gap = Duration::from_secs((UPLOAD_CHUNK_BYTES / 1024) as u64);
    assert!(!stall_left(read_gap, false).is_zero());
    // The whole body went three minutes ago and the slot is still committing it.
    assert!(!stall_left(Duration::from_secs(3 * 60), true).is_zero());
    // A body that stopped moving, or a reply that never comes, still ends.
    assert!(stall_left(UPLOAD_STALL, false).is_zero());
    assert!(stall_left(UPLOAD_REPLY, true).is_zero());
}

/// Review of #26498 at 2eba8e2f: a staged file's body was read to its end,
/// not its declared length, so a file positioned past its start (or longer
/// than `len`) sent bytes the Content-Length did not count.
#[tokio::test]
async fn a_file_body_sends_exactly_len_bytes_from_where_the_file_stands() {
    use std::io::{Seek, SeekFrom, Write as _};
    let mut file = tempfile::tempfile().unwrap();
    file.write_all(b"0123456789abcdefghij").unwrap();
    file.seek(SeekFrom::Start(7)).unwrap();
    let progress = Arc::new(UploadProgress::default());
    let chunks: Vec<Vec<u8>> = file_chunks(file, 4, Instant::now(), progress.clone())
        .map(|chunk| chunk.unwrap())
        .collect()
        .await;
    assert_eq!(chunks.concat(), b"789a");
    assert!(progress.sent.load(Ordering::Relaxed), "its last byte marks it sent");
}

/// Review of #26498 at 6a89561a: the reply body of a streamed upload was
/// read within the stall window, not the reply window.
#[test]
fn a_streamed_uploads_reply_body_has_the_reply_window() {
    assert_eq!(reply_body_window(), UPLOAD_REPLY);
}

/// Review of #26498 at d79ff855: a derived image's (bytes) reply body was
/// read within the stall window, not the reply window, though its whole
/// request has UPLOAD_TIMEOUT (10 min).
#[test]
fn a_byte_uploads_reply_body_has_the_reply_window_too() {
    assert_eq!(reply_body_window(), UPLOAD_REPLY);
}

/// Serves one raw HTTP/1.1 exchange and hands back the request head.
fn one_http_exchange(reply: &'static str) -> (String, mpsc::Receiver<(String, String)>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(socket.try_clone().unwrap());
        let mut head = String::new();
        let mut length = 0usize;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                length = value.trim().parse().unwrap();
            }
            if line == "\r\n" || line.is_empty() {
                break;
            }
            head.push_str(&line);
        }
        let mut body = vec![0; length];
        reader.read_exact(&mut body).unwrap();
        socket.write_all(reply.as_bytes()).unwrap();
        sender.send((head, String::from_utf8(body).unwrap())).unwrap();
    });
    (origin, receiver)
}

#[test]
fn cloud_environment_patch_sends_install_token_and_never_follows_redirects() {
    let backend = RemoteCloudBackend::new().unwrap();
    let patch = json!({"setup_script":null,"set_secrets":[{"name":"TOKEN","value":"write-only"}]});
    let (origin, seen) = one_http_exchange(
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 11\r\nconnection: close\r\n\r\n{\"ok\":true}",
    );
    let reply = backend
        .platform(
            "PATCH",
            &format!("{origin}/v1/cloud-environments/env_default"),
            "install.jwt",
            &patch,
        )
        .unwrap();
    assert_eq!(reply.status, 200);
    let (head, body) = seen.recv().unwrap();
    let head = head.to_ascii_lowercase();
    assert!(head.starts_with("patch /v1/cloud-environments/env_default "), "{head}");
    assert!(head.contains("authorization: bearer install.jwt"), "{head}");
    assert_eq!(serde_json::from_str::<Value>(&body).unwrap(), patch);

    // Following this redirect would fail the request; returning 307 proves
    // that no second request sends the install token to the target.
    let (origin, seen) = one_http_exchange(
        "HTTP/1.1 307 Temporary Redirect\r\nlocation: http://127.0.0.1:1/stolen\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
    );
    let reply = backend
        .platform(
            "PATCH",
            &format!("{origin}/v1/cloud-environments/env_default"),
            "install.jwt",
            &patch,
        )
        .unwrap();
    assert_eq!(reply.status, 307);
    assert!(seen.recv().unwrap().0.starts_with("PATCH "));
}

#[test]
fn direct_part_url_mint_uses_only_the_slot_and_part_header() {
    let backend = RemoteCloudBackend::new().unwrap();
    let (origin, seen) = one_http_exchange(
        "HTTP/1.1 200 OK\r\ncontent-length: 11\r\nconnection: close\r\n\r\n{\"ok\":true}",
    );
    backend.attachment_part_url(&format!("{origin}/signed-slot"), 3).unwrap();
    let (head, _) = seen.recv().unwrap();
    let head = head.to_ascii_lowercase();
    assert!(head.starts_with("post /signed-slot "));
    assert!(head.contains("x-cmux-part-number: 3"));
    assert!(!head.contains("authorization:"));
}

#[test]
fn a_post_without_a_bearer_sends_no_authorization_header() {
    let backend = RemoteCloudBackend::new().unwrap();
    let (origin, seen) = one_http_exchange(
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 11\r\nconnection: close\r\n\r\n{\"ok\":true}",
    );
    let reply = backend.post(&format!("{origin}/v1/read"), None, None, &json!({})).unwrap();
    assert_eq!(reply.status, 200);
    let (head, _) = seen.recv().unwrap();
    assert!(!head.to_ascii_lowercase().contains("authorization:"), "{head}");
}

#[test]
fn post_sends_the_bearer_version_and_json_and_reads_any_status() {
    let backend = RemoteCloudBackend::new().unwrap();
    let (origin, seen) = one_http_exchange(
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 11\r\nconnection: close\r\n\r\n{\"ok\":true}",
    );
    let reply = backend
        .post(
            &format!("{origin}/v1/ops"),
            Some("tok.en"),
            Some("0.70.0"),
            &json!({"op": "title.set"}),
        )
        .unwrap();
    assert_eq!(reply, HttpReply { status: 200, body: json!({"ok": true}) });
    let (head, body) = seen.recv().unwrap();
    let head = head.to_ascii_lowercase();
    assert!(head.starts_with("post /v1/ops "), "{head}");
    assert!(head.contains("authorization: bearer tok.en"), "{head}");
    assert!(head.contains("x-cmux-client-version: 0.70.0"), "{head}");
    assert_eq!(serde_json::from_str::<Value>(&body).unwrap(), json!({"op": "title.set"}));

    let (origin, _) = one_http_exchange(
        "HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
    );
    let reply = backend.post(&format!("{origin}/v1/read"), Some("t"), None, &json!({})).unwrap();
    assert_eq!(reply, HttpReply { status: 401, body: Value::Null });

    let refused = backend.post("http://127.0.0.1:1/v1/ops", Some("secret-token"), None, &json!({}));
    let TransportError(detail) = refused.unwrap_err();
    assert!(!detail.contains("secret-token"));
}

// tungstenite's handshake callback type fixes its large error variant.
#[allow(clippy::result_large_err)]
#[test]
fn a_stream_carries_the_token_in_the_authorization_header_and_reports_close_codes() {
    let backend = RemoteCloudBackend::new().unwrap();
    let listener = backend.runtime.block_on(tokio::net::TcpListener::bind("127.0.0.1:0")).unwrap();
    let address = listener.local_addr().unwrap();
    let (protocols_seen, protocols) = mpsc::channel();
    backend.runtime.spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let callback = move |request: &Request, mut response: Response| {
            let header = |name: &str| {
                request
                    .headers()
                    .get(name)
                    .map(|value| value.to_str().unwrap().to_string())
                    .unwrap_or_default()
            };
            protocols_seen
                .send((header("sec-websocket-protocol"), header("authorization")))
                .unwrap();
            response
                .headers_mut()
                .insert("sec-websocket-protocol", HeaderValue::from_static("cmux.wire.v1"));
            Ok(response)
        };
        let mut server = tokio_tungstenite::accept_hdr_async(socket, callback).await.unwrap();
        server.send(Message::Text("{\"t\":\"welcome\"}".into())).await.unwrap();
        let subscribe = server.next().await.unwrap().unwrap();
        assert_eq!(subscribe, Message::Text("{\"t\":\"subscribe\"}".into()));
        server
            .send(Message::Close(Some(CloseFrame {
                code: CloseCode::from(4401),
                reason: "token expired".into(),
            })))
            .await
            .unwrap();
    });
    let mut wire = backend
        .connect(&format!("ws://{address}/v1/wire/conv/x"), Some("tok.en"), Some("0.70.0"))
        .unwrap_or_else(|_| panic!("connect failed"));
    // cx-dgsp: the token is never in the subprotocols (Workers invocation logs record them).
    assert_eq!(
        protocols.recv().unwrap(),
        ("cmux.wire.v1".to_string(), "Bearer tok.en".to_string())
    );
    assert_eq!(wire.recv(Duration::from_secs(10)), WireRecv::Text("{\"t\":\"welcome\"}".into()));
    wire.send("{\"t\":\"subscribe\"}").unwrap();
    assert_eq!(wire.recv(Duration::from_secs(10)), WireRecv::Closed { code: Some(4401) });
}

#[test]
fn a_refused_handshake_maps_to_unauthenticated_or_forbidden() {
    let backend = RemoteCloudBackend::new().unwrap();
    for (reply, expected) in [
        (
            "HTTP/1.1 401 Unauthorized\r\nx-cmux-wire-auth: authorization, ticket\r\ncontent-length: 0\r\n\r\n",
            ConnectError::Unauthenticated,
        ),
        ("HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n", ConnectError::Forbidden),
    ] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut buffer = [0u8; 4096];
            let _ = socket.read(&mut buffer);
            socket.write_all(reply.as_bytes()).unwrap();
        });
        match backend.connect(&format!("ws://{address}/v1/wire/user"), Some("t"), None) {
            Err(error) => assert_eq!(error, expected),
            Ok(_) => panic!("the handshake must be refused"),
        }
    }
}

/// Any 401, with or without `x-cmux-wire-auth`, is final: the client never
/// retries with the token in a subprotocol, which Workers invocation logs
/// record (cx-dgsp; the legacy `bearer.` retry is retired).
#[test]
fn a_401_without_header_auth_is_final_and_sends_no_token_subprotocol() {
    let backend = RemoteCloudBackend::new().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (seen_tx, seen) = mpsc::channel();
    std::thread::spawn(move || {
        for _ in 0..2 {
            let Ok((mut socket, _)) = listener.accept() else { return };
            let mut buffer = [0u8; 4096];
            let read = socket.read(&mut buffer).unwrap();
            seen_tx.send(String::from_utf8_lossy(&buffer[..read]).to_ascii_lowercase()).unwrap();
            socket.write_all(b"HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\n\r\n").unwrap();
        }
    });
    match backend.connect(&format!("ws://{address}/v1/wire/user"), Some("tok.en"), None) {
        Err(error) => assert_eq!(error, ConnectError::Unauthenticated),
        Ok(_) => panic!("the handshake must be refused"),
    }
    let first = seen.recv().unwrap();
    assert!(first.contains("authorization: bearer tok.en"), "{first}");
    assert!(first.contains("sec-websocket-protocol: cmux.wire.v1\r\n"), "{first}");
    assert!(seen.recv_timeout(Duration::from_millis(500)).is_err(), "the client must not retry");
}
