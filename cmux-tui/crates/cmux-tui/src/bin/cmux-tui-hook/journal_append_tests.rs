//! The hook child against a daemon at its connection limit (#27698: 55,162
//! refusals in 2.5 h). A refused append is kept and sent again after the
//! daemon's `retry_after_ms`, spread by jitter, never in a spin.

use std::collections::HashMap;
use std::os::unix::net::UnixListener;
use std::sync::{Arc, Mutex};

use super::*;

const RETRY_AFTER_MS: u64 = 150;

fn refused_line(retry_after_ms: u64) -> String {
    let line = json!({
        "protocol": "cmux.protocol/2",
        "type": "refused",
        "code": "server.busy",
        "message": "the session is at its connection limit; retry",
        "retry_after_ms": retry_after_ms,
    });
    format!("{line}\n")
}

fn receipt_line(request_id: &str) -> String {
    let receipt = json!({
        "protocol": "cmux.protocol/2",
        "type": "response",
        "id": request_id,
        "ok": true,
        "result": {},
    });
    format!("{receipt}\n")
}

/// What the fake daemon saw of one request id: when it refused each try and
/// when it admitted one.
#[derive(Default, Clone, Debug)]
struct Seen {
    refused: Vec<Instant>,
    admitted: Option<Instant>,
}

/// What the fake daemon saw, by request id.
type SeenLog = Arc<Mutex<HashMap<String, Seen>>>;

/// A daemon that refuses the first `refusals` tries of every request id
/// with the busy line, then answers with a receipt. It reads each request
/// line before it answers, so the refusal is what the hook reads (the live
/// daemon may also close before the write; that path is a plain drop). A
/// line that is not a request stops it.
fn busy_daemon(listener: UnixListener, refusals: usize) -> (SeenLog, std::thread::JoinHandle<()>) {
    let seen = SeenLog::default();
    let record = seen.clone();
    let daemon = std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut stream = stream.unwrap();
            let mut line = String::new();
            BufReader::new(&stream).read_line(&mut line).unwrap();
            let Some(id) = serde_json::from_str::<Value>(&line)
                .ok()
                .and_then(|request| request["id"].as_str().map(str::to_owned))
            else {
                return;
            };
            let now = Instant::now();
            let mut seen = record.lock().unwrap();
            let entry = seen.entry(id.clone()).or_default();
            let answer = if entry.refused.len() < refusals {
                entry.refused.push(now);
                refused_line(RETRY_AFTER_MS)
            } else {
                entry.admitted = Some(now);
                receipt_line(&id)
            };
            drop(seen);
            let _ = stream.write_all(answer.as_bytes());
        }
    });
    (seen, daemon)
}

fn stop(socket: &Path, daemon: std::thread::JoinHandle<()>) {
    let mut stream = std::os::unix::net::UnixStream::connect(socket).unwrap();
    stream.write_all(b"stop\n").unwrap();
    daemon.join().unwrap();
}

fn hook_request() -> (String, Vec<u8>) {
    encode_request(json!({"kind":"test"}), serde_json::Map::new()).unwrap()
}

#[test]
fn a_refused_append_is_kept_until_the_daemon_admits_it() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("d.sock");
    let (seen, daemon) = busy_daemon(UnixListener::bind(&socket).unwrap(), 2);
    let (request_id, encoded) = hook_request();

    let result = append_with_receipt(&socket, &request_id, &encoded, &|| {});
    stop(&socket, daemon);

    result.expect("a refused append must be sent again, not dropped");
    let seen = seen.lock().unwrap()[&request_id].clone();
    assert_eq!(seen.refused.len(), 2);
    let admitted = seen.admitted.expect("the daemon admitted the append");
    let tries = [seen.refused[0], seen.refused[1], admitted];
    for pair in tries.windows(2) {
        assert!(
            pair[1] - pair[0] >= Duration::from_millis(RETRY_AFTER_MS),
            "a try came {:?} after a refusal that said retry after {RETRY_AFTER_MS} ms",
            pair[1] - pair[0]
        );
    }
}

