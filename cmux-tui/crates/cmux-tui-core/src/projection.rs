//! `projection-v1`: a folder of the person's Mac projected onto this Cloud machine (RFD 0007,
//! `cmux-projection`). The Mac sends a stat-only manifest; this daemon mounts it (FUSE, Linux)
//! at the chat's folder, answers every `stat` and listing from it, fetches a file's bytes from the
//! Mac on first read, and keeps everything written there on this machine's disk.
//!
//! Wire: a link dial whose first line is
//! `{"id", "cmd": "projection.serve", "name", "at", "manifest_bytes"}` is followed by that many
//! bytes of the encoded manifest (none to attach again to the projection `name` already mounted).
//! The daemon mounts it at `at` (a folder below the machine's file roots, empty or missing),
//! answers one line, `{"id", "ok": true, "data": {"at", "entries", "files", "bytes", "mount_ms"}}`
//! or `{"id", "ok": false, "error", "error_code"}`, and from then on the dial carries the
//! projection's asks and the Mac's answers (`cmux_projection::wire`) until the Mac closes it.
//! The mount stays when the dial ends; reads wait a few seconds for the Mac's next dial, then fail
//! with "Host is down". The agent sessions working in the folder are told once per away episode
//! (`cmux_projection::away`), in a notice naming the folder and the reads that failed
//! ([`away_notice`]); the Mac's next dial ends the episode.
//!
//! Bring Back (`cmux_projection::way_back`) reads what the agent changed with three more dials,
//! each one request and its answer, by projection `name`, mounted or not (the state folder
//! outlives the mount and a daemon restart):
//! - `{"id", "cmd": "projection.layer", "name", "prune"?}`: answered `{"id", "ok": true, "data": {"bytes",
//!   "upper", "whiteouts", "mark"}}`, then that many bytes of the encoded
//!   `cmux_projection::layer::Layer`. `mark` is the upper layer as it was when it was read
//!   (`cmux_projection::state::mark`);
//! - `{"id", "cmd": "projection.files", "name", "paths_bytes"}`, then that many bytes of upper
//!   paths, one per line: answered `{"id", "ok": true, "data": {}}`, then each file as
//!   `cmux_projection::layer::send_files` writes it;
//! - `{"id", "cmd": "projection.brought_back", "name", "mark"}`, once the Mac applied it all
//!   (RFD 0007: "brought back at the mark it read (`projection.brought_back`), and it is
//!   freed"): the record says so, the projection is unmounted and its state (upper layer,
//!   whiteouts, cache) deleted; `{"id", "ok": true, "data": {"freed_bytes", "dropped": true}}`.
//!   An upper layer written since `mark` stays whole: `projection.edited_since`;
//! - `{"id", "cmd": "projection.drop", "name"}`: the same with no mark (a Mac from before
//!   `projection.brought_back`); `{"id", "ok": true, "data": {"dropped"}}`.
//!
//! - `{"id", "cmd": "projection.unsynced", "name", "prune"?}`: one metadata walk of the upper
//!   layer, no bytes, for a "N files to bring back" line: `{"files", "bytes", "deleted"}`, what
//!   Bring Back would list (files and links) and its whiteouts. With `prune`, as
//!   `projection.layer` prunes, plus `"kept_on_machine": {"folders", "files", "bytes", "paths"}`
//!   (the first 256 folders): a caller whose manifest holds one of `paths` asks again without
//!   `prune`, as Bring Back does, so a committed `node_modules`'s edits are counted.
//!
//! Pinned folders (`cmux_projection::overlay::pin`, "available offline"), by projection `name`,
//! mounted here, each one request and its answer:
//! - `{"id", "cmd": "projection.pin", "name", "path"}`: `path` (relative to the projected folder,
//!   `""` for all of it) is recorded and every file under it fetched onto this machine's disk
//!   before the answer, `{"id", "ok": true, "data": {"path", "files", "bytes", "fetched_bytes",
//!   "failed", "first_error", "away", "pinned_bytes", "pins"}}`. With the Mac away the pin still
//!   holds (`"away": true`) and the next mount finishes it. A pin the disk cannot hold is refused
//!   first, `projection.no_space`; a path the folder lacks, `projection.not_found`;
//! - `{"id", "cmd": "projection.unpin", "name", "path"}`: its bytes go back to the cache, which
//!   may evict them: `{"path", "unpinned": true, "pinned_bytes", "pins"}`;
//! - `{"id", "cmd": "projection.pins", "name"}`: `{"pinned_bytes", "pins"}`.
//! - `{"id", "cmd": "projection.warm", "name", "paths"}`: the files at or under `paths` (in order,
//!   at most [`WARM_MAX_FILES`] files and [`WARM_MAX_BYTES`] bytes) fetched into the cache like a
//!   read's, before the answer: nothing pinned, recorded or shown in `pins`. The Mac sends its
//!   predicted hot set (instruction files, its changed and newest files) once the folder is
//!   mounted, so the agent's first reads find their bytes here. `{"files", "bytes",
//!   "fetched_bytes", "failed", "first_error", "away"}`. A daemon older than this answers it
//!   unknown, and the Mac lets it go.
//!
//! `pins` is one `{"path", "files", "bytes", "local_bytes", "present", "complete"}` per pin, and
//! `pinned_bytes` the bytes kept on disk for them; a mount's answer carries both too.
//!
//! When a chat is archived or deleted, `{"id", "cmd": "projection.release", "name", "why":
//! "archived" | "deleted"}` ends its projection, deletes its state and its empty mount point:
//! `{"freed_bytes", "dropped": true}`. The reaper ([`start_reaper`]) frees the rest on its own,
//! at the daemon's start and every [`REAP_EVERY`]: it reads this machine's chats from acpmux and
//! runs one bounded `cmux_projection::reap::pass` over the projections (archived chats, Bring
//! Back's leftovers, orphans past their grace), and logs each with the bytes it freed.
//!
//! `projection-extend-v1` (the Mac sends a small head manifest first and the whole folder's after
//! it, so the chat starts before the whole folder is listed):
//! - a `projection.serve` line with `"head": true` that mounts a new manifest also takes the
//!   folder's sync barrier (`cmux_git::sync_barrier`) and marks its head in place, so an agent
//!   that may start at the head does, and its tools wait for the rest;
//! - a `projection.serve` line for the mounted `name` with `"extend": true` and the full
//!   manifest's bytes swaps the mount's manifest in place (no remount: the kernel's numbers, the
//!   open files, the upper layer and the cache stay) and marks the barrier ready. The full
//!   manifest must hold every mounted path as the same kind of entry, else the dial is refused
//!   with `projection.extend_not_superset` and the mount stays as it was; a second extend with
//!   another manifest is `projection.extend_done`. The answer is `{"at", "extended": true,
//!   "entries", "files", "bytes", "added", "extend_ms"}`; the dial then carries the asks as any
//!   other, now by the full manifest's entry indices, while a stream still open from before the
//!   extend goes on speaking the head's. A dial with neither flag acts as before.
//!
//! Served where `fs-v1` is (a Cloud host), on Linux; anywhere else a dial is answered
//! `projection.unavailable`.
//!
//! A dial whose line says `"lines": true` sends every byte after that line, and gets every byte
//! after its answer, as text lines instead ([`LineReader`], [`LineWriter`]): the Cloud carrier
//! carries a dial as a `mux-control` stream, which moves whole lines only.
//!
//! Wire 2 (RFD 0065, "Projection answers compressed and binary"; negotiated on the dial, no
//! capability): a `projection.serve` line with `"wire": 2` says the Mac reads binary lines and
//! packed answers. This daemon then answers with `"wire": 2` in its data, writes binary lines
//! ([`LineWriter::binary`]: the raw bytes with only a newline and the escape byte escaped, not
//! base64's +33%), and takes the Mac's packed answers (`cmux_projection::wire::OK_ZSTD`, zstd
//! level 3 per file where it shrinks). The Mac packs and writes binary only once the answer says
//! `"wire": 2`, so with either side older than this the dial keeps base64 lines and plain
//! answers. A [`LineReader`] takes either kind of line.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

#[cfg(target_os = "linux")]
use cmux_git::sync_barrier::Sync as BarrierSync;

use serde::Deserialize;
use serde_json::{Value, json};

