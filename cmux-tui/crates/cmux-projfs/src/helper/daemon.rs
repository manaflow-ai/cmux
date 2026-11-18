//! The [`Source`] the helper mounts with: `projfs.fetch` on the session daemon's local socket.
//!
//! The daemon is a rendezvous, never a file server: it queues the wants until the person's Mac,
//! which polls it over the link, takes them and answers. One request line per call, in the
//! daemon's line format (`{id, cmd, …params}`, answered `{id, ok, data}` or
//! `{id, ok:false, error, error_code}`).
//!
//! The daemon is restarted at chat start (to turn approvals on), so a connection may break at
//! any time. A call that cannot reach the daemon answers every want [`Got::Away`], which the read
//! path waits out and asks again, and each call dials afresh when it has no idle connection.
//! The first answer after the daemon was unreachable tells the core the source is back, so
//! waiting reads ask at once.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock, PoisonError, Weak};
use std::time::Duration;

use base64::Engine as _;
use serde_json::{Value, json};

use crate::cache::CHUNK;
use crate::core::Core;
use crate::manifest::Stat;
use crate::source::{Got, Source, Want};

/// How long one `projfs.fetch` asks the daemon to wait for a Mac to take its wants. The read
/// path waits out an absent Mac for 5 s in all, asking again, so two asks fit.
pub(crate) const FETCH_WAIT_MS: u64 = 2_000;
/// The most bytes one `projfs.fetch` asks for (the sum of its wants' `len`): the Mac answers
/// them in one request line, whose base64 must stay under the daemon's 16 MiB line limit.
pub(crate) const FETCH_BYTES: u64 = 8 << 20;
/// The most wants one `projfs.fetch` carries.
pub(crate) const FETCH_WANTS: usize = 512;
/// The largest answer line read from the daemon.
const MAX_ANSWER_BYTES: u64 = 24 << 20;
/// How long an answer may take past the fetch's own wait: a batch the Mac took is waited for
/// up to its lease (30 s on the daemon).
const ANSWER_SLACK: Duration = Duration::from_secs(45);
/// Idle connections kept for the next call.
const IDLE_CONNECTIONS: usize = 8;

/// The daemon's `projfs.fetch` as a [`Source`].
pub(super) struct DaemonSource {
    socket: PathBuf,
    mount: String,
    idle: Mutex<Vec<BufReader<UnixStream>>>,
    unreachable: AtomicBool,
    next_id: AtomicU64,
    core: OnceLock<Weak<Core>>,
}

/// Why a call got no answers.
enum CallError {
    /// The daemon could not be reached, or the connection broke: the wants answer `Away`.
    Unreachable,
    /// The daemon answered, but not with results: every want fails with this.
    Failed(String),
}

impl DaemonSource {
    pub(super) fn new(socket: PathBuf, mount: String) -> DaemonSource {
        DaemonSource {
            socket,
            mount,
            idle: Mutex::new(Vec::new()),
            unreachable: AtomicBool::new(false),
            next_id: AtomicU64::new(1),
            core: OnceLock::new(),
        }
    }

    /// The core to tell when the daemon is reachable again.
    pub(super) fn attach(&self, core: Weak<Core>) {
        let _ = self.core.set(core);
    }

    fn fetch_group(&self, wants: &[Want]) -> Vec<Got> {
        match self.call(wants) {
            Ok(results) => {
                if self.unreachable.swap(false, Ordering::SeqCst)
                    && let Some(core) = self.core.get().and_then(Weak::upgrade)
                {
                    core.source_back();
                }
                results
            }
            Err(CallError::Unreachable) => {
                self.unreachable.store(true, Ordering::SeqCst);
                vec![Got::Away; wants.len()]
            }
            Err(CallError::Failed(why)) => vec![Got::Failed(why); wants.len()],
        }
    }

