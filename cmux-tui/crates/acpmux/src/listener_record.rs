//! `listener.json` in the acpmux home: the WebSocket listener of the daemon running now, for the
//! cmux link, which carries a paired peer's `acpmux` stream to it (`cmux-tui`
//! `link/acpmux.rs`).
//!
//! It is the only way the link finds the listener. `websocket.listen` in config.json is never
//! read for this: it outlives the daemon, and a stale port can reach whatever local service binds
//! it later. A DEV build listens on `127.0.0.1:0` and never saves its port, and a daemon whose
//! saved port was taken moves to a free one, so config.json is also often wrong.
//!
//! The daemon writes the record once its listener is bound and removes it on a clean exit. A
//! reader ([`connect_live`]) trusts it only when all of these hold, and otherwise sends nothing:
//! - the record's process still runs, with the start time the record names (a reused pid has
//!   another) and this reader's uid;
//! - the listener at the recorded address answers [`PROBE`] with the record's nonce, a random
//!   value this daemon drew at start (`serve_ws_until` answers it before any request head).
//!
//! Format (mode 0600, replaced through a temp file and a rename):
//! `{"version":1,"listen":"127.0.0.1:52341","pid":1234,"start":[1794120000,123456],"nonce":"<32 hex>"}`.
//! `start` is the OS start time of `pid`: on macOS `proc_bsdinfo` seconds and microseconds, on
//! Linux `/proc/<pid>/stat` field 22 (clock ticks since boot) and 0.

use std::io;
use std::net::SocketAddr;
use std::path::Path;
use std::sync::OnceLock;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::TcpStream;

/// The file name in the acpmux home.
pub const FILE_NAME: &str = "listener.json";
/// The first bytes the link sends: a whole request head to the listener's reader
/// (`server/ws_peek.rs`), answered with [`answer`] instead of HTTP.
pub const PROBE: &[u8] = b"ACPMUX-LINK/1\r\n\r\n";
const ANSWER_PREFIX: &str = "ACPMUX-LINK/1 ";
const VERSION: u32 = 1;
const MAX_BYTES: u64 = 4096;
/// The answer line's bound: the prefix, 32 hex digits and a newline, with room to spare.
const MAX_ANSWER_BYTES: usize = 128;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    version: u32,
    listen: SocketAddr,
    pid: u32,
    start: (u64, u64),
    nonce: String,
}

/// This process's nonce: 16 random bytes as hex, drawn once.
fn nonce() -> &'static str {
    static NONCE: OnceLock<String> = OnceLock::new();
    NONCE.get_or_init(|| {
        let mut bytes = [0u8; 16];
        // Without randomness the record cannot be bound to this listener: an empty nonce is
        // refused by every reader.
        if getrandom::fill(&mut bytes).is_err() {
            return String::new();
        }
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    })
}

/// The line the listener answers [`PROBE`] with.
pub fn answer() -> String {
    format!("{ANSWER_PREFIX}{}\n", nonce())
}

/// Record `listen` as this process's listener in `home`.
pub fn write(home: &Path, listen: SocketAddr) -> io::Result<()> {
    use std::io::Write as _;
    let pid = std::process::id();
    let (start, _) = process_identity(pid)?;
    if nonce().is_empty() {
        return Err(io::Error::other("no randomness for the listener nonce"));
    }
    let record = Record { version: VERSION, listen, pid, start, nonce: nonce().to_owned() };
    let text = serde_json::to_vec(&record).map_err(io::Error::other)?;
    let temp = home.join(format!(".{FILE_NAME}.{pid}.tmp"));
    let written = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = options.open(&temp)?;
        file.write_all(&text)?;
        file.sync_all()?;
        std::fs::rename(&temp, home.join(FILE_NAME))
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    written
}

/// Remove the record when it is this process's (a clean exit).
pub fn remove_if_owned(home: &Path) {
    if read(home).is_some_and(|record| record.pid == std::process::id() && record.nonce == nonce())
    {
        let _ = std::fs::remove_file(home.join(FILE_NAME));
    }
}

fn read(home: &Path) -> Option<Record> {
    let path = home.join(FILE_NAME);
    let meta = std::fs::symlink_metadata(&path).ok()?;
    if !meta.is_file() || meta.len() > MAX_BYTES {
        return None;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        // Only this user's file: another user cannot point the link anywhere.
        if meta.uid() != effective_uid() {
            return None;
        }
    }
    let record: Record = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    (record.version == VERSION && !record.nonce.is_empty()).then_some(record)
}

/// Why [`connect_live`] sent nothing on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotLive {
    /// No record, or one that is not this user's or does not parse.
    NoRecord,
    /// The record's address is not on loopback, or its port is 0.
    NotLoopback,
    /// The record's process ended, or its pid now names another process (start time or uid).
    Stale,
    /// Nothing listens at the recorded address.
    Unreachable,
    /// The listener there did not answer the probe with the record's nonce.
    WrongListener,
}

