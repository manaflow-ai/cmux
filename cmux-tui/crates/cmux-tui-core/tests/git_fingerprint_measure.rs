#![cfg(unix)]
//! VEHICLE ONLY: this file never merges. It prints what one freshness check of
//! an open diff tab costs today (`git.diff` with each patch, which the app then
//! hashed) and with `git.fingerprint`, on one host. Its rows compare two forms
//! on one host; they are no number for a person's Mac.
//!
//! Two work trees:
//!
//! - `large`: a scratch copy of the checkout this test was built from (its
//!   tracked files at HEAD; the objects are borrowed through `alternates`, the
//!   source checkout is only read);
//! - `small`: 30 files of 2.4 kB.
//!
//! Each has a branch that is 1 commit ahead of origin's default branch, and
//! that commit changes files, so the branch scope has a diff in every state.
//!
//! Three states for each tree: clean; tracked files changed and untracked files
//! added; the same and more tracked files with a new mtime and the same bytes.
//! In each state and each scope (`uncommitted`, `branch`), [`RUNS`] rounds in
//! which the forms take turns, so a slow moment of the host hits them all.
//!
//! "the whole request" is one request on the control socket of a daemon in this
//! process, from the write of the request to the read of its reply line. The
//! app's parse and SHA-256 of today's reply are NOT in today's time.

use cmux_git::run::{DEADLINE, run_git_within};
use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime};

/// The recorded rounds of each state and scope.
const RUNS: usize = 30;
const SCOPES: [&str; 2] = ["uncommitted", "branch"];

/// The config child of today's `Repository::open`.
const FILTER_CONFIG: [&str; 5] = [
    "config",
    "--null",
    "--name-only",
    "--get-regexp",
    r"^filter\..*\.(clean|smudge|process|required)$",
];
/// The config child of the open that `git.fingerprint` makes.
const DIFF_CONFIG: [&str; 4] = ["config", "--null", "--get-regexp", r"^(core|diff|filter)\."];

