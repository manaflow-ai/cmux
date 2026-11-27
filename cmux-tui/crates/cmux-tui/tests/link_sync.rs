//! `cmux link sync push`: a working copy reaches a Cloud machine's home
//! through the machine daemon's `fs-v1` ops, with its git state intact
//! (Move to Cloud, slice 2). The daemon side is the real `FsService`
//! behind a socket that answers lines the way the daemon's `fs_wire` does.
#![cfg(unix)]

use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_tui_core::fs_ops::{FsService, Roots, stream};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

/// Serves `fs.*` lines on `socket` with the real owner over `home`, one
/// thread per connection, until the test process ends.
fn serve_fs(socket: &Path, home: &Path) -> &'static Mutex<Vec<Planted>> {
    serve_hostile_fs(socket, home, &[])
}

/// [`serve_fs`] whose `identify` lists `capabilities`, as a Cloud daemon's
/// does (`cmux_tui_core::fs_ops::advertised`). Its listings stand in for
/// one read before the machine made its symlinks: a link to a folder is
/// listed as that folder, and any other link is left out.
fn serve_fs_advertising(socket: &Path, home: &Path, capabilities: &'static [&'static str]) {
    serve_hostile_fs(socket, home, capabilities);
}

/// A file a malicious machine plants in a listing: the folder's path as the
/// client asks for it, the name it lists (any text) and the bytes it serves
/// for `folder/name`.
type Planted = (String, String, Vec<u8>);

/// [`serve_fs`] that can turn malicious: the listings of the folders in the
/// returned list also name its files, and `fs.stat` and `fs.read` of their
/// paths answer with their bytes.
fn serve_hostile_fs(
    socket: &Path,
    home: &Path,
    capabilities: &'static [&'static str],
) -> &'static Mutex<Vec<Planted>> {
    let listener = UnixListener::bind(socket).unwrap();
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.to_path_buf()]))));
    let planted: &'static Mutex<Vec<Planted>> = Box::leak(Box::default());
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
                    let path = request["path"].as_str().unwrap_or_default().to_string();
                    let planted = planted.lock().unwrap().clone();
                    let advertised = (cmd == "identify" && !capabilities.is_empty())
                        .then(|| json!({ "capabilities": capabilities }));
                    let reply = match advertised.or_else(|| hostile_answer(&planted, &cmd, &path)) {
                        Some(data) => json!({"id": id, "ok": true, "data": data}),
                        None => {
                            let mut reply =
                                stream::answer(&id, service.call("local", &cmd, request));
                            if cmd == "fs.list" {
                                plant_entries(&planted, &path, &mut reply);
                                if !capabilities.is_empty()
                                    && let Some(entries) = reply["data"]["entries"].as_array_mut()
                                {
                                    entries.retain(|entry| {
                                        entry["kind"] != "symlink" || entry["target_kind"] == "dir"
                                    });
                                    for entry in entries.iter_mut() {
                                        if entry["kind"] == "symlink" {
                                            entry["kind"] = json!("dir");
                                        }
                                    }
                                }
                            }
                            reply
                        }
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
    planted
}

/// The answer for a planted file's `fs.stat` or `fs.read`.
fn hostile_answer(planted: &[Planted], cmd: &str, path: &str) -> Option<Value> {
    let (_, _, bytes) =
        planted.iter().find(|(folder, name, _)| format!("{folder}/{name}") == path)?;
    let revision = cmux_tui_core::fs_ops::revision(bytes.len() as u64, Some(1));
    match cmd {
        "fs.stat" => Some(json!({"kind": "file", "size": bytes.len(), "revision": revision,
                                 "mode_display": "rwxr-xr-x"})),
        "fs.read" => Some(json!({"bytes_base64": STANDARD.encode(bytes), "truncated": false,
                                 "revision": revision})),
        _ => None,
    }
}

/// Adds the planted files of the folder at `path` to its listing.
fn plant_entries(planted: &[Planted], path: &str, reply: &mut Value) {
    let Some(entries) = reply["data"]["entries"].as_array_mut() else { return };
    for (_, name, bytes) in planted.iter().filter(|(folder, _, _)| folder == path) {
        entries.push(json!({"name": name, "kind": "file", "size": bytes.len(), "mtime": 1}));
    }
}

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"])
        // No gc in the background: it would repack the objects mid-push.
        .args(["-c", "gc.auto=0", "-c", "maintenance.auto=false"])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        // Comparing never rewrites an index, so a second push sees no change.
        .env("GIT_OPTIONAL_LOCKS", "0")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap()
}

/// This Mac's state folder for a test: next to its socket.
fn state_of(socket: &Path) -> PathBuf {
    socket.parent().unwrap().join("state")
}

fn push(socket: &Path, local: &Path, remote: &Path) -> Value {
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("CMUX_TUI_STATE_DIR", state_of(socket))
        .args(["link", "sync", "push", "--socket"])
        .arg(socket)
        .arg(local)
        .arg(remote)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "sync push failed: {}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("one JSON summary on stdout")
}

/// A repo with every kind of state a working copy has: a branch other than
/// the default, a commit with a file over the 12 MiB single-write limit
/// and an executable script, staged, unstaged and untracked changes, an
/// ignored build output, a stash, a hook and a remote URL with a token.
fn dirty_repo(root: &Path) -> PathBuf {
    let repo = root.join("app");
    std::fs::create_dir_all(repo.join("src")).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    std::fs::write(repo.join("src/a.txt"), "one\n").unwrap();
    std::fs::write(repo.join(".gitignore"), "build/\n").unwrap();
    std::fs::write(repo.join("run.sh"), "#!/bin/sh\necho hi\n").unwrap();
    std::fs::set_permissions(repo.join("run.sh"), std::fs::Permissions::from_mode(0o755)).unwrap();
    let big: Vec<u8> =
        (0..13 * 1024 * 1024u32).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
    std::fs::write(repo.join("big.bin"), &big).unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    git(&repo, &["checkout", "-q", "-b", "feature/move"]);
    std::fs::write(repo.join("src/a.txt"), "one\nstashed\n").unwrap();
    git(&repo, &["stash", "push", "-q", "-m", "keep me"]);
    std::fs::write(repo.join("src/a.txt"), "one\nunstaged\n").unwrap();
    std::fs::write(repo.join("src/b.txt"), "staged\n").unwrap();
    git(&repo, &["add", "src/b.txt"]);
    std::fs::write(repo.join("c.txt"), "untracked\n").unwrap();
    std::fs::create_dir_all(repo.join("build")).unwrap();
    std::fs::write(repo.join("build/out.o"), "ignored\n").unwrap();
    std::fs::write(repo.join(".git/hooks/pre-commit"), "#!/bin/sh\nexit 1\n").unwrap();
    git(&repo, &["remote", "add", "origin", "https://user:ghp_secret123@example.com/app.git"]);
    repo
}

#[test]
fn a_dirty_repo_arrives_with_its_git_state_and_without_ignored_files_or_secrets() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let repo = dirty_repo(&root);
    let home = root.join("home");
    std::fs::create_dir_all(home.join("work")).unwrap();
    // A socket path must stay under SUN_LEN; the temp folder can be deep.
    let sockets = tempfile::Builder::new().prefix("cs").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("fs.sock");
    serve_fs(&socket, &home);
    let remote = home.join("work/app");

    let summary = push(&socket, &repo, &remote);
    assert!(summary["written"].as_u64().unwrap_or(0) > 0, "{summary}");

    let status = ["status", "--porcelain=v2", "--branch"];
    assert_eq!(git(&remote, &status), git(&repo, &status), "git status differs on the machine");
    assert_eq!(git(&remote, &["rev-parse", "HEAD"]), git(&repo, &["rev-parse", "HEAD"]));
    assert_eq!(git(&remote, &["stash", "list"]), git(&repo, &["stash", "list"]));
    assert_eq!(
        std::fs::read(remote.join("big.bin")).unwrap(),
        std::fs::read(repo.join("big.bin")).unwrap()
    );
    assert!(!remote.join("build").exists(), "an ignored folder was synced");
    assert!(!remote.join(".git/hooks/pre-commit").exists(), "a hook was synced");
    let config = std::fs::read_to_string(remote.join(".git/config")).unwrap();
    assert!(!config.contains("ghp_secret123"), "a remote URL kept its token: {config}");
    assert!(config.contains("https://example.com/app.git"), "{config}");

    // Nothing changed: the second push writes nothing. A local delete is
    // deleted on the machine too.
    let again = push(&socket, &repo, &remote);
    assert_eq!(again["written"].as_u64(), Some(0), "{again}");
    std::fs::remove_file(repo.join("c.txt")).unwrap();
    let after_delete = push(&socket, &repo, &remote);
    assert_eq!(after_delete["deleted"].as_u64(), Some(1), "{after_delete}");
    assert!(!remote.join("c.txt").exists());
    assert_eq!(git(&remote, &status), git(&repo, &status));
}

