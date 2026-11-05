use std::io::{BufRead, BufReader, Seek, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::Path;

use base64::Engine as _;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::super::backend::{ChatClient, Owner};
use super::super::link::Link;

#[derive(Default)]
struct Received {
    begin: Value,
    bytes: u64,
    largest_chunk: usize,
    committed: bool,
}

/// A wire peer consumes each chunk immediately, retaining only its hash and count.
fn upload(
    path: &Path,
    owner: Owner,
    after_begin: impl FnOnce() + Send + 'static,
) -> (Result<Value, String>, Received) {
    let dir = cmux_unix_socket::short_test_dir("chief-upload");
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let socket = dir.path().join("daemon.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let peer = std::thread::spawn(move || {
        let (mut writer, _) = listener.accept().unwrap();
        writer.set_read_timeout(Some(std::time::Duration::from_secs(15))).unwrap();
        let mut reader = BufReader::new(writer.try_clone().unwrap());
        let mut got = Received::default();
        let mut hash = Sha256::new();
        let mut line = String::new();
        let mut after_begin = Some(after_begin);
        while reader.read_line(&mut line).unwrap() != 0 {
            let request: Value = serde_json::from_str(&line).unwrap();
            line.clear();
            assert_eq!(
                request["cmd"],
                match owner {
                    Owner::Local => "conversation-attachment-upload",
                    Owner::Cloud => "cloud-attachment-upload",
                }
            );
            let data = match request["op"].as_str().unwrap() {
                "begin" => {
                    got.begin = request.clone();
                    after_begin.take().unwrap()();
                    json!({"upload": "stream", "needs": ["original"]})
                }
                "chunk" => {
                    assert_eq!(request["offset"], got.bytes);
                    let piece = base64::engine::general_purpose::STANDARD
                        .decode(request["data"].as_str().unwrap())
                        .unwrap();
                    assert!(piece.len() <= 2 << 20);
                    got.largest_chunk = got.largest_chunk.max(piece.len());
                    got.bytes += piece.len() as u64;
                    hash.update(piece);
                    json!({"received": got.bytes})
                }
                "commit" => {
                    assert_eq!(got.begin["byte_count"], got.bytes);
                    assert_eq!(got.begin["sha256"], format!("{:x}", hash.clone().finalize()));
                    got.committed = true;
                    json!({"stored": {"hash": got.begin["sha256"],
                        "mime_type": got.begin["mime_type"], "byte_count": got.bytes}})
                }
                "cancel" => json!({}),
                other => panic!("unexpected upload step: {other}"),
            };
            writeln!(writer, "{}", json!({"id": request["id"], "ok": true, "data": data})).unwrap();
            if got.committed {
                break;
            }
        }
        got
    });
    let mut client = ChatClient { link: Link::connect(&socket, true).unwrap(), owner };
    let result = client.upload("conv_upload", path);
    drop(client);
    (result, peer.join().unwrap())
}

#[test]
fn chief_attachment_streams_past_100_mb_on_both_owners() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("large.unknown");
    let mut file = std::fs::File::create(&path).unwrap();
    // Sparse source, but every byte crosses the real ChatClient/Link wire path.
    let bytes = 100 * 1024 * 1024 + 7;
    file.set_len(bytes).unwrap();
    file.seek(std::io::SeekFrom::End(-7)).unwrap();
    file.write_all(b"the end").unwrap();
    for owner in [Owner::Local, Owner::Cloud] {
        let (result, got) = upload(&path, owner, || {});
        let part = result.unwrap();
        assert!(got.committed);
        assert_eq!(got.bytes, bytes);
        assert!(got.largest_chunk > 0 && got.largest_chunk <= 2 << 20);
        assert_eq!(part["byte_count"], bytes);
        assert_eq!(part["hash"], got.begin["sha256"]);
        assert_eq!(part["mime_type"], "text/plain");
    }
}

/// Run the compiled test directly under `/usr/bin/time` on base and head so
/// compiler memory does not enter the upload's peak-RSS measurement.
#[test]
#[ignore = "same-harness attachment memory measurement"]
fn chief_attachment_upload_memory_probe() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("memory.bin");
    let bytes = 80 * 1024 * 1024 + 7;
    std::fs::File::create(&path).unwrap().set_len(bytes).unwrap();
    let (result, got) = upload(&path, Owner::Local, || {});
    assert_eq!(result.unwrap()["byte_count"], bytes);
    assert!(got.committed);
    assert_eq!(got.bytes, bytes);
}

#[test]
fn chief_attachment_sniffs_utf8_across_chunk_boundaries_and_rejects_mutation() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("unicode.unknown");
    let mut file = std::fs::File::create(&path).unwrap();
    file.set_len((2 << 20) - 1).unwrap();
    file.seek(std::io::SeekFrom::End(0)).unwrap();
    file.write_all("🦀end".as_bytes()).unwrap();
    let (result, got) = upload(&path, Owner::Cloud, || {});
    assert_eq!(result.unwrap()["mime_type"], "text/plain");
    assert!(got.committed);

    file.rewind().unwrap();
    file.write_all(&[0xff]).unwrap();
    let (result, got) = upload(&path, Owner::Local, || {});
    assert_eq!(result.unwrap()["mime_type"], "application/octet-stream");
    assert!(got.committed);
    file.rewind().unwrap();
    file.write_all(b"x").unwrap();

    let changed = path.clone();
    let (result, got) = upload(&path, Owner::Local, move || {
        std::fs::OpenOptions::new()
            .write(true)
            .open(changed)
            .unwrap()
            .write_all(b"changed")
            .unwrap();
    });
    assert!(result.unwrap_err().contains("changed"));
    assert!(!got.committed, "a changed source must never publish a truncated or wrong attachment");
}