/// Hooks of 16 agents refused at the same moment come back spread out, each no sooner than
/// the daemon's `retry_after_ms`, instead of in one wave that the daemon
/// refuses again.
#[test]
fn hooks_refused_at_once_do_not_retry_in_lockstep() {
    const HOOKS: usize = 16;
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("d.sock");
    let (seen, daemon) = busy_daemon(UnixListener::bind(&socket).unwrap(), 1);
    let start = Arc::new(std::sync::Barrier::new(HOOKS));
    let hooks: Vec<_> = (0..HOOKS)
        .map(|agent| {
            let socket = socket.clone();
            let start = start.clone();
            std::thread::spawn(move || {
                let (request_id, encoded) = hook_request_in(&format!("terminal_{agent}"));
                start.wait();
                append_with_receipt(&socket, &request_id, &encoded, &|| {})
                    .map_err(|error| format!("{error:#}"))
            })
        })
        .collect();
    let results: Vec<_> = hooks.into_iter().map(|hook| hook.join().unwrap()).collect();
    stop(&socket, daemon);

    for result in &results {
        assert!(result.is_ok(), "a refused hook event was lost: {result:?}");
    }
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), HOOKS);
    let waits: Vec<Duration> = seen
        .values()
        .map(|seen| seen.admitted.expect("every hook was admitted") - seen.refused[0])
        .collect();
    for wait in &waits {
        assert!(
            *wait >= Duration::from_millis(RETRY_AFTER_MS),
            "a hook came back {wait:?} after a refusal that said {RETRY_AFTER_MS} ms"
        );
    }
    let spread = *waits.iter().max().unwrap() - *waits.iter().min().unwrap();
    assert!(
        spread >= Duration::from_millis(25),
        "{HOOKS} refused hooks came back within {spread:?} of each other: a lockstep wave"
    );
}

/// What the daemon below does with one request line.
#[derive(Clone, Copy, Debug)]
enum Reply {
    Receipt,
    Busy,
    /// The live daemon's own busy line: no `retry_after_ms`.
    BusyBare,
    /// A durable rejection (`ok: false`, not retryable).
    Reject,
    /// Close the connection without an answer.
    Close,
    /// Keep the connection open and never answer (a handler that hung or
    /// panicked while the connection stays registered).
    Silent,
}

/// A daemon that serves each connection on its own thread, many lines per
/// connection, and answers each line by `policy(id, earlier tries of the id,
/// time since start)`. With `hold`, it keeps the very first line's answer
/// until the test says so.
struct Daemon {
    socket: PathBuf,
    connections: Arc<std::sync::atomic::AtomicUsize>,
    admitted: Arc<Mutex<Vec<String>>>,
    stop: Arc<std::sync::atomic::AtomicBool>,
    accept: std::thread::JoinHandle<()>,
}

type Policy = dyn Fn(&str, usize, Duration) -> Reply + Send + Sync;

/// The first line's hold: the daemon says when it holds it, and answers when released.
struct Hold {
    holding: std::sync::mpsc::Sender<()>,
    release: std::sync::mpsc::Receiver<()>,
}

