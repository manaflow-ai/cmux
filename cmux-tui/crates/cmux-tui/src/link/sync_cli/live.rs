//! `cmux link live`: a chat's folder synced both ways, live, while the chat runs on AutoCloud
//! (Leo: "we need to be able to toggle a chat on and off of autocloud").
//!
//! The Mac half of cmux-live-sync. `serve` is a process of its own (it outlives the move that
//! started it, as `cmux link project serve` does): it dials `sync.live` on the machine link's
//! socket (`cmux_tui_core::live_sync`, the VM half, keeps one follower per folder), runs
//! [`cmux_live_sync::Leader::run`] over that dial, and dials again through the link when it
//! drops (a sleep, a network change, a link swap), on the link's quiet socket when it has one so a
//! redial never wakes a paused machine. Every byte after the dial line travels as binary
//! projection lines both ways: the Cloud carrier moves whole lines only.
//!
//! Nothing degrades silently. Each conflict (both sides changed a file and the edits overlap:
//! the Mac's copy is kept beside it) is posted once with `cmux notify`; so is each distinct
//! alert (a watcher that fell back to rescans, a file skipped), and an outage past
//! [`OFFLINE_NOTICE`]. A machine that does not serve `sync.live`, or refuses the folder, is
//! posted too: [`start`] never falls back to a one-way copy without saying so.
//!
//!     cmux link live serve --socket S --at REMOTE [--chat ID] FOLDER
//!     cmux link live stop --at REMOTE | --chat ID
//!     cmux link live status
//!
//! Started when a chat turns AutoCloud on (its folder lands on the machine, or a move to the
//! machine commits); stopped when the machine is paused and when the chat turns AutoCloud off.

use std::collections::{HashMap, HashSet};
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::fs::FileTypeExt as _;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use anyhow::{Context as _, bail};
use cmux_live_sync::{Event, Leader};
use cmux_tui_core::projection::{LineReader, LineWriter};
use serde_json::{Value, json};

/// How long `serve` waits for the first catch-up before it answers.
const START_WAIT: Duration = Duration::from_secs(120);
/// How long the dial waits for the machine's answer line.
const ANSWER_WAIT: Duration = Duration::from_secs(30);
/// How long `stop` waits for the server to finish its round and exit before it signals it.
const STOP_WAIT: Duration = Duration::from_secs(5);
/// An outage this long is posted (once per outage).
const OFFLINE_NOTICE: Duration = Duration::from_secs(60);
/// The same alert is posted again only after this long.
const ALERT_REPEAT: Duration = Duration::from_secs(60);
/// A machine unreachable this long (paused and never resumed) ends the server, with a notice.
const GIVE_UP_AFTER: Duration = Duration::from_secs(6 * 60 * 60);

const USAGE: &str = "usage: cmux link live start|serve --socket S --at REMOTE [--chat ID] FOLDER | stop \
                     --at REMOTE | stop --chat ID | status";

/// `cmux link live ...`: one JSON line on stdout, exit 0 on success.
pub(crate) fn run(args: &[String]) -> i32 {
    if matches!(args.first().map(String::as_str), Some("-h" | "--help" | "help")) {
        println!("{USAGE}");
        return 0;
    }
    let rest = args.get(1..).unwrap_or_default();
    let outcome = match args.first().map(String::as_str) {
        Some("start") => parse(rest).and_then(|a| start(&a.socket, &a.folder, &a.at, &a.chat)),
        Some("serve") => serve_command(rest),
        Some("stop") => stop_command(rest),
        Some("status") => status(),
        _ => Err(anyhow::anyhow!(USAGE)),
    };
    match outcome {
        Ok(Value::Null) => 0,
        Ok(answer) => {
            println!("{answer}");
            i32::from(answer.get("ok").and_then(Value::as_bool) != Some(true))
        }
        Err(error) => {
            println!(
                "{}",
                json!({"ok": false, "error": first_line(&format!("{error:#}")), "error_code": "live_failed"})
            );
            1
        }
    }
}

fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or_default().to_string()
}

