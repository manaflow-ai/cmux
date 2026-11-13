//! The daemon's line reader sees every end of a client's sending side. A
//! client ends its side with a half-close (`shutdown(Write)`) and keeps its
//! descriptor to read the last replies (`cmux-tui relay`, the host-share
//! splice, the remote terminal-bytes pump). On macOS 26 and 27 a thread
//! blocked in recv() can miss the wake of that shutdown (this reader, with
//! 8 clients at once: 1 in 7,000 to 1 in 17,000 rounds), and then stays
//! blocked for the daemon's life; a thread that waits in poll() saw every
//! one (opt-tools probes/shutdown_wake.rs). `LineSocket` waits in poll()
//! before each read.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::AtomicUsize;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use super::*;

enum Seen {
    Line(String),
    End,
}

/// Reads `stream` the way `serve_line_connection` does: lines through a
/// `BufReader` over a `LineSocket`, until the end or an error.
fn read_lines(stream: Box<dyn transport::Stream>) -> (JoinHandle<()>, mpsc::Receiver<Seen>) {
    let (seen, events) = mpsc::channel();
    let reader = std::thread::spawn(move || {
        let mut reader = BufReader::new(LineSocket::new(stream));
        loop {
            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    if seen.send(Seen::Line(line)).is_err() {
                        return;
                    }
                }
            }
        }
        let _ = seen.send(Seen::End);
    });
    (reader, events)
}

#[derive(Clone, Copy, Debug)]
enum Race {
    /// The client half-closes while the reader starts its first read.
    AtFirstRead,
    /// The client half-closes right after the reader took one line, while
    /// it goes back into its read.
    AfterALine,
}

/// One client that half-closes and keeps its descriptor. `true` when the
/// reader did not see the end within `wait` (then the client closes, the
/// last close wakes the reader, and it is joined).
fn half_close_missed(
    make: &dyn Fn(UnixStream) -> Box<dyn transport::Stream>,
    race: Race,
    wait: Duration,
) -> bool {
    let (ours, client) = UnixStream::pair().unwrap();
    let kept = client.try_clone().unwrap();
    if matches!(race, Race::AfterALine) {
        (&client).write_all(b"{}\n").unwrap();
    }
    let (reader, events) = read_lines(make(ours));
    if matches!(race, Race::AfterALine) {
        assert!(matches!(events.recv_timeout(Duration::from_secs(10)), Ok(Seen::Line(_))));
    }
    client.shutdown(Shutdown::Write).unwrap();
    let missed = !matches!(events.recv_timeout(wait), Ok(Seen::End));
    drop(client);
    drop(kept);
    reader.join().unwrap();
    missed
}

fn plain(stream: UnixStream) -> Box<dyn transport::Stream> {
    Box::new(stream)
}

/// The remote entry's stream: the first line it already read, replayed.
fn prefixed(stream: UnixStream) -> Box<dyn transport::Stream> {
    fs_wire::prefixed_for_test(Vec::new(), stream)
}

/// `rounds` half-close rounds over `workers` threads at once (concurrent
/// clients make the miss more likely), round `n` with race
/// `races[n % races.len()]`. Counts the misses; with `stop_at_miss` every
/// worker stops at the first one.
fn count_half_close_misses(
    make: &(dyn Fn(UnixStream) -> Box<dyn transport::Stream> + Sync),
    races: &[Race],
    rounds: usize,
    workers: usize,
    stop_at_miss: bool,
) -> usize {
    let misses = AtomicUsize::new(0);
    let next = AtomicUsize::new(0);
    std::thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| {
                loop {
                    let round = next.fetch_add(1, Ordering::Relaxed);
                    if round >= rounds || (stop_at_miss && misses.load(Ordering::Relaxed) > 0) {
                        return;
                    }
                    let race = races[round % races.len()];
                    if half_close_missed(make, race, Duration::from_millis(1500)) {
                        misses.fetch_add(1, Ordering::Relaxed);
                    }
                }
            });
        }
    });
    misses.into_inner()
}

fn env_count(name: &str, default: usize) -> usize {
    std::env::var(name).ok().and_then(|value| value.parse().ok()).unwrap_or(default)
}

