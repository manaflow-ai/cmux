use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::os::unix::fs::FileExt as _;
use std::os::unix::net::UnixListener;
use std::process::Command;

use super::*;

#[test]
fn the_manifest_holds_what_a_copy_sends_and_never_a_secret() {
    let folder = tempfile::tempdir().unwrap();
    let root = folder.path();
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::write(root.join("src/main.rs"), "fn main() {}\n").unwrap();
    std::fs::write(root.join("README.md"), "# hi\n").unwrap();
    std::fs::write(root.join(".env"), "TOKEN=secret\n").unwrap();
    std::fs::create_dir_all(root.join("node_modules/x")).unwrap();
    std::fs::write(root.join("node_modules/x/index.js"), "x\n").unwrap();

    let listed = list(&std::fs::canonicalize(root).unwrap()).unwrap();
    let manifest = &listed.manifest;
    let main = manifest.resolve("src/main.rs").expect("src/main.rs is in the manifest");
    assert_eq!(manifest.entry(main).unwrap().size, 13);
    assert!(manifest.resolve("README.md").is_some());
    assert_eq!(manifest.resolve(".env"), None, "a secret never reaches the manifest");
    assert_eq!(manifest.resolve("node_modules"), None, "a heavy folder stays here");

    // Reads are answered from the file the manifest named; an edit since is re-listed: its stat
    // now and its new bytes (RFD 0007, hard case 7).
    assert_eq!(Source::whole(&listed, main), Part::ok(b"fn main() {}\n".to_vec()));
    assert_eq!(Source::read(&listed, main, 3, 4), Part::ok(b"main".to_vec()));
    std::fs::write(root.join("src/main.rs"), "fn main() { edited(); }\n").unwrap();
    let whole = Source::whole(&listed, main);
    let (stat, bytes) = whole.restat().expect("an edit since the manifest is re-listed");
    assert_eq!((stat.size, bytes), (24, &b"fn main() { edited(); }\n"[..]));
    // Anything that is not a file of the manifest is refused.
    assert_eq!(Source::whole(&listed, 0).status, wire::REFUSED);
    assert_eq!(Source::whole(&listed, 9999).status, wire::REFUSED);
}

#[test]
fn the_sent_line_counts_only_the_file_bytes_answered() {
    let folder = tempfile::tempdir().unwrap();
    let root = folder.path();
    std::fs::write(root.join("a.txt"), "0123456789").unwrap();
    let listed = list(&std::fs::canonicalize(root).unwrap()).unwrap();
    let entry = listed.manifest.resolve("a.txt").unwrap();
    let sent = Sent::default();
    let counted = Counted { source: &listed, sent: &sent };
    assert_eq!(Source::whole(&counted, entry), Part::ok(b"0123456789".to_vec()));
    assert_eq!(Source::read(&counted, entry, 2, 3), Part::ok(b"234".to_vec()));
    // A refusal is no bytes moved.
    assert_eq!(Source::whole(&counted, 9999).status, wire::REFUSED);
    assert_eq!(sent.line(), json!({"reads": 2, "bytes": 13}));
}

#[test]
fn each_chat_folder_has_its_own_projection_name() {
    assert_eq!(name_of("/home/cmux/work/a"), name_of("/home/cmux/work/a"));
    assert_ne!(name_of("/home/cmux/work/a"), name_of("/home/cmux/work/b"));
    assert!(name_of("/x").bytes().all(|byte| byte.is_ascii_alphanumeric()));
}

#[test]
fn each_chat_has_its_own_projection_and_its_name_is_one_the_machine_takes() {
    let one = chat_name("0c6f2c1e-6a4e-4d8e-9a59-1f7d3c2b9e10");
    let two = chat_name("5b0a9d7e-2f43-4c1b-8e6d-3a9c7f1e2d40");
    assert_ne!(one, two);
    assert_eq!(one, chat_name("0c6f2c1e-6a4e-4d8e-9a59-1f7d3c2b9e10"));
    // The daemon's rule (cmux-tui-core projection.rs): 1-64 letters, digits, - or _.
    assert!(one.len() <= 64);
    assert!(one.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte)));
}