/// The capability that carries `projection.serve`.
pub const PROJECTION_CAPABILITY: &str = "projection-v1";
/// The capability that carries `"head"` and `"extend"` on `projection.serve`.
pub const PROJECTION_EXTEND_CAPABILITY: &str = "projection-extend-v1";
/// The wire version a `projection.serve` line and its answer name for binary lines and packed
/// answers (module docs).
pub const WIRE: u32 = 2;
/// The one op: a dial that serves a projection.
pub const SERVE: &str = "projection.serve";
/// Bring Back's dials (module docs).
pub const LAYER: &str = "projection.layer";
pub const FILES: &str = "projection.files";
pub const DROP: &str = "projection.drop";
/// Bring Back carried the upper layer, as it was at a mark, to the Mac: free it.
pub const BROUGHT_BACK: &str = "projection.brought_back";
/// The chat is archived or deleted: free its projection.
pub const RELEASE: &str = "projection.release";
/// Pinned folders' dials (module docs).
pub const PIN: &str = "projection.pin";
pub const UNPIN: &str = "projection.unpin";
pub const PINS: &str = "projection.pins";
/// The Mac's predicted hot set, fetched into the cache (module docs).
pub const WARM: &str = "projection.warm";
/// The most files one [`WARM`] fetches.
pub const WARM_MAX_FILES: usize = 256;
/// The most bytes one [`WARM`] fetches.
pub const WARM_MAX_BYTES: u64 = 32 * 1024 * 1024;
/// What the agent changed that Bring Back would carry, and what stays on the machine, as counts
/// (module docs).
pub const UNSYNCED: &str = "projection.unsynced";
/// How long after the daemon starts the first reaper pass runs (acpmux starts beside it).
const REAP_FIRST_AFTER: std::time::Duration = std::time::Duration::from_secs(60);
/// How often the reaper runs.
pub const REAP_EVERY: std::time::Duration = std::time::Duration::from_secs(30 * 60);
/// The most one reaper pass waits for the chat list.
const CHATS_WITHIN: std::time::Duration = std::time::Duration::from_secs(20);
/// The most bytes of paths a `projection.files` dial may send.
const MAX_PATHS_BYTES: u64 = 256 * 1024 * 1024;
/// The largest encoded manifest a dial may send (a 1.1 M-entry folder encodes to 14 MB).
const MAX_MANIFEST_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Deserialize)]
struct ServeLine {
    cmd: String,
    name: String,
    at: String,
    #[serde(default)]
    manifest_bytes: u64,
    /// The bytes after this line, both ways, travel as [`LineWriter`] lines.
    #[serde(default)]
    lines: bool,
    /// [`WIRE`] or more: the Mac reads binary lines and packed answers (module docs).
    #[serde(default)]
    wire: u32,
    /// With no manifest bytes and no mount of this name: the stored revision to mount instead
    /// (RFD 0007, open question 3). The Mac sends this on a resume, so the listing comes from the
    /// store and not over its uplink.
    #[serde(default)]
    revision: Option<RevisionRef>,
    /// `projection-extend-v1`: the manifest is a head, and the folder's sync barrier is held at
    /// its head until the extend.
    #[serde(default)]
    head: bool,
    /// `projection-extend-v1`: the manifest is the whole folder's, for the mount of `name`.
    #[serde(default)]
    extend: bool,
    /// The folder on the Mac this projects, as that Mac names it. The mount table carries it
    /// ([`fsname_for`]), so the agent's `this_folder` tool can say which Mac folder it mirrors.
    #[serde(default)]
    from: Option<String>,
}

/// A revision in the person's store, and the read grant to fetch it with.
#[derive(Deserialize)]
struct RevisionRef {
    root: String,
    origin: String,
    grant: String,
}

/// The manifest of `revision`, read from the store.
fn fetch_revision(revision: &RevisionRef) -> Result<cmux_projection::manifest::Manifest, Refusal> {
    let unavailable = |why: String| ("projection.revision_unavailable", why);
    let local = revision.origin.starts_with("http://127.0.0.1")
        || revision.origin.starts_with("http://localhost");
    if !revision.origin.starts_with("https://") && !local {
        return Err(unavailable("the store's origin is not https".into()));
    }
    let origin = revision.origin.clone();
    let grant = revision.grant.clone();
    let root = revision.root.clone();
    // Its own thread: the blocking HTTP client cannot run inside an async runtime.
    std::thread::scope(|scope| {
        scope
            .spawn(|| {
                let http = cmux_projection::peers::Http::new()?;
                let store = cmux_projection::revision::Store { origin, grant, http: &http };
                cmux_projection::revision::assemble(&root, &store)
            })
            .join()
    })
    .map_err(|_| unavailable("reading the revision panicked".into()))?
    .map_err(|error| unavailable(format!("{error:#}")))
}

/// The first byte of every [`LineWriter`] line: never a JSON value's first byte, so a carrier
/// that sorts lines by their JSON never reads one as a request or a reply.
const LINE_MARK: u8 = b'~';
/// The first byte of every binary [`LineWriter`] line: never a JSON value's first byte either.
const BINARY_MARK: u8 = b'!';
/// In a binary line, the byte that escapes the next: `\\` is itself and `\n` a newline.
const ESCAPE: u8 = b'\\';
/// The most bytes one [`LineWriter`] line carries (1.4 MB of text, or at most 2 MiB of escaped
/// binary, far below the carrier's 16 MiB line limit).
const LINE_BYTES: usize = 1024 * 1024;

/// Bytes written as lines: each `write` of up to [`LINE_BYTES`] becomes one line, `~` and its
/// base64, or with [`LineWriter::binary`] `!` and the bytes with each newline and [`ESCAPE`]
/// escaped (0.8% more on compressed bytes, against base64's 33%).
pub struct LineWriter<W: Write> {
    inner: W,
    binary: bool,
}

impl<W: Write> LineWriter<W> {
    pub fn new(inner: W) -> Self {
        Self { inner, binary: false }
    }

    /// A writer of binary lines, for a reader that said it takes them (`"wire": 2`).
    pub fn binary(inner: W) -> Self {
        Self { inner, binary: true }
    }
}

impl<W: Write> Write for LineWriter<W> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        use base64::Engine as _;
        let chunk = bytes.get(..bytes.len().min(LINE_BYTES)).unwrap_or_default();
        if chunk.is_empty() {
            return Ok(0);
        }
        let mut line;
        if self.binary {
            line = Vec::with_capacity(chunk.len() + chunk.len() / 64 + 2);
            line.push(BINARY_MARK);
            for &byte in chunk {
                match byte {
                    b'\n' => line.extend_from_slice(&[ESCAPE, b'n']),
                    ESCAPE => line.extend_from_slice(&[ESCAPE, ESCAPE]),
                    byte => line.push(byte),
                }
            }
        } else {
            line = Vec::with_capacity(chunk.len() / 3 * 4 + 6);
            line.push(LINE_MARK);
            line.extend_from_slice(
                base64::engine::general_purpose::STANDARD.encode(chunk).as_bytes(),
            );
        }
        line.push(b'\n');
        self.inner.write_all(&line)?;
        Ok(chunk.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

/// The bytes of [`LineWriter`] lines read from `inner`.
pub struct LineReader<R: std::io::BufRead> {
    inner: R,
    decoded: Vec<u8>,
    at: usize,
}

impl<R: std::io::BufRead> LineReader<R> {
    pub fn new(inner: R) -> Self {
        Self { inner, decoded: Vec::new(), at: 0 }
    }
}

impl<R: std::io::BufRead> Read for LineReader<R> {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        use base64::Engine as _;
        while self.at >= self.decoded.len() {
            let mut line = Vec::new();
            if self.inner.read_until(b'\n', &mut line)? == 0 {
                return Ok(0);
            }
            if line.last() == Some(&b'\n') {
                line.pop();
            }
            self.decoded = match line.split_first() {
                Some((&LINE_MARK, text)) => base64::engine::general_purpose::STANDARD
                    .decode(text)
                    .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))?,
                Some((&BINARY_MARK, escaped)) => unescape(escaped)?,
                _ => {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "not a projection line",
                    ));
                }
            };
            self.at = 0;
        }
        let rest = self.decoded.get(self.at..).unwrap_or_default();
        let count = rest.len().min(out.len());
        out.get_mut(..count)
            .unwrap_or_default()
            .copy_from_slice(rest.get(..count).unwrap_or_default());
        self.at += count;
        Ok(count)
    }
}

/// The bytes of a binary line's `escaped` text (after its mark, before its newline).
fn unescape(escaped: &[u8]) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::with_capacity(escaped.len());
    let mut rest = escaped.iter();
    while let Some(&byte) = rest.next() {
        bytes.push(if byte == ESCAPE {
            match rest.next() {
                Some(b'n') => b'\n',
                Some(&ESCAPE) => ESCAPE,
                _ => {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "a bad escape in a projection line",
                    ));
                }
            }
        } else {
            byte
        });
    }
    Ok(bytes)
}