impl Daemon {
    fn start(socket: &Path, hold: Option<Hold>, policy: Arc<Policy>) -> Self {
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
        let listener = UnixListener::bind(socket).unwrap();
        let connections = Arc::new(AtomicUsize::new(0));
        let admitted = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let tries = Arc::new(Mutex::new(HashMap::<String, usize>::new()));
        let hold = Arc::new(Mutex::new(hold));
        let started = Instant::now();
        let accept = {
            let (connections, admitted, stop) =
                (connections.clone(), admitted.clone(), stop.clone());
            std::thread::spawn(move || {
                for stream in listener.incoming() {
                    if stop.load(Ordering::Acquire) {
                        return;
                    }
                    let Ok(stream) = stream else { continue };
                    connections.fetch_add(1, Ordering::AcqRel);
                    let (admitted, tries, hold, policy) =
                        (admitted.clone(), tries.clone(), hold.clone(), policy.clone());
                    std::thread::spawn(move || {
                        let mut writer = stream.try_clone().unwrap();
                        let mut reader = BufReader::new(stream);
                        loop {
                            let mut line = String::new();
                            if reader.read_line(&mut line).unwrap_or(0) == 0 {
                                return;
                            }
                            let Some(id) = serde_json::from_str::<Value>(&line)
                                .ok()
                                .and_then(|request| request["id"].as_str().map(str::to_owned))
                            else {
                                return;
                            };
                            let held = hold.lock().unwrap().take();
                            if let Some(hold) = held {
                                hold.holding.send(()).unwrap();
                                hold.release.recv().unwrap();
                            }
                            let earlier = {
                                let mut tries = tries.lock().unwrap();
                                let count = tries.entry(id.clone()).or_default();
                                *count += 1;
                                *count - 1
                            };
                            let reply = policy(&id, earlier, started.elapsed());
                            let answer = match reply {
                                Reply::Receipt => {
                                    admitted.lock().unwrap().push(id.clone());
                                    receipt_line(&id)
                                }
                                Reply::Busy => refused_line(RETRY_AFTER_MS),
                                Reply::BusyBare => format!(
                                    "{}\n",
                                    json!({
                                        "protocol": "cmux.protocol/2",
                                        "type": "refused",
                                        "code": "server.busy",
                                        "message": "the session is at its connection limit; retry",
                                    })
                                ),
                                Reply::Reject => format!(
                                    "{}\n",
                                    json!({
                                        "protocol": "cmux.protocol/2",
                                        "type": "response",
                                        "id": id,
                                        "ok": false,
                                        "error": {"message": "invalid event", "retryable": false},
                                    })
                                ),
                                Reply::Close => return,
                                Reply::Silent => {
                                    // Read on until the client hangs up.
                                    let mut rest = String::new();
                                    while reader.read_line(&mut rest).unwrap_or(0) > 0 {
                                        rest.clear();
                                    }
                                    return;
                                }
                            };
                            if writer.write_all(answer.as_bytes()).is_err() {
                                return;
                            }
                            if matches!(reply, Reply::Busy | Reply::BusyBare) {
                                // The live daemon closes a refused connection.
                                return;
                            }
                        }
                    });
                }
            })
        };
        Self { socket: socket.to_path_buf(), connections, admitted, stop, accept }
    }

    /// Connections accepted so far, and the ids it admitted, in order.
    fn stop(self) -> (usize, Vec<String>) {
        use std::sync::atomic::Ordering;
        let connections = self.connections.load(Ordering::Acquire);
        let admitted = self.admitted.lock().unwrap().clone();
        self.stop.store(true, Ordering::Release);
        drop(std::os::unix::net::UnixStream::connect(&self.socket));
        self.accept.join().unwrap();
        (connections, admitted)
    }
}

/// A hook event of the agent in `terminal`.
fn hook_request_in(terminal: &str) -> (String, Vec<u8>) {
    let event = json!({"kind": "test", "subjects": [{"kind": "terminal", "id": terminal}]});
    encode_request(event, serde_json::Map::new()).unwrap()
}