/// A file rewritten by rename after the manifest (git writes its index so: a new inode at the
/// same path) is re-listed, not refused, and read at its new version; it keeps being answered
/// with its stat now, so a machine that lost an answer gets it again.
#[test]
fn a_file_replaced_by_rename_after_the_manifest_is_re_listed_and_read() {
    let folder = tempfile::tempdir().unwrap();
    let root = folder.path();
    std::fs::write(root.join("index"), "version one").unwrap();
    let listed = list(&std::fs::canonicalize(root).unwrap()).unwrap();
    let entry = listed.manifest.resolve("index").unwrap();
    assert_eq!(Source::read(&listed, entry, 0, 64), Part::ok(b"version one".to_vec()));

    std::fs::write(root.join("index.lock"), "v2").unwrap();
    std::fs::rename(root.join("index.lock"), root.join("index")).unwrap();
    for _ in 0..2 {
        let part = Source::read(&listed, entry, 0, 64);
        let (stat, bytes) = part.restat().expect("re-listed");
        assert_eq!((stat.size, bytes), (2, &b"v2"[..]));
        assert_eq!(stat.mode, 0o644);
    }
    let whole = Source::whole(&listed, entry);
    assert_eq!(whole.restat().map(|(_, bytes)| bytes.to_vec()), Some(b"v2".to_vec()));
    // A symlink put at its path is never read through.
    std::fs::remove_file(root.join("index")).unwrap();
    std::os::unix::fs::symlink("/etc/hostname", root.join("index")).unwrap();
    assert_eq!(Source::read(&listed, entry, 0, 64).status, wire::FAILED);
}

#[test]
fn a_removed_source_is_reported_and_never_falls_back_to_bytes() {
    let folder = tempfile::tempdir().unwrap();
    let root = folder.path();
    std::fs::write(root.join("gone.txt"), "before").unwrap();
    let listed = list(&std::fs::canonicalize(root).unwrap()).unwrap();
    let entry = listed.manifest.resolve("gone.txt").unwrap();
    std::fs::remove_file(root.join("gone.txt")).unwrap();
    assert_eq!(Source::read(&listed, entry, 0, 16).status, wire::FAILED);
}

#[test]
fn a_huge_single_file_uses_ranged_reads_instead_of_whole() {
    let folder = tempfile::tempdir().unwrap();
    let root = folder.path();
    let path = root.join("huge.bin");
    let file = std::fs::File::create(&path).unwrap();
    let size: u64 = 64 * 1024 * 1024 * 1024 + 17;
    file.set_len(size).unwrap();
    let offset = u64::from(u32::MAX) + 4096;
    let sentinel = b"past u32 range";
    file.write_at(sentinel, offset).unwrap();
    drop(file);

    let listed = list(&std::fs::canonicalize(root).unwrap()).unwrap();
    let entry = listed.manifest.resolve("huge.bin").unwrap();
    assert_eq!(listed.manifest.entry(entry).unwrap().size, size);
    assert_eq!(
        Source::read(&listed, entry, offset, sentinel.len() as u32),
        Part::ok(sentinel.to_vec())
    );
    assert_eq!(Source::read(&listed, entry, size - 2, 64), Part::ok(vec![0, 0]));
    assert_eq!(Source::read(&listed, entry, size, 1), Part::ok(Vec::new()));
    assert_eq!(Source::whole(&listed, entry).status, wire::FAILED);
}

#[test]
fn line_carrier_preserves_manifest_bytes_including_newlines_and_nuls() {
    let bytes = b"before\n\0middle\r\nafter\0\n";
    let mut framed = Vec::new();
    cmux_tui_core::projection::LineWriter::new(&mut framed).write_all(bytes).unwrap();
    assert!(framed.starts_with(b"~"));
    assert!(framed.ends_with(b"\n"));

    let mut decoded = Vec::new();
    cmux_tui_core::projection::LineReader::new(BufReader::new(std::io::Cursor::new(framed)))
        .read_to_end(&mut decoded)
        .unwrap();
    assert_eq!(decoded, bytes);
}