/// A working copy whose objects live in other repositories, the way
/// `git clone --shared` and worktree mirrors leave it: `app` borrows from
/// `mid`, which borrows from `base` (by a relative path), and only `app`'s
/// newest commit is its own. It arrives standing alone: every object goes,
/// the alternates file (paths of this Mac) does not, and git on the machine
/// finds the whole history with the borrowed repositories gone.
#[test]
fn a_repo_that_borrows_objects_arrives_standing_alone() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let base = dirty_repo(&root);
    git(&base, &["add", "-A"]);
    git(&base, &["commit", "-q", "-m", "second"]);
    git(&root, &["clone", "-q", "--shared", "app", "mid"]);
    let mid = root.join("mid");
    // `--shared` writes an absolute path; git also takes one relative to
    // the object folder holding the alternates file.
    std::fs::write(mid.join(".git/objects/info/alternates"), "../../../app/.git/objects\n")
        .unwrap();
    git(&mid, &["checkout", "-q", "-b", "work"]);
    std::fs::write(mid.join("mid.txt"), "mid\n").unwrap();
    git(&mid, &["add", "mid.txt"]);
    git(&mid, &["commit", "-q", "-m", "mid"]);
    git(&root, &["clone", "-q", "--shared", "--branch", "work", "mid", "copy"]);
    let repo = root.join("copy");
    std::fs::write(repo.join("own.txt"), "own\n").unwrap();
    git(&repo, &["add", "own.txt"]);
    git(&repo, &["commit", "-q", "-m", "own"]);
    std::fs::write(repo.join("own.txt"), "own\nunstaged\n").unwrap();
    assert!(repo.join(".git/objects/info/alternates").exists());

    let home = root.join("home");
    std::fs::create_dir_all(home.join("work")).unwrap();
    let sockets = tempfile::Builder::new().prefix("cs").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("fs.sock");
    serve_fs(&socket, &home);
    let remote = home.join("work/copy");

    let summary = push(&socket, &repo, &remote);
    assert!(summary["written"].as_u64().unwrap_or(0) > 0, "{summary}");
    assert!(
        !remote.join(".git/objects/info/alternates").exists(),
        "the alternates file (paths of this Mac) was synced"
    );
    let status = ["status", "--porcelain=v2", "--branch"];
    let head = git(&repo, &["rev-parse", "HEAD"]);
    let history = git(&repo, &["log", "--format=%H %s", "--all"]);
    let stash = git(&repo, &["stash", "list"]);
    let local_status = git(&repo, &status);

    // Nothing changed here: the second push writes nothing.
    let again = push(&socket, &repo, &remote);
    assert_eq!(again["written"].as_u64(), Some(0), "{again}");

    // The machine's copy needs nothing of this Mac's repositories.
    std::fs::remove_dir_all(&base).unwrap();
    std::fs::remove_dir_all(&mid).unwrap();
    git(&remote, &["fsck", "--full", "--no-dangling"]);
    assert_eq!(git(&remote, &["rev-parse", "HEAD"]), head);
    assert_eq!(git(&remote, &["log", "--format=%H %s", "--all"]), history);
    assert_eq!(git(&remote, &["stash", "list"]), stash);
    assert_eq!(git(&remote, &status), local_status);
    assert_eq!(
        git(&remote, &["cat-file", "-s", "HEAD~2:big.bin"]).trim(),
        (13 * 1024 * 1024).to_string(),
        "a blob only the farthest repository held is missing"
    );
}

/// Every file below `dir`, by path, with its bytes.
/// The regular files below `dir` with their bytes (symlinks are not
/// followed or listed).
fn files_below(dir: &Path) -> Vec<(PathBuf, Vec<u8>)> {
    let mut found = Vec::new();
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_symlink() {
            continue;
        }
        if path.is_dir() {
            found.extend(files_below(&path));
        } else {
            found.push((path.clone(), std::fs::read(&path).unwrap()));
        }
    }
    found
}

/// One raw `fs.write` line on `socket`, answered.
fn write_line(socket: &Path, request: Value) -> Value {
    let mut stream = std::os::unix::net::UnixStream::connect(socket).unwrap();
    stream.write_all(format!("{request}\n").as_bytes()).unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).unwrap();
    serde_json::from_str(&answer).unwrap()
}

#[test]
fn hooks_and_credentials_never_go_and_the_folder_can_change_shape() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let repo = root.join("app");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    std::fs::write(repo.join("shape"), "a file\n").unwrap();
    std::fs::write(repo.join("notes.txt"), "mine\n").unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    // A submodule's repository, a worktree config, settings and a reflog
    // line that carry credentials.
    let module = repo.join(".git/modules/sub");
    std::fs::create_dir_all(module.join("hooks")).unwrap();
    std::fs::write(module.join("hooks/post-checkout"), "#!/bin/sh\nexit 1\n").unwrap();
    std::fs::write(module.join("HEAD"), "ref: refs/heads/main\n").unwrap();
    std::fs::write(
        module.join("config"),
        "[remote \"origin\"]\n\turl = https://u:tok-secret-1@example.com/s.git\n[credential]\n\thelper = store\n",
    )
    .unwrap();
    std::fs::write(
        repo.join(".git/config.worktree"),
        "[http]\n\textraheader = AUTHORIZATION: bearer tok-secret-2\n",
    )
    .unwrap();
    let mut config = std::fs::read_to_string(repo.join(".git/config")).unwrap();
    config.push_str("[http] extraheader = AUTHORIZATION: tok-secret-3\n[sendemail]\n\tsmtpPass = tok-secret-4\n");
    config.push_str("[remote \"my.fork\"]\n\turl = https://x:tok-secret-5@example.com/f.git\n");
    std::fs::write(repo.join(".git/config"), config).unwrap();
    let mut reflog = std::fs::read_to_string(repo.join(".git/logs/HEAD")).unwrap();
    reflog.push_str("0000000000000000000000000000000000000000 0000000000000000000000000000000000000000 t <t@example.com> 0 +0000\tclone: from https://u:tok-secret-6@example.com/app.git\n");
    std::fs::write(repo.join(".git/logs/HEAD"), reflog).unwrap();

    let home = root.join("home");
    std::fs::create_dir_all(home.join("work")).unwrap();
    let sockets = tempfile::Builder::new().prefix("cs").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("fs.sock");
    serve_fs(&socket, &home);
    let remote = home.join("work/app");
    push(&socket, &repo, &remote);

    for (path, bytes) in files_below(&remote.join(".git")) {
        let text = String::from_utf8_lossy(&bytes);
        assert!(!text.contains("tok-secret"), "{} carries a credential: {text}", path.display());
        assert!(
            !path.components().any(|part| part.as_os_str() == "hooks"),
            "a hook was synced: {}",
            path.display()
        );
    }
    let config = std::fs::read_to_string(remote.join(".git/config")).unwrap();
    assert!(
        config.contains("[remote \"my.fork\"]") && config.contains("https://example.com/f.git"),
        "{config}"
    );
    assert_eq!(git(&remote, &["rev-parse", "HEAD"]), git(&repo, &["rev-parse", "HEAD"]));

    // A file becomes a folder, then a folder again becomes a file.
    std::fs::remove_file(repo.join("shape")).unwrap();
    std::fs::create_dir_all(repo.join("shape")).unwrap();
    std::fs::write(repo.join("shape/inner"), "inside\n").unwrap();
    push(&socket, &repo, &remote);
    assert_eq!(std::fs::read_to_string(remote.join("shape/inner")).unwrap(), "inside\n");
    std::fs::remove_dir_all(repo.join("shape")).unwrap();
    std::fs::write(repo.join("shape"), "a file again\n").unwrap();
    push(&socket, &repo, &remote);
    assert_eq!(std::fs::read_to_string(remote.join("shape")).unwrap(), "a file again\n");

    // What the machine made or changed itself is never deleted.
    std::fs::create_dir_all(remote.join("machine")).unwrap();
    std::fs::write(remote.join("machine/out.txt"), "made there\n").unwrap();
    std::fs::write(remote.join("notes.txt"), "changed there\n").unwrap();
    std::fs::remove_file(repo.join("notes.txt")).unwrap();
    let summary = push(&socket, &repo, &remote);
    assert_eq!(summary["deleted"].as_u64(), Some(0), "{summary}");
    assert_eq!(std::fs::read_to_string(remote.join("notes.txt")).unwrap(), "changed there\n");
    assert!(remote.join("machine/out.txt").exists());

    // A subfolder of a working copy is refused: its git state is above it.
    std::fs::create_dir_all(repo.join("docs")).unwrap();
    std::fs::write(repo.join("docs/readme"), "docs\n").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["link", "sync", "push", "--socket"])
        .arg(&socket)
        .arg(repo.join("docs"))
        .arg(home.join("work/docs"))
        .output()
        .unwrap();
    assert!(!output.status.success());

    // Append changes a file in place only at its revision, and never one
    // with a second link (it could reach a file outside the home).
    let path = home.join("work/part");
    let created = write_line(
        &socket,
        serde_json::json!({"id":1,"cmd":"fs.write","path":path,"text":"a","mode":"create"}),
    );
    assert_eq!(created["ok"], true, "{created}");
    let stale = write_line(
        &socket,
        serde_json::json!({"id":2,"cmd":"fs.write","path":path,"text":"b","mode":"append","expected":"s9-m0"}),
    );
    assert_eq!(stale["error_code"], "fs.revision_mismatch", "{stale}");
    let revision = created["data"]["entry"]["revision"].clone();
    std::fs::hard_link(&path, home.join("work/part-link")).unwrap();
    let linked = write_line(
        &socket,
        serde_json::json!({"id":3,"cmd":"fs.write","path":path,"text":"b","mode":"append","expected":revision}),
    );
    assert_eq!(linked["error_code"], "fs.not_a_file", "{linked}");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "a");
}

/// `cmux link sync pull`: whether it exited 0, and its JSON line.
fn pull(socket: &Path, local: &Path, remote: &Path) -> (bool, Value) {
    pull_with_state(socket, local, remote, &state_of(socket))
}