/// #27698: every hook call opened its own connection, so 80 agents' hooks
/// held the daemon's connection slots. The hooks of one agent now go out in
/// order over one connection.
#[test]
fn one_agents_hook_burst_uses_one_connection_in_order() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("d.sock");
    let (holding, held) = std::sync::mpsc::channel();
    let (release, released) = std::sync::mpsc::channel();
    let hold = Hold { holding, release: released };
    let daemon = Daemon::start(
        &socket,
        Some(hold),
        Arc::new(|_: &str, _: usize, _: Duration| Reply::Receipt),
    );
    let requests: Vec<_> = (0..6).map(|_| hook_request_in("terminal_burst")).collect();

    let first = {
        let (socket, (id, encoded)) = (socket.clone(), requests[0].clone());
        std::thread::spawn(move || {
            append_with_receipt(&socket, &id, &encoded, &|| {}).map_err(|e| format!("{e:#}"))
        })
    };
    held.recv().unwrap();
    for (id, encoded) in &requests[1..] {
        let (socket, id, encoded) = (socket.clone(), id.clone(), encoded.clone());
        let hook = std::thread::spawn(move || {
            append_with_receipt(&socket, &id, &encoded, &|| {}).map_err(|e| format!("{e:#}"))
        });
        assert!(hook.join().unwrap().is_ok());
    }
    release.send(()).unwrap();
    assert!(first.join().unwrap().is_ok());
    let (connections, admitted) = daemon.stop();

    let ids: Vec<String> = requests.into_iter().map(|(id, _)| id).collect();
    assert_eq!(admitted, ids, "the burst reached the daemon out of order");
    assert_eq!(connections, 1, "one agent's burst of {} hooks opened {connections}", ids.len());
}

/// A busy daemon is waited out: the event is not dropped when some fixed
/// time has passed (the hook child gave up at 4 s).
#[test]
fn a_hook_event_outlives_a_busy_daemon() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("d.sock");
    let busy_for = Duration::from_millis(4500);
    let policy = move |_: &str, _: usize, since: Duration| {
        if since < busy_for { Reply::Busy } else { Reply::Receipt }
    };
    let daemon = Daemon::start(&socket, None, Arc::new(policy));
    let (id, encoded) = hook_request_in("terminal_busy");

    let result = append_with_receipt(&socket, &id, &encoded, &|| {});
    let (_, admitted) = daemon.stop();

    result.expect("a busy daemon must not cost the hook event");
    assert_eq!(admitted, vec![id]);
}

/// A rejected event leaves the agent's queue: it is not sent again, and the
/// events behind it still go out.
#[test]
fn a_rejected_hook_event_does_not_hold_back_the_next() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("d.sock");
    let (holding, held) = std::sync::mpsc::channel();
    let (release, released) = std::sync::mpsc::channel();
    let hold = Hold { holding, release: released };
    let (rejected_id, rejected) = hook_request_in("terminal_reject");
    let (next_id, next) = hook_request_in("terminal_reject");
    let tries = Arc::new(Mutex::new(Vec::new()));
    let policy = {
        let (rejected_id, tries) = (rejected_id.clone(), tries.clone());
        move |id: &str, _: usize, _: Duration| {
            tries.lock().unwrap().push(id.to_owned());
            if id == rejected_id { Reply::Reject } else { Reply::Receipt }
        }
    };
    let daemon = Daemon::start(&socket, Some(hold), Arc::new(policy));

    let first = {
        let (socket, id) = (socket.clone(), rejected_id.clone());
        std::thread::spawn(move || append_with_receipt(&socket, &id, &rejected, &|| {}).is_err())
    };
    held.recv().unwrap();
    let second = {
        let id = next_id.clone();
        std::thread::spawn(move || append_with_receipt(&socket, &id, &next, &|| {}).is_ok())
    };
    assert!(second.join().unwrap());
    release.send(()).unwrap();
    assert!(first.join().unwrap(), "the rejection reaches the hook whose event it was");
    let (_, admitted) = daemon.stop();

    assert_eq!(admitted, vec![next_id]);
    let rejected_tries = tries.lock().unwrap().iter().filter(|id| **id == rejected_id).count();
    assert_eq!(rejected_tries, 1, "a durable rejection was sent again");
}

