//! `cmux link start-chat project-serve --mount ID [--socket PATH] [--once]`: answers the reads of
//! a projected folder's machine ([`super::projected`]) for as long as the chat runs.
//!
//! It loads the mount's record and this Mac's copy of its manifest, then loops on a connection of
//! its own: `projfs.next` (a long poll), an answer for each want, `projfs.answer`. When the link
//! or the machine goes away it dials again with a growing wait (at most [`MAX_PAUSE`]) and never
//! exits for that; SIGTERM and SIGINT end it (their default action: it holds nothing to undo). A
//! missing record exits at once with `record_missing`. `--once` answers one batch and exits.
//!
//! The machine is the peer, so answering a want is the trust boundary: it gets only bytes of
//! files the manifest lists. For each want, in this order ([`Served::answer`]):
//!
//! - the path must be a plain relative path (absolute, `..`, `.`, an empty part or NUL is
//!   `failed`, and the disk is not touched), naming a file entry of the manifest: not listed (or
//!   gone) is `gone`, a withheld file `withheld`, a folder or symlink `failed`;
//! - the file is opened one name at a time below the folder, every folder on the way with
//!   `O_DIRECTORY | O_NOFOLLOW` and the file with `O_NOFOLLOW` ([`sync_cli::open_beneath`]), so no
//!   symlink is crossed: a symlink or anything else at the file's path or on its way is `gone`,
//!   and never read through;
//! - the OPENED file's size, mtime and ctime must be the want's version, else `changed` with its
//!   stat now; the manifest copy takes the change (in memory and on disk), so a want of the new
//!   version is served. A file not there any more is `gone`, also kept;
//! - `len` is at most one chunk; the bytes are `offset..offset+len`, cut at the file's end, read
//!   from that same open file, and checked unchanged after the read. One answer carries at most
//!   the rendezvous's batch bytes.
//!
//! Git's files the copy rewrites are served as rewritten, from the mount's `rewritten.json`.
//! Nothing it prints or keeps names a file's contents.

use std::collections::BTreeMap;
use std::io::{BufRead as _, BufReader, Read, Write as _};
use std::os::unix::fs::FileExt as _;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::time::Duration;

use base64::Engine as _;
use cmux_projfs::{Delta, Kind, Manifest, Stat, Version};
use serde_json::{Value, json};

use super::super::sync_cli::{self, Opened};
use super::Flags;
use super::projected::{MANIFEST, RECORD, REWRITTEN, Record, refused, write_private};

/// How long one `projfs.next` asks the daemon to wait for wants.
const POLL_WAIT_MS: u64 = 20_000;
/// The first wait before dialing again after the link went away.
const FIRST_PAUSE: Duration = Duration::from_millis(100);
/// The longest wait between two dials.
pub(super) const MAX_PAUSE: Duration = Duration::from_secs(10);
/// How long an answer may take past the poll's own wait.
const ANSWER_SLACK: Duration = Duration::from_secs(30);
/// The largest answer line read from the daemon (a batch of wants).
const MAX_ANSWER_BYTES: u64 = 4 << 20;
/// The most bytes one answer carries: the rendezvous's bound for a batch.
const MAX_ANSWER_DATA: u64 = cmux_tui_core::projfs_rendezvous::MAX_BATCH_BYTES;

/// `project-serve`; `None` on bad usage.
pub(super) fn cli(flags: &Flags, base: &Path) -> Option<Value> {
    let mount = flags.one("--mount").filter(|id| plain_id(id))?;
    let once = match flags.all("--once").as_slice() {
        [] => false,
        [_] => true,
        _ => return None,
    };
    let dir = base.join(mount);
    let (record, mut served) = match Served::load(&dir) {
        Ok(loaded) => loaded,
        Err(answer) => return Some(answer),
    };
    let socket = flags.one("--socket").map_or_else(|| PathBuf::from(&record.socket), PathBuf::from);
    // Kept for the life of the loop: nothing stops it but a signal.
    let (_keep, stop) = mpsc::channel::<()>();
    let options = Options { wait_ms: POLL_WAIT_MS, once, max_pause: MAX_PAUSE };
    Some(serve(&mut served, &socket, &options, &stop))
}

