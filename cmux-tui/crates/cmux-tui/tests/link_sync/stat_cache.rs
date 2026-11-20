//! The push's stat cache (`sync_cli/stat_cache.rs`): a file whose stat is the one this Mac
//! last hashed is not opened, and a push with the cache sends and records exactly what one
//! without it does.
use super::*;
use std::collections::BTreeMap;
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::time::Duration;

/// A push with the timings line on (and the stat cache off when `cache` is false): its answer
/// and its timings.
fn push_timed(socket: &Path, local: &Path, remote: &Path, cache: bool) -> (Value, Value) {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .env("CMUX_TUI_STATE_DIR", state_of(socket))
        .env("CMUX_SYNC_PUSH_TIMINGS", "1")
        .args(["link", "sync", "push", "--socket"])
        .arg(socket)
        .arg(local)
        .arg(remote);
    if !cache {
        command.env("CMUX_SYNC_STAT_CACHE", "0");
    }
    let output = command.output().unwrap();
    assert!(
        output.status.success(),
        "sync push failed: {}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let timings = String::from_utf8_lossy(&output.stderr)
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .find_map(|line| line.get("timings").cloned())
        .expect("a timings line");
    (serde_json::from_slice(&output.stdout).unwrap(), timings)
}

/// The stat caches this Mac keeps for a test's socket.
fn caches(socket: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(state_of(socket).join("link-sync")) else {
        return Vec::new();
    };
    entries
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "stat"))
        .collect()
}

/// A folder of `count` files in three folders, older than the cache's clock tick.
fn settled_folder(root: &Path, count: usize) -> PathBuf {
    let folder = root.join("notes");
    for index in 0..count {
        let path = folder.join(format!("d{}/n{index}.txt", index % 3));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, format!("note {index}\n")).unwrap();
    }
    std::thread::sleep(Duration::from_millis(120));
    folder
}

/// An unchanged re-push opens none of the folder's files (counted, not timed), and an edit of
/// the same size, even right after a push, is pushed.
#[test]
fn an_unchanged_re_push_opens_no_file_and_a_same_size_edit_is_pushed() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = settled_folder(&root, 30);
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs(&socket, &home);
    let remote = home.join("work/notes");

    let (first, timings) = push_timed(&socket, &folder, &remote, true);
    assert_eq!((first["written"].clone(), timings["hashed_files"].clone()), (json!(30), json!(30)));
    let kept = caches(&socket);
    assert_eq!(kept.len(), 1, "{kept:?}");
    assert_eq!(std::fs::metadata(&kept[0]).unwrap().mode() & 0o777, 0o600);

    let (again, timings) = push_timed(&socket, &folder, &remote, true);
    assert_eq!(again["unchanged"], json!(30), "{again}");
    assert_eq!(timings["opened_files"], json!(0), "{timings}");
    assert_eq!(timings["hashed_files"], json!(0), "{timings}");
    assert_eq!(timings["cached_files"], json!(30), "{timings}");

    // Same size, other bytes, written right after the push: pushed, and pushed again when it
    // changes once more at once.
    for text in ["NOTE 7\n", "note 7\n", "NoTe 7\n"] {
        std::fs::write(folder.join("d1/n7.txt"), text).unwrap();
        let (edited, timings) = push_timed(&socket, &folder, &remote, true);
        assert_eq!(edited["written"], json!(1), "{edited}");
        assert_eq!(timings["hashed_files"], json!(1), "{timings}");
        assert_eq!(std::fs::read_to_string(remote.join("d1/n7.txt")).unwrap(), text);
    }
}

/// A file touched without a change is read once, not written, and then cached again.
#[test]
fn a_touched_file_is_hashed_once_then_cached_again() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = settled_folder(&root, 6);
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs(&socket, &home);
    let remote = home.join("work/notes");
    push_timed(&socket, &folder, &remote, true);
    let touched = std::fs::File::options().write(true).open(folder.join("d0/n3.txt")).unwrap();
    touched.set_modified(std::time::SystemTime::now()).unwrap();
    std::thread::sleep(Duration::from_millis(120));
    let (answer, timings) = push_timed(&socket, &folder, &remote, true);
    assert_eq!((answer["written"].clone(), timings["hashed_files"].clone()), (json!(0), json!(1)));
    let (_, timings) = push_timed(&socket, &folder, &remote, true);
    assert_eq!(timings["hashed_files"], json!(0), "{timings}");
}