/// A daemon that refuses every connection with its busy line for a while:
/// the tries are spaced by a backoff, not a spin. (A daemon that takes a
/// line and closes on it without an answer is a line it will not take:
/// `a_line_the_daemon_never_answers_is_counted_and_does_not_block_the_agent`.)
#[test]
fn busy_refusals_are_retried_with_backoff_not_a_spin() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("d.sock");
    let refusing_for = Duration::from_millis(400);
    let policy = move |_: &str, _: usize, since: Duration| {
        if since < refusing_for { Reply::BusyBare } else { Reply::Receipt }
    };
    let daemon = Daemon::start(&socket, None, Arc::new(policy));
    let (id, encoded) = hook_request_in("terminal_drop");

    let result = append_with_receipt(&socket, &id, &encoded, &|| {});
    let (connections, admitted) = daemon.stop();

    result.expect("a refused hook event is retried");
    assert_eq!(admitted, vec![id]);
    assert!(
        (2..=12).contains(&connections),
        "{connections} connections while the daemon refused them for {refusing_for:?}"
    );
}

/// No daemon on the session socket (stopped, restarting or crashed): the
/// hook stops at once, so a synchronous provider is never delayed, and keeps
/// the event queued for the session's next owner.
#[test]
fn a_missing_session_socket_fails_at_once_and_keeps_the_event() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("missing.sock");
    let (id, encoded) = hook_request_in("terminal_gone");
    let started = Instant::now();

    assert!(append_with_receipt(&socket, &id, &encoded, &|| {}).is_err());
    assert!(started.elapsed() < Duration::from_secs(1));
    let queued = std::fs::read(queue_path(&socket, &socket, "terminal_gone"))
        .expect("the event was not kept");
    assert_eq!(queued, encoded);
}

/// The hook queue directory beside `socket`, and the file that counts the
/// events `reset-state` dropped.
fn spool_dir(socket: &Path) -> PathBuf {
    socket.parent().unwrap().join("hook-spool")
}

fn ended_session_events(socket: &Path) -> Option<String> {
    std::fs::read_to_string(spool_dir(socket).join("reset-dropped-events")).ok()
}

/// The queue file of `terminal` of the session on `of_socket`, in the queue
/// directory beside `socket`.
fn queue_path(socket: &Path, of_socket: &Path, terminal: &str) -> PathBuf {
    spool_dir(socket).join(format!(
        "{}.{}.jsonl",
        cmux_tui_core::diagnostics::queue_prefix(of_socket),
        cmux_tui_core::diagnostics::spool_name_part(terminal)
    ))
}

/// Writes a queue of `lines` for `terminal` of the session on the socket
/// named `socket_name` beside `socket`: what a sender that stopped leaves.
fn leave_queue(socket: &Path, socket_name: &str, terminal: &str, lines: &[Vec<u8>]) -> PathBuf {
    let mut private = std::fs::DirBuilder::new();
    private.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut private, 0o700);
    private.create(spool_dir(socket)).unwrap();
    let path = queue_path(socket, &socket.with_file_name(socket_name), terminal);
    std::fs::write(&path, lines.concat()).unwrap();
    path
}

/// The files left in the hook queue directory, but the drop count.
fn queue_files(socket: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(spool_dir(socket))
        .map(|entries| {
            entries.map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned()).collect()
        })
        .unwrap_or_default();
    names.retain(|name| name != "reset-dropped-events" && name != "undeliverable-events");
    names.sort();
    names
}

/// A queue of the live session that nobody sends (its sender died, or its
/// agent ran no hook since) is sent by the next hook child of any agent.
#[test]
fn an_orphaned_queue_of_the_live_session_is_sent_by_any_agents_next_hook() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("live.sock");
    let daemon =
        Daemon::start(&socket, None, Arc::new(|_: &str, _: usize, _: Duration| Reply::Receipt));
    let (orphan_id, orphan) = hook_request_in("terminal_orphan");
    leave_queue(&socket, "live.sock", "terminal_orphan", &[orphan]);
    let (id, encoded) = hook_request_in("terminal_live");

    let result = append_with_receipt(&socket, &id, &encoded, &|| {});
    let (_, admitted) = daemon.stop();

    result.unwrap();
    assert!(admitted.contains(&orphan_id), "the orphaned event was not sent: {admitted:?}");
    assert_eq!(queue_files(&socket), Vec::<String>::new());
    assert_eq!(ended_session_events(&socket), None, "a sent event was counted as dropped");
}