#[test]
fn dial_uses_the_line_carrier_for_manifest_bytes() {
    let folder = tempfile::tempdir().unwrap();
    let socket = folder.path().join("carrier.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let manifest = b"manifest\nwith\0bytes\n".to_vec();
    let expected = manifest.clone();
    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut first = String::new();
        reader.read_line(&mut first).unwrap();
        let first: Value = serde_json::from_str(first.trim()).unwrap();
        assert_eq!(first["lines"], true);
        assert_eq!(first["manifest_bytes"], expected.len());

        let mut decoded = vec![0; expected.len()];
        cmux_tui_core::projection::LineReader::new(&mut reader).read_exact(&mut decoded).unwrap();
        assert_eq!(decoded, expected);

        let mut writer = stream;
        writer.write_all(b"{\"id\":1,\"ok\":true,\"data\":{}}\n").unwrap();
        writer.flush().unwrap();
    });

    let (reader, answer) = dial(&socket, "chat-test", "/workspace", &manifest, None).unwrap();
    assert!(ok(&answer));
    drop(reader);
    server.join().unwrap();
}

#[test]
fn env_zero_disables_projection_without_mutating_machine_state() {
    const CHILD: &str = "CMUX_PROJECTED_FOLDERS_TEST_CHILD";
    if std::env::var_os(CHILD).is_some() {
        assert!(!enabled());
        return;
    }

    let status = Command::new(std::env::current_exe().unwrap())
        .arg("env_zero_disables_projection_without_mutating_machine_state")
        .env(ENV, "0")
        .env(CHILD, "1")
        .status()
        .unwrap();
    assert!(status.success());
}

#[test]
fn each_move_has_its_own_projection_and_its_name_is_one_the_machine_takes() {
    let one = chat_name(&move_key("/home/cmux/work/api"));
    std::thread::sleep(Duration::from_millis(1));
    // A later move of the same folder never mounts an earlier move's edits.
    assert_ne!(one, chat_name(&move_key("/home/cmux/work/api")));
    assert!(one.starts_with(&chat_name(&format!("move-{}", name_of("/home/cmux/work/api")))));
    // The daemon's rule (cmux-tui-core projection.rs): 1-64 letters, digits, - or _.
    assert!(one.len() <= 64);
    assert!(one.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte)));
}

#[test]
fn what_a_server_serves_reads_back_as_written() {
    let served = ServerRecord {
        machine: "m-7f3a".into(),
        chat: "move-p0123456789abcdef-1".into(),
        local: PathBuf::from("/Users/leo/Projects/with\nnewline"),
    };
    assert_eq!(ServerRecord::decode(&served.encode()), Some(served.clone()));
    assert_eq!(ServerRecord::decode(b"no separator"), None);
    assert_eq!(ServerRecord::decode(b"m\0\0/no/chat"), None);
    // A machine that answers no id is recorded as none, and matches only itself.
    let unnamed = ServerRecord { machine: String::new(), ..served };
    assert_eq!(ServerRecord::decode(&unnamed.encode()), Some(unnamed));
}

fn git_in(dir: &Path, args: &[&str]) {
    let status = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(args)
        .status()
        .unwrap();
    assert!(status.success(), "git {args:?}");
}

