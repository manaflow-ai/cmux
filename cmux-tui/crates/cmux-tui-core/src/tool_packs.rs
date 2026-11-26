//! Tools few people use, downloaded on first use (CMUX-570, app size). A NIGHTLY's signed app
//! ships `Contents/Resources/bin/cmux-mobile-host` (the iPhone host, which runs only while Allow
//! iPhone Connections is on) as a link to `cmux`, and the pin `Contents/Resources/tool-packs.json`
//! (scripts/cmux-next/tool-packs.py split):
//!
//! ```json
//! {"version": 1, "tools": {"cmux-mobile-host": {
//!   "url": "https://files-next.cmux.com/tool-packs/<sha>/cmux-mobile-host.tar.zst",
//!   "sha256": "<the pack's>", "size": 3757692,
//!   "file_sha256": "<the tool's own>", "file_size": 10698624}}}
//! ```
//!
//! `cmux` run under a pinned tool's name ([`run_as`], from main's folded hosts) puts the tool in
//! the user's cache once, at `<cache>/<pack sha256>/<name>`, and runs it as its child with the
//! same arguments and standard streams, passing on SIGTERM and SIGHUP and exiting with its status,
//! so every caller (the app's `IPhoneHostService`, scripts) runs `bin/<name>` as before. The first run downloads the pack with the language packs' installer
//! ([`crate::language_packs::install`]: `files-next.cmux.com` only, no redirect, 120 s, exactly
//! the pinned size and SHA-256, unpacked into a private folder and renamed into place), then checks
//! the tool's own size and SHA-256 against the pin before it marks it executable. The tool keeps
//! the Developer ID signature it was signed with inside the app (the split runs after the inner
//! code is signed); the pin it is checked against is sealed by the app's signature.
//!
//! An app without the pin, or a pin without the name, has the tool in `bin/` itself: nothing here
//! runs. The daemon admits a peer as the bundled iPhone host by its path
//! ([`verified`], `server/origin_gate.rs`), so the cached copy must still hash to the pin.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde::Deserialize;

use crate::language_packs::{self, Code};

/// The pin's file name in `Contents/Resources`.
pub(crate) const PIN_NAME: &str = "tool-packs.json";
/// The tools a pin may name: the names `cmux` answers to (main's `run_folded_host`).
pub(crate) const TOOLS: [&str; 1] = ["cmux-mobile-host"];
/// Overrides the cache folder (tests, and a person who wants it elsewhere); absolute.
pub(crate) const CACHE_ENV: &str = "CMUX_TOOL_PACKS_CACHE";
/// The only pin version this build reads.
const PIN_VERSION: u32 = 1;
/// The largest pin read; the real one is a few hundred bytes per tool.
const PIN_READ_LIMIT: u64 = 64 * 1024;
/// The largest tool a pin may name.
const TOOL_SIZE_LIMIT: u64 = 512 * 1024 * 1024;
/// A pack folder no run of any app used for this long is removed when another tool is put in
/// place: each NIGHTLY whose tool changed leaves one, and the cache must not grow with every update.
const UNUSED: Duration = Duration::from_secs(24 * 60 * 60);
/// Touched on every run of a pack's tool (its mtime is the last use).
const USED: &str = ".used";
/// The installer's unfinished folders and downloads (`language_packs::install`).
const PARTIAL: &str = ".partial-";
/// A `.partial-*` this old is no live run's.
const STALE_PARTIAL: Duration = Duration::from_secs(60 * 60);
/// The exit status when the tool cannot be had (sysexits `EX_UNAVAILABLE`).
pub(crate) const UNAVAILABLE: i32 = 69;

/// The pin the build writes into the signed app.
#[derive(Debug, Clone, Deserialize)]
struct Pin {
    version: u32,
    #[serde(default)]
    tools: BTreeMap<String, Tool>,
}

/// One tool's pinned pack.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(crate) struct Tool {
    pub(crate) url: String,
    pub(crate) sha256: String,
    pub(crate) size: u64,
    pub(crate) file_sha256: String,
    pub(crate) file_size: u64,
}