/// Whether the dial line `first` asks for [`LineWriter`] lines.
fn wants_lines(first: &str) -> bool {
    serde_json::from_str::<ServeLine>(first).is_ok_and(|line| line.lines)
}

/// Whether the dial line `first` is a `projection.serve` whose Mac reads binary lines and packed
/// answers ([`WIRE`]).
fn wants_wire(first: &str) -> bool {
    serde_json::from_str::<ServeLine>(first)
        .is_ok_and(|line| line.cmd == SERVE && line.wire >= WIRE)
}

/// `projection.serve` (or one of Bring Back's dials) when `line` asks for it, exactly.
#[must_use]
pub fn frame_command(line: &str) -> Option<&'static str> {
    if !line.contains("projection.") {
        return None;
    }
    let value: Value = serde_json::from_str(line).ok()?;
    let object = value.as_object()?;
    if object.contains_key("protocol") {
        return None;
    }
    let cmd = object.get("cmd")?.as_str()?;
    [SERVE, LAYER, FILES, DROP, BROUGHT_BACK, RELEASE, PIN, UNPIN, PINS, WARM, UNSYNCED]
        .into_iter()
        .find(|known| *known == cmd)
}

/// The capabilities to advertise: [`PROJECTION_CAPABILITY`] where a projection can mount (Linux,
/// with this daemon's file roots installed).
#[must_use]
pub fn advertised() -> Vec<&'static str> {
    if cfg!(target_os = "linux") && crate::fs_ops::installed().is_some() {
        vec![PROJECTION_CAPABILITY, PROJECTION_EXTEND_CAPABILITY]
    } else {
        Vec::new()
    }
}

/// A projection this daemon has mounted.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
struct Projected {
    link: Arc<cmux_projection::link::Link>,
    /// What the manifest it mounted hashed to (a dial with another manifest remounts); after an
    /// extend, the full manifest's.
    digest: AtomicU64,
    at: PathBuf,
    /// What the mount serves: its pins are read and changed here.
    #[cfg(target_os = "linux")]
    overlay: Arc<cmux_projection::overlay::Overlay>,
    /// The full manifest's mapping once the mount was extended (the streams then speak its indices).
    #[cfg(target_os = "linux")]
    ext: Mutex<Option<Arc<cmux_projection::lower::Ext>>>,
    /// The folder's sync barrier, held at its head from a `"head": true` dial until the extend.
    #[cfg(target_os = "linux")]
    barrier: Mutex<Option<BarrierSync>>,
    #[cfg(target_os = "linux")]
    mounted: Mutex<Option<cmux_projection::mount::Mounted>>,
    /// Its away episodes: the agent is told once of each ([`away_notice`]).
    #[cfg(target_os = "linux")]
    away: Arc<cmux_projection::away::Away>,
}

impl Projected {
    /// The mapping a stream of this mount speaks through: the full manifest's once extended.
    fn ext(&self) -> Option<Arc<cmux_projection::lower::Ext>> {
        #[cfg(target_os = "linux")]
        {
            self.ext.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }
        #[cfg(not(target_os = "linux"))]
        {
            None
        }
    }
}

fn projections() -> &'static Mutex<HashMap<String, Arc<Projected>>> {
    static PROJECTIONS: OnceLock<Mutex<HashMap<String, Arc<Projected>>>> = OnceLock::new();
    PROJECTIONS.get_or_init(Mutex::default)
}

/// An error answer's code and message.
type Refusal = (&'static str, String);

/// Serves one projection dial: `first` is its first line, `leftover` what was read after it.
/// `roots` are the folders a projection may mount below (the daemon's file roots). Returns when
/// the Mac closes the dial.
pub fn serve(stream: &UnixStream, first: &str, leftover: Vec<u8>, roots: &[PathBuf]) {
    let (Ok(reader), Ok(writer)) = (stream.try_clone(), stream.try_clone()) else { return };
    let _ = stream.set_read_timeout(None);
    let _ = stream.set_write_timeout(Some(std::time::Duration::from_secs(60)));
    serve_io(reader, writer, first, leftover, roots);
}

/// [`serve`] on a dial given as its two halves: what the Mac sends (after `first` and
/// `leftover`) and where its answers go. The Cloud carrier's dials arrive this way, as a line
/// connection of the local socket (server `fs_wire::serve_local_projection`).
pub fn serve_io(
    reader: impl Read,
    writer: impl Write + Send + 'static,
    first: &str,
    leftover: Vec<u8>,
    roots: &[PathBuf],
) {
    let reader = std::io::Cursor::new(leftover).chain(reader);
    if wants_lines(first) {
        let reader = LineReader::new(std::io::BufReader::with_capacity(256 * 1024, reader));
        if wants_wire(first) {
            serve_dial(reader, writer, first, roots, LineWriter::binary);
        } else {
            serve_dial(reader, writer, first, roots, LineWriter::new);
        }
    } else {
        serve_dial(reader, writer, first, roots, |writer| writer);
    }
}

/// Mounts (or attaches) and answers on `writer`, then serves the projection's asks with
/// `framed(writer)` until the Mac closes the dial.
fn serve_dial<R: Read, W: Write + Send + 'static, F: Write + Send + 'static>(
    mut reader: R,
    mut writer: W,
    first: &str,
    roots: &[PathBuf],
    framed: impl FnOnce(W) -> F,
) {
    let id = serde_json::from_str::<Value>(first)
        .ok()
        .and_then(|value| value.get("id").cloned())
        .unwrap_or(Value::Null);
    if let Some(cmd) = frame_command(first).filter(|cmd| *cmd != SERVE) {
        way_back(cmd, first, &id, &mut reader, writer, framed);
        return;
    }
    let projected = match attach(first, &mut reader, roots) {
        Ok((projected, mut data)) => {
            // The Mac packs its answers (and writes binary lines) once it reads this.
            if wants_wire(first) {
                if let Some(object) = data.as_object_mut() {
                    object.insert("wire".into(), json!(WIRE));
                }
            }
            if send_line(&mut writer, &json!({"id": id, "ok": true, "data": data})).is_err() {
                return;
            }
            projected
        }
        Err((code, message)) => {
            let _ = send_line(
                &mut writer,
                &json!({"id": id, "ok": false, "error": message, "error_code": code}),
            );
            return;
        }
    };
    // The Mac is back: the next read that fails for its absence starts a new episode.
    #[cfg(target_os = "linux")]
    projected.away.back();
    projected.link.serve_with(reader, framed(writer), projected.ext());
}

/// Where an away episode's notice goes: `(mount point, prompt id, notice title, notice text)`.
/// The daemon installs it once ([`tell_away_with`]); with none, nobody is told.
type AwayTeller = Box<dyn Fn(&Path, &str, &str, &str) + Send + Sync>;

fn away_teller() -> &'static OnceLock<AwayTeller> {
    static TELLER: OnceLock<AwayTeller> = OnceLock::new();
    &TELLER
}

/// Sends every projection's away notices through `teller` (the first call wins): the daemon
/// hands each one to the agent sessions working in the folder.
pub(crate) fn tell_away_with(teller: impl Fn(&Path, &str, &str, &str) + Send + Sync + 'static) {
    let _ = away_teller().set(Box::new(teller));
}

/// The sender an away notice names.
pub(crate) const AWAY_SENDER: &str = "cmux";

/// The title and body of the notice that tells the agent about away episode `report` of the
/// projection mounted at `at` (RFD 0007: "The session tells the agent once, in its context, that
/// the Mac is away and which reads failed; it does not retry on its own").
#[must_use]
pub(crate) fn away_notice(at: &Path, report: &cmux_projection::away::Report) -> (String, String) {
    let reads = if report.failed == 1 { "read" } else { "reads" };
    let title = if report.back {
        format!("The Mac was away: {} {reads} in a projected folder failed", report.failed)
    } else {
        format!("The Mac is away: {} {reads} in a projected folder failed", report.failed)
    };
    let mut body = if report.back {
        format!(
            "The Mac that projects {} was asleep or offline and is back now. The reads below \
             failed with EHOSTDOWN (\"Host is down\") while it was away; nothing retries them on \
             its own, so read them again.",
            at.display()
        )
    } else {
        format!(
            "The Mac that projects {} is asleep or offline. A read of a file not fetched from it \
             yet waits {} s, then fails with EHOSTDOWN (\"Host is down\"); files already read \
             keep working. Nothing retries on its own: read these again once the Mac is back.",
            at.display(),
            cmux_projection::link::AWAY_WAIT.as_secs()
        )
    };
    body.push_str(&format!("\nReads that failed ({}):", report.failed));
    for path in &report.paths {
        body.push_str(&format!("\n- {path}"));
    }
    let more = report.failed.saturating_sub(report.paths.len());
    if more > 0 {
        body.push_str(&format!("\n- and {more} more"));
    }
    (title, body)
}

