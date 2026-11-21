//! `cmux link sync history|undo|restore`: this Mac keeps snapshots of a
//! synced folder (manifests pointing at content-addressed blobs) and puts
//! the folder back exactly as one was. The machine side is the real
//! `FsService` behind a socket that answers lines as the daemon does.
#![cfg(unix)]

use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::Command;

use cmux_tui_core::fs_ops::{FsService, Roots, stream};
use serde_json::{Value, json};

fn serve_fs(socket: &Path, home: &Path) {
    let listener = UnixListener::bind(socket).unwrap();
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.to_path_buf()]))));
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            std::thread::spawn(move || {
                let mut writer = connection.try_clone().unwrap();
                for line in BufReader::new(connection).lines() {
                    let Ok(line) = line else { return };
                    let request: Value = serde_json::from_str(&line).unwrap();
                    let id = request["id"].clone();
                    let cmd = request["cmd"].as_str().unwrap_or_default().to_string();
                    let reply = stream::answer(&id, service.call("local", &cmd, request));
                    let mut text = reply.to_string();
                    text.push('\n');
                    if writer.write_all(text.as_bytes()).is_err() {
                        return;
                    }
                }
            });
        }
    });
}

struct Setup {
    _root: tempfile::TempDir,
    _sockets: tempfile::TempDir,
    folder: PathBuf,
    remote: PathBuf,
    socket: PathBuf,
    state: PathBuf,
}

fn setup(name: &str) -> Setup {
    let root_dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root_dir.path()).unwrap();
    let home = root.join("home");
    std::fs::create_dir_all(home.join("work")).unwrap();
    let sockets = tempfile::Builder::new().prefix("ch").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("fs.sock");
    serve_fs(&socket, &home);
    let folder = root.join(name);
    std::fs::create_dir_all(&folder).unwrap();
    Setup {
        folder,
        remote: home.join("work").join(name),
        socket,
        state: root.join("state"),
        _root: root_dir,
        _sockets: sockets,
    }
}

