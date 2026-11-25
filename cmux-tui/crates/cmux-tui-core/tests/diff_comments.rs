#![cfg(unix)]
//! `diff.comments.*` over a real session socket: the diff page's review
//! comments are saved, edited, listed and deleted per worktree root, the
//! daemon stamps ids and times, and they are kept on disk.

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

fn unique(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

struct Client {
    stream: BufReader<UnixStream>,
    next: u64,
}

impl Client {
    fn connect(path: &Path) -> Self {
        let stream = UnixStream::connect(path).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(12))).unwrap();
        Self { stream: BufReader::new(stream), next: 0 }
    }

    /// One request; mutations get a fresh idempotency key unless `key` names one.
    fn request(&mut self, operation: &str, mut params: Value, key: Option<&str>) -> Value {
        self.next += 1;
        let id = format!("r{}", self.next);
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
        if operation != "diff.comments.list" {
            request["idempotency_key"] = json!(key.map_or_else(|| unique("dc"), str::to_string));
        }
        writeln!(self.stream.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.stream.read_line(&mut line).unwrap(), 0, "closed before {id}");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == id {
                return reply;
            }
        }
    }

    fn ok(&mut self, operation: &str, params: Value) -> Value {
        let reply = self.request(operation, params, None);
        assert_eq!(reply["ok"], true, "{operation} failed: {reply}");
        reply["result"].clone()
    }

    fn list(&mut self, root: &str) -> Vec<Value> {
        let listed = self.ok("diff.comments.list", json!({"root": root}));
        assert_eq!(listed["root"], root, "{listed}");
        listed["comments"].as_array().unwrap().clone()
    }
}

#[test]
fn cmux_next_diff_comments_persist_until_deleted() {
    let dir = std::env::temp_dir().join(unique("dcm"));
    std::fs::create_dir_all(&dir).unwrap();
    let state = dir.join("state");
    let mux =
        Mux::open_persistent(unique("diff-comments"), SurfaceOptions::default(), &state).unwrap();
    let socket = dir.join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();

    let mut identify = BufReader::new(UnixStream::connect(&socket).unwrap());
    writeln!(identify.get_mut(), r#"{{"id":1,"cmd":"identify"}}"#).unwrap();
    let mut line = String::new();
    identify.read_line(&mut line).unwrap();
    let identified: Value = serde_json::from_str(&line).unwrap();
    let capabilities = identified["data"]["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "diff-comments-v1"), "{identified}");

    let root = "/work/repo";
    let mut client = Client::connect(&socket);
    assert!(client.list(root).is_empty(), "a root with no file lists none");

    let first = client.ok(
        "diff.comments.save",
        json!({"root": root, "comment": {
            "filePath": "src/a.rs", "side": "new", "startLine": 3, "endLine": 4,
            "lineText": "let x = 1;", "message": "rename x",
        }}),
    );
    assert_eq!(first["replayed"], false, "{first}");
    let first = first["value"]["comment"].clone();
    let first_id = first["id"].as_str().unwrap().to_string();
    assert!(!first_id.is_empty(), "{first}");
    assert_eq!(first["createdAt"], first["updatedAt"], "{first}");
    assert_eq!(first["message"], "rename x");
    std::thread::sleep(Duration::from_millis(5));
    let second = client.ok(
        "diff.comments.save",
        json!({"root": root, "comment": {"filePath": "b.rs", "message": "second", "id": "page-7"}}),
    )["value"]["comment"]
        .clone();
    assert_eq!(second["id"], "page-7", "an unknown well-formed id is kept: {second}");

    let listed = client.list(root);
    let ids: Vec<_> = listed.iter().map(|comment| comment["id"].clone()).collect();
    assert_eq!(ids, [json!(first_id), json!("page-7")], "oldest first: {listed:?}");
    assert!(client.list("/work/other").is_empty(), "roots are separate");

    std::thread::sleep(Duration::from_millis(5));
    let edited = client.ok(
        "diff.comments.save",
        json!({"root": root, "comment": {
            "id": first_id, "filePath": "src/a.rs", "message": "rename x to count",
            "createdAt": "1999-01-01T00:00:00.000Z",
        }}),
    )["value"]["comment"]
        .clone();
    assert_eq!(edited["id"], json!(first_id));
    assert_eq!(edited["createdAt"], first["createdAt"], "an edit keeps createdAt: {edited}");
    assert_ne!(edited["updatedAt"], first["updatedAt"], "{edited}");
    let listed = client.list(root);
    assert_eq!(listed.len(), 2, "an edit replaces: {listed:?}");
    assert_eq!(listed[0]["message"], "rename x to count");

    // A retry under the same key replays the first result.
    let params = json!({"root": root, "ids": [first_id, "unknown"]});
    let deleted = client.request("diff.comments.delete", params.clone(), Some("delete-once"));
    assert_eq!(deleted["result"]["value"]["deleted"], 1, "{deleted}");
    let again = client.request("diff.comments.delete", params, Some("delete-once"));
    assert_eq!(again["result"]["replayed"], true, "{again}");
    assert_eq!(again["result"]["value"]["deleted"], 1, "{again}");
    let listed = client.list(root);
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0]["id"], "page-7");

    for bad in ["relative/path", "", "/a\u{0}b"] {
        let refused = client.request("diff.comments.list", json!({"root": bad}), None);
        assert_eq!(refused["ok"], false, "{refused}");
        assert_eq!(refused["error"]["code"], "validation.invalid", "{refused}");
    }
    let refused = client.request(
        "diff.comments.save",
        json!({"root": root, "comment": {"message": "x".repeat(70 * 1024)}}),
        None,
    );
    assert_eq!(refused["error"]["code"], "validation.invalid", "{refused}");

    // The comments are on disk under the session's state directory, which
    // every list reads (nothing is cached), so they outlive the host.
    let stored = mux.session_state_directory().unwrap().join("diff-comments");
    let files: Vec<_> =
        std::fs::read_dir(&stored).unwrap().map(|entry| entry.unwrap().path()).collect();
    assert_eq!(files.len(), 1, "one file per root: {files:?}");
    let on_disk: Value = serde_json::from_slice(&std::fs::read(&files[0]).unwrap()).unwrap();
    assert_eq!(on_disk["root"], root, "{on_disk}");
    assert_eq!(on_disk["comments"][0]["id"], "page-7", "{on_disk}");
    assert_eq!(on_disk["comments"][0]["createdAt"], second["createdAt"], "{on_disk}");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&files[0]).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "comments are private");
    }

    drop(client);
    mux.shutdown();
    server::cleanup(&socket);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn cmux_next_diff_comments_need_a_state_directory() {
    let dir = std::env::temp_dir().join(unique("dcn"));
    std::fs::create_dir_all(&dir).unwrap();
    let mux = Mux::new(unique("diff-comments-memory"), SurfaceOptions::default());
    let socket = dir.join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    let mut client = Client::connect(&socket);
    let refused = client.request("diff.comments.list", json!({"root": "/r"}), None);
    assert_eq!(refused["error"]["code"], "operation.failed", "{refused}");
    assert_eq!(refused["error"]["details"]["reason"], "no_state_directory", "{refused}");
    drop(client);
    mux.shutdown();
    server::cleanup(&socket);
    let _ = std::fs::remove_dir_all(&dir);
}
