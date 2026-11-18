//! `projection-v1`: a folder of the person's Mac projected onto this Cloud machine (RFD 0007,
//! `cmux-projection`). The Mac sends a stat-only manifest; this daemon mounts it (FUSE, Linux)
//! at the chat's folder, answers every `stat` and listing from it, fetches a file's bytes from the
//! Mac on first read, and keeps everything written there on this machine's disk.
//!
//! Wire: a link dial whose first line is
//! `{"id", "cmd": "projection.serve", "name", "at", "manifest_bytes"}` is followed by that many
//! bytes of the encoded manifest (none to attach again to the projection `name` already mounted),
//! or, with `"base"` and `"target"` (manifest ids in hex), that many bytes of a delta of a manifest
//! this daemon kept from an earlier dial (`projection.no_base` when it has not kept it).
//! The daemon mounts it at `at` (a folder below the machine's file roots, empty or missing),
//! answers one line, `{"id", "ok": true, "data": {"at", "entries", "files", "bytes", "mount_ms"}}`
//! or `{"id", "ok": false, "error", "error_code"}`, and from then on the dial carries the
//! projection's asks and the Mac's answers (`cmux_projection::wire`) until the Mac closes it.
//! The mount stays when the dial ends; reads wait a few seconds for the Mac's next dial, then fail
//! with "Host is down".
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
/// The largest encoded manifest a dial may send (a 1.1 M-entry folder encodes to 14 MB). The Mac
/// checks it before it dials, so a folder past it goes as a copy without a refused dial.
pub const MAX_MANIFEST_BYTES: u64 = 512 * 1024 * 1024;

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
    /// The id ([`cmux_projection::manifest::Manifest::id`], hex) of a manifest this machine has
    /// had, when the bytes are a delta of it ([`cmux_projection::manifest::Delta`]).
    #[serde(default)]
    base: Option<String>,
    /// The id of the manifest the dial ends with (a delta applied must come to it): a later dial
    /// with the same id attaches to the mount, whole or as a delta.
    #[serde(default)]
    target: Option<String>,
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

/// `projection.serve` when `line` asks for it, exactly.
#[must_use]
pub fn frame_command(line: &str) -> Option<&'static str> {
    if !line.contains(SERVE) {
        return None;
    }
    let value: Value = serde_json::from_str(line).ok()?;
    let object = value.as_object()?;
    if object.contains_key("protocol") {
        return None;
    }
    (object.get("cmd")?.as_str()? == SERVE).then_some(SERVE)
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
    if line.name.is_empty()
        || line.name.len() > 64
        || !line.name.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte))
    {
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
    if encoded.is_empty() {
        let Some(projected) = existing.filter(|projected| projected.at == at) else {
            return Err(("projection.unknown", format!("no projection {} here", line.name)));
        };
        return Ok((projected, json!({"at": at, "attached": true})));
    }
    let bases = crate::platform::workspace_state_dir()
        .map(|dir| dir.join("projections").join(BASES))
        .ok_or(("projection.unavailable", "no state folder".to_owned()))?;
    let digest = match &line.target {
        Some(target) => u64::from_str_radix(target, 16)
            .map_err(|_| ("projection.params_invalid", "a bad target id".to_owned()))?,
        None => fnv(&encoded),
    };
    if let Some(projected) =
        existing.filter(|projected| projected.digest == digest && projected.at == at)
    {
        return Ok((projected, json!({"at": at, "attached": true})));
    }
    let started = std::time::Instant::now();
    let manifest = match (&line.base, &line.target) {
        (Some(base), Some(_)) => from_delta(&bases, base, digest, &encoded)?,
        (None, _) => cmux_projection::manifest::Manifest::decode(&encoded)
            .map_err(|error| ("projection.params_invalid", format!("bad manifest: {error:#}")))?,
        (Some(_), None) => {
            return Err(("projection.params_invalid", "a delta names its target".into()));
        }
    };
    keep_base(&bases, &manifest, line.base.is_none().then_some(encoded));
    let (files, bytes) = manifest.totals();
    let entries = manifest.len();
    // The upper layer and the cache: this daemon's own state, beside the folder roots, never in them.
    let state = crate::platform::workspace_state_dir()
        .map(|dir| dir.join("projections").join(&line.name))
        .ok_or(("projection.unavailable", "no state folder".to_owned()))?;
    let projected = mount(&line.name, manifest, &state, &at, digest)?;
    let data = json!({
        "at": at,
        "entries": entries,
        "files": files,
        "bytes": bytes,
        "mount_ms": u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
        "delta": line.base.is_some(),
    });
    Ok((projected, data))
}

