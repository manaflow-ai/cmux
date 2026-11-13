//! A verb's first contact waits for a Cloud machine's link (`reach`), as a
//! `cmux carrier serve` socket behaves right after a lease: it accepts and
//! opens the stream only later, is bound late or rebound, or closes a
//! connection whose dial failed without writing anything.
//!
//! Live red 5 (2026-11-10): the copy's stream opened 7.7 s after its accept,
//! past the old 5 s one-try `identify`, and `cmux chat --on vm:new
//! --from-folder` failed "Couldn't copy the folder to chat-…: the machine at
//! …/cmux-link-….sock did not answer". These tests scale those times down.

use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use super::*;

/// What the fake link does with each accepted connection, in order; the
/// last one repeats.
#[derive(Clone, Copy)]
enum Conn {
    /// Reads the request, waits, then answers `identify`.
    AnswerAfter(Duration),
    /// Closes at once, unanswered (a carrier dial that failed).
    Close,
    /// Reads the request and never answers.
    Silent,
    /// Answers with a refusal.
    Refuse,
}

fn socket_in(folder: &tempfile::TempDir) -> PathBuf {
    folder.path().join("cmux-link-0123456789ab.sock")
}

/// Serves `plan` on `socket` (bound after `bind_after`) on a thread.
fn fake_link(socket: &Path, bind_after: Duration, plan: Vec<Conn>) {
    let socket = socket.to_path_buf();
    std::thread::spawn(move || {
        std::thread::sleep(bind_after);
        let listener = UnixListener::bind(&socket).expect("bind the fake link");
        for (index, accepted) in listener.incoming().enumerate() {
            let Ok(stream) = accepted else { return };
            let conn = plan[index.min(plan.len() - 1)];
            std::thread::spawn(move || {
                if matches!(conn, Conn::Close) {
                    return;
                }
                let mut reader = BufReader::new(stream);
                let mut request = String::new();
                if reader.read_line(&mut request).unwrap_or(0) == 0 {
                    return;
                }
                let answer = match conn {
                    Conn::AnswerAfter(wait) => {
                        std::thread::sleep(wait);
                        json!({"id": 1, "ok": true,
                               "data": {"session_id": "s1", "capabilities": ["fs-v1"]}})
                    }
                    Conn::Refuse => {
                        json!({"id": 1, "ok": false, "error_code": "nope", "error": "no"})
                    }
                    Conn::Silent => {
                        std::thread::sleep(Duration::from_secs(30));
                        return;
                    }
                    Conn::Close => unreachable!(),
                };
                let _ = writeln!(reader.get_mut(), "{answer}");
            });
        }
    });
}

#[test]
fn a_stream_that_opens_past_the_one_try_budget_is_waited_for() {
    let folder = tempfile::tempdir().unwrap();
    let socket = socket_in(&folder);
    fake_link(&socket, Duration::ZERO, vec![Conn::AnswerAfter(Duration::from_millis(1500))]);
    std::thread::sleep(Duration::from_millis(100));
    // The old first contact: one try with a short budget fails on this link.
    let one_try = call_within(&socket, json!({"cmd": "identify"}), Duration::from_secs(1));
    assert!(
        matches!(&one_try, Err(CallFailure::Lost(why)) if why.contains("did not answer")),
        "{one_try:?}"
    );
    let identity = reach_within(&socket, Duration::from_secs(10)).expect("reach waits");
    assert_eq!(identity["session_id"], json!("s1"));
}

#[test]
fn a_socket_bound_after_the_first_dial_is_dialed_again() {
    let folder = tempfile::tempdir().unwrap();
    let socket = socket_in(&folder);
    fake_link(&socket, Duration::from_millis(600), vec![Conn::AnswerAfter(Duration::ZERO)]);
    assert!(identify(&socket).is_none(), "nothing listens yet");
    let identity = reach_within(&socket, Duration::from_secs(10)).expect("reach redials");
    assert_eq!(identity["session_id"], json!("s1"));
}

#[test]
fn a_connection_closed_unanswered_is_dialed_again() {
    let folder = tempfile::tempdir().unwrap();
    let socket = socket_in(&folder);
    fake_link(
        &socket,
        Duration::ZERO,
        vec![Conn::Close, Conn::Close, Conn::AnswerAfter(Duration::ZERO)],
    );
    std::thread::sleep(Duration::from_millis(100));
    let identity = reach_within(&socket, Duration::from_secs(10)).expect("reach redials");
    assert_eq!(identity["session_id"], json!("s1"));
}

#[test]
fn a_link_that_never_answers_ends_within_its_budget_and_says_what_to_do() {
    let folder = tempfile::tempdir().unwrap();
    let socket = socket_in(&folder);
    fake_link(&socket, Duration::ZERO, vec![Conn::Silent]);
    std::thread::sleep(Duration::from_millis(100));
    let started = Instant::now();
    let unreached = reach_within(&socket, Duration::from_millis(800)).expect_err("never answers");
    assert!(started.elapsed() < Duration::from_secs(3), "{:?}", started.elapsed());
    assert!(!unreached.refused);
    let message = unreached.to_string();
    assert!(message.contains("did not answer for"), "{message}");
    assert!(message.contains("send again in a minute"), "{message}");
}

#[test]
fn a_missing_socket_ends_within_its_budget() {
    let folder = tempfile::tempdir().unwrap();
    let socket = socket_in(&folder);
    let started = Instant::now();
    let unreached = reach_within(&socket, Duration::from_millis(700)).expect_err("no link");
    assert!(started.elapsed() < Duration::from_secs(3), "{:?}", started.elapsed());
    assert!(unreached.last.contains("cannot connect"), "{unreached:?}");
}

#[test]
fn a_refusal_is_the_answer_without_waiting() {
    let folder = tempfile::tempdir().unwrap();
    let socket = socket_in(&folder);
    fake_link(&socket, Duration::ZERO, vec![Conn::Refuse]);
    std::thread::sleep(Duration::from_millis(100));
    let started = Instant::now();
    let unreached = reach_within(&socket, Duration::from_secs(10)).expect_err("refused");
    assert!(unreached.refused);
    assert!(started.elapsed() < Duration::from_secs(2));
    assert!(unreached.to_string().contains("refused identify: nope: no"), "{unreached}");
}
