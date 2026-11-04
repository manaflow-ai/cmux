use std::collections::HashMap;
use std::io::{BufRead as _, BufReader, Write as _};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::{BlobFetchService, answer_line, frame_command, is_sha256};
use crate::fs_ops::Roots;

const GRANT: &str = "csg_test-grant-0123456789abcdefghijklmnopqrstuvw";

struct Home {
    path: PathBuf,
}

impl Home {
    fn new(label: &str) -> Self {
        let mut random = [0u8; 6];
        getrandom::fill(&mut random).unwrap();
        let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let path = std::env::temp_dir().join(format!("cmux-blobfetch-{label}-{suffix}"));
        std::fs::create_dir_all(&path).unwrap();
        Self { path: std::fs::canonicalize(path).unwrap() }
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

fn sha(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// A loopback store: GET /v1/sync/blobs/<sha> with the grant answers the blob;
/// it counts the requests it served.
struct FakeStore {
    origin: String,
    served: Arc<Mutex<Vec<String>>>,
}

impl FakeStore {
    fn start(blobs: HashMap<String, Vec<u8>>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
        let served = Arc::new(Mutex::new(Vec::new()));
        let log = served.clone();
        let blobs = Arc::new(blobs);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let blobs = blobs.clone();
                let log = log.clone();
                std::thread::spawn(move || {
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut request = String::new();
                    reader.read_line(&mut request).unwrap();
                    let mut authorized = false;
                    loop {
                        let mut header = String::new();
                        if reader.read_line(&mut header).unwrap() == 0 || header == "\r\n" {
                            break;
                        }
                        if header.to_ascii_lowercase().starts_with("authorization:")
                            && header.contains(GRANT)
                        {
                            authorized = true;
                        }
                    }
                    let path = request.split(' ').nth(1).unwrap_or("").to_string();
                    let key = path.trim_start_matches("/v1/sync/blobs/").to_string();
                    log.lock().unwrap().push(key.clone());
                    let (status, body): (&str, &[u8]) = if !authorized {
                        ("401 Unauthorized", b"")
                    } else if let Some(blob) = blobs.get(&key) {
                        ("200 OK", blob)
                    } else {
                        ("404 Not Found", b"")
                    };
                    let head = format!(
                        "HTTP/1.1 {status}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                        body.len()
                    );
                    let _ = stream.write_all(head.as_bytes());
                    let _ = stream.write_all(body);
                });
            }
        });
        Self { origin, served }
    }
}

fn start(service: &BlobFetchService, origin: &str, plan: &[u8]) -> Value {
    let line = json!({
        "id": 1, "cmd": "blob.fetch.start",
        "store": {"origin": origin, "grant": GRANT},
        "plan": sha(plan), "plan_size": plan.len(),
    })
    .to_string();
    answer_line(Some(service), true, &line)
}

