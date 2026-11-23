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
//! with "Host is down".
//!
//! Bring Back (`cmux_projection::way_back`) reads what the agent changed with three more dials,
//! each one request and its answer, by projection `name`, mounted or not (the state folder
//! outlives the mount and a daemon restart):
//! - `{"id", "cmd": "projection.layer", "name"}`: answered `{"id", "ok": true, "data": {"bytes",
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
//! When a chat is archived or deleted, `{"id", "cmd": "projection.release", "name", "why":
//! "archived" | "deleted"}` ends its projection, deletes its state and its empty mount point:
//! `{"freed_bytes", "dropped": true}`. The reaper ([`start_reaper`]) frees the rest on its own,
//! at the daemon's start and every [`REAP_EVERY`]: it reads this machine's chats from acpmux and
//! runs one bounded `cmux_projection::reap::pass` over the projections (archived chats, Bring
//! Back's leftovers, orphans past their grace), and logs each with the bytes it freed.
//!
//! Served where `fs-v1` is (a Cloud host), on Linux; anywhere else a dial is answered
//! `projection.unavailable`.
//!
//! A dial whose line says `"lines": true` sends every byte after that line, and gets every byte
//! after its answer, as text lines instead ([`LineReader`], [`LineWriter`]): the Cloud carrier
//! carries a dial as a `mux-control` stream, which moves whole lines only.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use serde::Deserialize;
use serde_json::{Value, json};

/// The capability that carries `projection.serve`.
pub const PROJECTION_CAPABILITY: &str = "projection-v1";
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
    /// With no manifest bytes and no mount of this name: the stored revision to mount instead
    /// (RFD 0007, open question 3). The Mac sends this on a resume, so the listing comes from the
    /// store and not over its uplink.
    #[serde(default)]
    revision: Option<RevisionRef>,
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
/// The most bytes one [`LineWriter`] line carries (1.4 MB of text, far below the carrier's
/// 16 MiB line limit).
const LINE_BYTES: usize = 1024 * 1024;

/// Bytes written as text lines: each `write` of up to [`LINE_BYTES`] becomes one line,
/// `~` and its base64.
pub struct LineWriter<W: Write> {
    inner: W,
}

impl<W: Write> LineWriter<W> {
    pub fn new(inner: W) -> Self {
        Self { inner }
    }
}

impl<W: Write> Write for LineWriter<W> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        use base64::Engine as _;
        let chunk = bytes.get(..bytes.len().min(LINE_BYTES)).unwrap_or_default();
        if chunk.is_empty() {
            return Ok(0);
        }
        let mut line = Vec::with_capacity(chunk.len() / 3 * 4 + 6);
        line.push(LINE_MARK);
        line.extend_from_slice(base64::engine::general_purpose::STANDARD.encode(chunk).as_bytes());
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
            let text = match line.split_first() {
                Some((&LINE_MARK, text)) => text,
                _ => {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "not a projection line",
                    ));
                }
            };
            self.decoded = base64::engine::general_purpose::STANDARD
                .decode(text)
                .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))?;
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

/// Whether the dial line `first` asks for [`LineWriter`] lines.
fn wants_lines(first: &str) -> bool {
    serde_json::from_str::<ServeLine>(first).is_ok_and(|line| line.lines)
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
    [SERVE, LAYER, FILES, DROP, BROUGHT_BACK, RELEASE].into_iter().find(|known| *known == cmd)
}

/// The capabilities to advertise: [`PROJECTION_CAPABILITY`] where a projection can mount (Linux,
/// with this daemon's file roots installed).
#[must_use]
pub fn advertised() -> Vec<&'static str> {
    if cfg!(target_os = "linux") && crate::fs_ops::installed().is_some() {
        vec![PROJECTION_CAPABILITY]
    } else {
        Vec::new()
    }
}

