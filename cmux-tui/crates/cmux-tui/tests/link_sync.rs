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

use cmux_tui_core::fs_ops::{FsService, Roots, stream};
use serde_json::Value;

/// Serves `fs.*` lines on `socket` with the real owner over `home`, one
/// thread per connection, until the test process ends.
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

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"])
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

fn push(socket: &Path, local: &Path, remote: &Path) -> Value {
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
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

/// Every file below `dir`, by path, with its bytes.
fn files_below(dir: &Path) -> Vec<(PathBuf, Vec<u8>)> {
    let mut found = Vec::new();
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
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
