//! `listener.json` in the acpmux home: the WebSocket listener of the daemon running now, for the
//! cmux link, which carries a paired peer's `acpmux` stream to it (`cmux-tui`
//! `link/acpmux.rs`).
//!
//! It is the only way the link finds the listener. `websocket.listen` in config.json is never
//! read for this: it outlives the daemon, and a stale port can reach whatever local service binds
//! it later. A DEV build listens on `127.0.0.1:0` and never saves its port, and a daemon whose
//! saved port was taken moves to a free one, so config.json is also often wrong.
//!
//! The record holds the address to dial: a wildcard bind (`0.0.0.0:P`, `[::]:P`) is recorded as
//! loopback (`127.0.0.1:P`, `[::1]:P`). It is written once per run: the daemon binds its web
//! listener once, before it serves (`daemon.rs`: the configured address, or a free loopback port
//! when that one is taken), and moves that listener into its one `serve_ws_until` task; nothing
//! rebinds it while the daemon runs.
//!
//! [`write`] returns a [`Written`] guard: dropping it removes the record, so a startup that fails
//! after the write leaves none, and the daemon drops it first thing in its shutdown, while its
//! listener is still bound (the record is gone before the port is freed). A crash leaves the
//! record; a reader refuses it, as below: no live listener holds a dead daemon's key. The write goes through the lost-home fence
//! (`config::refuse_lost_home`): a home replaced under the daemon never gets its record.
//!
//! A reader ([`connect_live`]) trusts the record only when all of these hold, and otherwise sends
//! nothing:
//! - the file is this user's;
//! - the listener at the recorded address answers a fresh random challenge with its HMAC-SHA256
//!   under the record's key. The key is drawn per daemon process and kept only in its memory
//!   and in this record (mode 0600), so only the daemon that wrote the record can answer. A
//!   process of another user cannot read the key, an answer seen once is useless for the next
//!   challenge, and a service that binds the port after the daemon (or after a crash) cannot
//!   pass, whatever it watched before. No process is inspected: cmux-next never scans processes.
//!
//! Format (mode 0600, replaced through a temp file and a rename):
//! `{"version":2,"listen":"127.0.0.1:52341","pid":1234,"key":"<64 hex>"}`. `pid` only tells
//! the writer its own record when it removes it; readers do not use it.
//!
//! The probe is one request head, so the listener's reader (`server/ws_peek.rs`) reads it whole:
//! `ACPMUX-LINK/2 <challenge: 64 hex>\r\n\r\n`, answered with `ACPMUX-LINK/2 <hmac: 64 hex>\n`.

use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::TcpStream;

/// The file name in the acpmux home.
pub const FILE_NAME: &str = "listener.json";
const PROBE_PREFIX: &str = "ACPMUX-LINK/2 ";
const VERSION: u32 = 2;
const MAX_BYTES: u64 = 4096;
/// Random bytes in a key and in a challenge.
const SECRET_BYTES: usize = 32;
/// The answer line: the prefix, 64 hex digits and a newline.
const ANSWER_BYTES: usize = PROBE_PREFIX.len() + 2 * SECRET_BYTES + 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    version: u32,
    listen: SocketAddr,
    pid: u32,
    key: String,
}

fn random() -> Option<[u8; SECRET_BYTES]> {
    let mut bytes = [0u8; SECRET_BYTES];
    getrandom::fill(&mut bytes).ok()?;
    Some(bytes)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(text.get(at..at + 2)?, 16).ok())
        .collect()
}

/// This process's key, drawn once; none without randomness (then no record is written and no
/// probe is answered).
fn key() -> Option<&'static [u8; SECRET_BYTES]> {
    static KEY: OnceLock<Option<[u8; SECRET_BYTES]>> = OnceLock::new();
    KEY.get_or_init(random).as_ref()
}

fn tag(key: &[u8], challenge: &[u8]) -> ring::hmac::Tag {
    ring::hmac::sign(&ring::hmac::Key::new(ring::hmac::HMAC_SHA256, key), challenge)
}

