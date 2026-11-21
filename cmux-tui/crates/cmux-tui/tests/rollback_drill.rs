//! DRILL, NOT FOR A MERGE. A rollback drill with real binaries, in ONE test
//! step. The NEWER build is this commit's `cmux-tui`; the OLDER build is made
//! by this test: a `git archive` of the older commit (a read of the
//! checkout's git, nothing is written there) into a new folder in `/tmp`, and
//! a `cargo build` of that tree with a target folder of its own. Where the
//! checkout's git does not have the older commit's tree, the archive is from
//! a fetch of the test's own: a git folder in the test's folder and ONE fetch
//! of the ONE commit from the public repository, with no credential and no
//! prompt. The test prints which of the 2 ways gave the archive. A submodule
//! is an empty folder in an archive's tree, so the tree gets a link to the
//! checkout's folder for each submodule that the build reads, after a check
//! that the 2 commits pin the same commit of it. No file
//! stays between 2 steps. Each part has a state folder of its own, a real
//! daemon of the newer build that leaves its store at schema number 16, and
//! then the older build on the same store.
//!
//! The parts:
//! (a) the check beside a live owner, a stop by request, the older build;
//! (b) a kill of the owner, the check, the older build;
//! (c) a kill of the owner, NO check, the older build's `server ensure`;
//! (d) then the newer build opens and stops, and the older build opens;
//! (e) SIGTERM to the owner, the older build;
//! (f) the check beside a live owner, a journal row after it, the older
//!     build's `server premigrate-registry` beside the owner, a stop by
//!     request, the older build;
//! (g) for 8, 80 and 800 sessions whose owner was killed (real stores, the
//!     product's sync mode): the time of the older build's check, and, on a
//!     new set, of the newer build's first check and of the check after it;
//!     a check of the newer build at or above 5 s fails the part;
//! (h) a check of 80 such sessions gets SIGKILL in its work; the check
//!     after it, and the older build on the real session's store;
//! (i) for 8, 80 and 800 OLD stores (the older build's daemon made the store
//!     and stopped by request) and one live session beside them: the time of
//!     the older build's first check and of its check again, and, on a new
//!     set, of the newer build's first check and of its check again; a
//!     check must leave the main file of each old store as it was;
//! (j) for 800 sessions whose owner was killed: the newer build's check with
//!     an end time of its own (`--within-ms 5000`), asked again until it
//!     gives a number; an ask at or above 6 s fails the part;
//! (k) the check beside a live owner, the OLDER build's `server stop`
//!     request to the newer build's daemon, ONE check more of the newer
//!     build with no owner, the older build. It runs after (f).
//!
//! Each line starts with `rollback drill:`. A drill that stops before its
//! parts says why in ONE line, `rollback drill: NO RESULT, ` and then `THE
//! ARCHIVE`, `THE OFFLINE CRATES`, `THE INNER BUILD` or `THE COPY`. The test
//! deletes its 2 folders at its end, in a pass and in a fail.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

/// The older commit and its committer time (`git log -1 --format=%ct`): a
/// build outside git takes its identity from the environment.
const OLDER_COMMIT: &str = "6e6a29962597b6cb8f0b2dfc78de9060d14bfd86";
const OLDER_COMMIT_TIME: &str = "1795190336";
/// The public repository, for the fetch of the test's own.
const REPOSITORY: &str = "https://github.com/manaflow-ai/cmux.git";
/// Each submodule that the build of `cmux-tui` reads at compile time: the
/// terminal library's build script and 5 `include_str!` of the shell
/// integration read `ghostty-next`. The build reads no file of the other 2
/// submodules (`ghostty`, `homebrew-cmux`).
const LINKED: [&str; 1] = ["ghostty-next"];
/// The time limits: of an archive (and of its unpack), of the fetch of the
/// test's own, and of the inner build.
const ARCHIVE_MINUTES: u64 = 5;
const FETCH_MINUTES: u64 = 15;
const BUILD_MINUTES: u64 = 25;
/// What the older build answers to `__store-schemas`.
const OLDER_READS: &str = r#"{"conversation_store":2,"workspace_registry":15}"#;

const REGISTRY: &str = "workspace-registry.sqlite3";
const CONVERSATIONS: &str = "conversations.sqlite3";
const LOCKS: &str = "session-locks";

static OLDER: OnceLock<PathBuf> = OnceLock::new();

fn say(text: &str) {
    println!("rollback drill: {text}");
}

fn newer() -> &'static Path {
    Path::new(env!("CARGO_BIN_EXE_cmux-tui"))
}

fn older() -> &'static Path {
    OLDER.get().expect("the older build is made before the parts")
}

/// No result of the drill: ONE line with the cause, then the test fails.
fn no_result(cause: &str, text: &str) -> ! {
    say(&format!("NO RESULT, {cause}: {text}"));
    panic!("NO RESULT, {cause}: {text}");
}

/// The older build's 2 folders in `/tmp`: its source tree and its cargo
/// target folder. Both go when the test ends, in a pass and in a fail.
struct OlderBuild {
    source: PathBuf,
    target: PathBuf,
}

impl Drop for OlderBuild {
    fn drop(&mut self) {
        for dir in [&self.source, &self.target] {
            say(&format!("the delete of {}: {:?}", dir.display(), fs::remove_dir_all(dir)));
        }
    }
}