/// This Mac's folder for live sync servers: their records, locks, stop marks, logs and synced
/// copies.
fn live_dir() -> anyhow::Result<PathBuf> {
    cmux_tui_core::platform::workspace_state_dir()
        .map(|dir| dir.join("link-sync").join("live"))
        .context("this Mac has no state folder")
}

/// What this Mac names the server for the machine folder `remote`.
fn name_of(remote: &str) -> String {
    let hash = remote.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    });
    format!("l{hash:016x}")
}

fn file(remote: &str, ext: &str) -> anyhow::Result<PathBuf> {
    Ok(live_dir()?.join(format!("{}.{ext}", name_of(remote))))
}

/// Held by the server for `remote` for as long as it runs.
fn hold_lock(remote: &str) -> Option<std::fs::File> {
    let path = file(remote, "lock").ok()?;
    std::fs::create_dir_all(path.parent()?).ok()?;
    let lock =
        std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(path).ok()?;
    lock.try_lock().ok()?;
    Some(lock)
}

/// Whether a server for `remote` runs (its lock is held).
fn serving(remote: &str) -> bool {
    let Ok(path) = file(remote, "lock") else { return false };
    let Ok(lock) = std::fs::OpenOptions::new().write(true).open(path) else { return false };
    matches!(lock.try_lock(), Err(std::fs::TryLockError::WouldBlock))
}

/// The machine's `identify` when it serves `sync.live`; otherwise why not.
fn serves_live(socket: &Path) -> Result<(), String> {
    let identity = super::machine_call(socket, "identify", json!({}))
        .map_err(|error| first_line(&format!("the machine did not answer identify: {error:#}")))?;
    let served = identity
        .get("capabilities")
        .and_then(Value::as_array)
        .is_some_and(|caps| caps.iter().any(|cap| cap == cmux_tui_core::live_sync::CAPABILITY));
    if served {
        Ok(())
    } else {
        Err(format!(
            "the machine's daemon does not serve live sync ({}); update it to sync this chat both ways",
            cmux_tui_core::live_sync::CAPABILITY
        ))
    }
}

/// Starts live sync of `local` with `remote` on the machine at `socket` for `chat`: a server of
/// its own that outlives this process. Answers once the first catch-up finished (or a server
/// already runs for `remote`). A machine that cannot, or a refusal, is posted and returned.
pub(crate) fn start(
    socket: &Path,
    local: &Path,
    remote: &str,
    chat: &str,
) -> anyhow::Result<Value> {
    match start_inner(socket, local, remote, chat) {
        Ok(answer) => Ok(answer),
        Err(error) => {
            notify("Live sync is off for this chat", &first_line(&format!("{error:#}")));
            Err(error)
        }
    }
}

fn start_inner(socket: &Path, local: &Path, remote: &str, chat: &str) -> anyhow::Result<Value> {
    if serving(remote) {
        return Ok(json!({"ok": true, "data": {"already": true, "at": remote}}));
    }
    serves_live(socket).map_err(|why| anyhow::anyhow!(why))?;
    let dir = live_dir()?;
    std::fs::create_dir_all(&dir)?;
    let exe = std::env::current_exe().context("cannot find this cmux binary")?;
    let stderr = std::fs::File::create(file(remote, "log")?)?;
    let mut child = cmux_process::Command::new(exe)
        .args(["link", "live", "serve", "--socket"])
        .arg(socket)
        .args(["--at", remote, "--chat", chat])
        .arg(local)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(stderr)
        // Its own process group: it outlives this command and the app's run of it.
        .process_group(0)
        .spawn()
        .context("cannot start live sync")?;
    let stdout = child.stdout.take().context("no pipe from live sync")?;
    let mut line = String::new();
    BufReader::new(stdout).read_line(&mut line).context("reading live sync's answer")?;
    let answer: Value = serde_json::from_str(line.trim())
        .with_context(|| format!("live sync answered {line:?}"))?;
    if answer.get("ok").and_then(Value::as_bool) == Some(true) {
        child.detach("live sync outlives the move that started it");
        return Ok(answer);
    }
    let _ = child.wait();
    bail!("{}", answer.get("error").and_then(Value::as_str).unwrap_or("live sync did not start"))
}