/// The listener's answer to `read`, when `read` is exactly one probe head; none for anything
/// else (it goes on as a request).
pub fn probe_answer(read: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(read).ok()?;
    let challenge = text.strip_prefix(PROBE_PREFIX)?.strip_suffix("\r\n\r\n")?;
    let challenge = unhex(challenge).filter(|bytes| bytes.len() == SECRET_BYTES)?;
    Some(format!("{PROBE_PREFIX}{}\n", hex(tag(key()?, &challenge).as_ref())))
}

/// The address to dial for a listener bound at `listen`: a wildcard is reached on loopback.
fn dialable(mut listen: SocketAddr) -> SocketAddr {
    match listen.ip() {
        IpAddr::V4(ip) if ip.is_unspecified() => listen.set_ip(IpAddr::V4(Ipv4Addr::LOCALHOST)),
        IpAddr::V6(ip) if ip.is_unspecified() => listen.set_ip(IpAddr::V6(Ipv6Addr::LOCALHOST)),
        _ => {}
    }
    listen
}

/// This process's record in a home: removed when dropped (if it is still this process's).
#[must_use = "dropping it removes the record"]
#[derive(Debug)]
pub struct Written {
    home: PathBuf,
}

impl Drop for Written {
    fn drop(&mut self) {
        remove_if_owned(&self.home);
    }
}

/// Record `listen` (the bound address; a wildcard is recorded as loopback) as this process's
/// listener in `home`, unless the home is lost (`config::refuse_lost_home`).
pub fn write(home: &Path, listen: SocketAddr) -> io::Result<Written> {
    write_fenced(home, listen, |path| {
        crate::config::refuse_lost_home(path).map_err(io::Error::other)
    })
}

fn write_fenced(
    home: &Path,
    listen: SocketAddr,
    fence: impl Fn(&Path) -> io::Result<()>,
) -> io::Result<Written> {
    use std::io::Write as _;
    let path = home.join(FILE_NAME);
    fence(&path)?;
    let listen = dialable(listen);
    let pid = std::process::id();
    let key = key().ok_or_else(|| io::Error::other("no randomness for the listener key"))?;
    let record = Record { version: VERSION, listen, pid, key: hex(key) };
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
        std::fs::rename(&temp, &path)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    written.map(|()| Written { home: home.to_path_buf() })
}

/// Remove the record when it is this process's.
fn remove_if_owned(home: &Path) {
    let ours = key().map(|key| hex(key));
    if read(home).is_some_and(|record| {
        record.pid == std::process::id() && Some(&record.key) == ours.as_ref()
    }) {
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
    let key_ok = unhex(&record.key).is_some_and(|key| key.len() == SECRET_BYTES);
    (record.version == VERSION && key_ok).then_some(record)
}

/// Why [`connect_live`] sent nothing on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotLive {
    /// No record, or one that is not this user's or does not parse.
    NoRecord,
    /// The record's address is not on loopback, or its port is 0.
    NotLoopback,
    /// Nothing listens at the recorded address.
    Unreachable,
    /// The listener there did not answer the challenge under the record's key: it is not the
    /// daemon that wrote the record (that daemon ended, or another process holds the port).
    WrongListener,
}

