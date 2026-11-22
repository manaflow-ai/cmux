//! Tests for `tool_read_images.rs`: a finished read of an image file carries the image.

use super::super::*;
use super::*;
use std::path::{Path, PathBuf};

/// The smallest PNG signature and header a viewer would accept as a start.
const PNG: &[u8] =
    b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\0\x01\0\0\0\x01\x08\x06\0\0\0\x1f\x15\xc4\x89";

fn update(fields: Value) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": fields}})
}

/// Codex's `view_image` completion as the adapter sends it (`imageView`): a `read` titled
/// "View <file>", the file in `locations`, no content.
fn codex_view(path: &str) -> Value {
    update(json!({
        "_meta": {"codexAppServer": {"itemType": "imageView"}},
        "sessionUpdate": "tool_call_update", "toolCallId": "exec-1", "kind": "read",
        "status": "completed", "title": "View shot.png", "locations": [{"path": path}],
    }))
}

fn scratch(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("acpmux-read-images-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn images(msg: &Value) -> Vec<Value> {
    msg.pointer("/params/update/content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|block| block.pointer("/content/type") == Some(&json!("image")))
        .map(|block| block["content"].clone())
        .collect()
}

fn hub_at(dir: &Path) -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

fn session_in(hub: &Hub, cwd: &Path) -> Arc<Session> {
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA,
        "id": "s-read-images",
        "name": "read-images",
        "harness": "codex",
        "cwd": cwd,
        "status": "idle",
        "createdAt": 0,
        "updatedAt": 0,
    }))
    .unwrap();
    hub.make_session(meta)
}