#[test]
fn carry_lists_worktrees_and_submodules_without_packing_subfolders() {
    let folder = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(folder.path()).unwrap();
    let repo = root.join("repo");
    std::fs::create_dir_all(repo.join("src")).unwrap();
    std::fs::write(repo.join("src/main.rs"), "fn main() {}\n").unwrap();
    git_in(&repo, &["init", "-q"]);
    git_in(&repo, &["add", "."]);
    git_in(&repo, &["commit", "-qm", "init"]);

    // A supported root still publishes its carried pack.
    let carry = projection_carry(&repo).expect("ordinary repository carries by default");
    let listed = list_with_carry(&repo, Some(&carry)).unwrap();
    assert!(listed.manifest.resolve(".git/cmux-carry.pack").is_some());
    drop(carry);

    let worktree = root.join("worktree");
    git_in(&repo, &["worktree", "add", "--detach", worktree.to_str().unwrap()]);
    git_in(
        &repo,
        &["-c", "protocol.file.allow=always", "submodule", "add", repo.to_str().unwrap(), "module"],
    );
    for at in [worktree, repo.join("module")] {
        assert!(at.join(".git").is_file());
        let carry = projection_carry(&at).expect("linked repositories carry by default");
        let listed = list_with_carry(&at, Some(&carry)).unwrap();
        assert!(listed.manifest.resolve(".git/cmux-carry.pack").is_some());
        assert!(listed.manifest.resolve(".git/cmux-carry.base").is_some());
        // The listing expands the gitfile into a standalone repository before carry
        // adds its entries, so those entries never appear beneath a manifest file.
        let git = listed.manifest.resolve(".git").unwrap();
        assert_eq!(listed.manifest.entry(git).unwrap().kind, Kind::Dir);
    }
    let subfolder = repo.join("src");
    assert!(projection_carry(&subfolder).is_none());
    assert!(list(&subfolder).is_err(), "preserve the listing's existing root-only contract");
}

#[test]
fn carry_skips_bare_repositories_without_a_worktree_git_directory() {
    let folder = tempfile::tempdir().unwrap();
    let bare = folder.path().join("bare");
    git_in(&folder.path(), &["init", "--bare", bare.to_str().unwrap()]);

    // A bare repository resolves HEAD for Git, but the projection listing treats it as a plain
    // folder. Carry must follow that same classification and never add a synthetic `.git` path.
    assert!(projection_carry(&bare).is_none());

    let carry_root = tempfile::tempdir().unwrap();
    let base_path = carry_root.path().join("carry.base");
    let pack_path = carry_root.path().join("carry.pack");
    std::fs::write(&base_path, "0".repeat(40)).unwrap();
    std::fs::write(&pack_path, b"pack").unwrap();
    let carry = CarryFiles { base_path, pack_path, folder: carry_root.path().to_path_buf() };
    let listed = list_with_carry(&bare, Some(&carry)).unwrap();
    assert!(listed.manifest.resolve(".git/cmux-carry.base").is_none());
    assert!(listed.manifest.resolve(".git/cmux-carry.pack").is_none());
}

/// RFD 0007, "Tracked files the skip rules keep home": in a folder of repositories, a secret a
/// repository tracks is listed with its real stat and why, and its bytes are refused; an untracked
/// secret is still not listed at all.
#[test]
fn a_tracked_secret_below_a_folder_of_repos_is_listed_with_its_stat_and_never_served() {
    let folder = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(folder.path()).unwrap();
    let repo = root.join("kubernetes");
    std::fs::create_dir_all(repo.join("test/fixtures")).unwrap();
    std::fs::create_dir_all(repo.join("web/node_modules/x")).unwrap();
    std::fs::write(repo.join("web/package.json"), "{}\n").unwrap();
    std::fs::write(repo.join("main.go"), "package main\n").unwrap();
    std::fs::write(repo.join("test/fixtures/server.key"), "PRIVATE KEY BYTES\n").unwrap();
    std::fs::write(repo.join("web/node_modules/x/index.js"), "x\n").unwrap();
    git_in(&repo, &["init", "-q"]);
    git_in(&repo, &["add", "-f", "."]);
    git_in(&repo, &["commit", "-qm", "init"]);
    std::fs::write(repo.join("untracked.pem"), "OTHER KEY\n").unwrap();

    let listed = list(&root).unwrap();
    let manifest = &listed.manifest;
    let key = manifest.resolve("kubernetes/test/fixtures/server.key").expect("the key is listed");
    let meta = std::fs::metadata(repo.join("test/fixtures/server.key")).unwrap();
    let entry = manifest.entry(key).unwrap();
    assert_eq!(entry.size, meta.len());
    assert_eq!(entry.mtime_ns, mtime_ns(&meta));
    assert_eq!(entry.mode, 0o644);
    assert_eq!(manifest.kept(key), Some("secret: key files are shared only on purpose"));
    let heavy = manifest.resolve("kubernetes/web/node_modules/x/index.js").unwrap();
    assert_eq!(manifest.kept(heavy), Some("a heavy folder rebuilt on the machine"));
    assert_eq!(manifest.kept_count(), 2);
    assert_eq!(manifest.resolve("kubernetes/untracked.pem"), None);
    let main = manifest.resolve("kubernetes/main.go").unwrap();
    assert_eq!(manifest.kept(main), None);

    // No byte of it is served, whole or by range.
    assert_eq!(Source::whole(&listed, key), Part::status(wire::REFUSED));
    assert_eq!(Source::read(&listed, key, 0, 4096), Part::status(wire::REFUSED));
    assert_eq!(Source::whole(&listed, main), Part::ok(b"package main\n".to_vec()));
    // And the wire carries the mark.
    let decoded = Manifest::decode(&manifest.encode().unwrap()).unwrap();
    assert_eq!(decoded.kept(key), manifest.kept(key));
}

