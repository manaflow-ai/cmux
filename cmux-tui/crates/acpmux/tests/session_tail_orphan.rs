//! `acpmux session tail` whose caller is gone (2026-11-20, a lane VM). Four
//! `acpmux session tail <id> --since N --suppress-reads`, started over ssh under `sh -s`, kept
//! running once the ssh caller left and grew to 30, 16, 5.6 and 1.8 GB resident in 10 to 15
//! minutes, until the OOM killer took other jobs. The chat's log was 12 GB (1.1M records):
//! the tail read every record after the cursor into memory before writing any, so it neither
//! stayed small nor ever wrote to the closed pipe that would have ended it.
//!
//! The real daemon and CLI run here over a long chat log, through the daemon's socket. Each
//! test prints one `acpmux-session-tail:` JSON line (resident size over time, exit latency).
//! `ACPMUX_TAIL_BIN=<acpmux build>` runs the same harness against another build (the base, for
//! a before/after); `ACPMUX_TAIL_MEASURE_ONLY=1` prints the numbers without asserting.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The harness knobs reach the re-started test process (`daemon_env::enter` clears the rest).
const HERMETIC: daemon_env::Process = daemon_env::Process::deny().keep(&[
    "ACPMUX_TAIL_BIN",
    "ACPMUX_TAIL_MEASURE_ONLY",
    "ACPMUX_TAIL_LOG_MB",
]);

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, BufWriter, Read, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// The most a tail may grow to, resident, whatever the log's size.
const RSS_CAP_KB: u64 = 160 * 1024;
/// How long a tail may run once nobody can read it.
const EXIT_WITHIN: Duration = Duration::from_secs(5);
/// A tail the harness ends itself, past this resident size (a build without the fix), so the
/// host keeps its memory.
const RSS_KILL_KB: u64 = 3 * 1024 * 1024;
/// How long the harness watches a tail that does not end.
const WATCH_FOR: Duration = Duration::from_secs(30);