fn cmux(setup: &Setup, args: &[&str]) -> (bool, Value) {
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("CMUX_TUI_STATE_DIR", &setup.state)
        .args(["link", "sync"])
        .args(args)
        .output()
        .unwrap();
    let answer = serde_json::from_slice(&output.stdout).unwrap_or_else(|_| {
        panic!(
            "no JSON line: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    });
    (output.status.success(), answer)
}

fn synced(setup: &Setup, action: &str) -> Value {
    let socket = setup.socket.to_str().unwrap();
    let (folder, remote) = (setup.folder.to_str().unwrap(), setup.remote.to_str().unwrap());
    let (ok, answer) = cmux(setup, &[action, "--socket", socket, folder, remote]);
    assert!(ok, "{action}: {answer}");
    answer
}

fn local_only(setup: &Setup, args: &[&str]) -> (bool, Value) {
    let (folder, remote) = (setup.folder.to_str().unwrap(), setup.remote.to_str().unwrap());
    let mut all = vec![args[0], folder, remote];
    all.extend_from_slice(&args[1..]);
    cmux(setup, &all)
}

/// Every file below `dir` but sync records and git's own folder: its path,
/// bytes and permissions.
fn tree(dir: &Path) -> Vec<(String, Vec<u8>, u32)> {
    let mut found = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(next) = stack.pop() {
        for entry in std::fs::read_dir(&next).unwrap() {
            let entry = entry.unwrap();
            let path = entry.path();
            let relative = path.strip_prefix(dir).unwrap().to_string_lossy().into_owned();
            if relative == ".git" || relative.starts_with(".cmux-sync") {
                continue;
            }
            let meta = std::fs::symlink_metadata(&path).unwrap();
            if meta.is_dir() {
                stack.push(path);
            } else {
                let mode = meta.permissions().mode() & 0o777;
                found.push((relative, std::fs::read(&path).unwrap(), mode));
            }
        }
    }
    found.sort();
    found
}

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap()
}

/// A pull that changed, added and deleted files is undone exactly: every
/// byte and permission of the folder is as it was before the pull, and the
/// undo is listed in the history.
#[test]
fn an_undo_puts_the_folder_back_exactly_as_before_the_pull() {
    let setup = setup("notes");
    std::fs::create_dir_all(setup.folder.join("docs")).unwrap();
    std::fs::write(setup.folder.join("a.txt"), "one\n").unwrap();
    std::fs::write(setup.folder.join("docs/b.sh"), "#!/bin/sh\necho b\n").unwrap();
    std::fs::set_permissions(
        setup.folder.join("docs/b.sh"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    synced(&setup, "push");
    let before = tree(&setup.folder);

    // The machine changes one, deletes one and adds one.
    std::fs::write(setup.remote.join("a.txt"), "one\ntwo from the machine\n").unwrap();
    std::fs::remove_file(setup.remote.join("docs/b.sh")).unwrap();
    std::fs::write(setup.remote.join("docs/new.md"), "new\n").unwrap();
    let pulled = synced(&setup, "pull");
    assert_eq!(pulled["written"].as_u64(), Some(2), "{pulled}");
    assert_eq!(pulled["deleted"].as_u64(), Some(1), "{pulled}");
    assert_ne!(tree(&setup.folder), before);

    let (ok, history) = local_only(&setup, &["history"]);
    assert!(ok, "{history}");
    let actions: Vec<&str> = history["snapshots"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|s| s["action"].as_str())
        .collect();
    // Nothing changed here between the push and the pull: the state before
    // the pull is the push's, kept once.
    assert_eq!(actions, ["pull", "push"], "{history}");

    let (ok, undone) = local_only(&setup, &["undo"]);
    assert!(ok, "{undone}");
    assert_eq!(tree(&setup.folder), before, "the undo did not put the folder back exactly");
    assert!(!setup.folder.join("docs/new.md").exists());

    // Undo again goes further back than the push: there is nothing earlier.
    let (ok, again) = local_only(&setup, &["undo"]);
    assert!(!ok, "{again}");
    assert_eq!(again["error_code"], "sync_no_snapshot", "{again}");
    assert_eq!(tree(&setup.folder), before);

    // Restoring the pull's snapshot by number brings the machine's edits back.
    let pull_seq = history["snapshots"][0]["seq"].as_u64().unwrap().to_string();
    let (ok, redone) = local_only(&setup, &["restore", &pull_seq]);
    assert!(ok, "{redone}");
    assert_eq!(
        std::fs::read_to_string(setup.folder.join("a.txt")).unwrap(),
        "one\ntwo from the machine\n"
    );
    assert!(setup.folder.join("docs/new.md").exists());
    assert!(!setup.folder.join("docs/b.sh").exists());
}

/// A file changed here since the last sync stops an undo, and nothing in
/// the folder changes.
#[test]
fn an_undo_never_overwrites_a_change_made_here_since_the_sync() {
    let setup = setup("draft");
    std::fs::write(setup.folder.join("a.txt"), "one\n").unwrap();
    std::fs::write(setup.folder.join("b.txt"), "b\n").unwrap();
    synced(&setup, "push");
    std::fs::write(setup.remote.join("a.txt"), "machine\n").unwrap();
    std::fs::write(setup.remote.join("b.txt"), "machine b\n").unwrap();
    synced(&setup, "pull");

    std::fs::write(setup.folder.join("a.txt"), "edited here after the pull\n").unwrap();
    let edited = tree(&setup.folder);
    let (ok, refused) = local_only(&setup, &["undo"]);
    assert!(!ok, "{refused}");
    assert_eq!(refused["error_code"], "sync_restore_conflict", "{refused}");
    assert_eq!(refused["paths"], json!(["a.txt"]), "{refused}");
    assert_eq!(tree(&setup.folder), edited, "a refused undo changed the folder");

    // Put back as the pull left it, the undo goes through.
    std::fs::write(setup.folder.join("a.txt"), "machine\n").unwrap();
    let (ok, undone) = local_only(&setup, &["undo"]);
    assert!(ok, "{undone}");
    assert_eq!(std::fs::read_to_string(setup.folder.join("a.txt")).unwrap(), "one\n");
    assert_eq!(std::fs::read_to_string(setup.folder.join("b.txt")).unwrap(), "b\n");
}

/// In git, an undo of a pull that fast-forwarded the branch moves it back
/// and puts the working tree back.
#[test]
fn an_undo_in_git_moves_the_branch_back() {
    let setup = setup("app");
    git(&setup.folder, &["init", "-q", "-b", "main"]);
    std::fs::write(setup.folder.join("a.txt"), "one\n").unwrap();
    git(&setup.folder, &["add", "-A"]);
    git(&setup.folder, &["commit", "-q", "-m", "first"]);
    let first = git(&setup.folder, &["rev-parse", "HEAD"]);
    synced(&setup, "push");

    std::fs::write(setup.remote.join("a.txt"), "one\ntwo\n").unwrap();
    git(&setup.remote, &["commit", "-q", "-am", "second"]);
    let pulled = synced(&setup, "pull");
    assert_eq!(pulled["fast_forwarded"], json!(true), "{pulled}");
    assert_ne!(git(&setup.folder, &["rev-parse", "HEAD"]), first);

    let (ok, undone) = local_only(&setup, &["undo"]);
    assert!(ok, "{undone}");
    assert_eq!(undone["git_moved"], json!(true), "{undone}");
    assert_eq!(git(&setup.folder, &["rev-parse", "HEAD"]), first);
    assert_eq!(std::fs::read_to_string(setup.folder.join("a.txt")).unwrap(), "one\n");
    assert_eq!(git(&setup.folder, &["status", "--porcelain"]), "");
}

/// An undo puts back only what a sync changed: a file edited here before
/// the pull, and a file made here, keep this Mac's version after a push.
#[test]
fn an_undo_never_puts_back_what_this_mac_changed_itself() {
    let setup = setup("mine");
    std::fs::write(setup.folder.join("a.txt"), "a\n").unwrap();
    std::fs::write(setup.folder.join("b.txt"), "b\n").unwrap();
    synced(&setup, "push");

    // Edited and made here, while the machine changes b.
    std::fs::write(setup.folder.join("a.txt"), "a edited here\n").unwrap();
    std::fs::write(setup.folder.join("c.txt"), "made here\n").unwrap();
    std::fs::write(setup.remote.join("b.txt"), "b from the machine\n").unwrap();
    synced(&setup, "pull");
    synced(&setup, "push");

    let (ok, undone) = local_only(&setup, &["undo"]);
    assert!(ok, "{undone}");
    assert_eq!(std::fs::read_to_string(setup.folder.join("b.txt")).unwrap(), "b\n");
    assert_eq!(std::fs::read_to_string(setup.folder.join("a.txt")).unwrap(), "a edited here\n");
    assert_eq!(std::fs::read_to_string(setup.folder.join("c.txt")).unwrap(), "made here\n");
}

/// A locked git index stops an undo before the branch moves: HEAD, the
/// index and the files stay as the pull left them.
#[test]
fn a_locked_index_stops_an_undo_before_the_branch_moves() {
    let setup = setup("locked");
    git(&setup.folder, &["init", "-q", "-b", "main"]);
    std::fs::write(setup.folder.join("a.txt"), "one\n").unwrap();
    git(&setup.folder, &["add", "-A"]);
    git(&setup.folder, &["commit", "-q", "-m", "first"]);
    let first = git(&setup.folder, &["rev-parse", "HEAD"]);
    synced(&setup, "push");
    std::fs::write(setup.remote.join("a.txt"), "one\ntwo\n").unwrap();
    git(&setup.remote, &["commit", "-q", "-am", "second"]);
    let pulled = synced(&setup, "pull");
    assert_eq!(pulled["fast_forwarded"], json!(true), "{pulled}");
    let second = git(&setup.folder, &["rev-parse", "HEAD"]);

    let lock = setup.folder.join(".git/index.lock");
    std::fs::write(&lock, "").unwrap();
    let (ok, refused) = local_only(&setup, &["undo"]);
    assert!(!ok, "{refused}");
    assert_eq!(git(&setup.folder, &["rev-parse", "HEAD"]), second);
    assert_eq!(std::fs::read_to_string(setup.folder.join("a.txt")).unwrap(), "one\ntwo\n");
    assert!(lock.exists(), "the undo removed a lock it did not make");

    std::fs::remove_file(&lock).unwrap();
    let (ok, undone) = local_only(&setup, &["undo"]);
    assert!(ok, "{undone}");
    assert_eq!(git(&setup.folder, &["rev-parse", "HEAD"]), first);
    assert_eq!(git(&setup.folder, &["status", "--porcelain"]), "");
}

/// Both sides changed a text file on different lines: the pull merges them
/// by line, and the next push sends the merge.
#[test]
fn edits_to_different_lines_of_a_text_file_merge_cleanly() {
    let setup = setup("merge");
    std::fs::write(setup.folder.join("a.txt"), "1\n2\n3\n4\n5\n6\n7\n").unwrap();
    synced(&setup, "push");
    std::fs::write(setup.folder.join("a.txt"), "one here\n2\n3\n4\n5\n6\n7\n").unwrap();
    std::fs::write(setup.remote.join("a.txt"), "1\n2\n3\n4\n5\n6\nseven there\n").unwrap();

    let pulled = synced(&setup, "pull");
    assert_eq!(pulled["written"].as_u64(), Some(1), "{pulled}");
    let merged = "one here\n2\n3\n4\n5\n6\nseven there\n";
    assert_eq!(std::fs::read_to_string(setup.folder.join("a.txt")).unwrap(), merged);
    assert!(!setup.folder.join("a.txt.cmux-sync-conflict").exists());

    // The merge reaches the machine with the next push, and then both agree.
    let pushed = synced(&setup, "push");
    assert_eq!(pushed["written"].as_u64(), Some(1), "{pushed}");
    assert_eq!(std::fs::read_to_string(setup.remote.join("a.txt")).unwrap(), merged);
    let again = synced(&setup, "pull");
    assert_eq!(again["written"].as_u64(), Some(0), "{again}");
}

/// Both sides changed the same line: a conflict. This Mac's file stays
/// byte for byte, nothing else comes back either, and the merge with
/// conflict markers is beside it, never sent by a push.
#[test]
fn overlapping_edits_conflict_without_touching_this_macs_file() {
    let setup = setup("clash");
    std::fs::write(setup.folder.join("a.txt"), "1\n2\n3\n").unwrap();
    std::fs::write(setup.folder.join("b.txt"), "b\n").unwrap();
    synced(&setup, "push");
    std::fs::write(setup.folder.join("a.txt"), "1\ntwo here\n3\n").unwrap();
    std::fs::write(setup.remote.join("a.txt"), "1\ntwo there\n3\n").unwrap();
    std::fs::write(setup.remote.join("b.txt"), "b from the machine\n").unwrap();
    let here = tree(&setup.folder);

    let socket = setup.socket.to_str().unwrap();
    let (folder, remote) = (setup.folder.to_str().unwrap(), setup.remote.to_str().unwrap());
    let (ok, answer) = cmux(&setup, &["pull", "--socket", socket, folder, remote]);
    assert!(!ok, "{answer}");
    assert_eq!(answer["error_code"], "sync_conflict", "{answer}");
    assert_eq!(answer["conflicts"], json!(["a.txt"]), "{answer}");
    assert_eq!(answer["merge_files"], json!(["a.txt.cmux-sync-conflict"]), "{answer}");

    let side = std::fs::read_to_string(setup.folder.join("a.txt.cmux-sync-conflict")).unwrap();
    assert!(side.contains("<<<<<<<") && side.contains(">>>>>>>"), "{side}");
    assert!(side.contains("two here") && side.contains("two there"), "{side}");
    let mut after = tree(&setup.folder);
    after.retain(|(path, _, _)| path != "a.txt.cmux-sync-conflict");
    assert_eq!(after, here, "a conflicting pull changed this Mac's files");

    let pushed = synced(&setup, "push");
    assert!(!setup.remote.join("a.txt.cmux-sync-conflict").exists(), "{pushed}");
}

/// A symlink by a conflict merge's name is never replaced by the merge (it
/// goes to the next name), and never pushed.
#[test]
fn a_symlink_by_the_merge_files_name_is_left_alone() {
    let setup = setup("clash-link");
    std::fs::write(setup.folder.join("a.txt"), "1\n2\n3\n").unwrap();
    synced(&setup, "push");
    std::os::unix::fs::symlink("a.txt", setup.folder.join("a.txt.cmux-sync-conflict")).unwrap();
    std::fs::write(setup.folder.join("a.txt"), "1\ntwo here\n3\n").unwrap();
    std::fs::write(setup.remote.join("a.txt"), "1\ntwo there\n3\n").unwrap();

    let socket = setup.socket.to_str().unwrap();
    let (folder, remote) = (setup.folder.to_str().unwrap(), setup.remote.to_str().unwrap());
    let (ok, answer) = cmux(&setup, &["pull", "--socket", socket, folder, remote]);
    assert!(!ok, "{answer}");
    assert_eq!(answer["conflicts"], json!(["a.txt"]), "{answer}");
    assert_eq!(answer["merge_files"], json!(["a.txt.2.cmux-sync-conflict"]), "{answer}");
    let side = setup.folder.join("a.txt.cmux-sync-conflict");
    assert!(std::fs::symlink_metadata(&side).unwrap().file_type().is_symlink());
    assert_eq!(std::fs::read_link(&side).unwrap(), Path::new("a.txt"));
    assert_eq!(std::fs::read_to_string(setup.folder.join("a.txt")).unwrap(), "1\ntwo here\n3\n");

    synced(&setup, "push");
    assert!(std::fs::symlink_metadata(setup.remote.join("a.txt.cmux-sync-conflict")).is_err());
}

/// A file already at the conflict merge's name (the user's own, or a merge
/// they edited) is kept byte for byte: the merge goes to the next name, and
/// the same conflict pulled again reuses that file instead of adding more.
#[test]
fn a_file_by_the_merge_files_name_is_never_overwritten() {
    let setup = setup("clash-file");
    std::fs::write(setup.folder.join("a.txt"), "1\n2\n3\n").unwrap();
    synced(&setup, "push");
    std::fs::write(setup.folder.join("a.txt.cmux-sync-conflict"), "my notes\n").unwrap();
    // Nor a file by the old fixed temporary name.
    std::fs::write(setup.folder.join(".a.txt.2.cmux-sync-conflict.cmux-sync-part"), "mine\n")
        .unwrap();
    std::fs::write(setup.folder.join("a.txt"), "1\ntwo here\n3\n").unwrap();
    std::fs::write(setup.remote.join("a.txt"), "1\ntwo there\n3\n").unwrap();

    let socket = setup.socket.to_str().unwrap();
    let (folder, remote) = (setup.folder.to_str().unwrap(), setup.remote.to_str().unwrap());
    for _ in 0..2 {
        let (ok, answer) = cmux(&setup, &["pull", "--socket", socket, folder, remote]);
        assert!(!ok, "{answer}");
        assert_eq!(answer["merge_files"], json!(["a.txt.2.cmux-sync-conflict"]), "{answer}");
    }
    assert_eq!(
        std::fs::read_to_string(setup.folder.join("a.txt.cmux-sync-conflict")).unwrap(),
        "my notes\n"
    );
    let side = std::fs::read_to_string(setup.folder.join("a.txt.2.cmux-sync-conflict")).unwrap();
    assert!(side.contains("two here") && side.contains("two there"), "{side}");
    assert!(!setup.folder.join("a.txt.3.cmux-sync-conflict").exists());
    assert_eq!(
        std::fs::read_to_string(setup.folder.join(".a.txt.2.cmux-sync-conflict.cmux-sync-part"))
            .unwrap(),
        "mine\n"
    );
    assert_eq!(std::fs::read_to_string(setup.folder.join("a.txt")).unwrap(), "1\ntwo here\n3\n");
}

/// A conflict merge is readable by its owner only, whatever the umask.
#[test]
fn a_conflict_merge_is_owner_only() {
    use std::os::unix::fs::PermissionsExt as _;
    let setup = setup("clash-private");
    std::fs::write(setup.folder.join("a.txt"), "1\n2\n3\n").unwrap();
    synced(&setup, "push");
    std::fs::write(setup.folder.join("a.txt"), "1\ntwo here\n3\n").unwrap();
    std::fs::write(setup.remote.join("a.txt"), "1\ntwo there\n3\n").unwrap();
    let socket = setup.socket.to_str().unwrap();
    let (folder, remote) = (setup.folder.to_str().unwrap(), setup.remote.to_str().unwrap());
    let (ok, answer) = cmux(&setup, &["pull", "--socket", socket, folder, remote]);
    assert!(!ok, "{answer}");
    let mode = std::fs::metadata(setup.folder.join("a.txt.cmux-sync-conflict"))
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600, "{mode:o}");
}

/// A folder whose name ends like a conflict merge is an ordinary folder:
/// pushed, and kept by the next pull.
#[test]
fn a_folder_by_a_conflict_name_round_trips() {
    let setup = setup("clash-dir");
    std::fs::create_dir(setup.folder.join("archive.cmux-sync-conflict")).unwrap();
    std::fs::write(setup.folder.join("archive.cmux-sync-conflict/keep.txt"), "keep\n").unwrap();
    synced(&setup, "push");
    assert_eq!(
        std::fs::read_to_string(setup.remote.join("archive.cmux-sync-conflict/keep.txt")).unwrap(),
        "keep\n"
    );
    synced(&setup, "pull");
    assert_eq!(
        std::fs::read_to_string(setup.folder.join("archive.cmux-sync-conflict/keep.txt")).unwrap(),
        "keep\n"
    );
}

/// A binary file both sides changed stays a whole-file conflict, with no
/// merge file.
#[test]
fn a_binary_file_changed_on_both_sides_stays_a_whole_file_conflict() {
    let setup = setup("bin");
    std::fs::write(setup.folder.join("data.bin"), b"\0\x01\n\x02\n").unwrap();
    synced(&setup, "push");
    std::fs::write(setup.folder.join("data.bin"), b"\0\x01\nhere\n").unwrap();
    std::fs::write(setup.remote.join("data.bin"), b"\0there\n\x02\n").unwrap();

    let socket = setup.socket.to_str().unwrap();
    let (folder, remote) = (setup.folder.to_str().unwrap(), setup.remote.to_str().unwrap());
    let (ok, answer) = cmux(&setup, &["pull", "--socket", socket, folder, remote]);
    assert!(!ok, "{answer}");
    assert_eq!(answer["conflicts"], json!(["data.bin"]), "{answer}");
    assert_eq!(answer["merge_files"], json!([]), "{answer}");
    assert_eq!(std::fs::read(setup.folder.join("data.bin")).unwrap(), b"\0\x01\nhere\n");
}