/// The plain form of a mount id (as the daemon checks it).
pub(super) fn plain_id(id: &str) -> bool {
    (1..=64).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// How the loop polls and waits.
#[derive(Clone, Copy, Debug)]
pub(super) struct Options {
    pub wait_ms: u64,
    pub once: bool,
    pub max_pause: Duration,
}

/// One mount being served: the folder on this Mac, its manifest copy and rewritten files.
pub(super) struct Served {
    mount: String,
    root: PathBuf,
    dir: PathBuf,
    manifest: Manifest,
    rewritten: BTreeMap<String, Vec<u8>>,
}

/// A want, as checked.
struct Asked<'a> {
    path: &'a str,
    version: Version,
    offset: u64,
    len: u64,
}

fn status(name: &str) -> Value {
    json!({ "status": name })
}

fn failed(reason: &str) -> Value {
    json!({ "status": "failed", "reason": reason })
}

impl Served {
    /// The mount kept in `dir`, or the refusal to print.
    pub(super) fn load(dir: &Path) -> Result<(Record, Served), Value> {
        let missing = |what: &str| {
            let message = format!("no projected folder is kept at {} ({what})", dir.display());
            refused("record_missing", message)
        };
        let record = std::fs::read(dir.join(RECORD)).map_err(|_| missing("no record"))?;
        let record: Record =
            serde_json::from_slice(&record).map_err(|_| missing("its record is unreadable"))?;
        let bytes = std::fs::read(dir.join(MANIFEST)).map_err(|_| missing("no manifest"))?;
        let manifest =
            Manifest::decode(&bytes).map_err(|_| missing("its manifest is unreadable"))?;
        let rewritten: BTreeMap<String, String> = std::fs::read(dir.join(REWRITTEN))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        let decode = |text: &String| base64::engine::general_purpose::STANDARD.decode(text).ok();
        let rewritten = rewritten
            .iter()
            .filter_map(|(path, text)| Some((path.clone(), decode(text)?)))
            .collect();
        let served = Served {
            mount: record.mount.clone(),
            root: PathBuf::from(&record.local_root),
            dir: dir.to_path_buf(),
            manifest,
            rewritten,
        };
        Ok((record, served))
    }

    /// The manifest copy as it is now.
    #[cfg(test)]
    pub(super) fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    /// The results of a batch's wants, in order, carrying at most [`MAX_ANSWER_DATA`] bytes.
    pub(super) fn answer_batch(&mut self, wants: &[Value]) -> Vec<Value> {
        let mut carried: u64 = 0;
        let mut results = Vec::with_capacity(wants.len());
        for want in wants {
            let len = want.get("len").and_then(Value::as_u64).unwrap_or_default();
            if carried.saturating_add(len) > MAX_ANSWER_DATA {
                results.push(failed("the batch asks for more bytes than one answer carries"));
                continue;
            }
            let result = self.answer(want);
            if result.get("status").and_then(Value::as_str) == Some("bytes") {
                carried = carried.saturating_add(len);
            }
            results.push(result);
        }
        results
    }

    /// The result of one want, by the rules in the module doc.
    pub(super) fn answer(&mut self, want: &Value) -> Value {
        let Some(asked) = checked(want) else {
            return failed("not a want this Mac serves");
        };
        let Some(entry) = self.manifest.resolve(asked.path).and_then(|i| self.manifest.entry(i))
        else {
            return status("gone");
        };
        if entry.stat.kind != Kind::File {
            return failed("not a file");
        }
        if entry.stat.withheld {
            return status("withheld");
        }
        let listed = entry.stat.version();
        if let Some(bytes) = self.rewritten.get(asked.path) {
            if asked.version != listed {
                return changed(&entry.stat);
            }
            return range(bytes, asked.offset, asked.len);
        }
        self.read_disk(&asked)
    }

