//! DRILL, NOT FOR A MERGE. A measure of the rollback check on a commit of
//! the base branch, with this commit's real `cmux-tui`: how long ONE plain
//! check takes on a state root with many sessions whose stores no daemon
//! owns, and what the app's rule of asks with an end time gives on the same
//! kind of state.
//!
//! The app's rule is Swift and is not on this branch. This test has a copy
//! of it in Rust (see `THE COPY OF THE APP's RULE` below). So this test is a
//! measure of the CLI and of the rule; it is NOT a run of the app.
//!
//! The state: this build's daemon starts headless with one session in a
//! folder below `/tmp`, one workspace is made by request, and the daemon
//! gets SIGKILL. Its store's files and its guard file stay, and no daemon
//! owns them. Then the session's folder and its guard file are copied until
//! the state root has the wanted count of sessions. The files are new, so
//! they are in the machine's file cache: a cold cache is NOT measured.
//!
//! The parts, for 800 sessions and then for 2,000 sessions:
//! (i)  on a new state: ONE `__store-schemas --stored` call with no end time
//!      and with no stop at the app's 10 s: its time;
//! (ii) 2 runs, each on a new state: the app's rule for its 2 state roots
//!      (root 1 is the state, root 2 has no session): each call's time, exit
//!      code and count of sessions read; the end (the numbers or no answer);
//!      the sum of the time.
//!
//! One state is on the disk at a time. Each state's folder is deleted when
//! its part ends, in each way out (a failed assert too). At its start the
//! test deletes each folder of its own name prefix below `/tmp` that is
//! older than 1 hour: a test that the runner ended left one.
//!
//! Each line starts with `ask drill:`. The test fails only when a state of
//! 800 sessions is not made. A state of 2,000 sessions that is not made
//! (the disk) is the line `NOT RUN` for that size.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime};

use serde_json::{Value, json};

// THE COPY OF THE APP's RULE. The app's probe is
// `Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/StoreSchemaProbe.swift`
// at commit 6f4ba8e26fb0444b7c7866b0d0ab0b7628449015 (the pull request of
// the app's half; not on this branch). Each constant and each step of the
// copy names its line in that file at that commit, as `:LINE`.

/// `:15`, `timeout: Duration = .seconds(10)`: the app ends each call of the
/// CLI after this time.
const TIMEOUT: Duration = Duration::from_secs(10);
/// `:55`, `static let checkEndMilliseconds = 5000`: the end time that each
/// ask gives the check.
const CHECK_END_MILLISECONDS: u64 = 5000;
/// `:58`, `static let maxStoredCalls = 6`: the most calls of the CLI in one
/// call of the probe, for all state roots together.
const MAX_STORED_CALLS: usize = 6;

/// The name prefix of each folder of this test below `/tmp`.
const PREFIX: &str = "cmux-ask-drill-";
/// A folder of this test that is older is a folder that a test left.
const OLD: Duration = Duration::from_secs(3600);
/// No state fills the disk of the machine: 4 GB of copies is the limit.
const DISK_LIMIT: u64 = 4_000_000_000;
const REGISTRY: &str = "workspace-registry.sqlite3";
const LOCKS: &str = "session-locks";

fn say(text: &str) {
    println!("ask drill: {text}");
}

/// A text of the CLI for the log: no name below a home folder, and 600
/// characters at most.
fn safe(text: &str) -> String {
    let mut text = text.to_string();
    if let Ok(home) = std::env::var("HOME")
        && home.len() > 1
    {
        text = text.replace(&home, "HOME");
    }
    for root in ["/Users/", "/home/"] {
        let mut out = String::new();
        let mut rest = text.as_str();
        while let Some(at) = rest.find(root) {
            let after = at + root.len();
            out.push_str(&rest[..after]);
            rest = &rest[after..];
            let end = rest
                .find(|character: char| {
                    character == '/' || character == '"' || character.is_whitespace()
                })
                .unwrap_or(rest.len());
            out.push_str("NAME");
            rest = &rest[end..];
        }
        out.push_str(rest);
        text = out;
    }
    text.chars().take(600).collect()
}

/// The start of the test: each folder of this test's name prefix below
/// `/tmp` that is older than 1 hour is deleted.
fn delete_old_folders() {
    let Ok(entries) = fs::read_dir("/tmp") else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.starts_with(PREFIX) {
            continue;
        }
        let age = entry
            .metadata()
            .and_then(|data| data.modified())
            .ok()
            .and_then(|at| SystemTime::now().duration_since(at).ok());
        if age.is_some_and(|age| age >= OLD) {
            say(&format!(
                "an old folder of this test, /tmp/{name}: the delete: {:?}",
                fs::remove_dir_all(entry.path())
            ));
        }
    }
}

