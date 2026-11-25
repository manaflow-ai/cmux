//! `apps.call` and `apps.listener` on the agent socket (`apps_call.rs`).

use std::os::unix::fs::MetadataExt as _;
use std::os::unix::net::UnixStream;

use serde_json::json;

use super::apps_call::{AppsCall, check_call, check_listener, listener_reply, peer_uid, reply_for};
use super::sender::Answer;

fn call(method: &str, path: &str) -> serde_json::Value {
    json!({"method": method, "path": path, "body": {"commit": "abc"}, "idempotencyKey": "web:abc:v1.1"})
}

#[test]
fn a_path_outside_the_apps_routes_is_refused() {
    for path in [
        "/v1/me/github",
        "/v1/ops",
        "/v1/integrations/github/token",
        "/v1/cloud/appsx",
        "/v1/cloud/apps/",
        "/v1/cloud/apps//versions",
        "/v1/cloud/apps/../../ops",
        "/v1/cloud/apps/web/%2e%2e",
        "/v1/cloud/apps/web?x=1",
        "/v1/cloud/apps/web#x",
        "https://elsewhere.example/v1/cloud/apps",
        "v1/cloud/apps",
        "",
    ] {
        let refused = check_call(&call("POST", path));
        assert!(refused.is_err(), "{path:?} was accepted");
        assert!(refused.unwrap_err().contains("/v1/cloud/apps"), "{path:?}");
    }
}

#[test]
fn the_apps_routes_are_accepted_as_asked() {
    for path in [
        "/v1/cloud/apps",
        "/v1/cloud/apps/web",
        "/v1/cloud/apps/web/versions",
        "/v1/cloud/apps/web/grants",
    ] {
        let checked = check_call(&call("POST", path)).unwrap();
        assert_eq!(
            checked,
            AppsCall {
                method: "POST".into(),
                path: path.into(),
                body: Some(json!({"commit": "abc"})),
                idempotency_key: Some("web:abc:v1.1".into()),
            }
        );
    }
    assert!(
        check_call(&json!({"method": "GET", "path": "/v1/cloud/apps"})).unwrap().body.is_none()
    );
}

#[test]
fn other_methods_bodies_and_keys_are_refused() {
    assert!(check_call(&call("PATCH", "/v1/cloud/apps")).is_err());
    assert!(check_call(&json!({"method": "POST", "path": "/v1/cloud/apps", "body": "x"})).is_err());
    let bad_key = json!({"method": "POST", "path": "/v1/cloud/apps", "idempotencyKey": "a b"});
    assert!(check_call(&bad_key).is_err());
}

#[test]
fn the_reply_carries_the_status_body_and_machine_never_a_bearer() {
    let answer =
        Answer::Http { status: 502, body: json!({"error": {"code": "cloud.app.promote_failed"}}) };
    assert_eq!(
        reply_for(&answer, "vm_1"),
        json!({"ok": true, "status": 502, "body": {"error": {"code": "cloud.app.promote_failed"}}, "machine": "vm_1"})
    );
    assert_eq!(reply_for(&Answer::Transport, "vm_1")["ok"], false);
}

#[test]
fn a_listener_port_must_be_a_port() {
    assert_eq!(check_listener(&json!({"port": 3000})), Ok(3000));
    assert!(check_listener(&json!({"port": 0})).is_err());
    assert!(check_listener(&json!({"port": 70000})).is_err());
    assert!(check_listener(&json!({})).is_err());
}

/// A fake `proc` with process 77 listening on port 3000 in `cwd`.
fn fake_proc(root: &std::path::Path, cwd: &std::path::Path) {
    let table = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   \
                 0: 0100007F:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 4242 1 0000000000000000 100 0 0 10 0\n";
    std::fs::create_dir_all(root.join("net")).unwrap();
    std::fs::write(root.join("net/tcp"), table).unwrap();
    std::fs::create_dir_all(root.join("77/fd")).unwrap();
    std::os::unix::fs::symlink("socket:[4242]", root.join("77/fd/7")).unwrap();
    std::os::unix::fs::symlink(cwd, root.join("77/cwd")).unwrap();
    std::fs::write(root.join("77/cmdline"), b"node\0server.js\0").unwrap();
    std::fs::write(root.join("77/stat"), b"77 (node) S 1 77 77 0").unwrap();
}

#[test]
fn the_listener_is_answered_to_its_own_user_only() {
    let dir = tempfile::tempdir().unwrap();
    let proc_root = dir.path().join("proc");
    fake_proc(&proc_root, dir.path());
    let owner = std::fs::metadata(proc_root.join("77")).unwrap().uid();

    let mine = listener_reply(&proc_root, Ok(3000), Some(owner));
    assert_eq!(mine["ok"], true, "{mine}");
    assert_eq!(mine["pid"], 77);
    assert_eq!(mine["command"], "node server.js");
    assert_eq!(mine["dir"], dir.path().display().to_string());

    let theirs = listener_reply(&proc_root, Ok(3000), Some(owner.wrapping_add(1).max(1)));
    if owner != 0 {
        assert_eq!(theirs["ok"], false);
        assert!(theirs["error"]["message"].as_str().unwrap().contains("--cmd"));
    }
    assert_eq!(listener_reply(&proc_root, Ok(3000), None)["ok"], false);
    assert_eq!(listener_reply(&proc_root, Ok(4000), Some(owner))["error"]["code"], "app.infer");
}

#[test]
fn the_peer_is_the_connecting_user() {
    let (a, _b) = UnixStream::pair().unwrap();
    // SAFETY: geteuid has no preconditions.
    assert_eq!(peer_uid(&a), Some(unsafe { libc::geteuid() }));
}
