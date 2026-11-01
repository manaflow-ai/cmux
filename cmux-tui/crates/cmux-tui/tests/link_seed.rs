//! `cmux link seed push|clone`: a git folder with a GitHub remote reaches a
//! Cloud machine as a clone plus one bundle of the local diff, and anything
//! else as the streamed copy. The machine side is the real `FsService` and
//! `GitSeedService` behind a socket that answers lines the way the daemon
//! does; "GitHub" is a folder of bare repositories the service clones from
//! (`GitSeedService::with_test_github`).
#![cfg(unix)]

use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

use cmux_tui_core::fs_ops::{FsService, Roots, stream};
use cmux_tui_core::git_seed::{self, GitSeedService};
use serde_json::{Value, json};

const URL: &str = "https://github.com/acme/widget.git";

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"])
        .args(["-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always"])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

/// How the fake machine answers.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Serves {
    Seed,
    /// Another build without `git-seed-v1`.
    CopyOnly,
}

/// One test's world: "GitHub", this Mac's working copy, the machine's home
/// and its socket.
struct World {
    _dir: tempfile::TempDir,
    _sockets: tempfile::TempDir,
    root: PathBuf,
    github: PathBuf,
    work: PathBuf,
    home: PathBuf,
    socket: PathBuf,
    /// `fs.write` requests the machine answered.
    writes: &'static AtomicUsize,
}

impl World {
    fn new(serves: Serves) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        let github = root.join("github");
        let bare = github.join("acme/widget.git");
        std::fs::create_dir_all(&bare).unwrap();
        git(&bare, &["init", "-q", "--bare"]);
        git(&bare, &["config", "uploadpack.allowFilter", "true"]);
        git(&bare, &["config", "uploadpack.allowAnySHA1InWant", "true"]);
        let work = root.join("widget");
        git(&root, &["clone", "-q", &format!("file://{}", bare.display()), "widget"]);
        write(&work.join("README.md"), "widget\n");
        write(&work.join("src/lib.rs"), "pub fn one() {}\n");
        write(&work.join(".gitignore"), "node_modules/\n");
        git(&work, &["add", "-A"]);
        git(&work, &["commit", "-q", "-m", "first"]);
        git(&work, &["push", "-q", "origin", "HEAD:main"]);
        git(&work, &["branch", "-q", "--set-upstream-to=origin/main"]);
        git(&work, &["remote", "set-url", "origin", URL]);
        git(
            &work,
            &[
                "config",
                &format!("url.file://{}/.insteadOf", github.display()),
                "https://github.com/",
            ],
        );
        let home = root.join("home");
        std::fs::create_dir_all(home.join("work")).unwrap();
        let sockets = tempfile::Builder::new().prefix("ls").tempdir_in("/tmp").unwrap();
        let socket = sockets.path().join("m.sock");
        let writes = serve(&socket, &home, &github, serves);
        Self { _dir: dir, _sockets: sockets, root, github, work, home, socket, writes }
    }

    fn remote(&self, name: &str) -> PathBuf {
        self.home.join("work").join(name)
    }

    /// `cmux link seed ARGS`: exit status, its answer line, its stderr lines.
    fn seed(&self, args: &[&str]) -> (bool, Value, Vec<Value>) {
        let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .env("CMUX_TUI_STATE_DIR", self.root.join("state"))
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .args(["link", "seed"])
            .args(args)
            .output()
            .unwrap();
        let answer = serde_json::from_slice(&output.stdout).unwrap_or_else(|_| {
            panic!(
                "one JSON answer on stdout: {}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            )
        });
        let progress = String::from_utf8_lossy(&output.stderr)
            .lines()
            .filter_map(|line| serde_json::from_str(line).ok())
            .collect();
        (output.status.success(), answer, progress)
    }

    fn push(&self, local: &Path, remote: &Path, since_last: bool) -> (bool, Value, Vec<Value>) {
        let mut args = vec!["push", "--socket", self.socket.to_str().unwrap()];
        args.extend([local.to_str().unwrap(), remote.to_str().unwrap()]);
        if since_last {
            args.push("--since-last");
        }
        self.seed(&args)
    }
}

/// Serves `fs.*` and `git.seed.*` lines (and `identify`) on `socket`, one
/// thread per connection, until the test process ends.
fn serve(socket: &Path, home: &Path, github: &Path, serves: Serves) -> &'static AtomicUsize {
    let listener = UnixListener::bind(socket).unwrap();
    let roots = Roots::new([home.to_path_buf()]);
    let fs: &'static FsService = Box::leak(Box::new(FsService::new(roots.clone())));
    let seed: &'static GitSeedService =
        Box::leak(Box::new(GitSeedService::with_test_github(roots, github)));
    let writes: &'static AtomicUsize = Box::leak(Box::default());
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
                    let reply = if cmd == "identify" {
                        let capabilities = match serves {
                            Serves::Seed => json!(["fs-v1", "git-seed-v1"]),
                            Serves::CopyOnly => json!(["fs-v1"]),
                        };
                        json!({"id": id, "ok": true, "data": {"capabilities": capabilities,
                               "build_id": "machine-build", "session_id": "machine-a"}})
                    } else if git_seed::frame_command(&line).is_some() {
                        if serves == Serves::Seed {
                            git_seed::answer_line(Some(seed), true, &line)
                        } else {
                            json!({"id": id, "ok": false, "error_code": "unknown_command",
                                   "error": "unknown command"})
                        }
                    } else {
                        if cmd == "fs.write" {
                            writes.fetch_add(1, Ordering::SeqCst);
                        }
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
    writes
}

