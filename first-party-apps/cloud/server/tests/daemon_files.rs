//! The real daemon file op (`LinkDaemonFiles`) against a stand-in for the
//! Mac app's `cmux carrier serve` socket (no network), and the daemon answer
//! and error mapping (request file daemon-fs-for-cloud.md, "Exact wire JSON").

use cmux_cloud::fs::link_files::{decode_answer, fs_error};
use cmux_cloud::fs::{Cancel, DaemonFiles, DialTarget, LinkDaemonFiles};
use serde_json::json;
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, channel};

/// A carrier socket in this test's own folder whose every connection answers
/// the op's dial probe (a `ping`), then runs `serve`, and the requests it
/// read (one line each, the probe left out).
fn carrier(
    name: &str,
    serve: impl Fn(UnixStream, String) + Send + Sync + 'static,
) -> (DialTarget, Receiver<String>) {
    let dir = std::env::temp_dir().join(format!("cx-files-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("carrier.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let (sent, requests) = channel();
    let serve = std::sync::Arc::new(serve);
    std::thread::spawn(move || {
        for connection in listener.incoming().flatten() {
            let (sent, serve) = (sent.clone(), std::sync::Arc::clone(&serve));
            std::thread::spawn(move || {
                let mut reader = BufReader::new(connection.try_clone().unwrap());
                let mut probe = String::new();
                let _ = reader.read_line(&mut probe);
                assert_eq!(probe, "{\"id\":0,\"cmd\":\"ping\"}\n", "the probe goes first");
                let _ = (&connection).write_all(b"{\"id\":0,\"ok\":true}\n");
                let mut line = String::new();
                let _ = reader.read_line(&mut line);
                let _ = sent.send(line.clone());
                serve(connection, line);
            });
        }
    });
    (DialTarget { socket }, requests)
}

#[test]
fn one_stream_sends_one_v12_line_and_reads_one_answer() {
    let (target, requests) = carrier("ok", |mut connection, _| {
        let _ = connection
            .write_all(b"{\"id\":1,\"ok\":true,\"data\":{\"entry\":{\"revision\":\"s2-m1\"}}}\n");
    });
    let data = LinkDaemonFiles
        .call(
            &target,
            "fs.write",
            json!({ "path": "/a", "bytes_base64": "aGk=", "mode": "create" }),
            &Cancel::default(),
        )
        .expect("answer");
    assert_eq!(data, json!({ "entry": { "revision": "s2-m1" } }));
    let sent: serde_json::Value = serde_json::from_str(&requests.recv().unwrap()).unwrap();
    assert_eq!(
        sent,
        json!({ "id": 1, "cmd": "fs.write", "path": "/a", "bytes_base64": "aGk=", "mode": "create" })
    );
}

#[test]
fn a_refused_dial_and_a_gone_carrier_are_typed() {
    // The app's carrier refused the dial: it closes the stream having
    // written nothing, so the probe gets no answer and the op never went out.
    let refused = std::env::temp_dir().join(format!("cx-files-refused-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&refused);
    std::fs::create_dir_all(&refused).unwrap();
    let socket = refused.join("carrier.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    std::thread::spawn(move || {
        for connection in listener.incoming().flatten() {
            drop(connection);
        }
    });
    let err = LinkDaemonFiles
        .call(&DialTarget { socket }, "fs.write", json!({ "path": "/a" }), &Cancel::default())
        .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.link_down", "{err:?}");
    assert!(err.retryable, "nothing went out: even a write may run again");
    // The daemon went away after the request went out: a read may run again.
    let (target, _) = carrier("lost", |connection, _| drop(connection));
    let err = LinkDaemonFiles
        .call(&target, "fs.stat", json!({ "path": "/a" }), &Cancel::default())
        .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.link_answer_lost", "{err:?}");
    assert!(err.retryable, "a read may run again");
    // No carrier at all (the app's serve child ended): nothing went out.
    let gone = DialTarget { socket: PathBuf::from("/tmp/cx-files-no-such-carrier.sock") };
    let err = LinkDaemonFiles
        .call(&gone, "fs.write", json!({ "path": "/a" }), &Cancel::default())
        .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.link_down", "{err:?}");
    assert!(err.message.contains("unreachable"), "{}", err.message);
    assert!(err.retryable, "a carrier that is not running is retryable");
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

/// A cancel ends the carrier stream at once (the op answers long before its
/// 30 s bound), while the daemon behind it never answers.
#[test]
fn a_cancel_ends_the_carrier_stream() {
    let (held, streams) = channel();
    let held = std::sync::Mutex::new(held);
    let (target, requests) = carrier("cancel", move |connection, _| {
        // A daemon that never answers: the test keeps the stream open.
        let _ = held.lock().unwrap().send(connection);
    });
    let cancel = Cancel::default();
    let worker_cancel = cancel.clone();
    let started = std::time::Instant::now();
    let worker = std::thread::spawn(move || {
        LinkDaemonFiles.call(&target, "fs.stat", json!({ "path": "/a" }), &worker_cancel)
    });
    requests.recv_timeout(std::time::Duration::from_secs(5)).expect("the request came");
    let _open = streams.recv_timeout(std::time::Duration::from_secs(5)).expect("held open");
    cancel.cancel();
    let outcome = worker.join().expect("worker");
    assert!(outcome.is_err(), "a cancelled op is an error");
    assert!(started.elapsed() < std::time::Duration::from_secs(10), "it ended at once");
}

#[test]
fn a_reply_slower_than_the_request_still_arrives() {
    // The real carrier ends the remote stream when its client half-closes
    // (pump_mux_client_buffered reads that EOF as done), so the request must
    // keep its write side open until the answer: a stand-in that drops the
    // stream on EOF and answers only after network latency.
    let (target, _) = carrier("slow", |mut connection, _| {
        connection.set_read_timeout(Some(std::time::Duration::from_millis(300))).unwrap();
        let mut probe = [0u8; 1];
        if matches!(std::io::Read::read(&mut connection, &mut probe), Ok(0)) {
            return;
        }
        let _ = connection
            .write_all(b"{\"id\":1,\"ok\":true,\"data\":{\"entry\":{\"revision\":\"s3\"}}}\n");
    });
    let data = LinkDaemonFiles
        .call(&target, "fs.stat", json!({ "path": "/a" }), &Cancel::default())
        .expect("the answer after the delay");
    assert_eq!(data, json!({ "entry": { "revision": "s3" } }));
}

#[test]
fn an_op_cancelled_while_the_carrier_dials_never_goes_out() {
    // A carrier that is still dialing: it accepts, reads nothing back for the
    // probe, and records every byte it got until the client is gone.
    let dir = std::env::temp_dir().join(format!("cx-files-dialing-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("carrier.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let (got, received) = channel();
    std::thread::spawn(move || {
        for connection in listener.incoming().flatten() {
            let mut bytes = Vec::new();
            let _ = std::io::Read::read_to_end(&mut &connection, &mut bytes);
            let _ = got.send(String::from_utf8_lossy(&bytes).into_owned());
        }
    });
    let cancel = Cancel::default();
    let worker_cancel = cancel.clone();
    let worker = std::thread::spawn(move || {
        LinkDaemonFiles.call(&DialTarget { socket }, "fs.delete", json!({ "path": "/a" }), &worker_cancel)
    });
    std::thread::sleep(std::time::Duration::from_millis(200));
    cancel.cancel();
    let outcome = worker.join().expect("worker");
    assert!(outcome.is_err(), "a cancelled op is an error");
    let bytes = received.recv_timeout(std::time::Duration::from_secs(5)).expect("the stream ended");
    assert_eq!(bytes, "{\"id\":0,\"cmd\":\"ping\"}\n", "only the probe went out, never the delete");
}
