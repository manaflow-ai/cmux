use std::collections::HashMap;
use std::io::{BufRead as _, BufReader, Write as _};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
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

/// A gate a [`FakeStore`] holds one blob's answer behind until it opens.
type Gate = Arc<(Mutex<bool>, Condvar)>;

impl FakeStore {
    fn start(blobs: HashMap<String, Vec<u8>>) -> Self {
        Self::holding(blobs, None)
    }

    /// Like [`FakeStore::start`], but the answer for `held.0` waits for its gate.
    fn holding(blobs: HashMap<String, Vec<u8>>, held: Option<(String, Gate)>) -> Self {
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
                let held = held.clone();
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
                    if let Some((held_key, gate)) = &held
                        && *held_key == key
                    {
                        let (open, opened) = &**gate;
                        let mut open = open.lock().unwrap();
                        while !*open {
                            open = opened.wait(open).unwrap();
                        }
                    }
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

/// The folder every test's files are under.
fn temp_root() -> String {
    std::fs::canonicalize(std::env::temp_dir()).unwrap().to_str().unwrap().to_string()
}

fn start(service: &BlobFetchService, origin: &str, plan: &[u8]) -> Value {
    start_under(service, origin, plan, &temp_root())
}

fn start_under(service: &BlobFetchService, origin: &str, plan: &[u8], target: &str) -> Value {
    let line = json!({
        "id": 1, "cmd": "blob.fetch.start",
        "store": {"origin": origin, "grant": GRANT},
        "plan": sha(plan), "plan_size": plan.len(), "target": target,
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
    // Each written file's revision, as a listing would give it right after.
    let line =
        json!({"id": 3, "cmd": "blob.fetch.status", "job": job, "written_from": 1}).to_string();
    let page = answer_line(Some(&service), true, &line);
    assert_eq!(page["data"]["written_count"], 3, "{page}");
    let entries = page["data"]["written"].as_array().unwrap();
    assert_eq!(entries.len(), 2, "{page}");
    for entry in entries {
        let path = entry["path"].as_str().unwrap();
        let meta = std::fs::metadata(path).unwrap();
        let mtime =
            meta.modified().unwrap().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
                as u64;
        assert_eq!(entry["revision"], crate::fs_ops::revision(meta.len(), Some(mtime)), "{entry}");
    }
    // The same plan after its job finished runs again: a file it wrote may
    // have changed here since, and the push means the plan's bytes.
    std::fs::write(home.path.join("proj/a.txt"), b"changed on the machine").unwrap();
    let served = store.served.lock().unwrap().len();
    let again = start(&service, &store.origin, &plan);
    let second = again["data"]["job"].as_str().unwrap().to_string();
    assert_ne!(second, job);
    assert_eq!(wait(&service, &second)["data"]["state"], "done");
    assert_eq!(std::fs::read(home.path.join("proj/a.txt")).unwrap(), small);
    assert!(store.served.lock().unwrap().len() > served, "the second job fetched nothing");
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
            "plan": sha(b"p"), "plan_size": 1, "target": temp_root()})
        .to_string();
        let answer = answer_line(Some(&service), true, &line);
        assert_eq!(answer["error_code"], "blob.bad_request", "{origin} {grant}");
    }
    for target in ["relative", "/", "/a/../b", "/a//b"] {
        let line = json!({"id": 1, "cmd": "blob.fetch.cancel", "target": target}).to_string();
        let answer = answer_line(Some(&service), true, &line);
        assert_eq!(answer["error_code"], "blob.bad_request", "{target}");
    }
    let line = json!({"id": 1, "cmd": "blob.fetch.status", "job": "x"}).to_string();
    assert_eq!(answer_line(Some(&service), false, &line)["error_code"], "blob.permission_denied");
    assert_eq!(answer_line(None, true, &line)["error_code"], "blob.unavailable");
}

#[test]
fn only_the_four_ops_are_blob_fetch_frames() {
    assert_eq!(frame_command(r#"{"id":1,"cmd":"blob.fetch.start"}"#), Some("blob.fetch.start"));
    assert_eq!(frame_command(r#"{"id":1,"cmd":"blob.fetch.status"}"#), Some("blob.fetch.status"));
    assert_eq!(frame_command(r#"{"id":1,"cmd":"blob.fetch.cancel"}"#), Some("blob.fetch.cancel"));
    assert_eq!(frame_command(r#"{"id":1,"cmd":"blob.fetch.forget"}"#), Some("blob.fetch.forget"));
    assert_eq!(frame_command(r#"{"id":1,"cmd":"blob.fetch.list"}"#), None);
    assert_eq!(frame_command(r#"{"id":1,"cmd":"blob.fetch.start","protocol":"x"}"#), None);
    assert!(is_sha256(&sha(b"")));
    assert!(!is_sha256("ABC"));
}

#[test]
fn starts_past_the_running_cap_are_refused() {
    let home = Home::new("busy");
    // A store that takes connections and never answers: every job stays running.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    std::thread::spawn(move || {
        let mut held = Vec::new();
        for stream in listener.incoming() {
            held.push(stream);
        }
    });
    let service = BlobFetchService::new(Roots::new([home.path.clone()]));
    let folder = |index: usize| format!("{}/p{index}", home.path.to_str().unwrap());
    let mut first = String::new();
    for index in 0..super::MAX_RUNNING {
        let plan = format!("plan {index}").into_bytes();
        let started = start_under(&service, &origin, &plan, &folder(index));
        assert_eq!(started["ok"], true, "{started}");
        if index == 0 {
            first = started["data"]["job"].as_str().unwrap().to_string();
        }
    }
    let refused = start_under(&service, &origin, b"one more plan", &folder(99));
    assert_eq!(refused["error_code"], "blob.busy", "{refused}");
    // A start under a running job's folder cancels it, and its worker, still
    // waiting on the store, keeps its place under the cap until it ends.
    let again = start_under(&service, &origin, b"plan 0 again", &folder(0));
    assert_eq!(again["error_code"], "blob.busy", "{again}");
    let line = json!({"id": 2, "cmd": "blob.fetch.status", "job": first}).to_string();
    let old = answer_line(Some(&service), true, &line);
    assert_eq!(old["data"]["error_code"], "blob.superseded", "{old}");
}

#[test]
fn a_blob_body_past_its_size_is_cut_off_without_a_length() {
    let home = Home::new("unbounded");
    let claimed = b"five!".to_vec();
    let plan = json!({"version": 1, "files": [
        {"path": home.path.join("f").to_str().unwrap(), "permissions": 0o644,
         "size": claimed.len(), "sha256": sha(&claimed)},
    ]})
    .to_string()
    .into_bytes();
    // A store that answers the plan, then the blob with no Content-Length
    // and far more bytes than the plan says, until it closes.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let plan_sha = sha(&plan);
    let served_plan = plan.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut request = String::new();
            reader.read_line(&mut request).unwrap();
            loop {
                let mut header = String::new();
                if reader.read_line(&mut header).unwrap_or(0) == 0 || header == "\r\n" {
                    break;
                }
            }
            if request.contains(&plan_sha) {
                let head = format!(
                    "HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                    served_plan.len()
                );
                let _ = stream.write_all(head.as_bytes());
                let _ = stream.write_all(&served_plan);
            } else {
                let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nconnection: close\r\n\r\n");
                let _ = stream.write_all(&vec![b'x'; 4 * 1024 * 1024]);
            }
        }
    });
    let service = BlobFetchService::new(Roots::new([home.path.clone()]));
    let job = start(&service, &origin, &plan)["data"]["job"].as_str().unwrap().to_string();
    let done = wait(&service, &job);
    assert_eq!(done["data"]["state"], "failed", "{done}");
    assert_eq!(done["data"]["error_code"], "blob.digest_mismatch", "{done}");
    assert!(!home.path.join("f").exists());
}

#[test]
fn a_symlink_on_the_path_is_named_and_what_it_points_at_is_untouched() {
    let home = Home::new("symlink");
    std::fs::write(home.path.join("real"), b"keep me").unwrap();
    std::os::unix::fs::symlink(home.path.join("real"), home.path.join("link")).unwrap();
    // A folder on the path that is a symlink to another folder.
    std::fs::create_dir_all(home.path.join("other")).unwrap();
    std::fs::write(home.path.join("other/f"), b"keep me too").unwrap();
    std::os::unix::fs::symlink(home.path.join("other"), home.path.join("src")).unwrap();
    let bytes = b"new bytes".to_vec();
    let plan = json!({"version": 1, "files": [
        {"path": home.path.join("link").to_str().unwrap(), "permissions": 0o644,
         "size": bytes.len(), "sha256": sha(&bytes)},
        {"path": home.path.join("src/f").to_str().unwrap(), "permissions": 0o644,
         "size": bytes.len(), "sha256": sha(&bytes)},
    ]})
    .to_string()
    .into_bytes();
    let store = FakeStore::start(HashMap::from([(sha(&plan), plan.clone()), (sha(&bytes), bytes)]));
    let service = BlobFetchService::new(Roots::new([home.path.clone()]));
    let job = start(&service, &store.origin, &plan)["data"]["job"].as_str().unwrap().to_string();
    let done = wait(&service, &job);
    assert_eq!(done["data"]["state"], "done", "{done}");
    assert_eq!(done["data"]["failed_count"], 2, "{done}");
    for failed in done["data"]["failed"].as_array().unwrap() {
        assert_eq!(failed["error_code"], "fs.symlink_in_path", "{done}");
    }
    assert_eq!(std::fs::read(home.path.join("real")).unwrap(), b"keep me");
    assert_eq!(std::fs::read(home.path.join("other/f")).unwrap(), b"keep me too");
    assert!(std::fs::symlink_metadata(home.path.join("link")).unwrap().file_type().is_symlink());
}

#[test]
fn a_newer_start_or_a_cancel_fences_off_a_running_job_that_has_not_written() {
    let home = Home::new("fence");
    let root = home.path.join("proj");
    std::fs::create_dir_all(&root).unwrap();
    let root = root.to_str().unwrap().to_string();
    let path = format!("{root}/f");
    let plan_of = |bytes: &[u8]| {
        json!({"version": 1, "files": [
            {"path": path, "permissions": 0o644, "size": bytes.len(), "sha256": sha(bytes)},
        ]})
        .to_string()
        .into_bytes()
    };
    let (old, newer) = (b"old bytes".to_vec(), b"newer bytes".to_vec());
    let (old_plan, newer_plan) = (plan_of(&old), plan_of(&newer));
    let gate: Gate = Arc::new((Mutex::new(false), Condvar::new()));
    let store = FakeStore::holding(
        HashMap::from([
            (sha(&old_plan), old_plan.clone()),
            (sha(&newer_plan), newer_plan.clone()),
            (sha(&old), old.clone()),
            (sha(&newer), newer.clone()),
        ]),
        Some((sha(&old), gate.clone())),
    );
    let service = BlobFetchService::new(Roots::new([home.path.clone()]));
    let held_job = |service: &BlobFetchService| {
        let started = start_under(service, &store.origin, &old_plan, &root);
        let job = started["data"]["job"].as_str().unwrap().to_string();
        let deadline = Instant::now() + Duration::from_secs(30);
        while !store.served.lock().unwrap().contains(&sha(&old)) {
            assert!(Instant::now() < deadline, "the old job never asked for its blob");
            std::thread::sleep(Duration::from_millis(10));
        }
        job
    };
    let release_and_settle = |job: &str| {
        let (open, opened) = &*gate;
        *open.lock().unwrap() = true;
        opened.notify_all();
        // The held job's thread sees its answer, then the cancel.
        std::thread::sleep(Duration::from_millis(300));
        let line = json!({"id": 9, "cmd": "blob.fetch.status", "job": job}).to_string();
        let answer = answer_line(Some(&service), true, &line);
        assert_eq!(answer["data"]["error_code"], "blob.superseded", "{answer}");
        *open.lock().unwrap() = false;
    };

    // A retry with a changed plan: the old job, held mid-fetch, writes nothing.
    let first = held_job(&service);
    let started = start_under(&service, &store.origin, &newer_plan, &root);
    let second = started["data"]["job"].as_str().unwrap().to_string();
    assert_eq!(wait(&service, &second)["data"]["state"], "done");
    assert_eq!(std::fs::read(&path).unwrap(), newer);
    release_and_settle(&first);
    assert_eq!(std::fs::read(&path).unwrap(), newer, "the superseded job overwrote");

    // A copy over the link after a cancel: the same.
    std::fs::remove_file(&path).unwrap();
    store.served.lock().unwrap().clear();
    let third = held_job(&service);
    let line = json!({"id": 4, "cmd": "blob.fetch.cancel", "target": root}).to_string();
    let cancelled = answer_line(Some(&service), true, &line);
    assert_eq!(cancelled["data"]["cancelled"], 1, "{cancelled}");
    std::fs::write(&path, b"written over the link").unwrap();
    release_and_settle(&third);
    assert_eq!(std::fs::read(&path).unwrap(), b"written over the link");
    // A cancel with nothing running cancels nothing.
    let again = answer_line(Some(&service), true, &line);
    assert_eq!(again["data"]["cancelled"], 0, "{again}");
    // Both answers name every job kept there, so the caller can read back
    // what each committed, until it forgets them.
    let named = |answer: &Value| -> Vec<String> {
        let mut jobs: Vec<String> = answer["data"]["jobs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|job| job.as_str().unwrap().to_string())
            .collect();
        jobs.sort();
        jobs
    };
    let mut kept = vec![first.clone(), second.clone(), third.clone()];
    kept.sort();
    assert_eq!(named(&cancelled), kept, "{cancelled}");
    assert_eq!(named(&again), kept, "{again}");
    let forget = json!({"id": 5, "cmd": "blob.fetch.forget", "jobs": [first, third]}).to_string();
    let forgot = answer_line(Some(&service), true, &forget);
    assert_eq!(forgot["data"]["forgotten"], 2, "{forgot}");
    assert_eq!(named(&answer_line(Some(&service), true, &line)), vec![second]);
}

#[test]
fn a_plan_file_outside_the_jobs_folder_fails_the_plan() {
    let home = Home::new("target");
    std::fs::create_dir_all(home.path.join("proj")).unwrap();
    let bytes = b"x".to_vec();
    let plan = json!({"version": 1, "files": [
        {"path": home.path.join("elsewhere/f").to_str().unwrap(), "permissions": 0o644,
         "size": 1, "sha256": sha(&bytes)},
    ]})
    .to_string()
    .into_bytes();
    let store = FakeStore::start(HashMap::from([(sha(&plan), plan.clone()), (sha(&bytes), bytes)]));
    let service = BlobFetchService::new(Roots::new([home.path.clone()]));
    let target = home.path.join("proj");
    let started = start_under(&service, &store.origin, &plan, target.to_str().unwrap());
    let job = started["data"]["job"].as_str().unwrap().to_string();
    let done = wait(&service, &job);
    assert_eq!(done["data"]["error_code"], "blob.bad_plan", "{done}");
    assert!(!home.path.join("elsewhere/f").exists());
}

#[test]
fn a_job_that_wrote_is_kept_until_forgotten_however_many_finish_after_it() {
    let home = Home::new("kept");
    std::fs::create_dir_all(home.path.join("proj")).unwrap();
    std::fs::create_dir_all(home.path.join("other")).unwrap();
    let bytes = b"fetched".to_vec();
    let path = home.path.join("proj/f");
    let plan = json!({"version": 1, "files": [
        {"path": path.to_str().unwrap(), "permissions": 0o644,
         "size": bytes.len(), "sha256": sha(&bytes)},
    ]})
    .to_string()
    .into_bytes();
    let store = FakeStore::start(HashMap::from([(sha(&plan), plan.clone()), (sha(&bytes), bytes)]));
    let service = BlobFetchService::new(Roots::new([home.path.clone()]));
    let proj = home.path.join("proj").to_str().unwrap().to_string();
    let other = home.path.join("other").to_str().unwrap().to_string();
    // A push whose client died after this commit, before its manifest named it.
    let wrote = start_under(&service, &store.origin, &plan, &proj)["data"]["job"]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(wait(&service, &wrote)["data"]["state"], "done");
    // More jobs than are kept finish after it, each writing nothing (the
    // store has no such plan).
    for index in 0..super::KEPT_FINISHED + 8 {
        let missing = format!("missing plan {index}").into_bytes();
        let started = start_under(&service, &store.origin, &missing, &other);
        let job = started["data"]["job"].as_str().unwrap().to_string();
        assert_eq!(wait(&service, &job)["data"]["state"], "failed");
    }
    // The next push there still reads what it wrote.
    let cancel = |target: &str| {
        let line = json!({"id": 4, "cmd": "blob.fetch.cancel", "target": target}).to_string();
        answer_line(Some(&service), true, &line)
    };
    let fenced = cancel(&proj);
    assert_eq!(fenced["data"]["jobs"], json!([wrote]), "{fenced}");
    let line =
        json!({"id": 5, "cmd": "blob.fetch.status", "job": wrote, "written_from": 0}).to_string();
    let page = answer_line(Some(&service), true, &line);
    assert_eq!(page["data"]["written"][0]["path"], path.to_str().unwrap(), "{page}");
    // Jobs that wrote nothing are still dropped past the limit.
    let elsewhere = cancel(&other);
    assert_eq!(elsewhere["data"]["jobs"].as_array().unwrap().len(), super::KEPT_FINISHED);
    // Forgotten, it goes.
    let forget = json!({"id": 6, "cmd": "blob.fetch.forget", "jobs": [wrote]}).to_string();
    assert_eq!(answer_line(Some(&service), true, &forget)["data"]["forgotten"], 1);
    assert_eq!(cancel(&proj)["data"]["jobs"], json!([]));
}