/// A file replaced by another inode with its size and mtime, a mode change, a file deleted
/// and made again, and a file swapped for a symlink and back all reach the machine.
#[test]
fn replaced_files_mode_changes_and_symlink_swaps_are_pushed() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("work");
    std::fs::create_dir_all(&folder).unwrap();
    for name in ["a.txt", "b.sh", "c.txt", "target.txt", "swap.txt"] {
        std::fs::write(folder.join(name), format!("{name:>12}\n")).unwrap();
    }
    std::thread::sleep(Duration::from_millis(120));
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs(&socket, &home);
    let remote = home.join("work/work");
    push_timed(&socket, &folder, &remote, true);

    let old = std::fs::metadata(folder.join("a.txt")).unwrap().modified().unwrap();
    std::fs::write(folder.join(".a.new"), "       A.TXT\n").unwrap();
    let new = std::fs::File::options().write(true).open(folder.join(".a.new")).unwrap();
    new.set_modified(old).unwrap();
    std::fs::rename(folder.join(".a.new"), folder.join("a.txt")).unwrap();
    std::fs::set_permissions(folder.join("b.sh"), std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::remove_file(folder.join("c.txt")).unwrap();
    std::fs::write(folder.join("c.txt"), "       C.TXT\n").unwrap();
    std::fs::remove_file(folder.join("swap.txt")).unwrap();
    std::os::unix::fs::symlink("target.txt", folder.join("swap.txt")).unwrap();
    let (answer, _) = push_timed(&socket, &folder, &remote, true);
    assert!(answer["ok"] == json!(true), "{answer}");
    assert_eq!(std::fs::read_to_string(remote.join("a.txt")).unwrap(), "       A.TXT\n");
    assert_eq!(std::fs::read_to_string(remote.join("c.txt")).unwrap(), "       C.TXT\n");
    assert_eq!(std::fs::metadata(remote.join("b.sh")).unwrap().mode() & 0o111, 0o111);
    assert_eq!(std::fs::read_link(remote.join("swap.txt")).unwrap(), Path::new("target.txt"));

    // Back to a file with the target's bytes (the size the link's target has).
    std::fs::remove_file(folder.join("swap.txt")).unwrap();
    std::fs::write(folder.join("swap.txt"), "  target.txt\n").unwrap();
    push_timed(&socket, &folder, &remote, true);
    let meta = std::fs::symlink_metadata(remote.join("swap.txt")).unwrap();
    assert!(meta.is_file());
    assert_eq!(std::fs::read_to_string(remote.join("swap.txt")).unwrap(), "  target.txt\n");
}

/// A damaged cache is ignored (every file hashed, the push as without one) and replaced by a
/// whole one; `CMUX_SYNC_STAT_CACHE=0` reads and writes none.
#[test]
fn a_damaged_cache_falls_back_and_the_switch_turns_it_off() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = settled_folder(&root, 9);
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs(&socket, &home);
    let remote = home.join("work/notes");
    let (_, timings) = push_timed(&socket, &folder, &remote, false);
    assert_eq!(timings["hashed_files"], json!(9));
    assert!(caches(&socket).is_empty(), "the switch wrote a cache");
    let (_, timings) = push_timed(&socket, &folder, &remote, false);
    assert_eq!(timings["hashed_files"], json!(9));

    push_timed(&socket, &folder, &remote, true);
    let cache = caches(&socket).pop().unwrap();
    let mut bytes = std::fs::read(&cache).unwrap();
    let middle = bytes.len() / 2;
    bytes[middle] ^= 0xff;
    std::fs::write(&cache, &bytes).unwrap();
    let (answer, timings) = push_timed(&socket, &folder, &remote, true);
    assert_eq!(
        (answer["unchanged"].clone(), timings["hashed_files"].clone()),
        (json!(9), json!(9))
    );
    let (_, timings) = push_timed(&socket, &folder, &remote, true);
    assert_eq!(timings["cached_files"], json!(9), "{timings}");
}

/// A small deterministic random source (xorshift64).
struct Random(u64);

impl Random {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, bound: usize) -> usize {
        usize::try_from(self.next() % bound as u64).unwrap()
    }

    fn bytes(&mut self, count: usize) -> Vec<u8> {
        (0..count).map(|_| (self.next() >> 24) as u8).collect()
    }
}

/// What the machine holds below `dir`: each file's bytes and executable bit, each link's text.
fn machine_tree(dir: &Path) -> BTreeMap<String, (Vec<u8>, u32, Option<PathBuf>)> {
    let mut found = BTreeMap::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(at) = stack.pop() {
        for entry in std::fs::read_dir(&at).unwrap() {
            let path = entry.unwrap().path();
            let name = path.strip_prefix(dir).unwrap().to_string_lossy().into_owned();
            let meta = std::fs::symlink_metadata(&path).unwrap();
            if name == ".cmux-sync.json" || name.ends_with(".cmux-sync-part") {
                continue;
            }
            if meta.file_type().is_symlink() {
                found.insert(name, (Vec::new(), 0, Some(std::fs::read_link(&path).unwrap())));
            } else if meta.is_dir() {
                stack.push(path);
            } else {
                found.insert(name, (std::fs::read(&path).unwrap(), meta.mode() & 0o111, None));
            }
        }
    }
    found
}