    /// A listed file's range, from the file as it is on this Mac now.
    fn read_disk(&mut self, asked: &Asked<'_>) -> Value {
        let file = match sync_cli::open_beneath(&self.root, asked.path) {
            Ok(Opened::File(file)) => file,
            Ok(Opened::Gone) => {
                self.note(asked.path, Delta::Gone);
                return status("gone");
            }
            Err(_) => return failed("this Mac could not open it"),
        };
        let Ok(before) = file.metadata().map(|meta| sync_cli::times_of(&meta)) else {
            return failed("this Mac could not look at it");
        };
        let now = Stat::file(before.mode, before.size, before.mtime_ns, before.ctime_ns);
        if now.version() != asked.version {
            self.note(asked.path, Delta::Stat(now.clone()));
            return changed(&now);
        }
        let end = asked.offset.saturating_add(asked.len).min(before.size);
        let wanted = end.saturating_sub(asked.offset);
        let mut bytes = vec![0u8; usize::try_from(wanted).unwrap_or_default()];
        let read = file.read_exact_at(&mut bytes, asked.offset);
        let after = file.metadata().map(|meta| sync_cli::times_of(&meta));
        match after {
            Ok(after) if after != before => {
                let now = Stat::file(after.mode, after.size, after.mtime_ns, after.ctime_ns);
                self.note(asked.path, Delta::Stat(now.clone()));
                changed(&now)
            }
            Ok(_) if read.is_ok() => json!({
                "status": "bytes",
                "data_b64": base64::engine::general_purpose::STANDARD.encode(&bytes),
            }),
            _ => failed("this Mac could not read it"),
        }
    }

    /// Takes a change the disk showed into the manifest copy, in memory and on disk.
    fn note(&mut self, path: &str, delta: Delta) {
        if let Ok(Some(_)) = self.manifest.apply_delta(path, delta)
            && let Ok(bytes) = self.manifest.encode()
        {
            let _ = write_private(&self.dir.join(MANIFEST), &bytes);
        }
    }
}

/// A want's fields, when its path is a plain relative path and its range is in bounds.
fn checked(want: &Value) -> Option<Asked<'_>> {
    let path = want.get("path").and_then(Value::as_str)?;
    let plain = !path.is_empty()
        && !path.starts_with('/')
        && !path.contains('\0')
        && path.split('/').all(|part| !matches!(part, "" | "." | ".."));
    if !plain {
        return None;
    }
    let unsigned = |key: &str| want.get(key).and_then(Value::as_u64);
    let signed = |key: &str| want.get(key).and_then(Value::as_i64);
    let version = Version {
        size: unsigned("size")?,
        mtime_ns: signed("mtime_ns")?,
        ctime_ns: signed("ctime_ns")?,
    };
    let (offset, len) = (unsigned("offset")?, unsigned("len")?);
    if len == 0 || len > cmux_projfs::CHUNK {
        return None;
    }
    Some(Asked { path, version, offset, len })
}

fn changed(stat: &Stat) -> Value {
    json!({
        "status": "changed",
        "size": stat.size,
        "mtime_ns": stat.mtime_ns,
        "ctime_ns": stat.ctime_ns,
        "mode": stat.mode,
    })
}

/// `bytes[offset..offset+len]`, cut at the end.
fn range(bytes: &[u8], offset: u64, len: u64) -> Value {
    let start = usize::try_from(offset).unwrap_or(usize::MAX);
    let len = usize::try_from(len).unwrap_or(usize::MAX);
    let slice: Vec<u8> = bytes.iter().skip(start).take(len).copied().collect();
    json!({ "status": "bytes", "data_b64": base64::engine::general_purpose::STANDARD.encode(slice) })
}

/// Why a request got no answer.
enum CallError {
    /// The connection broke or could not be made: dial again.
    Dropped,
    /// The daemon refused it (an expired batch, or a daemon without projected folders yet).
    Refused,
}

/// One connection to the machine's daemon through the link.
struct Link {
    reader: BufReader<UnixStream>,
    next_id: u64,
}

impl Link {
    fn dial(socket: &Path, wait_ms: u64) -> Option<Link> {
        let stream = UnixStream::connect(socket).ok()?;
        let read = Duration::from_millis(wait_ms).saturating_add(ANSWER_SLACK);
        stream.set_read_timeout(Some(read)).ok()?;
        stream.set_write_timeout(Some(ANSWER_SLACK)).ok()?;
        Some(Link { reader: BufReader::new(stream), next_id: 1 })
    }