/// One state's folder under `/tmp` (a socket path must be short). Its drop
/// deletes it: at the end of its part, at an early return, and at a failed
/// assert (the panic of a test unwinds, and the unwind drops it).
struct Folder(PathBuf);

impl Folder {
    fn new(part: &str) -> Self {
        let dir = PathBuf::from("/tmp").join(format!("{PREFIX}{part}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("state").join("sessions")).unwrap();
        fs::create_dir_all(dir.join("state-2").join("sessions")).unwrap();
        Self(dir)
    }

    /// The state root with the sessions.
    fn root(&self) -> PathBuf {
        self.0.join("state").join("sessions")
    }

    /// A second state root, with no session: the app has 2 state roots.
    fn second_root(&self) -> PathBuf {
        self.0.join("state-2").join("sessions")
    }

    fn socket(&self) -> PathBuf {
        self.0.join("mux.sock")
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let done = fs::remove_dir_all(&self.0);
        say(&format!("the delete of a state's folder: {done:?}"));
    }
}

/// This build's CLI with `root` as its state root, and its config and its
/// log file in the test's folder.
fn command(folder: &Folder, root: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .env("CMUX_TUI_STATE_DIR", root)
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

/// What one call of the CLI gave.
struct Run {
    /// False = this test ended the process at its limit, as the app ends a
    /// call at its timeout.
    in_time: bool,
    code: Option<i32>,
    stdout: String,
    stderr: String,
    time: Duration,
}

/// One run of `command`, ended with SIGKILL at `limit`. The 2 outputs go to
/// files of `folder`, not to pipes.
fn run(mut command: Command, folder: &Folder, limit: Duration) -> Run {
    let (out, err) = (folder.0.join("command-stdout.txt"), folder.0.join("command-stderr.txt"));
    let stdout = fs::File::create(&out).unwrap();
    let stderr = fs::File::create(&err).unwrap();
    let began = Instant::now();
    let mut child = command.stdout(stdout).stderr(stderr).spawn().unwrap();
    let deadline = began + limit;
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
    let time = began.elapsed();
    Run {
        in_time,
        code,
        stdout: fs::read_to_string(&out).unwrap_or_default().trim().to_string(),
        stderr: fs::read_to_string(&err).unwrap_or_default().trim().to_string(),
        time,
    }
}

/// `:108-117`, `enum Answer`: what one call of the CLI gave, as the probe
/// reads it.
enum Answer {
    /// `:109`, `.schemas`: the numbers, as the CLI printed them.
    Schemas(String),
    /// `:112`, `.notReady`: the count of sessions read, 0 when it has none.
    NotReady(u64),
    /// `:114`, `.failed`: the CLI ended by itself with an exit that is not 0.
    Failed,
    /// `:116`, `.nothing`.
    Nothing,
}

/// `:130-139`, `ask`. Not in the copy: `:134`, a CLI that does not start
/// (this test's CLI is there, and a failed start fails the test).
fn answer_of(run: &Run) -> Answer {
    // `:135`, `guard outcome.succeeded else { return outcome.exited ? .failed : .nothing }`:
    // a call that the timeout or a signal ended is nothing; an exit that is
    // not 0 by the CLI itself is a failure.
    if !run.in_time {
        return Answer::Nothing;
    }
    match run.code {
        None => return Answer::Nothing,
        Some(0) => {}
        Some(_) => return Answer::Failed,
    }
    // `:153` and `:145`: the output must be one JSON object.
    let Ok(Value::Object(object)) = serde_json::from_str::<Value>(&run.stdout) else {
        return Answer::Nothing;
    };
    // `:136`, `parse` (`:152-160`): each value is a number = the schemas.
    if object.values().all(Value::is_number) {
        return Answer::Schemas(run.stdout.clone());
    }
    // `:137`, `notReadyCount` (`:144-150`): an object `not_ready`; its
    // `sessions_read` when that is a number, else 0. The CLI prints a whole
    // number there, so the copy reads a whole number.
    match object.get("not_ready") {
        Some(Value::Object(not_ready)) => {
            Answer::NotReady(not_ready.get("sessions_read").and_then(Value::as_u64).unwrap_or(0))
        }
        // `:138`: an output of neither form.
        _ => Answer::Nothing,
    }
}

/// An answer for the log.
fn form(answer: &Answer, run: &Run) -> String {
    match answer {
        Answer::Schemas(numbers) => format!("THE NUMBERS {numbers}"),
        Answer::NotReady(read) => {
            format!("not_ready, {read} sessions read: {}", safe(&run.stdout))
        }
        Answer::Failed => format!("A FAILURE, stderr {:?}", safe(&run.stderr)),
        Answer::Nothing => format!(
            "NOTHING (this test ended the call at its limit: {}), stdout of {} bytes, stderr {:?}",
            !run.in_time,
            run.stdout.len(),
            safe(&run.stderr)
        ),
    }
}

/// One call of the check for `root`, ended at `limit`: `__store-schemas
/// --stored`, and with `in_its_time` the end time of `:85`
/// (`["--stored", "--within-ms", String(Self.checkEndMilliseconds)]`).
fn check(folder: &Folder, root: &Path, in_its_time: bool, limit: Duration) -> Run {
    let mut command = command(folder, root);
    command.args(["__store-schemas", "--stored"]);
    if in_its_time {
        let millis = CHECK_END_MILLISECONDS.to_string();
        command.args(["--within-ms", millis.as_str()]);
    }
    run(command, folder, limit)
}

/// `:84-103`, `stored(environment:calls:)`: one state root, `limit` calls
/// of the CLI at most. The numbers (`None` = no answer) and the count of
/// calls. Each call adds its line to `lines`.
fn stored_of_one_root(
    folder: &Folder,
    name: &str,
    root: &Path,
    limit: usize,
    lines: &mut Vec<String>,
) -> (Option<String>, usize) {
    let mut calls = 0; // `:86`, `var calls = 0`
    let mut read = 0; // `:87`, `var read = 0`
    // `:88`, `asks: while calls < limit - 1`.
    while calls < limit - 1 {
        calls += 1; // `:89`
        // `:90`, `switch await ask(arguments: inItsTime, environment: environment)`.
        let run = check(folder, root, true, TIMEOUT);
        let answer = answer_of(&run);
        lines.push(format!(
            "{name}, call {calls}, an ask with the end time: {} ms, exit code {:?}: {}",
            run.time.as_millis(),
            run.code,
            form(&answer, &run)
        ));
        match answer {
            // `:91-92`, `case .schemas(let schemas): return (schemas, calls)`.
            Answer::Schemas(numbers) => return (Some(numbers), calls),
            // `:93-94`, `case .notReady(let now) where now > read: read = now`.
            Answer::NotReady(now) if now > read => read = now,
            // `:95-96`, `case .notReady, .failed: break asks`.
            Answer::NotReady(_) | Answer::Failed => break,
            // `:97-98`, `case .nothing: return (nil, calls)`.
            Answer::Nothing => return (None, calls),
        }
    }
    // `:101`, `let plain = await run(arguments: ["--stored"], environment: environment)`.
    let run = check(folder, root, false, TIMEOUT);
    let answer = answer_of(&run);
    lines.push(format!(
        "{name}, call {}, THE PLAIN CALL with no end time: {} ms, exit code {:?}: {}",
        calls + 1,
        run.time.as_millis(),
        run.code,
        form(&answer, &run)
    ));
    // `:124-127`, `run`: only the numbers are an answer.
    let plain = match answer {
        Answer::Schemas(numbers) => Some(numbers),
        _ => None,
    };
    (plain, calls + 1) // `:102`, `return (plain, calls + 1)`
}

/// `:35-48`, `stored(stateDirectories:)`: all the state roots, in their
/// order. True = each root gave its numbers; and the count of calls. The
/// merge of the numbers (`:45`) is not in the copy: the measure does not
/// need it.
fn stored(folder: &Folder, roots: &[(&str, PathBuf)], lines: &mut Vec<String>) -> (bool, usize) {
    let mut calls_left = MAX_STORED_CALLS as i64; // `:37`, `var callsLeft = Self.maxStoredCalls`
    let mut calls_made = 0;
    for (index, (name, root)) in roots.iter().enumerate() {
        // `:41`, `let limit = max(1, callsLeft - (stateDirectories.count - index - 1))`.
        let after = (roots.len() - index - 1) as i64;
        let limit = (calls_left - after).max(1) as usize;
        // `:42`, `let (found, calls) = await stored(environment: environment, calls: limit)`.
        let (found, calls) = stored_of_one_root(folder, name, root, limit, lines);
        calls_left -= calls as i64; // `:43`, `callsLeft -= calls`
        calls_made += calls;
        // `:44`, `guard let found else { return nil }`.
        if found.is_none() {
            return (false, calls_made);
        }
    }
    (true, calls_made) // `:47`
}

/// One request on a new connection to the daemon's socket; its answer.
fn request(folder: &Folder, request: &Value) -> Result<Value, String> {
    let stream = UnixStream::connect(folder.socket()).map_err(|error| error.to_string())?;
    stream.set_read_timeout(Some(Duration::from_secs(30))).map_err(|error| error.to_string())?;
    let mut writer = stream.try_clone().map_err(|error| error.to_string())?;
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").map_err(|error| error.to_string())?;
    let mut line = String::new();
    reader.read_line(&mut line).map_err(|error| error.to_string())?;
    serde_json::from_str(&line).map_err(|error| error.to_string())
}

/// This build's daemon, the owner of the state's one session. Its drop ends
/// it with SIGKILL.
struct Owner {
    child: Child,
}

impl Owner {
    /// Starts the daemon. `Err` = it gave no answer in 60 s.
    fn start(folder: &Folder, session: &str) -> Result<Self, String> {
        let stderr = folder.0.join("daemon-stderr.txt");
        let child = command(folder, &folder.root())
            .args(["--headless", "--session", session, "--socket"])
            .arg(folder.socket())
            .stdout(Stdio::null())
            .stderr(fs::File::create(&stderr).unwrap())
            .spawn()
            .unwrap();
        let mut owner = Self { child };
        let deadline = Instant::now() + Duration::from_secs(60);
        loop {
            let status = command(folder, &folder.root())
                .args(["--json", "server", "status", "--session", session, "--socket"])
                .arg(folder.socket())
                .output();
            let answers = status.is_ok_and(|output| {
                output.status.success()
                    && String::from_utf8_lossy(&output.stdout).contains("\"running\"")
            });
            if answers {
                return Ok(owner);
            }
            let ended = owner.child.try_wait().unwrap();
            if ended.is_some() || Instant::now() >= deadline {
                let text = fs::read_to_string(&stderr).unwrap_or_default();
                return Err(format!(
                    "the daemon gave no answer (ended by itself: {}, exit code {:?}), stderr {:?}",
                    ended.is_some(),
                    ended.and_then(|status| status.code()),
                    safe(text.trim())
                ));
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// A state root with `sessions` sessions whose stores no daemon owns.
struct State {
    folder: Folder,
    text: String,
}

impl State {
    /// `Err` = the state is not made, with the cause. The folder is deleted
    /// then too (the drop of `folder`).
    fn new(part: &str, sessions: usize) -> Result<Self, String> {
        let folder = Folder::new(part);
        let owner = Owner::start(&folder, "ask-drill")?;
        // A workspace with no terminal: a journal row and no terminal host.
        let made = request(
            &folder,
            &json!({"id": 1, "cmd": "create-workspace",
                    "key": "00000000-0000-4000-8000-000000000001",
                    "name": "ask-drill-workspace", "origin": "user",
                    "mutation_id": "00000000-0000-4000-8000-000000000101"}),
        );
        let workspace = made.is_ok_and(|answer| answer["ok"] == true);
        // The journal's write gets its time, then SIGKILL, as a crash.
        std::thread::sleep(Duration::from_millis(500));
        drop(owner);
        let root = folder.root();
        let first = fs::read_dir(&root)
            .map_err(|error| error.to_string())?
            .flatten()
            .map(|entry| entry.path())
            .find(|path| path.join(REGISTRY).is_file())
            .ok_or_else(|| "the daemon's start made no registry".to_string())?;
        let session = first.file_name().unwrap().to_string_lossy().into_owned();
        let locks = root.join(LOCKS);
        let guard = locks.join(format!("{session}.lock"));
        let guarded = guard.is_file();
        let files = fs::read_dir(&first)
            .map_err(|error| error.to_string())?
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.is_file())
            .collect::<Vec<_>>();
        let bytes = files
            .iter()
            .map(|path| fs::metadata(path).map(|data| data.len()).unwrap_or(0))
            .sum::<u64>();
        let all = bytes * u64::try_from(sessions).unwrap();
        if all > DISK_LIMIT {
            return Err(format!(
                "{sessions} sessions of {bytes} bytes each are {all} bytes, above this test's \
                 disk limit of {DISK_LIMIT} bytes"
            ));
        }
        for copy in 1..sessions {
            let name = format!("{session}-{copy:04}");
            let to = root.join(&name);
            fs::create_dir(&to).map_err(|error| format!("copy {copy}: {error}"))?;
            for path in &files {
                fs::copy(path, to.join(path.file_name().unwrap()))
                    .map_err(|error| format!("copy {copy}: {error}"))?;
            }
            if guarded {
                fs::copy(&guard, locks.join(format!("{name}.lock")))
                    .map_err(|error| format!("copy {copy}: {error}"))?;
            }
        }
        let text = format!(
            "{sessions} sessions whose stores no daemon owns (a session's folder has {bytes} \
             bytes in {} files; each session has a guard file: {guarded}; the workspace was \
             made by request: {workspace})",
            files.len()
        );
        Ok(Self { folder, text })
    }
}

/// Part (i): ONE plain call with no end time, and with no stop at the app's
/// 10 s (this test's limit is 300 s). `Err` = the state was not made. The
/// call's time when it gave the numbers.
fn part_i(sessions: usize) -> Result<Option<Duration>, String> {
    let state = State::new(&format!("i-{sessions}"), sessions)?;
    let run = check(&state.folder, &state.folder.root(), false, Duration::from_secs(300));
    let answer = answer_of(&run);
    say(&format!(
        "({sessions}) (i) {}: ONE PLAIN CALL with no end time and with no stop at 10 s: {} ms, \
         exit code {:?}: {}; AT OR ABOVE THE APP's 10 s: {}",
        state.text,
        run.time.as_millis(),
        run.code,
        form(&answer, &run),
        run.time >= TIMEOUT
    ));
    Ok(matches!(answer, Answer::Schemas(_)).then_some(run.time))
}

/// Part (ii), one run: the app's rule for its 2 state roots, on a new
/// state. Root 1 is the state; root 2 has no session, and the check of such
/// a root gives its (empty) numbers at the first ask. So root 1 gets 5 of
/// the 6 calls: 4 asks and the plain call (`:41`). With root 2 as the first
/// root the count is the same: root 2 uses 1 call, and 5 stay. `Err` = the
/// state was not made.
fn part_ii(sessions: usize, number: usize, plain: Option<Duration>) -> Result<(), String> {
    let state = State::new(&format!("r{number}-{sessions}"), sessions)?;
    let roots =
        [("root 1", state.folder.root()), ("root 2 (no session)", state.folder.second_root())];
    let mut lines = Vec::new();
    let began = Instant::now();
    let (numbers, calls) = stored(&state.folder, &roots, &mut lines);
    let sum = began.elapsed();
    let against = match plain {
        Some(plain) => format!(
            "the plain call of (i) took {} ms; THE SUM IS ABOVE IT BY MORE THAN 5000 ms: {}",
            plain.as_millis(),
            sum > plain + Duration::from_secs(5)
        ),
        None => "the plain call of (i) gave no numbers".to_string(),
    };
    say(&format!(
        "({sessions}) (ii) run {number}, {}: THE APP's RULE (asks with `--within-ms \
         {CHECK_END_MILLISECONDS}`, each call ended at {} ms, {MAX_STORED_CALLS} calls at most \
         for the 2 roots): {calls} calls: {}; THE END: {}; THE SUM: {} ms; {against}",
        state.text,
        TIMEOUT.as_millis(),
        lines.join("; "),
        if numbers { "THE NUMBERS" } else { "NO ANSWER" },
        sum.as_millis()
    ));
    Ok(())
}

/// The 3 measures of one size, one after the other: one state on the disk
/// at a time. `Err` = a state was not made, with the cause.
fn size(sessions: usize) -> Result<(), String> {
    let plain = part_i(sessions)?;
    part_ii(sessions, 1, plain)?;
    part_ii(sessions, 2, plain)
}

#[test]
fn rollback_ask_drill_at_a_base_commit() {
    delete_old_folders();
    let first = size(800);
    if let Err(cause) = &first {
        say(&format!("(800) NOT RUN from here: a state was not made: {cause}"));
    }
    if let Err(cause) = size(2000) {
        say(&format!("(2000) NOT RUN from here: a state was not made: {cause}"));
    }
    assert!(first.is_ok(), "a state of 800 sessions was not made: {first:?}");
}