/// The machine's record: each file's hash and permissions, and the links.
fn record(remote: &Path) -> (BTreeMap<String, (String, u64)>, Value) {
    let record: Value =
        serde_json::from_slice(&std::fs::read(remote.join(".cmux-sync.json")).unwrap()).unwrap();
    let files = record["files"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(path, file)| {
            let sha = file["sha256"].as_str().unwrap().to_string();
            (path.clone(), (sha, file["permissions"].as_u64().unwrap()))
        })
        .collect();
    (files, record.get("links").cloned().unwrap_or(Value::Null))
}

/// Random trees and random edits (same-size rewrites, resizes, deletes and re-adds, mode
/// changes, touches, new inodes with the old mtime, symlinks), some right after a push and
/// some after a pause: a push with the cache and one without send and record the same, and
/// every recorded hash is the file's here.
#[test]
fn with_or_without_the_cache_a_push_sends_and_records_the_same() {
    let seed = std::env::var("STAT_CACHE_SEED").ok().and_then(|seed| seed.parse().ok());
    let seed = seed.unwrap_or(0x9e37_79b9_7f4a_7c15u64);
    let mut random = Random(seed);
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("tree");
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs(&socket, &home);
    let (cached, plain) = (home.join("work/cached"), home.join("work/plain"));
    let names: Vec<String> = (0..40).map(|index| format!("d{}/f{index}.txt", index % 4)).collect();
    for name in names.iter().take(24) {
        let path = folder.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let size = random.below(3000);
        std::fs::write(path, random.bytes(size)).unwrap();
    }
    for round in 0..24 {
        for _ in 0..1 + random.below(6) {
            let name = &names[random.below(names.len())];
            let path = folder.join(name);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            let meta = std::fs::symlink_metadata(&path).ok();
            let is_file = meta.as_ref().is_some_and(std::fs::Metadata::is_file);
            match random.below(9) {
                // Same size, other bytes, in place.
                0 if is_file => {
                    let size = usize::try_from(meta.unwrap().len()).unwrap();
                    let file = std::fs::File::options().write(true).open(&path).unwrap();
                    std::os::unix::fs::FileExt::write_all_at(&file, &random.bytes(size), 0)
                        .unwrap();
                }
                1 => {
                    let _ = std::fs::remove_file(&path);
                    let size = random.below(3000);
                    std::fs::write(&path, random.bytes(size)).unwrap();
                }
                2 => {
                    let _ = std::fs::remove_file(&path);
                }
                3 if is_file => {
                    let mode = meta.unwrap().mode() ^ 0o111;
                    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
                }
                4 if is_file => {
                    let file = std::fs::File::options().write(true).open(&path).unwrap();
                    file.set_modified(std::time::SystemTime::now()).unwrap();
                }
                // Another inode with the same size and mtime.
                5 if is_file => {
                    let meta = meta.unwrap();
                    let size = usize::try_from(meta.len()).unwrap();
                    let other = path.with_extension("new");
                    std::fs::write(&other, random.bytes(size)).unwrap();
                    let file = std::fs::File::options().write(true).open(&other).unwrap();
                    file.set_modified(meta.modified().unwrap()).unwrap();
                    std::fs::rename(&other, &path).unwrap();
                }
                // A symlink to a file of the same folder, or a symlink made a file again.
                6 => {
                    let _ = std::fs::remove_file(&path);
                    let target = names[random.below(names.len())].rsplit('/').next().unwrap();
                    std::os::unix::fs::symlink(target, &path).unwrap();
                }
                7 if meta.as_ref().is_some_and(|meta| meta.file_type().is_symlink()) => {
                    std::fs::remove_file(&path).unwrap();
                    let size = random.below(64);
                    std::fs::write(&path, random.bytes(size)).unwrap();
                }
                _ => {}
            }
        }
        if random.below(3) == 0 {
            std::thread::sleep(Duration::from_millis(80));
        }
        let (with, timings) = push_timed(&socket, &folder, &cached, true);
        let (without, _) = push_timed(&socket, &folder, &plain, false);
        let context = format!("seed {seed:#x} round {round}: {timings}");
        for key in ["written", "unchanged", "deleted", "skipped", "bytes"] {
            assert_eq!(with[key], without[key], "{key}, {context}\n{with}\n{without}");
        }
        assert_eq!(record(&cached), record(&plain), "{context}");
        assert_eq!(machine_tree(&cached), machine_tree(&plain), "{context}");
        for (relative, (sha, _)) in record(&cached).0 {
            let here = std::fs::read(folder.join(&relative)).unwrap();
            assert_eq!(sha, sha256_hex(&here), "{relative}, {context}");
        }
    }
}