/// [`start`] in a process of its own, so the chat's start or move answers without waiting for the
/// first catch-up. Its outcome goes to the log (`<name>.start.log`) and, when it fails, to the
/// app's notices ([`start`] posts it). Spawning it at all failing is posted here.
pub(crate) fn start_detached(socket: &Path, local: &Path, remote: &str, chat: &str) {
    let spawned = (|| -> anyhow::Result<()> {
        let dir = live_dir()?;
        std::fs::create_dir_all(&dir)?;
        let log = std::fs::File::create(file(remote, "start.log")?)?;
        let exe = std::env::current_exe().context("cannot find this cmux binary")?;
        let mut child = cmux_process::Command::new(exe)
            .args(["link", "live", "start", "--socket"])
            .arg(socket)
            .args(["--at", remote, "--chat", chat])
            .arg(local)
            .stdin(cmux_process::Stdio::null())
            .stdout(log.try_clone()?)
            .stderr(log)
            .process_group(0)
            .spawn()
            .context("cannot start live sync")?;
        child.detach("live sync's start outlives the chat start that asked for it");
        Ok(())
    })();
    if let Err(error) = spawned {
        notify("Live sync is off for this chat", &first_line(&format!("{error:#}")));
    }
}

/// Stops the live sync of the chat `chat` (AutoCloud turned off, or its machine paused). Whether
/// one ran.
pub(crate) fn stop_chat(chat: &str) -> anyhow::Result<bool> {
    let mut stopped = false;
    for record in records()? {
        if record.get("chat").and_then(Value::as_str) == Some(chat)
            && let Some(at) = record.get("at").and_then(Value::as_str)
        {
            stopped |= stop_at(at)?;
        }
    }
    Ok(stopped)
}

/// Stops every live sync with the machine whose link socket is `socket` (the machine paused).
pub(crate) fn stop_socket(socket: &Path) -> anyhow::Result<bool> {
    let mut stopped = false;
    for record in records()? {
        if record.get("socket").and_then(Value::as_str) == Some(&*socket.to_string_lossy())
            && let Some(at) = record.get("at").and_then(Value::as_str)
        {
            stopped |= stop_at(at)?;
        }
    }
    Ok(stopped)
}

/// Stops the server for `remote`: a stop mark it reads between rounds, then its process group
/// when it has not exited within [`STOP_WAIT`]. Whether one ran.
pub(crate) fn stop_at(remote: &str) -> anyhow::Result<bool> {
    let record_path = file(remote, "json")?;
    if !serving(remote) {
        let _ = std::fs::remove_file(&record_path);
        return Ok(false);
    }
    std::fs::write(file(remote, "stop")?, b"")?;
    let deadline = Instant::now() + STOP_WAIT;
    while Instant::now() < deadline && serving(remote) {
        std::thread::sleep(Duration::from_millis(20));
    }
    if serving(remote) {
        // Its group id is its pid (`start` made it a group of its own); only signalled while
        // its lock is held, so a reused pid is never signalled.
        let pid = std::fs::read(&record_path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .and_then(|record| record.get("pid").and_then(Value::as_u64));
        if let Some(pid) = pid {
            let _ = cmux_process::Command::new("kill")
                .args(["-TERM", "--", &format!("-{pid}")])
                .status();
        }
    }
    let _ = std::fs::remove_file(&record_path);
    Ok(true)
}

fn records() -> anyhow::Result<Vec<Value>> {
    let Ok(entries) = std::fs::read_dir(live_dir()?) else { return Ok(Vec::new()) };
    Ok(entries
        .flatten()
        .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "json"))
        .filter_map(|entry| std::fs::read(entry.path()).ok())
        .filter_map(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .collect())
}

fn status() -> anyhow::Result<Value> {
    let live: Vec<Value> = records()?
        .into_iter()
        .map(|mut record| {
            let running = record.get("at").and_then(Value::as_str).is_some_and(serving);
            if let Some(object) = record.as_object_mut() {
                object.insert("running".into(), Value::from(running));
            }
            record
        })
        .collect();
    Ok(json!({"ok": true, "live": live}))
}

