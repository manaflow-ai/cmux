#![cfg(unix)]
//! `git.fingerprint` over a real session socket. A diff tab asks it each 4 s while a person
//! looks at it, to know that the diff it shows is old. Before this read, the app asked a whole
//! `git.diff` with each patch and made a hash of the reply.
//!
//! - it changes when that reply changes: [`today`] is that reply, and each step of a test says
//!   whether the reply and the fingerprint moved;
//! - a touch (a new mtime, the same bytes) is no change;
//! - it starts fewer git children than that `git.diff`, and none that makes a patch or counts
//!   lines;
//! - the daemon reads no file of a work tree at rest, and one file after one edit: the reply
//!   says how many files and bytes the daemon read to make it;
//! - a long list has a bound: 8192 files and 256 MiB a read, no file above 64 MiB. A file past
//!   a bound counts by its stat entry and is never read.
//!
//! The git on `PATH` is a stand-in that writes its arguments to a log named as its working
//! directory, and then is the real git.

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::ffi::OsStr;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

struct Fixture {
    dir: PathBuf,
    real: PathBuf,
}

/// The real git, as an absolute path, before the stand-in goes on `PATH`.
fn real_git() -> PathBuf {
    let path = std::env::var_os("PATH").expect("PATH is set");
    std::env::split_paths(&path)
        .map(|dir| dir.join("git"))
        .find(|candidate| candidate.is_file())
        .expect("git is on PATH")
}

/// One directory for this test process, with a stand-in `git` first on `PATH`.
fn fixture() -> &'static Fixture {
    static FIXTURE: OnceLock<Fixture> = OnceLock::new();
    FIXTURE.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("gfinger-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let bin = dir.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::create_dir_all(dir.join("log")).unwrap();
        let dir = std::fs::canonicalize(&dir).unwrap();
        let real = real_git();
        let script = format!(
            "#!/bin/sh\n\
             echo \"$*\" >> \"{log}/$(basename \"$PWD\")\"\n\
             exec \"{real}\" \"$@\"\n",
            log = dir.join("log").display(),
            real = real.display(),
        );
        let shim = dir.join("bin").join("git");
        std::fs::write(&shim, script).unwrap();
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut path = dir.join("bin").into_os_string();
        if let Some(old) = std::env::var_os("PATH") {
            path.push(":");
            path.push(old);
        }
        // Every test takes the fixture before it starts a daemon or a child,
        // and this runs once, under the cell's lock.
        unsafe { std::env::set_var("PATH", path) };
        Fixture { dir, real }
    })
}

fn unique(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}{}", NEXT.fetch_add(1, Ordering::Relaxed))
}

/// Runs the real git in `directory`, apart from the host's git config.
fn git<S: AsRef<OsStr> + std::fmt::Debug>(directory: &Path, arguments: &[S]) {
    let ended = Command::new(&fixture().real)
        .arg("-C")
        .arg(directory)
        .args(["-c", "maintenance.auto=false", "-c", "user.name=t", "-c", "user.email=t@e.test"])
        .args(["-c", "protocol.file.allow=always", "-c", "advice.detachedHead=false"])
        .args(arguments)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success();
    assert!(ended, "git {arguments:?} failed in {directory:?}");
}

/// A commit that writes `text` to `file`.
fn commit(repo: &Path, file: &str, text: &str) {
    std::fs::write(repo.join(file), text).unwrap();
    git(repo, &["add", file]);
    git(repo, &["commit", "--quiet", "-m", file]);
}

/// A new clone of a new origin with `a.txt`, `b.txt` and a file of 6000 lines, on `main` with
/// the upstream `origin/main`. It has a name of its own: the name of its log of git children.
fn fresh_clone() -> PathBuf {
    let dir = fixture().dir.join(unique("w"));
    let origin = dir.join("origin");
    std::fs::create_dir_all(&origin).unwrap();
    git(&origin, &["init", "--quiet", "--initial-branch=main"]);
    commit(&origin, "a.txt", "one\ntwo\n");
    commit(&origin, "b.txt", "two\n");
    commit(&origin, "long.txt", &long_text('a', 'a'));
    let name = unique("c");
    git(&dir, &["clone", "--quiet", &origin.to_string_lossy(), &name]);
    dir.join(name)
}

