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

/// Hooks refused at the same moment come back spread out, each no sooner than
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
        .map(|_| {
            let socket = socket.clone();
            let start = start.clone();
            std::thread::spawn(move || {
                let (request_id, encoded) = hook_request();
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