fn stop_command(args: &[String]) -> anyhow::Result<Value> {
    let stopped = match args {
        [flag, at] if flag == "--at" => stop_at(at)?,
        [flag, chat] if flag == "--chat" => stop_chat(chat)?,
        _ => bail!("usage: cmux link live stop --at REMOTE | --chat ID"),
    };
    Ok(json!({"ok": true, "stopped": stopped}))
}

/// Posts one notice in the app (`cmux notify`), as automation failures are.
fn notify(title: &str, body: &str) {
    eprintln!("cmux link live: notice: {title}: {body}");
    if std::env::var("CMUX_LIVE_SYNC_NOTIFY").is_ok_and(|value| value == "off") {
        return;
    }
    let Ok(exe) = std::env::current_exe() else { return };
    if let Ok(mut child) = cmux_process::Command::new(exe)
        .args(["notify", "--title", title, "--body", body, "--workspace", "current"])
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .spawn()
    {
        let _ = child.wait_timeout(Duration::from_secs(5));
    }
}

struct ServeArgs {
    socket: PathBuf,
    at: String,
    chat: String,
    folder: PathBuf,
}

fn parse(args: &[String]) -> anyhow::Result<ServeArgs> {
    let (mut socket, mut at, mut chat, mut folder) = (None, None, String::new(), None);
    let mut words = args.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--socket" => socket = words.next().map(PathBuf::from),
            "--at" => at = words.next().cloned(),
            "--chat" => chat = words.next().cloned().unwrap_or_default(),
            other if !other.starts_with("--") && folder.is_none() => {
                folder = Some(PathBuf::from(other));
            }
            _ => bail!(USAGE),
        }
    }
    match (socket, at, folder) {
        (Some(socket), Some(at), Some(folder)) => Ok(ServeArgs { socket, at, chat, folder }),
        _ => bail!(USAGE),
    }
}

/// A refusal the dial must not retry (anything but `sync.busy`, which an older connection's end
/// clears), kept for the answer and the notice.
type Refused = Arc<Mutex<Option<String>>>;

/// The link's quiet socket (`<socket>.quiet`) when it has one: a dial there is closed instead of
/// waking a sleeping machine.
fn quiet_socket(socket: &Path) -> Option<PathBuf> {
    let mut path = socket.as_os_str().to_owned();
    path.push(".quiet");
    let path = PathBuf::from(path);
    std::fs::symlink_metadata(&path).ok().filter(|meta| meta.file_type().is_socket())?;
    Some(path)
}

/// The stream halves of one `sync.live` dial.
pub(crate) type Dialed = (LineReader<BufReader<UnixStream>>, LineWriter<UnixStream>);

/// Dials `sync.live` for `at` on the machine link at `socket` (its quiet socket first) and reads
/// the machine's answer. A refusal is an error carrying its code and first line.
pub(crate) fn dial(socket: &Path, at: &str) -> std::io::Result<Dialed> {
    let stream = match quiet_socket(socket).and_then(|quiet| UnixStream::connect(quiet).ok()) {
        Some(stream) => stream,
        None => UnixStream::connect(socket)?,
    };
    dial_on(stream, at)
}

/// [`dial`] on a connected `stream`.
pub(crate) fn dial_on(mut stream: UnixStream, at: &str) -> std::io::Result<Dialed> {
    let line = json!({"id": 1, "cmd": cmux_tui_core::live_sync::SERVE, "root": at});
    let mut bytes = serde_json::to_vec(&line)?;
    bytes.push(b'\n');
    stream.write_all(&bytes)?;
    stream.flush()?;
    stream.set_read_timeout(Some(ANSWER_WAIT))?;
    let mut reader = BufReader::with_capacity(256 * 1024, stream);
    let mut answer = String::new();
    if reader.read_line(&mut answer)? == 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "the machine closed the link without answering (asleep or unreachable)",
        ));
    }
    let answer: Value = serde_json::from_str(answer.trim())?;
    if answer.get("ok").and_then(Value::as_bool) != Some(true) {
        let code = answer.get("error_code").and_then(Value::as_str).unwrap_or("sync.failed");
        let error = answer.get("error").and_then(Value::as_str).unwrap_or("refused");
        return Err(std::io::Error::other(format!("{code}: {}", first_line(error))));
    }
    // The leader pings every few seconds and drops a silent stream itself.
    reader.get_ref().set_read_timeout(None)?;
    reader.get_ref().set_write_timeout(Some(Duration::from_secs(60)))?;
    let writer = reader.get_ref().try_clone()?;
    Ok((LineReader::new(reader), LineWriter::binary(writer)))
}