/// 6000 lines of 60 bytes of `fill`; the last line starts with `last`. A change of each line
/// is a patch of 2 times 360 000 bytes, above the 262 144 bytes that `git.diff` keeps of one
/// file's patch.
fn long_text(fill: char, last: char) -> String {
    let line = fill.to_string().repeat(59) + "\n";
    let mut text = line.repeat(5999);
    text.push(last);
    text.push_str(&fill.to_string().repeat(58));
    text.push('\n');
    text
}

/// The git children that ran in `directory` since [`forget_children`].
fn children(directory: &Path) -> Vec<String> {
    let name = directory.file_name().unwrap();
    let log = std::fs::read_to_string(fixture().dir.join("log").join(name)).unwrap_or_default();
    log.lines().map(str::to_owned).collect()
}

fn forget_children(directory: &Path) {
    let name = directory.file_name().unwrap();
    let _ = std::fs::remove_file(fixture().dir.join("log").join(name));
}

/// The children whose arguments have the word `word`.
fn with_word<'a>(children: &'a [String], word: &str) -> Vec<&'a String> {
    children.iter().filter(|line| line.split(' ').any(|argument| argument == word)).collect()
}

/// Gives `file` the mtime `time` and keeps its bytes.
fn set_mtime(file: &Path, time: SystemTime) {
    std::fs::File::options().write(true).open(file).unwrap().set_modified(time).unwrap();
}

fn mtime(file: &Path) -> SystemTime {
    std::fs::metadata(file).unwrap().modified().unwrap()
}

struct Client {
    stream: BufReader<UnixStream>,
    next: u64,
}

impl Client {
    /// A client of a new daemon on a socket of its own.
    fn of_a_new_daemon() -> Self {
        let name = unique("d");
        let socket = fixture().dir.join(format!("{name}.sock"));
        let mux = Mux::new(
            format!("git-fingerprint-{}-{name}", std::process::id()),
            SurfaceOptions::default(),
        );
        server::serve(mux.clone(), Some(socket.clone())).unwrap();
        // The daemon lives as long as the test process.
        std::mem::forget(mux);
        let stream = UnixStream::connect(&socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        Self { stream: BufReader::new(stream), next: 0 }
    }

    /// The whole reply to one read `operation` of `directory` in `scope`.
    fn ask(&mut self, operation: &str, directory: &Path, scope: &str, patch: bool) -> Value {
        self.next += 1;
        let id = format!("r{}", self.next);
        let mut params =
            json!({"path": directory, "machine": "current", "session": "current", "scope": scope});
        if patch {
            params["include_patch"] = json!(true);
        }
        let request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
        writeln!(self.stream.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.stream.read_line(&mut line).unwrap(), 0, "closed before {id}");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == id {
                return reply;
            }
        }
    }

    /// The fingerprint of `directory` in `scope`: 64 hex digits.
    fn fingerprint(&mut self, directory: &Path, scope: &str) -> String {
        self.read(directory, scope).fingerprint
    }

    /// One `git.fingerprint` of `directory` in `scope`, with what the daemon read for it.
    fn read(&mut self, directory: &Path, scope: &str) -> Read {
        let reply = self.ask("git.fingerprint", directory, scope, false);
        assert_eq!(reply["ok"], true, "git.fingerprint in scope {scope}: {reply}");
        let fingerprint = reply["result"]["fingerprint"].as_str().unwrap_or_default().to_owned();
        assert!(
            fingerprint.len() == 64 && fingerprint.bytes().all(|byte| byte.is_ascii_hexdigit()),
            "git.fingerprint in scope {scope} is not 64 hex digits: {reply}"
        );
        let count = |name: &str| {
            reply["result"][name].as_u64().unwrap_or_else(|| panic!("no {name} in {reply}"))
        };
        Read { fingerprint, files: count("files_read"), bytes: count("bytes_read") }
    }