fn pull_with_state(socket: &Path, local: &Path, remote: &Path, state: &Path) -> (bool, Value) {
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("CMUX_TUI_STATE_DIR", state)
        .args(["link", "sync", "pull", "--socket"])
        .arg(socket)
        .arg(local)
        .arg(remote)
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

/// A clean repo pushed to a fake machine: the repo, the machine's folder
/// and the socket (its folder kept alive by the returned guards).
fn pushed_repo() -> (tempfile::TempDir, tempfile::TempDir, PathBuf, PathBuf, PathBuf) {
    let (root, sockets, repo, remote, socket, _) = hostile_pushed_repo();
    (root, sockets, repo, remote, socket)
}

/// [`pushed_repo`] whose machine can turn malicious after the push.
#[allow(clippy::type_complexity)]
fn hostile_pushed_repo()
-> (tempfile::TempDir, tempfile::TempDir, PathBuf, PathBuf, PathBuf, &'static Mutex<Vec<Planted>>) {
    let root = tempfile::tempdir().unwrap();
    let base = std::fs::canonicalize(root.path()).unwrap();
    let repo = base.join("app");
    std::fs::create_dir_all(repo.join("src")).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    std::fs::write(repo.join("src/a.txt"), "one\n").unwrap();
    std::fs::write(repo.join("old.txt"), "old\n").unwrap();
    std::fs::write(repo.join("notes.txt"), "notes\n").unwrap();
    std::fs::write(repo.join("other.txt"), "other\n").unwrap();
    std::fs::write(repo.join(".gitignore"), "build/\n").unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let home = base.join("home");
    std::fs::create_dir_all(home.join("work")).unwrap();
    let sockets = tempfile::Builder::new().prefix("cs").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("fs.sock");
    let planted = serve_hostile_fs(&socket, &home, &[]);
    let remote = home.join("work/app");
    push(&socket, &repo, &remote);
    (root, sockets, repo, remote, socket, planted)
}

#[test]
fn a_pull_brings_back_the_machines_edits_and_commits_but_never_its_hooks() {
    let (_root, _sockets, repo, remote, socket) = pushed_repo();
    // On the machine: a commit that edits, adds and deletes, then an
    // unstaged edit and a staged new file, a hook, a config setting, an
    // ignored build output and a new .env file.
    std::fs::write(remote.join("src/a.txt"), "one\nfrom the machine\n").unwrap();
    std::fs::write(remote.join("new.txt"), "made there\n").unwrap();
    std::fs::remove_file(remote.join("old.txt")).unwrap();
    git(&remote, &["add", "-A"]);
    git(&remote, &["commit", "-q", "-m", "on the machine"]);
    std::fs::write(remote.join("notes.txt"), "notes\nunstaged there\n").unwrap();
    std::fs::write(remote.join("staged.txt"), "staged there\n").unwrap();
    git(&remote, &["add", "staged.txt"]);
    // The push sent no hooks folder.
    std::fs::create_dir_all(remote.join(".git/hooks")).unwrap();
    std::fs::write(remote.join(".git/hooks/post-merge"), "#!/bin/sh\nexit 1\n").unwrap();
    git(&remote, &["config", "core.hooksPath", "/tmp/machine-hooks"]);
    std::fs::create_dir_all(remote.join("build")).unwrap();
    std::fs::write(remote.join("build/out.o"), "ignored\n").unwrap();
    std::fs::write(remote.join(".env.local"), "TOKEN=machine\n").unwrap();

    let (ok, pulled) = pull(&socket, &repo, &remote);
    assert!(ok, "{pulled}");
    assert_eq!(pulled["fast_forwarded"], true, "{pulled}");

    assert_eq!(std::fs::read_to_string(repo.join("src/a.txt")).unwrap(), "one\nfrom the machine\n");
    assert_eq!(std::fs::read_to_string(repo.join("new.txt")).unwrap(), "made there\n");
    assert!(!repo.join("old.txt").exists(), "a delete on the machine did not come back");
    assert_eq!(git(&repo, &["rev-parse", "HEAD"]), git(&remote, &["rev-parse", "HEAD"]));
    assert_eq!(git(&repo, &["log", "-1", "--format=%s"]), "on the machine\n");
    let status = ["status", "--porcelain=v2", "--branch"];
    let mut there = git(&remote, &status);
    there = there
        .lines()
        .filter(|line| !line.contains(".env.local"))
        .map(|l| format!("{l}\n"))
        .collect();
    assert_eq!(git(&repo, &status), there, "git status differs from the machine's");
    assert!(!repo.join(".git/hooks/post-merge").exists(), "a machine hook arrived");
    let config = std::fs::read_to_string(repo.join(".git/config")).unwrap();
    assert!(!config.contains("machine-hooks"), "the machine's config arrived: {config}");
    assert!(!repo.join("build").exists(), "an ignored folder came back");
    assert!(!repo.join(".env.local").exists(), "a new .env file came back");

    // Nothing new on the machine: a second pull changes nothing.
    let (ok, again) = pull(&socket, &repo, &remote);
    assert!(ok, "{again}");
    assert_eq!(again["written"], 0, "{again}");
    assert_eq!(again["deleted"], 0, "{again}");
    assert_eq!(again["fast_forwarded"], false, "{again}");
}

#[test]
fn a_pull_with_changes_on_both_sides_changes_nothing_and_names_them() {
    let (_root, _sockets, repo, remote, socket) = pushed_repo();
    std::fs::write(remote.join("notes.txt"), "notes\nfrom the machine\n").unwrap();
    std::fs::write(remote.join("other.txt"), "other\nfrom the machine\n").unwrap();
    std::fs::write(repo.join("notes.txt"), "notes\nfrom the mac\n").unwrap();
    let head = git(&repo, &["rev-parse", "HEAD"]);

    let (ok, answer) = pull(&socket, &repo, &remote);
    assert!(!ok, "{answer}");
    assert_eq!(answer["error_code"], "sync_conflict", "{answer}");
    assert_eq!(answer["conflicts"], serde_json::json!(["notes.txt"]), "{answer}");
    assert_eq!(std::fs::read_to_string(repo.join("notes.txt")).unwrap(), "notes\nfrom the mac\n");
    assert_eq!(std::fs::read_to_string(repo.join("other.txt")).unwrap(), "other\n", "half applied");

    // Both sides commit: the branch is a conflict too, and stays here.
    git(&remote, &["commit", "-q", "-am", "there"]);
    git(&repo, &["commit", "-q", "-am", "here"]);
    let here = git(&repo, &["rev-parse", "HEAD"]);
    assert_ne!(here, head);
    let (ok, answer) = pull(&socket, &repo, &remote);
    assert!(!ok, "{answer}");
    let conflicts = answer["conflicts"].as_array().cloned().unwrap_or_default();
    assert!(conflicts.contains(&serde_json::json!(".git/HEAD")), "{answer}");
    assert!(conflicts.contains(&serde_json::json!("notes.txt")), "{answer}");
    assert_eq!(git(&repo, &["rev-parse", "HEAD"]), here, "the branch moved");
    assert_eq!(std::fs::read_to_string(repo.join("other.txt")).unwrap(), "other\n", "half applied");
}

/// Every path below `dir`, relative to it, folders included.
fn paths_below(dir: &Path) -> Vec<String> {
    let mut found = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(at) = stack.pop() {
        for entry in std::fs::read_dir(&at).unwrap() {
            let path = entry.unwrap().path();
            found.push(path.strip_prefix(dir).unwrap().to_string_lossy().into_owned());
            if path.is_dir() && !path.is_symlink() {
                stack.push(path);
            }
        }
    }
    found.sort();
    found
}

/// A malicious machine (the VM is not trusted): a repository folder under
/// another spelling (`.GIT` reaches the real `.git` on a Mac's
/// case-insensitive disk) and a nested repository never come back.
#[test]
fn a_pull_never_brings_back_a_repository_folder_under_another_spelling() {
    let (_root, _sockets, repo, remote, socket) = pushed_repo();
    for folder in [".GIT/hooks", "git~1/hooks", ".Git/info"] {
        std::fs::create_dir_all(remote.join(folder)).unwrap();
    }
    std::fs::write(remote.join(".GIT/hooks/pre-commit"), "#!/bin/sh\necho planted\n").unwrap();
    std::fs::set_permissions(
        remote.join(".GIT/hooks/pre-commit"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    std::fs::write(remote.join("git~1/hooks/post-checkout"), "#!/bin/sh\n").unwrap();
    std::fs::write(remote.join(".Git/info/attributes"), "* filter=evil\n").unwrap();
    // A nested repository: its marker and its files stay on the machine.
    std::fs::create_dir_all(remote.join("vendor/lib/.git")).unwrap();
    std::fs::write(remote.join("vendor/lib/.git/config"), "[core]\n\tfsmonitor = evil\n").unwrap();
    std::fs::write(remote.join("vendor/lib/code.txt"), "nested\n").unwrap();
    let before = paths_below(&repo.join(".git"));

    let (_ok, answer) = pull(&socket, &repo, &remote);

    // By name: on a case-insensitive disk `.GIT` exists wherever `.git` does.
    let names: Vec<String> = std::fs::read_dir(&repo)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    for planted in [".GIT", ".Git", "git~1", "vendor"] {
        assert!(!names.iter().any(|name| name == planted), "{planted} came back: {answer}");
    }
    assert_eq!(paths_below(&repo.join(".git")), before, "the repository changed: {answer}");
}

/// A malicious machine lists names that climb: nothing is written outside
/// the folder or into its repository.
#[test]
fn a_pull_refuses_listed_names_that_climb_out_of_the_folder() {
    let (root, _sockets, repo, remote, socket, planted) = hostile_pushed_repo();
    let top = remote.to_string_lossy().into_owned();
    planted.lock().unwrap().extend([
        (top.clone(), "x/../.git/hooks/pre-commit".into(), b"#!/bin/sh\necho planted\n".to_vec()),
        (top, "../escaped.txt".into(), b"outside\n".to_vec()),
    ]);
    let (ok, answer) = pull(&socket, &repo, &remote);
    assert!(!ok, "a climbing name was taken: {answer}");
    assert!(!repo.join(".git/hooks/pre-commit").exists(), "a hook was planted: {answer}");
    assert!(!root.path().join("escaped.txt").exists(), "a file landed outside: {answer}");

    // Outside git nothing else stands in the way.
    let plain = std::fs::canonicalize(root.path()).unwrap().join("plain");
    std::fs::create_dir_all(&plain).unwrap();
    std::fs::write(plain.join("a.txt"), "a\n").unwrap();
    let plain_remote = remote.parent().unwrap().join("plain");
    push(&socket, &plain, &plain_remote);
    let plain_top = plain_remote.to_string_lossy().into_owned();
    planted.lock().unwrap().push((plain_top, "../escaped.txt".into(), b"outside\n".to_vec()));
    let (ok, answer) = pull(&socket, &plain, &plain_remote);
    assert!(!ok, "a climbing name was taken: {answer}");
    let outside = plain.parent().unwrap().join("escaped.txt");
    assert!(!outside.exists(), "a file landed outside the folder: {answer}");
}

/// The staged entries of the index at `repo`, as text.
fn staged(repo: &Path) -> String {
    git(repo, &["ls-files", "--stage"])
}

/// A pull that fails partway leaves this Mac as it was: its files, its
/// branch and its index.
#[test]
fn a_pull_that_fails_partway_changes_nothing_here() {
    // SAFETY: geteuid has no preconditions.
    if unsafe { libc::geteuid() } == 0 {
        eprintln!("skipped: root writes into a read-only folder");
        return;
    }
    let (_root, _sockets, repo, remote, socket) = pushed_repo();
    std::fs::write(remote.join("notes.txt"), "notes\nfrom the machine\n").unwrap();
    std::fs::remove_file(remote.join("other.txt")).unwrap();
    std::fs::write(remote.join("src/new.txt"), "new there\n").unwrap();
    git(&remote, &["add", "-A"]);
    git(&remote, &["commit", "-q", "-m", "on the machine"]);
    let head = git(&repo, &["rev-parse", "HEAD"]);
    let index = staged(&repo);
    // The machine's new file can't land in this folder here.
    std::fs::set_permissions(repo.join("src"), std::fs::Permissions::from_mode(0o555)).unwrap();

    let (ok, answer) = pull(&socket, &repo, &remote);
    std::fs::set_permissions(repo.join("src"), std::fs::Permissions::from_mode(0o755)).unwrap();

    assert!(!ok, "{answer}");
    assert_eq!(std::fs::read_to_string(repo.join("notes.txt")).unwrap(), "notes\n", "half applied");
    assert_eq!(std::fs::read_to_string(repo.join("other.txt")).unwrap(), "other\n", "half applied");
    assert!(!repo.join("src/new.txt").exists(), "{answer}");
    assert_eq!(git(&repo, &["rev-parse", "HEAD"]), head, "the branch moved: {answer}");
    assert_eq!(staged(&repo), index, "the index changed: {answer}");
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The base of a pull is the copy of the push's record this Mac kept, never
/// the machine's: a machine that claims it was sent files the push never
/// sent can't overwrite or delete them here.
#[test]
fn a_pull_trusts_only_the_base_this_mac_kept() {
    let (_root, _sockets, repo, remote, socket) = pushed_repo();
    // Never pushed: an untracked .env and an ignored build output.
    std::fs::write(repo.join(".env"), "SECRET=mac\n").unwrap();
    std::fs::create_dir_all(repo.join("build")).unwrap();
    std::fs::write(repo.join("build/keep.o"), "mine\n").unwrap();

    // No copy of the record here: nothing is brought back.
    let elsewhere = socket.parent().unwrap().join("other-state");
    let (ok, answer) = pull_with_state(&socket, &repo, &remote, &elsewhere);
    assert!(!ok, "{answer}");
    assert_eq!(answer["error_code"], "sync_no_base", "{answer}");

    // The machine claims the push sent both, unchanged, then deleted .env
    // and changed build/keep.o.
    let record = remote.join(".git/cmux-sync.json");
    let mut manifest: Value = serde_json::from_slice(&std::fs::read(&record).unwrap()).unwrap();
    for (path, bytes) in [(".env", &b"SECRET=mac\n"[..]), ("build/keep.o", &b"mine\n"[..])] {
        manifest["files"][path] =
            json!({"sha256": sha256_hex(bytes), "permissions": 0o644, "revision": "s1-m1"});
    }
    std::fs::write(&record, manifest.to_string()).unwrap();
    std::fs::create_dir_all(remote.join("build")).unwrap();
    std::fs::write(remote.join("build/keep.o"), "planted\n").unwrap();

    let (ok, answer) = pull(&socket, &repo, &remote);
    assert!(!ok, "{answer}");
    assert_eq!(answer["error_code"], "sync_base_mismatch", "{answer}");
    assert_eq!(std::fs::read_to_string(repo.join(".env")).unwrap(), "SECRET=mac\n", "{answer}");
    assert_eq!(std::fs::read_to_string(repo.join("build/keep.o")).unwrap(), "mine\n", "{answer}");
}

/// Plants the files of a bare repository's shape in `folder` on the
/// machine: git run anywhere below it would read its `config` (and run
/// `core.fsmonitor`), so none of it may come back.
fn plant_repository_shape(folder: &Path) {
    std::fs::create_dir_all(folder.join("objects/info")).unwrap();
    std::fs::create_dir_all(folder.join("refs/heads")).unwrap();
    std::fs::write(folder.join("HEAD"), "ref: refs/heads/main\n").unwrap();
    std::fs::write(folder.join("objects/info/packs"), "\n").unwrap();
    std::fs::write(folder.join("refs/heads/main"), format!("{}\n", "1".repeat(40))).unwrap();
    std::fs::write(folder.join("config"), "[core]\n\tfsmonitor = touch /tmp/cmux-pwned\n").unwrap();
}

/// A malicious machine plants a repository's shape (HEAD, objects, refs
/// and a config) instead of a `.git` folder: a new folder, a folder the
/// push sent, a `commondir` variant and, outside git, the top itself.
/// None of it comes back, and the folder the push sent keeps its files.
#[test]
fn a_pull_never_brings_back_a_planted_repository_shape() {
    let (root, _sockets, repo, remote, socket) = pushed_repo();
    plant_repository_shape(&remote.join("sub"));
    plant_repository_shape(&remote.join("src"));
    std::fs::create_dir_all(remote.join("wt")).unwrap();
    std::fs::write(remote.join("wt/HEAD"), "ref: refs/heads/main\n").unwrap();
    std::fs::write(remote.join("wt/commondir"), "../sub\n").unwrap();
    std::fs::write(remote.join("wt/config"), "[core]\n\tfsmonitor = evil\n").unwrap();
    std::fs::write(remote.join("fine.txt"), "fine\n").unwrap();

    let (ok, answer) = pull(&socket, &repo, &remote);
    assert!(ok, "{answer}");
    for planted in ["sub/HEAD", "sub/config", "sub/refs", "src/HEAD", "src/config", "wt/commondir"]
    {
        assert!(!repo.join(planted).exists(), "{planted} came back: {answer}");
    }
    assert_eq!(std::fs::read_to_string(repo.join("src/a.txt")).unwrap(), "one\n", "{answer}");
    assert_eq!(std::fs::read_to_string(repo.join("fine.txt")).unwrap(), "fine\n", "{answer}");

    // Outside git: the top itself is planted. Only its repository names
    // stay out; another new file still comes back.
    let plain = std::fs::canonicalize(root.path()).unwrap().join("plain");
    std::fs::create_dir_all(&plain).unwrap();
    std::fs::write(plain.join("a.txt"), "a\n").unwrap();
    let plain_remote = remote.parent().unwrap().join("plain");
    push(&socket, &plain, &plain_remote);
    plant_repository_shape(&plain_remote);
    std::fs::write(plain_remote.join("readme.txt"), "made there\n").unwrap();
    let (ok, answer) = pull(&socket, &plain, &plain_remote);
    assert!(ok, "{answer}");
    for planted in ["HEAD", "config", "refs", "objects"] {
        assert!(!plain.join(planted).exists(), "{planted} came back: {answer}");
    }
    assert_eq!(std::fs::read_to_string(plain.join("readme.txt")).unwrap(), "made there\n");
}

/// The folder this working copy's `core.hooksPath` names runs on its next
/// commit: nothing the machine put there comes back, husky's layout
/// (`.husky/_` calling `.husky/<hook>`) included.
#[test]
fn a_pull_never_brings_back_the_hooks_this_working_copy_runs() {
    let (_root, _sockets, repo, remote, socket) = pushed_repo();
    git(&repo, &["config", "core.hooksPath", ".githooks"]);
    std::fs::create_dir_all(remote.join(".githooks")).unwrap();
    std::fs::write(remote.join(".githooks/pre-commit"), "#!/bin/sh\necho planted\n").unwrap();
    std::fs::set_permissions(
        remote.join(".githooks/pre-commit"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    let (ok, answer) = pull(&socket, &repo, &remote);
    assert!(ok, "{answer}");
    assert!(!repo.join(".githooks/pre-commit").exists(), "a hook came back: {answer}");

    git(&repo, &["config", "core.hooksPath", ".husky/_"]);
    std::fs::create_dir_all(remote.join(".husky/_")).unwrap();
    std::fs::write(remote.join(".husky/_/pre-push"), "#!/bin/sh\n. .husky/pre-push\n").unwrap();
    std::fs::write(remote.join(".husky/pre-push"), "#!/bin/sh\necho planted\n").unwrap();
    let (ok, answer) = pull(&socket, &repo, &remote);
    assert!(ok, "{answer}");
    assert!(!repo.join(".husky").exists(), "a hook came back: {answer}");
}

/// Hundreds of new files in as many folders come back under a Mac's
/// default limit of open files (256): a pull holds no handle per file.
#[test]
fn a_pull_of_many_files_finishes_under_a_low_open_file_limit() {
    let (_root, _sockets, repo, remote, socket) = pushed_repo();
    for index in 0..300 {
        let folder = remote.join(format!("many/d{index}"));
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join("f.txt"), format!("{index}\n")).unwrap();
    }
    let output = Command::new("sh")
        .arg("-c")
        .arg("ulimit -n 128 && exec \"$0\" \"$@\"")
        .arg(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["link", "sync", "pull", "--socket"])
        .arg(&socket)
        .arg(&repo)
        .arg(&remote)
        .env("CMUX_TUI_STATE_DIR", state_of(&socket))
        .output()
        .unwrap();
    let answer = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "{answer}{}", String::from_utf8_lossy(&output.stderr));
    for index in [0, 150, 299] {
        let path = repo.join(format!("many/d{index}/f.txt"));
        assert_eq!(std::fs::read_to_string(path).unwrap(), format!("{index}\n"), "{answer}");
    }
}

/// `core.hooksPath` spelled in another case still names the hooks folder
/// on a Mac's disk: what the machine put there stays out.
#[test]
fn a_pull_fences_the_hooks_folder_under_any_case() {
    let (_root, _sockets, repo, remote, socket) = pushed_repo();
    git(&repo, &["config", "core.hooksPath", ".GitHooks"]);
    std::fs::create_dir_all(remote.join(".githooks")).unwrap();
    std::fs::write(remote.join(".githooks/pre-commit"), "#!/bin/sh\necho planted\n").unwrap();
    let (ok, answer) = pull(&socket, &repo, &remote);
    assert!(ok, "{answer}");
    assert!(!repo.join(".githooks").exists(), "a hook came back: {answer}");
}

/// The machine's commits and staged changes go into this Mac's branch and
/// index: one that adds a hook or a repository's shape is a conflict, so a
/// later `git checkout -- .` can't write it out here.
#[test]
fn a_pull_refuses_commits_and_staging_that_carry_a_hook_or_a_repository() {
    let (_root, _sockets, repo, remote, socket) = pushed_repo();
    git(&repo, &["config", "core.hooksPath", ".githooks"]);
    let head = git(&repo, &["rev-parse", "HEAD"]);
    std::fs::create_dir_all(remote.join(".githooks")).unwrap();
    std::fs::write(remote.join(".githooks/pre-commit"), "#!/bin/sh\necho planted\n").unwrap();
    git(&remote, &["add", "-f", ".githooks/pre-commit"]);
    git(&remote, &["commit", "-q", "-m", "a hook"]);
    let (ok, answer) = pull(&socket, &repo, &remote);
    assert!(!ok, "{answer}");
    assert!(answer["conflicts"].to_string().contains(".git/HEAD"), "{answer}");
    assert_eq!(git(&repo, &["rev-parse", "HEAD"]), head, "the branch moved: {answer}");

    // Staged instead: a bare repository's shape in a subfolder.
    git(&remote, &["reset", "-q", "--hard", head.trim()]);
    std::fs::remove_dir_all(remote.join(".githooks")).ok();
    std::fs::create_dir_all(remote.join("sub")).unwrap();
    std::fs::write(remote.join("sub/HEAD"), "ref: refs/heads/main\n").unwrap();
    std::fs::write(remote.join("sub/config"), "[core]\n\tfsmonitor = evil\n").unwrap();
    git(&remote, &["add", "sub"]);
    let index = staged(&repo);
    let (ok, answer) = pull(&socket, &repo, &remote);
    assert!(!ok, "{answer}");
    assert!(answer["conflicts"].to_string().contains(".git/index"), "{answer}");
    assert_eq!(staged(&repo), index, "the index changed: {answer}");
}

/// Serves `fs.*` like [`serve_fs`], but answers the `fs.write` of a file
/// (not the sync record) with `refusal` once `allowed` of them went through.
fn serve_fs_refusing_writes(socket: &Path, home: &Path, allowed: usize, refusal: &'static str) {
    let listener = UnixListener::bind(socket).unwrap();
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.to_path_buf()]))));
    let writes: &'static std::sync::atomic::AtomicUsize = Box::leak(Box::default());
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
                    let path = request["path"].as_str().unwrap_or_default().to_string();
                    let refused = cmd == "fs.write"
                        && !path.ends_with("cmux-sync.json")
                        && writes.fetch_add(1, std::sync::atomic::Ordering::SeqCst) >= allowed;
                    let reply = if refused {
                        json!({"id": id, "ok": false, "error_code": refusal, "error": "refused"})
                    } else {
                        stream::answer(&id, service.call("local", &cmd, request))
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
}

