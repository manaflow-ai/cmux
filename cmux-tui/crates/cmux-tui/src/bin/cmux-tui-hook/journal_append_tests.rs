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

/// A failure the hook may retry is spaced by a backoff: the old loop called
/// `yield_now` between tries and ran a core for the whole 4 s bound.
#[test]
fn a_retryable_failure_backs_off_instead_of_spinning() {
    let mut attempts = 0_u32;
    let bound = Duration::from_millis(400);
    let started = Instant::now();
    let error = retry_until(bound, |_| {
        attempts += 1;
        Err::<(), _>(AppendAttemptError::Retryable(anyhow!("connection dropped")))
    })
    .unwrap_err();
    assert!(started.elapsed() <= bound + Duration::from_millis(200), "{error:#}");
    assert!(
        (2..=12).contains(&attempts),
        "{attempts} tries in {bound:?}: retries must be spaced by a backoff, not a spin"
    );
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
    /// A durable rejection (`ok: false`, not retryable).
    Reject,
    /// Close the connection without an answer.
    Close,
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
                            };
                            if writer.write_all(answer.as_bytes()).is_err() {
                                return;
                            }
                            if matches!(reply, Reply::Busy) {
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
        let (socket, id) = (socket.clone(), next_id.clone());
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

/// A daemon that drops every connection: the tries are spaced by a backoff,
/// not a spin.
#[test]
fn dropped_connections_are_retried_with_backoff_not_a_spin() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("d.sock");
    let dropping_for = Duration::from_millis(400);
    let policy = move |_: &str, _: usize, since: Duration| {
        if since < dropping_for { Reply::Close } else { Reply::Receipt }
    };
    let daemon = Daemon::start(&socket, None, Arc::new(policy));
    let (id, encoded) = hook_request_in("terminal_drop");

    let result = append_with_receipt(&socket, &id, &encoded, &|| {});
    let (connections, admitted) = daemon.stop();

    result.expect("a dropped connection is retried");
    assert_eq!(admitted, vec![id]);
    assert!(
        (2..=12).contains(&connections),
        "{connections} connections while the daemon dropped them for {dropping_for:?}"
    );
}

/// A terminal whose session socket is gone is not attached to a live
/// cmux-tui: the hook stops at once and leaves nothing behind.
#[test]
fn a_missing_session_socket_fails_at_once_and_keeps_nothing() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("missing.sock");
    let (id, encoded) = hook_request_in("terminal_gone");
    let started = Instant::now();

    assert!(append_with_receipt(&socket, &id, &encoded, &|| {}).is_err());
    assert!(started.elapsed() < Duration::from_secs(1));
    let left: Vec<_> = std::fs::read_dir(root.path()).unwrap().collect();
    assert!(left.is_empty(), "a hook for a gone session left {left:?}");
}
