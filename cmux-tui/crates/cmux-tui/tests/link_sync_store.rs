//! `cmux link sync push --store`: the Mac uploads only the blobs the store
//! lacks, and the machine pulls them from the store itself. A fake platform
//! (`/v1/sync/*`) and a fake daemon (the real `FsService` and
//! `BlobFetchService`) count what crosses each wire, so the same harness
//! measures the direct link copy and the store path:
//! `cargo test -p cmux-tui --test link_sync_store -- --nocapture`.
#![cfg(unix)]

use std::collections::HashMap;
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::net::TcpListener;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_tui_core::blob_fetch::{self, BlobFetchService};
use cmux_tui_core::fs_ops::{FsService, Roots, stream};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

const CREDENTIAL: &str = "person-token-for-tests";
const GRANT: &str = "csg_read-grant-for-tests-0123456789";

fn sha(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// The platform's sync store, one user: what it holds and what crossed to it.
#[derive(Default)]
struct Store {
    blobs: Mutex<HashMap<String, Vec<u8>>>,
    uploaded: AtomicU64,
    served: AtomicU64,
}

fn serve_store() -> (String, Arc<Store>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let store = Arc::new(Store::default());
    let shared = store.clone();
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            let store = shared.clone();
            std::thread::spawn(move || answer_http(connection, &store));
        }
    });
    (origin, store)
}

fn answer_http(mut connection: std::net::TcpStream, store: &Store) {
    let mut reader = BufReader::new(connection.try_clone().unwrap());
    let mut first = String::new();
    if reader.read_line(&mut first).unwrap_or(0) == 0 {
        return;
    }
    let mut length = 0usize;
    let mut bearer = String::new();
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header).unwrap_or(0) == 0 || header == "\r\n" {
            break;
        }
        let lower = header.to_ascii_lowercase();
        if let Some(value) = lower.strip_prefix("content-length:") {
            length = value.trim().parse().unwrap_or(0);
        }
        if lower.starts_with("authorization:") {
            bearer = header.trim().rsplit(' ').next().unwrap_or("").to_string();
        }
    }
    let mut body = vec![0u8; length];
    reader.read_exact(&mut body).unwrap();
    let mut parts = first.split(' ');
    let (method, path) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
    let person = bearer == CREDENTIAL;
    let (status, reply): (&str, Vec<u8>) = match (method, path) {
        _ if !(person || (method == "GET" && bearer == GRANT)) => ("401 Unauthorized", vec![]),
        ("POST", "/v1/sync/blobs/missing") => {
            let asked: Value = serde_json::from_slice(&body).unwrap();
            let blobs = store.blobs.lock().unwrap();
            let missing: Vec<&str> = asked["sha256"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(Value::as_str)
                .filter(|hash| !blobs.contains_key(*hash))
                .collect();
            ("200 OK", json!({ "missing": missing }).to_string().into_bytes())
        }
        ("POST", "/v1/sync/grants") => (
            "200 OK",
            json!({"grant": GRANT, "expiresAt": "2099-01-01T00:00:00Z"}).to_string().into_bytes(),
        ),
        ("PUT", path) => {
            let hash = path.trim_start_matches("/v1/sync/blobs/");
            if sha(&body) != hash {
                ("400 Bad Request", vec![])
            } else {
                store.uploaded.fetch_add(body.len() as u64, Ordering::SeqCst);
                store.blobs.lock().unwrap().insert(hash.to_string(), body);
                ("200 OK", b"{}".to_vec())
            }
        }
        ("GET", path) => {
            let hash = path.trim_start_matches("/v1/sync/blobs/");
            match store.blobs.lock().unwrap().get(hash) {
                Some(blob) => {
                    store.served.fetch_add(blob.len() as u64, Ordering::SeqCst);
                    ("200 OK", blob.clone())
                }
                None => ("404 Not Found", vec![]),
            }
        }
        _ => ("404 Not Found", vec![]),
    };
    let head = format!(
        "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
        reply.len()
    );
    let _ = connection.write_all(head.as_bytes());
    let _ = connection.write_all(&reply);
}

