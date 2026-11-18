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
//! Served where `fs-v1` is (a Cloud host), on Linux; anywhere else a dial is answered
//! `projection.unavailable`.
//!
//! Freeing what a chat wrote (`cmux_projection::state`, `cmux_projection::reap`): three one-line
//! dials, each answered with one line, end a projection's state on this machine.
//! - `{"id", "cmd": "projection.mark", "name"}` answers `{"mark"}`, the upper layer as it is now.
//!   Bring Back takes it before it reads the upper layer.
//! - `{"id", "cmd": "projection.brought_back", "name", "mark"}`: Bring Back carried the upper
//!   layer, as it was at `mark`, to the Mac. The record says so (persisted), and while nothing was
//!   written since, the projection ends and its state folder goes: `{"freed_bytes"}`. An edit
//!   since is `projection.edited_since` (with the new `mark`), and everything stays.
//! - `{"id", "cmd": "projection.release", "name", "why": "archived" | "deleted"}`: the chat is
//!   gone. The record says so, the projection ends, its state and empty mount point go.
//!
//! The reaper ([`start_reaper`]) frees the rest on its own: at the daemon's start and every
//! [`REAP_EVERY`], it reads this machine's chats from acpmux and runs one bounded
//! `cmux_projection::reap::pass` over the projections, the chats' copies under `$HOME/work/chats`
//! and their repositories under `$HOME/chats`, and logs each reclaim with the bytes it freed.

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
/// What the upper layer is now (Bring Back reads it first).
pub const MARK: &str = "projection.mark";
/// Bring Back carried the upper layer to the Mac: free it.
pub const BROUGHT_BACK: &str = "projection.brought_back";
/// The chat is archived or deleted: free everything.
pub const RELEASE: &str = "projection.release";
/// The ops a projection dial may carry.
const OPS: [&str; 4] = [SERVE, MARK, BROUGHT_BACK, RELEASE];
/// How long after the daemon starts the first reaper pass runs (acpmux starts beside it).
const REAP_FIRST_AFTER: std::time::Duration = std::time::Duration::from_secs(60);
/// How often the reaper runs.
pub const REAP_EVERY: std::time::Duration = std::time::Duration::from_secs(30 * 60);
/// The most one reaper pass waits for the chat list.
const CHATS_WITHIN: std::time::Duration = std::time::Duration::from_secs(20);
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

/// The projection op `line` asks for, exactly ([`SERVE`], [`MARK`], [`BROUGHT_BACK`],
/// [`RELEASE`]).
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
    OPS.into_iter().find(|op| *op == cmd)
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
    if frame_command(first) != Some(SERVE) {
        let answer = match control(first) {
            Ok(data) => json!({"id": id, "ok": true, "data": data}),
            Err((code, message)) => {
                json!({"id": id, "ok": false, "error": message, "error_code": code})
            }
        };
        let mut writer = stream;
        let _ = send_line(&mut writer, &answer);
        return;
    }
    let Ok(reader) = stream.try_clone() else { return };
    let mut reader = std::io::Cursor::new(leftover).chain(reader);
    let mut writer = stream;
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
    valid_name(&line.name)?;
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
        attached(&line.name, &at);
        return Ok((projected, json!({"at": at, "attached": true})));
    }
    let digest = fnv(&encoded);
    if let Some(projected) =
        existing.filter(|projected| projected.digest == digest && projected.at == at)
    {
        attached(&line.name, &at);
        return Ok((projected, json!({"at": at, "attached": true})));
    }
    let started = std::time::Instant::now();
    let manifest = cmux_projection::manifest::Manifest::decode(&encoded)
        .map_err(|error| ("projection.params_invalid", format!("bad manifest: {error:#}")))?;
    let (files, bytes) = manifest.totals();
    let entries = manifest.len();
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