/// The scratch directory, removed when the test ends or fails.
struct Scratch {
    dir: PathBuf,
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// The real git, as an absolute path.
fn real_git() -> PathBuf {
    let path = std::env::var_os("PATH").expect("PATH is set");
    std::env::split_paths(&path)
        .map(|dir| dir.join("git"))
        .find(|candidate| candidate.is_file())
        .expect("git is on PATH")
}

/// A setup run of the real git, with no user or system config. Its output.
fn setup_git(real: &Path, directory: &Path, arguments: &[&str]) -> String {
    let output = Command::new(real)
        .arg("-C")
        .arg(directory)
        .args(["-c", "safe.directory=*", "-c", "maintenance.auto=false", "-c", "gc.auto=0"])
        .args(["-c", "user.name=t", "-c", "user.email=t@e.test"])
        .args(arguments)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {arguments:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim_end_matches('\n').to_string()
}

/// One connection to the daemon; one request at a time.
struct Connection {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Connection {
    fn open(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(120))).unwrap();
        let mut writer = stream.try_clone().unwrap();
        writeln!(writer, "{}", json!({"id": 0, "cmd": "ping"})).unwrap();
        let mut connection = Self { writer, reader: BufReader::new(stream), next: 0 };
        connection.line_of(&json!(0));
        connection
    }

    /// The reply line with `id`, its value, and the time from the call to the
    /// read of that line (the parse is not in it).
    fn line_of(&mut self, id: &Value) -> (Duration, Value, usize) {
        let started = Instant::now();
        loop {
            let mut line = String::new();
            let read = self.reader.read_line(&mut line).unwrap();
            let at = started.elapsed();
            assert!(read > 0, "the daemon closed the connection before the reply {id}");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if &reply["id"] == id {
                return (at, reply, line.len());
            }
        }
    }

    /// One `cmux.protocol/2` request: the time to its reply line, the reply
    /// and the bytes of the line.
    fn ask(&mut self, operation: &str, mut params: Value) -> (Duration, Value, usize) {
        self.next += 1;
        let id = json!(format!("m{}", self.next));
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
        let started = Instant::now();
        writeln!(self.writer, "{request}").unwrap();
        let wrote = started.elapsed();
        let (waited, reply, bytes) = self.line_of(&id);
        assert_eq!(reply["ok"], true, "{operation} failed: {reply:.600}");
        (wrote + waited, reply, bytes)
    }
}

/// One check as the app made it before `git.fingerprint`.
struct Today {
    elapsed: Duration,
    /// Bytes of the reply line: what crossed the socket and the app hashed.
    line: usize,
    files: usize,
}

fn today(connection: &mut Connection, repo: &Path, scope: &str) -> Today {
    let params = json!({"path": repo, "scope": scope, "include_patch": true});
    let (elapsed, reply, line) = connection.ask("git.diff", params);
    Today { elapsed, line, files: reply["result"]["files"].as_array().map_or(0, Vec::len) }
}

/// One `git.fingerprint`, with what the daemon says it read for it.
struct Poll {
    elapsed: Duration,
    line: usize,
    digits: String,
    files: u64,
    bytes: u64,
}

fn fingerprint(connection: &mut Connection, repo: &Path, scope: &str) -> Poll {
    let (elapsed, reply, line) =
        connection.ask("git.fingerprint", json!({"path": repo, "scope": scope}));
    let result = &reply["result"];
    let digits = result["fingerprint"].as_str().unwrap_or_default().to_string();
    assert_eq!(digits.len(), 64, "git.fingerprint in scope {scope}: {reply:.300}");
    Poll {
        elapsed,
        line,
        digits,
        files: result["files_read"].as_u64().expect("files_read"),
        bytes: result["bytes_read"].as_u64().expect("bytes_read"),
    }
}

/// One config child with the daemon's environment and no override.
fn config_child(repo: &Path, arguments: &[&str]) -> Duration {
    let started = Instant::now();
    // git exits 1 when no setting matches: the cost is the same.
    let _ = run_git_within(repo, &[], arguments, 1024 * 1024, DEADLINE);
    started.elapsed()
}

fn milliseconds(duration: Duration) -> String {
    format!("{:.2}", duration.as_secs_f64() * 1000.0)
}

/// The sample at the quantile `part` (nearest rank) of sorted `samples`.
fn quantile(samples: &[Duration], part: f64) -> Duration {
    let rank = (samples.len() as f64 * part).ceil() as usize;
    samples[rank.clamp(1, samples.len()) - 1]
}

fn row(samples: &mut [Duration], name: &str) {
    samples.sort();
    eprintln!(
        "fp-measure: p50 {:>8} | p95 {:>8} | max {:>8} | min {:>8} | {name}",
        milliseconds(quantile(samples, 0.5)),
        milliseconds(quantile(samples, 0.95)),
        milliseconds(samples[samples.len() - 1]),
        milliseconds(samples[0]),
    );
}

/// One work tree and what its states change.
struct Tree {
    name: &'static str,
    repo: PathBuf,
    /// Source files that no commit of the setup changed.
    sources: Vec<PathBuf>,
    /// Every regular tracked file.
    all: Vec<PathBuf>,
    changed: usize,
    untracked: usize,
    touched: usize,
}

/// [`RUNS`] rounds of the 4 forms in each scope, with the work tree at rest.
/// What is not as the design says goes to `problems`.
fn rest(connection: &mut Connection, tree: &Tree, state: &str, problems: &mut Vec<String>) {
    for scope in SCOPES {
        let name = tree.name;
        let _ = today(connection, &tree.repo, scope);
        let first = fingerprint(connection, &tree.repo, scope);
        let mut rows: [Vec<Duration>; 4] = Default::default();
        let (mut files, mut bytes, mut moved) = (0_u64, 0_u64, 0_usize);
        let (mut patch_line, mut patch_files, mut digits_line) = (0, 0, 0);
        for _ in 0..RUNS {
            let old = today(connection, &tree.repo, scope);
            rows[0].push(old.elapsed);
            patch_line = old.line;
            patch_files = old.files;
            let new = fingerprint(connection, &tree.repo, scope);
            rows[1].push(new.elapsed);
            digits_line = new.line;
            files += new.files;
            bytes += new.bytes;
            if new.digits != first.digits {
                moved += 1;
            }
            rows[2].push(config_child(&tree.repo, &FILTER_CONFIG));
            rows[3].push(config_child(&tree.repo, &DIFF_CONFIG));
        }
        eprintln!(
            "fp-measure: === [{name}] state: {state} | scope {scope} (ms; n = {RUNS} each row)"
        );
        let [old, new, filters, settings] = &mut rows;
        row(
            old,
            &format!(
                "today: git.diff with each patch, the whole request | reply line {patch_line} \
                 bytes, {patch_files} files"
            ),
        );
        row(
            new,
            &format!(
                "new:   git.fingerprint, the whole request | reply line {digits_line} bytes | in \
                 the {RUNS} polls: {files} files read, {bytes} bytes read, {moved} polls with \
                 other digits"
            ),
        );
        row(filters, "child: config of the filter drivers (today's open)");
        row(settings, "child: config of core, diff and filter (the open of git.fingerprint)");
        let ratio = |part: f64| {
            quantile(new, part).as_secs_f64() / quantile(old, part).as_secs_f64().max(1e-9)
        };
        eprintln!(
            "fp-measure: [{name}] {state} | {scope}: new / today = {:.3} at p50, {:.3} at p95, \
             {:.3} at max",
            ratio(0.5),
            ratio(0.95),
            ratio(1.0),
        );
        if files != 0 || bytes != 0 || moved != 0 {
            problems.push(format!(
                "[{name}] {state} | {scope}: at rest the daemon read {files} files, {bytes} \
                 bytes, and {moved} polls gave other digits"
            ));
        }
        if quantile(new, 0.5) >= quantile(old, 0.5) {
            problems.push(format!(
                "[{name}] {state} | {scope}: the fingerprint's p50 is not below today's"
            ));
        }
    }
}

/// The polls after a change of the work tree, in the uncommitted scope: the
/// first one, one at once (inside the 2 s window of a racy hash), one 2.3 s
/// later, and the next. The digits of the first and of the last.
fn settle(connection: &mut Connection, tree: &Tree, what: &str) -> (String, String) {
    let name = tree.name;
    let say = |when: &str, poll: &Poll| {
        eprintln!(
            "fp-measure: [{name}] after {what}: {when}: {} files read, {} bytes read, {} ms",
            poll.files,
            poll.bytes,
            milliseconds(poll.elapsed),
        );
    };
    let first = fingerprint(connection, &tree.repo, "uncommitted");
    say("the first poll", &first);
    let again = fingerprint(connection, &tree.repo, "uncommitted");
    say("the next poll at once (inside the 2 s window)", &again);
    std::thread::sleep(Duration::from_millis(2300));
    let late = fingerprint(connection, &tree.repo, "uncommitted");
    say("the first poll 2.3 s later", &late);
    let last = fingerprint(connection, &tree.repo, "uncommitted");
    say("the poll after that", &last);
    assert_eq!(first.digits, last.digits, "[{name}] after {what}: the digits moved with no change");
    assert_eq!((last.files, last.bytes), (0, 0), "[{name}] after {what}: a read at rest");
    (first.digits, last.digits)
}

/// The regular files among `names`, as (path, bytes).
fn regular_files(repo: &Path, names: &[String]) -> Vec<(PathBuf, u64)> {
    names
        .iter()
        .filter_map(|name| {
            let path = repo.join(name);
            let metadata = std::fs::symlink_metadata(&path).ok()?;
            metadata.is_file().then(|| (path, metadata.len()))
        })
        .collect()
}

/// `count` of `items`, at equal steps.
fn spread<T: Clone>(items: &[T], count: usize) -> Vec<T> {
    assert!(items.len() >= count, "{} items, {count} wanted", items.len());
    (0..count).map(|index| items[index * items.len() / count].clone()).collect()
}

fn append_line(path: &Path) {
    let mut file = std::fs::File::options().append(true).open(path).unwrap();
    file.write_all(b"\n// one more line of the fingerprint measure\n").unwrap();
}

/// Gives the repository at `repo` (on `refs/heads/main` at a commit, clean) an
/// origin whose default branch is that commit and a commit ahead of it that
/// changes `ahead` source files. The tree, clean again.
fn tree_of(
    real: &Path,
    name: &'static str,
    repo: PathBuf,
    ahead: usize,
    (changed, untracked, touched): (usize, usize, usize),
) -> Tree {
    let head = setup_git(real, &repo, &["rev-parse", "HEAD"]);
    setup_git(real, &repo, &["update-ref", "refs/remotes/origin/main", &head]);
    let origin_head = ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"];
    setup_git(real, &repo, &origin_head);
    setup_git(real, &repo, &["config", "remote.origin.url", "/nonexistent/origin"]);
    let fetch = ["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"];
    setup_git(real, &repo, &fetch);
    setup_git(real, &repo, &["config", "branch.main.remote", "origin"]);
    setup_git(real, &repo, &["config", "branch.main.merge", "refs/heads/main"]);

    let listed = setup_git(real, &repo, &["ls-files", "-z"]);
    let names: Vec<String> =
        listed.split('\0').filter(|name| !name.is_empty()).map(str::to_string).collect();
    let files = regular_files(&repo, &names);
    let file_bytes: u64 = files.iter().map(|(_, bytes)| bytes).sum();
    let sources: Vec<PathBuf> = files
        .iter()
        .filter(|(path, bytes)| {
            let extension = path.extension().and_then(|extension| extension.to_str());
            matches!(extension, Some("rs" | "swift" | "ts" | "tsx"))
                && (2_000..200_000).contains(bytes)
        })
        .map(|(path, _)| path.clone())
        .collect();
    // The files of the commit ahead, and the others for the states.
    let picked = spread(&sources, ahead + changed + 1);
    for path in &picked[..ahead] {
        append_line(path);
    }
    setup_git(real, &repo, &["commit", "--quiet", "-a", "-m", "ahead"]);
    // An index entry as new as the index file is compared by content at each
    // read. One refresh after the clock's second has passed makes the tree clean.
    std::thread::sleep(Duration::from_secs(2));
    setup_git(real, &repo, &["update-index", "-q", "--refresh"]);
    let dirty = setup_git(real, &repo, &["status", "--porcelain"]);
    assert!(dirty.is_empty(), "the scratch repository {name} is not clean: {dirty:.300}");
    eprintln!(
        "fp-measure: [{name}] {}: {} tracked entries, {} regular files, {file_bytes} bytes; the \
         commit ahead of origin changes {ahead} files",
        repo.display(),
        names.len(),
        files.len(),
    );
    Tree {
        name,
        repo,
        sources: picked[ahead..].to_vec(),
        all: files.into_iter().map(|(path, _)| path).collect(),
        changed,
        untracked,
        touched,
    }
}

/// The 3 states of `tree` and one edit after them.
fn states(connection: &mut Connection, tree: &Tree, problems: &mut Vec<String>) {
    let repo = &tree.repo;
    let (changed, untracked, touched) = (tree.changed, tree.untracked, tree.touched);
    let (_, clean) = settle(connection, tree, "the setup (a clean tree)");
    rest(connection, tree, "clean", problems);

    // State 2: source files get one more line; new files.
    for path in &tree.sources[..changed] {
        append_line(path);
    }
    for number in 0..untracked {
        let path = repo.join(format!("fingerprint-measure-untracked-{number}.txt"));
        std::fs::write(&path, "a line of an untracked file\n".repeat(80)).unwrap();
    }
    let state = format!("{changed} tracked files changed + {untracked} untracked files");
    let (dirty, _) = settle(connection, tree, &state);
    assert_ne!(clean, dirty, "[{}] {state}: the digits did not move", tree.name);
    rest(connection, tree, &state, problems);
    let seen = today(connection, repo, "uncommitted").files;
    assert_eq!(seen, changed + untracked, "[{}] the changed and the untracked files", tree.name);

    // State 3: more tracked files get a new mtime and keep their bytes.
    let mut touched_bytes = 0;
    for path in &spread(&tree.all, touched) {
        touched_bytes += std::fs::symlink_metadata(path).unwrap().len();
        let file = std::fs::File::options().append(true).open(path).unwrap();
        file.set_modified(SystemTime::now()).unwrap();
    }
    let touch =
        format!("{touched} tracked files touched (new mtime, same bytes: {touched_bytes} bytes)");
    let (after_touch, _) = settle(connection, tree, &touch);
    if after_touch != dirty {
        problems.push(format!("[{}] the touch of {touched} files moved the digits", tree.name));
    }
    rest(connection, tree, &format!("{state} + {touched} tracked files touched"), problems);

    // One edit of one changed file.
    let edited = &tree.sources[0];
    append_line(edited);
    let size = std::fs::symlink_metadata(edited).unwrap().len();
    let edit = format!("one edit of one changed file ({size} bytes)");
    let (after_edit, _) = settle(connection, tree, &edit);
    assert_ne!(after_edit, after_touch, "[{}] the edit did not move the digits", tree.name);
}

/// A git child's arguments without the leading `-c key=value` pairs.
fn without_config(line: &str) -> String {
    let mut words = line.split(' ').peekable();
    while words.peek() == Some(&"-c") {
        words.next();
        words.next();
    }
    words.collect::<Vec<_>>().join(" ")
}

#[test]
fn git_fingerprint_measure_prints_a_check_today_and_with_the_fingerprint() {
    let real = real_git();
    let scratch =
        Scratch { dir: std::env::temp_dir().join(format!("fpcost-{}", std::process::id())) };
    let bin = scratch.dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    // The daemon's git is `git` on PATH. It is a link to the real git while the
    // clock runs; the count pass at the end puts a script that logs its
    // arguments in its place. PATH changes here, before any other thread.
    std::os::unix::fs::symlink(&real, bin.join("git")).unwrap();
    let mut path = bin.as_os_str().to_owned();
    path.push(":");
    path.push(std::env::var_os("PATH").unwrap());
    unsafe { std::env::set_var("PATH", path) };

    // The source of the large tree: the checkout this test was built from. It is only read.
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    let source = PathBuf::from(setup_git(&real, manifest, &["rev-parse", "--show-toplevel"]));
    let common = PathBuf::from(setup_git(
        &real,
        &source,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    ));
    let head = setup_git(&real, &source, &["rev-parse", "HEAD"]);
    let shallow = common.join("shallow").is_file();
    let space = Command::new("df").arg("-P").arg(&scratch.dir).output().ok();
    let space = space.map(|output| String::from_utf8_lossy(&output.stdout).into_owned());
    eprintln!(
        "fp-measure: host {} {}, {} cpus; {}; file system: {}",
        std::env::consts::OS,
        std::env::consts::ARCH,
        std::thread::available_parallelism().map_or(0, usize::from),
        setup_git(&real, &source, &["--version"]),
        space.unwrap_or_default().lines().last().unwrap_or_default(),
    );
    eprintln!("fp-measure: source {} at {head}, shallow {shallow}", source.display());

    // The large tree: the source's objects, its own index and files.
    let repo = scratch.dir.join("large");
    std::fs::create_dir_all(&repo).unwrap();
    setup_git(&real, &repo, &["init", "--quiet"]);
    setup_git(&real, &repo, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    let alternates = format!("{}\n", common.join("objects").display());
    std::fs::write(repo.join(".git/objects/info/alternates"), alternates).unwrap();
    if shallow {
        std::fs::copy(common.join("shallow"), repo.join(".git/shallow")).unwrap();
    }
    setup_git(&real, &repo, &["update-ref", "refs/heads/main", &head]);
    setup_git(&real, &repo, &["reset", "--hard", "--quiet"]);
    let large = tree_of(&real, "large", repo, 10, (20, 5, 200));

    // The small tree.
    let repo = scratch.dir.join("small");
    std::fs::create_dir_all(repo.join("src")).unwrap();
    setup_git(&real, &repo, &["init", "--quiet"]);
    setup_git(&real, &repo, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    for number in 0..30 {
        let text = format!("// line of small file {number:02}\n").repeat(100);
        std::fs::write(repo.join(format!("src/file_{number:02}.rs")), text).unwrap();
    }
    setup_git(&real, &repo, &["add", "-A"]);
    setup_git(&real, &repo, &["commit", "--quiet", "-m", "base"]);
    let small = tree_of(&real, "small", repo, 2, (3, 2, 10));

    // The daemon.
    let socket = scratch.dir.join("d.sock");
    let mux = Mux::new(format!("fp-measure-{}", std::process::id()), SurfaceOptions::default());
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    // The daemon lives as long as the test process.
    std::mem::forget(mux);
    let mut connection = Connection::open(&socket);

    let mut problems = Vec::new();
    for tree in [&large, &small] {
        states(&mut connection, tree, &mut problems);
    }

    // The count pass: `git` on PATH becomes a script that logs its arguments.
    let log = scratch.dir.join("children.log");
    let script = format!(
        "#!/bin/sh\necho \"$*\" >> \"{}\"\nexec \"{}\" \"$@\"\n",
        log.display(),
        real.display()
    );
    let counting = bin.join("git.count");
    std::fs::write(&counting, script).unwrap();
    std::fs::set_permissions(&counting, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::rename(&counting, bin.join("git")).unwrap();
    eprintln!("fp-measure: === the git children of one check (the last state of each tree)");
    for tree in [&large, &small] {
        for scope in SCOPES {
            let mut counts = [0_usize; 2];
            for (index, form) in ["today: git.diff with each patch", "new:   git.fingerprint"]
                .into_iter()
                .enumerate()
            {
                let _ = std::fs::remove_file(&log);
                if index == 0 {
                    let _ = today(&mut connection, &tree.repo, scope);
                } else {
                    let _ = fingerprint(&mut connection, &tree.repo, scope);
                }
                let children = std::fs::read_to_string(&log).unwrap_or_default();
                counts[index] = children.lines().count();
                eprintln!(
                    "fp-measure: [{}] {scope}: {} children | {form}",
                    tree.name, counts[index]
                );
                for line in children.lines() {
                    eprintln!("fp-measure:     git {:.150}", without_config(line));
                }
            }
            if counts[1] >= counts[0] {
                problems.push(format!(
                    "[{}] {scope}: git.fingerprint starts {} children, git.diff {}",
                    tree.name, counts[1], counts[0]
                ));
            }
        }
    }
    drop(connection);
    drop(scratch);
    assert!(problems.is_empty(), "not as the design says:\n{}", problems.join("\n"));
}
