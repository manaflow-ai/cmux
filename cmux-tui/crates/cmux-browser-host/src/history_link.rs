//! The host's end of the daemon's history link (H3; ff decision
//! 2026-10-07). The daemon that supervises the host passes one end of a
//! socketpair at spawn (`--history-fd`); the host sends only the six page
//! history operations over it, one request line and one response line at
//! a time, and labels each with the REPL session it serves
//! (`on_behalf_of`, attribution only: the daemon stamps every request
//! origin agent, principal `browser-host:<pid>`). It never sends
//! `history.backups.purge` (only the user deletes a backup) and never
//! claims an origin.
//!
//! The descriptor is made close-on-exec when the host takes it, so the
//! browser and every other child never inherit the link.

use crate::protocol::{DriverError, ErrorCode};
use serde_json::{Value, json};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

/// The operations the host sends; the daemon admits these and no other.
pub const OPERATIONS: [&str; 6] = [
    "history.entries.list",
    "history.entries.remove",
    "history.site.remove",
    "history.visit.remove",
    "history.clear",
    "history.restore",
];

/// How long one call waits for the daemon's answer.
const REPLY_TIMEOUT: Duration = Duration::from_secs(15);

/// The longest response line read (the daemon answers at most 5,000
/// entries).
const MAX_REPLY: u64 = 16 << 20;

pub struct HistoryLink {
    io: Mutex<(BufReader<UnixStream>, UnixStream)>,
    next_id: AtomicU64,
}

/// Takes the inherited link descriptor `fd`: it must be a socket; it is
/// made close-on-exec at once.
pub fn inherited_link(fd: std::os::fd::RawFd) -> io::Result<HistoryLink> {
    use std::os::fd::FromRawFd;
    if fd < 3 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{fd}: not an inherited descriptor"),
        ));
    }
    // SAFETY: fstat(2) on an fd number with a zeroed out buffer.
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(fd, &mut stat) } != 0 || (stat.st_mode & libc::S_IFMT) != libc::S_IFSOCK
    {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, format!("{fd}: not a socket")));
    }
    // SAFETY: fcntl(2) on the fd checked above.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the daemon passes this socket open for this process; it is taken once.
    HistoryLink::new(unsafe { UnixStream::from_raw_fd(fd) })
}

fn random_hex() -> Result<String, DriverError> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes)
        .map_err(|e| DriverError::new(ErrorCode::Unsupported, format!("history: {e}")))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

fn closed(error: impl std::fmt::Display) -> DriverError {
    DriverError::new(
        ErrorCode::Closed,
        format!("history: the daemon's history link failed: {error}"),
    )
}

impl HistoryLink {
    pub fn new(stream: UnixStream) -> io::Result<HistoryLink> {
        stream.set_read_timeout(Some(REPLY_TIMEOUT))?;
        let writer = stream.try_clone()?;
        Ok(HistoryLink {
            io: Mutex::new((BufReader::new(stream), writer)),
            next_id: AtomicU64::new(1),
        })
    }

    /// Runs one of [`OPERATIONS`] for the session `on_behalf_of` and
    /// answers its result (a mutation's `value`).
    pub fn call(
        &self,
        on_behalf_of: &str,
        operation: &str,
        mut fields: Value,
    ) -> Result<Value, DriverError> {
        if !OPERATIONS.contains(&operation) {
            return Err(DriverError::new(
                ErrorCode::Forbidden,
                format!("{operation}: not a history operation the host may send"),
            ));
        }
        fields["machine"] = json!("current");
        fields["session"] = json!("current");
        let id = format!("bh-{}", self.next_id.fetch_add(1, Ordering::Relaxed));
        let mut request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": fields,
        });
        let mutation = operation != "history.entries.list";
        if mutation {
            request["idempotency_key"] = json!(format!("bh-{}", random_hex()?));
        }
        let line = json!({"on_behalf_of": on_behalf_of, "request": request}).to_string();
        let reply = {
            let mut io = self.io.lock().unwrap_or_else(PoisonError::into_inner);
            let (reader, writer) = &mut *io;
            writeln!(writer, "{line}").map_err(closed)?;
            let mut reply = String::new();
            match (&mut *reader).take(MAX_REPLY).read_line(&mut reply) {
                Ok(0) => return Err(closed("the daemon closed it")),
                Ok(_) => reply,
                Err(error) => return Err(closed(error)),
            }
        };
        let reply: Value = serde_json::from_str(&reply).map_err(closed)?;
        if reply["ok"] == true {
            let result = &reply["result"];
            return Ok(if mutation { result["value"].clone() } else { result.clone() });
        }
        let code = match reply["error"]["code"].as_str().unwrap_or("") {
            "origin.forbidden" => ErrorCode::Forbidden,
            "validation.invalid" | "idempotency.conflict" => ErrorCode::Invalid,
            _ => ErrorCode::Unsupported,
        };
        let message = reply["error"]["message"].as_str().unwrap_or("the daemon refused it");
        Err(DriverError::new(code, format!("{operation}: {message}")))
    }
}