/// A stopped daemon (its owner removes the socket on every stop, upgrades
/// and restarts included) or a crashed one (it leaves the socket) gives no
/// definitive answer: the session comes back on the same socket. The line
/// stays queued, nothing is counted as dropped, and the next owner gets it
/// from the next hook of any agent of the session.
#[test]
fn a_stopped_daemon_keeps_the_queue_for_its_next_owner() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("restart.sock");
    let (kept_id, kept) = hook_request_in("terminal_kept");
    let stopped = append_with_receipt(&socket, &kept_id, &kept, &|| {});
    assert!(stopped.is_err(), "no daemon answered");
    // A crashed owner: its socket file stays, nobody listens on it.
    drop(UnixListener::bind(&socket).unwrap());
    let crashed = append_with_receipt(&socket, &kept_id, &kept, &|| {});
    assert!(crashed.is_err(), "no daemon answered");
    std::fs::remove_file(&socket).unwrap();
    assert_eq!(ended_session_events(&socket), None, "a restart is not a dropped event");

    let daemon =
        Daemon::start(&socket, None, Arc::new(|_: &str, _: usize, _: Duration| Reply::Receipt));
    let (id, encoded) = hook_request_in("terminal_next");
    let result = append_with_receipt(&socket, &id, &encoded, &|| {});
    let (_, admitted) = daemon.stop();

    result.unwrap();
    assert!(
        admitted.contains(&kept_id),
        "the kept event never reached the next owner: {admitted:?}"
    );
    assert!(admitted.contains(&id));
    assert_eq!(queue_files(&socket), Vec::<String>::new());
}

/// Another session's queues belong to that session: a hook of this session
/// neither sends them here nor deletes them.
#[test]
fn another_sessions_queue_is_left_to_its_session() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("live.sock");
    let daemon =
        Daemon::start(&socket, None, Arc::new(|_: &str, _: usize, _: Duration| Reply::Receipt));
    let (other_id, other) = hook_request_in("terminal_other");
    let other_queue = leave_queue(&socket, "other.sock", "terminal_other", &[other]);
    let (id, encoded) = hook_request_in("terminal_live");

    let result = append_with_receipt(&socket, &id, &encoded, &|| {});
    let (_, admitted) = daemon.stop();

    result.unwrap();
    assert_eq!(admitted, vec![id], "another session's event {other_id} came here");
    assert!(other_queue.exists(), "another session's queue was deleted");
    assert_eq!(ended_session_events(&socket), None);
}

/// The provider waits only until its event is safe on disk: a daemon that
/// refuses every connection before it reads (a broken pipe on the write)
/// must not hold the agent's tool call.
#[test]
fn a_queued_event_releases_the_provider_at_once() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("closing.sock");
    let closing_for = Duration::from_millis(1500);
    let listener = UnixListener::bind(&socket).unwrap();
    let started = Instant::now();
    let closer = std::thread::spawn(move || {
        for stream in listener.incoming() {
            let stream = stream.unwrap();
            if started.elapsed() >= closing_for {
                let mut line = String::new();
                let mut reader = BufReader::new(&stream);
                if reader.read_line(&mut line).unwrap_or(0) == 0 {
                    continue;
                }
                let id = serde_json::from_str::<Value>(&line).unwrap()["id"]
                    .as_str()
                    .unwrap()
                    .to_owned();
                (&stream).write_all(receipt_line(&id).as_bytes()).unwrap();
                return;
            }
            // Closed unread: a request larger than the socket buffer then
            // fails its write with a broken pipe.
            drop(stream);
        }
    });
    let mut live = serde_json::Map::new();
    live.insert("live_prompt".into(), Value::String("x".repeat(1024 * 1024)));
    let (id, encoded) = encode_request(
        json!({"kind":"test","subjects":[{"kind":"terminal","id":"terminal_big"}]}),
        live,
    )
    .unwrap();
    let released = Arc::new(Mutex::new(None));
    let result = {
        let released = released.clone();
        append_with_receipt(&socket, &id, &encoded, &move || {
            released.lock().unwrap().get_or_insert(started.elapsed());
        })
    };
    closer.join().unwrap();

    result.unwrap();
    let released = released.lock().unwrap().expect("the provider was never released");
    assert!(
        released < Duration::from_millis(500),
        "the provider waited {released:?} for a queued event"
    );
}