    /// What the app made its hash of before `git.fingerprint`: the result of a `git.diff` of
    /// `directory` in `scope` with each patch.
    fn today(&mut self, directory: &Path, scope: &str) -> Value {
        let reply = self.ask("git.diff", directory, scope, true);
        assert_eq!(reply["ok"], true, "git.diff in scope {scope}: {reply}");
        reply["result"].clone()
    }
}

/// One `git.fingerprint`: the 64 digits, and the files and the bytes of file content that the
/// daemon read to make them.
#[derive(Debug)]
struct Read {
    fingerprint: String,
    files: u64,
    bytes: u64,
}

/// The time after which a hash that the daemon keeps is no more "racy": the daemon reads a
/// file again while its last change is less than 2 s before the read.
fn wait_until_the_files_are_settled() {
    std::thread::sleep(Duration::from_millis(2300));
}

/// One step of a test: what `git.diff` with each patch says and the fingerprint, in a scope.
struct Seen {
    today: Value,
    fingerprint: String,
}

fn see(client: &mut Client, directory: &Path, scope: &str) -> Seen {
    Seen {
        today: client.today(directory, scope),
        fingerprint: client.fingerprint(directory, scope),
    }
}

#[test]
fn git_fingerprint_stays_when_files_get_a_new_mtime_and_the_same_bytes() {
    let repo = fresh_clone();
    let mut client = Client::of_a_new_daemon();
    std::fs::write(repo.join("a.txt"), "one\nTWO\n").unwrap();
    std::fs::write(repo.join("new.txt"), "not tracked\n").unwrap();
    for scope in ["uncommitted", "unstaged", "branch"] {
        let before = see(&mut client, &repo, scope);
        let later = SystemTime::now() + Duration::from_secs(5);
        // A changed file, a file with no change, and a file that git does not track.
        for file in ["a.txt", "b.txt", "new.txt"] {
            set_mtime(&repo.join(file), later);
        }
        let after = see(&mut client, &repo, scope);
        assert_eq!(before.today, after.today, "{scope}: a touch changed the reply of git.diff");
        assert_eq!(
            before.fingerprint, after.fingerprint,
            "{scope}: a touch with the same bytes changed the fingerprint"
        );
    }
}

#[test]
fn git_fingerprint_moves_when_bytes_change_and_the_size_and_the_mtime_stay() {
    let repo = fresh_clone();
    let mut client = Client::of_a_new_daemon();
    std::fs::write(repo.join("a.txt"), "one\nTWO\n").unwrap();
    std::fs::write(repo.join("new.txt"), "not tracked\n").unwrap();
    for scope in ["uncommitted", "unstaged", "branch"] {
        // A tracked file: the same count of bytes, and the mtime that it had.
        let before = see(&mut client, &repo, scope);
        let old = mtime(&repo.join("a.txt"));
        std::fs::write(repo.join("a.txt"), "one\nTwo\n").unwrap();
        set_mtime(&repo.join("a.txt"), old);
        let after = see(&mut client, &repo, scope);
        assert_ne!(before.today, after.today, "{scope}: git.diff did not see the tracked edit");
        assert_ne!(
            before.fingerprint, after.fingerprint,
            "{scope}: new bytes of the same size in a tracked file kept the fingerprint"
        );
        std::fs::write(repo.join("a.txt"), "one\nTWO\n").unwrap();
        set_mtime(&repo.join("a.txt"), old);
        let back = see(&mut client, &repo, scope);
        assert_eq!(before.today, back.today, "{scope}: git.diff of the first bytes again");
        assert_eq!(
            before.fingerprint, back.fingerprint,
            "{scope}: the first bytes again did not give the first fingerprint"
        );

        // A file that git does not track: the same count of bytes and of lines. The reply of
        // git.diff has only its count of lines, so it stays; the fingerprint moves.
        let old = mtime(&repo.join("new.txt"));
        std::fs::write(repo.join("new.txt"), "NOT tracked\n").unwrap();
        set_mtime(&repo.join("new.txt"), old);
        let edited = see(&mut client, &repo, scope);
        assert_ne!(
            back.fingerprint, edited.fingerprint,
            "{scope}: new bytes of the same size in an untracked file kept the fingerprint"
        );
        std::fs::write(repo.join("new.txt"), "not tracked\n").unwrap();
        set_mtime(&repo.join("new.txt"), old);
        assert_eq!(edited.today, back.today, "{scope}: git.diff does not show these bytes");
    }
}