/// The prompt text of a notice from [`AWAY_SENDER`] (acpmux's `prompt_provenance::notice_text`
/// for a `warn` notice with no host or links), so an agent or page that knows no notice reads it.
#[must_use]
pub(crate) fn away_prompt(title: &str, body: &str) -> String {
    format!("[notice from {AWAY_SENDER} · WARN] {title}\n{body}")
}

/// Tells the installed teller about episode `report` of projection `name` at `at`.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn tell_away(name: &str, at: &Path, report: &cmux_projection::away::Report) {
    let (title, body) = away_notice(at, report);
    let started = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_millis());
    // Unique across daemon restarts: acpmux answers a resent prompt id from its log.
    let prompt_id = format!("projection-away-{name}-{started}-{}", report.episode);
    eprintln!(
        "cmux-tui: projection {name}: the Mac is away, {} reads failed; telling the agent",
        report.failed
    );
    if let Some(teller) = away_teller().get() {
        teller(at, &prompt_id, &title, &away_prompt(&title, &body));
    }
}

fn send_line(writer: &mut impl Write, value: &Value) -> std::io::Result<()> {
    let mut bytes = serde_json::to_vec(value).map_err(std::io::Error::other)?;
    bytes.push(b'\n');
    writer.write_all(&bytes)?;
    writer.flush()
}

#[derive(Deserialize)]
struct WayBackLine {
    name: String,
    #[serde(default)]
    paths_bytes: u64,
    /// [`BROUGHT_BACK`]'s mark.
    #[serde(default)]
    mark: Option<String>,
    /// [`RELEASE`]'s reason.
    #[serde(default)]
    why: Option<String>,
    /// [`PIN`]'s and [`UNPIN`]'s path, relative to the projected folder.
    #[serde(default)]
    path: Option<String>,
    /// [`WARM`]'s paths, relative to the projected folder.
    #[serde(default)]
    paths: Vec<String>,
    /// [`LAYER`]: leave dependency, cache and build folders out of the listing
    /// (`cmux_projection::layer::Layer::collect_pruned`); they follow it as `pruned_bytes`.
    #[serde(default)]
    prune: bool,
}

/// A projection name: 1-64 letters, digits, `-` or `_`.
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte))
}

/// The state folder of projection `name` (upper layer, whiteouts, cache).
fn state_of(name: &str) -> Result<PathBuf, Refusal> {
    crate::platform::workspace_state_dir()
        .map(|dir| dir.join("projections").join(name))
        .ok_or(("projection.unavailable", "no state folder".to_owned()))
}

/// Serves one of Bring Back's dials (module docs): its answer line on `writer`, the bytes after
/// it through `framed(writer)` (text lines on a `"lines": true` dial), or the refusal.
fn way_back<W: Write, F: Write>(
    cmd: &str,
    first: &str,
    id: &Value,
    reader: &mut impl Read,
    mut writer: W,
    framed: impl FnOnce(W) -> F,
) {
    let (data, body) = match way_back_answer(cmd, first, reader) {
        Ok(answer) => answer,
        Err((code, message)) => {
            let _ = send_line(
                &mut writer,
                &json!({"id": id, "ok": false, "error": message, "error_code": code}),
            );
            return;
        }
    };
    if send_line(&mut writer, &json!({"id": id, "ok": true, "data": data})).is_err() {
        return;
    }
    // Past the answer line an error just ends the stream; the Mac sees it short.
    let mut body_writer = std::io::BufWriter::with_capacity(256 * 1024, framed(writer));
    let _ = match body {
        WayBackBody::None => Ok(()),
        WayBackBody::Bytes(bytes) => body_writer.write_all(&bytes),
        WayBackBody::Files(state, paths) => {
            cmux_projection::layer::send_files(&state, &paths, &mut body_writer)
                .map(|_| ())
                .map_err(std::io::Error::other)
        }
    };
    let _ = body_writer.flush();
}

/// What one of Bring Back's dials sends after its answer line.
enum WayBackBody {
    None,
    Bytes(Vec<u8>),
    Files(PathBuf, Vec<String>),
}

/// The `data` of one of Bring Back's answers and the bytes that follow it, after reading what
/// the dial sends.
fn way_back_answer(
    cmd: &str,
    first: &str,
    reader: &mut impl Read,
) -> Result<(Value, WayBackBody), Refusal> {
    let line: WayBackLine = serde_json::from_str(first)
        .map_err(|error| ("projection.params_invalid", format!("bad request: {error}")))?;
    if !valid_name(&line.name) {
        return Err(("projection.params_invalid", "a name is 1-64 letters, digits, - or _".into()));
    }
    let state = state_of(&line.name)?;
    let io = |error: &dyn std::fmt::Display| ("projection.io", error.to_string());
    match cmd {
        LAYER => {
            if !state.is_dir() {
                return Err(("projection.unknown", format!("no projection {} here", line.name)));
            }
            // Taken before the listing: a write between the two makes the mark older than the
            // listing, so `projection.brought_back` finds it changed and keeps everything.
            let mark = cmux_projection::state::mark(&state).map_err(|error| io(&error))?;
            let (layer, pruned) = if line.prune {
                cmux_projection::layer::Layer::collect_pruned(&state)
            } else {
                cmux_projection::layer::Layer::collect(&state).map(|layer| (layer, Vec::new()))
            }
            .map_err(|error| io(&error))?;
            let mut encoded = layer.encode().map_err(|error| io(&error))?;
            let data = if line.prune {
                // The pruned folders follow the listing, so a dial with thousands of them
                // (`__pycache__` in every package) never makes a long answer line.
                let more = cmux_projection::layer::Layer::encode_pruned(&pruned)
                    .map_err(|error| io(&error))?;
                let data = json!({"bytes": encoded.len(), "upper": layer.upper.len(),
                "whiteouts": layer.whiteouts.len(), "mark": mark,
                "pruned_bytes": more.len(), "kept_on_machine": {
                    "folders": pruned.len(),
                    "files": pruned.iter().map(|folder| folder.files).sum::<u64>(),
                    "bytes": pruned.iter().map(|folder| folder.bytes).sum::<u64>(),
                }});
                encoded.extend_from_slice(&more);
                data
            } else {
                json!({"bytes": encoded.len(), "upper": layer.upper.len(),
                       "whiteouts": layer.whiteouts.len(), "mark": mark})
            };
            Ok((data, WayBackBody::Bytes(encoded)))
        }
        UNSYNCED => {
            if !state.is_dir() {
                return Err(("projection.unknown", format!("no projection {} here", line.name)));
            }
            Ok((unsynced(&state, line.prune).map_err(|error| io(&error))?, WayBackBody::None))
        }
        FILES => {
            if line.paths_bytes > MAX_PATHS_BYTES {
                return Err(("projection.too_large", "too many paths".into()));
            }
            let mut raw = Vec::new();
            reader.take(line.paths_bytes).read_to_end(&mut raw).map_err(|error| io(&error))?;
            if raw.len() as u64 != line.paths_bytes {
                return Err(("projection.io", "the dial ended inside the paths".into()));
            }
            let text = String::from_utf8(raw)
                .map_err(|_| ("projection.params_invalid", "paths are not UTF-8".to_owned()))?;
            let paths: Vec<String> =
                text.lines().filter(|path| !path.is_empty()).map(str::to_owned).collect();
            Ok((json!({}), WayBackBody::Files(state, paths)))
        }
        BROUGHT_BACK | RELEASE => Ok((free(cmd, &line, &state)?, WayBackBody::None)),
        PIN | UNPIN | PINS | WARM => Ok((pin_answer(cmd, &line)?, WayBackBody::None)),
        _ => {
            end(
                &mut projections().lock().unwrap_or_else(PoisonError::into_inner),
                &line.name,
                None,
            );
            let dropped = state.is_dir();
            if dropped {
                std::fs::remove_dir_all(&state).map_err(|error| io(&error))?;
            }
            Ok((json!({"dropped": dropped}), WayBackBody::None))
        }
    }
}

/// The most pruned folders [`UNSYNCED`]'s answer names.
const UNSYNCED_FOLDERS: usize = 256;