    fn call(&self, wants: &[Want]) -> Result<Vec<Got>, CallError> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let request = json!({
            "id": id,
            "cmd": "projfs.fetch",
            "mount": self.mount,
            "wait_ms": FETCH_WAIT_MS,
            "wants": wants.iter().map(want_json).collect::<Vec<_>>(),
        });
        let mut line = request.to_string();
        line.push('\n');
        // An idle connection may have been closed by a daemon restart since: one fresh dial.
        let reused = self.take_idle();
        let fresh_only = reused.is_none();
        let mut conn = match reused {
            Some(conn) => conn,
            None => self.dial()?,
        };
        let answer = match exchange(&mut conn, &line, id) {
            Ok(answer) => answer,
            Err(()) if !fresh_only => {
                conn = self.dial()?;
                exchange(&mut conn, &line, id).map_err(|()| CallError::Unreachable)?
            }
            Err(()) => return Err(CallError::Unreachable),
        };
        self.put_idle(conn);
        parse_answer(&answer, wants.len())
    }

    fn take_idle(&self) -> Option<BufReader<UnixStream>> {
        self.idle.lock().unwrap_or_else(PoisonError::into_inner).pop()
    }

    fn put_idle(&self, conn: BufReader<UnixStream>) {
        let mut idle = self.idle.lock().unwrap_or_else(PoisonError::into_inner);
        if idle.len() < IDLE_CONNECTIONS {
            idle.push(conn);
        }
    }

    fn dial(&self) -> Result<BufReader<UnixStream>, CallError> {
        let stream = UnixStream::connect(&self.socket).map_err(|_| CallError::Unreachable)?;
        let wait = Duration::from_millis(FETCH_WAIT_MS) + ANSWER_SLACK;
        stream.set_read_timeout(Some(wait)).map_err(|_| CallError::Unreachable)?;
        stream.set_write_timeout(Some(ANSWER_SLACK)).map_err(|_| CallError::Unreachable)?;
        Ok(BufReader::new(stream))
    }
}

impl Source for DaemonSource {
    fn fetch(&self, wants: &[Want]) -> Vec<Got> {
        let mut out = Vec::with_capacity(wants.len());
        for group in groups(wants) {
            out.extend(self.fetch_group(group));
        }
        out
    }
}

/// Splits `wants` into runs that each fit one `projfs.fetch` ([`FETCH_BYTES`], [`FETCH_WANTS`]).
fn groups(wants: &[Want]) -> Vec<&[Want]> {
    let mut out = Vec::new();
    let mut rest = wants;
    while !rest.is_empty() {
        // How many of `rest` fit one fetch: at least one.
        let mut bytes = 0u64;
        let mut take = 0usize;
        for w in rest.iter().take(FETCH_WANTS) {
            bytes = bytes.saturating_add(u64::from(w.len).min(CHUNK));
            if take > 0 && bytes > FETCH_BYTES {
                break;
            }
            take = take.saturating_add(1);
        }
        let (group, tail) = rest.split_at(take.min(rest.len()));
        out.push(group);
        rest = tail;
    }
    out
}

fn want_json(w: &Want) -> Value {
    json!({
        "path": w.path,
        "size": w.version.size,
        "mtime_ns": w.version.mtime_ns,
        "ctime_ns": w.version.ctime_ns,
        "offset": w.offset,
        "len": w.len,
    })
}

/// Sends `line` and reads the answer whose `id` is `id` (a few others are skipped).
fn exchange(conn: &mut BufReader<UnixStream>, line: &str, id: u64) -> Result<Value, ()> {
    conn.get_mut().write_all(line.as_bytes()).map_err(drop)?;
    for _ in 0..4 {
        let mut buf = Vec::new();
        let read = Read::take(&mut *conn, MAX_ANSWER_BYTES + 1).read_until(b'\n', &mut buf);
        if read.map_err(drop)? == 0 || buf.last() != Some(&b'\n') {
            return Err(());
        }
        let Ok(answer) = serde_json::from_slice::<Value>(&buf) else { return Err(()) };
        if answer.get("id").and_then(Value::as_u64) == Some(id) {
            return Ok(answer);
        }
    }
    Err(())
}

