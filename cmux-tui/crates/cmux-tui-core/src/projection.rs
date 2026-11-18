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
//!   "upper", "whiteouts"}}`, then that many bytes of the encoded `cmux_projection::layer::Layer`;
//! - `{"id", "cmd": "projection.files", "name", "paths_bytes"}`, then that many bytes of upper
//!   paths, one per line: answered `{"id", "ok": true, "data": {}}`, then each file as
//!   `cmux_projection::layer::send_files` writes it;
//! - `{"id", "cmd": "projection.drop", "name"}`, once the Mac applied it all: unmounts the
//!   projection and deletes its state (upper layer, whiteouts, cache); `{"id", "ok": true,
//!   "data": {"dropped"}}`.
//!
//! Served where `fs-v1` is (a Cloud host), on Linux; anywhere else a dial is answered
//! `projection.unavailable`.

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
    [SERVE, LAYER, FILES, DROP].into_iter().find(|known| *known == cmd)
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
    let id = serde_json::from_str::<Value>(first)
        .ok()
        .and_then(|value| value.get("id").cloned())
        .unwrap_or(Value::Null);
    let Ok(reader) = stream.try_clone() else { return };
    let mut reader = std::io::Cursor::new(leftover).chain(reader);
    let mut writer = stream;
    if let Some(cmd) = frame_command(first).filter(|cmd| *cmd != SERVE) {
        if let Err((code, message)) = way_back(cmd, first, &id, &mut reader, &mut writer) {
            let _ = send_line(
                &mut writer,
                &json!({"id": id, "ok": false, "error": message, "error_code": code}),
            );
        }
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
    let _ = stream.set_read_timeout(None);
    let _ = stream.set_write_timeout(Some(std::time::Duration::from_secs(60)));
    let Ok(answers_to) = stream.try_clone() else { return };
    projected.link.serve(reader, answers_to);
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

/// Serves one of Bring Back's dials (module docs). An error before the answer line is the
/// caller's to send.
fn way_back(
    cmd: &str,
    first: &str,
    id: &Value,
    reader: &mut impl Read,
    writer: &mut impl Write,
) -> Result<(), Refusal> {
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
            let layer =
                cmux_projection::layer::Layer::collect(&state).map_err(|error| io(&error))?;
            let encoded = layer.encode().map_err(|error| io(&error))?;
            let data = json!({"bytes": encoded.len(), "upper": layer.upper.len(),
                              "whiteouts": layer.whiteouts.len()});
            send_line(writer, &json!({"id": id, "ok": true, "data": data}))
                .and_then(|()| writer.write_all(&encoded))
                .and_then(|()| writer.flush())
                .map_err(|error| io(&error))
                .or(Ok(()))
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
            if send_line(writer, &json!({"id": id, "ok": true, "data": {}})).is_err() {
                return Ok(());
            }
            // Past the answer line an error just ends the stream; the Mac sees it short.
            let mut buffered = std::io::BufWriter::with_capacity(256 * 1024, writer);
            let _ = cmux_projection::layer::send_files(&state, &paths, &mut buffered);
            Ok(())
        }
        _ => {
            let old =
                projections().lock().unwrap_or_else(PoisonError::into_inner).remove(&line.name);
            if let Some(old) = old {
                old.link.detach();
                #[cfg(target_os = "linux")]
                if let Some(mounted) =
                    old.mounted.lock().unwrap_or_else(PoisonError::into_inner).take()
                {
                    mounted.unmount();
                }
            }
            let dropped = state.is_dir();
            if dropped {
                std::fs::remove_dir_all(&state).map_err(|error| io(&error))?;
            }
            let _ = send_line(writer, &json!({"id": id, "ok": true, "data": {"dropped": dropped}}));
            Ok(())
        }
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
    if encoded.is_empty() {
        let Some(projected) = existing.filter(|projected| projected.at == at) else {
            return Err(("projection.unknown", format!("no projection {} here", line.name)));
        };
        return Ok((projected, json!({"at": at, "attached": true})));
    }
    let digest = fnv(&encoded);
    if let Some(projected) =
        existing.filter(|projected| projected.digest == digest && projected.at == at)
    {
        return Ok((projected, json!({"at": at, "attached": true})));
    }
    let started = std::time::Instant::now();
    let manifest = cmux_projection::manifest::Manifest::decode(&encoded)
        .map_err(|error| ("projection.params_invalid", format!("bad manifest: {error:#}")))?;
    let (files, bytes) = manifest.totals();
    let entries = manifest.len();
    // The upper layer and the cache: this daemon's own state, beside the folder roots, never in them.
    let state = state_of(&line.name)?;
    let projected = mount(&line.name, manifest, &state, &at, digest)?;
    let data = json!({
        "at": at,
        "entries": entries,
        "files": files,
        "bytes": bytes,
        "mount_ms": u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
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
    let mounted = cmux_projection::mount::mount(Arc::new(overlay), at)
        .map_err(|error| ("projection.mount_failed", format!("{error:#}")))?;
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
