//! The real daemon file op (`LinkDaemonFiles`) against a `/bin/sh` stand-in
//! for `cmux link dial` (no network), and the daemon answer and error
//! mapping (request file daemon-fs-for-cloud.md, "Exact wire JSON").

use cmux_cloud::fs::link_files::{decode_answer, fs_error};
use cmux_cloud::fs::{Cancel, DaemonFiles, DialTarget, LinkDaemonFiles};
use serde_json::json;
use std::path::PathBuf;

fn sh_target(script: &str, name: &str) -> (DialTarget, PathBuf) {
    let dir = std::env::temp_dir().join(format!("cx-files-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let request = dir.join("request.json");
    // A wrapper script stands in for the `cmux` binary; it gets the real
    // argv (`link dial --host <host>`) and writes the request it read to OUT.
    let wrapper = dir.join("dial.sh");
    std::fs::write(&wrapper, format!("#!/bin/sh\nOUT='{}'\n{script}\n", request.display()))
        .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    let target = DialTarget {
        binary: wrapper,
        host: "host-vm-alpha01".into(),
        env: vec![("PATH".into(), "/usr/bin:/bin".into())],
    };
    (target, request)
}

#[cfg(unix)]
#[test]
fn one_dial_sends_one_v12_line_and_reads_one_answer() {
    let script = r#"test "$1 $2 $3 $4" = "link dial --host host-vm-alpha01" || exit 9
printf '%s\n' '{"relay_available":false,"path_state":"direct","ok":true}' >&2
IFS= read -r line
printf '%s' "$line" > "$OUT"
printf '%s\n' '{"id":1,"ok":true,"data":{"entry":{"revision":"s2-m1"}}}'"#;
    let (target, request) = sh_target(script, "ok");
    let data = LinkDaemonFiles
        .call(
            &target,
            "fs.write",
            json!({ "path": "/a", "bytes_base64": "aGk=", "mode": "create" }),
            &Cancel::default(),
        )
        .expect("answer");
    assert_eq!(data, json!({ "entry": { "revision": "s2-m1" } }));
    let sent: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&request).unwrap()).unwrap();
    assert_eq!(
        sent,
        json!({ "id": 1, "cmd": "fs.write", "path": "/a", "bytes_base64": "aGk=", "mode": "create" })
    );
}

#[cfg(unix)]
#[test]
fn a_refused_dial_and_a_missing_reply_line_are_typed() {
    let refused = r#"printf '%s\n' '{"ok":false,"error_code":"host_paused","path_state":"unreachable","relay_available":false}' >&2; exit 4"#;
    let (target, _) = sh_target(refused, "refused");
    let err = LinkDaemonFiles
        .call(&target, "fs.stat", json!({ "path": "/a" }), &Cancel::default())
        .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.link_down");
    assert!(err.message.contains("host_paused"), "{}", err.message);
    let silent = "exit 6";
    let (target, _) = sh_target(silent, "silent");
    let err = LinkDaemonFiles
        .call(&target, "fs.stat", json!({ "path": "/a" }), &Cancel::default())
        .unwrap_err();
    assert!(err.retryable, "a link that is not running is retryable");
}

#[test]
fn answers_and_errors_map_as_the_request_file_says() {
    assert_eq!(
        decode_answer("fs.stat", br#"{"id":1,"ok":true,"data":{"size":3}}"#),
        Ok(json!({"size":3}))
    );
    for (daemon, ours) in [
        ("fs.not_found", "cmux.cloud.not_found"),
        ("fs.permission_denied", "cmux.cloud.forbidden"),
        ("fs.read_only", "cmux.cloud.forbidden"),
        ("fs.exists", "cmux.cloud.conflict"),
        ("fs.revision_mismatch", "cmux.cloud.conflict"),
        ("fs.not_empty", "cmux.cloud.conflict"),
        ("fs.not_a_file", "cmux.cloud.invalid_args"),
        ("fs.not_a_directory", "cmux.cloud.invalid_args"),
        ("params.invalid", "cmux.cloud.invalid_args"),
        ("fs.too_large", "cmux.cloud.file_too_large"),
        ("fs.something_new", "cmux.cloud.upstream_error"),
    ] {
        // The daemon's v12 envelope (decision D1): text in "error", the code
        // in "error_code", details in "error_details".
        let line = json!({ "id": 1, "ok": false, "error": "m", "error_code": daemon });
        let err = decode_answer("fs.stat", line.to_string().as_bytes()).unwrap_err();
        assert_eq!(err.code, ours, "{daemon}");
        assert_eq!(err.upstream_code.as_deref(), Some(daemon));
        assert_eq!(fs_error(daemon, "m").code, ours);
    }
    let line = json!({ "id": 1, "ok": false, "error": "changed", "error_code": "fs.revision_mismatch",
        "error_details": { "current": "s3-m9" } });
    let err = decode_answer("fs.write", line.to_string().as_bytes()).unwrap_err();
    assert_eq!(err.message, "changed");
    assert_eq!(err.details, Some(json!({ "current": "s3-m9" })), "details are kept");
    let err = decode_answer("fs.stat", b"not json").unwrap_err();
    assert_eq!(err.code, "cmux.cloud.bad_response");
}

/// A cancel ends the dial child at once (the op answers long before its
/// 30 s bound) and the child does not outlive the op.
#[cfg(unix)]
#[test]
fn a_cancel_ends_the_dial_child() {
    let script = r#"printf '%s\n' '{"ok":true,"path_state":"direct"}' >&2
echo $$ > "$OUT"
exec sleep 30"#;
    let (target, pid_file) = sh_target(script, "cancel");
    let cancel = Cancel::default();
    let worker_cancel = cancel.clone();
    let started = std::time::Instant::now();
    let worker = std::thread::spawn(move || {
        LinkDaemonFiles.call(&target, "fs.stat", json!({ "path": "/a" }), &worker_cancel)
    });
    // Wait until the child runs (tests may sleep).
    for _ in 0..200 {
        if std::fs::read_to_string(&pid_file).is_ok_and(|p| !p.trim().is_empty()) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    cancel.cancel();
    let outcome = worker.join().expect("worker");
    assert!(outcome.is_err(), "a cancelled op is an error");
    assert!(started.elapsed() < std::time::Duration::from_secs(10), "it ended at once");
    let pid = std::fs::read_to_string(&pid_file).unwrap();
    let alive = std::process::Command::new("/bin/kill")
        .args(["-0", pid.trim()])
        .status()
        .is_ok_and(|s| s.success());
    assert!(!alive, "the dial child {pid} was ended");
}
