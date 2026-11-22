//! A cloud conversation's attachments from the person's page, through the
//! daemon (`cloud-attachments-v1`): the page uploads a video with its poster
//! in the same steps as a local upload; the daemon asks the cloud owner for a
//! slot with the lease, sends the poster first and then the video to the
//! slot (no bearer: the slot is the credential), reads bytes back through a
//! signed URL and serves a local download link with byte ranges. The cloud
//! is a loopback HTTP server that keeps what it was sent.

use std::collections::HashMap;

use base64::Engine;
use sha2::{Digest, Sha256};

use super::*;

fn hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Larger than one streamed read of the staged file (1 MiB), so the
/// upload to the slot spans several body chunks with one Content-Length.
fn video() -> Vec<u8> {
    (0..2_500_000_u32).map(|i| (i.wrapping_mul(2_246_822_519) >> 11) as u8).collect()
}

const POSTER: &[u8] = b"\xff\xd8\xff\xe0 the cloud clip's first frame";
const OBJECT: &str = "0123456789abcdef0123456789abcdef";

/// One request the fake cloud saw: method, path, bearer, body length.
type Seen = (String, String, String, usize);

/// A loopback stand-in for the Worker's attachment routes.
struct FakeFiles {
    base: String,
    seen: Arc<Mutex<Vec<Seen>>>,
}

impl FakeFiles {
    fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let (log, origin) = (seen.clone(), base.clone());
        std::thread::spawn(move || {
            let stored: Arc<Mutex<HashMap<String, Vec<u8>>>> = Arc::default();
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let mut reader = BufReader::new(stream);
                let (mut length, mut method, mut path, mut bearer, mut range) =
                    (0usize, String::new(), String::new(), String::new(), None::<String>);
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 {
                        break;
                    }
                    if method.is_empty() {
                        let mut parts = line.split(' ');
                        method = parts.next().unwrap_or("").to_string();
                        path = parts.next().unwrap_or("").to_string();
                    }
                    let lower = line.to_ascii_lowercase();
                    if let Some(value) = lower.strip_prefix("content-length:") {
                        length = value.trim().parse().unwrap_or(0);
                    }
                    if lower.starts_with("authorization:") {
                        bearer = line["authorization:".len()..].trim().to_string();
                    }
                    if let Some(value) = lower.strip_prefix("range:") {
                        range = Some(value.trim().to_string());
                    }
                    if line == "\r\n" {
                        break;
                    }
                }
                let mut body = vec![0; length];
                let _ = reader.read_exact(&mut body);
                log.lock().unwrap().push((method.clone(), path.clone(), bearer, body.len()));
                let json_body = serde_json::from_slice::<Value>(&body).unwrap_or(Value::Null);
                let ok =
                    |value: Value| json!({"ok": true, "value": value}).to_string().into_bytes();
                let (status, content_type, extra, reply): (u16, &str, String, Vec<u8>) = if path
                    == "/v1/home/attachments/intent"
                {
                    let hash = json_body["sha256"].as_str().unwrap_or("").to_string();
                    if stored.lock().unwrap().contains_key(&hash) {
                        let attachment = json!({"hash": hash, "mime_type": json_body["mime_type"],
                                "byte_count": json_body["byte_count"], "poster": {"hash": hex(POSTER),
                                "mime_type": "image/jpeg", "byte_count": POSTER.len()}});
                        (
                            200,
                            "application/json",
                            String::new(),
                            ok(json!({"state": "exists", "attachment": attachment})),
                        )
                    } else {
                        (
                            200,
                            "application/json",
                            String::new(),
                            ok(json!({"state": "upload", "mode": "stream",
                                "method": "PUT", "slot": "slot1",
                                "upload_url": format!("{origin}/v1/home/attachments/upload/{CONV}/slot1.1.sig"),
                                "headers": {"content-type": json_body["mime_type"]},
                                "poster_upload": {"upload_url": format!("{origin}/v1/home/attachments/poster/{CONV}/slot1.1.sig")}})),
                        )
                    }
                } else if path.starts_with("/v1/home/attachments/poster/") {
                    stored.lock().unwrap().insert("poster".into(), body.clone());
                    (200, "application/json", String::new(), ok(json!({"state": "poster_stored"})))
                } else if path.starts_with("/v1/home/attachments/upload/") {
                    let poster_first = stored.lock().unwrap().contains_key("poster");
                    if !poster_first {
                        (409, "application/json", String::new(), json!({"ok": false, "error": {"code": "attachment.poster_missing", "message": "poster first"}}).to_string().into_bytes())
                    } else {
                        let hash = hex(&body);
                        stored.lock().unwrap().insert(hash.clone(), body.clone());
                        stored.lock().unwrap().insert("object".into(), body.clone());
                        (
                            200,
                            "application/json",
                            String::new(),
                            ok(json!({"state": "stored", "attachment": {"hash": hash,
                                "mime_type": "video/mp4", "byte_count": body.len(), "poster": {"hash": hex(POSTER),
                                "mime_type": "image/jpeg", "byte_count": POSTER.len()}}})),
                        )
                    }
                } else if path == "/v1/home/attachments/url" {
                    let variant = json_body["variant"].as_str().unwrap_or("original").to_string();
                    (
                        200,
                        "application/json",
                        String::new(),
                        ok(
                            json!({"url": format!("{origin}/v1/home/attachments/{CONV}/{OBJECT}?variant={variant}&s=sig"),
                            "expires_at": 4_102_444_800_000_u64}),
                        ),
                    )
                } else if path.starts_with(&format!("/v1/home/attachments/{CONV}/{OBJECT}")) {
                    let key = if path.contains("variant=poster") { "poster" } else { "object" };
                    let object = stored.lock().unwrap().get(key).cloned().unwrap_or_default();
                    let total = object.len();
                    let (start, end) = range
                        .as_deref()
                        .and_then(|r| r.strip_prefix("bytes="))
                        .and_then(|r| r.split_once('-'))
                        .map(|(a, b)| {
                            (
                                a.parse::<usize>().unwrap_or(0),
                                b.parse::<usize>().unwrap_or(total - 1).min(total - 1),
                            )
                        })
                        .unwrap_or((0, total - 1));
                    let mime = if key == "poster" { "image/jpeg" } else { "video/mp4" };
                    (
                        206,
                        mime,
                        format!("Content-Range: bytes {start}-{end}/{total}\r\n"),
                        object[start..=end].to_vec(),
                    )
                } else {
                    (404, "text/plain", String::new(), b"no route".to_vec())
                };
                let head = format!(
                    "HTTP/1.1 {status} X\r\nContent-Type: {content_type}\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n",
                    reply.len()
                );
                let stream = reader.get_mut();
                let _ = stream.write_all(head.as_bytes());
                let _ = stream.write_all(&reply);
            }
        });
        Self { base, seen }
    }

    fn seen(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }
}