/// A push's exit status, its answer line and its stderr lines.
fn push_output(socket: &Path, local: &Path, remote: &Path) -> (bool, Value, Vec<Value>) {
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("CMUX_TUI_STATE_DIR", state_of(socket))
        .args(["link", "sync", "push", "--socket"])
        .arg(socket)
        .arg(local)
        .arg(remote)
        .output()
        .unwrap();
    let answer = serde_json::from_slice(&output.stdout).expect("one JSON answer on stdout");
    let progress = String::from_utf8_lossy(&output.stderr)
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect();
    (output.status.success(), answer, progress)
}

/// A machine served over a fresh home: (its temp folders, socket, home).
fn machine_home(root: &Path) -> (tempfile::TempDir, PathBuf, PathBuf) {
    let home = root.join("home");
    std::fs::create_dir_all(home.join("work")).unwrap();
    let sockets = tempfile::Builder::new().prefix("cs").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("fs.sock");
    (sockets, socket, home)
}

/// Outside git, dependency and build folders, secrets, symlinks that leave
/// the folder and special files stay on this Mac, and the answer names each
/// with why; a symlink inside the folder arrives as a symlink.
#[test]
fn outside_git_heavy_folders_secrets_and_links_stay_and_are_named() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("site");
    for dir in ["node_modules/left-pad", "target/debug", "build", "dist", "src", "docs/build"] {
        std::fs::create_dir_all(folder.join(dir)).unwrap();
    }
    for (path, text) in [
        ("package.json", "{}"),
        ("Cargo.toml", "[package]"),
        ("node_modules/left-pad/index.js", "x"),
        ("target/debug/app", "x"),
        ("build/out.js", "x"),
        ("dist/out.js", "x"),
        ("docs/build/page.md", "kept: no project file beside it"),
        ("src/main.rs", "fn main() {}"),
        (".env", "TOKEN=1"),
        (".env.local", "TOKEN=2"),
        ("id_ed25519", "key"),
        ("src/cert.pem", "pem"),
    ] {
        std::fs::write(folder.join(path), text).unwrap();
    }
    std::fs::write(root.join("outside.txt"), "outside").unwrap();
    std::os::unix::fs::symlink("src/main.rs", folder.join("inside-link")).unwrap();
    std::os::unix::fs::symlink(root.join("outside.txt"), folder.join("outside-link")).unwrap();
    let fifo = {
        use std::os::unix::ffi::OsStrExt as _;
        std::ffi::CString::new(folder.join("pipe").as_os_str().as_bytes()).unwrap()
    };
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs(&socket, &home);
    let remote = home.join("work/site");

    let (ok, summary, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{summary}");
    let mut sent: Vec<String> = files_below(&remote)
        .into_iter()
        .map(|(path, _)| path.strip_prefix(&remote).unwrap().to_string_lossy().into_owned())
        .filter(|path| path != ".cmux-sync.json")
        .collect();
    sent.sort();
    assert_eq!(sent, ["Cargo.toml", "docs/build/page.md", "package.json", "src/main.rs"]);
    let named: std::collections::BTreeMap<String, String> = summary["skipped_files"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| {
            (
                entry["path"].as_str().unwrap().to_string(),
                entry["why"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    let heavy = "a heavy folder rebuilt on the machine";
    for folder in ["node_modules/", "target/", "build/", "dist/"] {
        assert_eq!(named.get(folder).map(String::as_str), Some(heavy), "{summary}");
    }
    assert_eq!(named[".env"], "secret: .env files are shared only on purpose");
    assert_eq!(named[".env.local"], "secret: .env files are shared only on purpose");
    assert_eq!(named["id_ed25519"], "secret: key files are shared only on purpose");
    assert_eq!(named["src/cert.pem"], "secret: key files are shared only on purpose");
    assert!(!named.contains_key("inside-link"), "{summary}");
    assert_eq!(std::fs::read_link(remote.join("inside-link")).unwrap(), Path::new("src/main.rs"));
    assert_eq!(named["outside-link"], "a symlink (to a place outside the folder)");
    assert!(std::fs::symlink_metadata(remote.join("outside-link")).is_err());
    assert_eq!(named["pipe"], "a socket, FIFO or device");
    assert_eq!(named.len(), 10, "{summary}");
    assert_eq!(summary["skipped"], json!(10));
    assert_eq!(summary["skipped_counts"]["heavy"], json!(4));
    assert_eq!(summary["skipped_counts"]["secret"], json!(4));
    assert_eq!(summary["skipped_counts"]["symlink"], json!(1));
    assert_eq!(summary["skipped_counts"]["special"], json!(1));
}

/// Progress goes to stderr as JSON lines: the totals before anything is
/// written, and the last line at the totals.
#[test]
fn a_push_reports_its_progress_against_the_totals() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("notes");
    std::fs::create_dir_all(&folder).unwrap();
    let mut bytes = 0u64;
    for index in 0..30u64 {
        let text = "x".repeat(usize::try_from(index * 7).unwrap());
        bytes += text.len() as u64;
        std::fs::write(folder.join(format!("n{index}.txt")), text).unwrap();
    }
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs(&socket, &home);

    let (ok, summary, lines) = push_output(&socket, &folder, &home.join("work/notes"));
    assert!(ok, "{summary}");
    assert!(lines.len() >= 2, "{lines:?}");
    let totals = json!({"files_done": 0, "files_total": 30, "bytes_done": 0, "bytes_total": bytes});
    assert_eq!(lines[0]["progress"], totals);
    let done =
        json!({"files_done": 30, "files_total": 30, "bytes_done": bytes, "bytes_total": bytes});
    assert_eq!(lines.last().unwrap()["progress"], done);
    // The answer line keeps its shape.
    assert_eq!(summary["ok"], json!(true));
    assert_eq!(summary["written"], json!(30));
}

/// A push cut off partway saves what landed as it goes: its retry writes
/// only what the record did not hold yet.
#[test]
fn a_retry_of_an_interrupted_push_writes_only_what_had_not_landed() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("many");
    std::fs::create_dir_all(&folder).unwrap();
    for index in 0..1200 {
        std::fs::write(folder.join(format!("f{index:04}.txt")), format!("{index}\n")).unwrap();
    }
    let (_sockets, socket, home) = machine_home(&root);
    let remote = home.join("work/many");
    serve_fs_refusing_writes(&socket, &home, 700, "fs.failure");
    let (ok, failed, _) = push_output(&socket, &folder, &remote);
    assert!(!ok, "{failed}");
    assert_eq!(failed["error_code"], json!("fs.failure"), "{failed}");

    let sockets = tempfile::Builder::new().prefix("cs").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("fs.sock");
    serve_fs(&socket, &home);
    let (ok, summary, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{summary}");
    // The record was saved at 500 files; the 200 after it are written again.
    assert_eq!(summary["unchanged"], json!(500), "{summary}");
    assert_eq!(summary["written"], json!(700), "{summary}");
    assert_eq!(files_below(&remote).len(), 1201);
}

/// The machine's full disk answers in plain words.
#[test]
fn a_full_disk_on_the_machine_answers_disk_full() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("small");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("a.txt"), "a").unwrap();
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs_refusing_writes(&socket, &home, 0, "fs.no_space");
    let (ok, answer, _) = push_output(&socket, &folder, &home.join("work/small"));
    assert!(!ok);
    assert_eq!(answer["error_code"], json!("disk_full"), "{answer}");
    assert_eq!(answer["error"], json!("The Cloud machine's disk is full"));
}

/// The `skipped_files` of an answer by path: why each was left out.
fn skipped_by_path(answer: &Value) -> std::collections::BTreeMap<String, String> {
    answer["skipped_files"]
        .as_array()
        .unwrap_or_else(|| panic!("no skipped_files: {answer}"))
        .iter()
        .map(|entry| {
            (
                entry["path"].as_str().unwrap().to_string(),
                entry["why"].as_str().unwrap().to_string(),
            )
        })
        .collect()
}

/// Symlinks that stay inside the folder go to the machine as symlinks with
/// their text (an absolute one rewritten relative), and come back as
/// symlinks: one the machine pointed elsewhere and one it made are here
/// after a pull, with exactly the machine's text. One that points outside
/// the folder is skipped and named with why, by the push and by the pull,
/// and nothing of it is made on either side.
#[test]
fn an_inside_symlink_round_trips_and_an_outside_one_is_skipped_and_named() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("site");
    std::fs::create_dir_all(folder.join("src/deep")).unwrap();
    std::fs::write(folder.join("src/a.txt"), "a\n").unwrap();
    std::fs::write(folder.join("src/b.txt"), "b\n").unwrap();
    std::os::unix::fs::symlink("src", folder.join("lib")).unwrap();
    std::os::unix::fs::symlink(folder.join("src/a.txt"), folder.join("abs")).unwrap();
    std::os::unix::fs::symlink("../a.txt", folder.join("src/deep/up")).unwrap();
    std::os::unix::fs::symlink("/etc", folder.join("out")).unwrap();
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs(&socket, &home);
    let remote = home.join("work/site");

    let (ok, summary, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{summary}");
    let link = |path: PathBuf| std::fs::read_link(path).ok().map(|text| text.display().to_string());
    assert_eq!(link(remote.join("lib")).as_deref(), Some("src"));
    assert_eq!(link(remote.join("abs")).as_deref(), Some("src/a.txt"));
    assert_eq!(link(remote.join("src/deep/up")).as_deref(), Some("../a.txt"));
    assert!(std::fs::symlink_metadata(remote.join("out")).is_err(), "an outside link was made");
    let named = skipped_by_path(&summary);
    assert_eq!(named["out"], "a symlink (to a place outside the folder)", "{summary}");
    assert_eq!(named.len(), 1, "{summary}");
    // Nothing changed: a second push makes nothing.
    let (ok, again, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{again}");
    assert_eq!(again["written"], json!(0), "{again}");

    // On the machine: `lib` now points at one file, a new inside link, and
    // links that leave the folder by an absolute path or by climbing.
    std::fs::remove_file(remote.join("lib")).unwrap();
    std::os::unix::fs::symlink("src/b.txt", remote.join("lib")).unwrap();
    std::os::unix::fs::symlink("deep", remote.join("src/near")).unwrap();
    std::os::unix::fs::symlink("/etc/passwd", remote.join("evil")).unwrap();
    std::os::unix::fs::symlink("../../../..", remote.join("src/climb")).unwrap();
    std::os::unix::fs::symlink(".git/hooks", remote.join("hooks")).unwrap();

    let (ok, pulled) = pull(&socket, &folder, &remote);
    assert!(ok, "{pulled}");
    assert_eq!(link(folder.join("lib")).as_deref(), Some("src/b.txt"), "{pulled}");
    assert_eq!(link(folder.join("src/near")).as_deref(), Some("deep"), "{pulled}");
    assert_eq!(
        link(folder.join("abs")).as_deref(),
        Some(folder.join("src/a.txt").to_str().unwrap())
    );
    assert_eq!(std::fs::read_to_string(folder.join("lib")).unwrap(), "b\n");
    for gone in ["evil", "src/climb", "hooks"] {
        assert!(std::fs::symlink_metadata(folder.join(gone)).is_err(), "{gone} came back");
    }
    let named = skipped_by_path(&pulled);
    for outside in ["evil", "src/climb"] {
        assert_eq!(named[outside], "a symlink (to a place outside the folder)", "{pulled}");
    }
    assert_eq!(named["hooks"], "a symlink (into the repository folder)", "{pulled}");
    // The pull is the next base: pulling again changes nothing, and a push
    // after it makes nothing new.
    let (ok, again) = pull(&socket, &folder, &remote);
    assert!(ok, "{again}");
    assert_eq!(again["written"], json!(0), "{again}");
    let (ok, pushed, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{pushed}");
    assert_eq!(pushed["written"], json!(0), "{pushed}");
}

/// A symlink changed on both sides is a conflict, and the pull changes
/// nothing here: this Mac's link keeps its text.
#[test]
fn a_symlink_changed_on_both_sides_is_a_conflict_that_changes_nothing() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("site");
    std::fs::create_dir_all(folder.join("src")).unwrap();
    std::fs::write(folder.join("src/a.txt"), "a\n").unwrap();
    std::fs::write(folder.join("src/b.txt"), "b\n").unwrap();
    std::os::unix::fs::symlink("src", folder.join("lib")).unwrap();
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs(&socket, &home);
    let remote = home.join("work/site");
    let (ok, summary, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{summary}");

    std::fs::remove_file(remote.join("lib")).unwrap();
    std::os::unix::fs::symlink("src/a.txt", remote.join("lib")).unwrap();
    std::fs::remove_file(folder.join("lib")).unwrap();
    std::os::unix::fs::symlink("src/b.txt", folder.join("lib")).unwrap();

    let (ok, pulled) = pull(&socket, &folder, &remote);
    assert!(!ok, "{pulled}");
    assert_eq!(pulled["error_code"], "sync_conflict", "{pulled}");
    assert_eq!(pulled["conflicts"], json!(["lib"]), "{pulled}");
    assert_eq!(std::fs::read_link(folder.join("lib")).unwrap(), Path::new("src/b.txt"));
}

/// A link named like the sync record never goes (the record would be
/// written through it), and a machine link that climbs out through another
/// link stays there, though its own words stay inside.
#[test]
fn a_link_over_the_record_or_out_through_another_link_stays() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("site");
    std::fs::create_dir_all(folder.join("src")).unwrap();
    std::fs::write(folder.join("src/a.txt"), "a\n").unwrap();
    std::os::unix::fs::symlink("src/a.txt", folder.join(".cmux-sync.json")).unwrap();
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs(&socket, &home);
    let remote = home.join("work/site");

    let (ok, summary, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{summary}");
    assert_eq!(skipped_by_path(&summary)[".cmux-sync.json"], "the name of the sync record");
    assert_eq!(std::fs::read_to_string(folder.join("src/a.txt")).unwrap(), "a\n");
    assert!(!std::fs::symlink_metadata(remote.join(".cmux-sync.json")).unwrap().is_symlink());
    std::fs::remove_file(folder.join(".cmux-sync.json")).unwrap();

    // `src/up -> ..` is inside; `leak` climbs out through it.
    std::os::unix::fs::symlink("..", remote.join("src/up")).unwrap();
    std::os::unix::fs::symlink("src/up/../../outside", remote.join("leak")).unwrap();
    let (ok, pulled) = pull(&socket, &folder, &remote);
    assert!(ok, "{pulled}");
    assert_eq!(std::fs::read_link(folder.join("src/up")).unwrap(), Path::new(".."));
    assert!(std::fs::symlink_metadata(folder.join("leak")).is_err(), "{pulled}");
    assert_eq!(skipped_by_path(&pulled)["leak"], "a symlink (to a place outside the folder)");
}

/// A link the machine changed is never written through: this Mac's file at
/// its path stays here and is named, and the machine's file it now names
/// keeps its bytes.
#[test]
fn a_file_is_never_written_through_a_link_the_machine_changed() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("site");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("a.txt"), "a\n").unwrap();
    std::os::unix::fs::symlink("a.txt", folder.join("link")).unwrap();
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs(&socket, &home);
    let remote = home.join("work/site");
    let (ok, summary, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{summary}");

    std::fs::write(remote.join("secret.txt"), "secret\n").unwrap();
    std::fs::remove_file(remote.join("link")).unwrap();
    std::os::unix::fs::symlink("secret.txt", remote.join("link")).unwrap();
    std::fs::remove_file(folder.join("link")).unwrap();
    std::fs::write(folder.join("link"), "mine\n").unwrap();

    let (ok, pushed, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{pushed}");
    assert_eq!(std::fs::read_to_string(remote.join("secret.txt")).unwrap(), "secret\n");
    assert_eq!(std::fs::read_link(remote.join("link")).unwrap(), Path::new("secret.txt"));
    assert_eq!(
        skipped_by_path(&pushed)["link"],
        "a symlink (something else is at its path on the other side)",
        "{pushed}"
    );
    // Nor into a folder the machine made a link: `sub/b.txt` stays here.
    std::fs::create_dir_all(folder.join("sub")).unwrap();
    std::fs::write(folder.join("sub/b.txt"), "b\n").unwrap();
    std::fs::create_dir_all(remote.join("elsewhere")).unwrap();
    std::os::unix::fs::symlink("elsewhere", remote.join("sub")).unwrap();
    let (ok, into, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{into}");
    assert!(!remote.join("elsewhere/b.txt").exists(), "{into}");
    assert!(skipped_by_path(&into).contains_key("sub/b.txt"), "{into}");
    // Nor the push after it, whose record no longer holds the link.
    let (ok, again, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{again}");
    assert_eq!(std::fs::read_to_string(remote.join("secret.txt")).unwrap(), "secret\n");
    assert_eq!(std::fs::read_link(remote.join("link")).unwrap(), Path::new("secret.txt"));
}

/// With no-follow writes (`fs-write-nofollow-v1`) a push asks each folder's
/// listing what is in the way instead of an `fs.stat` a file, and a link the
/// machine made after that listing still stops the file: the machine refuses
/// it at its path (`fs.symlink_in_path`), and a folder on the way is a link.
#[test]
fn a_no_follow_push_never_writes_through_a_link_the_machine_changed() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("site");
    std::fs::create_dir_all(folder.join("sub")).unwrap();
    std::fs::write(folder.join("a.txt"), "a\n").unwrap();
    std::fs::write(folder.join("sub/b.txt"), "b\n").unwrap();
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs_advertising(
        &socket,
        &home,
        &["fs-v1", "fs-symlink-v1", "fs-write-deflate-v1", "fs-write-nofollow-v1"],
    );
    let remote = home.join("work/site");
    let (ok, summary, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{summary}");
    assert_eq!(std::fs::read_to_string(remote.join("sub/b.txt")).unwrap(), "b\n");

    std::fs::write(remote.join("secret.txt"), "secret\n").unwrap();
    std::fs::remove_file(remote.join("a.txt")).unwrap();
    std::os::unix::fs::symlink("secret.txt", remote.join("a.txt")).unwrap();
    std::fs::remove_dir_all(remote.join("sub")).unwrap();
    std::fs::create_dir_all(remote.join("elsewhere")).unwrap();
    std::os::unix::fs::symlink("elsewhere", remote.join("sub")).unwrap();
    std::fs::write(folder.join("a.txt"), "mine\n").unwrap();
    std::fs::write(folder.join("sub/b.txt"), "mine\n").unwrap();
    std::fs::write(folder.join("new.txt"), "new\n").unwrap();
    // A link to an empty folder, listed as a folder: it is asked again and
    // stays, never deleted as an empty folder in the way.
    std::fs::create_dir_all(remote.join("hollow")).unwrap();
    std::os::unix::fs::symlink("hollow", remote.join("c.txt")).unwrap();
    std::fs::write(folder.join("c.txt"), "c\n").unwrap();

    let (ok, pushed, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{pushed}");
    assert_eq!(std::fs::read_to_string(remote.join("secret.txt")).unwrap(), "secret\n");
    assert_eq!(std::fs::read_link(remote.join("a.txt")).unwrap(), Path::new("secret.txt"));
    assert!(!remote.join("elsewhere/b.txt").exists(), "{pushed}");
    let skipped = skipped_by_path(&pushed);
    assert!(skipped.contains_key("a.txt") && skipped.contains_key("sub/b.txt"), "{pushed}");
    assert_eq!(std::fs::read_link(remote.join("c.txt")).unwrap(), Path::new("hollow"));
    assert!(skipped.contains_key("c.txt"), "{pushed}");
    assert_eq!(std::fs::read_to_string(remote.join("new.txt")).unwrap(), "new\n");
}

/// A machine link at or above the hooks folder never comes back: through it
/// git would run hooks the machine chose.
#[test]
fn a_pull_never_brings_back_a_link_over_the_hooks_folder() {
    let (_root, _sockets, repo, remote, socket) = pushed_repo();
    git(&repo, &["config", "core.hooksPath", "entry/hooks"]);
    std::fs::create_dir_all(remote.join("payload/hooks")).unwrap();
    std::fs::write(remote.join("payload/hooks/reference-transaction"), "#!/bin/sh\necho x\n")
        .unwrap();
    std::os::unix::fs::symlink("payload", remote.join("entry")).unwrap();
    let (_, answer) = pull(&socket, &repo, &remote);
    assert!(std::fs::symlink_metadata(repo.join("entry")).is_err(), "{answer}");
}

/// A link through a link that sorts after it still arrives on the first
/// push: it waits for the pass after the one that makes its target.
#[test]
fn a_chain_of_links_arrives_on_the_first_push() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("site");
    std::fs::create_dir_all(folder.join("src")).unwrap();
    std::fs::write(folder.join("src/a.txt"), "a\n").unwrap();
    std::os::unix::fs::symlink("z/a.txt", folder.join("a")).unwrap();
    std::os::unix::fs::symlink("src", folder.join("z")).unwrap();
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs(&socket, &home);
    let remote = home.join("work/site");
    let (ok, summary, _) = push_output(&socket, &folder, &remote);
    assert!(ok, "{summary}");
    assert_eq!(std::fs::read_link(remote.join("a")).unwrap(), Path::new("z/a.txt"), "{summary}");
    assert_eq!(std::fs::read_to_string(remote.join("a")).unwrap(), "a\n");
    assert_eq!(summary["skipped"], json!(0), "{summary}");
}

/// The files below `dir`'s git object store, by path relative to it.
fn object_files(objects: &Path) -> Vec<String> {
    let mut found: Vec<String> = files_below(objects)
        .into_iter()
        .filter_map(|(path, _)| {
            path.strip_prefix(objects).ok().and_then(Path::to_str).map(str::to_string)
        })
        .collect();
    found.sort();
    found
}

fn is_loose(relative: &str) -> bool {
    relative.len() == 41 && relative.as_bytes().get(2) == Some(&b'/')
}

/// A repository's loose objects arrive as one pack, its own packs as they
/// are; this Mac's repository is not changed; the copy passes `git fsck`
/// and shows the same status. A push of an unchanged repository writes
/// nothing, one after a commit one small pack, and a pull right after a
/// push brings nothing back.
#[test]
fn loose_objects_go_as_a_pack_and_the_copy_is_a_valid_repository() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let repo = dirty_repo(&root);
    // Some history packed here, more loose on top of it.
    git(&repo, &["repack", "-q", "-a", "-d"]);
    for index in 0..40 {
        std::fs::write(repo.join(format!("src/f{index}.txt")), format!("{index}\n")).unwrap();
    }
    git(&repo, &["add", "src"]);
    git(&repo, &["commit", "-q", "-m", "loose"]);
    let objects_here = repo.join(".git/objects");
    let before = files_below(&objects_here);
    let local_packs: Vec<String> =
        object_files(&objects_here).into_iter().filter(|path| path.starts_with("pack/")).collect();
    assert!(object_files(&objects_here).iter().any(|path| is_loose(path)), "no loose objects");

    let home = root.join("home");
    std::fs::create_dir_all(home.join("work")).unwrap();
    let sockets = tempfile::Builder::new().prefix("cs").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("fs.sock");
    serve_fs(&socket, &home);
    let remote = home.join("work/app");

    let summary = push(&socket, &repo, &remote);
    assert!(summary["written"].as_u64().unwrap_or(0) > 0, "{summary}");
    assert_eq!(files_below(&objects_here), before, "the push changed this Mac's objects");
    let pushed = object_files(&remote.join(".git/objects"));
    assert!(!pushed.iter().any(|path| is_loose(path)), "loose objects went: {pushed:?}");
    for pack in &local_packs {
        assert!(pushed.contains(pack), "{pack} did not go whole: {pushed:?}");
    }
    let made: Vec<&String> = pushed
        .iter()
        .filter(|path| path.ends_with(".pack") && !local_packs.contains(path))
        .collect();
    assert_eq!(made.len(), 1, "{pushed:?}");
    // A made pack is the owner's alone, whatever its objects' modes were.
    for made in &made {
        let path = remote.join(".git/objects").join(made);
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "{made} is {mode:o}");
    }
    git(&remote, &["fsck", "--full", "--no-dangling"]);
    let status = ["status", "--porcelain=v2", "--branch"];
    assert_eq!(git(&remote, &status), git(&repo, &status));
    assert_eq!(git(&remote, &["rev-parse", "HEAD"]), git(&repo, &["rev-parse", "HEAD"]));
    assert_eq!(git(&remote, &["stash", "list"]), git(&repo, &["stash", "list"]));

    // Unchanged: nothing goes, the made pack stays.
    let again = push(&socket, &repo, &remote);
    assert_eq!(again["written"].as_u64(), Some(0), "{again}");
    assert_eq!(object_files(&remote.join(".git/objects")), pushed);

    // A pull right after the push brings nothing back and changes nothing.
    let (ok, pulled) = pull(&socket, &repo, &remote);
    assert!(ok, "{pulled}");
    assert_eq!(pulled["written"].as_u64(), Some(0), "{pulled}");
    assert_eq!(files_below(&objects_here), before, "the pull changed this Mac's objects");

    // A commit: the earlier pack stays, one small new one goes with it.
    std::fs::write(repo.join("src/new.txt"), "new\n").unwrap();
    git(&repo, &["add", "src/new.txt"]);
    git(&repo, &["commit", "-q", "-m", "new"]);
    let after_commit = push(&socket, &repo, &remote);
    let now = object_files(&remote.join(".git/objects"));
    for pack in &pushed {
        assert!(now.contains(pack), "{pack} was sent again or deleted: {now:?}");
    }
    let local_pack_count = local_packs.iter().filter(|path| path.ends_with(".pack")).count();
    assert_eq!(now.iter().filter(|path| path.ends_with(".pack")).count(), local_pack_count + 2);
    let objects_written = after_commit["written"].as_u64().unwrap_or(0);
    assert!(objects_written <= 10, "{after_commit}");
    git(&remote, &["fsck", "--full", "--no-dangling"]);
    assert_eq!(git(&remote, &status), git(&repo, &status));
    assert_eq!(git(&remote, &["rev-parse", "HEAD"]), git(&repo, &["rev-parse", "HEAD"]));

    // gc here packs everything: the made packs go, the repository's pack
    // takes their place, and the copy is still whole.
    git(&repo, &["gc", "-q", "--prune=now"]);
    push(&socket, &repo, &remote);
    let after_gc = object_files(&remote.join(".git/objects"));
    for pack in now.iter().filter(|path| path.ends_with(".pack")) {
        assert!(!after_gc.contains(pack), "{pack} stayed after gc: {after_gc:?}");
    }
    git(&remote, &["fsck", "--full", "--no-dangling"]);
    assert_eq!(git(&remote, &status), git(&repo, &status));
}

/// Serves `fs.*` like [`serve_fs`], waiting `latency` before each answer (a
/// link's round trip), and counts the requests, the `fs.write`s and the
/// bytes sent.
fn serve_fs_counted(
    socket: &Path,
    home: &Path,
    latency: std::time::Duration,
) -> &'static [std::sync::atomic::AtomicU64; 3] {
    use std::sync::atomic::Ordering::Relaxed;
    let listener = UnixListener::bind(socket).unwrap();
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.to_path_buf()]))));
    let counts: &'static [std::sync::atomic::AtomicU64; 3] = Box::leak(Box::default());
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            std::thread::spawn(move || {
                let mut writer = connection.try_clone().unwrap();
                for line in BufReader::new(connection).lines() {
                    let Ok(line) = line else { return };
                    let [requests, writes, bytes] = counts;
                    requests.fetch_add(1, Relaxed);
                    bytes.fetch_add(line.len() as u64 + 1, Relaxed);
                    let request: Value = serde_json::from_str(&line).unwrap();
                    if request["cmd"] == "fs.write" {
                        writes.fetch_add(1, Relaxed);
                    }
                    std::thread::sleep(latency);
                    let id = request["id"].clone();
                    let cmd = request["cmd"].as_str().unwrap_or_default().to_string();
                    let mut text =
                        stream::answer(&id, service.call("local", &cmd, request)).to_string();
                    text.push('\n');
                    if writer.write_all(text.as_bytes()).is_err() {
                        return;
                    }
                }
            });
        }
    });
    counts
}