/// Every file below `root` but `.git`, by relative path.
fn files(root: &Path) -> std::collections::BTreeMap<String, String> {
    let mut found = std::collections::BTreeMap::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).unwrap() {
            let entry = entry.unwrap();
            if entry.file_name() == ".git" {
                continue;
            }
            if entry.file_type().unwrap().is_dir() {
                stack.push(entry.path());
            } else {
                let relative = entry.path().strip_prefix(root).unwrap().display().to_string();
                found.insert(relative, std::fs::read_to_string(entry.path()).unwrap_or_default());
            }
        }
    }
    found
}

#[test]
fn a_full_seed_then_deltas_carry_the_working_state() {
    let w = World::new(Serves::Seed);
    write(&w.work.join("src/lib.rs"), "pub fn one() {}\npub fn two() {}\n");
    git(&w.work, &["commit", "-q", "-am", "unpushed"]);
    write(&w.work.join("README.md"), "staged\n");
    git(&w.work, &["add", "README.md"]);
    write(&w.work.join("notes/todo.md"), "untracked\n");
    write(&w.work.join(".env"), "TOKEN=secret\n");
    write(&w.work.join("node_modules/x/index.js"), "ignored\n");
    let remote = w.remote("widget");

    let (ok, seeded, progress) = w.push(&w.work, &remote, false);
    assert!(ok, "{seeded}");
    assert_eq!(seeded["mode"], json!("seed"), "{seeded}");
    assert_eq!(seeded["unchanged"], json!(false));
    assert!(seeded["bundle_bytes"].as_u64().unwrap() > 0, "{seeded}");
    assert_eq!(seeded["head"], json!(git(&w.work, &["rev-parse", "HEAD"])));
    assert_eq!(seeded["skipped_files"][0]["path"], json!(".env"), "{seeded}");
    assert_eq!(seeded["skipped_files"][0]["kind"], json!("secret"));
    assert!(seeded.get("fallback_code").is_none(), "{seeded}");
    let phases: Vec<&str> =
        progress.iter().filter_map(|line| line["progress"]["phase"].as_str()).collect();
    assert_eq!(phases.first(), Some(&"upload"), "{progress:?}");
    // The machine has the branch at HEAD, the staged file and the tree.
    assert_eq!(git(&remote, &["rev-parse", "HEAD"]), git(&w.work, &["rev-parse", "HEAD"]));
    assert_eq!(git(&remote, &["symbolic-ref", "HEAD"]), "refs/heads/main");
    assert_eq!(git(&remote, &["diff", "--cached", "--name-only"]), "README.md");
    let mut expected = files(&w.work);
    expected.retain(|path, _| path != ".env" && !path.starts_with("node_modules/"));
    assert_eq!(files(&remote), expected);
    // No bundle is left beside the folder.
    let left: Vec<_> = std::fs::read_dir(w.home.join("work"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(left, ["widget"], "{left:?}");

    // A change since: only it goes.
    write(&w.work.join("notes/todo.md"), "untracked, edited\n");
    let (ok, delta, _) = w.push(&w.work, &remote, true);
    assert!(ok, "{delta}");
    assert_eq!(delta["mode"], json!("delta"), "{delta}");
    assert!(delta["bundle_bytes"].as_u64().unwrap() > 0, "{delta}");
    assert_eq!(
        std::fs::read_to_string(remote.join("notes/todo.md")).unwrap(),
        "untracked, edited\n"
    );

    // Nothing changed: nothing is uploaded.
    let before = w.writes.load(Ordering::SeqCst);
    let (ok, same, _) = w.push(&w.work, &remote, true);
    assert!(ok, "{same}");
    assert_eq!(same["mode"], json!("delta"));
    assert_eq!(same["unchanged"], json!(true), "{same}");
    assert_eq!(same["bundle_bytes"], json!(0));
    assert_eq!(w.writes.load(Ordering::SeqCst), before, "an unchanged delta uploaded");
}

#[test]
fn since_last_never_copies_and_says_why() {
    let w = World::new(Serves::Seed);
    let remote = w.remote("widget");
    let (ok, none, _) = w.push(&w.work, &remote, true);
    assert!(!ok);
    assert_eq!(none["error_code"], json!("seed.no_previous"), "{none}");
    assert!(!remote.exists(), "--since-last copied");

    let (ok, seeded, _) = w.push(&w.work, &remote, false);
    assert!(ok, "{seeded}");
    // A file changed on the machine since the seed.
    write(&remote.join("README.md"), "the agent was here\n");
    write(&w.work.join("src/lib.rs"), "changed here\n");
    let (ok, changed, _) = w.push(&w.work, &remote, true);
    assert!(!ok);
    assert_eq!(changed["error_code"], json!("seed.machine_changed"), "{changed}");
    // The folder on the machine is no seed of this repository any more.
    std::fs::remove_dir_all(remote.join(".git")).unwrap();
    let (ok, mismatch, _) = w.push(&w.work, &remote, true);
    assert!(!ok);
    assert_eq!(mismatch["error_code"], json!("seed.since_mismatch"), "{mismatch}");
}

#[test]
fn folders_that_cannot_be_seeded_are_copied_and_say_why() {
    let w = World::new(Serves::Seed);
    // Not git.
    let plain = w.root.join("plain");
    write(&plain.join("a.txt"), "a\n");
    let (ok, copied, progress) = w.push(&plain, &w.remote("plain"), false);
    assert!(ok, "{copied}");
    assert_eq!(copied["mode"], json!("copy"));
    assert_eq!(copied["fallback_code"], json!("not_git"), "{copied}");
    // The copy says why before its own lines, for the card's live row.
    assert_eq!(
        progress.first().map(|line| &line["progress"]),
        Some(&json!({"phase": "copy", "fallback_code": "not_git"})),
        "{progress:?}"
    );
    assert!(copied["fallback_why"].as_str().is_some_and(|why| !why.is_empty()));
    assert_eq!(copied["copy"]["written"], json!(1), "{copied}");
    assert_eq!(std::fs::read_to_string(w.remote("plain").join("a.txt")).unwrap(), "a\n");
    // A copy's --since-last re-pushes it, incrementally.
    write(&plain.join("b.txt"), "b\n");
    let (ok, again, _) = w.push(&plain, &w.remote("plain"), true);
    assert!(ok, "{again}");
    assert_eq!(again["mode"], json!("copy"), "{again}");
    assert_eq!(
        (again["copy"]["written"].clone(), again["copy"]["unchanged"].clone()),
        (json!(1), json!(1))
    );
    assert!(again.get("fallback_code").is_none());

    // Not GitHub.
    git(&w.work, &["remote", "set-url", "origin", "https://gitlab.com/acme/widget.git"]);
    let (ok, gitlab, _) = w.push(&w.work, &w.remote("gitlab"), false);
    assert!(ok, "{gitlab}");
    assert_eq!(gitlab["mode"], json!("copy"));
    assert_eq!(gitlab["fallback_code"], json!("not_github"), "{gitlab}");
    assert!(w.remote("gitlab").join(".git").is_dir());
}

#[test]
fn a_repository_the_machine_cannot_clone_is_copied_and_leaves_nothing_behind() {
    let w = World::new(Serves::Seed);
    // "GitHub" no longer has it.
    std::fs::rename(w.github.join("acme"), w.github.join("gone")).unwrap();
    let remote = w.remote("widget");
    let (ok, copied, _) = w.push(&w.work, &remote, false);
    assert!(ok, "{copied}");
    assert_eq!(copied["mode"], json!("copy"), "{copied}");
    assert_eq!(copied["fallback_code"], json!("seed.clone_failed"), "{copied}");
    assert_eq!(std::fs::read_to_string(remote.join("README.md")).unwrap(), "widget\n");
}

#[test]
fn a_machine_without_git_seed_gets_the_copy() {
    let w = World::new(Serves::CopyOnly);
    let remote = w.remote("widget");
    let (ok, copied, _) = w.push(&w.work, &remote, false);
    assert!(ok, "{copied}");
    assert_eq!(copied["mode"], json!("copy"));
    assert_eq!(copied["fallback_code"], json!("machine_outdated"), "{copied}");
    let (ok, clone, _) =
        w.seed(&["clone", "--socket", w.socket.to_str().unwrap(), "--repo", "acme/widget", "/x/y"]);
    assert!(!ok);
    assert_eq!(clone["error_code"], json!("machine_outdated"), "{clone}");
}

#[test]
fn seed_clone_checks_out_a_repository_with_no_folder_here() {
    let w = World::new(Serves::Seed);
    let remote = w.remote("cloned");
    let socket = w.socket.to_str().unwrap();
    let (ok, cloned, _) =
        w.seed(&["clone", "--socket", socket, "--repo", "acme/widget", remote.to_str().unwrap()]);
    assert!(ok, "{cloned}");
    assert_eq!(cloned["mode"], json!("clone"));
    assert_eq!(cloned["head"], json!(git(&w.work, &["rev-parse", "HEAD"])), "{cloned}");
    assert_eq!(std::fs::read_to_string(remote.join("README.md")).unwrap(), "widget\n");
    let missing = w.remote("missing");
    let (ok, failed, _) =
        w.seed(&["clone", "--socket", socket, "--repo", "acme/nothing", missing.to_str().unwrap()]);
    assert!(!ok);
    assert_eq!(failed["error_code"], json!("seed.clone_failed"), "{failed}");
}