/// A projection this daemon has mounted.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
struct Projected {
    link: Arc<cmux_projection::link::Link>,
    /// What the manifest it mounted hashed to (a dial with another manifest remounts).
    digest: u64,
    at: PathBuf,
    #[cfg(target_os = "linux")]
    mounted: Mutex<Option<cmux_projection::mount::Mounted>>,
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
        serve_dial(reader, writer, first, roots, LineWriter::new);
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
        Ok((projected, data)) => {
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
    projected.link.serve(reader, framed(writer));
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
            let layer =
                cmux_projection::layer::Layer::collect(&state).map_err(|error| io(&error))?;
            let encoded = layer.encode().map_err(|error| io(&error))?;
            let data = json!({"bytes": encoded.len(), "upper": layer.upper.len(),
                              "whiteouts": layer.whiteouts.len(), "mark": mark});
            Ok((data, WayBackBody::Bytes(encoded)))
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

/// Starts the reaper thread: a pass [`REAP_FIRST_AFTER`] the daemon starts, then every
/// [`REAP_EVERY`]. Only where this daemon serves projections (Linux, with file roots), and once.
pub fn start_reaper(acpmux_socket: Option<PathBuf>) {
    static STARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if advertised().is_empty() || STARTED.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    let spawned =
        std::thread::Builder::new().name("cmux-projection-reaper".into()).spawn(move || {
            std::thread::sleep(REAP_FIRST_AFTER);
            loop {
                reap_once(acpmux_socket.as_deref());
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
    let mut from_store = None;
    let (manifest, digest) = if encoded.is_empty() {
        let existing = existing.filter(|projected| projected.at == at);
        if let Some(projected) = existing {
            attached(&line.name, &at);
            return Ok((projected, json!({"at": at, "attached": true})));
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
        if let Some(projected) =
            existing.filter(|projected| projected.digest == digest && projected.at == at)
        {
            attached(&line.name, &at);
            return Ok((projected, json!({"at": at, "attached": true})));
        }
        let manifest = cmux_projection::manifest::Manifest::decode(&encoded)
            .map_err(|error| ("projection.params_invalid", format!("bad manifest: {error:#}")))?;
        (manifest, digest)
    };
    let (files, bytes) = manifest.totals();
    let entries = manifest.len();
    // The upper layer and the cache: this daemon's own state, beside the folder roots, never in them.
    let state = state_of(&line.name)?;
    let projected = mount(&line.name, manifest, &state, &at, digest)?;
    if let (Some(dir), Some(home)) = (state.parent(), std::env::var_os("HOME"))
        && let Err(error) = git_stat::keep(dir, Path::new(&home), &at)
    {
        eprintln!("cmux-tui: projection {}: git settings: {error}", line.name);
    }
    let data = json!({
        "at": at,
        "entries": entries,
        "files": files,
        "bytes": bytes,
        "mount_ms": u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
        "revision_ms": from_store,
    });
    Ok((projected, data))
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
) -> Result<Arc<Projected>, Refusal> {
    use std::os::unix::fs::MetadataExt as _;
    let mut table = projections().lock().unwrap_or_else(PoisonError::into_inner);
    // Another manifest for the same name (the Mac's folder changed shape): the old mount goes.
    if let Some(old) = table.remove(name) {
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
    let overlay = cmux_projection::overlay::Overlay::open(
        Arc::new(manifest),
        state,
        fetch,
        (meta.uid(), meta.gid()),
    )
    .map_err(|error| io("opening the projection", &format!("{error:#}")))?;
    let overlay = Arc::new(overlay);
    let mounted = cmux_projection::mount::mount(overlay.clone(), at)
        .map_err(|error| ("projection.mount_failed", format!("{error:#}")))?;
    // Pinned folders an earlier mount recorded are fetched whole in the background, so they read
    // with the Mac away again (a new manifest starts a fresh cache). Mac away: it stops at the
    // first absence, and the next mount tries again.
    if !overlay.pins().is_empty() {
        let pinned = overlay.clone();
        let _ = std::thread::Builder::new()
            .name("projection-pins".into())
            .spawn(move || drop(pinned.hydrate_pins()));
    }
    let projected = Arc::new(Projected {
        link,
        digest,
        at: at.to_path_buf(),
        mounted: Mutex::new(Some(mounted)),
    });
    table.insert(name.to_owned(), projected.clone());
    // RFD 0007, seed bundles: with `CMUX_PROJECTION_GIT_SWAP=1`, a `.git` with a public remote
    // takes its objects from the remote (a blobless fetch the machine makes) and only what the
    // Mac has unpushed over the link, then switches from projection to that repository. Opt-in
    // until Bring Back reads the machine's repository after a swap.
    if std::env::var_os("CMUX_PROJECTION_GIT_SWAP").is_some_and(|value| value == "1") {
        let swapping = projected.clone();
        let (overlay, at, state) = (overlay.clone(), at.to_path_buf(), state.to_path_buf());
        let _ = std::thread::Builder::new().name("projection-git-swap".into()).spawn(move || {
            let forget =
                || match swapping.mounted.lock().unwrap_or_else(PoisonError::into_inner).as_ref() {
                    Some(mounted) => mounted.forget_entry(overlay.root(), ".git"),
                    None => Ok(()),
                };
            match cmux_projection::git_swap::run(&overlay, &forget, &at, &state) {
                Ok(outcome) => eprintln!("cmux projection: {} .git: {outcome:?}", at.display()),
                Err(error) => {
                    eprintln!("cmux projection: {} .git stays projected: {error:#}", at.display())
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
) -> Result<Arc<Projected>, Refusal> {
    Err(("projection.unavailable", "projected folders mount on Linux only".into()))
}

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