/// Where this daemon keeps the last manifests it mounted, by id, for a later dial to send a delta
/// of one ([`cmux_projection::manifest::Delta`]): a second chat on the same folder sends what
/// changed, not the whole manifest again.
const BASES: &str = ".bases";
/// How many manifests it keeps.
const KEPT_BASES: usize = 8;

fn base_path(bases: &Path, id: u64) -> PathBuf {
    bases.join(format!("{id:016x}.manifest"))
}

/// The manifest the delta `encoded` makes of base `base` (hex id), checked to be `target`.
/// `projection.no_base` when this machine no longer has that base (the Mac then sends it whole).
fn from_delta(
    bases: &Path,
    base: &str,
    target: u64,
    encoded: &[u8],
) -> Result<cmux_projection::manifest::Manifest, Refusal> {
    use cmux_projection::manifest::{Delta, Manifest};
    let no_base = |why: String| ("projection.no_base", why);
    let id = u64::from_str_radix(base, 16).map_err(|_| no_base("a bad base id".into()))?;
    let bytes = std::fs::read(base_path(bases, id))
        .map_err(|_| no_base(format!("no manifest {base} here")))?;
    let base = Manifest::decode(&bytes).map_err(|error| no_base(format!("{error:#}")))?;
    let delta = Delta::decode(encoded)
        .map_err(|error| ("projection.params_invalid", format!("bad delta: {error:#}")))?;
    let manifest = base.apply(&delta).map_err(|error| no_base(format!("{error:#}")))?;
    if manifest.id().ok() != Some(target) {
        return Err(no_base("the delta did not make the Mac's manifest".into()));
    }
    Ok(manifest)
}

/// Keeps `manifest` (its wire bytes `encoded` when the dial sent them whole) as a base for a
/// later delta, and only the newest [`KEPT_BASES`]. A delta's result is encoded again here
/// (about 175 ms for 1.5 M files), before the answer, so the next chat's delta finds it.
fn keep_base(
    bases: &Path,
    manifest: &cmux_projection::manifest::Manifest,
    encoded: Option<Vec<u8>>,
) {
    let Ok(id) = manifest.id() else { return };
    let bytes = match encoded {
        Some(bytes) => bytes,
        None => match manifest.encode() {
            Ok(bytes) => bytes,
            Err(_) => return,
        },
    };
    store_base(bases, id, &bytes);
}

fn store_base(bases: &Path, id: u64, bytes: &[u8]) {
    if std::fs::create_dir_all(bases).is_err() {
        return;
    }
    let path = base_path(bases, id);
    let temp = path.with_extension(format!("tmp{}", std::process::id()));
    if std::fs::write(&temp, bytes).is_err() || std::fs::rename(&temp, &path).is_err() {
        let _ = std::fs::remove_file(&temp);
        return;
    }
    let mut kept: Vec<(std::time::SystemTime, PathBuf)> = std::fs::read_dir(bases)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "manifest"))
        .filter_map(|entry| Some((entry.metadata().ok()?.modified().ok()?, entry.path())))
        .collect();
    kept.sort();
    let old = kept.len().saturating_sub(KEPT_BASES);
    for (_, path) in kept.into_iter().take(old) {
        let _ = std::fs::remove_file(path);
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
    let mounted = cmux_projection::mount::mount(Arc::new(overlay), at)
        .map_err(|error| ("projection.mount_failed", format!("{error:#}")))?;
    // Where it is mounted, for git's fsmonitor hook (`cmux link project fsmonitor`) to find it.
    {
        use std::os::unix::ffi::OsStrExt as _;
        let _ = std::fs::write(
            state.join(cmux_projection::fsmonitor::MOUNT_POINT_FILE),
            at.as_os_str().as_bytes(),
        );
    }
    let projected = Arc::new(Projected {
        link,
        digest,
        at: at.to_path_buf(),
        mounted: Mutex::new(Some(mounted)),
    });
    table.insert(name.to_owned(), projected.clone());
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

/// FNV-1a of the manifest's bytes: which manifest a mount serves.
fn fnv(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

#[cfg(test)]
#[path = "projection_tests.rs"]
mod tests;