/// [`UNSYNCED`]'s answer for the projection whose state folder is `state` (module docs).
fn unsynced(state: &Path, prune: bool) -> anyhow::Result<Value> {
    let (layer, pruned) = if prune {
        cmux_projection::layer::Layer::collect_pruned(state)?
    } else {
        (cmux_projection::layer::Layer::collect(state)?, Vec::new())
    };
    let (files, bytes) = layer
        .upper
        .iter()
        .filter(|entry| entry.kind != cmux_projection::manifest::Kind::Dir)
        .fold((0u64, 0u64), |(files, bytes), entry| (files + 1, bytes + entry.size));
    Ok(if prune {
        json!({"files": files, "bytes": bytes, "deleted": layer.whiteouts.len(),
        "kept_on_machine": {
            "folders": pruned.len(),
            "files": pruned.iter().map(|folder| folder.files).sum::<u64>(),
            "bytes": pruned.iter().map(|folder| folder.bytes).sum::<u64>(),
            "paths": pruned.iter().take(UNSYNCED_FOLDERS).map(|f| &f.path).collect::<Vec<_>>(),
        }})
    } else {
        json!({"files": files, "bytes": bytes, "deleted": layer.whiteouts.len()})
    })
}

/// [`PIN`], [`UNPIN`] or [`PINS`] of projection `line.name`, mounted here (module docs).
fn pin_answer(cmd: &str, line: &WayBackLine) -> Result<Value, Refusal> {
    let projected =
        projections().lock().unwrap_or_else(PoisonError::into_inner).get(&line.name).cloned();
    let Some(projected) = projected else {
        return Err((
            "projection.unknown",
            format!("projection {} is not mounted here", line.name),
        ));
    };
    let Some(pins) = projected.pins() else {
        return Err(("projection.unavailable", "projected folders mount on Linux only".into()));
    };
    let path = || {
        line.path.as_deref().ok_or(("projection.params_invalid", format!("{cmd} needs the path")))
    };
    let mut data = match cmd {
        PIN => {
            let path = path()?;
            let report = pins
                .pin(path)
                .map_err(|errno| pin_refusal(errno, path, "not in the projected folder"))?;
            let away = report.first_error == Some(cmux_projection::FetchError::Away.errno());
            json!({"path": path, "files": report.files, "bytes": report.bytes,
                   "fetched_bytes": report.fetched_bytes, "failed": report.failed,
                   "first_error": report.first_error, "away": away})
        }
        UNPIN => {
            let path = path()?;
            pins.unpin(path).map_err(|errno| pin_refusal(errno, path, "not pinned"))?;
            json!({"path": path, "unpinned": true})
        }
        WARM => {
            // A cache fill, not a pin: no pin status in its answer.
            let report = pins.warm(&line.paths, WARM_MAX_FILES, WARM_MAX_BYTES);
            let away = report.first_error == Some(cmux_projection::FetchError::Away.errno());
            return Ok(json!({"files": report.files, "bytes": report.bytes,
                             "fetched_bytes": report.fetched_bytes, "failed": report.failed,
                             "first_error": report.first_error, "away": away}));
        }
        _ => json!({}),
    };
    if let (Some(fields), Value::Object(status)) = (data.as_object_mut(), pin_status(pins)) {
        fields.extend(status);
    }
    Ok(data)
}

/// A pin's or an unpin's `errno` as an answer's code and message.
/// `missing` says what `ENOENT` means for it.
fn pin_refusal(errno: i32, path: &str, missing: &str) -> Refusal {
    let shown = if path.is_empty() { "the whole folder" } else { path };
    match errno {
        libc::ENOENT => ("projection.not_found", format!("{shown}: {missing}")),
        libc::ENOSPC => (
            "projection.no_space",
            format!("{shown}: pinning it would leave too little free disk on this machine"),
        ),
        libc::EINVAL => ("projection.params_invalid", format!("{shown}: not a path in the folder")),
        errno => {
            ("projection.io", format!("{shown}: {}", std::io::Error::from_raw_os_error(errno)))
        }
    }
}

/// `{"pinned_bytes", "pins"}` of `overlay` (module docs).
fn pin_status(overlay: &cmux_projection::overlay::Overlay) -> Value {
    let pins: Vec<Value> = overlay
        .pin_states()
        .into_iter()
        .map(|pin| {
            let complete = pin.complete();
            let mut value = serde_json::to_value(pin).unwrap_or(Value::Null);
            if let Some(fields) = value.as_object_mut() {
                fields.insert("complete".into(), Value::Bool(complete));
            }
            value
        })
        .collect();
    json!({"pinned_bytes": overlay.pinned_bytes(), "pins": pins})
}

impl Projected {
    /// The overlay whose pins this mount keeps.
    #[cfg(target_os = "linux")]
    fn pins(&self) -> Option<&cmux_projection::overlay::Overlay> {
        Some(&self.overlay)
    }

    /// None off Linux, where nothing mounts.
    #[cfg(not(target_os = "linux"))]
    fn pins(&self) -> Option<&cmux_projection::overlay::Overlay> {
        None
    }
}

/// [`BROUGHT_BACK`] or [`RELEASE`] of projection `line.name`, whose state folder is `state`: the
/// record says why, the projection ends and its state goes; the bytes freed. A brought-back upper
/// layer written since the Mac's mark (before the unmount or after it) stays whole:
/// `projection.edited_since`.
fn free(cmd: &str, line: &WayBackLine, state: &Path) -> Result<Value, Refusal> {
    use cmux_projection::reap::{self, Why};
    use cmux_projection::state::{self as record, BroughtBack, Release, Released};
    let io = |error: std::io::Error| ("projection.io", error.to_string());
    let edited = |now: String| {
        let message = format!("the upper layer changed since Bring Back read it (now {now})");
        ("projection.edited_since", message)
    };
    let now = record::ms_of(std::time::SystemTime::now());
    // Held throughout: no mount of this name starts while its state goes.
    let mut table = projections().lock().unwrap_or_else(PoisonError::into_inner);
    let at = record::read(state)
        .map(|found| found.at)
        .or_else(|| table.get(&line.name).map(|projected| projected.at.clone()));
    let recorded_at = at.clone().unwrap_or_default();
    let why = if cmd == BROUGHT_BACK {
        let Some(mark) = line.mark.as_deref() else {
            return Err(("projection.params_invalid", "brought_back needs the mark".into()));
        };
        if !state.is_dir() {
            return Err(("projection.unknown", format!("no projection {} here", line.name)));
        }
        let current = record::mark(state).map_err(io)?;
        if current != mark {
            return Err(edited(current));
        }
        record::update(state, &recorded_at, |found| {
            found.brought_back = Some(BroughtBack { ms: now, mark: mark.to_owned() });
        })
        .map_err(io)?;
        end(&mut table, &line.name, at.as_deref());
        // A write that landed before the unmount is in the upper layer now.
        let current = record::mark(state).map_err(io)?;
        if current != mark {
            return Err(edited(current));
        }
        Why::BroughtBack
    } else {
        let Some(release) = Release::parse(line.why.as_deref().unwrap_or("archived")) else {
            return Err(("projection.params_invalid", "why is archived or deleted".into()));
        };
        if state.is_dir() {
            record::update(state, &recorded_at, |found| {
                found.released = Some(Released { ms: now, why: release });
            })
            .map_err(io)?;
        }
        end(&mut table, &line.name, at.as_deref());
        release.into()
    };
    let freed = reap::free_projection(state, at.as_deref(), why);
    drop(table);
    let freed = freed.map_err(io)?;
    eprintln!("cmux projection: freed {} ({}): {freed} bytes", state.display(), why.as_str());
    Ok(json!({"freed_bytes": freed, "dropped": true}))
}

/// Ends projection `name`: this daemon's mount of it, or a dead daemon's mount left at `at`.
/// `table` is [`projections`], held.
fn end(table: &mut HashMap<String, Arc<Projected>>, name: &str, at: Option<&Path>) {
    if let Some(old) = table.remove(name) {
        old.link.detach();
        #[cfg(target_os = "linux")]
        if let Some(mounted) = old.mounted.lock().unwrap_or_else(PoisonError::into_inner).take() {
            mounted.unmount();
        }
        return;
    }
    #[cfg(target_os = "linux")]
    if let Some(at) = at.filter(|at| is_mount(at)) {
        cmux_projection::mount::unmount_stale(at);
    }
    #[cfg(not(target_os = "linux"))]
    let _ = at;
}

/// Whether `at` is a mount point (or a dead one: a FUSE mount whose daemon is gone fails `stat`).
#[cfg(target_os = "linux")]
fn is_mount(at: &Path) -> bool {
    use std::os::unix::fs::MetadataExt as _;
    match (std::fs::symlink_metadata(at), at.parent().map(std::fs::metadata)) {
        (Err(error), _) => error.kind() != std::io::ErrorKind::NotFound,
        (Ok(meta), Some(Ok(parent))) => meta.dev() != parent.dev(),
        (Ok(_), _) => false,
    }
}