/// The listener of the acpmux daemon that runs from `home` now, connected and proven by its nonce:
/// the stream is past the probe, and the caller's bytes go to the listener's request reader.
/// `bound` limits the connect and the probe together.
pub async fn connect_live(home: &Path, bound: Duration) -> Result<TcpStream, NotLive> {
    let record = read(home).ok_or(NotLive::NoRecord)?;
    if !record.listen.ip().is_loopback() || record.listen.port() == 0 {
        return Err(NotLive::NotLoopback);
    }
    match process_identity(record.pid) {
        Ok((start, uid)) if start == record.start && uid == effective_uid() => {}
        _ => return Err(NotLive::Stale),
    }
    tokio::time::timeout(bound, async {
        let mut stream =
            TcpStream::connect(record.listen).await.map_err(|_| NotLive::Unreachable)?;
        let _ = stream.set_nodelay(true);
        stream.write_all(PROBE).await.map_err(|_| NotLive::WrongListener)?;
        let expected = format!("{ANSWER_PREFIX}{}\n", record.nonce);
        let mut line = Vec::with_capacity(expected.len());
        // Byte by byte: what follows the answer belongs to the caller's stream.
        while line.last() != Some(&b'\n') {
            if line.len() >= MAX_ANSWER_BYTES {
                return Err(NotLive::WrongListener);
            }
            let byte = stream.read_u8().await.map_err(|_| NotLive::WrongListener)?;
            line.push(byte);
        }
        if line != expected.as_bytes() {
            return Err(NotLive::WrongListener);
        }
        Ok(stream)
    })
    .await
    .unwrap_or(Err(NotLive::Unreachable))
}

#[cfg(unix)]
fn effective_uid() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

#[cfg(not(unix))]
fn effective_uid() -> u32 {
    0
}

/// `pid`'s OS start time and uid: what tells a live daemon from a reused pid.
#[cfg(target_os = "macos")]
fn process_identity(pid: u32) -> io::Result<((u64, u64), u32)> {
    let pid = libc::c_int::try_from(pid).map_err(io::Error::other)?;
    // SAFETY: proc_bsdinfo is plain C data; the out-buffer has its exact size.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = libc::c_int::try_from(size_of::<libc::proc_bsdinfo>()).map_err(io::Error::other)?;
    // SAFETY: info is writable for `size` bytes, as this flavor needs.
    let written =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size) };
    if written != size {
        return Err(io::Error::new(io::ErrorKind::NotFound, "no such process"));
    }
    Ok(((info.pbi_start_tvsec, info.pbi_start_tvusec), info.pbi_uid))
}

/// `pid`'s OS start time and uid: what tells a live daemon from a reused pid.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn process_identity(pid: u32) -> io::Result<((u64, u64), u32)> {
    use std::os::unix::fs::MetadataExt as _;
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat"))?;
    let uid = std::fs::metadata(format!("/proc/{pid}"))?.uid();
    let start = linux_start(&stat).ok_or_else(|| io::Error::other("unreadable /proc stat"))?;
    Ok(((start, 0), uid))
}

/// Field 22 (starttime) of `/proc/<pid>/stat`; the command name may hold spaces and ')'.
#[cfg(any(target_os = "linux", target_os = "android", test))]
fn linux_start(stat: &str) -> Option<u64> {
    let (_, fields) = stat.rsplit_once(')')?;
    fields.split_whitespace().nth(19)?.parse().ok()
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "macos")))]
fn process_identity(_pid: u32) -> io::Result<((u64, u64), u32)> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "no process identity on this OS"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_start_time_is_field_22_after_the_command_name() {
        let stat = "42 (a ) b) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 777 20";
        assert_eq!(linux_start(stat), Some(777));
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn the_record_is_this_users_and_a_clean_exit_removes_it() {
        let home = tempfile::tempdir().unwrap();
        write(home.path(), "127.0.0.1:52341".parse().unwrap()).unwrap();
        let record = read(home.path()).unwrap();
        assert_eq!(record.pid, std::process::id());
        assert_eq!(record.nonce.len(), 32);
        assert_eq!(answer(), format!("ACPMUX-LINK/1 {}\n", record.nonce));
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(home.path().join(FILE_NAME)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        remove_if_owned(home.path());
        assert!(!home.path().join(FILE_NAME).exists());
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn another_daemons_record_is_left_alone() {
        let home = tempfile::tempdir().unwrap();
        let other = r#"{"version":1,"listen":"127.0.0.1:1","pid":1,"start":[1,0],"nonce":"ab"}"#;
        std::fs::write(home.path().join(FILE_NAME), other).unwrap();
        remove_if_owned(home.path());
        assert!(home.path().join(FILE_NAME).exists());
    }
}
