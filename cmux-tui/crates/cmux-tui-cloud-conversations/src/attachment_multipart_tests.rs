use std::io::{Read, Write};
use std::sync::{Arc, Mutex};

use super::*;
use crate::{CloudBackend, CloudWire, ConnectError, HttpReply, ServiceOptions, TransportError};

const CONV: &str = "conv_0123456789ABCDEFGHJKMNPQRS";

#[derive(Default)]
struct Backend {
    parts: Mutex<Vec<(u64, u64, Vec<(String, String)>)>>,
    posts: Mutex<Vec<(String, String, Value)>>,
    fail_part: Option<usize>,
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
            body: json!({"ok": true, "value": {"attachment": {"hash": "stored"}}}),
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
