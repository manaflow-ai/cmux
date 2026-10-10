//! `link_preview` parts against a real headless daemon, over its socket:
//! the sender uploads the page's picture as an ordinary attachment record,
//! sends a part that names it, and another participant reads the picture
//! back by its hash. The JSON matches what the cmux-next app and the Chief
//! send.

use super::*;
use base64::Engine;
use sha2::{Digest, Sha256};

/// A JPEG-shaped payload (the owner checks type, size and hash, never pixels).
const IMAGE: &[u8] = b"\xff\xd8\xff\xe0 the page's og:image, resized";

fn hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Sends `cmd` and returns the whole reply line (ok or not).
fn reply(conn: &mut Conn, cmd: &str, params: Value) -> Value {
    let id = conn.next;
    conn.next += 1;
    let mut body = params.as_object().cloned().unwrap_or_default();
    body.insert("id".into(), json!(id));
    body.insert("cmd".into(), json!(cmd));
    writeln!(conn.writer, "{}", Value::Object(body)).unwrap();
    loop {
        let value = conn.line();
        if value.get("event").is_some() {
            conn.events.push_back(value);
        } else if value["id"] == id {
            return value;
        }
    }
}

fn send(conn: &mut Conn, conversation: &str, key: &str, parts: Value) -> Value {
    reply(
        conn,
        "conversation-op",
        json!({"conversation": conversation, "idempotency_key": key,
               "op": {"kind": "message.send", "client_msg_id": key, "parts": parts}}),
    )
}

/// The reason of a refused op (`error_code` `conversation_rejected`).
fn refused(answer: &Value) -> &str {
    assert_eq!(answer["ok"], false, "{answer}");
    assert_eq!(answer["error_code"], "conversation_rejected", "{answer}");
    answer["error"].as_str().unwrap_or("")
}

fn link(image: Option<Value>) -> Value {
    let mut part = json!({"type": "link_preview", "url": "https://example.com/post",
                          "title": "A post", "site": "example.com"});
    if let Some(image) = image {
        part["image"] = image;
    }
    part
}

fn image(mime_type: &str, byte_count: usize) -> Value {
    json!({"hash": hex(IMAGE), "mime_type": mime_type, "byte_count": byte_count})
}

fn upload_image(conn: &mut Conn, conversation: &str) {
    let begun = conn.request(
        "conversation-attachment-upload",
        json!({"op": "begin", "conversation": conversation, "sha256": hex(IMAGE),
               "byte_count": IMAGE.len(), "mime_type": "image/jpeg", "name": "link-preview.jpg"}),
    );
    let upload = begun["upload"].as_str().unwrap().to_owned();
    let data = base64::engine::general_purpose::STANDARD.encode(IMAGE);
    conn.request(
        "conversation-attachment-upload",
        json!({"op": "chunk", "upload": upload, "piece": "original", "offset": 0, "data": data}),
    );
    conn.request("conversation-attachment-upload", json!({"op": "commit", "upload": upload}));
}

