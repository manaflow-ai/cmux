//! Saved-file commands must issue exactly one file GET, even on failure.
//! A mock with no lifecycle/exec routes detects accidental compute wakes.

use std::io::{self, Write};

use cmux_vm::exit;
use serde_json::json;
use wiremock::matchers::{header, method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

const VM: &str = "vm_0123456789abcdefghjkmnpqrs";

async fn run(server: &MockServer, args: &[&str], out: &mut dyn Write) -> (i32, String) {
    let uri = server.uri();
    let env = |name: &str| match name {
        "CMUX_VM_API_KEY" => Some("cmuxvm_sk_test".into()),
        "CMUX_VM_BASE_URL" => Some(uri.clone()),
        "CMUX_VM_TEAM_ID" => Some("team_test".into()),
        _ => None,
    };
    let mut stderr = Vec::new();
    let code = cmux_vm::run(
        std::iter::once("cmux-vm").chain(args.iter().copied()),
        &env,
        &mut cmux_vm::NoPrompt,
        out,
        &mut stderr,
    )
    .await;
    (code, String::from_utf8(stderr).unwrap())
}

#[tokio::test]
async fn saved_file_read_preserves_binary_bytes_without_lifecycle_calls() {
    let server = MockServer::start().await;
    let bytes = vec![0, 255, 13, 10, 0, 128];
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM}/files/content")))
        .and(query_param("path", "/workspace/a b?#.bin"))
        .and(header("authorization", "Bearer cmuxvm_sk_test"))
        .and(header("x-cmux-team-id", "team_test"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(bytes.clone()))
        .expect(1)
        .mount(&server)
        .await;
    let mut out = Vec::new();
    let (code, err) = run(
        &server,
        &["file", "read", VM, "/workspace/a b?#.bin"],
        &mut out,
    )
    .await;
    assert_eq!(code, exit::OK, "{err}");
    assert_eq!(out, bytes);
    assert_eq!(server.received_requests().await.unwrap().len(), 1);
}

#[tokio::test]
async fn saved_file_read_accepts_partial_content_and_open_ranges() {
    for range in ["bytes=4-7", "bytes=4-"] {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path(format!("/v1/vms/{VM}/files/content")))
            .and(header("range", range))
            .respond_with(
                ResponseTemplate::new(206)
                    .insert_header("content-range", "bytes 4-7/8")
                    .set_body_bytes(b"tail"),
            )
            .expect(1)
            .mount(&server)
            .await;
        let mut out = Vec::new();
        let (code, err) = run(
            &server,
            &["file", "read", VM, "/log", "--range", range],
            &mut out,
        )
        .await;
        assert_eq!(code, exit::OK, "{err}");
        assert_eq!(out, b"tail");
        assert_eq!(server.received_requests().await.unwrap().len(), 1);
    }
}

#[tokio::test]
async fn saved_file_range_is_not_silently_replaced_by_the_whole_file() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(b"whole file"))
        .expect(1)
        .mount(&server)
        .await;
    let mut out = Vec::new();
    let (code, err) = run(
        &server,
        &["file", "read", VM, "/log", "--range", "bytes=4-"],
        &mut out,
    )
    .await;
    assert_eq!(code, exit::UNEXPECTED);
    assert!(err.contains("ignored"));
    assert!(out.is_empty());
}

#[tokio::test]
async fn saved_file_list_preserves_json_and_escapes_terminal_control_characters() {
    let server = MockServer::start().await;
    let entries = json!({"entries":[{"name":"a\u{1b}[2J\nfile", "kind":"file"},{"name":"src", "kind":"directory"}], "future":true});
    Mock::given(method("GET"))
        .and(path(format!("/v1/vms/{VM}/files/entries")))
        .and(query_param("path", "/workspace"))
        .respond_with(ResponseTemplate::new(200).set_body_json(&entries))
        .expect(2)
        .mount(&server)
        .await;
    let mut out = Vec::new();
    let (code, err) = run(
        &server,
        &["--json", "file", "ls", VM, "/workspace"],
        &mut out,
    )
    .await;
    assert_eq!(code, exit::OK, "{err}");
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&out).unwrap(),
        entries
    );
    out.clear();
    let (code, err) = run(&server, &["file", "ls", VM, "/workspace"], &mut out).await;
    assert_eq!(code, exit::OK, "{err}");
    let text = String::from_utf8(out).unwrap();
    assert!(!text.contains('\u{1b}'));
    assert!(text.contains("\\nfile"));
    assert!(text.contains("directory\tsrc"));
    assert_eq!(server.received_requests().await.unwrap().len(), 2);
}

#[tokio::test]
async fn saved_file_invalid_arguments_send_no_requests() {
    let server = MockServer::start().await;
    for verb in ["read", "ls", "stat"] {
        for (vm, file) in [
            (VM, "relative"),
            (VM, "/a/../b"),
            ("private-provider-id", "/a"),
        ] {
            let (code, _) = run(&server, &["file", verb, vm, file], &mut Vec::new()).await;
            assert_eq!(code, exit::USAGE);
        }
    }
    for range in [
        "bytes=-4",
        "bytes=9-4",
        "bytes=0-1,4-5",
        "bad",
        "bytes=18446744073709551615-",
    ] {
        let (code, _) = run(
            &server,
            &["file", "read", VM, "/a", "--range", range],
            &mut Vec::new(),
        )
        .await;
        assert_eq!(code, exit::USAGE, "{range}");
    }
    let mut out = Vec::new();
    let (code, err) = run(&server, &["--json", "file", "read", VM, "/a"], &mut out).await;
    assert_eq!(code, exit::USAGE);
    assert!(serde_json::from_str::<serde_json::Value>(&err).is_ok());
    assert!(out.is_empty());
    assert!(server.received_requests().await.unwrap().is_empty());
}

#[tokio::test]
async fn saved_file_errors_do_not_retry_or_wake_the_vm() {
    for (status, expected) in [
        (403, exit::FORBIDDEN),
        (404, exit::NOT_FOUND),
        (409, exit::CONFLICT),
        (503, exit::SERVICE_UNAVAILABLE),
    ] {
        for verb in ["read", "ls"] {
            let server = MockServer::start().await;
            Mock::given(method("GET"))
                .respond_with(ResponseTemplate::new(status).set_body_json(
                    json!({"_tag":"Unavailable", "message":"saved disk unavailable"}),
                ))
                .expect(1)
                .mount(&server)
                .await;
            let mut out = Vec::new();
            let (code, err) = run(&server, &["file", verb, VM, "/a"], &mut out).await;
            assert_eq!(code, expected, "{err}");
            assert!(out.is_empty());
            assert_eq!(server.received_requests().await.unwrap().len(), 1);
        }
    }
}

#[derive(Default)]
struct CountingWriter {
    bytes: usize,
    largest_write: usize,
}
impl Write for CountingWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.bytes += bytes.len();
        self.largest_write = self.largest_write.max(bytes.len());
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[tokio::test]
async fn saved_file_download_streams_beyond_the_json_response_limit() {
    let server = MockServer::start().await;
    let length = 17 * 1024 * 1024;
    Mock::given(method("GET"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(vec![42; length]))
        .expect(1)
        .mount(&server)
        .await;
    let mut out = CountingWriter::default();
    let (code, err) = run(&server, &["file", "read", VM, "/artifact"], &mut out).await;
    assert_eq!(code, exit::OK, "{err}");
    assert_eq!(out.bytes, length);
    assert!(out.largest_write < length);
}