/// A repository folder itself lists every tracked file with its bytes (tracked secrets were
/// committed on purpose): nothing is kept.
#[test]
fn a_repository_folder_keeps_nothing_home() {
    let folder = tempfile::tempdir().unwrap();
    let repo = std::fs::canonicalize(folder.path()).unwrap();
    std::fs::write(repo.join("server.key"), "TEST KEY\n").unwrap();
    git_in(&repo, &["init", "-q"]);
    git_in(&repo, &["add", "-f", "."]);
    git_in(&repo, &["commit", "-qm", "init"]);
    let listed = list(&repo).unwrap();
    let key = listed.manifest.resolve("server.key").unwrap();
    assert_eq!(listed.manifest.kept(key), None);
    assert_eq!(listed.manifest.kept_count(), 0);
}

/// A stand-in machine socket at `path`: each dial's ask is counted, then answered `ok`.
fn answering(path: &Path) -> Arc<std::sync::atomic::AtomicUsize> {
    use std::sync::atomic::Ordering;
    let listener = std::os::unix::net::UnixListener::bind(path).unwrap();
    let dials = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counted = dials.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap_or(0) == 0 {
                continue;
            }
            counted.fetch_add(1, Ordering::SeqCst);
            let _ = reader.get_mut().write_all(b"{\"ok\":true,\"data\":{}}\n");
        }
    });
    dials
}

#[test]
fn a_redial_prefers_the_quiet_socket_and_falls_back_when_there_is_none() {
    use std::sync::atomic::Ordering;
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("carrier.sock");
    let main = answering(&socket);

    // No quiet socket (an older carrier serve, or a daemon's own socket): the main one.
    assert_eq!(quiet_socket(&socket), None);
    let (dialed, quiet) = redial(&socket, "p1", "/w", &[], None);
    assert!(ok(&dialed.unwrap().1));
    assert!(!quiet, "no quiet socket: the main one, as before");
    assert_eq!(main.load(Ordering::SeqCst), 1);

    // A file at the quiet path that is not a socket is no quiet socket.
    let quiet_path = dir.path().join("carrier.sock.quiet");
    std::fs::write(&quiet_path, "").unwrap();
    assert_eq!(quiet_socket(&socket), None);
    let (dialed, quiet) = redial(&socket, "p1", "/w", &[], None);
    assert!(ok(&dialed.unwrap().1) && !quiet);
    assert_eq!(main.load(Ordering::SeqCst), 2);
    std::fs::remove_file(&quiet_path).unwrap();

    // A stale quiet socket (nothing accepts on it): the main one.
    drop(std::os::unix::net::UnixListener::bind(&quiet_path).unwrap());
    assert_eq!(quiet_socket(&socket), Some(quiet_path.clone()));
    let (dialed, quiet) = redial(&socket, "p1", "/w", &[], None);
    assert!(ok(&dialed.unwrap().1) && !quiet);
    assert_eq!(main.load(Ordering::SeqCst), 3);
    std::fs::remove_file(&quiet_path).unwrap();

    // A live quiet socket: every redial goes there and none to the main one.
    let hushed = answering(&quiet_path);
    for n in 1..=2 {
        let (dialed, quiet) = redial(&socket, "p1", "/w", &[], None);
        assert!(ok(&dialed.unwrap().1));
        assert!(quiet, "the quiet socket is preferred");
        assert_eq!(hushed.load(Ordering::SeqCst), n);
    }
    assert_eq!(main.load(Ordering::SeqCst), 3, "no redial reached the main socket");
}