/// Not a check: the miss rate of the reader at this commit, for choosing the
/// rounds of the check below. `CMUX_LINE_READER_ROUNDS` rounds per race and
/// per worker count in `CMUX_LINE_READER_WORKERS` (a comma list).
#[test]
#[ignore = "measurement: run with --ignored on each macOS version"]
fn measure_the_half_close_miss_rate() {
    let rounds = env_count("CMUX_LINE_READER_ROUNDS", 20_000);
    let workers: Vec<usize> = std::env::var("CMUX_LINE_READER_WORKERS")
        .unwrap_or_else(|_| "1".into())
        .split(',')
        .filter_map(|value| value.trim().parse().ok())
        .collect();
    for workers in workers {
        for race in [Race::AtFirstRead, Race::AfterALine] {
            let started = Instant::now();
            let misses = count_half_close_misses(&plain, &[race], rounds, workers, false);
            let us = started.elapsed().as_micros() / rounds as u128;
            println!(
                "RATE race={race:?} workers={workers} rounds={rounds} misses={misses} \
                 us_per_round={us}"
            );
        }
    }
}

/// Rounds per check, chosen so that the old reader (a blocking recv) passes
/// by chance with probability under 1 in 10,000. Measured at 8ea06419 with 8
/// workers and both races in turn (`measure_the_half_close_miss_rate`), the
/// lowest rate was 24 misses in 400,000 rounds (aws-m4pro-6, macOS 26.5.2,
/// load 22; aws-m4pro-3, macOS 27.0.1: 57 in 400,000). The 95% Poisson
/// lower bound of 24 events is 15.38, so p >= 15.38 / 400,000 = 3.84e-5.
/// The old reader passes N rounds with probability (1 - p)^N <= e^(-pN);
/// e^(-pN) < 1e-4 needs N > ln(10^4) / p = 9.21 / 3.84e-5 = 239,600.
/// N = 250,000 gives e^(-9.61) = 6.7e-5. At 30-50 us per round that is 8 to
/// 13 s on an idle host and longer on a loaded one, over the 10 s budget of
/// the default run: the two checks are ignored by default, and run with
/// `cargo test -p cmux-tui-core --lib read_tests::the_line_reader_sees_every_half_close -- --ignored`.
/// The old reader fails them in about 3 s (its first miss).
const HALF_CLOSE_ROUNDS: usize = 250_000;
const HALF_CLOSE_WORKERS: usize = 8;
const BOTH_RACES: [Race; 2] = [Race::AtFirstRead, Race::AfterALine];

fn assert_no_half_close_missed(make: &(dyn Fn(UnixStream) -> Box<dyn transport::Stream> + Sync)) {
    let rounds = env_count("CMUX_LINE_READER_ROUNDS", HALF_CLOSE_ROUNDS);
    let misses = count_half_close_misses(make, &BOTH_RACES, rounds, HALF_CLOSE_WORKERS, true);
    assert_eq!(misses, 0, "the reader missed a client's half-close in {rounds} rounds");
}

#[test]
#[ignore = "250,000 rounds, over the 10 s budget: see HALF_CLOSE_ROUNDS"]
fn the_line_reader_sees_every_half_close_of_a_local_client() {
    assert_no_half_close_missed(&plain);
}

#[test]
#[ignore = "250,000 rounds, over the 10 s budget: see HALF_CLOSE_ROUNDS"]
fn the_line_reader_sees_every_half_close_of_a_remote_entry_client() {
    assert_no_half_close_missed(&prefixed);
}

/// Lines a client sent before its end are read, then the end: a wait that
/// sees the hang-up still lets the read drain the last bytes.
/// `half_close`: the client only shuts down its sending side and stays
/// open; otherwise it closes.
fn reads_the_last_lines_then_the_end(half_close: bool) {
    let (ours, client) = UnixStream::pair().unwrap();
    (&client).write_all(b"{\"a\":1}\n{\"b\":2}\n").unwrap();
    let kept = if half_close {
        client.shutdown(Shutdown::Write).unwrap();
        Some(client)
    } else {
        drop(client);
        None
    };
    let (reader, events) = read_lines(Box::new(ours));
    let mut seen = Vec::new();
    loop {
        match events.recv_timeout(Duration::from_secs(5)) {
            Ok(Seen::Line(line)) => seen.push(line),
            Ok(Seen::End) => break,
            Err(_) => panic!("no end after {seen:?}"),
        }
    }
    reader.join().unwrap();
    assert_eq!(seen, ["{\"a\":1}\n", "{\"b\":2}\n"]);
    drop(kept);
}

