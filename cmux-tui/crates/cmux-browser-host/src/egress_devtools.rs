//! DevTools endpoints by what they answer, for the egress service check
//! (crate::egress_services): a port whose `GET /json/version` answers like
//! V8's inspector (node, deno, Electron's main process) or Chrome's remote
//! debugging is refused, however it opened (`inspector.open()`, a process
//! title that hid `--inspect`, chrome://inspect, a debug terminal). The
//! argument and environment checks (crate::egress_holders) stay: they also
//! catch an inspector that is not answering yet.
//!
//! The probe is one HTTP/1.0 request with a 200 ms budget. Its answer is
//! remembered for 2 s per address and holder pids, so a page's many
//! connections to one dev server probe it once, and a new process on the
//! same port is probed again.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::{LazyLock, Mutex, PoisonError};
use std::time::{Duration, Instant};

const BUDGET: Duration = Duration::from_millis(200);
const REMEMBER: Duration = Duration::from_secs(2);
/// Fields of the `/json/version` answer of V8's inspector and of Chrome.
const MARKERS: &[&str] = &["\"webSocketDebuggerUrl\"", "\"Protocol-Version\"", "\"V8-Version\""];
const MAX_ANSWER: usize = 16 * 1024;

/// Whether an HTTP answer is a DevTools `/json/version` answer.
pub(crate) fn answers_like_devtools(answer: &[u8]) -> bool {
    let text = String::from_utf8_lossy(answer);
    MARKERS.iter().any(|marker| text.contains(marker))
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
    let devtools = remembered.unwrap_or_else(|| {
        let devtools = probe(addr);
        let mut seen = SEEN.lock().unwrap_or_else(PoisonError::into_inner);
        seen.retain(|_, (at, _)| now.duration_since(*at) < REMEMBER);
        seen.insert(key, (now, devtools));
        devtools
    });
    devtools.then(|| format!("{addr} answers like a DevTools endpoint (/json/version)"))
}

/// One `GET /json/version` within the budget; `false` when nothing answers.
fn probe(addr: SocketAddr) -> bool {
    let deadline = Instant::now() + BUDGET;
    let Ok(mut stream) = TcpStream::connect_timeout(&addr, BUDGET) else { return false };
    let request =
        format!("GET /json/version HTTP/1.0\r\nHost: {addr}\r\nConnection: close\r\n\r\n");
    if stream.set_write_timeout(Some(BUDGET)).is_err()
        || stream.write_all(request.as_bytes()).is_err()
    {
        return false;
    }
    let mut answer = Vec::new();
    let mut chunk = [0u8; 4096];
    while answer.len() < MAX_ANSWER {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() || stream.set_read_timeout(Some(left)).is_err() {
            break;
        }
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(read) => answer.extend_from_slice(&chunk[..read]),
        }
        if answers_like_devtools(&answer) {
            return true;
        }
    }
    answers_like_devtools(&answer)
}

#[cfg(test)]
#[path = "egress_devtools_tests.rs"]
mod tests;