/// The Mac dialed projection `name` again: its record says when (an orphan's grace counts from it).
fn attached(name: &str, at: &Path) {
    if let Ok(state) = state_of(name) {
        let now = cmux_projection::state::ms_of(std::time::SystemTime::now());
        let _ = cmux_projection::state::update(&state, at, |record| record.attached_ms = now);
    }
}

/// The reaper's view of this daemon's mounts ([`cmux_projection::reap::Live`]).
struct DaemonMounts;

impl cmux_projection::reap::Live for DaemonMounts {
    fn mounted(&self, name: &str) -> bool {
        projections().lock().unwrap_or_else(PoisonError::into_inner).contains_key(name)
    }

    fn end(
        &self,
        name: &str,
        at: Option<&Path>,
        only_if_idle: bool,
        free: &mut dyn FnMut() -> std::io::Result<u64>,
    ) -> Option<std::io::Result<u64>> {
        let mut table = projections().lock().unwrap_or_else(PoisonError::into_inner);
        if only_if_idle && table.contains_key(name) {
            return None;
        }
        end(&mut table, name, at);
        Some(free())
    }
}

/// One reaper pass now: this machine's chats from acpmux at `acpmux_socket`, then
/// [`cmux_projection::reap::pass`] over the projections' state. Logs each reclaim.
pub fn reap_once(acpmux_socket: Option<&Path>) -> cmux_projection::reap::Report {
    use cmux_projection::reap;
    let chats = acpmux_socket.map_or_else(reap::Chats::unread, |socket| {
        crate::server::machine_chats(socket, CHATS_WITHIN)
    });
    let started = std::time::Instant::now();
    let places = reap::Places {
        projections: crate::platform::workspace_state_dir().map(|dir| dir.join("projections")),
    };
    let report = reap::pass(
        &places,
        &chats,
        &DaemonMounts,
        std::time::SystemTime::now(),
        &reap::Limits::default(),
    );
    for reclaim in &report.reclaimed {
        eprintln!(
            "cmux projection reaper: freed {} ({}): {} bytes",
            reclaim.path.display(),
            reclaim.why.as_str(),
            reclaim.bytes
        );
    }
    for (path, error) in &report.failed {
        eprintln!("cmux projection reaper: could not free {}: {error}", path.display());
    }
    if !report.reclaimed.is_empty() || report.deferred > 0 {
        eprintln!(
            "cmux projection reaper: pass freed {} bytes in {} folders ({} left for the next \
             pass; chat list {}) in {} ms",
            report.bytes(),
            report.reclaimed.len(),
            report.deferred,
            if chats.complete { "read" } else { "not read" },
            started.elapsed().as_millis()
        );
    }
    report
}

/// One aging pass over every mounted projection's content store
/// (`cmux_projection::overlay::content::Content::age`: unread bytes go cold, then are deleted
/// unless pinned), then the machine's held number (`cmux_projection::hold::held`) written to
/// `projection-held.json` in the workspace state folder for NOW's now-bytes source. Logs both.
pub fn age_once() -> Option<cmux_projection::hold::Held> {
    let started = std::time::Instant::now();
    #[cfg(target_os = "linux")]
    {
        let now = std::time::SystemTime::now();
        let aging = cmux_projection::overlay::content::Aging::default();
        let live: Vec<(String, Arc<Projected>)> = projections()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .map(|(name, projected)| (name.clone(), projected.clone()))
            .collect();
        for (name, projected) in live {
            let Some(report) = projected.overlay.age(now, &aging) else { continue };
            if report.went_cold_blobs + report.deleted_blobs > 0 {
                eprintln!(
                    "cmux projection aging: {name}: {} blobs cold ({} bytes, {} saved), {} \
                     deleted ({} bytes freed); holds {} bytes",
                    report.went_cold_blobs,
                    report.went_cold_bytes,
                    report.went_cold_saved_bytes,
                    report.deleted_blobs,
                    report.deleted_stored_bytes,
                    report.held_bytes()
                );
            }
        }
    }
    let state = crate::platform::workspace_state_dir()?;
    let held = cmux_projection::hold::held(&state.join("projections"));
    let line = serde_json::to_vec(&json!({
        "schema": "projection-held/v1",
        "at": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
        "held": held,
    }))
    .ok()?;
    let to = state.join("projection-held.json");
    let temp = to.with_extension("json.new");
    if std::fs::write(&temp, line).and_then(|()| std::fs::rename(&temp, &to)).is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    eprintln!(
        "cmux projection held: {} logical bytes ({} stored, {} duplicate) in {} blobs ({} cold) \
         over {} projections, in {} ms",
        held.logical_bytes,
        held.stored_bytes,
        held.duplicate_bytes,
        held.blobs,
        held.cold_blobs,
        held.projections,
        started.elapsed().as_millis()
    );
    Some(held)
}

/// Starts the reaper thread: a pass [`REAP_FIRST_AFTER`] the daemon starts, then every
/// [`REAP_EVERY`]. Only where this daemon serves projections (Linux, with file roots), and once.
pub fn start_reaper(acpmux_socket: Option<PathBuf>) {
    static STARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if advertised().is_empty() || STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    let spawned =
        std::thread::Builder::new().name("cmux-projection-reaper".into()).spawn(move || {
            std::thread::sleep(REAP_FIRST_AFTER);
            loop {
                reap_once(acpmux_socket.as_deref());
                age_once();
                std::thread::sleep(REAP_EVERY);
            }
        });
    if let Err(error) = spawned {
        eprintln!("cmux projection reaper: not started: {error}");
    }
}

/// Reads the dial's manifest and mounts it (or finds the mount it attaches to again).
fn attach(
    first: &str,
    reader: &mut impl Read,
    roots: &[PathBuf],
) -> Result<(Arc<Projected>, Value), Refusal> {
    let line: ServeLine = serde_json::from_str(first)
        .map_err(|error| ("projection.params_invalid", format!("bad request: {error}")))?;
    if line.cmd != SERVE {
        return Err(("projection.params_invalid", "not projection.serve".into()));
    }
    if !valid_name(&line.name) {
        return Err(("projection.params_invalid", "a name is 1-64 letters, digits, - or _".into()));
    }
    if line.manifest_bytes > MAX_MANIFEST_BYTES {
        return Err(("projection.too_large", "the manifest is too large".into()));
    }
    let at = mount_point(&line.at, roots)?;
    let mut encoded = Vec::new();
    reader
        .take(line.manifest_bytes)
        .read_to_end(&mut encoded)
        .map_err(|error| ("projection.io", format!("reading the manifest: {error}")))?;
    if encoded.len() as u64 != line.manifest_bytes {
        return Err(("projection.io", "the dial ended inside the manifest".into()));
    }
    let existing =
        projections().lock().unwrap_or_else(PoisonError::into_inner).get(&line.name).cloned();
    let started = std::time::Instant::now();
    if line.extend {
        return extend(&line.name, &at, &encoded, existing, started);
    }
    let mut from_store = None;
    let (manifest, digest) = if encoded.is_empty() {
        let existing = existing.filter(|projected| projected.at == at);
        if let Some(projected) = existing {
            attached(&line.name, &at);
            return Ok((
                projected.clone(),
                with_pins(json!({"at": at, "attached": true}), &projected),
            ));
        }
        // Not mounted here (a resume, a daemon restart): the stored revision, when the Mac named one.
        let Some(revision) = &line.revision else {
            return Err(("projection.unknown", format!("no projection {} here", line.name)));
        };
        let manifest = fetch_revision(revision)?;
        from_store = Some(u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX));
        (manifest, fnv(revision.root.as_bytes()))
    } else {
        let digest = fnv(&encoded);
        if let Some(projected) = existing.filter(|projected| {
            projected.digest.load(Ordering::Relaxed) == digest && projected.at == at
        }) {
            attached(&line.name, &at);
            return Ok((
                projected.clone(),
                with_pins(json!({"at": at, "attached": true}), &projected),
            ));
        }
        let manifest = cmux_projection::manifest::Manifest::decode(&encoded)
            .map_err(|error| ("projection.params_invalid", format!("bad manifest: {error:#}")))?;
        (manifest, digest)
    };
    let (files, bytes) = manifest.totals();
    let entries = manifest.len();
    // The upper layer and the cache: this daemon's own state, beside the folder roots, never in them.
    let state = state_of(&line.name)?;
    let projected =
        mount(&line.name, manifest, &state, &at, digest, line.head, line.from.as_deref())?;
    if let (Some(dir), Some(home)) = (state.parent(), std::env::var_os("HOME")) {
        if let Err(error) = git_stat::keep(dir, Path::new(&home), &at) {
            eprintln!("cmux-tui: projection {}: git settings: {error}", line.name);
        }
    }
    let data = json!({
        "at": at,
        "entries": entries,
        "files": files,
        "bytes": bytes,
        "mount_ms": u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
        "revision_ms": from_store,
    });
    Ok((projected.clone(), with_pins(data, &projected)))
}