#[test]
fn the_last_lines_before_a_half_close_are_read() {
    reads_the_last_lines_then_the_end(true);
}

#[test]
fn the_last_lines_before_the_client_closes_are_read() {
    reads_the_last_lines_then_the_end(false);
}

/// A read timeout on the socket still ends a read that gets nothing: the
/// wait fails as the read would.
#[test]
fn a_read_timeout_still_ends_a_read_that_gets_nothing() {
    let (ours, _client) = UnixStream::pair().unwrap();
    ours.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
    let mut reader = BufReader::new(LineSocket::new(Box::new(ours)));
    let started = Instant::now();
    let error = reader.read_line(&mut String::new()).unwrap_err();
    assert!(
        matches!(error.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut),
        "{error:?}"
    );
    assert!(started.elapsed() < Duration::from_secs(5));
}

/// The remote entry's replayed first line is read at once, while the socket
/// has nothing to read and stays open.
#[test]
fn a_replayed_first_line_is_read_without_waiting_for_the_socket() {
    let (ours, _client) = UnixStream::pair().unwrap();
    let stream = fs_wire::prefixed_for_test(b"{\"first\":1}\n".to_vec(), ours);
    let (_reader, events) = read_lines(stream);
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(5)),
        Ok(Seen::Line(line)) if line == "{\"first\":1}\n"
    ));
}

extern "C" fn note_signal(_: libc::c_int) {}

/// Reads once through a `LineSocket` while another thread sends SIGURG
/// (caught, no `SA_RESTART`) to the reader every 10 ms for `signals_for`;
/// then `client` sends `then_send`. Returns the read's result and its time.
fn read_while_signalled(
    read_timeout: Option<Duration>,
    signals_for: Duration,
    then_send: &[u8],
) -> (Result<usize, std::io::ErrorKind>, Duration) {
    // SAFETY: a handler that does nothing, installed for a signal whose
    // default action is to ignore it; no other code of this test binary
    // catches SIGURG.
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = note_signal as extern "C" fn(libc::c_int) as libc::sighandler_t;
        libc::sigemptyset(&mut action.sa_mask);
        assert_eq!(libc::sigaction(libc::SIGURG, &action, std::ptr::null_mut()), 0);
    }
    let (ours, client) = UnixStream::pair().unwrap();
    ours.set_read_timeout(read_timeout).unwrap();
    let (thread_id, reader_id) = mpsc::channel();
    let reader = std::thread::spawn(move || {
        // SAFETY: pthread_self has no preconditions.
        thread_id.send(unsafe { libc::pthread_self() } as usize).unwrap();
        let mut socket = LineSocket::new(Box::new(ours));
        let started = Instant::now();
        let result = socket.read(&mut [0; 16]).map_err(|error| error.kind());
        (result, started.elapsed())
    });
    let reader_id = reader_id.recv().unwrap();
    let started = Instant::now();
    while started.elapsed() < signals_for && !reader.is_finished() {
        // SAFETY: the reader thread is not joined yet, so its id is valid.
        unsafe { libc::pthread_kill(reader_id as libc::pthread_t, libc::SIGURG) };
        std::thread::sleep(Duration::from_millis(10));
    }
    if !then_send.is_empty() {
        (&client).write_all(then_send).unwrap();
    }
    reader.join().unwrap()
}

/// A signal during the wait does not end it: the wait polls again (EINTR),
/// for the time left of the read timeout when the socket has one.
#[test]
fn a_signal_during_the_wait_does_not_end_the_read() {
    let (result, _) = read_while_signalled(None, Duration::from_millis(200), b"x");
    assert_eq!(result, Ok(1));

    let timeout = Duration::from_millis(400);
    let (result, took) = read_while_signalled(Some(timeout), Duration::from_millis(200), b"");
    assert!(
        matches!(result, Err(std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut)),
        "{result:?}"
    );
    assert!(took >= timeout, "the read ended after {took:?}, before its {timeout:?} timeout");
}