impl Tool {
    /// The language packs' installer's view of this pack (strings only, no Chromium pak).
    fn pack(&self) -> language_packs::Pack {
        language_packs::Pack {
            url: self.url.clone(),
            sha256: self.sha256.clone(),
            size: self.size,
            chromium: None,
            strings: true,
        }
    }

    fn well_formed(&self) -> bool {
        language_packs::is_sha256(&self.sha256)
            && language_packs::is_sha256(&self.file_sha256)
            && self.size > 0
            && self.size <= TOOL_SIZE_LIMIT
            && self.file_size > 0
            && self.file_size <= TOOL_SIZE_LIMIT
            && language_packs::allowed_url(&self.url)
    }
}

/// Why a tool cannot be had, with the sentence a person reads (it names no path).
pub(crate) fn message(code: Code) -> &'static str {
    match code {
        Code::Offline => {
            "cmux could not download this part of the app and will try again next time."
        }
        Code::Verify => "The downloaded part of the app did not match what this cmux expects.",
        Code::BadManifest => "This version of cmux lists a part of the app it cannot use.",
        Code::Io => "cmux could not save this part of the app on this Mac.",
    }
}

/// The pin's tool `name` in `bytes`: `Ok(None)` when the pin does not name it, an error when the
/// pin is not one this build reads or the tool is not well formed.
fn parse(bytes: &[u8], name: &str) -> Result<Option<Tool>, Code> {
    let pin: Pin = serde_json::from_slice(bytes).map_err(|_| Code::BadManifest)?;
    if pin.version != PIN_VERSION {
        return Err(Code::BadManifest);
    }
    let Some(tool) = pin.tools.get(name) else { return Ok(None) };
    if !TOOLS.contains(&name) || !tool.well_formed() {
        return Err(Code::BadManifest);
    }
    Ok(Some(tool.clone()))
}

/// The pin beside `bin_dir` (`Contents/Resources/bin` -> `Contents/Resources/tool-packs.json`):
/// its tool `name`, `Ok(None)` when there is no pin or it does not name the tool.
pub(crate) fn pinned(bin_dir: &Path, name: &str) -> Result<Option<Tool>, Code> {
    let Some(resources) = bin_dir.parent() else { return Ok(None) };
    let file = match std::fs::File::open(resources.join(PIN_NAME)) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(Code::Io),
    };
    let mut bytes = Vec::new();
    file.take(PIN_READ_LIMIT + 1).read_to_end(&mut bytes).map_err(|_| Code::Io)?;
    if bytes.len() as u64 > PIN_READ_LIMIT {
        return Err(Code::BadManifest);
    }
    parse(&bytes, name)
}

/// The tool packs' cache: `CMUX_TOOL_PACKS_CACHE` when absolute, else `~/Library/Caches/cmux-next/
/// tool-packs` on macOS and `${XDG_CACHE_HOME:-~/.cache}/cmux/tool-packs` elsewhere.
pub(crate) fn cache_dir() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os(CACHE_ENV).map(PathBuf::from).filter(|p| p.is_absolute()) {
        return Some(path);
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).filter(|p| p.is_absolute())?;
    let base = if cfg!(target_os = "macos") {
        home.join("Library").join("Caches")
    } else {
        std::env::var_os("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .unwrap_or_else(|| home.join(".cache"))
    };
    Some(base.join(cmux_config::NEXT_DIR).join("tool-packs"))
}

/// Where `tool` named `name` is once it is in `cache`.
pub(crate) fn tool_path(cache: &Path, tool: &Tool, name: &str) -> PathBuf {
    cache.join(&tool.sha256).join(name)
}

/// Whether the file at `path` is the pinned tool: a regular file of the pinned size whose SHA-256
/// is the pinned one.
pub(crate) fn matches_pin(path: &Path, tool: &Tool) -> bool {
    use sha2::{Digest as _, Sha256};
    let Ok(meta) = std::fs::symlink_metadata(path) else { return false };
    if !meta.is_file() || meta.len() != tool.file_size {
        return false;
    }
    let Ok(mut file) = std::fs::File::open(path) else { return false };
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 256 * 1024];
    loop {
        match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => hasher.update(buffer.get(..read).unwrap_or_default()),
            Err(_) => return false,
        }
    }
    language_packs::hex(&hasher.finalize()) == tool.file_sha256
}