/// A push of a repository with many loose objects through a link with a
/// round trip of `CMUX_SYNC_BENCH_RTT_MS` (default 20): prints its wall
/// time, requests, `fs.write`s and bytes sent. `cargo test --test link_sync
/// -- --ignored --nocapture loose_object_push_bench`.
#[test]
#[ignore = "a benchmark"]
fn loose_object_push_bench() {
    use std::sync::atomic::Ordering::Relaxed;
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let repo = root.join("app");
    std::fs::create_dir_all(repo.join("src")).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    for commit in 0..10 {
        for index in 0..300 {
            let text = format!("file {index} at commit {commit}\n").repeat(40);
            std::fs::write(repo.join(format!("src/f{index:03}.txt")), text).unwrap();
        }
        git(&repo, &["add", "-A"]);
        git(&repo, &["commit", "-q", "-m", &format!("commit {commit}")]);
    }
    println!("bench local {}", git(&repo, &["count-objects", "-v"]).replace('\n', " "));
    let rtt: u64 = std::env::var("CMUX_SYNC_BENCH_RTT_MS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(20);
    let (_sockets, socket, home) = machine_home(&root);
    let counts = serve_fs_counted(&socket, &home, std::time::Duration::from_millis(rtt));
    let remote = home.join("work/app");
    let started = std::time::Instant::now();
    let summary = push(&socket, &repo, &remote);
    let wall = started.elapsed();
    git(&remote, &["fsck", "--full", "--no-dangling"]);
    println!("bench remote {}", git(&remote, &["count-objects", "-v"]).replace('\n', " "));
    let [requests, writes, bytes] = counts;
    println!(
        "bench rtt_ms={rtt} wall_ms={} requests={} fs_writes={} bytes_sent={} files_written={}",
        wall.as_millis(),
        requests.load(Relaxed),
        writes.load(Relaxed),
        bytes.load(Relaxed),
        summary["written"]
    );
}

/// Loose objects only their owner can read (git under `umask 077` makes
/// them 0400) arrive in a pack only its owner can read, and so does the
/// pack reused after the private ones are gone here.
#[test]
fn a_pack_of_private_objects_is_private() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let repo = dirty_repo(&root);
    let objects_here = repo.join(".git/objects");
    for relative in object_files(&objects_here).into_iter().filter(|path| is_loose(path)) {
        let path = objects_here.join(relative);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
    }
    let (_sockets, socket, home) = machine_home(&root);
    serve_fs(&socket, &home);
    let remote = home.join("work/app");

    push(&socket, &repo, &remote);
    let packs = remote.join(".git/objects/pack");
    let made: Vec<PathBuf> = std::fs::read_dir(&packs)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "pack"))
        .collect();
    assert_eq!(made.len(), 1, "{made:?}");
    for path in made.iter().flat_map(|pack| [pack.clone(), pack.with_extension("idx")]) {
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "{} is {mode:o}", path.display());
    }
    git(&remote, &["fsck", "--full", "--no-dangling"]);

    // An object made public here keeps the kept pack in use; it is sent
    // again (its mode changed nothing on the machine) still owner-only.
    std::fs::write(repo.join("public.txt"), "public\n").unwrap();
    git(&repo, &["add", "public.txt"]);
    push(&socket, &repo, &remote);
    for entry in std::fs::read_dir(&packs).unwrap() {
        let path = entry.unwrap().path();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "{} is {mode:o}", path.display());
    }
}