#[test]
fn a_quiet_refusal_is_a_failed_dial_and_the_redial_waits_half_a_second_flat() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("carrier.sock");
    let quiet_path = dir.path().join("carrier.sock.quiet");
    let quiet = std::os::unix::net::UnixListener::bind(&quiet_path).unwrap();
    // The quiet socket closes the dial unanswered, as carrier serve does while the machine sleeps.
    std::thread::spawn(move || {
        for stream in quiet.incoming() {
            drop(stream);
        }
    });
    let (dialed, went_quiet) = redial(&socket, "p1", "/w", &[], None);
    assert!(went_quiet);
    let error = format!("{:#}", dialed.expect_err("an unanswered dial fails"));
    assert!(error.contains("without answering"), "{error}");

    let mut backoff = Duration::from_millis(200);
    for _ in 0..10 {
        assert_eq!(retry_wait(true, &mut backoff), QUIET_RETRY);
    }
    assert_eq!(QUIET_RETRY, Duration::from_millis(500));
    let waits: Vec<_> = (0..8).map(|_| retry_wait(false, &mut backoff).as_millis()).collect();
    assert_eq!(
        waits,
        [200, 400, 800, 1600, 3200, 6400, 10_000, 10_000],
        "the main socket backs off"
    );
}

#[test]
fn the_ready_line_splits_the_gate_into_listing_encoding_and_mount() {
    let timing = ready_timing(21_592, 900, 950, 2_000_000, 2_100, Some(400));
    assert_eq!(timing["entries"], 21_592);
    assert_eq!(timing["listed_ms"], 900);
    assert_eq!(timing["encoded_ms"], 950);
    assert_eq!(timing["manifest_bytes"], 2_000_000);
    assert_eq!(timing["ready_ms"], 2_100);
    assert_eq!(timing["mount_ms"], 400);
    // An older machine's answer has no mount time.
    assert!(ready_timing(2, 1, 1, 10, 5, None)["mount_ms"].is_null());
    // One line in the log, for the start matrix to read back.
    assert!(!timing.to_string().contains('\n'));
}

/// Leo, 2026-11-25: a Cloud chat started on an empty folder must still be that folder, projected,
/// so what the agent writes comes back to it. An empty or non-git folder lists to a manifest the
/// machine mounts (never zero bytes, which the machine reads as a resume of a mount it has).
#[test]
fn an_empty_or_non_git_folder_is_projected_not_skipped() {
    let empty = tempfile::tempdir().unwrap();
    let listed = list(&std::fs::canonicalize(empty.path()).unwrap()).unwrap();
    assert!(listed.served.iter().all(Option::is_none), "no file to serve");
    assert_eq!(listed.manifest.len(), 1, "the folder itself and nothing in it");
    let encoded = listed.manifest.encode().unwrap();
    assert!(!encoded.is_empty(), "zero manifest bytes would ask the machine for a resume");
    let decoded = Manifest::decode(&encoded).unwrap();
    assert_eq!(decoded.len(), 1);

    let plain = tempfile::tempdir().unwrap();
    std::fs::write(plain.path().join("notes.txt"), "hi\n").unwrap();
    assert!(!plain.path().join(".git").exists());
    let listed = list(&std::fs::canonicalize(plain.path()).unwrap()).unwrap();
    assert!(listed.manifest.resolve("notes.txt").is_some());
    assert!(!listed.manifest.encode().unwrap().is_empty());
}