/// The tool `name` in `cache`, put there first when it is not: downloaded, checked against the
/// pin and marked executable (0755). A folder already marked complete is answered without a
/// network or a hash (the installer checked it; the daemon checks again before it trusts it).
pub(crate) fn ensure(cache: &Path, tool: &Tool, name: &str) -> Result<PathBuf, Code> {
    let root = cache.join(&tool.sha256);
    let path = root.join(name);
    if !(language_packs::is_complete(&root) && is_tool_file(&path)) {
        if language_packs::is_complete(&root) {
            // A whole folder whose tool is gone or changed type: made again.
            let _ = std::fs::remove_dir_all(&root);
        }
        let installed = language_packs::install(cache, &tool.pack())?;
        let path = installed.join(name);
        if !matches_pin(&path, tool) {
            let _ = std::fs::remove_dir_all(&installed);
            return Err(Code::Verify);
        }
        prune(cache, &tool.sha256, SystemTime::now());
    }
    set_executable(&path)?;
    // The last use, for prune; a failure only makes the folder look older.
    let _ = std::fs::File::create(root.join(USED));
    Ok(path)
}

fn is_tool_file(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|meta| meta.is_file())
}

fn set_executable(path: &Path) -> Result<(), Code> {
    use std::os::unix::fs::PermissionsExt as _;
    let meta = std::fs::metadata(path).map_err(|_| Code::Io)?;
    if meta.permissions().mode() & 0o777 == 0o755 {
        return Ok(());
    }
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).map_err(|_| Code::Io)
}

/// Removes from `cache` each pack folder but `keep` that no run used within [`UNUSED`] at `now`
/// (its `.used`, else the folder's own mtime). Links are never followed; a failure is left for
/// the next install. A `.partial-*` an installer left (a run killed mid-download) goes after an hour.
pub(crate) fn prune(cache: &Path, keep: &str, now: SystemTime) {
    let Ok(entries) = std::fs::read_dir(cache) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if name.starts_with(PARTIAL) {
            let stale = entry
                .metadata()
                .and_then(|meta| meta.modified())
                .ok()
                .and_then(|modified| now.duration_since(modified).ok())
                .is_some_and(|age| age > STALE_PARTIAL);
            if stale {
                let path = entry.path();
                let _ = std::fs::remove_dir_all(&path).or_else(|_| std::fs::remove_file(&path));
            }
            continue;
        }
        if name == keep || !language_packs::is_sha256(name) {
            continue;
        }
        if !entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            continue;
        }
        let path = entry.path();
        let used = std::fs::metadata(path.join(USED))
            .or_else(|_| std::fs::symlink_metadata(&path))
            .and_then(|meta| meta.modified())
            .ok();
        let unused =
            used.and_then(|used| now.duration_since(used).ok()).is_some_and(|age| age > UNUSED);
        if unused {
            let _ = std::fs::remove_dir_all(&path);
        }
    }
}

/// A checked tool file: its real path, device, inode, size, mtime and ctime.
type Key = (PathBuf, u64, u64, u64, i64, i64, i64, i64);

/// The pinned tool `name` of the app whose `bin` folder is `bin_dir`, by real path, when it is in
/// the cache and its bytes hash to the pin: what the daemon admits as that tool
/// (`server/origin_gate.rs`). Nothing is downloaded. The hash is read again whenever the file's
/// device, inode, size, mtime or ctime changed since the last check; any failure is `None`.
pub(crate) fn verified(bin_dir: &Path, name: &str) -> Option<PathBuf> {
    use std::sync::Mutex;
    static CHECKED: Mutex<Option<Key>> = Mutex::new(None);
    verified_in(&cache_dir()?, bin_dir, name, &CHECKED)
}

