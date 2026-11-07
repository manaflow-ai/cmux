//! The C ABI against a mock daemon: connect, a read, a mutation with its
//! key, an older command line and its refusal, and a stream read to its
//! cancel. Each test checks the exact request the daemon saw and the JSON
//! the app gets back.
#![cfg(unix)]

use cmux_sdk_ffi::{
    CmuxSdkBytes, CmuxSdkClient, CmuxSdkStream, ERR_INVALID, ERR_NULL, KIND_MUTATION, KIND_READ,
    OK, cmux_sdk_bytes_free, cmux_sdk_call, cmux_sdk_cancel, cmux_sdk_close, cmux_sdk_command,
    cmux_sdk_connect, cmux_sdk_next, cmux_sdk_stream_free, cmux_sdk_subscribe,
};
use serde_json::{Value, json};
use std::ffi::CString;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;

static NEXT_SOCKET: AtomicU64 = AtomicU64::new(1);

fn socket_path() -> PathBuf {
    std::env::temp_dir().join(format!(
        "cmux-sdk-ffi-{}-{}.sock",
        std::process::id(),
        NEXT_SOCKET.fetch_add(1, Ordering::Relaxed)
    ))
}

fn line(reader: &mut BufReader<UnixStream>) -> Value {
    let mut text = String::new();
    assert_ne!(reader.read_line(&mut text).unwrap(), 0, "the client closed early");
    serde_json::from_str(&text).unwrap()
}

fn respond(stream: &mut UnixStream, request: &Value, body: Value) {
    let mut envelope = json!({"protocol": "cmux.protocol/2", "type": "response",
                              "id": request["id"]});
    envelope.as_object_mut().unwrap().extend(body.as_object().unwrap().clone());
    writeln!(stream, "{envelope}").unwrap();
}

fn empty() -> CmuxSdkBytes {
    CmuxSdkBytes { ptr: std::ptr::null_mut(), len: 0 }
}

fn take(out: CmuxSdkBytes) -> Value {
    assert!(!out.ptr.is_null());
    let text = unsafe { std::slice::from_raw_parts(out.ptr, out.len) }.to_vec();
    unsafe { cmux_sdk_bytes_free(out) };
    serde_json::from_slice(&text).unwrap()
}

struct Client(*mut CmuxSdkClient);

impl Drop for Client {
    fn drop(&mut self) {
        unsafe { cmux_sdk_close(self.0) };
    }
}

fn connect(path: &PathBuf) -> Client {
    let path = CString::new(path.to_str().unwrap()).unwrap();
    let mut client = std::ptr::null_mut();
    let mut out = empty();
    assert_eq!(unsafe { cmux_sdk_connect(path.as_ptr(), 2000, &mut client, &mut out) }, OK);
    assert!(out.ptr.is_null() && !client.is_null());
    Client(client)
}

fn call(client: &Client, op: &str, kind: i32, key: Option<&str>, params: &Value) -> Value {
    let op = CString::new(op).unwrap();
    let key = key.map(|key| CString::new(key).unwrap());
    let params = params.to_string();
    let mut out = empty();
    let code = unsafe {
        cmux_sdk_call(
            client.0,
            op.as_ptr(),
            kind,
            key.as_ref().map_or(std::ptr::null(), |key| key.as_ptr()),
            params.as_ptr(),
            params.len(),
            &mut out,
        )
    };
    assert_eq!(code, OK);
    take(out)
}