    fn call(&mut self, cmd: &str, mut params: Value) -> Result<Value, CallError> {
        let id = self.next_id;
        self.next_id = self.next_id.saturating_add(1);
        if let Some(fields) = params.as_object_mut() {
            fields.insert("id".into(), json!(id));
            fields.insert("cmd".into(), json!(cmd));
        }
        let mut line = params.to_string();
        line.push('\n');
        self.reader.get_mut().write_all(line.as_bytes()).map_err(|_| CallError::Dropped)?;
        for _ in 0..8 {
            let mut answer = Vec::new();
            let limited = &mut Read::take(&mut self.reader, MAX_ANSWER_BYTES + 1);
            let read = limited.read_until(b'\n', &mut answer).map_err(|_| CallError::Dropped)?;
            if read == 0 || answer.last() != Some(&b'\n') {
                return Err(CallError::Dropped);
            }
            let answer: Value = serde_json::from_slice(&answer).map_err(|_| CallError::Dropped)?;
            if answer.get("id") != Some(&json!(id)) {
                continue;
            }
            if answer.get("ok") == Some(&json!(true)) {
                return Ok(answer.get("data").cloned().unwrap_or(Value::Null));
            }
            return Err(CallError::Refused);
        }
        Err(CallError::Dropped)
    }
}

/// Whether `stop` was signalled (only a sent stop counts: a closed channel does not).
fn stopped(stop: &Receiver<()>) -> bool {
    matches!(stop.try_recv(), Ok(()))
}

/// Waits `pause` unless `stop` is signalled first; whether it was.
fn wait(stop: &Receiver<()>, pause: Duration) -> bool {
    match stop.recv_timeout(pause) {
        Ok(()) => true,
        Err(RecvTimeoutError::Timeout) => false,
        // No one can stop it: the full pause, on a channel of its own.
        Err(RecvTimeoutError::Disconnected) => {
            let (_keep, alone) = mpsc::channel::<()>();
            let _ = alone.recv_timeout(pause);
            false
        }
    }
}

/// Serves `served` through the daemon at `socket` until `stop` is signalled (or one batch was
/// answered, with `once`); its answer line.
pub(super) fn serve(
    served: &mut Served,
    socket: &Path,
    options: &Options,
    stop: &Receiver<()>,
) -> Value {
    let mut pause = FIRST_PAUSE;
    let mut link: Option<Link> = None;
    let mut batches: u64 = 0;
    loop {
        if stopped(stop) {
            return json!({ "ok": true, "mount": served.mount, "batches": batches });
        }
        let Some(conn) = link.as_mut() else {
            link = Link::dial(socket, options.wait_ms);
            if link.is_none() {
                if wait(stop, pause) {
                    return json!({ "ok": true, "mount": served.mount, "batches": batches });
                }
                pause = pause.saturating_mul(2).min(options.max_pause);
            }
            continue;
        };
        let poll = json!({ "mount": served.mount, "wait_ms": options.wait_ms });
        match conn.call("projfs.next", poll) {
            Ok(data) => {
                pause = FIRST_PAUSE;
                let Some(batch) = data.get("batch").filter(|batch| batch.is_object()) else {
                    continue;
                };
                let wants =
                    batch.get("wants").and_then(Value::as_array).cloned().unwrap_or_default();
                let results = served.answer_batch(&wants);
                let id = batch.get("id").cloned().unwrap_or(Value::Null);
                let answer = json!({ "mount": served.mount, "batch": id, "results": results });
                // An expired batch (`projfs.unknown_batch`) is dropped; the machine asks again.
                if let Err(CallError::Dropped) = conn.call("projfs.answer", answer) {
                    link = None;
                }
                batches = batches.saturating_add(1);
                if options.once {
                    return json!({ "ok": true, "mount": served.mount, "batches": batches });
                }
            }
            Err(error) => {
                if matches!(error, CallError::Dropped) {
                    link = None;
                }
                // Away, or a daemon that does not serve projected folders yet (its update is
                // on its way): wait, then ask again.
                if wait(stop, pause) {
                    return json!({ "ok": true, "mount": served.mount, "batches": batches });
                }
                pause = pause.saturating_mul(2).min(options.max_pause);
            }
        }
    }
}

#[cfg(test)]
#[path = "projected_serve_tests.rs"]
mod tests;