/// Serves `fs.*` like [`serve_fs`] and counts the connections that wrote a
/// file (not the sync record).
fn serve_fs_counting_writers(
    socket: &Path,
    home: &Path,
) -> &'static std::sync::atomic::AtomicUsize {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let listener = UnixListener::bind(socket).unwrap();
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.to_path_buf()]))));
    let writers: &'static AtomicUsize = Box::leak(Box::default());
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            std::thread::spawn(move || {
                let mut writer = connection.try_clone().unwrap();
                let mut wrote = false;
                for line in BufReader::new(connection).lines() {
                    let Ok(line) = line else { return };
                    let request: Value = serde_json::from_str(&line).unwrap();
                    let path = request["path"].as_str().unwrap_or_default();
                    if request["cmd"] == "fs.write" && !path.ends_with("cmux-sync.json") && !wrote {
                        wrote = true;
                        writers.fetch_add(1, Ordering::SeqCst);
                    }
                    let id = request["id"].clone();
                    let cmd = request["cmd"].as_str().unwrap_or_default().to_string();
                    let mut text =
                        stream::answer(&id, service.call("local", &cmd, request)).to_string();
                    text.push('\n');
                    if writer.write_all(text.as_bytes()).is_err() {
                        return;
                    }
                }
            });
        }
    });
    writers
}