/// Whether a dial error is a refusal no retry clears.
fn final_refusal(error: &std::io::Error) -> bool {
    let text = error.to_string();
    ["sync.bad_request", "sync.denied", "sync.unavailable", "sync.failed"]
        .iter()
        .any(|code| text.starts_with(&format!("{code}:")))
}

/// What the notices have said, so each is said once.
#[derive(Default)]
struct Notices {
    conflicts: HashSet<(String, String)>,
    alerts: HashMap<String, Instant>,
    offline_since: Option<Instant>,
    offline_posted: bool,
}

impl Notices {
    /// Posts what `event` needs posting; `post` is the notice path (tests swap it).
    fn see(&mut self, event: &Event, mut post: impl FnMut(&str, &str)) {
        match event {
            Event::Conflict { path, copy } => {
                if self.conflicts.insert((path.clone(), copy.clone())) {
                    post(
                        "Live sync conflict",
                        &format!("{path} changed on both sides; this Mac's copy is kept at {copy}"),
                    );
                }
            }
            Event::Alert { reason } => {
                let due = self.alerts.get(reason).is_none_or(|at| at.elapsed() >= ALERT_REPEAT);
                if due {
                    self.alerts.insert(reason.clone(), Instant::now());
                    post("Live sync", reason);
                }
            }
            Event::Offline { .. } => {
                self.offline_since.get_or_insert_with(Instant::now);
            }
            Event::Online { .. } => {
                if self.offline_posted {
                    post("Live sync is back", "this chat's folder is in sync again");
                }
                self.offline_since = None;
                self.offline_posted = false;
            }
            Event::Round { .. } | Event::KeptEdit { .. } => {}
        }
    }

    /// Posts an outage past [`OFFLINE_NOTICE`] once; whether it has gone past [`GIVE_UP_AFTER`].
    fn tick(&mut self, last_reason: &str, mut post: impl FnMut(&str, &str)) -> bool {
        let Some(since) = self.offline_since else { return false };
        if !self.offline_posted && since.elapsed() >= OFFLINE_NOTICE {
            self.offline_posted = true;
            post(
                "Live sync is offline",
                &format!("edits wait on both sides until the machine is back: {last_reason}"),
            );
        }
        since.elapsed() >= GIVE_UP_AFTER
    }
}