/// The listener of the acpmux daemon that runs from `home` now, connected and proven by the
/// record's key: the stream is past the probe, and the caller's bytes go to the listener's
/// request reader. `bound` limits the connect and the probe together.
pub async fn connect_live(home: &Path, bound: Duration) -> Result<TcpStream, NotLive> {
    let record = read(home).ok_or(NotLive::NoRecord)?;
    if !record.listen.ip().is_loopback() || record.listen.port() == 0 {
        return Err(NotLive::NotLoopback);
    }
    let key = unhex(&record.key).ok_or(NotLive::NoRecord)?;
    let challenge = random().ok_or(NotLive::WrongListener)?;
    tokio::time::timeout(bound, async {
        let mut stream =
            TcpStream::connect(record.listen).await.map_err(|_| NotLive::Unreachable)?;
        let _ = stream.set_nodelay(true);
        let probe = format!("{PROBE_PREFIX}{}\r\n\r\n", hex(&challenge));
        stream.write_all(probe.as_bytes()).await.map_err(|_| NotLive::WrongListener)?;
        let mut line = Vec::with_capacity(ANSWER_BYTES);
        // Byte by byte: what follows the answer belongs to the caller's stream.
        while line.last() != Some(&b'\n') {
            if line.len() >= ANSWER_BYTES {
                return Err(NotLive::WrongListener);
            }
            let byte = stream.read_u8().await.map_err(|_| NotLive::WrongListener)?;
            line.push(byte);
        }
        let answer = std::str::from_utf8(&line)
            .ok()
            .and_then(|line| line.strip_prefix(PROBE_PREFIX)?.strip_suffix('\n'))
            .and_then(unhex)
            .ok_or(NotLive::WrongListener)?;
        let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, &key);
        ring::hmac::verify(&key, &challenge, &answer).map_err(|_| NotLive::WrongListener)?;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn the_record_is_this_users_and_dropping_its_guard_removes_it() {
        let home = tempfile::tempdir().unwrap();
        let written = write(home.path(), "127.0.0.1:52341".parse().unwrap()).unwrap();
        let record = read(home.path()).unwrap();
        assert_eq!(record.pid, std::process::id());
        assert_eq!(unhex(&record.key).unwrap().len(), SECRET_BYTES);
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(home.path().join(FILE_NAME)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        drop(written);
        assert!(!home.path().join(FILE_NAME).exists());
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn a_lost_home_refuses_the_write() {
        let home = tempfile::tempdir().unwrap();
        let refused = write_fenced(home.path(), "127.0.0.1:52341".parse().unwrap(), |_| {
            Err(io::Error::other("the acpmux home is gone"))
        });
        assert!(refused.is_err());
        assert!(!home.path().join(FILE_NAME).exists());
        assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 0, "nothing written");
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn a_startup_error_after_the_write_leaves_no_record() {
        fn start(home: &Path) -> io::Result<()> {
            let _record = write(home, "127.0.0.1:52341".parse().unwrap())?;
            assert!(home.join(FILE_NAME).exists());
            // A later startup step fails (`Mailbox::open`, the WireGuard transport): `?` returns.
            Err(io::Error::other("mailbox"))?;
            Ok(())
        }
        let home = tempfile::tempdir().unwrap();
        assert!(start(home.path()).is_err());
        assert!(!home.path().join(FILE_NAME).exists());
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn a_wildcard_bind_is_recorded_as_loopback() {
        for (bound, recorded) in [
            ("0.0.0.0:52341", "127.0.0.1:52341"),
            ("[::]:52341", "[::1]:52341"),
            ("127.0.0.1:52341", "127.0.0.1:52341"),
            ("[::1]:52341", "[::1]:52341"),
        ] {
            let home = tempfile::tempdir().unwrap();
            let _written = write(home.path(), bound.parse().unwrap()).unwrap();
            assert_eq!(read(home.path()).unwrap().listen, recorded.parse().unwrap(), "{bound}");
        }
    }

    /// A listener on `bound` that answers one probe with `answer` (what it computes or replays).
    async fn answering(
        listener: tokio::net::TcpListener,
        answer: impl FnOnce(&[u8]) -> String + Send + 'static,
    ) {
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut head = Vec::new();
            while !head.ends_with(b"\r\n\r\n") {
                head.push(stream.read_u8().await.unwrap());
            }
            stream.write_all(answer(&head).as_bytes()).await.unwrap();
            let _ = stream.read_u8().await;
        });
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[tokio::test]
    async fn a_wildcard_listener_is_reached_and_proven_through_its_record() {
        let listener = tokio::net::TcpListener::bind("0.0.0.0:0").await.unwrap();
        let bound = listener.local_addr().unwrap();
        answering(listener, |head| probe_answer(head).unwrap()).await;
        let home = tempfile::tempdir().unwrap();
        let _written = write(home.path(), bound).unwrap();
        assert!(connect_live(home.path(), Duration::from_secs(5)).await.is_ok());
    }

    /// The shutdown order: the record goes while the port is still held, so the link stops
    /// sending peers here before any other process could bind the port.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[tokio::test]
    async fn the_record_is_gone_before_the_port_closes() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let bound = listener.local_addr().unwrap();
        let home = tempfile::tempdir().unwrap();
        let written = write(home.path(), bound).unwrap();
        drop(written);
        assert!(!home.path().join(FILE_NAME).exists());
        // The port is still this daemon's and still accepts, yet the link no longer dials it.
        let raw = TcpStream::connect(bound).await.unwrap();
        let (_held, _) = listener.accept().await.unwrap();
        assert!(matches!(
            connect_live(home.path(), Duration::from_secs(5)).await,
            Err(NotLive::NoRecord)
        ));
        drop(raw);
        drop(listener);
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[tokio::test]
    async fn an_answer_seen_before_does_not_pass_a_new_challenge() {
        // A process that watched one probe and its answer, then binds the port itself.
        let first = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let bound = first.local_addr().unwrap();
        let (seen_tx, seen_rx) = tokio::sync::oneshot::channel();
        answering(first, move |head| {
            let answer = probe_answer(head).unwrap();
            let _ = seen_tx.send(answer.clone());
            answer
        })
        .await;
        let home = tempfile::tempdir().unwrap();
        let _written = write(home.path(), bound).unwrap();
        assert!(connect_live(home.path(), Duration::from_secs(5)).await.is_ok());
        let seen = seen_rx.await.unwrap();
        // The first listener closes once its connection ends; then the port is free to take.
        let mut replayer = None;
        for _ in 0..100 {
            if let Ok(listener) = tokio::net::TcpListener::bind(bound).await {
                replayer = Some(listener);
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let replayer = replayer.expect("the port frees");
        answering(replayer, move |_| seen).await;
        assert_eq!(
            connect_live(home.path(), Duration::from_secs(5)).await.err(),
            Some(NotLive::WrongListener)
        );
    }

    #[test]
    fn only_a_whole_probe_head_is_answered() {
        let challenge = hex(&[7u8; SECRET_BYTES]);
        let probe = format!("ACPMUX-LINK/2 {challenge}\r\n\r\n");
        assert!(probe_answer(probe.as_bytes()).is_some());
        assert!(probe_answer(format!("{probe}GET").as_bytes()).is_none());
        assert!(probe_answer(b"ACPMUX-LINK/2 00\r\n\r\n").is_none());
        assert!(probe_answer(b"GET / HTTP/1.1\r\n\r\n").is_none());
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn another_daemons_record_is_left_alone() {
        let home = tempfile::tempdir().unwrap();
        let other = format!(
            r#"{{"version":2,"listen":"127.0.0.1:1","pid":1,"key":"{}"}}"#,
            hex(&[1u8; SECRET_BYTES])
        );
        std::fs::write(home.path().join(FILE_NAME), other).unwrap();
        assert!(read(home.path()).is_some(), "a well-formed record");
        remove_if_owned(home.path());
        assert!(home.path().join(FILE_NAME).exists());
    }

    /// A daemon that crashed left its record; a live listener now at that address (here: one
    /// that answers with this process's key, as a newer daemon would) fails its challenge.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[tokio::test]
    async fn a_dead_daemons_record_fails_the_challenge() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let bound = listener.local_addr().unwrap();
        answering(listener, |head| probe_answer(head).unwrap()).await;
        let home = tempfile::tempdir().unwrap();
        let dead = format!(
            r#"{{"version":2,"listen":"{bound}","pid":1,"key":"{}"}}"#,
            hex(&[1u8; SECRET_BYTES])
        );
        std::fs::write(home.path().join(FILE_NAME), dead).unwrap();
        assert!(matches!(
            connect_live(home.path(), Duration::from_secs(5)).await,
            Err(NotLive::WrongListener)
        ));
    }
}