#[test]
fn git_fingerprint_moves_when_the_base_or_the_head_moves() {
    let repo = fresh_clone();
    let mut client = Client::of_a_new_daemon();
    commit(&repo, "c.txt", "three\n");
    commit(&repo, "d.txt", "four\n");
    let first = see(&mut client, &repo, "branch");
    assert_eq!(first.today["total_files"], 2, "2 files since the base: {}", first.today);

    // The base branch takes in the first of the 2 commits: HEAD stays, the merge base moves.
    git(&repo, &["update-ref", "refs/remotes/origin/main", "HEAD~1"]);
    let moved = see(&mut client, &repo, "branch");
    assert_ne!(first.today["base"], moved.today["base"], "the merge base moved");
    assert_ne!(first.fingerprint, moved.fingerprint, "a new merge base kept the fingerprint");

    // A commit with no change of a file: only HEAD moves.
    let before = see(&mut client, &repo, "uncommitted");
    git(&repo, &["commit", "--quiet", "--allow-empty", "-m", "empty"]);
    let after = see(&mut client, &repo, "uncommitted");
    assert_ne!(before.today["head"], after.today["head"], "HEAD moved");
    assert_ne!(before.fingerprint, after.fingerprint, "a new HEAD kept the fingerprint");
}

#[test]
fn git_fingerprint_of_a_file_above_the_patch_bound_moves_as_the_reply_of_git_diff_moves() {
    let repo = fresh_clone();
    let mut client = Client::of_a_new_daemon();
    std::fs::write(repo.join("long.txt"), long_text('b', 'b')).unwrap();
    let before = see(&mut client, &repo, "uncommitted");
    let file = &before.today["files"][0];
    assert_eq!(file["path"], "long.txt");
    assert_eq!(file["patch_truncated"], true, "the patch is above the bound: {file}");

    // One byte of the last line: it is after the part of the patch that git.diff keeps.
    let old = mtime(&repo.join("long.txt"));
    std::fs::write(repo.join("long.txt"), long_text('b', 'c')).unwrap();
    set_mtime(&repo.join("long.txt"), old);
    let after = see(&mut client, &repo, "uncommitted");
    assert_eq!(before.today["files"][0]["patch"], after.today["files"][0]["patch"]);
    assert_ne!(before.today, after.today, "git.diff names the new bytes by their blob id");
    assert_ne!(
        before.fingerprint, after.fingerprint,
        "a change after the patch bound kept the fingerprint"
    );

    set_mtime(&repo.join("long.txt"), SystemTime::now() + Duration::from_secs(5));
    let touched = see(&mut client, &repo, "uncommitted");
    assert_eq!(after.today, touched.today);
    assert_eq!(after.fingerprint, touched.fingerprint, "a touch of the long file");
}