/// A mount's answer `data` with its pins' status added (module docs).
fn with_pins(mut data: Value, projected: &Projected) -> Value {
    if let (Some(fields), Some(Value::Object(status))) =
        (data.as_object_mut(), projected.pins().map(pin_status))
    {
        fields.extend(status);
    }
    data
}

/// `projection-extend-v1`: the mount of `name` at `at` takes the full manifest `encoded` in place
/// of the one it mounted, and its sync barrier (held at the head by a `"head": true` dial) opens.
#[cfg(target_os = "linux")]
fn extend(
    name: &str,
    at: &Path,
    encoded: &[u8],
    existing: Option<Arc<Projected>>,
    started: std::time::Instant,
) -> Result<(Arc<Projected>, Value), Refusal> {
    let projected = existing
        .filter(|projected| projected.at == at)
        .ok_or_else(|| ("projection.unknown", format!("no projection {name} here to extend")))?;
    if encoded.is_empty() {
        return Err(("projection.params_invalid", "an extend carries the full manifest".into()));
    }
    let digest = fnv(encoded);
    if projected.digest.load(Ordering::Relaxed) == digest {
        // The same manifest again (a dial that retried): nothing to swap, the barrier may still wait.
        open_barrier(&projected)?;
        attached(name, at);
        return Ok((projected, json!({"at": at, "extended": true, "added": 0})));
    }
    let full = cmux_projection::manifest::Manifest::decode(encoded)
        .map_err(|error| ("projection.params_invalid", format!("bad manifest: {error:#}")))?;
    let (files, bytes) = full.totals();
    let entries = full.len();
    let extended = projected.overlay.extend(Arc::new(full)).map_err(|error| match error {
        cmux_projection::lower::ExtendError::NotSuperset { .. } => {
            ("projection.extend_not_superset", error.to_string())
        }
        cmux_projection::lower::ExtendError::Done => ("projection.extend_done", error.to_string()),
    })?;
    projected.digest.store(digest, Ordering::Relaxed);
    *projected.ext.lock().unwrap_or_else(PoisonError::into_inner) = Some(extended.ext.clone());
    if let Some(mounted) = projected.mounted.lock().unwrap_or_else(PoisonError::into_inner).as_ref()
    {
        mounted.forget_inodes(&extended.changed);
    }
    open_barrier(&projected)?;
    attached(name, at);
    let data = json!({
        "at": at,
        "extended": true,
        "entries": entries,
        "files": files,
        "bytes": bytes,
        "added": extended.added,
        "extend_ms": u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
    });
    Ok((projected, data))
}

#[cfg(not(target_os = "linux"))]
fn extend(
    _name: &str,
    _at: &Path,
    _encoded: &[u8],
    _existing: Option<Arc<Projected>>,
    _started: std::time::Instant,
) -> Result<(Arc<Projected>, Value), Refusal> {
    Err(("projection.unavailable", "projected folders mount on Linux only".into()))
}

/// Marks the folder's sync barrier ready, when a `"head": true` dial left it held at the head.
#[cfg(target_os = "linux")]
fn open_barrier(projected: &Projected) -> Result<(), Refusal> {
    let held = projected.barrier.lock().unwrap_or_else(PoisonError::into_inner).take();
    match held {
        Some(barrier) => barrier
            .complete()
            .map_err(|error| ("projection.io", format!("marking the folder ready: {error}"))),
        None => Ok(()),
    }
}

/// `at` as a mount point: absolute, below one of `roots`, and a folder that is empty (made when
/// missing). A dead mount left there by an earlier daemon is cleared first.
fn mount_point(at: &str, roots: &[PathBuf]) -> Result<PathBuf, Refusal> {
    let path = PathBuf::from(at);
    let refused = |why: &str| ("projection.params_invalid", format!("{at}: {why}"));
    if !path.is_absolute()
        || path.components().any(|part| {
            !matches!(part, std::path::Component::Normal(_) | std::path::Component::RootDir)
        })
    {
        return Err(refused("not an absolute, plain path"));
    }
    let parent = path.parent().ok_or_else(|| refused("no folder above it"))?;
    std::fs::create_dir_all(parent).map_err(|error| refused(&error.to_string()))?;
    let parent = std::fs::canonicalize(parent).map_err(|error| refused(&error.to_string()))?;
    let below = roots
        .iter()
        .any(|root| std::fs::canonicalize(root).is_ok_and(|root| parent.starts_with(&root)));
    if !below {
        return Err(refused("outside this machine's file roots"));
    }
    let path = parent.join(path.file_name().ok_or_else(|| refused("no name"))?);
    #[cfg(target_os = "linux")]
    if !projections()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .values()
        .any(|projected| projected.at == path)
    {
        cmux_projection::mount::unmount_stale(&path);
    }
    Ok(path)
}