/// `name` as a projection's name: 1-64 letters, digits, `-` or `_` (it names a folder).
fn valid_name(name: &str) -> Result<(), Refusal> {
    if name.is_empty()
        || name.len() > 64
        || !name.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte))
    {
        return Err(("projection.params_invalid", "a name is 1-64 letters, digits, - or _".into()));
    }
    Ok(())
}

/// The folder this daemon keeps every projection's state in.
fn projections_dir() -> Option<PathBuf> {
    crate::platform::workspace_state_dir().map(|dir| dir.join("projections"))
}

/// Projection `name`'s state folder: the upper layer, the whiteouts, its record and the cache.
/// This daemon's own state, beside the folder roots, never in them.
fn state_of(name: &str) -> Result<PathBuf, Refusal> {
    projections_dir()
        .map(|dir| dir.join(name))
        .ok_or(("projection.unavailable", "no state folder".to_owned()))
}

/// The Mac dialed projection `name` again: its record says when (an orphan's grace counts from it).
fn attached(name: &str, at: &Path) {
    if let Ok(state) = state_of(name) {
        let now = cmux_projection::state::ms_of(std::time::SystemTime::now());
        let _ = cmux_projection::state::update(&state, at, |record| record.attached_ms = now);
    }
}

#[derive(Deserialize)]
struct ControlLine {
    cmd: String,
    name: String,
    #[serde(default)]
    mark: Option<String>,
    #[serde(default)]
    why: Option<String>,
}

