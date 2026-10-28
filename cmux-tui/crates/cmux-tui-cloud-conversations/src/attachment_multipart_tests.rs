use std::io::{Read, Write};
use std::sync::{Arc, Mutex};

use super::*;

type HeaderPairs = Vec<(String, String)>;
type PartReceipt = (u64, u64, HeaderPairs);
use crate::{CloudBackend, CloudWire, ConnectError, HttpReply, ServiceOptions, TransportError};

const CONV: &str = "conv_0123456789ABCDEFGHJKMNPQRS";

#[derive(Default)]
struct Backend {
    parts: Mutex<Vec<PartReceipt>>,
    posts: Mutex<Vec<(String, String, Value)>>,
    fail_part: Option<usize>,
    progress: Mutex<std::collections::VecDeque<Value>>,
    signed_lengths: Vec<u64>,
    missing_etag: bool,
    destination: Option<String>,
}
impl CloudBackend for Backend {
    fn post(
        &self,
        url: &str,
        bearer: Option<&str>,
        _: Option<&str>,
        body: &Value,
    ) -> Result<HttpReply, TransportError> {
        self.posts.lock().unwrap().push((
            url.into(),
            bearer.unwrap_or_default().into(),
            body.clone(),
        ));
        Ok(HttpReply {
            status: 200,
            body: json!({"ok": true, "value": self.progress.lock().unwrap().pop_front().unwrap_or_else(|| json!({"attachment": {"hash": "stored"}}))}),
        })
    }
    fn put(
        &self,
        _: &str,
        headers: &[(String, String)],
        body: PutBody,
    ) -> Result<HttpReply, TransportError> {
        let PutBody::File { mut file, len } = body else { panic!("original must remain a file") };
        let offset = file.stream_position().unwrap();
        let mut parts = self.parts.lock().unwrap();
        parts.push((offset, len, headers.to_vec()));
        if self.fail_part == Some(parts.len()) {
            return Err(TransportError("part failed".into()));
        }
        // Check range boundaries without reading a multi-GB sparse fixture.
        let mut marker = [0];
        file.read_exact(&mut marker).unwrap();
        file.seek(SeekFrom::Start(offset + len - 1)).unwrap();
        file.read_exact(&mut marker).unwrap();
        Ok(HttpReply {
            status: 200,
            body: json!({"ok": true, "value": {"part_number": parts.len()}}),
        })
    }
    fn attachment_part_url(&self, url: &str, number: u64) -> Result<HttpReply, TransportError> {
        assert!(url.starts_with("https://api.cmux.test/"));
        Ok(HttpReply {
            status: 200,
            body: json!({"ok": true, "value": {
                "url": self.destination.as_deref().unwrap_or("https://storage.example/part?signature=opaque"),
                "part_number": number, "method": "PUT", "headers": {"content-length": self.signed_lengths[number as usize - 1].to_string(), "authorization": "never-forward"}
            }}),
        })
    }
    fn put_with_etag(
        &self,
        url: &str,
        headers: &[(String, String)],
        body: PutBody,
    ) -> Result<(HttpReply, Option<String>), TransportError> {
        assert!(url.starts_with("https://storage.example/"));
        assert_eq!(headers, &[("content-length".into(), body.len().to_string())]);
        let reply = self.put(url, headers, body)?;
        Ok((reply, (!self.missing_etag).then(|| "\"part-tag\"".into())))
    }
    fn connect(
        &self,
        _: &str,
        _: Option<&str>,
        _: Option<&str>,
    ) -> Result<Box<dyn CloudWire>, ConnectError> {
        Err(ConnectError::Unavailable("no socket".into()))
    }
}

fn service(backend: Arc<Backend>) -> CloudConversations {
    let service = CloudConversations::with_options(
        backend,
        ServiceOptions {
            api_origins: vec!["https://api.cmux.test".into()],
            ..ServiceOptions::default()
        },
    );
    service
        .set_session(
            serde_json::from_value(json!({
                "api_base_url": "https://api.cmux.test", "access_token": "stack.jwt.token",
                "expires_at": 4_102_444_800_000_u64
            }))
            .unwrap(),
        )
        .unwrap();
    service
}