/// The hook queue lives only in a directory no other user can write: in a
/// shared one (the socket's parent may be one, such as /tmp), the hook sends
/// its event directly and leaves nothing there.
#[cfg(unix)]
#[test]
fn a_shared_socket_directory_gets_no_queue_and_the_event_still_goes() {
    use std::os::unix::fs::PermissionsExt as _;
    let root = tempfile::tempdir().unwrap();
    let shared = root.path().join("shared");
    std::fs::create_dir(&shared).unwrap();
    std::fs::set_permissions(&shared, std::fs::Permissions::from_mode(0o777)).unwrap();
    let socket = shared.join("s.sock");
    let daemon =
        Daemon::start(&socket, None, Arc::new(|_: &str, _: usize, _: Duration| Reply::Receipt));
    let (id, encoded) = hook_request_in("terminal_shared");

    let result = append_with_receipt(&socket, &id, &encoded, &|| {});
    let (_, admitted) = daemon.stop();

    result.unwrap();
    assert_eq!(admitted, vec![id]);
    assert!(!spool_dir(&socket).exists(), "a queue was made in a shared directory");
}

/// A planted symlink in place of a queue file is never followed.
#[cfg(unix)]
#[test]
fn a_planted_symlink_is_not_followed() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("s.sock");
    let daemon =
        Daemon::start(&socket, None, Arc::new(|_: &str, _: usize, _: Duration| Reply::Receipt));
    let victim = root.path().join("victim.txt");
    std::fs::write(&victim, "keep me\n").unwrap();
    let dir = spool_dir(&socket);
    let mut private = std::fs::DirBuilder::new();
    std::os::unix::fs::DirBuilderExt::mode(&mut private, 0o700);
    private.create(&dir).unwrap();
    std::os::unix::fs::symlink(&victim, queue_path(&socket, &socket, "terminal_link")).unwrap();
    let (id, encoded) = hook_request_in("terminal_link");

    let result = append_with_receipt(&socket, &id, &encoded, &|| {});
    let (_, admitted) = daemon.stop();

    result.unwrap();
    assert_eq!(admitted, vec![id], "the event was not delivered");
    assert_eq!(
        std::fs::read_to_string(&victim).unwrap(),
        "keep me\n",
        "the hook wrote through a symlink"
    );
}

/// A hook that queues while the sender deletes the finished queue gets a
/// sender: the old code unlinked the queue before the drain lock, so a child
/// in between appended to a new queue file, found the old drain lock held
/// and left its event with no sender.
#[test]
fn a_hook_that_queues_while_the_queue_is_deleted_still_gets_sent() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("s.sock");
    let daemon =
        Daemon::start(&socket, None, Arc::new(|_: &str, _: usize, _: Duration| Reply::Receipt));
    let (first_id, first) = hook_request_in("terminal_race");
    let (late_id, late) = hook_request_in("terminal_race");
    let late_hook = Arc::new(Mutex::new(None));
    {
        let (socket, late_id, late_hook) = (socket.clone(), late_id.clone(), late_hook.clone());
        hook_spool::between_unlinks_for_test(Box::new(move || {
            *late_hook.lock().unwrap() = Some(std::thread::spawn(move || {
                append_with_receipt(&socket, &late_id, &late, &|| {}).map_err(|e| format!("{e:#}"))
            }));
            // Room for the late hook to reach its drain lock while this
            // sender still holds its own.
            std::thread::sleep(Duration::from_millis(200));
        }));
    }

    let result = append_with_receipt(&socket, &first_id, &first, &|| {});
    let late_result = late_hook.lock().unwrap().take().expect("the hook ran").join().unwrap();
    let (_, admitted) = daemon.stop();

    result.unwrap();
    late_result.unwrap();
    assert!(admitted.contains(&late_id), "the late hook's event got no sender: {admitted:?}");
    assert_eq!(queue_files(&socket), Vec::<String>::new());
}