/// Home (`user_local`) and the Chief (`agent_mux`, bound with its token) on one conversation.
fn home_and_chief(server: &HeadlessServer) -> (Conn, Conn, String) {
    let mut home = Conn::open(&server.socket);
    let conversation = chief_conversation(&mut home);
    let token =
        home.request("conversation-agent-token", json!({"participant": "agent_mux"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut chief = Conn::open(&server.socket);
    chief.request("conversation-bind", json!({"participant": "agent_mux", "token": token}));
    (home, chief, conversation)
}

#[test]
fn a_link_preview_commits_with_the_senders_picture_and_every_participant_reads_it() {
    let server = HeadlessServer::start("link-preview");
    let (mut home, mut chief, conversation) = home_and_chief(&server);
    let matching = link(Some(image("image/jpeg", IMAGE.len())));

    // A preview without a picture needs no upload.
    let bare = json!([{"type": "text", "text": "look"}, link(None)]);
    let sent = send(&mut home, &conversation, "c0", bare.clone());
    assert_eq!(sent["ok"], true, "{sent}");
    assert_eq!(sent["data"]["change"]["message"]["parts"], bare);

    // The picture must be a record the author may use, of the same type and size.
    assert_eq!(
        refused(&send(&mut home, &conversation, "c1", json!([matching]))),
        "unknown_attachment"
    );
    upload_image(&mut home, &conversation);
    assert_eq!(
        refused(&send(&mut chief, &conversation, "c2", json!([matching]))),
        "unknown_attachment",
        "another participant's unsent upload is not theirs to use"
    );
    let wrong_type = link(Some(image("image/webp", IMAGE.len())));
    assert_eq!(
        refused(&send(&mut home, &conversation, "c3", json!([wrong_type]))),
        "attachment_mismatch"
    );
    let wrong_size = link(Some(image("image/jpeg", IMAGE.len() + 1)));
    assert_eq!(
        refused(&send(&mut home, &conversation, "c4", json!([wrong_size]))),
        "attachment_mismatch"
    );

    let sent = send(&mut home, &conversation, "c5", json!([matching]));
    assert_eq!(sent["ok"], true, "{sent}");
    assert_eq!(sent["data"]["change"]["message"]["parts"], json!([matching]));
    let snapshot =
        chief.request("conversation-snapshot", json!({"conversation": conversation, "tail": 1}));
    assert_eq!(snapshot["messages"][0]["parts"], json!([matching]));
    let read = chief.request(
        "conversation-attachment-read",
        json!({"conversation": conversation, "hash": hex(IMAGE), "variant": "original",
               "offset": 0, "length": 4096}),
    );
    let bytes =
        base64::engine::general_purpose::STANDARD.decode(read["data"].as_str().unwrap()).unwrap();
    assert_eq!(bytes, IMAGE);
    assert_eq!(read["eof"], true);
}

#[test]
fn a_link_preview_of_the_wrong_shape_is_refused_before_any_record() {
    let server = HeadlessServer::start("link-preview-shape");
    let (mut home, _chief, conversation) = home_and_chief(&server);
    let cases = [
        json!({"type": "link_preview", "url": "javascript:alert(1)"}),
        json!({"type": "link_preview", "url": "https://user@example.com"}),
        json!({"type": "link_preview", "url": "https:///path"}),
        json!({"type": "link_preview", "url": "https://example.com", "title": ""}),
        json!({"type": "link_preview", "url": "https://example.com", "site": "a\nb"}),
        link(Some(image("image/png", IMAGE.len()))),
        link(Some(image("image/jpeg", 512_001))),
    ];
    for (index, part) in cases.into_iter().enumerate() {
        let answer = send(&mut home, &conversation, &format!("s{index}"), json!([part.clone()]));
        assert_eq!(refused(&answer), "invalid_parts", "{part}");
    }
}

#[test]
fn the_daemon_advertises_link_preview_parts() {
    let server = HeadlessServer::start("link-preview-capability");
    let mut home = Conn::open(&server.socket);
    let identity = home.request("identify", json!({}));
    let capabilities = identity["capabilities"].as_array().expect("capabilities");
    assert!(capabilities.iter().any(|value| value == "link-preview-v1"), "{capabilities:?}");
}

#[test]
fn a_part_of_an_unknown_type_is_refused_as_invalid_parts_not_as_a_bad_request() {
    let server = HeadlessServer::start("link-preview-unknown-part");
    let (mut home, _chief, conversation) = home_and_chief(&server);
    let parts =
        json!([{"type": "text", "text": "hi"}, {"type": "future_part", "anything": [1, 2]}]);
    let answer = send(&mut home, &conversation, "u0", parts);
    assert_eq!(refused(&answer), "invalid_parts");
    // The conversation goes on: a known part list still commits.
    let sent = send(&mut home, &conversation, "u1", json!([{"type": "text", "text": "hi"}]));
    assert_eq!(sent["ok"], true, "{sent}");
}

#[test]
fn an_import_with_a_part_the_owner_would_refuse_is_refused_whole() {
    let server = HeadlessServer::start("link-preview-import");
    let (mut home, _chief, conversation) = home_and_chief(&server);
    let import = |parts: Value| {
        json!({"conversation": conversation, "messages": [
            {"client_msg_id": "i0", "author": "user_local", "created_at": "2026-01-01T00:00:00.000Z",
             "parts": [{"type": "text", "text": "fine"}]},
            {"client_msg_id": "i1", "author": "user_local", "created_at": "2026-01-01T00:00:01.000Z",
             "parts": parts}]})
    };
    for parts in [
        json!([{"type": "future_part", "anything": 1}]),
        json!([{"type": "link_preview", "url": "javascript:alert(1)"}]),
    ] {
        let answer = reply(&mut home, "conversation-import", import(parts.clone()));
        assert_eq!(refused(&answer), "invalid_parts", "{parts}");
    }
    // Nothing of a refused batch was imported; a valid one still is.
    let ok = reply(
        &mut home,
        "conversation-import",
        import(json!([{"type": "link_preview", "url": "https://example.com/a"}])),
    );
    assert_eq!(ok["ok"], true, "{ok}");
    assert_eq!(ok["data"]["imported"].as_array().map(Vec::len), Some(2), "{ok}");
}
