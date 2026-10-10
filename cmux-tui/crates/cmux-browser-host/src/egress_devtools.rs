//! DevTools endpoints by what they answer, for the egress service check
//! (crate::egress_services): a port whose `GET /json/version` answers like
//! V8's inspector (node, deno, Electron's main process) or Chrome's remote
//! debugging is refused, however it opened (`inspector.open()`, a process
//! title that hid `--inspect`, chrome://inspect, a debug terminal). The
//! argument and environment checks (crate::egress_holders) stay: they also
//! catch an inspector that is not answering yet.
//!
//! Only a connected peer held by node, bun or deno is probed
//! (crate::egress_services `probe`); Chromium-family holders are refused
//! before, by name or bundle.
//!
//! The probe is one HTTP/1.0 request within one 200 ms budget. An answer is
//! remembered for 2 s per address and holder pids, so a page's many
//! connections to one dev server probe it about once, and a new process on
//! the same port is probed again. No answer (a timeout) is not remembered,
//! so a slow inspector is probed again on the next connection.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::{LazyLock, Mutex, PoisonError};
use std::time::{Duration, Instant};

const BUDGET: Duration = Duration::from_millis(200);
const REMEMBER: Duration = Duration::from_secs(2);
/// Fields of the `/json/version` answer of V8's inspector and of Chrome.
/// The last is Chromium's and node's refusal of a foreign Host header.
const MARKERS: &[&str] = &[
    "\"webSocketDebuggerUrl\"",
    "\"Protocol-Version\"",
    "\"V8-Version\"",
    "Host header is specified and is not an IP address or localhost",
];
const MAX_ANSWER: usize = 16 * 1024;

/// Whether an HTTP answer is a DevTools `/json/version` answer.
pub(crate) fn answers_like_devtools(answer: &[u8]) -> bool {
    let text = String::from_utf8_lossy(answer);
    MARKERS.iter().any(|marker| text.contains(marker))
}

/// Whether a listener held by `holders` gets the probe: one of them is an
/// inspector runtime (crate::egress_holders::is_inspector_runtime).
pub(crate) fn wants_probe(holders: &[crate::egress_holders::Holder]) -> bool {
    holders.iter().any(crate::egress_holders::is_inspector_runtime)
}

/// Why `addr` is refused as a DevTools endpoint, or `None`.
/// `pids`: the processes that hold the listener.
pub(crate) fn refusal(addr: SocketAddr, pids: &[i32]) -> Option<String> {
    type Key = (SocketAddr, Vec<i32>);
    static SEEN: LazyLock<Mutex<HashMap<Key, (Instant, bool)>>> =
        LazyLock::new(|| Mutex::new(HashMap::new()));
    let mut pids = pids.to_vec();
    pids.sort_unstable();
    let key = (addr, pids);
    let now = Instant::now();
    let remembered = SEEN
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get(&key)
        .filter(|(at, _)| now.duration_since(*at) < REMEMBER)
        .map(|(_, devtools)| *devtools);
    let devtools = match remembered {
        Some(devtools) => devtools,
        None => {
            let answer = probe(addr);
            let mut seen = SEEN.lock().unwrap_or_else(PoisonError::into_inner);
            seen.retain(|_, (at, _)| now.duration_since(*at) < REMEMBER);
            if let Some(devtools) = answer {
                seen.insert(key, (now, devtools));
            }
            answer.unwrap_or(false)
        }
    };
    devtools.then(|| format!("{addr} answers like a DevTools endpoint (/json/version)"))
}

/// One `GET /json/version` within the budget: `Some(devtools)` for an
/// answer, `None` when nothing answered in time.
fn probe(addr: SocketAddr) -> Option<bool> {
    let deadline = Instant::now() + BUDGET;
    let left = || deadline.saturating_duration_since(Instant::now());
    let mut stream = TcpStream::connect_timeout(&addr, BUDGET).ok()?;
    let request = "GET /json/version HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    if left().is_zero()
        || stream.set_write_timeout(Some(left())).is_err()
        || stream.write_all(request.as_bytes()).is_err()
    {
        return None;
    }
    let mut answer = Vec::new();
    let mut chunk = [0u8; 4096];
    while answer.len() < MAX_ANSWER {
        if answers_like_devtools(&answer) {
            return Some(true);
        }
        if complete(&answer) {
            return Some(false);
        }
        let left = left();
        if left.is_zero() || stream.set_read_timeout(Some(left)).is_err() {
            break;
        }
        match stream.read(&mut chunk) {
            // The server closed: the answer is whole.
            Ok(0) => return Some(answers_like_devtools(&answer)),
            Err(_) => break,
            Ok(read) => answer.extend_from_slice(&chunk[..read]),
        }
    }
    (!answer.is_empty()).then(|| answers_like_devtools(&answer))
}

/// Whether an HTTP answer is whole without the server closing: its headers
/// ended and its `Content-Length` body arrived.
fn complete(answer: &[u8]) -> bool {
    let text = String::from_utf8_lossy(answer);
    let Some((head, body)) = text.split_once("\r\n\r\n") else { return false };
    head.lines()
        .find_map(|line| {
            let (name, value) = line.split_once(':')?;
            name.trim().eq_ignore_ascii_case("content-length").then(|| value.trim().parse().ok())?
        })
        .is_some_and(|length: usize| body.len() >= length)
}

#[cfg(test)]
#[path = "egress_devtools_tests.rs"]
mod tests;