/// A machine: the real fs and blob-fetch owners over `home` behind
/// `socket`. Returns the bytes the Mac sent it over the link, and a count of
/// `blob.fetch.start` answers still to lose: such a start runs its job, then
/// the connection closes with no answer.
fn serve_machine(
    socket: &Path,
    home: &Path,
    capability: &'static str,
) -> (&'static AtomicU64, &'static AtomicU64, &'static AtomicU64) {
    let listener = UnixListener::bind(socket).unwrap();
    let roots = Roots::new([home.to_path_buf()]);
    let fs: &'static FsService = Box::leak(Box::new(FsService::new(roots.clone())));
    let fetch: &'static BlobFetchService = Box::leak(Box::new(BlobFetchService::new(roots)));
    let sent: &'static AtomicU64 = Box::leak(Box::default());
    let lose_starts: &'static AtomicU64 = Box::leak(Box::default());
    let supersede: &'static AtomicU64 = Box::leak(Box::default());
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            std::thread::spawn(move || {
                let mut writer = connection.try_clone().unwrap();
                for line in BufReader::new(connection).lines() {
                    let Ok(line) = line else { return };
                    sent.fetch_add(line.len() as u64 + 1, Ordering::SeqCst);
                    let request: Value = serde_json::from_str(&line).unwrap();
                    let id = request["id"].clone();
                    let cmd = request["cmd"].as_str().unwrap_or_default().to_string();
                    let reply = if cmd == "identify" {
                        json!({"id": id, "ok": true, "data": {
                            "capabilities": ["fs-v1", capability],
                            "build_id": "machine-build", "session_id": "machine"}})
                    } else if capability != blob_fetch::BLOB_FETCH_CAPABILITY
                        && cmd.starts_with("blob.fetch.")
                    {
                        // A pre-release `blob-fetch-v1` daemon: no cancel.
                        json!({"id": id, "ok": false, "error": "unknown blob.fetch op",
                               "error_code": "blob.bad_request"})
                    } else if cmd == "blob.fetch.status"
                        && request.get("written_from").is_none()
                        && supersede.load(Ordering::SeqCst) > 0
                    {
                        // As a newer push's start would have it: cancelled.
                        json!({"id": id, "ok": true, "data": {
                            "job": request["job"], "state": "failed",
                            "error_code": "blob.superseded",
                            "error": "a newer push to this folder took over"}})
                    } else if blob_fetch::frame_command(&line).is_some() {
                        let answer = blob_fetch::answer_line(Some(fetch), true, &line);
                        if cmd == "blob.fetch.start"
                            && lose_starts
                                .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |left| {
                                    left.checked_sub(1)
                                })
                                .is_ok()
                        {
                            return;
                        }
                        answer
                    } else {
                        stream::answer(&id, fs.call("local", &cmd, request))
                    };
                    let mut text = reply.to_string();
                    text.push('\n');
                    if writer.write_all(text.as_bytes()).is_err() {
                        return;
                    }
                }
            });
        }
    });
    (sent, lose_starts, supersede)
}

fn git(dir: &Path, args: &[&str]) {
    let output = Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"])
        // No background gc or maintenance: it would change .git while a push reads it.
        .args(["-c", "gc.auto=0", "-c", "maintenance.auto=false"])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
}

/// Bytes that do not compress: a source tree's worth of distinct content.
fn noise(seed: u64, len: usize) -> Vec<u8> {
    let mut state = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
    (0..len)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            (state >> 24) as u8
        })
        .collect()
}

/// A mid-sized repo: 600 files of 2-24 KiB in 30 folders, two copies of a
/// vendored file, and a 24 MiB asset, all committed.
fn mid_repo(root: &Path) -> PathBuf {
    let repo = root.join("app");
    for index in 0..600u64 {
        let folder = repo.join(format!("src/m{}", index % 30));
        std::fs::create_dir_all(&folder).unwrap();
        let size = 2048 + (index as usize * 7919) % (22 * 1024);
        std::fs::write(folder.join(format!("f{index}.rs")), noise(index, size)).unwrap();
    }
    let vendored = noise(9_001, 200 * 1024);
    std::fs::create_dir_all(repo.join("vendor/a")).unwrap();
    std::fs::create_dir_all(repo.join("vendor/b")).unwrap();
    std::fs::write(repo.join("vendor/a/lib.js"), &vendored).unwrap();
    std::fs::write(repo.join("vendor/b/lib.js"), &vendored).unwrap();
    std::fs::create_dir_all(repo.join("assets")).unwrap();
    std::fs::write(repo.join("assets/model.bin"), noise(77, 24 * 1024 * 1024)).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    repo
}

