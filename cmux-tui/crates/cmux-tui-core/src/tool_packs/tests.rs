use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use serde_json::json;
use sha2::{Digest as _, Sha256};

use super::*;

/// A folder of this test's own, removed when dropped.
struct Folder(PathBuf);

impl Folder {
    fn new(label: &str) -> Self {
        let mut random = [0u8; 6];
        getrandom::fill(&mut random).unwrap();
        let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let path = std::env::temp_dir().join(format!("cmux-tool-packs-{label}-{suffix}"));
        std::fs::create_dir_all(&path).unwrap();
        Self(std::fs::canonicalize(path).unwrap())
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn sha(bytes: &[u8]) -> String {
    language_packs::hex(&Sha256::digest(bytes))
}

/// The pack tool-packs.py writes: one entry `name`, mode 0755, zstd.
fn pack(name: &str, tool: &[u8]) -> Vec<u8> {
    let mut builder = tar::Builder::new(Vec::new());
    let mut header = tar::Header::new_ustar();
    header.set_path(name).unwrap();
    header.set_entry_type(tar::EntryType::Regular);
    header.set_size(tool.len() as u64);
    header.set_mode(0o755);
    header.set_mtime(0);
    header.set_cksum();
    builder.append(&header, tool).unwrap();
    zstd::encode_all(&builder.into_inner().unwrap()[..], 3).unwrap()
}

/// A loopback server that answers every GET with `body`, counting the connections.
struct Server {
    url: String,
    requests: Arc<AtomicUsize>,
}

impl Server {
    fn start(body: Vec<u8>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let url = format!("http://127.0.0.1:{port}/tool-packs/x/cmux-mobile-host.tar.zst");
        let requests = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&requests);
        let body = Arc::new(body);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                counter.fetch_add(1, Ordering::SeqCst);
                let body = Arc::clone(&body);
                std::thread::spawn(move || {
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    loop {
                        let mut line = String::new();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                            break;
                        }
                    }
                    let head = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    let _ = stream.write_all(head.as_bytes());
                    let _ = stream.write_all(&body);
                });
            }
        });
        Self { url, requests }
    }
}

const NAME: &str = "cmux-mobile-host";
const TOOL: &[u8] = b"#!/bin/sh\necho the iPhone host\n";

/// A tool served by a loopback server and pinned as tool-packs.py pins it.
fn served(tool: &[u8], pinned_file: &[u8]) -> (Server, Tool) {
    let body = pack(NAME, tool);
    let server = Server::start(body.clone());
    let tool = Tool {
        url: server.url.clone(),
        sha256: sha(&body),
        size: body.len() as u64,
        file_sha256: sha(pinned_file),
        file_size: pinned_file.len() as u64,
    };
    (server, tool)
}

/// `<app>/Contents/Resources/{bin/, tool-packs.json}` with `tool` pinned; the bin folder.
fn app_with_pin(folder: &Path, tool: &Tool) -> PathBuf {
    let resources = folder.join("app").join("Contents").join("Resources");
    let bin = resources.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let pin = json!({"version": 1, "tools": {NAME: {
        "url": tool.url, "sha256": tool.sha256, "size": tool.size,
        "file_sha256": tool.file_sha256, "file_size": tool.file_size}}});
    std::fs::write(resources.join(PIN_NAME), serde_json::to_vec(&pin).unwrap()).unwrap();
    bin
}

const SHA_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const SHA_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

#[test]
fn a_pin_is_version_1_naming_known_well_formed_tools() {
    let url = "https://files-next.cmux.com/tool-packs/x/cmux-mobile-host.tar.zst";
    let pin = |version: u32, name: &str, url: &str, sha256: &str| {
        serde_json::to_vec(&json!({"version": version, "tools": {name: {
            "url": url, "sha256": sha256, "size": 10, "file_sha256": SHA_B, "file_size": 20}}}))
        .unwrap()
    };
    let tool = parse(&pin(1, NAME, url, SHA_A), NAME).unwrap().unwrap();
    assert_eq!(
        tool,
        Tool {
            url: url.into(),
            sha256: SHA_A.into(),
            size: 10,
            file_sha256: SHA_B.into(),
            file_size: 20
        }
    );
    // A pin that does not name the tool: the tool is in bin/ itself.
    assert_eq!(parse(&pin(1, NAME, url, SHA_A), "optchat-chief"), Ok(None));
    assert_eq!(parse(&pin(2, NAME, url, SHA_A), NAME), Err(Code::BadManifest));
    assert_eq!(parse(&pin(1, NAME, url, "nothex"), NAME), Err(Code::BadManifest));
    assert_eq!(
        parse(&pin(1, NAME, "https://example.com/x.tar.zst", SHA_A), NAME),
        Err(Code::BadManifest)
    );
    // A name cmux does not answer to is refused even when pinned.
    assert_eq!(parse(&pin(1, "sh", url, SHA_A), "sh"), Err(Code::BadManifest));
    assert_eq!(parse(b"not json", NAME), Err(Code::BadManifest));
}