fn parse_answer(answer: &Value, n: usize) -> Result<Vec<Got>, CallError> {
    if answer.get("ok").and_then(Value::as_bool) != Some(true) {
        let code = answer.get("error_code").and_then(Value::as_str).unwrap_or("unknown");
        let message = answer.get("error").and_then(Value::as_str).unwrap_or("");
        // A daemon that does not serve projected folders (yet: an older one before the restart
        // that updates it) is as good as away.
        if code == "projfs.unavailable" {
            return Err(CallError::Unreachable);
        }
        return Err(CallError::Failed(format!("the daemon refused the fetch: {code}: {message}")));
    }
    let results = answer
        .pointer("/data/results")
        .and_then(Value::as_array)
        .filter(|r| r.len() == n)
        .ok_or_else(|| CallError::Failed("the daemon's answer has the wrong results".into()))?;
    Ok(results.iter().map(parse_result).collect())
}

/// One result: `{status:"bytes", data_b64}`, `{status:"changed", size, mtime_ns, ctime_ns,
/// mode}`, `{status:"gone"}`, `{status:"withheld"}`, `{status:"failed", reason}` or
/// `{status:"away"}`.
pub(super) fn parse_result(r: &Value) -> Got {
    let int = |k: &str| r.get(k).and_then(Value::as_i64);
    match r.get("status").and_then(Value::as_str) {
        Some("bytes") => match r
            .get("data_b64")
            .and_then(Value::as_str)
            .map(|d| base64::engine::general_purpose::STANDARD.decode(d))
        {
            Some(Ok(bytes)) => Got::Bytes(bytes),
            _ => Got::Failed("the Mac's bytes are not base64".into()),
        },
        Some("changed") => match (int("size"), int("mtime_ns"), int("ctime_ns"), int("mode")) {
            (Some(size), Some(m), Some(c), Some(mode)) if size >= 0 && mode >= 0 => {
                Got::Changed(Stat::file((mode & 0o7777) as u32, size as u64, m, c))
            }
            _ => Got::Failed("a changed answer without its stat".into()),
        },
        Some("gone") => Got::Gone,
        Some("withheld") => Got::Withheld,
        Some("away") => Got::Away,
        Some("failed") => Got::Failed(
            r.get("reason").and_then(Value::as_str).unwrap_or("the Mac could not read it").into(),
        ),
        _ => Got::Failed("an answer with an unknown status".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::Version;

    fn want(len: u32) -> Want {
        Want {
            path: "a".into(),
            version: Version { size: 1, mtime_ns: 0, ctime_ns: 0 },
            offset: 0,
            len,
        }
    }

    #[test]
    fn wants_split_by_bytes_and_count() {
        let big: Vec<Want> = (0..5).map(|_| want(CHUNK as u32)).collect();
        let sizes: Vec<usize> = groups(&big).iter().map(|g| g.len()).collect();
        assert_eq!(sizes, [2, 2, 1]);
        let many: Vec<Want> = (0..1100).map(|_| want(10)).collect();
        let sizes: Vec<usize> = groups(&many).iter().map(|g| g.len()).collect();
        assert_eq!(sizes, [512, 512, 76]);
        assert!(groups(&[]).is_empty());
    }

    #[test]
    fn results_parse() {
        let b64 = base64::engine::general_purpose::STANDARD.encode(b"hi");
        assert_eq!(
            parse_result(&json!({"status":"bytes","data_b64":b64})),
            Got::Bytes(b"hi".to_vec())
        );
        assert_eq!(
            parse_result(
                &json!({"status":"changed","size":3,"mtime_ns":5,"ctime_ns":6,"mode":0o100644})
            ),
            Got::Changed(Stat::file(0o644, 3, 5, 6))
        );
        assert_eq!(parse_result(&json!({"status":"away"})), Got::Away);
        assert!(matches!(parse_result(&json!({"status":"bytes","data_b64":"!"})), Got::Failed(_)));
        assert!(matches!(parse_result(&json!({"status":"what"})), Got::Failed(_)));
    }
}