struct Machine {
    home: PathBuf,
    socket: PathBuf,
    sent: &'static AtomicU64,
    lose_starts: &'static AtomicU64,
    supersede: &'static AtomicU64,
    _sockets: tempfile::TempDir,
}

fn machine(root: &Path, name: &str) -> Machine {
    machine_serving(root, name, blob_fetch::BLOB_FETCH_CAPABILITY)
}

fn machine_serving(root: &Path, name: &str, capability: &'static str) -> Machine {
    let home = root.join(name);
    std::fs::create_dir_all(home.join("work")).unwrap();
    let sockets = tempfile::Builder::new().prefix("cs").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("fs.sock");
    let (sent, lose_starts, supersede) = serve_machine(&socket, &home, capability);
    Machine { home, socket, sent, lose_starts, supersede, _sockets: sockets }
}

/// One push, with the store when `origin` is given. Returns its summary,
/// the bytes over the link, the bytes uploaded to the store and the wall
/// time.
fn push(machine: &Machine, repo: &Path, origin: Option<&str>, store: &Store) -> Measured {
    let (link_before, up_before) =
        (machine.sent.load(Ordering::SeqCst), store.uploaded.load(Ordering::SeqCst));
    let started = Instant::now();
    let output = run_push(machine, repo, origin);
    assert!(
        output.status.success(),
        "sync push failed: {}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    Measured {
        summary: serde_json::from_slice(&output.stdout).expect("one JSON summary"),
        link: machine.sent.load(Ordering::SeqCst) - link_before,
        uploaded: store.uploaded.load(Ordering::SeqCst) - up_before,
        millis: started.elapsed().as_millis(),
    }
}