fn file_body(len: u64) -> PutBody {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let path = std::env::temp_dir().join(format!(
        "cmux-multipart-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let mut file =
        std::fs::OpenOptions::new().create_new(true).read(true).write(true).open(&path).unwrap();
    // Unlink immediately; the handle keeps the sparse test file alive until the upload drops.
    std::fs::remove_file(path).unwrap();
    file.set_len(len).unwrap();
    file.write_all(b"x").unwrap();
    PutBody::File { file, len }
}

fn plan(len: u64, size: u64) -> Value {
    json!({"upload_url": "https://api.cmux.test/v1/home/attachments/multipart/slot-token",
        "mode": "multipart", "slot": "slot", "part_size": size,
        "part_count": len.div_ceil(size), "headers": {"Authorization": "must-not-send", "content-length": len}})
}

#[test]
fn multipart_streams_over_five_gib_and_authenticates_only_completion() {
    let len = 5 * 1024 * 1024 * 1024 + 7;
    let size = 32 * 1024 * 1024;
    let backend = Arc::new(Backend::default());
    let service = service(backend.clone());
    let result = service.attachment_multipart(CONV, &plan(len, size), file_body(len)).unwrap();
    assert_eq!(result["attachment"]["hash"], "stored");
    let parts = backend.parts.lock().unwrap();
    assert_eq!(parts.len(), 161);
    for (index, (offset, bytes, headers)) in parts.iter().enumerate() {
        assert_eq!(*offset, index as u64 * size);
        assert_eq!(*bytes, size.min(len - offset));
        assert_eq!(
            headers,
            &vec![
                ("x-cmux-part-number".into(), (index + 1).to_string()),
                ("content-length".into(), bytes.to_string())
            ]
        );
    }
    let posts = backend.posts.lock().unwrap();
    assert_eq!(posts.len(), 1);
    assert!(posts[0].0.ends_with("/multipart/complete"));
    assert_eq!(posts[0].1, "stack.jwt.token");
    assert_eq!(posts[0].2, json!({"conversation": CONV, "slot": "slot"}));
}

#[test]
fn multipart_stops_on_error_and_rejects_foreign_origin_and_bad_plan() {
    let backend = Arc::new(Backend { fail_part: Some(2), ..Backend::default() });
    let service = service(backend.clone());
    assert!(service.attachment_multipart(CONV, &plan(25, 10), file_body(25)).is_err());
    assert_eq!(backend.parts.lock().unwrap().len(), 2);
    assert!(backend.posts.lock().unwrap().is_empty());
    let mut foreign = plan(25, 10);
    foreign["upload_url"] = json!("https://other.test/slot");
    assert!(service.attachment_multipart(CONV, &foreign, file_body(25)).is_err());
    let mut invalid = plan(25, 10);
    invalid["part_count"] = json!(2);
    assert!(service.attachment_multipart(CONV, &invalid, file_body(25)).is_err());
    assert_eq!(backend.parts.lock().unwrap().len(), 2);
}

#[test]
fn intent_opts_into_multipart_even_if_declaration_disables_it() {
    let backend = Arc::new(Backend::default());
    let service = service(backend.clone());
    service.attachment_intent(CONV, &json!({"multipart": false})).unwrap();
    assert_eq!(backend.posts.lock().unwrap()[0].2["multipart"], true);
}

#[test]
fn direct_multipart_streams_terabyte_ranges_and_verifies_before_returning() {
    let size = 1024 * 1024 * 1024;
    let len = 1024 * size + 7;
    let mut lengths = vec![size; 1024];
    lengths.push(7);
    let backend = Arc::new(Backend {
        signed_lengths: lengths,
        progress: Mutex::new(
            [json!({"state":"verifying", "verified_bytes":256*1024*1024, "byte_count":len})].into(),
        ),
        ..Backend::default()
    });
    let mut declaration = plan(len, size);
    declaration["transport"] = json!("direct");
    service(backend.clone()).attachment_multipart(CONV, &declaration, file_body(len)).unwrap();
    assert_eq!(backend.parts.lock().unwrap().len(), 1025);
    let posts = backend.posts.lock().unwrap();
    assert_eq!(posts.len(), 2);
    assert_eq!(posts[0].2, posts[1].2);
    assert_eq!(posts[0].1, "stack.jwt.token");
    let receipts = posts[0].2["parts"].as_array().unwrap();
    assert_eq!(receipts.len(), 1025);
    assert_eq!(receipts[1024], json!({"part_number":1025, "etag":"\"part-tag\""}));
}

#[test]
fn direct_multipart_bounds_increasing_verification_polls() {
    let mut declaration = plan(25, 10);
    declaration["transport"] = json!("direct");
    let progress = (1..=8)
        .map(|verified_bytes| json!({"state":"verifying", "verified_bytes":verified_bytes, "byte_count":25}))
        .collect();
    let backend = Arc::new(Backend {
        signed_lengths: vec![10, 10, 5],
        progress: Mutex::new(progress),
        ..Backend::default()
    });
    let result = service(backend.clone()).attachment_multipart(CONV, &declaration, file_body(25));
    assert!(result.is_err(), "increasing progress must still hit the poll bound");
    assert_eq!(backend.posts.lock().unwrap().len(), 8);
}

#[test]
fn direct_multipart_rejects_missing_etag_bad_destination_and_stalled_verification() {
    let mut declaration = plan(25, 10);
    declaration["transport"] = json!("direct");
    for backend in [
        Backend { signed_lengths: vec![10, 10, 5], missing_etag: true, ..Backend::default() },
        Backend {
            signed_lengths: vec![10, 10, 5],
            destination: Some("http://localhost/steal".into()),
            ..Backend::default()
        },
        Backend {
            signed_lengths: vec![10, 10, 5],
            progress: Mutex::new(
                [
                    json!({"state":"verifying", "verified_bytes":10, "byte_count":25}),
                    json!({"state":"verifying", "verified_bytes":10, "byte_count":25}),
                ]
                .into(),
            ),
            ..Backend::default()
        },
    ] {
        assert!(
            service(Arc::new(backend))
                .attachment_multipart(CONV, &declaration, file_body(25))
                .is_err()
        );
    }
    declaration["transport"] = json!(true);
    assert!(
        service(Arc::new(Backend::default()))
            .attachment_multipart(CONV, &declaration, file_body(25))
            .is_err()
    );
}