/// Small files go on several connections at once (one with
/// `CMUX_SYNC_PUSH_CONNECTIONS=1`), a big one too, and every file lands as
/// it is here; a second push writes nothing.
#[test]
fn small_files_go_on_several_connections_and_all_land() {
    use std::sync::atomic::Ordering;
    for (connections, least, most) in [("8", 3, 8), ("1", 1, 1)] {
        let root = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(root.path()).unwrap();
        let folder = root.join("many");
        std::fs::create_dir_all(folder.join("deep/er")).unwrap();
        for index in 0..300 {
            let at = if index % 3 == 0 { "deep/er" } else { "." };
            std::fs::write(folder.join(at).join(format!("f{index:03}.txt")), format!("{index}\n"))
                .unwrap();
        }
        let big: Vec<u8> = (0..6 * 1024 * 1024u32).map(|i| (i % 251) as u8).collect();
        std::fs::write(folder.join("big.bin"), &big).unwrap();
        let (_sockets, socket, home) = machine_home(&root);
        let writers = serve_fs_counting_writers(&socket, &home);
        let remote = home.join("work/many");
        let run = || {
            let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
                .env("CMUX_TUI_STATE_DIR", state_of(&socket))
                .env("CMUX_SYNC_PUSH_CONNECTIONS", connections)
                .args(["link", "sync", "push", "--socket"])
                .arg(&socket)
                .arg(&folder)
                .arg(&remote)
                .output()
                .unwrap();
            assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stdout));
            serde_json::from_slice::<Value>(&output.stdout).unwrap()
        };
        let summary = run();
        assert_eq!(summary["written"], json!(301), "{summary}");
        // The big file goes on the push's own connection, the small ones on
        // up to `connections` more.
        let used = writers.load(Ordering::SeqCst);
        assert!(used <= most + 1, "{used} writing connections");
        assert!(used >= least, "{used} writing connections");
        for (path, bytes) in files_below(&folder) {
            let relative = path.strip_prefix(&folder).unwrap();
            assert_eq!(std::fs::read(remote.join(relative)).unwrap(), bytes, "{relative:?}");
        }
        assert_eq!(run()["written"], json!(0));
    }
}