#[test]
fn git_fingerprint_moves_with_the_index_and_with_the_list_of_untracked_files() {
    let repo = fresh_clone();
    let mut client = Client::of_a_new_daemon();
    std::fs::write(repo.join("a.txt"), "one\nTWO\n").unwrap();
    let scopes = ["uncommitted", "unstaged", "staged"];
    let first = scopes.map(|scope| see(&mut client, &repo, scope));

    // The work tree stays; the index takes the change.
    git(&repo, &["add", "a.txt"]);
    let staged = scopes.map(|scope| see(&mut client, &repo, scope));
    for ((scope, first), staged) in scopes.iter().zip(&first).zip(&staged) {
        let moved = first.today != staged.today;
        assert_eq!(*scope != "uncommitted", moved, "{scope}: what git.diff says of the add");
        assert_eq!(
            moved,
            first.fingerprint != staged.fingerprint,
            "{scope}: the fingerprint and the reply of git.diff did not move together at an add"
        );
    }
    git(&repo, &["restore", "--staged", "a.txt"]);
    for (scope, first) in scopes.iter().zip(&first) {
        let again = client.fingerprint(&repo, scope);
        assert_eq!(first.fingerprint, again, "{scope}: the first index again");
    }

    // A file that git does not track comes and goes; an ignored file is no change.
    let first = see(&mut client, &repo, "uncommitted");
    std::fs::write(repo.join("new.txt"), "x\n").unwrap();
    let with = see(&mut client, &repo, "uncommitted");
    assert_ne!(first.fingerprint, with.fingerprint, "a new untracked file");
    std::fs::remove_file(repo.join("new.txt")).unwrap();
    assert_eq!(first.fingerprint, client.fingerprint(&repo, "uncommitted"), "the file is gone");
    std::fs::write(repo.join(".git/info/exclude"), "ignored.txt\n").unwrap();
    std::fs::write(repo.join("ignored.txt"), "x\n").unwrap();
    assert_eq!(first.today, client.today(&repo, "uncommitted"));
    assert_eq!(first.fingerprint, client.fingerprint(&repo, "uncommitted"), "an ignored file");

    // The mode of a tracked file.
    let mut mode = std::fs::metadata(repo.join("b.txt")).unwrap().permissions();
    mode.set_mode(0o755);
    std::fs::set_permissions(repo.join("b.txt"), mode).unwrap();
    let executable = see(&mut client, &repo, "uncommitted");
    assert_ne!(first.today, executable.today, "git.diff shows the new mode");
    assert_ne!(first.fingerprint, executable.fingerprint, "a new mode kept the fingerprint");
}

#[test]
fn git_fingerprint_starts_fewer_children_than_git_diff_and_none_for_a_patch() {
    let repo = fresh_clone();
    let mut client = Client::of_a_new_daemon();
    std::fs::write(repo.join("a.txt"), "one\nTWO\n").unwrap();
    std::fs::write(repo.join("new.txt"), "not tracked\n").unwrap();
    for scope in ["uncommitted", "unstaged", "staged", "branch"] {
        forget_children(&repo);
        client.today(&repo, scope);
        let diff = children(&repo);
        forget_children(&repo);
        client.fingerprint(&repo, scope);
        let fingerprint = children(&repo);
        eprintln!(
            "git-fingerprint: scope {scope}: git.diff with each patch = {} children, \
             git.fingerprint = {} children:\n  {}",
            diff.len(),
            fingerprint.len(),
            fingerprint.join("\n  ")
        );
        assert!(!diff.is_empty(), "{scope}: the log of the children of git.diff is empty");
        assert!(
            fingerprint.len() < diff.len(),
            "{scope}: git.fingerprint started {} children, git.diff {}",
            fingerprint.len(),
            diff.len()
        );
        for word in ["--patch", "--numstat", "--name-status"] {
            assert!(
                with_word(&fingerprint, word).is_empty(),
                "{scope}: git.fingerprint started a {word} child: {fingerprint:?}"
            );
        }
    }
}

#[test]
fn git_fingerprint_refuses_what_is_no_scope_of_a_work_tree() {
    let repo = fresh_clone();
    let mut client = Client::of_a_new_daemon();
    for scope in ["commits", "everything"] {
        let reply = client.ask("git.fingerprint", &repo, scope, false);
        assert_eq!(reply["ok"], false, "scope {scope}: {reply}");
        assert_eq!(reply["error"]["code"], "validation.invalid", "scope {scope}: {reply}");
    }
    let outside = fixture().dir.join(unique("plain"));
    std::fs::create_dir_all(&outside).unwrap();
    let reply = client.ask("git.fingerprint", &outside, "uncommitted", false);
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["details"]["extra"]["code"], "not_a_repository", "{reply}");
}