#[cfg(target_os = "linux")]
fn mount(
    name: &str,
    manifest: cmux_projection::manifest::Manifest,
    state: &Path,
    at: &Path,
    digest: u64,
    head: bool,
    from: Option<&str>,
) -> Result<Arc<Projected>, Refusal> {
    use std::os::unix::fs::MetadataExt as _;
    let mut table = projections().lock().unwrap_or_else(PoisonError::into_inner);
    // A barrier the old mount held at its head: a remount that is no head dial has the whole
    // folder to offer, so it opens (below, once that mount is up); another head dial takes its own.
    let mut old_barrier = None;
    // Another manifest for the same name (the Mac's folder changed shape): the old mount goes.
    if let Some(old) = table.remove(name) {
        old_barrier = old.barrier.lock().unwrap_or_else(PoisonError::into_inner).take();
        old.link.detach();
        if let Some(mounted) = old.mounted.lock().unwrap_or_else(PoisonError::into_inner).take() {
            mounted.unmount();
        }
    }
    let io =
        |what: &str, error: &dyn std::fmt::Display| ("projection.io", format!("{what}: {error}"));
    std::fs::create_dir_all(at).map_err(|error| io("making the mount point", &error))?;
    let busy = std::fs::read_dir(at)
        .map_err(|error| io("reading the mount point", &error))?
        .next()
        .is_some();
    if busy {
        return Err(("projection.busy", format!("{} is not empty", at.display())));
    }
    std::fs::create_dir_all(state).map_err(|error| io("making the projection's state", &error))?;
    let meta = std::fs::metadata(state).map_err(|error| io("reading the state folder", &error))?;
    let link = Arc::new(cmux_projection::link::Link::default());
    let fetch: Arc<dyn cmux_projection::Fetch> = link.clone();
    let away = {
        let (name, at) = (name.to_owned(), at.to_path_buf());
        cmux_projection::away::Away::new(move |report| tell_away(&name, &at, &report))
    };
    let overlay = cmux_projection::overlay::Overlay::open(
        Arc::new(manifest),
        state,
        fetch,
        (meta.uid(), meta.gid()),
    )
    .map_err(|error| io("opening the projection", &format!("{error:#}")))?
    .with_away(away.clone());
    // RFD 0065 piece 8: record this start's first reads and replay the last start's list.
    // `CMUX_PROJECTION_REPLAY=0` keeps the folder read-ahead alone, as before.
    let replay = std::env::var_os("CMUX_PROJECTION_REPLAY").is_none_or(|value| value != "0");
    let overlay = if replay { overlay.with_replay("start") } else { overlay };
    let overlay = Arc::new(overlay);
    let named =
        cmux_projection::mount::Options { fsname: Some(fsname_for(from)), ..Default::default() };
    let mounted = match cmux_projection::mount::mount_with(overlay.clone(), at, named) {
        Ok(mounted) => Ok(mounted),
        // The Mac folder's name in the mount table is a label only: a mount that refuses it
        // mounts as before, under the plain name.
        Err(error) if from.is_some() => {
            eprintln!("cmux-tui: projection {name}: mounting with its Mac folder named: {error:#}");
            cmux_projection::mount::mount(overlay.clone(), at)
        }
        Err(error) => Err(error),
    }
    .map_err(|error| ("projection.mount_failed", format!("{error:#}")))?;
    // Pinned folders an earlier mount recorded are fetched whole in the background, so they read
    // with the Mac away again (a new manifest starts a fresh cache). Mac away: it stops at the
    // first absence, and the next mount tries again.
    if !overlay.pins().is_empty() {
        let pinned = overlay.clone();
        let _ = std::thread::Builder::new().name("projection-pins".into()).spawn(move || {
            let _ = pinned.hydrate_pins();
        });
    }
    // The last start's access list is fetched in the background, so its files are local before
    // the agent asks (it stops at the first batch the Mac is away for).
    if !overlay.replay_list().is_empty() {
        let replaying = overlay.clone();
        let _ = std::thread::Builder::new().name("projection-replay".into()).spawn(move || {
            let _ = replaying.replay_prefetch();
        });
    }
    // RFD 0065 piece 11: behind the mount, the rest of the tree comes down at low priority so the
    // folder ends up local. Off unless `CMUX_PROJECTION_BULK_COPY=1`: it moves the whole tree over
    // the Mac's link, and the path-ordered pack transport the RFD sizes it with is not built yet.
    if std::env::var_os("CMUX_PROJECTION_BULK_COPY").is_some_and(|value| value == "1") {
        let copying = overlay.clone();
        let _ = std::thread::Builder::new().name("projection-bulk-copy".into()).spawn(move || {
            cmux_projection::overlay::bulk::lower_priority();
            let _ = copying.bulk_copy(
                &cmux_projection::overlay::bulk::BulkOptions::default(),
                &std::sync::atomic::AtomicBool::new(false),
            );
        });
    }
    let projected = Arc::new(Projected {
        link,
        digest: AtomicU64::new(digest),
        at: at.to_path_buf(),
        overlay: overlay.clone(),
        ext: Mutex::new(None),
        barrier: Mutex::new(None),
        mounted: Mutex::new(Some(mounted)),
        away,
    });
    table.insert(name.to_owned(), projected.clone());
    if head {
        // Its marker beside the folder is the old one's too: that sync lets go first.
        drop(old_barrier.take());
        // The mount is the head (a few entries): the harness may start, its tools wait for the extend.
        let held = BarrierSync::begin(at).map(|mut barrier| {
            barrier.head_ready();
            barrier
        });
        match held {
            Ok(barrier) => {
                *projected.barrier.lock().unwrap_or_else(PoisonError::into_inner) = Some(barrier);
            }
            Err(error) => {
                table.remove(name);
                projected.link.detach();
                if let Some(mounted) =
                    projected.mounted.lock().unwrap_or_else(PoisonError::into_inner).take()
                {
                    mounted.unmount();
                }
                return Err((
                    "projection.barrier_busy",
                    format!("{}: the sync barrier is not free: {error}", at.display()),
                ));
            }
        }
    } else if let Some(barrier) = old_barrier.take() {
        let _ = barrier.complete();
    }
    // RFD 0007, seed bundles: carry is on by default. The sender's live git probe adds a depth-1
    // pack and base to the manifest, and the machine switches from projection to that repository.
    // CMUX_PROJECTION_GIT_SWAP=off is the diagnostic kill switch.
    if cmux_projection::git_swap::enabled() {
        let swapping = projected.clone();
        let (at, state) = (at.to_path_buf(), state.to_path_buf());
        let _ = std::thread::Builder::new().name("projection-git-swap".into()).spawn(move || {
            let forget =
                || match swapping.mounted.lock().unwrap_or_else(PoisonError::into_inner).as_ref() {
                    Some(mounted) => mounted.forget_entry(overlay.root(), ".git"),
                    None => Ok(()),
                };
            match cmux_projection::git_swap::run(&overlay, &forget, &at, &state) {
                Ok(outcome) => eprintln!("cmux projection: {} .git: {outcome:?}", at.display()),
                Err(error) => {
                    eprintln!("cmux projection: {} .git stays projected: {error:#}", at.display());
                }
            }
        });
    }
    // The record the reaper reads: where it is, since when, and a release or Bring Back undone (a
    // dial again means the chat is live). One that cannot be written leaves the state to the orphan grace,
    // never freed early.
    let now = cmux_projection::state::ms_of(std::time::SystemTime::now());
    let _ = cmux_projection::state::update(state, at, |record| {
        if record.created_ms == 0 {
            record.created_ms = now;
        }
        record.at = at.to_path_buf();
        record.attached_ms = now;
        record.released = None;
        record.brought_back = None;
    });
    Ok(projected)
}

#[cfg(not(target_os = "linux"))]
fn mount(
    _name: &str,
    _manifest: cmux_projection::manifest::Manifest,
    _state: &Path,
    _at: &Path,
    _digest: u64,
    _head: bool,
    _from: Option<&str>,
) -> Result<Arc<Projected>, Refusal> {
    Err(("projection.unavailable", "projected folders mount on Linux only".into()))
}

/// The mount table's source for a projection: [`FSNAME`], then `:` and the Mac folder it mirrors
/// when the Mac named one, percent-encoded so no mount option separator, space or escape is in
/// it (decoded by acpmux's `this_folder`). `CMUX_PROJECTION_NAMES_MAC_FOLDER=0` leaves it out.
pub fn fsname_for(from: Option<&str>) -> String {
    let off = std::env::var("CMUX_PROJECTION_NAMES_MAC_FOLDER")
        .is_ok_and(|value| matches!(value.as_str(), "0" | "false"));
    let Some(from) = from.filter(|from| {
        !off && !from.is_empty()
            && from.len() <= MAX_FROM_BYTES
            && !from.chars().any(char::is_control)
    }) else {
        return FSNAME.to_owned();
    };
    let mut name = format!("{FSNAME}:");
    for byte in from.bytes() {
        if byte.is_ascii_alphanumeric() || b"/._~+-".contains(&byte) {
            name.push(char::from(byte));
        } else {
            name.push_str(&format!("%{byte:02X}"));
        }
    }
    name
}

/// The mount table's source of every projection, alone or before `:` and its Mac folder.
pub const FSNAME: &str = "cmux-projection";
/// The longest Mac folder name a mount carries; a longer one is left out.
const MAX_FROM_BYTES: usize = 1024;

/// Git in a projected folder compares a file's size and whole-second mtime only. The index came
/// from the Mac, so its inode, device, owner and ctime never match this mount's: with git's
/// default checks every `git status` would read every tracked file once, fetching all of them
/// from the Mac (cmuxterm-hq: 1.1 GB and minutes before an agent's first answer, against 3 s).
/// Only this machine's git settings change, never the folder: `~/.gitconfig` includes
/// [`MOUNTS`], which holds one `includeIf "gitdir:<mount>/"` per mount, naming [`STAT`].
mod git_stat {
    use std::io::Write as _;
    use std::path::Path;

    pub(super) const STAT: &str = "git-stat.config";
    pub(super) const MOUNTS: &str = "git-mounts.config";
    const STAT_TEXT: &str = "[core]\n\tcheckStat = minimal\n\ttrustctime = false\n";

    /// Makes `at` (and every repository below it) use [`STAT`]; `dir` is the projections'
    /// state folder, `home` the work user's home.
    pub(super) fn keep(dir: &Path, home: &Path, at: &Path) -> std::io::Result<()> {
        let stat = dir.join(STAT);
        if std::fs::read_to_string(&stat).ok().as_deref() != Some(STAT_TEXT) {
            std::fs::write(&stat, STAT_TEXT)?;
        }
        let mounts = dir.join(MOUNTS);
        let section = section(at, &stat);
        let known = std::fs::read_to_string(&mounts).unwrap_or_default();
        if !known.contains(&section) {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&mounts)?
                .write_all(section.as_bytes())?;
        }
        let global = home.join(".gitconfig");
        let include = include(&mounts);
        let text = std::fs::read_to_string(&global).unwrap_or_default();
        if !text.contains(&include) {
            let lead = if text.is_empty() || text.ends_with('\n') { "" } else { "\n" };
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&global)?
                .write_all(format!("{lead}{include}").as_bytes())?;
        }
        Ok(())
    }

    /// The `includeIf` for `at`: git adds `**` after a trailing `/`, so it holds below `at` too.
    pub(super) fn section(at: &Path, stat: &Path) -> String {
        format!("[includeIf \"gitdir:{}/\"]\n\tpath = {}\n", at.display(), stat.display())
    }

    pub(super) fn include(mounts: &Path) -> String {
        format!("[include]\n\tpath = {}\n", mounts.display())
    }
}

/// FNV-1a of the manifest's bytes: which manifest a mount serves.
fn fnv(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

#[cfg(test)]
#[path = "projection_tests.rs"]
mod tests;