/// A folder the machine turns into a symlink after the push planned it
/// (here: when the first file lands) is never written through: the write
/// into it is skipped and named, and nothing lands where the link points.
#[test]
fn a_folder_turned_into_a_symlink_mid_push_is_not_written_through() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let folder = root.join("site");
    std::fs::create_dir_all(folder.join("sub")).unwrap();
    std::fs::write(folder.join("a.txt"), "a\n").unwrap();
    std::fs::write(folder.join("sub/b.txt"), "b\n").unwrap();
    let (_sockets, socket, home) = machine_home(&root);
    let remote = home.join("work/site");
    let elsewhere = home.join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();

    let listener = UnixListener::bind(&socket).unwrap();
    let service: &'static FsService = Box::leak(Box::new(FsService::new(Roots::new([home]))));
    let swapped: &'static std::sync::atomic::AtomicBool = Box::leak(Box::default());
    let (sub, target) = (remote.join("sub"), elsewhere.clone());
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            let (sub, target) = (sub.clone(), target.clone());
            std::thread::spawn(move || {
                let mut writer = connection.try_clone().unwrap();
                for line in BufReader::new(connection).lines() {
                    let Ok(line) = line else { return };
                    let request: Value = serde_json::from_str(&line).unwrap();
                    let id = request["id"].clone();
                    let cmd = request["cmd"].as_str().unwrap_or_default().to_string();
                    let first_write = cmd == "fs.write"
                        && !swapped.swap(true, std::sync::atomic::Ordering::SeqCst);
                    let reply = stream::answer(&id, service.call("local", &cmd, request));
                    if first_write {
                        std::fs::remove_dir(&sub).unwrap();
                        std::os::unix::fs::symlink(&target, &sub).unwrap();
                    }
                    let mut text = reply.to_string();
                    text.push('\n');
                    if writer.write_all(text.as_bytes()).is_err() {
                        return;
                    }
                }
            });
        }
    });

    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("CMUX_TUI_STATE_DIR", state_of(&socket))
        .env("CMUX_SYNC_PUSH_CONNECTIONS", "1")
        .args(["link", "sync", "push", "--socket"])
        .arg(&socket)
        .arg(&folder)
        .arg(&remote)
        .output()
        .unwrap();
    let summary: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(output.status.success(), "{summary}");
    assert_eq!(std::fs::read_to_string(remote.join("a.txt")).unwrap(), "a\n");
    assert!(!elsewhere.join("b.txt").exists(), "a write went through the symlink: {summary}");
    let named: Vec<&str> = summary["skipped_files"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|entry| entry["path"].as_str())
        .collect();
    assert!(named.contains(&"sub/b.txt"), "{summary}");
}

#[path = "link_sync/git_index.rs"]
mod git_index;