#[test]
fn an_app_without_a_pin_has_no_pinned_tool() {
    let folder = Folder::new("no-pin");
    let bin = folder.path().join("Contents").join("Resources").join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    assert_eq!(pinned(&bin, NAME), Ok(None));
}

#[test]
fn ensure_downloads_once_checks_the_tool_and_marks_it_executable() {
    let folder = Folder::new("ensure");
    let cache = folder.path().join("cache");
    let (server, tool) = served(TOOL, TOOL);
    let bin = app_with_pin(folder.path(), &tool);
    assert_eq!(pinned(&bin, NAME), Ok(Some(tool.clone())));

    let path = ensure(&cache, &tool, NAME).unwrap();
    assert_eq!(path, tool_path(&cache, &tool, NAME));
    assert_eq!(std::fs::read(&path).unwrap(), TOOL);
    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o755);
    assert!(cache.join(&tool.sha256).join(USED).is_file());
    assert_eq!(server.requests.load(Ordering::SeqCst), 1);

    // The second run uses the cache.
    assert_eq!(ensure(&cache, &tool, NAME).unwrap(), path);
    assert_eq!(server.requests.load(Ordering::SeqCst), 1);

    // The daemon admits the cached copy while it hashes to the pin.
    let checked = Mutex::new(None);
    assert_eq!(verified_in(&cache, &bin, NAME, &checked), Some(path.clone()));
    assert_eq!(verified_in(&cache, &bin, NAME, &checked), Some(path.clone()));
    std::fs::write(&path, b"#!/bin/sh\necho not the host\n").unwrap();
    assert_eq!(verified_in(&cache, &bin, NAME, &checked), None);
}

#[test]
fn a_pack_whose_tool_is_not_the_pinned_one_is_refused_and_removed() {
    let folder = Folder::new("wrong-tool");
    let cache = folder.path().join("cache");
    // The pack itself matches its pin; the file inside does not match the tool's.
    let (_server, tool) = served(b"#!/bin/sh\necho another\n", TOOL);
    assert_eq!(ensure(&cache, &tool, NAME), Err(Code::Verify));
    assert!(!cache.join(&tool.sha256).exists());
    let bin = app_with_pin(folder.path(), &tool);
    assert_eq!(verified_in(&cache, &bin, NAME, &Mutex::new(None)), None);
}

#[test]
fn a_pack_that_does_not_match_its_pin_is_refused() {
    let folder = Folder::new("wrong-pack");
    let cache = folder.path().join("cache");
    let (_server, mut tool) = served(TOOL, TOOL);
    tool.sha256 = SHA_A.into();
    assert_eq!(ensure(&cache, &tool, NAME), Err(Code::Verify));
    assert!(!cache.join(SHA_A).exists());
}

#[test]
fn prune_removes_unused_packs_and_stale_partials_only() {
    let folder = Folder::new("prune");
    let cache = folder.path();
    let now = SystemTime::now();
    let old = now - UNUSED - Duration::from_secs(60);
    for sha in [SHA_A, SHA_B] {
        std::fs::create_dir_all(cache.join(sha)).unwrap();
        let used = std::fs::File::create(cache.join(sha).join(USED)).unwrap();
        used.set_modified(old).unwrap();
    }
    let recent = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    std::fs::create_dir_all(cache.join(recent)).unwrap();
    std::fs::File::create(cache.join(recent).join(USED)).unwrap();
    let partial = cache.join(format!("{PARTIAL}{SHA_A}-1-0"));
    std::fs::create_dir_all(&partial).unwrap();
    let not_ours = cache.join("notes");
    std::fs::create_dir_all(&not_ours).unwrap();

    // A fresh partial is a live run's.
    prune(cache, SHA_A, now);
    assert!(cache.join(SHA_A).is_dir(), "the pack in use stays");
    assert!(!cache.join(SHA_B).exists(), "an unused pack goes");
    assert!(cache.join(recent).is_dir(), "a recently used pack stays");
    assert!(partial.is_dir());
    assert!(not_ours.is_dir());

    prune(cache, SHA_A, now + STALE_PARTIAL + Duration::from_secs(60));
    assert!(!partial.exists(), "a stale partial goes");
    assert!(not_ours.is_dir());
}