/// [`verified`] with the cache and the last check given.
fn verified_in(
    cache: &Path,
    bin_dir: &Path,
    name: &str,
    checked: &std::sync::Mutex<Option<Key>>,
) -> Option<PathBuf> {
    use std::os::unix::fs::MetadataExt as _;
    let tool = pinned(bin_dir, name).ok()??;
    let path = std::fs::canonicalize(tool_path(cache, &tool, name)).ok()?;
    let meta = std::fs::symlink_metadata(&path).ok()?;
    if !meta.is_file() {
        return None;
    }
    let key: Key = (
        path.clone(),
        meta.dev(),
        meta.ino(),
        meta.size(),
        meta.mtime(),
        meta.mtime_nsec(),
        meta.ctime(),
        meta.ctime_nsec(),
    );
    let mut checked = checked.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if checked.as_ref() == Some(&key) {
        return Some(path);
    }
    if !matches_pin(&path, &tool) {
        return None;
    }
    *checked = Some(key);
    Some(path)
}

/// `cmux` run as `bin/<name>`: `None` when `name` is no tool `cmux` answers to (the caller goes
/// on as `cmux`), else the tool's exit status (128 + the signal that ended it), or
/// [`UNAVAILABLE`] when it could not be had. The tool runs as this process's child with the same
/// arguments, environment and standard streams; a SIGTERM or SIGHUP sent to this process is passed
/// on to it. (A child, not an exec: a cmux crate starts processes through `cmux_process` only,
/// scripts/cmux-next/check-no-raw-spawn.py.)
pub fn run_as(name: &str, exe: &Path) -> Option<i32> {
    if !TOOLS.contains(&name) {
        return None;
    }
    let bin_dir = exe.parent()?;
    let failed = |code: Code| {
        eprintln!("{name}: {} ({})", message(code), code.wire_name());
        Some(UNAVAILABLE)
    };
    let tool = match pinned(bin_dir, name) {
        Ok(Some(tool)) => tool,
        // A link to cmux with no pin for it: nothing to run.
        Ok(None) => return failed(Code::BadManifest),
        Err(code) => return failed(code),
    };
    let Some(cache) = cache_dir() else { return failed(Code::Io) };
    let path = match ensure(&cache, &tool, name) {
        Ok(path) => path,
        Err(code) => return failed(code),
    };
    let mut args = std::env::args_os();
    let argv0 = args.next().unwrap_or_else(|| name.into());
    let mut child = match cmux_process::Command::new(&path).arg0(argv0).args(args).spawn() {
        Ok(child) => child,
        Err(error) => {
            eprintln!("{name}: could not start the downloaded tool: {error}");
            return Some(UNAVAILABLE);
        }
    };
    forward_signals(child.id());
    match child.wait() {
        Ok(status) => {
            use std::os::unix::process::ExitStatusExt as _;
            Some(status.code().or_else(|| status.signal().map(|signal| 128 + signal)).unwrap_or(1))
        }
        Err(error) => {
            eprintln!("{name}: lost the downloaded tool: {error}");
            Some(UNAVAILABLE)
        }
    }
}

/// The child [`forward`] passes signals to (0: none yet).
static CHILD: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);

/// Passes SIGTERM and SIGHUP on to the child `pid` (the app stops its iPhone host with SIGTERM).
fn forward_signals(pid: u32) {
    let Ok(pid) = i32::try_from(pid) else { return };
    CHILD.store(pid, std::sync::atomic::Ordering::SeqCst);
    for signal in [libc::SIGTERM, libc::SIGHUP] {
        // SAFETY: `forward` is async-signal-safe (an atomic load and kill(2)); the action is
        // zeroed and then filled in, as sigaction(2) asks.
        unsafe {
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = forward as *const () as libc::sighandler_t;
            action.sa_flags = libc::SA_RESTART;
            libc::sigemptyset(&raw mut action.sa_mask);
            libc::sigaction(signal, &raw const action, std::ptr::null_mut());
        }
    }
}

extern "C" fn forward(signal: libc::c_int) {
    let pid = CHILD.load(std::sync::atomic::Ordering::SeqCst);
    if pid > 0 {
        // SAFETY: kill(2) is async-signal-safe.
        unsafe {
            libc::kill(pid, signal);
        }
    }
}

#[cfg(test)]
#[path = "tool_packs/tests.rs"]
mod tests;