#[test]
fn git_fingerprint_reads_no_file_of_a_work_tree_at_rest_and_one_file_after_one_edit() {
    let repo = fresh_clone();
    let mut client = Client::of_a_new_daemon();
    // A changed file, a staged file and 2 files that git does not track: 4 files to read.
    std::fs::write(repo.join("a.txt"), "one\nTWO\n").unwrap();
    std::fs::write(repo.join("b.txt"), "TWO\n").unwrap();
    git(&repo, &["add", "b.txt"]);
    std::fs::write(repo.join("new.txt"), "not tracked\n").unwrap();
    std::fs::write(repo.join("other.txt"), "x\n").unwrap();
    let bytes = "one\nTWO\n".len() + "TWO\n".len() + "not tracked\n".len() + "x\n".len();
    wait_until_the_files_are_settled();
    for scope in ["uncommitted", "unstaged", "branch"] {
        // The daemon is new for the first scope only: the next scopes find the hashes.
        let first = client.read(&repo, scope);
        if scope == "uncommitted" {
            assert_eq!((first.files, first.bytes), (4, bytes as u64), "the first read");
        }
        forget_children(&repo);
        let rest = client.read(&repo, scope);
        eprintln!(
            "git-fingerprint: scope {scope}: at rest: {} files, {} bytes read by the daemon, \
             {} git children",
            rest.files,
            rest.bytes,
            children(&repo).len()
        );
        assert_eq!(first.fingerprint, rest.fingerprint, "{scope}: no change");
        assert_eq!((rest.files, rest.bytes), (0, 0), "{scope}: a read at rest read a file");
    }
    // The staged scope compares 2 ids that git has: no file is read at all.
    let staged = client.read(&repo, "staged");
    assert_eq!((staged.files, staged.bytes), (0, 0), "the staged scope read a file");

    // One edit: the daemon reads that file and no other.
    let before = client.read(&repo, "uncommitted");
    std::fs::write(repo.join("new.txt"), "now 13 bytes\n").unwrap();
    let edited = client.read(&repo, "uncommitted");
    eprintln!(
        "git-fingerprint: after one edit: {} files, {} bytes read by the daemon",
        edited.files, edited.bytes
    );
    assert_ne!(before.fingerprint, edited.fingerprint, "the edit");
    assert_eq!((edited.files, edited.bytes), (1, 13), "the daemon read more than the edited file");
    // Less than 2 s after the edit the hash is racy, so the next reads take the file again;
    // after that time one more read takes it, and then none.
    let racy = client.read(&repo, "uncommitted");
    assert!(racy.files <= 1, "a read after the edit read other files: {racy:?}");
    wait_until_the_files_are_settled();
    let settled = client.read(&repo, "uncommitted");
    assert!(settled.files <= 1, "a read after the wait read other files: {settled:?}");
    let rest = client.read(&repo, "uncommitted");
    assert_eq!(edited.fingerprint, rest.fingerprint, "no change after the edit");
    assert_eq!((rest.files, rest.bytes), (0, 0), "at rest after the edit");
}

/// The files that one read gives a content hash, in the order of git's list.
const FILES_OF_ONE_READ: usize = 8192;