/// One command of the older build's making, with a time limit of its own.
/// Its 2 outputs go to `log`. It has a process group of its own, and the
/// whole group gets SIGKILL at the limit. `Err` has the log's last lines.
fn made_by(
    what: &str,
    mut command: Command,
    log: &Path,
    limit: Duration,
) -> Result<String, String> {
    let file = fs::File::create(log).map_err(|error| format!("{what}: no log file: {error}"))?;
    let both = file.try_clone().map_err(|error| format!("{what}: no log file: {error}"))?;
    let started = Instant::now();
    let mut child = command
        .stdin(Stdio::null())
        .stdout(file)
        .stderr(both)
        .process_group(0)
        .spawn()
        .map_err(|error| format!("{what} did not start: {error}"))?;
    let mut in_time = true;
    while child.try_wait().unwrap().is_none() {
        if started.elapsed() >= limit {
            in_time = false;
            let group = format!("-{}", child.id());
            let _ = Command::new("kill").args(["-KILL", &group]).status();
            let _ = child.kill();
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let code = child.wait().unwrap().code();
    let took = started.elapsed().as_secs();
    let text = String::from_utf8_lossy(&fs::read(log).unwrap_or_default()).into_owned();
    let lines: Vec<&str> = text.lines().collect();
    let tail = lines[lines.len().saturating_sub(40)..].join("\n");
    let errors = error_lines(&lines);
    let then = "its `error` lines, then its last lines";
    if !in_time {
        let minutes = limit.as_secs() / 60;
        return Err(format!("{what} did not end in {minutes} minutes; {then}:\n{errors}{tail}"));
    }
    if code != Some(0) {
        return Err(format!(
            "{what} ended in {took} s, exit code {code:?}; {then}:\n{errors}{tail}"
        ));
    }
    Ok(format!("{what} ended in {took} s; its last line: {:?}", lines.last().unwrap_or(&"")))
}

/// Each line that starts with `error` and the 3 lines after it (60 lines at
/// most), and then the line that says where the last lines start.
fn error_lines(lines: &[&str]) -> String {
    let mut shown = vec![false; lines.len()];
    for (at, line) in lines.iter().enumerate() {
        if line.trim_start().starts_with("error") {
            for mark in shown.iter_mut().skip(at).take(4) {
                *mark = true;
            }
        }
    }
    let mut found: Vec<&str> = Vec::new();
    for (line, mark) in lines.iter().zip(&shown) {
        if *mark && found.len() < 60 {
            found.push(*line);
        }
    }
    if found.is_empty() {
        return "(no line starts with `error`)\nthe last lines:\n".to_string();
    }
    format!("{}\nthe last lines:\n", found.join("\n"))
}

/// The commit of the submodule `name` that `commit` pins, by `git ls-tree`
/// (a read; `git` says in which git folder).
fn pin(mut git: Command, commit: &str, name: &str) -> Result<String, String> {
    let output = git
        .args(["ls-tree", commit, "--", name])
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("`git ls-tree {commit} {name}` did not start: {error}"))?;
    let text = String::from_utf8_lossy(&output.stdout).into_owned();
    let mut words = text.split_whitespace();
    match (words.next(), words.next(), words.next()) {
        (Some("160000"), Some("commit"), Some(id)) if output.status.success() => Ok(id.to_string()),
        _ => Err(format!(
            "`git ls-tree {commit} {name}` gave exit code {:?}, stdout {text:?}, stderr {:?}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr)
        )),
    }
}

/// Takes from `command` each name of this process's environment that starts
/// with one of `starts` or is one of `names`.
fn without(command: &mut Command, starts: &[&str], names: &[&str]) {
    for (name, _) in std::env::vars_os() {
        let text = name.to_string_lossy();
        if starts.iter().any(|start| text.starts_with(*start)) || names.contains(&&*text) {
            command.env_remove(&name);
        }
    }
}

/// `git` in the test's own git folder, with no credential and no prompt: no
/// credential name and no git folder name of the outer run, no system or user
/// configuration (`home` is the test's folder), no credential helper. A wrong
/// state fails at once.
fn own_git(own: &Path, home: &Path) -> Command {
    let mut git = Command::new("git");
    git.args(["-c", "credential.helper="]).arg("-C").arg(own);
    let names = [
        "GH_TOKEN",
        "GITHUB_TOKEN",
        "GH_ENTERPRISE_TOKEN",
        "GITHUB_ENTERPRISE_TOKEN",
        "GIT_ASKPASS",
        "SSH_ASKPASS",
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_INDEX_FILE",
    ];
    without(&mut git, &["GIT_CONFIG", "GIT_CREDENTIAL", "GCM_"], &names);
    git.env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("HOME", home)
        .env("XDG_CONFIG_HOME", home);
    git
}

/// The second way to the archive: a git folder of the test's own in its
/// source folder (the guard removes it with that folder), ONE fetch of the
/// ONE commit from the public repository, and the archive from that folder.
fn archive_from_a_fetch_of_its_own(source: &Path, tar: &Path) -> Result<(), String> {
    let own = source.join("git");
    fs::create_dir_all(&own).map_err(|error| format!("the test's own git folder: {error}"))?;
    let short = Duration::from_secs(ARCHIVE_MINUTES * 60);
    let long = Duration::from_secs(FETCH_MINUTES * 60);
    let mut init = own_git(&own, source);
    init.args(["init", "-q"]);
    let mut fetch = own_git(&own, source);
    fetch.args(["fetch", "-q", "--depth", "1", REPOSITORY, OLDER_COMMIT]);
    let mut archive = own_git(&own, source);
    archive.args(["archive", "--format=tar", "-o"]).arg(tar).arg(OLDER_COMMIT);
    for (what, command, log, limit) in [
        ("the init of the test's own git folder", init, "own-init.log", short),
        ("the fetch of the test's own", fetch, "own-fetch.log", long),
        ("the archive from the fetch of the test's own", archive, "own-archive.log", short),
    ] {
        say(&made_by(what, command, &source.join(log), limit)?);
    }
    Ok(())
}

/// Makes the older build: an archive of the older commit (from the checkout's
/// git, else from a fetch of the test's own), its tree in `/tmp`, and a cargo
/// build of that tree. The inner build does not get the outer run's cargo
/// and nextest environment.
fn make_the_older_build() -> OlderBuild {
    let id = std::process::id();
    let made = OlderBuild {
        source: PathBuf::from("/tmp").join(format!("cmux-drill-older-source-{id}")),
        target: PathBuf::from("/tmp").join(format!("cmux-drill-older-target-{id}")),
    };
    let tree = made.source.join("tree");
    for dir in [&made.source, &made.target, &tree] {
        let _ = fs::remove_dir_all(dir);
        fs::create_dir_all(dir)
            .unwrap_or_else(|error| no_result("THE ARCHIVE", &format!("no folder: {error}")));
    }
    let checkout = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let checkout = checkout
        .canonicalize()
        .unwrap_or_else(|error| no_result("THE ARCHIVE", &format!("no checkout: {error}")));
    let limit = Duration::from_secs(ARCHIVE_MINUTES * 60);
    let tar = made.source.join("older.tar");
    let mut archive = Command::new("git");
    archive.arg("-C").arg(&checkout).args(["archive", "--format=tar", "-o"]).arg(&tar);
    archive.arg(OLDER_COMMIT).env("GIT_NO_LAZY_FETCH", "1");
    let what = "the archive from the checkout's git";
    let way = match made_by(what, archive, &made.source.join("archive.log"), limit) {
        Ok(text) => {
            say(&text);
            "from the checkout"
        }
        Err(first) => {
            say(&format!("no archive from the checkout, so a fetch of the test's own: {first}"));
            if let Err(second) = archive_from_a_fetch_of_its_own(&made.source, &tar) {
                let head = |text: &str| text.lines().next().unwrap_or("").to_string();
                let heads = format!("{} AND {}", head(&first), head(&second));
                no_result("THE ARCHIVE", &format!("both ways failed: {heads}\n{first}\n{second}"));
            }
            "from a fetch of its own"
        }
    };
    say(&format!("the archive is {way}"));
    let mut unpack = Command::new("tar");
    unpack.arg("-xf").arg(&tar).arg("-C").arg(&tree);
    match made_by("the unpack of the archive", unpack, &made.source.join("unpack.log"), limit) {
        Ok(text) => say(&text),
        Err(text) => no_result("THE ARCHIVE", &text),
    }
    let _ = fs::remove_file(&tar);

    let ghostty = checkout.join("ghostty-next");
    if !ghostty.join("build.zig").is_file() {
        no_result("THE INNER BUILD", "the checkout has no `ghostty-next/build.zig`");
    }
    for name in LINKED {
        let mut at_head = Command::new("git");
        at_head.arg("-C").arg(&checkout).env("GIT_NO_LAZY_FETCH", "1");
        let mut at_older = Command::new("git");
        at_older.arg("-C").arg(&checkout).env("GIT_NO_LAZY_FETCH", "1");
        if way != "from the checkout" {
            at_older = own_git(&made.source.join("git"), &made.source);
        }
        match (pin(at_head, "HEAD", name), pin(at_older, OLDER_COMMIT, name)) {
            (Ok(head), Ok(older)) if head == older => {
                say(&format!("the 2 commits pin the same commit of {name}: {head}"));
            }
            (Ok(head), Ok(older)) => no_result(
                "THE INNER BUILD",
                &format!("the 2 commits pin different commits of {name}: {head} and {older}"),
            ),
            (Err(text), _) | (_, Err(text)) => {
                no_result("THE INNER BUILD", &format!("no read of the pin of {name}: {text}"))
            }
        }
        let link = tree.join(name);
        let _ = fs::remove_dir(&link);
        if let Err(error) = std::os::unix::fs::symlink(checkout.join(name), &link) {
            no_result("THE INNER BUILD", &format!("no link to the checkout's {name}: {error}"));
        }
        say(&format!("the tree's {name} is a link to the checkout's {name}"));
    }
    let mut build = Command::new("cargo");
    build.current_dir(tree.join("cmux-tui"));
    build.args(["build", "--locked", "--offline", "-p", "cmux-tui", "--bin", "cmux-tui"]);
    let starts = [
        "NEXTEST",
        "__NEXTEST",
        "CARGO_PKG_",
        "CARGO_BIN_",
        "CARGO_MANIFEST_",
        "CARGO_CRATE_",
        "CARGO_PRIMARY_",
    ];
    let names = ["CARGO", "CARGO_TARGET_TMPDIR", "CARGO_MAKEFLAGS", "GIT_DIR", "GIT_WORK_TREE"];
    without(&mut build, &starts, &names);
    build
        .env("CARGO_TARGET_DIR", &made.target)
        .env("CMUX_GHOSTTY_SRC", &ghostty)
        .env("CMUX_TUI_BUILD_COMMIT", OLDER_COMMIT)
        .env("CMUX_TUI_BUILD_TIME", OLDER_COMMIT_TIME)
        .env("CMUX_GIT_SHORT_SHA", &OLDER_COMMIT[..9]);
    let log = made.source.join("build.log");
    match made_by("the older build", build, &log, Duration::from_secs(BUILD_MINUTES * 60)) {
        Ok(text) => say(&text),
        Err(text) => {
            let whole = String::from_utf8_lossy(&fs::read(&log).unwrap_or_default()).to_lowercase();
            let offline = !text.contains("did not end in") && whole.contains("offline");
            no_result(if offline { "THE OFFLINE CRATES" } else { "THE INNER BUILD" }, &text);
        }
    }

    let binary = made.target.join("debug").join("cmux-tui");
    let bytes = fs::read(&binary).unwrap_or_else(|error| {
        no_result("THE COPY", &format!("no executable at {}: {error}", binary.display()))
    });
    let hash: String = Sha256::digest(&bytes).iter().map(|byte| format!("{byte:02x}")).collect();
    say(&format!("the older build's executable has {} bytes and SHA-256 {hash}", bytes.len()));
    drop(bytes);
    OLDER.set(binary).expect("the older build is made one time");
    made
}

/// One part's folder under `/tmp` (a socket path must be short).
struct Folder(PathBuf);

impl Folder {
    fn new(part: &str) -> Self {
        let dir = PathBuf::from("/tmp").join(format!("cmux-drill-{part}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("state").join("sessions")).unwrap();
        Self(dir)
    }

    fn root(&self) -> PathBuf {
        self.0.join("state").join("sessions")
    }

    fn socket(&self) -> PathBuf {
        self.0.join("mux.sock")
    }

    /// The one session's folder: the one that has a registry.
    fn session_folder(&self) -> PathBuf {
        fs::read_dir(self.root())
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .find(|path| path.join(REGISTRY).is_file())
            .expect("the newer build's start makes the registry")
    }

    fn registry(&self) -> PathBuf {
        self.session_folder().join(REGISTRY)
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn command(binary: &Path, folder: &Folder) -> Command {
    let mut command = Command::new(binary);
    command
        .env("CMUX_TUI_STATE_DIR", folder.root())
        .env("CMUX_TUI_CONFIG", folder.0.join("config.json"))
        .env("CMUX_TUI_LOG_FILE", folder.0.join("client.log"))
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("SSH_CONNECTION")
        .env_remove("SSH_CLIENT")
        .env_remove("SSH_TTY")
        .stdin(Stdio::null());
    command
}

/// What one run of a command gave: its exit code and stdout, and the text
/// `exit code, stdout, stderr`, each exact. The 2 outputs go to files of
/// `folder`, not to pipes: a daemon that the command leaves keeps a pipe
/// open, and the read of the pipe would not end.
fn result_of(
    mut command: Command,
    folder: &Folder,
    limit: Duration,
) -> (Option<i32>, String, String) {
    let (out, err) = (folder.0.join("command-stdout.txt"), folder.0.join("command-stderr.txt"));
    let mut child = command
        .stdout(fs::File::create(&out).unwrap())
        .stderr(fs::File::create(&err).unwrap())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + limit;
    let mut in_time = true;
    while child.try_wait().unwrap().is_none() {
        if Instant::now() >= deadline {
            in_time = false;
            let _ = child.kill();
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    let code = child.wait().unwrap().code();
    let stdout = fs::read_to_string(&out).unwrap_or_default().trim().to_string();
    let stderr = fs::read_to_string(&err).unwrap_or_default().trim().to_string();
    let late = if in_time { "" } else { "KILLED AT ITS TIME LIMIT, " };
    (
        code,
        stdout.clone(),
        format!("{late}exit code {code:?}, stdout {stdout:?}, stderr {stderr:?}"),
    )
}

/// The schema number in the store's file, by a read-only connection.
fn number(registry: &Path) -> i64 {
    let db = Connection::open_with_flags(registry, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    db.busy_timeout(Duration::from_secs(5)).unwrap();
    db.query_row(
        "SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'schema_version'",
        [],
        |row| row.get(0),
    )
    .unwrap()
}

/// `__store-schemas --stored` of `binary`: its exit code and text, the
/// workspace registry's number in its answer, and its time.
fn check_by(binary: &Path, folder: &Folder) -> (String, Option<i64>, Duration) {
    let mut command = command(binary, folder);
    command.args(["__store-schemas", "--stored"]);
    let began = Instant::now();
    let (_, stdout, text) = result_of(command, folder, Duration::from_secs(300));
    let time = began.elapsed();
    let answer = serde_json::from_str::<Value>(&stdout)
        .ok()
        .and_then(|value| value.get("workspace_registry").and_then(Value::as_i64));
    (text, answer, time)
}

/// The newer build's check: its text and its answer.
fn check(folder: &Folder) -> (String, Option<i64>) {
    let (text, answer, _) = check_by(newer(), folder);
    (text, answer)
}

/// One request on a new connection to the daemon's socket; its answer.
fn request(folder: &Folder, request: Value) -> Result<Value, String> {
    let stream = UnixStream::connect(folder.socket()).map_err(|error| error.to_string())?;
    stream.set_read_timeout(Some(Duration::from_secs(30))).map_err(|error| error.to_string())?;
    let mut writer = stream.try_clone().map_err(|error| error.to_string())?;
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").map_err(|error| error.to_string())?;
    let mut line = String::new();
    reader.read_line(&mut line).map_err(|error| error.to_string())?;
    serde_json::from_str(&line).map_err(|error| format!("{error}: {line:?}"))
}

/// A daemon of one build that owns the part's session.
struct Owner<'a> {
    child: Child,
    binary: &'static Path,
    folder: &'a Folder,
    session: String,
}

impl<'a> Owner<'a> {
    /// Starts `binary` as the session's daemon. `Err` = the daemon ended
    /// before it answered: its exit code and its stderr.
    fn start(binary: &'static Path, folder: &'a Folder, session: &str) -> Result<Self, String> {
        let _ = fs::remove_file(folder.socket());
        let stderr = folder.0.join("daemon-stderr.txt");
        let child = command(binary, folder)
            .args(["--headless", "--session", session, "--socket"])
            .arg(folder.socket())
            .stdout(Stdio::null())
            .stderr(fs::File::create(&stderr).unwrap())
            .spawn()
            .unwrap();
        let mut owner = Self { child, binary, folder, session: session.to_string() };
        let deadline = Instant::now() + Duration::from_secs(60);
        loop {
            if owner.answers() {
                return Ok(owner);
            }
            let ended = owner.child.try_wait().unwrap();
            if ended.is_some() || Instant::now() >= deadline {
                let _ = owner.child.kill();
                let status = owner.child.wait().unwrap();
                let text = fs::read_to_string(&stderr).unwrap_or_default();
                let log = fs::read_to_string(folder.0.join("client.log")).unwrap_or_default();
                let log_end = log.lines().rev().take(6).collect::<Vec<_>>();
                return Err(format!(
                    "no answer (ended by itself: {}), exit code {:?}, stderr {:?}, the last \
                     lines of its log file, newest first: {log_end:?}",
                    ended.is_some(),
                    status.code(),
                    text.trim()
                ));
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn server(&self, verb: &str) -> Command {
        self.server_of(self.binary, verb)
    }

    /// The `server` command of `binary` for this daemon's session and socket.
    fn server_of(&self, binary: &Path, verb: &str) -> Command {
        let mut command = command(binary, self.folder);
        command.args(["--json", "server", verb, "--session", &self.session, "--socket"]);
        command.arg(self.folder.socket());
        command
    }

    fn answers(&self) -> bool {
        self.server("status").output().is_ok_and(|output| {
            output.status.success()
                && String::from_utf8_lossy(&output.stdout).contains("\"running\"")
        })
    }

    /// A workspace with no terminal: a journal row and no terminal host.
    fn make_workspace(&self, seed: u64) -> String {
        let name = format!("drill-ws-{seed}");
        let created = request(
            self.folder,
            json!({"id": 1, "cmd": "create-workspace",
                   "key": format!("00000000-0000-4000-8000-{seed:012x}"), "name": name,
                   "origin": "user",
                   "mutation_id": format!("00000000-0000-4000-8000-{:012x}", seed + 100)}),
        );
        assert!(
            created.as_ref().is_ok_and(|answer| answer["ok"] == true),
            "create-workspace {name}: {created:?}"
        );
        name
    }

    /// Makes workspaces until the store's file is at 16 (a journal row
    /// waits for its subject rows). The names of the workspaces.
    fn leave_the_store_at_16(&self, first_seed: u64) -> Vec<String> {
        let mut names = Vec::new();
        for seed in first_seed..first_seed + 5 {
            names.push(self.make_workspace(seed));
            let deadline = Instant::now() + Duration::from_secs(2);
            while Instant::now() < deadline {
                if number(&self.folder.registry()) == 16 {
                    return names;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        }
        panic!("the store is not at 16 after 5 workspaces: {}", number(&self.folder.registry()));
    }

    /// Which of `names` the daemon lists.
    fn lists(&self, names: &[String]) -> String {
        let listed = request(self.folder, json!({"id": 2, "cmd": "list-workspaces"}));
        let text = format!("{listed:?}");
        let found = names.iter().filter(|name| text.contains(name.as_str())).count();
        format!("lists {found} of the {} workspaces {names:?}", names.len())
    }

    /// A stop by request; the daemon's exit code.
    fn stop(self) -> String {
        let binary = self.binary;
        self.stop_by(binary)
    }

    /// A stop by the `server stop` request of `binary`, which can be another
    /// build than the daemon's; the daemon's exit code.
    fn stop_by(mut self, binary: &Path) -> String {
        let began = Instant::now();
        let deadline = began + Duration::from_secs(30);
        loop {
            let _ = self.server_of(binary, "stop").output();
            let retry = Instant::now() + Duration::from_secs(1);
            while Instant::now() < retry {
                if let Some(status) = self.child.try_wait().unwrap() {
                    return format!(
                        "stopped by request in {} ms, exit code {:?}",
                        began.elapsed().as_millis(),
                        status.code()
                    );
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            if Instant::now() >= deadline {
                let _ = self.child.kill();
                let _ = self.child.wait();
                return "DID NOT STOP in 30 s; killed".to_string();
            }
        }
    }

    /// SIGKILL, as a crash.
    fn kill(mut self) {
        self.child.kill().unwrap();
        self.child.wait().unwrap();
    }

    /// SIGTERM, then the wait for the exit.
    fn terminate(mut self) -> String {
        let began = Instant::now();
        // This test's own child, which it has not waited for.
        let sent =
            Command::new("kill").args(["-TERM", &self.child.id().to_string()]).status().unwrap();
        assert!(sent.success(), "kill -TERM: {sent:?}");
        let deadline = began + Duration::from_secs(30);
        while Instant::now() < deadline {
            if let Some(status) = self.child.try_wait().unwrap() {
                let after = began.elapsed().as_millis();
                return format!(
                    "ended {after} ms after SIGTERM (SIGKILL comes 5000 ms after it; above 3000 \
                     ms is too near: {}), exit code {:?}, by a signal: {}",
                    after > 3000,
                    status.code(),
                    status.code().is_none()
                );
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        "DID NOT END 30 s after SIGTERM; killed".to_string()
    }
}

impl Drop for Owner<'_> {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The older build as the session's daemon on the part's store: what a
/// person gets, then its stop.
fn the_older_build_opens(part: &str, folder: &Folder, session: &str, names: &[String]) -> bool {
    let before = number(&folder.registry());
    match Owner::start(older(), folder, session) {
        Ok(owner) => {
            say(&format!(
                "({part}) THE OLDER BUILD OPENS the store (its number before: {before}): it \
                 runs and {}; then {}",
                owner.lists(names),
                owner.stop()
            ));
            true
        }
        Err(text) => {
            say(&format!(
                "({part}) THE OLDER BUILD DOES NOT OPEN the store (its number before: \
                 {before}): {text}"
            ));
            false
        }
    }
}

/// The newer build's owner with the store at 16: the part's start.
fn at_16<'a>(part: &str, folder: &'a Folder, session: &str) -> (Owner<'a>, Vec<String>) {
    let owner = Owner::start(newer(), folder, session).unwrap();
    let names = owner.leave_the_store_at_16(1);
    say(&format!(
        "({part}) the newer build runs, {} workspaces made, the store's number is {}",
        names.len(),
        number(&folder.registry())
    ));
    (owner, names)
}

/// The control: the copy runs as a daemon from `/tmp` on a store of its
/// own. A copy that does not is no result of the drill.
fn the_copy_runs_as_a_daemon() {
    let folder = Folder::new("control");
    let owner = Owner::start(older(), &folder, "drill-control").unwrap_or_else(|text| {
        no_result("THE COPY", &format!("the older build does not run as a daemon: {text}"))
    });
    let names = vec![owner.make_workspace(1)];
    say(&format!(
        "the control: the older build runs as a daemon on a store of its own (its number: \
         {}), {}; {}",
        number(&folder.registry()),
        owner.lists(&names),
        owner.stop()
    ));
}

fn part_a() -> bool {
    let folder = Folder::new("a");
    let (owner, names) = at_16("a", &folder, "drill-a");
    let (text, answer) = check(&folder);
    say(&format!(
        "(a) the check beside the live owner: {text}; the store's number after it: {}",
        number(&folder.registry())
    ));
    say(&format!(
        "(a) the newer build: {}; the store's number: {}",
        owner.stop(),
        number(&folder.registry())
    ));
    let opens = the_older_build_opens("a", &folder, "drill-a", &names);
    answer == Some(15) && opens
}

fn part_b() -> bool {
    let folder = Folder::new("b");
    let (owner, names) = at_16("b", &folder, "drill-b");
    owner.kill();
    let before = number(&folder.registry());
    let (text, answer) = check(&folder);
    say(&format!(
        "(b) the owner was killed (the store's number: {before}); the check: {text}; the \
         store's number after it: {}",
        number(&folder.registry())
    ));
    let opens = the_older_build_opens("b", &folder, "drill-b", &names);
    answer == Some(15) && opens
}

/// Parts (c) and (d): the hand case. No check runs before the older build.
fn parts_c_and_d() -> bool {
    let folder = Folder::new("c");
    let (owner, names) = at_16("c", &folder, "drill-c");
    owner.kill();
    say(&format!("(c) the owner was killed; the store's number: {}", number(&folder.registry())));
    // An owner that this `server ensure` starts ends with this test's
    // process (`--exit-with-pid`), also when the stop below does not end it.
    let mut ensure = command(older(), &folder);
    ensure.args(["--json", "server", "ensure", "--session", "drill-c", "--exit-with-pid"]);
    ensure.arg(std::process::id().to_string()).arg("--socket").arg(folder.socket());
    let (_, _, text) = result_of(ensure, &folder, Duration::from_secs(90));
    say(&format!("(c) THE OLDER BUILD's `server ensure` with no check before it: {text}"));
    let mut stop = command(older(), &folder);
    stop.args(["--json", "server", "stop", "--session", "drill-c", "--socket"]);
    stop.arg(folder.socket());
    let (_, _, text) = result_of(stop, &folder, Duration::from_secs(60));
    say(&format!(
        "(c) the older build's `server stop` after it: {text}; the store's number: {}",
        number(&folder.registry())
    ));
    let owner = Owner::start(newer(), &folder, "drill-c").unwrap();
    say(&format!(
        "(d) THE NEWER BUILD OPENS the same store again: it runs and {}; {}; the store's \
         number: {}",
        owner.lists(&names),
        owner.stop(),
        number(&folder.registry())
    ));
    the_older_build_opens("d", &folder, "drill-c", &names)
}

fn part_e() -> bool {
    let folder = Folder::new("e");
    let (owner, names) = at_16("e", &folder, "drill-e");
    say(&format!(
        "(e) the newer build's daemon: {}; the store's number: {}",
        owner.terminate(),
        number(&folder.registry())
    ));
    the_older_build_opens("e", &folder, "drill-e", &names)
}

fn part_f() -> bool {
    let folder = Folder::new("f");
    let (owner, mut names) = at_16("f", &folder, "drill-f");
    let (text, answer) = check(&folder);
    say(&format!("(f) the check beside the live owner: {text}"));
    names.extend(owner.leave_the_store_at_16(50));
    say(&format!(
        "(f) the owner ran on and made a workspace more; the store's number: {}",
        number(&folder.registry())
    ));
    let mut premigrate = command(older(), &folder);
    premigrate.args(["--json", "server", "premigrate-registry", "--session", "drill-f"]);
    premigrate.args(["--max-seconds", "60"]);
    let (_, _, text) = result_of(premigrate, &folder, Duration::from_secs(90));
    say(&format!(
        "(f) THE OLDER BUILD's `server premigrate-registry` beside the live owner: {text}"
    ));
    say(&format!(
        "(f) the newer build: {}; the store's number: {}",
        owner.stop(),
        number(&folder.registry())
    ));
    let opens = the_older_build_opens("f", &folder, "drill-f", &names);
    answer == Some(15) && opens
}

/// Sessions whose owner was killed with the store at 16. The first session
/// is a real one; the others are copies of its folder and of its guard
/// file. No store is read after the kill: a check finds each store as the
/// kill left it (the copies are new files, so the machine's file cache has
/// them: this is not a read from a cold disk).
struct Killed {
    folder: Folder,
    names: Vec<String>,
    copies: Copies,
}

/// The one session of a folder and its copies: `sessions` session folders,
/// each with the files and the guard file of the first.
struct Copies {
    registries: Vec<PathBuf>,
    size: u64,
    folder_bytes: u64,
    /// The names of the files of one session's folder.
    files: Vec<String>,
    /// The first session had a guard file, and each copy has a copy of it.
    guarded: bool,
}

impl Copies {
    /// `None` = not made: the copies would take too much of the disk.
    fn new(part: &str, folder: &Folder, sessions: usize) -> Option<Self> {
        let first = folder.session_folder();
        let session = first.file_name().unwrap().to_str().unwrap().to_string();
        let locks = folder.root().join(LOCKS);
        let guard = locks.join(format!("{session}.lock"));
        let guarded = guard.is_file();
        let found = fs::read_dir(&first)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|path| path.is_file())
            .collect::<Vec<_>>();
        let folder_bytes = found.iter().map(|path| fs::metadata(path).unwrap().len()).sum::<u64>();
        let mut files = found
            .iter()
            .map(|path| path.file_name().unwrap().to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        files.sort();
        // No part fills the disk of the machine: 4 GB of copies is the limit.
        if folder_bytes * u64::try_from(sessions).unwrap() > 4_000_000_000 {
            say(&format!(
                "({part}) {sessions} sessions: NOT RUN: a session's folder has {folder_bytes} \
                 bytes in the files {files:?}, and the copies would take more than 4 GB"
            ));
            return None;
        }
        let mut registries = vec![first.join(REGISTRY)];
        for copy in 1..sessions {
            let name = format!("{session}-{copy:03}");
            let to = folder.root().join(&name);
            fs::create_dir(&to).unwrap();
            for path in &found {
                fs::copy(path, to.join(path.file_name().unwrap())).unwrap();
            }
            if guarded {
                fs::copy(&guard, locks.join(format!("{name}.lock"))).unwrap();
            }
            registries.push(to.join(REGISTRY));
        }
        let size = fs::metadata(&registries[0]).unwrap().len();
        Some(Self { registries, size, folder_bytes, files, guarded })
    }

    /// The names of the files that the first session's folder has now.
    fn files_now(&self) -> Vec<String> {
        let mut files = fs::read_dir(self.registries[0].parent().unwrap())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        files.sort();
        files
    }

    /// How many of the stores are at `wanted`.
    fn at(&self, wanted: i64) -> usize {
        self.registries.iter().filter(|path| number(path) == wanted).count()
    }

    /// The SHA-256 of each store's main file, by a read of the file.
    fn hashes(&self) -> Vec<String> {
        self.registries
            .iter()
            .map(|path| {
                Sha256::digest(fs::read(path).unwrap())
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect()
            })
            .collect()
    }

    fn stores(&self) -> String {
        format!(
            "a store's file has {} bytes; a session's folder has {} bytes in the files {:?}; \
             the conversation store's file is in each folder: {}; each session has a guard \
             file: {}",
            self.size,
            self.folder_bytes,
            self.files,
            self.files.iter().any(|file| file == CONVERSATIONS),
            self.guarded
        )
    }
}

impl Killed {
    /// `None` = not made: the copies would take too much of the disk.
    fn new(part: &str, sessions: usize) -> Option<Self> {
        let folder = Folder::new(&format!("{part}{sessions}"));
        let (owner, names) = at_16(part, &folder, &format!("drill-{part}"));
        owner.kill();
        let copies = Copies::new(part, &folder, sessions)?;
        assert!(copies.guarded, "a killed owner leaves its session's guard file");
        Some(Self { folder, names, copies })
    }

    fn at(&self, wanted: i64) -> usize {
        self.copies.at(wanted)
    }

    fn stores(&self) -> String {
        format!(
            "REAL stores of the newer build's daemon, the product's sync mode; {}",
            self.copies.stores()
        )
    }
}

/// Part (g): 3 times for `sessions` sessions whose owner was killed with the
/// store at 16: the older build's check (it reads and writes nothing), then,
/// on a new set of the same stores, the newer build's first check and the
/// check after it. Its result and the newer build's first time.
fn part_g(sessions: usize) -> (bool, Duration) {
    let each = |time: Duration| time.as_secs_f64() * 1000.0 / sessions as f64;
    // The app waits 10 s for the check. Half of that is the limit here: a
    // person's disk is not this machine's disk.
    let limit = Duration::from_secs(5);
    let Some(set) = Killed::new("g", sessions) else {
        return (false, Duration::ZERO);
    };
    let (older_text, older_answer, older_time) = check_by(older(), &set.folder);
    say(&format!(
        "(g) {sessions} sessions whose owner was killed with the store at 16 ({}): THE OLDER \
         BUILD's CHECK (the code before this change: it reads each store and writes none) took \
         {} ms ({:.2} ms a session): {older_text}; its answer is 16: {}; {} of {sessions} \
         stores are at 16 after it; AT OR ABOVE 5000 ms (half of the app's 10 s): {}",
        set.stores(),
        older_time.as_millis(),
        each(older_time),
        older_answer == Some(16),
        set.at(16),
        older_time >= limit
    ));
    drop(set);
    let Some(set) = Killed::new("g", sessions) else {
        return (false, Duration::ZERO);
    };
    let (first_text, first_answer, first_time) = check_by(newer(), &set.folder);
    let (second_text, second_answer, second_time) = check_by(newer(), &set.folder);
    let at_15 = set.at(15);
    let too_long = first_time.max(second_time) >= limit;
    say(&format!(
        "(g) {sessions} sessions whose owner was killed with the store at 16, a new set ({}): \
         THE NEWER BUILD's FIRST CHECK after the daemon's end took {} ms ({:.2} ms a session): \
         {first_text}; THE CHECK AFTER IT took {} ms ({:.2} ms a session): {second_text}; \
         {at_15} of {sessions} stores are at 15 after the 2 checks; A CHECK AT OR ABOVE 5000 ms \
         (half of the app's 10 s): {too_long}",
        set.stores(),
        first_time.as_millis(),
        each(first_time),
        second_time.as_millis(),
        each(second_time)
    ));
    let good =
        first_answer == Some(15) && second_answer == Some(15) && at_15 == sessions && !too_long;
    (good, first_time)
}

/// Part (h): a check that is ended in its work, as the app ends it at its
/// time limit. `whole` is the time of a whole first check of as many
/// sessions; the check gets half of it, then SIGKILL. The stores that it
/// wrote must stay at 15, the check after it must write the others and say
/// 15, and the older build must open the real session.
fn part_h(sessions: usize, whole: Duration) -> bool {
    let Some(set) = Killed::new("h", sessions) else {
        return false;
    };
    let after = (whole / 2).max(Duration::from_millis(50));
    let mut ended = command(newer(), &set.folder);
    ended.args(["__store-schemas", "--stored"]).stdout(Stdio::null()).stderr(Stdio::null());
    let mut child = ended.spawn().unwrap();
    std::thread::sleep(after);
    let before_the_kill = child.try_wait().unwrap().is_some();
    let _ = child.kill();
    let status = child.wait().unwrap();
    let written = set.at(15);
    let real_at = number(&set.copies.registries[0]);
    let (text, answer, time) = check_by(newer(), &set.folder);
    let at_15 = set.at(15);
    let in_its_work = !before_the_kill && written > 0 && written < sessions;
    say(&format!(
        "(h) {sessions} sessions whose owner was killed with the store at 16 ({}): THE CHECK GOT \
         SIGKILL {} ms after its start (half of the {} ms of a whole first check); it ended \
         before the kill: {before_the_kill}; its exit code: {:?}; {written} of {sessions} \
         stores are at 15 after the kill (ENDED IN ITS WORK: {in_its_work}); the real \
         session's store is at {real_at}; THE CHECK AFTER IT took {} ms: {text}; {at_15} of \
         {sessions} stores are at 15 after it",
        set.stores(),
        after.as_millis(),
        whole.as_millis(),
        status.code(),
        time.as_millis()
    ));
    let opens = match Owner::start(older(), &set.folder, "drill-h") {
        Ok(owner) => {
            say(&format!(
                "(h) THE OLDER BUILD OPENS the real session's store: it runs and {}; then {}",
                owner.lists(&set.names),
                owner.stop()
            ));
            true
        }
        Err(text) => {
            say(&format!("(h) THE OLDER BUILD DOES NOT OPEN the real session's store: {text}"));
            false
        }
    };
    in_its_work && answer == Some(15) && at_15 == sessions && opens
}

/// One half of part (i): `sessions` OLD stores (the older build's daemon made
/// the first and stopped by request; the others are copies of its folder)
/// and one live session of `binary` beside them; then 2 checks of `binary`.
/// No store of the set is opened between the stop and the first check: the
/// first check is the first open of each store. The copies are new files, so
/// the machine's file cache has them: this is not a read from a cold disk.
fn old_stores(build: &str, binary: &'static Path, sessions: usize) -> bool {
    let each = |time: Duration| time.as_secs_f64() * 1000.0 / sessions as f64;
    let folder = Folder::new(&format!("i{build}{sessions}"));
    let maker = Owner::start(older(), &folder, "drill-old").unwrap();
    maker.make_workspace(1);
    let stopped = maker.stop();
    let Some(old) = Copies::new("i", &folder, sessions) else {
        return false;
    };
    let before = old.hashes();
    let live = Owner::start(binary, &folder, "drill-live").unwrap();
    let live_registry = fs::read_dir(folder.root())
        .unwrap()
        .map(|entry| entry.unwrap().path().join(REGISTRY))
        .find(|path| path.is_file() && !old.registries.contains(path))
        .expect("the live session's registry");
    // The newer build's live session gets journal rows until its file is at
    // 16; the older build's gets one workspace and stays at its number.
    let most = if binary == newer() { 5 } else { 1 };
    for seed in 1..=most {
        live.make_workspace(seed);
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline && number(&live_registry) != 16 {
            std::thread::sleep(Duration::from_millis(50));
        }
        if number(&live_registry) == 16 {
            break;
        }
    }
    let live_at = number(&live_registry);
    let (first_text, first_answer, first_time) = check_by(binary, &folder);
    let (again_text, again_answer, again_time) = check_by(binary, &folder);
    let changed = old.hashes().iter().zip(&before).filter(|(now, was)| now != was).count();
    let files_after = old.files_now();
    let at_15 = old.at(15);
    say(&format!(
        "(i) {sessions} OLD stores (the older build's daemon made the first and {stopped}; the \
         others are copies of its folder; {}) + 1 live session of the {build} build (the number \
         in its store's file: {live_at}): THE {build} BUILD's FIRST CHECK took {} ms ({:.2} ms \
         a session): {first_text}; ITS CHECK AGAIN took {} ms ({:.2} ms a session): \
         {again_text}; A FIRST CHECK AT OR ABOVE 5000 ms (half of the app's 10 s): {}; the main \
         file of {changed} of {sessions} old stores changed in the 2 checks (SHA-256); \
         {at_15} of {sessions} old stores are at 15 after them; the files of an old session's \
         folder after them: {files_after:?}; the live session {}",
        old.stores(),
        first_time.as_millis(),
        each(first_time),
        again_time.as_millis(),
        each(again_time),
        first_time >= Duration::from_secs(5),
        live.stop()
    ));
    first_answer == Some(15) && again_answer == Some(15) && changed == 0 && at_15 == sessions
}

/// Part (i): the old stores with the older build's check (the code before
/// this change), then on a new set with the newer build's check. A time is
/// not in the result: the read of an old store is the older build's code.
fn part_i(sessions: usize) -> bool {
    let by_the_older = old_stores("older", older(), sessions);
    let by_the_newer = old_stores("newer", newer(), sessions);
    by_the_older && by_the_newer
}

/// Part (j): the newer build's check with an end time of its own, as the
/// app's half of the mend will ask it: `--stored --within-ms N` for
/// `sessions` sessions whose owner was killed with the store at 16, asked
/// again until it gives a number. Each ask: its time, its exit code and
/// answer, and how many stores are at 15 after it. The check reads its
/// clock only between 2 sessions, so an ask can end after its N ms by one
/// session's write; the part fails at an ask that took N + 1000 ms or more.
fn part_j(sessions: usize, within: Duration) -> bool {
    let Some(set) = Killed::new("j", sessions) else {
        return false;
    };
    let millis = within.as_millis().to_string();
    let limit = within + Duration::from_secs(1);
    let mut asks: Vec<String> = Vec::new();
    let mut slowest = Duration::ZERO;
    let mut answer: Option<i64> = None;
    // 40 asks at the most: a check that never gives a number ends the part.
    while answer.is_none() && asks.len() < 40 {
        let mut ask = command(newer(), &set.folder);
        ask.args(["__store-schemas", "--stored", "--within-ms", millis.as_str()]);
        let began = Instant::now();
        let (code, stdout, _) = result_of(ask, &set.folder, Duration::from_secs(300));
        let time = began.elapsed();
        slowest = slowest.max(time);
        answer = serde_json::from_str::<Value>(&stdout)
            .ok()
            .and_then(|value| value.get("workspace_registry").and_then(Value::as_i64));
        let ask_number = asks.len() + 1;
        let written = set.at(15);
        asks.push(format!(
            "ask {ask_number}: {} ms, exit code {code:?}, stdout {stdout:?}, {written} of \
             {sessions} stores at 15 after it",
            time.as_millis()
        ));
    }
    let at_15 = set.at(15);
    let too_long = slowest >= limit;
    say(&format!(
        "(j) {sessions} sessions whose owner was killed with the store at 16 ({}): THE NEWER \
         BUILD's CHECK WITH `--within-ms {millis}`, asked again until it gives a number: {} \
         asks; {}; the slowest ask took {} ms; AN ASK AT OR ABOVE {} ms (its end time and 1000 \
         ms): {too_long}; the last answer is 15: {}; {at_15} of {sessions} stores are at 15 \
         after the last ask",
        set.stores(),
        asks.len(),
        asks.join("; "),
        slowest.as_millis(),
        limit.as_millis(),
        answer == Some(15)
    ));
    answer == Some(15) && at_15 == sessions && !too_long
}

/// Part (k): the check beside the live owner, then the OLDER build's
/// `server stop` request to the newer build's daemon, then ONE check more
/// of the newer build with no owner, then the older build. A stop that
/// leaves the store at 16 gets its 15 from that check; a stop that leaves
/// 15 gets a check that only reads.
fn part_k() -> bool {
    let folder = Folder::new("k");
    let (owner, names) = at_16("k", &folder, "drill-k");
    let (text, answer) = check(&folder);
    say(&format!(
        "(k) the check beside the live owner: {text}; the store's number after it: {}",
        number(&folder.registry())
    ));
    let stopped = owner.stop_by(older());
    let after_the_stop = number(&folder.registry());
    let (more_text, more_answer) = check(&folder);
    let after_the_check = number(&folder.registry());
    say(&format!(
        "(k) THE OLDER BUILD's `server stop` REQUEST to the newer build's daemon: {stopped}; the \
         store's number after it: {after_the_stop}; ONE CHECK MORE of the newer build, with no \
         owner: {more_text}; the store's number after it: {after_the_check}"
    ));
    let opens = the_older_build_opens("k", &folder, "drill-k", &names);
    answer == Some(15) && more_answer == Some(15) && after_the_check == 15 && opens
}

#[test]
fn rollback_drill_with_the_older_builds_copy() {
    // The older build first: its 2 folders go last, after each part's folder.
    let _made = make_the_older_build();
    let folder = Folder::new("reads");
    for (build, binary) in [("older", older()), ("newer", newer())] {
        let mut readable = command(binary, &folder);
        readable.arg("__store-schemas");
        let (_, answer, text) = result_of(readable, &folder, Duration::from_secs(30));
        say(&format!("the {build} build reads: {text}"));
        if build == "older" && answer != OLDER_READS {
            no_result("THE COPY", &format!("the older build does not answer {OLDER_READS}"));
        }
    }
    drop(folder);
    the_copy_runs_as_a_daemon();
    let mut results = vec![
        ("a", part_a()),
        ("b", part_b()),
        ("c and d", parts_c_and_d()),
        ("e", part_e()),
        ("f", part_f()),
        ("k", part_k()),
    ];
    let mut whole_at_80 = Duration::ZERO;
    for (name, sessions) in [("g 8", 8), ("g 80", 80), ("g 800", 800)] {
        let (good, first_time) = part_g(sessions);
        if sessions == 80 {
            whole_at_80 = first_time;
        }
        results.push((name, good));
    }
    results.push(("h", part_h(80, whole_at_80)));
    for (name, sessions) in [("i 8", 8), ("i 80", 80), ("i 800", 800)] {
        results.push((name, part_i(sessions)));
    }
    results.push(("j 800", part_j(800, Duration::from_secs(5))));
    say(&format!(
        "EACH PART (a to f: true = the older build opened the store at the part's end, and a \
         check beside a live owner said 15; g: true = both checks of the newer build said 15, \
         each store is at 15, and each of the 2 took less than 5000 ms; h: true = the check \
         was ended in its work, the check after it said 15, each store is at 15, and the older \
         build opened the real session's store; i: true = each of the 4 checks said 15, the \
         main file of no old store changed, and each old store is at 15; its times are not in \
         the result; j: true = the last ask with an end time of 5000 ms said 15, each store is \
         at 15, and each ask took less than 6000 ms; k: true = both checks said 15, the store \
         is at 15 after the check with no owner, and the older build opened the store): \
         {results:?}"
    ));
    assert!(results.iter().all(|(_, good)| *good), "{results:?}");
}