/// One push's process output, success or not.
fn run_push(machine: &Machine, repo: &Path, origin: Option<&str>) -> std::process::Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .env("CMUX_TUI_STATE_DIR", machine.socket.parent().unwrap().join("state"))
        .args(["link", "sync", "push", "--socket"])
        .arg(&machine.socket)
        .arg(repo)
        .arg(machine.home.join("work/app"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(origin) = origin {
        command.args(["--store", origin]);
    }
    let mut child = command.spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    if origin.is_some() {
        writeln!(stdin, "{CREDENTIAL}").unwrap();
    }
    drop(stdin);
    child.wait_with_output().unwrap()
}

struct Measured {
    summary: Value,
    link: u64,
    uploaded: u64,
    millis: u128,
}

impl Measured {
    /// Bytes that left the Mac: over the link plus up to the store.
    fn sent_from_mac(&self) -> u64 {
        self.link + self.uploaded
    }
}

fn same_tree(a: &Path, b: &Path) {
    let mut stack = vec![PathBuf::new()];
    while let Some(relative) = stack.pop() {
        for entry in std::fs::read_dir(a.join(&relative)).unwrap() {
            let entry = entry.unwrap();
            let name = relative.join(entry.file_name());
            if name.starts_with(".git") {
                continue;
            }
            if entry.file_type().unwrap().is_dir() {
                stack.push(name);
            } else {
                assert_eq!(
                    std::fs::read(a.join(&name)).unwrap(),
                    std::fs::read(b.join(&name)).unwrap_or_default(),
                    "{} differs",
                    name.display()
                );
            }
        }
    }
}

#[test]
fn the_store_moves_each_blob_from_the_mac_once_and_the_link_copy_stays_the_fallback() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let repo = mid_repo(&root);
    let (origin, store) = serve_store();
    let unused = Store::default();

    // Before: the direct link copy, same repo, same machines.
    let direct_a = machine(&root, "direct-a");
    let direct_b = machine(&root, "direct-b");
    let first_direct = push(&direct_a, &repo, None, &unused);
    let second_direct = push(&direct_b, &repo, None, &unused);
    assert!(first_direct.summary.get("store").is_none_or(Value::is_null));

    // After: through the store.
    let a = machine(&root, "a");
    let b = machine(&root, "b");
    let first = push(&a, &repo, Some(&origin), &store);
    assert_eq!(first.summary["store"]["used"], true, "{}", first.summary);
    same_tree(&repo, &a.home.join("work/app"));
    // The vendored copy is stored once.
    assert!(first.uploaded < first_direct.link, "{} vs {}", first.uploaded, first_direct.link);

    let second = push(&b, &repo, Some(&origin), &store);
    assert_eq!(second.summary["store"]["used"], true, "{}", second.summary);
    same_tree(&repo, &b.home.join("work/app"));
    // A second machine costs the Mac only the plan and the control lines.
    assert!(
        second.sent_from_mac() < 1024 * 1024,
        "second machine moved {}",
        second.sent_from_mac()
    );

    // A one-file edit: only that file's blob goes up.
    let edited = repo.join("src/m3/f3.rs");
    let mut bytes = std::fs::read(&edited).unwrap();
    bytes.extend_from_slice(b"\n// edited\n");
    std::fs::write(&edited, &bytes).unwrap();
    let edit_direct = push(&direct_a, &repo, None, &unused);
    let edit = push(&a, &repo, Some(&origin), &store);
    assert_eq!(std::fs::read(a.home.join("work/app/src/m3/f3.rs")).unwrap(), bytes);
    assert!(edit.uploaded < 256 * 1024, "edit uploaded {}", edit.uploaded);
    // A write that small goes over the link: a store round trip costs more.
    assert_eq!(edit.summary["store"]["reason"], "small", "{}", edit.summary);

    // A big file edited in the middle sends only the chunks around the edit.
    let model = repo.join("assets/model.bin");
    let mut big = std::fs::read(&model).unwrap();
    big[12 * 1024 * 1024] ^= 0xff;
    std::fs::write(&model, &big).unwrap();
    let big_direct = push(&direct_a, &repo, None, &unused);
    let big_edit = push(&a, &repo, Some(&origin), &store);
    assert_eq!(std::fs::read(a.home.join("work/app/assets/model.bin")).unwrap(), big);
    assert!(big_edit.uploaded < 20 * 1024 * 1024, "big edit uploaded {}", big_edit.uploaded);

    // A store that refuses the credential: the link copy still lands it all.
    let c = machine(&root, "c");
    let refused = {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .env("CMUX_TUI_STATE_DIR", c.socket.parent().unwrap().join("state"))
            .args(["link", "sync", "push", "--socket"])
            .arg(&c.socket)
            .arg(&repo)
            .arg(c.home.join("work/app"))
            .args(["--store", &origin])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped());
        let mut child = command.spawn().unwrap();
        writeln!(child.stdin.take().unwrap(), "wrong-credential").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        serde_json::from_slice::<Value>(&output.stdout).unwrap()
    };
    assert_eq!(refused["store"]["used"], false, "{refused}");
    same_tree(&repo, &c.home.join("work/app"));

    let row = |name: &str, before: &Measured, after: &Measured| {
        eprintln!(
            "| {name} | {} B, {} ms | {} B ({} B link + {} B store), {} ms |",
            before.sent_from_mac(),
            before.millis,
            after.sent_from_mac(),
            after.link,
            after.uploaded,
            after.millis
        );
    };
    for (name, measured) in
        [("edit", &edit_direct), ("big edit", &big_direct), ("store edit", &edit)]
    {
        eprintln!("{name}: written {} pushed {}", measured.summary["written"], measured.summary);
    }
    eprintln!("| case | direct link copy (bytes from the Mac, wall) | store |");
    row("first sync", &first_direct, &first);
    row("second machine", &second_direct, &second);
    row("one-file edit", &edit_direct, &edit);
    row("24 MiB file, 1 byte edited", &big_direct, &big_edit);
}

#[test]
fn a_lost_fetch_start_answer_fails_the_push_and_the_next_push_fences_its_job() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let repo = root.join("app");
    std::fs::create_dir_all(repo.join("assets")).unwrap();
    std::fs::write(repo.join("assets/big.bin"), noise(5, 3 * 1024 * 1024)).unwrap();
    std::fs::write(repo.join("readme.md"), b"hello\n").unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let (origin, store) = serve_store();
    let machine = machine(&root, "lost");
    // The start's answer is lost and the link with it: the job may be
    // writing, and it cannot be stopped, so nothing goes over the link.
    machine.lose_starts.store(1, Ordering::SeqCst);
    let failed = run_push(&machine, &repo, Some(&origin));
    let stdout = String::from_utf8_lossy(&failed.stdout);
    assert!(!failed.status.success(), "the push went on: {stdout}");
    assert!(stdout.contains("store fetch has not finished"), "{stdout}");
    // The next push stops that job first, then writes the whole tree.
    let again = push(&machine, &repo, Some(&origin), &store);
    assert_eq!(again.summary["store"]["used"], true, "{}", again.summary);
    same_tree(&repo, &machine.home.join("work/app"));
}