#[test]
fn git_fingerprint_of_a_long_list_hashes_a_bounded_part_and_never_reads_a_file_past_the_bound() {
    let repo = fresh_clone();
    let mut client = Client::of_a_new_daemon();
    // Build output that no ignore rule covers: 8 files more than one read hashes. git lists
    // them by name, so the 8 last names are past the bound.
    let folder = repo.join("out");
    std::fs::create_dir_all(&folder).unwrap();
    let name = |number: usize| folder.join(format!("f{number:05}.o"));
    for number in 0..FILES_OF_ONE_READ + 8 {
        std::fs::write(name(number), format!("{number:05}\n")).unwrap();
    }
    wait_until_the_files_are_settled();
    let first = client.read(&repo, "uncommitted");
    assert_eq!(first.files, FILES_OF_ONE_READ as u64, "the first read hashes to the bound");
    assert_eq!(first.bytes, 6 * FILES_OF_ONE_READ as u64);
    forget_children(&repo);
    let rest = client.read(&repo, "uncommitted");
    let started = children(&repo);
    eprintln!(
        "git-fingerprint: {} untracked files: first read {} files, at rest {} files and {} \
         bytes, {} git children",
        FILES_OF_ONE_READ + 8,
        first.files,
        rest.files,
        rest.bytes,
        started.len()
    );
    assert_eq!(first.fingerprint, rest.fingerprint);
    assert_eq!((rest.files, rest.bytes), (0, 0), "a read at rest read a file of the long list");

    // New bytes of the same size in a file PAST the bound, with the mtime that it had: the
    // write moved the file's change time, so the fingerprint moves, and the daemon read no file.
    let past = name(FILES_OF_ONE_READ + 3);
    let old = mtime(&past);
    std::fs::write(&past, "abcde\n").unwrap();
    set_mtime(&past, old);
    let edited = client.read(&repo, "uncommitted");
    assert_ne!(rest.fingerprint, edited.fingerprint, "an edit past the bound kept the fingerprint");
    assert_eq!((edited.files, edited.bytes), (0, 0), "the daemon read a file past the bound");

    // A file inside the bound is read when it changes, and it alone.
    std::fs::write(name(7), "ABCDE\n").unwrap();
    let inside = client.read(&repo, "uncommitted");
    assert_ne!(edited.fingerprint, inside.fingerprint, "an edit inside the bound");
    assert_eq!((inside.files, inside.bytes), (1, 6), "one edit inside the bound");
}

#[test]
fn git_fingerprint_reads_no_file_above_64_mib_and_at_most_256_mib_in_one_read() {
    const MIB: u64 = 1024 * 1024;
    let repo = fresh_clone();
    let mut client = Client::of_a_new_daemon();
    // Files with no blocks on the disk: only their sizes count.
    let sized = |name: &str, bytes: u64| {
        std::fs::File::create(repo.join(name)).unwrap().set_len(bytes).unwrap();
    };
    sized("huge.bin", 64 * MIB + 1);
    wait_until_the_files_are_settled();
    let huge = client.read(&repo, "uncommitted");
    assert_eq!((huge.files, huge.bytes), (0, 0), "the daemon read a file above 64 MiB");
    // It counts by its stat entry: a new mtime moves the fingerprint, with no read.
    set_mtime(&repo.join("huge.bin"), SystemTime::now() + Duration::from_secs(5));
    let touched = client.read(&repo, "uncommitted");
    assert_ne!(huge.fingerprint, touched.fingerprint, "the stat entry of the huge file moved");
    assert_eq!((touched.files, touched.bytes), (0, 0));
    std::fs::remove_file(repo.join("huge.bin")).unwrap();

    // 5 files of 60 MiB: the first 4 in git's order are 240 MiB, the fifth is past 256 MiB.
    for name in ["s1.bin", "s2.bin", "s3.bin", "s4.bin", "s5.bin"] {
        sized(name, 60 * MIB);
    }
    wait_until_the_files_are_settled();
    let sum = client.read(&repo, "uncommitted");
    eprintln!(
        "git-fingerprint: 5 untracked files of 60 MiB: {} files, {} bytes read by the daemon",
        sum.files, sum.bytes
    );
    assert_eq!((sum.files, sum.bytes), (4, 240 * MIB), "the sum of one read is above 256 MiB");
    let rest = client.read(&repo, "uncommitted");
    assert_eq!(sum.fingerprint, rest.fingerprint);
    assert_eq!((rest.files, rest.bytes), (0, 0), "at rest");
}