/// Leo: "this preview is not correct". A Codex View of a PNG on the session's machine reaches
/// the client, and the log, with the image itself, so a pane on another Mac draws it.
#[cfg(unix)]
#[test]
fn a_codex_view_of_a_png_is_logged_with_its_image() {
    let store = cmux_unix_socket::short_test_dir("acpmux-ri");
    let dir = scratch("logged");
    std::fs::create_dir_all(dir.join("captures")).unwrap();
    std::fs::write(dir.join("captures/shot.png"), PNG).unwrap();
    let hub = hub_at(store.path());
    let session = session_in(&hub, &dir);

    let (rec, _) = hub.append_logged(
        &session,
        "in",
        "tool_call_update",
        codex_view("captures/shot.png"),
        None,
    );
    let want = base64::engine::general_purpose::STANDARD.encode(PNG);
    assert_eq!(
        images(&rec.msg),
        vec![json!({"type": "image", "mimeType": "image/png", "data": want})],
        "{}",
        rec.msg
    );
    assert_eq!(
        rec.msg["params"]["update"]["title"], "View shot.png",
        "the rest of the record stays"
    );
    let mut stored = Vec::new();
    let _ = hub.store.scan_kinds(&session.id, &["tool_call_update"], &mut |e: EventRecord| {
        stored.push(e.msg);
        true
    });
    assert_eq!(stored, std::slice::from_ref(&rec.msg), "a reopened chat hears the same image");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn each_image_type_is_named_by_its_bytes() {
    let dir = scratch("types");
    let cases: [(&str, &[u8], &str); 4] = [
        ("a.png", PNG, "image/png"),
        ("b.jpg", b"\xff\xd8\xff\xe0\0\x10JFIF", "image/jpeg"),
        ("c.gif", b"GIF89a\x01\0\x01\0", "image/gif"),
        ("d.bin", b"RIFF\x1a\0\0\0WEBPVP8 ", "image/webp"),
    ];
    for (name, bytes, mime) in cases {
        let path = dir.join(name);
        std::fs::write(&path, bytes).unwrap();
        let mut msg = codex_view(path.to_str().unwrap());
        add_read_image("tool_call_update", &mut msg, &dir);
        assert_eq!(images(&msg).len(), 1, "{name}: {msg}");
        assert_eq!(images(&msg)[0]["mimeType"], mime, "{name}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// What is not a finished read of one image file goes on as it came.
#[test]
fn anything_else_is_left_as_it_came() {
    let dir = scratch("left");
    let png = dir.join("shot.png");
    std::fs::write(&png, PNG).unwrap();
    std::fs::write(dir.join("fake.png"), b"not an image").unwrap();
    std::fs::write(dir.join("notes.txt"), b"notes\n").unwrap();
    let big = std::fs::File::create(dir.join("big.png")).unwrap();
    big.set_len(MAX_READ_IMAGE_BYTES + 1).unwrap();
    let png = png.to_str().unwrap().to_owned();

    let mut running = codex_view(&png);
    running["params"]["update"]["status"] = json!("in_progress");
    let mut edit = codex_view(&png);
    edit["params"]["update"]["kind"] = json!("edit");
    let mut two = codex_view(&png);
    two["params"]["update"]["locations"] = json!([{"path": png}, {"path": png}]);
    // A Claude Read that returned its image already (`claude_stdio/result_images.rs`).
    let mut returned = codex_view(&png);
    returned["params"]["update"]["content"] = json!([{"type": "content", "content": {"type": "image", "mimeType": "image/png", "data": "AAAA"}}]);
    let mut spoofed = codex_view("notes.txt");
    spoofed["params"]["update"]["locations"][0]["_meta"] =
        json!({"acpmux": {"canonicalPath": png}});
    let cases = [
        ("still running", running, "tool_call_update"),
        ("not a read", edit, "tool_call_update"),
        ("two files", two, "tool_call_update"),
        ("returned its image", returned, "tool_call_update"),
        ("the call's start", codex_view(&png), "tool_call"),
        // A resumed chat's replayed history: not drawn, and never read again.
        ("a replay", codex_view(&png), "tool_call_update.replay"),
        ("not an image", codex_view("notes.txt"), "tool_call_update"),
        ("an image name on other bytes", codex_view("fake.png"), "tool_call_update"),
        ("gone", codex_view("missing.png"), "tool_call_update"),
        ("too large", codex_view("big.png"), "tool_call_update"),
        ("a folder", codex_view(dir.to_str().unwrap()), "tool_call_update"),
        // A canonicalPath the agent's own update carries never picks the file.
        ("a canonicalPath of the agent's", spoofed, "tool_call_update"),
    ];
    for (why, msg, kind) in cases {
        let mut seen = msg.clone();
        add_read_image(kind, &mut seen, &dir);
        assert_eq!(seen, msg, "{why}");
    }

    // Text it returned stays, and the image follows it.
    let mut text = codex_view(&png);
    text["params"]["update"]["content"] =
        json!([{"type": "content", "content": {"type": "text", "text": "ok"}}]);
    add_read_image("tool_call_update", &mut text, &dir);
    let content = text["params"]["update"]["content"].as_array().unwrap();
    assert_eq!(content.len(), 2, "{text}");
    assert_eq!(content[0]["content"]["text"], "ok");
    assert_eq!(content[1]["content"]["type"], "image");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A FIFO with no writer is refused at once: opening it never waits on the event path.
#[cfg(unix)]
#[test]
fn a_fifo_is_refused_without_waiting() {
    let dir = scratch("fifo");
    let fifo = dir.join("shot.png");
    let name = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    let (done, wait) = std::sync::mpsc::channel();
    let path = fifo.to_str().unwrap().to_owned();
    let dir2 = dir.clone();
    std::thread::spawn(move || {
        let mut msg = codex_view(&path);
        let before = msg.clone();
        add_read_image("tool_call_update", &mut msg, &dir2);
        let _ = done.send(msg == before);
    });
    let unchanged = wait.recv_timeout(std::time::Duration::from_secs(5));
    assert_eq!(unchanged, Ok(true), "a FIFO is left as it came, and at once");
    let _ = std::fs::remove_dir_all(&dir);
}