#[test]
fn a_file_only_a_failed_pushs_fetch_wrote_goes_once_the_tree_drops_it() {
    stray_after_failed_push(false);
}

#[test]
fn a_fetched_file_the_machine_changed_since_stays_when_the_tree_drops_it() {
    stray_after_failed_push(true);
}

fn stray_after_failed_push(edit_on_machine: bool) {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let repo = root.join("app");
    std::fs::create_dir_all(repo.join("assets")).unwrap();
    std::fs::write(repo.join("assets/big.bin"), noise(8, 3 * 1024 * 1024)).unwrap();
    std::fs::write(repo.join("readme.md"), b"hello\n").unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let (origin, store) = serve_store();
    let machine = machine(&root, "stray");
    // The push fails, but its fetch goes on and writes the file: no
    // manifest names it.
    machine.lose_starts.store(1, Ordering::SeqCst);
    assert!(!run_push(&machine, &repo, Some(&origin)).status.success());
    let stray = machine.home.join("work/app/assets/big.bin");
    let deadline = Instant::now() + Duration::from_secs(60);
    while !stray.exists() {
        assert!(Instant::now() < deadline, "the fetch never wrote");
        std::thread::sleep(Duration::from_millis(20));
    }
    if edit_on_machine {
        // Give the edit a revision of its own.
        std::thread::sleep(Duration::from_millis(1100));
        std::fs::write(&stray, b"edited on the machine").unwrap();
    }
    // The next push's tree has no such file: it goes from the machine,
    // unless the machine changed it since the fetch wrote it.
    git(&repo, &["rm", "-q", "assets/big.bin"]);
    git(&repo, &["commit", "-q", "-m", "drop"]);
    push(&machine, &repo, Some(&origin), &store);
    if edit_on_machine {
        assert_eq!(std::fs::read(&stray).unwrap(), b"edited on the machine");
    } else {
        assert!(!stray.exists(), "the fetched file stayed");
    }
    same_tree(&repo, &machine.home.join("work/app"));
}

#[test]
fn a_machine_with_the_pre_release_capability_gets_a_plain_link_copy() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let repo = root.join("app");
    std::fs::create_dir_all(repo.join("assets")).unwrap();
    std::fs::write(repo.join("assets/big.bin"), noise(6, 2 * 1024 * 1024)).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let (origin, store) = serve_store();
    let old = machine_serving(&root, "old", "blob-fetch-v1");
    for origin in [None, Some(origin.as_str())] {
        let pushed = push(&old, &repo, origin, &store);
        assert_ne!(pushed.summary["store"]["used"], true, "{}", pushed.summary);
        same_tree(&repo, &old.home.join("work/app"));
    }
    assert_eq!(store.uploaded.load(Ordering::SeqCst), 0);
}

#[test]
fn a_push_whose_fetch_a_newer_push_cancelled_stops_without_a_link_copy() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let repo = root.join("app");
    std::fs::create_dir_all(repo.join("assets")).unwrap();
    std::fs::write(repo.join("assets/big.bin"), noise(7, 3 * 1024 * 1024)).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let (origin, _store) = serve_store();
    let machine = machine(&root, "superseded");
    machine.supersede.store(1, Ordering::SeqCst);
    let before = machine.sent.load(Ordering::SeqCst);
    let failed = run_push(&machine, &repo, Some(&origin));
    let stdout = String::from_utf8_lossy(&failed.stdout);
    assert!(!failed.status.success(), "the push went on: {stdout}");
    assert!(stdout.contains("a newer push to this folder took over"), "{stdout}");
    // Nothing of the 3 MiB file crossed the link.
    let link = machine.sent.load(Ordering::SeqCst) - before;
    assert!(link < 1024 * 1024, "{link} bytes went over the link");
}
