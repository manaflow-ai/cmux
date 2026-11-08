//! An upload takes a file of any size (Leo: "Attachments take arbitrarily
//! large files of any type; there is no size cap"), sent to the machine in
//! bounded parts, never read whole into memory.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::thread::JoinHandle;

use serde_json::{Value, json};

use super::{cancel, upload, upload_with_id};

/// The most bytes one `fs.write` part carries (the sync remote's part).
const PART_BYTES: u64 = 8 * 1024 * 1024;

/// What the fake machine saw: each write's mode and decoded size, and the
/// size of every file it ended with.
struct Seen {
    writes: Vec<(String, u64)>,
    files: BTreeMap<String, u64>,
}

/// Decoded size of standard base64 `text`, without decoding it.
fn decoded_len(text: &str) -> u64 {
    let padding = text.bytes().rev().take_while(|byte| *byte == b'=').count();
    (text.len() / 4 * 3 - padding) as u64
}

/// A machine daemon on `socket` answering the `fs-v1` requests one upload
/// makes, for one connection, under the folder `root`.
fn fake_machine(socket: &Path, root: &str) -> JoinHandle<Seen> {
    fake_machine_with_files(socket, root, BTreeMap::new())
}

fn fake_machine_with_files(
    socket: &Path,
    root: &str,
    files: BTreeMap<String, u64>,
) -> JoinHandle<Seen> {
    let listener = UnixListener::bind(socket).unwrap();
    let root = root.to_string();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut writer = stream.try_clone().unwrap();
        let mut reader = BufReader::new(stream);
        let mut dirs: BTreeSet<String> = ["/".to_string(), root].into();
        let mut seen = Seen { writes: Vec::new(), files };
        let mut line = String::new();
        loop {
            line.clear();
            if reader.read_line(&mut line).unwrap() == 0 {
                return seen;
            }
            let request: Value = serde_json::from_str(&line).unwrap();
            let path = request["path"].as_str().unwrap_or_default().to_string();
            let answer = match request["cmd"].as_str().unwrap() {
                "fs.stat" if dirs.contains(&path) => Ok(json!({"kind": "dir"})),
                "fs.stat" if seen.files.contains_key(&path) => Ok(json!({"kind": "file"})),
                "fs.stat" => Err("fs.not_found"),
                "fs.mkdir" => {
                    let name = request["name"].as_str().unwrap();
                    dirs.insert(format!("{}/{name}", path.trim_end_matches('/')));
                    Ok(json!({"entry": {}}))
                }
                "fs.write" => {
                    let mode = request["mode"].as_str().unwrap().to_string();
                    let bytes = decoded_len(request["bytes_base64"].as_str().unwrap());
                    seen.writes.push((mode.clone(), bytes));
                    let size = seen.files.entry(path).or_default();
                    *size = if mode == "append" { *size + bytes } else { bytes };
                    Ok(json!({"entry": {"revision": format!("r{}", seen.writes.len())}}))
                }
                "fs.delete" => {
                    for path in request["paths"].as_array().unwrap() {
                        let path = path.as_str().unwrap();
                        seen.files
                            .retain(|at, _| at != path && !at.starts_with(&format!("{path}/")));
                    }
                    Ok(json!({}))
                }
                "fs.rename" => {
                    let size = seen.files.remove(&path).unwrap();
                    let (parent, _) = path.rsplit_once('/').unwrap();
                    let name = request["name"].as_str().unwrap();
                    seen.files.insert(format!("{parent}/{name}"), size);
                    Ok(json!({"entry": {"revision": "renamed"}}))
                }
                other => panic!("the upload asked for {other}"),
            };
            let id = request["id"].clone();
            let reply = match answer {
                Ok(data) => json!({"id": id, "ok": true, "data": data}),
                Err(code) => json!({"id": id, "ok": false, "error_code": code, "error": code}),
            };
            writer.write_all(format!("{reply}\n").as_bytes()).unwrap();
        }
    })
}

/// A sparse 1 GiB + 1 byte file pasted into a Cloud chat is uploaded, not
/// refused, and reaches the machine whole in parts of at most 8 MiB.
#[test]
fn a_sparse_file_over_1_gib_uploads_in_bounded_parts() {
    let pastes = std::env::temp_dir().join(super::PASTES);
    std::fs::create_dir_all(&pastes).unwrap();
    let folder = tempfile::Builder::new().prefix("upload-test-").tempdir_in(&pastes).unwrap();
    let file = folder.path().join("big.bin");
    let size = (1u64 << 30) + 1;
    std::fs::File::create(&file).unwrap().set_len(size).unwrap();
    let daemon = tempfile::Builder::new().prefix("upload-sock-").tempdir().unwrap();
    let socket = daemon.path().join("d.sock");
    let machine = fake_machine(&socket, "/work");

    let answer = match upload(&socket, "/work", &[file.to_string_lossy().into_owned()]) {
        Ok(answer) => answer,
        Err(failure) => panic!("refused: {} {}", failure.code, failure.error),
    };
    let seen = machine.join().unwrap();

    let at = answer["uploads"][0]["path"].as_str().unwrap();
    assert!(at.starts_with("/work/local/uploads/") && at.ends_with("/big.bin"), "{answer}");
    assert_eq!(seen.files.get(at), Some(&size), "{:?}", seen.files);
    assert_eq!(seen.writes.len() as u64, size.div_ceil(PART_BYTES));
    assert!(seen.writes.iter().all(|(_, bytes)| *bytes <= PART_BYTES));
    assert_eq!(seen.writes[0].0, "overwrite");
    assert!(seen.writes[1..].iter().all(|(mode, _)| mode == "append"));
}

/// Malformed ids cannot turn cancellation into deletion of another path, and the upload checks
/// ids before opening the socket or reading the source.
#[test]
fn upload_cancel_refuses_ids_outside_its_random_directory() {
    for id in [
        "",
        "../other",
        "/work",
        "ABCDEF0123456789abcdef0123456789",
        "0123456789abcdef0123456789abcde/",
    ] {
        let failure = cancel(Path::new("/absent.sock"), "/work", id).unwrap_err();
        assert_eq!(failure.code, "upload_refused");
        let failure =
            upload_with_id(Path::new("/absent.sock"), "/work", &["/absent.bin".into()], Some(id))
                .unwrap_err();
        assert_eq!(failure.code, "upload_refused");
    }
}

#[test]
fn upload_cancel_only_deletes_its_owned_directory() {
    let daemon = tempfile::tempdir().unwrap();
    let socket = daemon.path().join("d.sock");
    let owned = "/work/local/uploads/0123456789abcdef0123456789abcdef/.big.bin.cmux-sync-part";
    let other = "/work/local/uploads/fedcba9876543210fedcba9876543210/keep.bin";
    let files = [(owned.to_string(), PART_BYTES), (other.to_string(), 12)].into();
    let machine = fake_machine_with_files(&socket, "/work", files);
    assert!(cancel(&socket, "/work", "0123456789abcdef0123456789abcdef").is_ok());
    let seen = machine.join().unwrap();
    assert_eq!(seen.files, [(other.to_string(), 12)].into());
    assert!(seen.writes.is_empty());
}