/// The session's next owner sends what a stop or crash left queued as soon
/// as it serves the socket (R2), not at some agent's next hook; a session
/// whose hooks never queued gets no queue directory.
#[test]
fn the_next_owner_sends_the_queues_a_stop_left() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("s.sock");
    let (left_id, left) = hook_request_in("terminal_left");
    leave_queue(&socket, "s.sock", "terminal_left", &[left]);
    let daemon =
        Daemon::start(&socket, None, Arc::new(|_: &str, _: usize, _: Duration| Reply::Receipt));

    send_session_queues(&socket);
    let (_, admitted) = daemon.stop();

    assert_eq!(admitted, vec![left_id], "the next owner did not get the queued event");
    assert_eq!(queue_files(&socket), Vec::<String>::new());
    let fresh = tempfile::tempdir().unwrap();
    send_session_queues(&fresh.path().join("new.sock"));
    assert!(!spool_dir(&fresh.path().join("new.sock")).exists(), "a queue directory was made");
}

/// The count of hook events no daemon would ever answer, beside `socket`.
fn undeliverable_events(socket: &Path) -> Option<String> {
    std::fs::read_to_string(spool_dir(socket).join("undeliverable-events")).ok()
}

/// A line the live daemon takes and never answers (it closes on it, or its
/// handler hangs) must not hold back every later event of its agent, and
/// its loss must show (R-L4: a budget, R-L5: the loss is counted). The old
/// sender retried such a line forever, and each new owner got it first again.
#[test]
fn a_line_the_daemon_never_answers_is_counted_and_does_not_block_the_agent() {
    for unanswered in [Reply::Close, Reply::Silent] {
        let root = tempfile::tempdir().unwrap();
        let socket = root.path().join("s.sock");
        let (bad_id, bad) = hook_request_in("terminal_stuck");
        let (next_id, next) = hook_request_in("terminal_stuck");
        let policy = {
            let bad_id = bad_id.clone();
            move |id: &str, _: usize, _: Duration| {
                if id == bad_id { unanswered } else { Reply::Receipt }
            }
        };
        leave_queue(&socket, "s.sock", "terminal_stuck", &[bad.clone(), next.clone()]);
        let daemon = Daemon::start(&socket, None, Arc::new(policy));

        let (id, encoded) = hook_request_in("terminal_stuck");
        // The old sender waited on a silent daemon forever: bound the test's
        // own wait so a regression fails here instead of hanging the run.
        let (done, finished) = std::sync::mpsc::channel();
        {
            let (socket, id) = (socket.clone(), id.clone());
            std::thread::spawn(move || {
                let _ = done.send(
                    append_with_receipt(&socket, &id, &encoded, &|| {})
                        .map_err(|error| format!("{error:#}")),
                );
            });
        }
        let result = finished.recv_timeout(Duration::from_secs(20));
        let (_, admitted) = daemon.stop();

        let result = result.unwrap_or_else(|_| panic!("{unanswered:?}: the sender never finished"));
        result.unwrap();
        assert_eq!(
            admitted,
            vec![next_id, id],
            "{unanswered:?}: the agent's later events were held back"
        );
        assert_eq!(
            undeliverable_events(&socket).as_deref().map(str::trim),
            Some("1"),
            "{unanswered:?}: the unanswered event was not counted"
        );
        assert_eq!(queue_files(&socket), Vec::<String>::new());
    }
}