/// One HTTP GET on the daemon's listener: (status, Content-Range, body).
fn get(addr: &str, path: &str, range: &str) -> (u16, String, Vec<u8>) {
    let mut stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    write!(
        stream,
        "GET {path} HTTP/1.1\r\nHost: {addr}\r\nRange: {range}\r\nConnection: close\r\n\r\n"
    )
    .unwrap();
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).unwrap();
    let end = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
    let head = String::from_utf8_lossy(&raw[..end]).to_string();
    let status = head.split(' ').nth(1).unwrap().parse().unwrap();
    let content_range = head
        .lines()
        .find_map(|line| {
            line.to_ascii_lowercase().strip_prefix("content-range:").map(|v| v.trim().to_string())
        })
        .unwrap_or_default();
    (status, content_range, raw[end + 4..].to_vec())
}

#[test]
fn the_persons_page_sends_and_plays_a_cloud_video_through_the_daemon() {
    let fixture = Fixture::start("files");
    let cloud = FakeFiles::start();
    let token = person_token();
    let mut app = fixture.app();
    assert_eq!(app.rpc(lease(&cloud.base, &token))["ok"], true);
    let (addr, file_token) = fixture.credential();
    let credential = page_credential(&mut app);
    let mut page = Page::open(&addr, &credential);
    let identity = page.rpc(json!({"cmd":"identify"}));
    assert!(
        identity["data"]["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v == "cloud-attachments-v1"),
        "{identity}"
    );

    // The same steps as a local upload: begin, chunks, commit.
    let bytes = video();
    let poster =
        json!({"sha256": hex(POSTER), "byte_count": POSTER.len(), "mime_type": "image/jpeg"});
    let begin = json!({"cmd":"cloud-attachment-upload","op":"begin","conversation":CONV,
        "sha256":hex(&bytes),"byte_count":bytes.len(),"mime_type":"video/mp4","name":"clip.mp4",
        "duration_ms":3000,"poster":poster});
    let begun = page.rpc(begin.clone());
    assert_eq!(begun["ok"], true, "{begun}");
    assert_eq!(begun["data"]["needs"], json!(["original", "poster"]), "{begun}");
    let upload = begun["data"]["upload"].as_str().unwrap().to_owned();
    let b64 = |data: &[u8]| base64::engine::general_purpose::STANDARD.encode(data);
    for (piece, offset, data) in [
        ("original", 0, &bytes[..100_000]),
        ("original", 100_000, &bytes[100_000..]),
        ("poster", 0, POSTER),
    ] {
        let chunk = page.rpc(json!({"cmd":"cloud-attachment-upload","op":"chunk","upload":upload,
            "piece":piece,"offset":offset,"data":b64(data)}));
        assert_eq!(chunk["ok"], true, "{chunk}");
    }
    let committed =
        page.rpc(json!({"cmd":"cloud-attachment-upload","op":"commit","upload":upload}));
    assert_eq!(committed["ok"], true, "{committed}");
    assert_eq!(committed["data"]["stored"]["hash"], hex(&bytes), "{committed}");
    assert_eq!(committed["data"]["stored"]["poster"]["hash"], hex(POSTER), "{committed}");
    let seen = cloud.seen();
    let order: Vec<&str> = seen.iter().map(|(_, path, _, _)| path.as_str()).collect();
    assert!(order[0] == "/v1/home/attachments/intent", "{order:?}");
    assert!(
        order[1].starts_with("/v1/home/attachments/poster/"),
        "the poster goes first: {order:?}"
    );
    assert!(order[2].starts_with("/v1/home/attachments/upload/"), "{order:?}");
    assert_eq!(seen[2].3, bytes.len(), "the whole video went to the slot");
    assert_eq!(seen[0].2, format!("Bearer {token}"), "the intent carries the lease");
    assert!(seen[1].2.is_empty() && seen[2].2.is_empty(), "a slot URL gets no bearer: {seen:?}");

    // A hash the conversation already holds: no upload, the owner's record.
    let again = page.rpc(begin);
    assert_eq!(again["data"]["upload"], Value::Null, "{again}");
    assert_eq!(again["data"]["stored"]["hash"], hex(&bytes), "{again}");

    // Bytes back through a signed URL, at an offset.
    let read = page
        .rpc(json!({"cmd":"cloud-attachment-read","conversation":CONV,"hash":hex(&bytes),
        "offset":1000,"length":16}));
    assert_eq!(read["ok"], true, "{read}");
    let data = base64::engine::general_purpose::STANDARD
        .decode(read["data"]["data"].as_str().unwrap())
        .unwrap();
    assert_eq!(data, bytes[1000..1016], "{read}");
    assert_eq!(read["data"]["byte_count"], bytes.len(), "{read}");
    assert_eq!(read["data"]["mime_type"], "video/mp4", "{read}");
    let poster_read = page.rpc(json!({"cmd":"cloud-attachment-read","conversation":CONV,
        "hash":hex(&bytes),"variant":"poster"}));
    let poster_bytes = base64::engine::general_purpose::STANDARD
        .decode(poster_read["data"]["data"].as_str().unwrap())
        .unwrap();
    assert_eq!(poster_bytes, POSTER, "{poster_read}");

    // A local download link that a video element seeks in.
    let link = page
        .rpc(json!({"cmd":"cloud-attachment-link","conversation":CONV,"hash":hex(&bytes),
        "name":"clip.mp4"}));
    assert_eq!(link["ok"], true, "{link}");
    let path = link["data"]["path"].as_str().unwrap().to_owned();
    let (status, content_range, body) = get(&addr, &path, "bytes=150000-150099");
    assert_eq!(status, 206);
    assert_eq!(content_range, format!("bytes 150000-150099/{}", bytes.len()));
    assert_eq!(body, bytes[150_000..150_100]);
    // The signed URL was minted once and reused.
    let mints =
        cloud.seen().iter().filter(|(_, path, _, _)| path == "/v1/home/attachments/url").count();
    assert_eq!(mints, 2, "one URL per variant: {:?}", cloud.seen());

    // The file token never uses the person's lease.
    let mut other = Page::open(&addr, &file_token);
    let refused =
        other.rpc(json!({"cmd":"cloud-attachment-read","conversation":CONV,"hash":hex(&bytes)}));
    assert_eq!(refused["ok"], false, "{refused}");
}