/// Answers a [`MARK`], [`BROUGHT_BACK`] or [`RELEASE`] dial.
fn control(first: &str) -> Result<Value, Refusal> {
    use cmux_projection::reap::{self, Why};
    use cmux_projection::state::{self, BroughtBack, Release, Released};
    let line: ControlLine = serde_json::from_str(first)
        .map_err(|error| ("projection.params_invalid", format!("bad request: {error}")))?;
    valid_name(&line.name)?;
    let state = state_of(&line.name)?;
    let io = |error: std::io::Error| ("projection.io", error.to_string());
    // Every change below holds the table: no mount of this name starts meanwhile.
    let mut table = projections().lock().unwrap_or_else(PoisonError::into_inner);
    if !state.is_dir() {
        return Err(("projection.unknown", format!("no projection {} here", line.name)));
    }
    let at = state::read(&state).map(|record| record.at);
    let now = state::ms_of(std::time::SystemTime::now());
    let (why, freed) = match line.cmd.as_str() {
        MARK => return Ok(json!({"mark": state::mark(&state).map_err(io)?})),
        BROUGHT_BACK => {
            let Some(mark) = line.mark else {
                return Err(("projection.params_invalid", "brought_back needs the mark".into()));
            };
            let current = state::mark(&state).map_err(io)?;
            if current != mark {
                return Err((
                    "projection.edited_since",
                    format!("the upper layer changed since Bring Back read it; now {current}"),
                ));
            }
            let at = at.unwrap_or_default();
            state::update(&state, &at, |record| {
                record.brought_back = Some(BroughtBack { ms: now, mark: mark.clone() });
            })
            .map_err(io)?;
            end(&mut table, &line.name, Some(&at));
            (Why::BroughtBack, reap::free_projection(&state, Some(&at), Why::BroughtBack))
        }
        RELEASE => {
            let why = line.why.as_deref().unwrap_or("archived");
            let Some(release) = Release::parse(why) else {
                return Err(("projection.params_invalid", "why is archived or deleted".into()));
            };
            let at = at.unwrap_or_default();
            state::update(&state, &at, |record| {
                record.released = Some(Released { ms: now, why: release });
            })
            .map_err(io)?;
            end(&mut table, &line.name, Some(&at));
            (release.into(), reap::free_projection(&state, Some(&at), release.into()))
        }
        other => {
            return Err(("projection.params_invalid", format!("not a projection op: {other}")));
        }
    };
    drop(table);
    let freed = freed.map_err(io)?;
    eprintln!("cmux projection: freed {} ({}): {freed} bytes", state.display(), why.as_str());
    Ok(json!({"freed_bytes": freed}))
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

/// The reaper's view of this daemon's mounts ([`cmux_projection::reap::Live`]).
struct DaemonMounts;

impl cmux_projection::reap::Live for DaemonMounts {
    fn mounted(&self, name: &str) -> bool {
        projections().lock().unwrap_or_else(PoisonError::into_inner).contains_key(name)
    }

    fn holds(&self, folder: &Path) -> bool {
        projections()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .any(|projected| projected.at.starts_with(folder))
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

/// The places this machine keeps per-chat state: the projections' state, and on a Cloud host
/// (`home`: the file root) the chats' copies and added repositories.
fn reap_places(home: Option<&Path>) -> cmux_projection::reap::Places {
    cmux_projection::reap::Places {
        projections: projections_dir(),
        copies: home.map(|home| home.join("work").join("chats")),
        repos: home.map(|home| home.join("chats")),
    }
}

/// One reaper pass now: this machine's chats from acpmux at `acpmux_socket`, then
/// [`cmux_projection::reap::pass`]. Logs each reclaim.
pub fn reap_once(
    acpmux_socket: Option<&Path>,
    home: Option<&Path>,
) -> cmux_projection::reap::Report {
    let chats = acpmux_socket.map_or_else(cmux_projection::reap::Chats::unread, |socket| {
        crate::server::machine_chats(socket, CHATS_WITHIN)
    });
    let started = std::time::Instant::now();
    let report = cmux_projection::reap::pass(
        &reap_places(home),
        &chats,
        &DaemonMounts,
        std::time::SystemTime::now(),
        &cmux_projection::reap::Limits::default(),
    );
    for reclaim in &report.reclaimed {
        eprintln!(
            "cmux chat reaper: freed {} ({}): {} bytes",
            reclaim.path.display(),
            reclaim.why.as_str(),
            reclaim.bytes
        );
    }
    for (path, error) in &report.failed {
        eprintln!("cmux chat reaper: could not free {}: {error}", path.display());
    }
    if !report.reclaimed.is_empty() || report.deferred > 0 {
        eprintln!(
            "cmux chat reaper: pass freed {} bytes in {} folders ({} left for the next pass; chat \
             list {}) in {} ms",
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
/// [`REAP_EVERY`]. Only where this daemon serves the machine's files (a Cloud host).
pub fn start_reaper(acpmux_socket: Option<PathBuf>) {
    let Some(service) = crate::fs_ops::installed() else { return };
    let home = service.roots().canonical_paths().next().map(Path::to_path_buf);
    let spawned = std::thread::Builder::new().name("cmux-chat-reaper".into()).spawn(move || {
        std::thread::sleep(REAP_FIRST_AFTER);
        loop {
            reap_once(acpmux_socket.as_deref(), home.as_deref());
            std::thread::sleep(REAP_EVERY);
        }
    });
    if let Err(error) = spawned {
        eprintln!("cmux chat reaper: not started: {error}");
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
    let projected = Arc::new(Projected {
        link,
        digest,
        at: at.to_path_buf(),
        mounted: Mutex::new(Some(mounted)),
    });
    table.insert(name.to_owned(), projected.clone());
    // The record the reaper reads: where it is, since when, and a release undone (a dial again
    // means the chat is live). A record that cannot be written leaves the state unfreeable by
    // an archived chat's folder, never freed early.
    let now = cmux_projection::state::ms_of(std::time::SystemTime::now());
    let _ = cmux_projection::state::update(state, at, |record| {
        if record.created_ms == 0 {
            record.created_ms = now;
        }
        record.at = at.to_path_buf();
        record.attached_ms = now;
        record.released = None;
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

/// FNV-1a of the manifest's bytes: which manifest a mount serves.
fn fnv(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

#[cfg(test)]
#[path = "projection_tests.rs"]
mod tests;