/// `serve`: runs the leader until stopped; prints one line once the first catch-up finished, or
/// the refusal.
fn serve_command(args: &[String]) -> anyhow::Result<Value> {
    let args = parse(args)?;
    let folder = std::fs::canonicalize(&args.folder)
        .with_context(|| format!("no folder at {}", args.folder.display()))?;
    let Some(_lock) = hold_lock(&args.at) else {
        return Ok(json!({"ok": true, "data": {"already": true, "at": args.at}}));
    };
    let stop_mark = file(&args.at, "stop")?;
    let _ = std::fs::remove_file(&stop_mark);
    let state = live_dir()?.join(name_of(&args.at));
    let (events_tx, events) = crossbeam_channel::unbounded();
    let mut leader = Leader::new(&folder, &state, events_tx)?;
    let record = json!({
        "pid": std::process::id(),
        "at": args.at,
        "chat": args.chat,
        "socket": args.socket.to_string_lossy(),
        "local": folder.to_string_lossy(),
    });
    std::fs::write(file(&args.at, "json")?, serde_json::to_vec(&record)?)?;

    let (stop_tx, stop_rx) = crossbeam_channel::bounded::<()>(4);
    let refused: Refused = Arc::default();
    let runner = {
        let (socket, at, refused, stop_tx) =
            (args.socket.clone(), args.at.clone(), refused.clone(), stop_tx.clone());
        std::thread::Builder::new().name("live-leader".into()).spawn(move || {
            leader.run(
                || {
                    let dialed = dial(&socket, &at);
                    if let Err(error) = &dialed
                        && final_refusal(error)
                    {
                        *refused.lock().unwrap_or_else(PoisonError::into_inner) =
                            Some(error.to_string());
                        let _ = stop_tx.try_send(());
                    }
                    dialed
                },
                &stop_rx,
            );
        })?
    };

    let started = Instant::now();
    let mut answered = false;
    let mut notices = Notices::default();
    let mut last_reason = String::new();
    loop {
        if std::fs::remove_file(&stop_mark).is_ok() {
            let _ = stop_tx.try_send(());
        }
        if runner.is_finished() {
            break;
        }
        let event = match events.recv_timeout(Duration::from_millis(200)) {
            Ok(event) => Some(event),
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => None,
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
        };
        if let Some(event) = &event {
            log(event);
            if let Event::Offline { reason } = event {
                last_reason.clone_from(reason);
            }
            notices.see(event, notify);
            if !answered && let Event::Online { paths, took } = event {
                answered = true;
                answer(&json!({"ok": true, "data": {
                    "at": args.at,
                    "local": folder.to_string_lossy(),
                    "catch_up_paths": paths,
                    "catch_up_ms": took.as_millis(),
                    "pid": std::process::id(),
                }}));
            }
        }
        if !answered && started.elapsed() >= START_WAIT {
            answered = true;
            answer(&json!({"ok": false, "error_code": "live_failed", "error": format!(
                "no catch-up with the machine within {} s: {}", START_WAIT.as_secs(), last_reason
            )}));
            let _ = stop_tx.try_send(());
        }
        if notices.tick(&last_reason, notify) {
            notify(
                "Live sync stopped",
                &format!("the machine was unreachable for 6 hours: {last_reason}"),
            );
            let _ = stop_tx.try_send(());
        }
    }
    let _ = runner.join();
    let _ = std::fs::remove_file(file(&args.at, "json")?);
    let refusal = refused.lock().unwrap_or_else(PoisonError::into_inner).clone();
    if let Some(refusal) = refusal {
        if answered {
            notify("Live sync stopped", &refusal);
        } else {
            answer(&json!({"ok": false, "error_code": "live_refused", "error": refusal}));
        }
    }
    Ok(Value::Null)
}

/// The one stdout line `start` reads.
fn answer(line: &Value) {
    let mut stdout = std::io::stdout();
    let _ = writeln!(stdout, "{line}");
    let _ = stdout.flush();
}

fn log(event: &Event) {
    match event {
        Event::Round { to_remote, to_local, merged, took } => eprintln!(
            "cmux link live: round to_remote={to_remote} to_local={to_local} merged={merged} took_ms={}",
            took.as_millis()
        ),
        other => eprintln!("cmux link live: {other:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conflicts_post_once_and_alerts_dedupe() {
        let mut notices = Notices::default();
        let mut posted = Vec::new();
        let conflict = Event::Conflict { path: "a.txt".into(), copy: "a (Mac).txt".into() };
        let alert = Event::Alert { reason: "skipped big.bin: over 512 MB".into() };
        for _ in 0..3 {
            notices.see(&conflict, |t, b| posted.push(format!("{t}: {b}")));
            notices.see(&alert, |t, b| posted.push(format!("{t}: {b}")));
        }
        assert_eq!(posted.len(), 2, "{posted:?}");
        assert!(posted[0].contains("a (Mac).txt"));
    }

    #[test]
    fn short_outage_is_not_posted() {
        let mut notices = Notices::default();
        let mut posted = Vec::new();
        notices.see(&Event::Offline { reason: "dial".into() }, |_, _| {});
        assert!(!notices.tick("dial", |t, _| posted.push(t.to_string())));
        notices.see(&Event::Online { paths: 0, took: Duration::ZERO }, |t, _| {
            posted.push(t.to_string());
        });
        assert!(posted.is_empty(), "{posted:?}");
    }

    #[test]
    fn refusals_that_stop() {
        assert!(final_refusal(&std::io::Error::other("sync.denied: no")));
        assert!(!final_refusal(&std::io::Error::other("sync.busy: later")));
        assert!(!final_refusal(&std::io::Error::other("connection refused")));
    }
}