fn env_or(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn measure_only() -> bool {
    std::env::var_os("ACPMUX_TAIL_MEASURE_ONLY").is_some()
}

/// The CLI build the tail runs: this test's, or `ACPMUX_TAIL_BIN`'s.
fn tail_binary() -> PathBuf {
    let tail_bin = daemon_env::bin();
    std::env::var_os("ACPMUX_TAIL_BIN").map(PathBuf::from).unwrap_or_else(|| tail_bin.into())
}

fn private_dir(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(path).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
}

fn set_private(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

/// A busy chat's log of about `mb` MB in 8 MB segments: turns of streamed reply chunks and
/// tool calls with outputs of a few KB (reads, which `--suppress-reads` blanks). Returns the
/// number of records.
fn write_log(session: &Path, mb: u64) -> u64 {
    let events = session.join("events");
    private_dir(&events);
    let open = |n: u32| {
        let path = events.join(format!("{n:06}.ndjson"));
        let file = std::fs::File::create(&path).unwrap();
        set_private(&path);
        BufWriter::new(file)
    };
    let (mut seq, mut written, mut segment, mut in_segment) = (0u64, 0u64, 1u32, 0u64);
    let mut out = open(segment);
    let chunk = "word ".repeat(40);
    let output = "line of a file that was read\n".repeat(120);
    let mut turn = 0u64;
    while written < mb * 1_000_000 {
        turn += 1;
        let mut lines = vec![
            ("mux", "user_message", json!({"text": format!("prompt {turn}")})),
            ("mux", "turn_started", json!({"turnId": format!("t{turn}")})),
        ];
        for k in 0..40u64 {
            let call = format!("call-{turn}-{k}");
            let update = |u: Value| json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": u}});
            lines.push(("in", "agent_message_chunk", update(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": chunk}}))));
            lines.push(("in", "tool_call", update(json!({"sessionUpdate": "tool_call", "toolCallId": call, "kind": "read", "title": "Read"}))));
            lines.push(("in", "tool_call_update", update(json!({"sessionUpdate": "tool_call_update", "toolCallId": call, "status": "completed",
                "content": [{"type": "content", "content": {"type": "text", "text": output}}]}))));
        }
        lines.push((
            "mux",
            "turn_result",
            json!({"status": "completed", "turnId": format!("t{turn}")}),
        ));
        for (dir, kind, msg) in lines {
            seq += 1;
            let line = format!(
                r#"{{"seq":{seq},"at":{},"dir":"{dir}","kind":"{kind}","msg":{msg}}}"#,
                1_792_500_000_000u64 + seq
            ) + "\n";
            if in_segment >= 8 * 1024 * 1024 {
                out.flush().unwrap();
                segment += 1;
                out = open(segment);
                in_segment = 0;
            }
            out.write_all(line.as_bytes()).unwrap();
            in_segment += line.len() as u64;
            written += line.len() as u64;
        }
    }
    out.flush().unwrap();
    seq
}

struct Fixture {
    dir: daemon_env::Scratch,
    home: PathBuf,
    socket: PathBuf,
    daemon: Child,
    id: &'static str,
    records: u64,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        // SAFETY: the daemon is this test's own child.
        unsafe { libc::kill(self.daemon.id() as i32, libc::SIGTERM) };
        let _ = self.daemon.wait();
    }
}

/// A daemon over one chat with a log of `ACPMUX_TAIL_LOG_MB` (default 150) MB.
fn fixture(tag: &str) -> Fixture {
    let mb = env_or("ACPMUX_TAIL_LOG_MB", 150);
    let dir = daemon_env::Scratch::new(tag);
    let home = dir.join("home");
    private_dir(&home);
    let id = "01a1d21c-0000-7000-8000-000000000001";
    let session = home.join("sessions").join(id);
    private_dir(&session);
    let records = write_log(&session, mb);
    let meta = json!({"schema": "acpmux.session.v1", "id": id, "name": "busy-lane", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1, "lastSeq": records, "eventCount": records});
    std::fs::write(session.join("session.json"), meta.to_string()).unwrap();
    set_private(&session.join("session.json"));
    let socket = dir.join("s.sock");
    let mut daemon = daemon_env::acpmux(&dir)
        .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", &socket)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    daemon_env::ready_line(daemon.stdout.take().unwrap());
    Fixture { dir, home, socket, daemon, id, records }
}

impl Fixture {
    /// `program` with the hermetic environment and this daemon's socket.
    fn command(&self, program: &Path) -> Command {
        let mut cmd = daemon_env::command_at(program, &self.dir, daemon_env::Agents::Deny, &[]);
        cmd.env("ACPMUX_HOME", &self.home).env("ACPMUX_SOCKET", &self.socket);
        cmd
    }
}

/// Resident KB of `pid`, `None` once it is gone (or a zombie).
fn rss_kb(pid: i32) -> Option<u64> {
    #[cfg(target_os = "linux")]
    {
        let status = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
        if status.lines().any(|l| l.starts_with("State:") && l.contains("Z")) {
            return None;
        }
        let line = status.lines().find(|l| l.starts_with("VmRSS:"))?;
        line.split_whitespace().nth(1)?.parse().ok()
    }
    #[cfg(not(target_os = "linux"))]
    {
        let out =
            Command::new("ps").args(["-o", "rss=,stat=", "-p", &pid.to_string()]).output().ok()?;
        let text = String::from_utf8_lossy(&out.stdout).into_owned();
        let mut words = text.split_whitespace();
        let rss = words.next()?.parse().ok()?;
        (!words.next()?.starts_with('Z')).then_some(rss)
    }
}

/// What the harness saw of one tail.
struct Watch {
    /// (ms since the reader went, resident KB), every 100 ms.
    samples: Vec<(u128, u64)>,
    peak_kb: u64,
    /// When it ended, after the reader went; `None`: it was still running at the end of the watch
    /// or past `RSS_KILL_KB`, and the harness ended it.
    exit_ms: Option<u128>,
}

/// Samples `pid` from `since` until it is gone, [`WATCH_FOR`] passes, or it passes
/// [`RSS_KILL_KB`]; ends it in the last two cases. `reap` waits for it when it is our child.
fn watch(pid: i32, since: Instant, mut reap: impl FnMut() -> bool) -> Watch {
    let mut w = Watch { samples: Vec::new(), peak_kb: 0, exit_ms: None };
    loop {
        let at = since.elapsed().as_millis();
        if reap() {
            w.exit_ms = Some(at);
            return w;
        }
        let Some(kb) = rss_kb(pid) else {
            w.exit_ms = Some(at);
            return w;
        };
        w.peak_kb = w.peak_kb.max(kb);
        w.samples.push((at, kb));
        if since.elapsed() > WATCH_FOR || kb > RSS_KILL_KB {
            // SAFETY: the tail this test started (or its own child, under the test's shell).
            unsafe { libc::kill(pid, libc::SIGKILL) };
            while rss_kb(pid).is_some() && !reap() {
                std::thread::sleep(Duration::from_millis(20));
            }
            return w;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn report(case: &str, f: &Fixture, w: &Watch) {
    // Every tenth sample: the shape over time, not every reading.
    let timeline: Vec<_> =
        w.samples.iter().step_by(10).map(|(t, kb)| json!([t, kb / 1024])).collect();
    println!(
        "acpmux-session-tail: {}",
        json!({"case": case, "records": f.records, "log_mb": env_or("ACPMUX_TAIL_LOG_MB", 150),
            "peak_rss_mb": w.peak_kb / 1024, "exit_ms": w.exit_ms, "timeline_ms_mb": timeline,
            "binary": tail_binary().display().to_string()})
    );
    if measure_only() {
        return;
    }
    let exit = w.exit_ms.map(|ms| Duration::from_millis(ms as u64));
    assert!(
        exit.is_some_and(|e| e <= EXIT_WITHIN),
        "{case}: the tail ran on with nobody to read it ({exit:?})"
    );
    assert!(
        w.peak_kb <= RSS_CAP_KB,
        "{case}: the tail grew to {} MB (cap {} MB)",
        w.peak_kb / 1024,
        RSS_CAP_KB / 1024
    );
}

/// The incident: `--since 1 --suppress-reads` of a long log, its reader gone at once (the ssh
/// caller left). The tail ends within seconds and stays small.
#[test]
fn session_tail_whose_reader_left_exits_within_a_memory_cap() {
    let f = fixture("amx-tail-reader");
    let mut tail = f
        .command(&tail_binary())
        .args(["--json", "--suppress-reads", "session", "tail", f.id, "--since", "1"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let pid = tail.id() as i32;
    // The reader reads the first output, as a caller would, then leaves. A tail that writes
    // nothing (the bug) gives none: it leaves after a while anyway.
    let mut stdout = tail.stdout.take().unwrap();
    let started = Instant::now();
    let mut first_output_ms = None;
    while started.elapsed() < Duration::from_secs(10)
        && rss_kb(pid).is_some_and(|kb| kb < RSS_KILL_KB)
    {
        let mut p = libc::pollfd { fd: stdout.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: one valid pollfd on our own pipe.
        if unsafe { libc::poll(&mut p, 1, 20) } > 0 {
            let _ = stdout.read(&mut [0u8; 4096]);
            first_output_ms = Some(started.elapsed().as_millis());
            break;
        }
    }
    drop(stdout);
    let w = watch(pid, Instant::now(), || tail.try_wait().ok().flatten().is_some());
    let _ = tail.wait();
    println!("acpmux-session-tail-first-output: {}", json!({"first_output_ms": first_output_ms}));
    report("reader-left", &f, &w);
}

/// Starts `tail -f` of the chat's quiet end in the background of a shell that lives a second,
/// then exits: the tail is reparented to init or a subreaper. `stdout` is the tail's stdout
/// (`-` for the shell's own pipe). Returns the tail's pid and the shell's stdout pipe.
fn orphaned_follow(f: &Fixture, stdout: &str) -> (i32, std::process::ChildStdout) {
    let mut shell = f
        .command(Path::new("/bin/sh"))
        .arg("-c")
        .arg(
            r#"if [ "$3" = - ]; then exec 4>&1; else exec 4>"$3"; fi
"$0" --suppress-reads session tail "$1" --since "$2" -f >&4 4>&- & echo "$!" >&2; exec 4>&-; sleep 1"#,
        )
        .arg(tail_binary())
        .arg(f.id)
        .arg(f.records.to_string())
        .arg(stdout)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut text = String::new();
    BufReader::new(shell.stderr.take().unwrap()).read_line(&mut text).unwrap();
    let pid: i32 = text.trim().parse().unwrap();
    let out = shell.stdout.take().unwrap();
    shell.wait().unwrap();
    (pid, out)
}

/// A `-f` tail of a quiet chat, writing to `/dev/null`, whose shell exited: nobody can read it
/// and it never writes a line that could fail, so only its parent check ends it.
#[test]
fn session_tail_orphaned_by_its_shell_exits() {
    let f = fixture("amx-tail-orphan");
    let (pid, _out) = orphaned_follow(&f, "/dev/null");
    let w = watch(pid, Instant::now(), || false);
    report("orphaned-follow-devnull", &f, &w);
}

/// A `-f` tail of a quiet chat whose shell exited but whose pipe's reader is alive keeps
/// running (the reader decides, not the parent), then ends within seconds of the reader
/// closing the pipe, though it has nothing to write.
#[test]
fn session_tail_orphan_lives_with_its_reader_and_exits_after_it() {
    let f = fixture("amx-tail-orphan-reader");
    let (pid, out) = orphaned_follow(&f, "-");
    std::thread::sleep(Duration::from_secs(2));
    let alive = rss_kb(pid).is_some();
    drop(out);
    let w = watch(pid, Instant::now(), || false);
    report("orphaned-follow-reader-left", &f, &w);
    if !measure_only() {
        assert!(alive, "the tail ended while its pipe's reader was alive");
    }
}