fn wait(service: &BlobFetchService, job: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let line = json!({"id": 2, "cmd": "blob.fetch.status", "job": job}).to_string();
        let answer = answer_line(Some(service), true, &line);
        let state = answer["data"]["state"].as_str().unwrap_or("").to_string();
        if state != "running" || Instant::now() > deadline {
            return answer;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_plan_writes_every_file_from_its_chunks_with_its_permissions() {
    let home = Home::new("write");
    std::fs::create_dir_all(home.path.join("proj/src")).unwrap();
    let small = b"hello\n".to_vec();
    let (part_a, part_b) = (vec![7u8; 5000], vec![9u8; 3000]);
    let big: Vec<u8> = [part_a.clone(), part_b.clone()].concat();
    let plan = json!({"version": 1, "files": [
        {"path": home.path.join("proj/a.txt").to_str().unwrap(), "permissions": 0o644,
         "size": small.len(), "sha256": sha(&small)},
        {"path": home.path.join("proj/src/run.sh").to_str().unwrap(), "permissions": 0o755,
         "size": big.len(), "sha256": sha(&big),
         "chunks": [{"sha256": sha(&part_a), "size": part_a.len()},
                    {"sha256": sha(&part_b), "size": part_b.len()}]},
        {"path": home.path.join("proj/empty").to_str().unwrap(), "permissions": 0o600,
         "size": 0, "sha256": sha(b"")},
    ]})
    .to_string()
    .into_bytes();
    let blobs = HashMap::from([
        (sha(&plan), plan.clone()),
        (sha(&small), small.clone()),
        (sha(&part_a), part_a),
        (sha(&part_b), part_b),
    ]);
    let store = FakeStore::start(blobs);
    let service = BlobFetchService::new(Roots::new([home.path.clone()]));
    let started = start(&service, &store.origin, &plan);
    assert_eq!(started["ok"], true, "{started}");
    let job = started["data"]["job"].as_str().unwrap().to_string();
    let done = wait(&service, &job);
    assert_eq!(done["data"]["state"], "done", "{done}");
    assert_eq!(done["data"]["files_done"], 3);
    assert_eq!(std::fs::read(home.path.join("proj/a.txt")).unwrap(), small);
    assert_eq!(std::fs::read(home.path.join("proj/src/run.sh")).unwrap(), big);
    use std::os::unix::fs::PermissionsExt as _;
    let mode =
        |name: &str| std::fs::metadata(home.path.join(name)).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode("proj/src/run.sh"), 0o755);
    assert_eq!(mode("proj/empty"), 0o600);
    // The same plan after its job finished runs again: a file it wrote may
    // have changed here since, and the push means the plan's bytes.
    std::fs::write(home.path.join("proj/a.txt"), b"changed on the machine").unwrap();
    let again = start(&service, &store.origin, &plan);
    let second = again["data"]["job"].as_str().unwrap().to_string();
    assert_ne!(second, job);
    assert_eq!(wait(&service, &second)["data"]["state"], "done");
    assert_eq!(std::fs::read(home.path.join("proj/a.txt")).unwrap(), small);
}

#[test]
fn a_blob_that_does_not_match_its_hash_fails_the_job_and_writes_nothing() {
    let home = Home::new("mismatch");
    let claimed = b"what the plan says".to_vec();
    let plan = json!({"version": 1, "files": [
        {"path": home.path.join("f").to_str().unwrap(), "permissions": 0o644,
         "size": 5, "sha256": sha(&claimed[..5])},
    ]})
    .to_string()
    .into_bytes();
    // The store answers other bytes under the claimed hash.
    let blobs =
        HashMap::from([(sha(&plan), plan.clone()), (sha(&claimed[..5]), b"EVIL!".to_vec())]);
    let store = FakeStore::start(blobs);
    let service = BlobFetchService::new(Roots::new([home.path.clone()]));
    let job = start(&service, &store.origin, &plan)["data"]["job"].as_str().unwrap().to_string();
    let done = wait(&service, &job);
    assert_eq!(done["data"]["state"], "failed", "{done}");
    assert_eq!(done["data"]["error_code"], "blob.digest_mismatch");
    assert!(!home.path.join("f").exists());
}

#[test]
fn a_path_outside_the_roots_is_named_and_not_written() {
    let home = Home::new("outside");
    let other = Home::new("other");
    let bytes = b"x".to_vec();
    let plan = json!({"version": 1, "files": [
        {"path": other.path.join("f").to_str().unwrap(), "permissions": 0o644,
         "size": 1, "sha256": sha(&bytes)},
    ]})
    .to_string()
    .into_bytes();
    let store = FakeStore::start(HashMap::from([(sha(&plan), plan.clone()), (sha(&bytes), bytes)]));
    let service = BlobFetchService::new(Roots::new([home.path.clone()]));
    let job = start(&service, &store.origin, &plan)["data"]["job"].as_str().unwrap().to_string();
    let done = wait(&service, &job);
    assert_eq!(done["data"]["state"], "done", "{done}");
    assert_eq!(done["data"]["failed_count"], 1);
    assert!(!other.path.join("f").exists());
}

#[test]
fn bad_requests_are_refused_before_any_fetch() {
    let home = Home::new("refuse");
    let service = BlobFetchService::new(Roots::new([home.path.clone()]));
    for (origin, grant) in [
        ("http://example.com", GRANT),
        ("https://example.com/path", GRANT),
        ("https://example.com", "not-a-grant"),
    ] {
        let line = json!({"id": 1, "cmd": "blob.fetch.start",
            "store": {"origin": origin, "grant": grant},
            "plan": sha(b"p"), "plan_size": 1})
        .to_string();
        let answer = answer_line(Some(&service), true, &line);
        assert_eq!(answer["error_code"], "blob.bad_request", "{origin} {grant}");
    }
    let line = json!({"id": 1, "cmd": "blob.fetch.status", "job": "x"}).to_string();
    assert_eq!(answer_line(Some(&service), false, &line)["error_code"], "blob.permission_denied");
    assert_eq!(answer_line(None, true, &line)["error_code"], "blob.unavailable");
}

#[test]
fn only_the_two_ops_are_blob_fetch_frames() {
    assert_eq!(frame_command(r#"{"id":1,"cmd":"blob.fetch.start"}"#), Some("blob.fetch.start"));
    assert_eq!(frame_command(r#"{"id":1,"cmd":"blob.fetch.status"}"#), Some("blob.fetch.status"));
    assert_eq!(frame_command(r#"{"id":1,"cmd":"blob.fetch.cancel"}"#), None);
    assert_eq!(frame_command(r#"{"id":1,"cmd":"blob.fetch.start","protocol":"x"}"#), None);
    assert!(is_sha256(&sha(b"")));
    assert!(!is_sha256("ABC"));
}