#[test]
fn reads_and_mutations_go_through_the_sdk() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let list = line(&mut reader);
        assert_eq!(list["operation"], "conversation.list");
        assert_eq!(list["params"], json!({"machine": "current", "session": "current"}));
        assert!(list.get("idempotency_key").is_none());
        respond(&mut stream, &list, json!({"ok": true, "result": {"conversations": []}}));
        let send = line(&mut reader);
        assert_eq!(send["operation"], "conversation.send");
        assert_eq!(send["idempotency_key"], "send-1");
        respond(
            &mut stream,
            &send,
            json!({"ok": false, "error": {"code": "operation.failed", "message": "not_participant",
                   "details": {"reason": "not_participant"}, "retryable": false}}),
        );
    });

    let client = connect(&path);
    let here = json!({"machine": "current", "session": "current"});
    let listed = call(&client, "conversation.list", KIND_READ, None, &here);
    assert_eq!(listed, json!({"ok": true, "result": {"conversations": []}}));
    let refused = call(&client, "conversation.send", KIND_MUTATION, Some("send-1"), &here);
    assert_eq!(refused["ok"], false);
    assert_eq!(refused["error"]["code"], "operation.failed");
    assert_eq!(refused["error"]["details"]["reason"], "not_participant");
    assert_eq!(refused["error"]["retryable"], false);

    // A mutation without its key, and a read with one, are refused locally.
    let op = CString::new("conversation.send").unwrap();
    let mut out = empty();
    let no_key = unsafe {
        cmux_sdk_call(
            client.0,
            op.as_ptr(),
            KIND_MUTATION,
            std::ptr::null(),
            std::ptr::null(),
            0,
            &mut out,
        )
    };
    assert_eq!(no_key, ERR_INVALID);
    assert!(out.ptr.is_null());
    let null = unsafe {
        cmux_sdk_call(
            std::ptr::null(),
            op.as_ptr(),
            KIND_READ,
            std::ptr::null(),
            std::ptr::null(),
            0,
            &mut out,
        )
    };
    assert_eq!(null, ERR_NULL);
    drop(client);
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn command_lines_return_data_and_whole_refusals() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let _protocol = listener.accept().unwrap();
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let history = line(&mut reader);
        assert_eq!(history["cmd"], "cloud-conversation-history");
        assert_eq!(history["conversation"], "conv_1");
        writeln!(stream, "{}", json!({"id": history["id"], "ok": true, "data": {"messages": [1]}}))
            .unwrap();
        let refused = line(&mut reader);
        writeln!(
            stream,
            "{}",
            json!({"id": refused["id"], "ok": false, "error_code": "cloud_unavailable",
                   "error": "signed out", "reason": "missing"})
        )
        .unwrap();
    });

    let client = connect(&path);
    let command = |name: &str, params: &Value| {
        let name = CString::new(name).unwrap();
        let params = params.to_string();
        let mut out = empty();
        let code = unsafe {
            cmux_sdk_command(client.0, name.as_ptr(), params.as_ptr(), params.len(), &mut out)
        };
        assert_eq!(code, OK);
        take(out)
    };
    let history = command("cloud-conversation-history", &json!({"conversation": "conv_1"}));
    assert_eq!(history, json!({"ok": true, "result": {"messages": [1]}}));
    let refused = command("cloud-inbox-list", &json!({}));
    assert_eq!(refused["error"]["code"], "cloud_unavailable");
    assert_eq!(refused["error"]["message"], "signed out");
    assert_eq!(refused["error"]["details"]["reason"], "missing");
    drop(client);
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn a_stream_yields_items_and_ends_when_canceled() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let _control = listener.accept().unwrap();
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let open = line(&mut reader);
        assert_eq!(open["operation"], "conversation.events");
        let stream_id = open["params"]["stream_id"].as_str().unwrap().to_string();
        respond(&mut stream, &open, json!({"ok": true, "result": {"stream_id": stream_id}}));
        writeln!(
            stream,
            "{}",
            json!({"protocol": "cmux.protocol/2", "type": "stream_item", "stream_id": stream_id,
                   "sequence": "0", "item": {"type": "snapshot", "messages": []}})
        )
        .unwrap();
        let cancel = line(&mut reader);
        assert_eq!(cancel["operation"], "stream.cancel");
        respond(&mut stream, &cancel, json!({"ok": true, "result": {}}));
        writeln!(
            stream,
            "{}",
            json!({"protocol": "cmux.protocol/2", "type": "stream_end", "stream_id": stream_id,
                   "reason": "canceled"})
        )
        .unwrap();
    });

    let client = connect(&path);
    let op = CString::new("conversation.events").unwrap();
    let params =
        json!({"machine": "current", "session": "current", "conversation": "conv_1"}).to_string();
    let mut stream: *mut CmuxSdkStream = std::ptr::null_mut();
    let mut out = empty();
    let code = unsafe {
        cmux_sdk_subscribe(
            client.0,
            op.as_ptr(),
            params.as_ptr(),
            params.len(),
            &mut stream,
            &mut out,
        )
    };
    assert_eq!(code, OK);
    assert!(out.ptr.is_null() && !stream.is_null());

    let next = |timeout_ms: u32| {
        let mut out = empty();
        assert_eq!(unsafe { cmux_sdk_next(stream, timeout_ms, &mut out) }, OK);
        take(out)
    };
    let item = next(2000);
    assert_eq!(item["item"]["sequence"], 0);
    assert_eq!(item["item"]["value"], json!({"type": "snapshot", "messages": []}));
    assert_eq!(next(20), json!({"timed_out": true}));
    assert_eq!(unsafe { cmux_sdk_cancel(stream) }, OK);
    let end = next(2000);
    assert_eq!(end["end"]["reason"], "canceled");
    unsafe { cmux_sdk_stream_free(stream) };
    drop(client);
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn a_missing_socket_is_an_error_envelope() {
    let path = CString::new(socket_path().to_str().unwrap()).unwrap();
    let mut client = std::ptr::null_mut();
    let mut out = empty();
    assert_eq!(unsafe { cmux_sdk_connect(path.as_ptr(), 500, &mut client, &mut out) }, OK);
    assert!(client.is_null());
    let failure = take(out);
    assert_eq!(failure["ok"], false);
    assert_eq!(failure["error"]["code"], "connection");
}
