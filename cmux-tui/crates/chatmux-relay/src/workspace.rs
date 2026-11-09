//! Workspace verbs (relay wire v6, the pane data plane): one typed
//! `workspace_request` -> `workspace_result` round trip per op, plus the
//! dispatch seam the `fs_watch_*` stream family (watch.rs) and the preview
//! proxy (preview_proxy.rs) hang off.
//!
//! Behavior contract: chatmux `packages/protocol/src/relay.ts` (vendored
//! serde types in relay_wire.rs) and the JS relay's actions.mjs discipline:
//! trust is re-checked HERE from the machine's own state (observe trust
//! refuses the mutating ops), every path is scoped against BOTH the
//! server-echoed allowedRoots and the machine's own `--allow-root` config
//! (lexically first, then again on the canonical/realpath), and every
//! answer is capped by the named WORKSPACE_* limits so one result can never
//! flood the socket. The chatmux conformance harness
//! (`apps/backend/test/e2e-workspace.ts`) is the cross-language gate.

use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde_json::Value;
use sha2::{Digest as _, Sha256};
use tokio::io::AsyncReadExt as _;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio_util::sync::CancellationToken;

use crate::actions::{
    RootLists, ensure_scoped_file_roots_available, process_env_snapshot, scrubbed_env,
    validate_request_path as validate_action_path,
};
use crate::preview_proxy::PreviewRegistry;
use crate::relay_wire as wire;
use crate::session::OutboundSink;
use crate::watch::WatchRegistry;

mod git;
use git::{run_git_diff_with_cancel_until, run_git_status_with_cancel_until};

/// Every v6 frame this module emits carries the workspace dialect
/// (`RELAY_PROTOCOL_WORKSPACE_VERSION` in chatmux packages/protocol).
pub const WORKSPACE_FRAME_VERSION: i64 = 6;

// Named caps, mirrored from chatmux packages/protocol/src/relay.ts
// (WORKSPACE_*). The server validates request-side; the relay re-clamps
// here so a buggy or hostile server still cannot request unbounded output.
pub const TREE_MAX_ENTRIES: i64 = 20_000;
pub const READ_MAX_BYTES: i64 = 2_000_000;
pub const WRITE_MAX_BYTES: usize = 2_000_000;
pub const SEARCH_MAX_RESULTS: i64 = 1_000;
/// Per-match line text ceiling, in UTF-16 code units: the consumers are
/// JS/web clients, so "characters" on this wire means JS string units.
pub const SEARCH_MAX_TEXT_UNITS: usize = 1_000;
pub const STATUS_MAX_ENTRIES: usize = 5_000;
pub const DIFF_MAX_BYTES: usize = 2_000_000;
pub const MAX_PATH_CHARS: usize = 4_096;
const MAX_ALLOWED_ROOTS: usize = 32;
const MAX_ALLOWED_ROOTS_CHARS: usize = 16 * 1024;

/// On-machine runtime bounds for one op (Worker default is 30s, ceiling
/// 120s; the relay tolerates up to the v3 exec ceiling).
const MIN_TIMEOUT_MS: i64 = 1_000;
const MAX_TIMEOUT_MS: i64 = 300_000;
/// Bound per-connection workspace task fan-out. This matches the control
/// plane's pending-request cap and makes refusal explicit under load.
pub const MAX_IN_FLIGHT_WORKSPACE_REQUESTS: usize = 256;

// Include one byte for the line delimiter. The assembled patch still uses
// DIFF_MAX_BYTES as its payload ceiling, so this only bounds one input line.
const GIT_DIFF_LINE_MAX_BYTES: usize = DIFF_MAX_BYTES + 1;
const GIT_STDERR_MAX_BYTES: usize = 64 * 1024;
const GIT_STDERR_DRAIN_TIMEOUT: Duration = Duration::from_millis(250);
const GIT_CHILD_WAIT_TIMEOUT: Duration = Duration::from_secs(5);
const GIT_STOP_TIMEOUT: Duration = Duration::from_secs(1);
const CONNECTION_REQUEST_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);
const CONNECTION_REQUEST_ABORT_TIMEOUT: Duration = Duration::from_secs(1);

fn validate_allowed_roots_value(frame: &Value) -> Result<(), &'static str> {
    let Some(value) = frame.get("allowedRoots") else { return Ok(()) };
    let Some(roots) = value.as_array() else {
        return if value.is_null() { Ok(()) } else { Err("allowedRoots must be an array or null") };
    };
    if roots.len() > MAX_ALLOWED_ROOTS {
        return Err("allowed roots exceed entry limit");
    }
    let mut total_bytes = 0usize;
    for root in roots {
        let Some(root) = root.as_str() else { return Err("allowedRoots entries must be strings") };
        total_bytes = total_bytes.checked_add(root.len()).ok_or("allowed roots size overflow")?;
        if total_bytes > MAX_ALLOWED_ROOTS_CHARS {
            return Err("allowed roots exceed byte limit");
        }
        if root.is_empty() {
            return Err("allowed roots cannot contain empty paths");
        }
        validate_request_path(root).map_err(|_| "allowed roots contain an invalid path")?;
    }
    Ok(())
}

/// A typed machine-side refusal (one `WorkspaceErrorCode` on the wire).
#[derive(Debug)]
pub struct Refusal {
    pub code: wire::WorkspaceErrorCode,
    pub message: String,
    /// write_conflict only: hash of the bytes currently on disk.
    pub current_sha256: Option<String>,
}

impl Refusal {
    pub fn new(code: wire::WorkspaceErrorCode, message: impl Into<String>) -> Refusal {
        Refusal { code, message: message.into(), current_sha256: None }
    }

    fn path_forbidden(message: impl Into<String>) -> Refusal {
        Refusal::new(wire::WorkspaceErrorCode::PathForbidden, message)
    }

    fn not_found(message: impl Into<String>) -> Refusal {
        Refusal::new(wire::WorkspaceErrorCode::NotFound, message)
    }

    pub(crate) fn failed(message: impl Into<String>) -> Refusal {
        Refusal::new(wire::WorkspaceErrorCode::Failed, message)
    }
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(64);
    for byte in digest {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

fn home_dir() -> PathBuf {
    let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var_os(var).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

/// Root-relative path with "/" separators (the wire's path spelling).
pub fn slash_path(path: &Path) -> String {
    let mut out = String::new();
    for component in path.components() {
        if let Component::Normal(part) = component {
            if !out.is_empty() {
                out.push('/');
            }
            out.push_str(&part.to_string_lossy());
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Path scoping (port of actions.mjs resolveScopedPath +
// resolveScopedHostPath: lexical pass against the raw roots, canonical pass
// against realpathed roots, dangling-symlink refusal on create targets)
// ---------------------------------------------------------------------------

fn validate_request_path(raw: &str) -> Result<(), String> {
    if raw.is_empty() {
        return Err("path is empty".to_owned());
    }
    validate_action_path(raw)
}

fn relative_path_escapes(raw: &str) -> bool {
    let mut depth: i64 = 0;
    for segment in raw.split(['/', '\\']) {
        match segment {
            "" | "." => {}
            ".." => {
                if depth == 0 {
                    return true;
                }
                depth -= 1;
            }
            _ => depth += 1,
        }
    }
    false
}

/// Lexical normalization of an absolute path (`..`/`.` collapsed without
/// touching the filesystem, excess `..` clamped at the root — the
/// `node:path` resolve rules the JS relay scopes with).
fn lexical_normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                let popped = out.pop();
                let _ = popped; // clamp at the root, like path.resolve
            }
            other => out.push(other),
        }
    }
    out
}

fn is_absolute_request(raw: &str) -> bool {
    Path::new(raw).is_absolute() || raw == "~" || raw.starts_with("~/") || raw.starts_with("~\\")
}

fn expand_path(raw: &str, home: &Path, base: &Path) -> PathBuf {
    if raw == "~" {
        return lexical_normalize(home);
    }
    if let Some(rest) = raw.strip_prefix("~/").or_else(|| raw.strip_prefix("~\\")) {
        return lexical_normalize(&home.join(rest));
    }
    let path = Path::new(raw);
    if path.is_absolute() { lexical_normalize(path) } else { lexical_normalize(&base.join(path)) }
}

fn within_root(path: &Path, root: &Path) -> bool {
    path == root || path.starts_with(root)
}

/// Canonicalize a path that may not exist yet: realpath the nearest existing
/// ancestor and re-append the missing tail. A dangling symlink is refused
/// rather than reinterpreted as a create target (actions.mjs
/// `canonicalPotentialPath`).
fn canonical_potential_path(path: &Path) -> Result<PathBuf, Refusal> {
    let mut cursor = path.to_path_buf();
    let mut suffix: Vec<std::ffi::OsString> = Vec::new();
    loop {
        match std::fs::canonicalize(&cursor) {
            Ok(canonical) => {
                let mut out = canonical;
                for part in suffix.iter().rev() {
                    out.push(part);
                }
                return Ok(lexical_normalize(&out));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                if let Ok(meta) = std::fs::symlink_metadata(&cursor)
                    && meta.file_type().is_symlink()
                {
                    return Err(Refusal::path_forbidden(format!(
                        "path {} is a symlink whose target cannot be resolved",
                        cursor.display()
                    )));
                }
                let Some(name) = cursor.file_name().map(std::ffi::OsStr::to_os_string) else {
                    return Err(Refusal::failed(format!(
                        "path {} has no resolvable ancestor",
                        path.display()
                    )));
                };
                let Some(parent) = cursor.parent().map(Path::to_path_buf) else {
                    return Err(Refusal::failed(format!(
                        "path {} has no resolvable ancestor",
                        path.display()
                    )));
                };
                suffix.push(name);
                cursor = parent;
            }
            Err(error) => {
                return Err(Refusal::failed(format!(
                    "could not resolve {}: {error}",
                    cursor.display()
                )));
            }
        }
    }
}

/// The per-request scoping context: the workspace root plus every enforced
/// root list (server echo AND local config — the intersection wins).
pub struct Scope {
    home: PathBuf,
    /// Canonical workspace root: relative request paths resolve here, and
    /// `fs_tree`/`fs_search` without an explicit root list it.
    pub workdir: PathBuf,
    /// Enforced root lists, expanded but not canonicalized (lexical pass).
    lexical_roots: Vec<Vec<PathBuf>>,
    /// The same lists, canonicalized (host pass).
    canonical_roots: Vec<Vec<PathBuf>>,
}

impl Scope {
    /// `frame_roots` is the server's allowedRoots echo; `local_roots` is
    /// this machine's own `--allow-root` config. Both are enforced.
    pub fn build(
        frame_roots: Option<&[String]>,
        local_roots: Option<&[String]>,
    ) -> Result<Scope, Refusal> {
        let home = home_dir();
        let mut lexical_roots: Vec<Vec<PathBuf>> = Vec::new();
        for list in [local_roots, frame_roots].into_iter().flatten() {
            if list.is_empty() {
                continue;
            }
            if list.len() > MAX_ALLOWED_ROOTS {
                return Err(Refusal::path_forbidden(format!(
                    "allowed roots exceed {MAX_ALLOWED_ROOTS} entries"
                )));
            }
            let total_bytes =
                list.iter().try_fold(0usize, |total, root| total.checked_add(root.len()));
            if total_bytes.is_none_or(|bytes| bytes > MAX_ALLOWED_ROOTS_CHARS) {
                return Err(Refusal::path_forbidden(format!(
                    "allowed roots exceed {MAX_ALLOWED_ROOTS_CHARS} characters"
                )));
            }
            if list.iter().any(|root| root.is_empty()) {
                return Err(Refusal::path_forbidden("allowed roots cannot contain empty paths"));
            }
            for root in list {
                validate_request_path(root).map_err(Refusal::path_forbidden)?;
            }
            lexical_roots.push(list.iter().map(|root| expand_path(root, &home, &home)).collect());
        }
        let mut canonical_roots = Vec::new();
        for list in &lexical_roots {
            let mut canonical = Vec::new();
            for root in list {
                canonical.push(canonical_potential_path(root)?);
            }
            canonical_roots.push(canonical);
        }
        let workdir_source = lexical_roots
            .first()
            .and_then(|list| list.first().cloned())
            .or_else(|| {
                std::env::var_os("CHATMUX_WORKSPACE_ROOT")
                    .filter(|value| !value.is_empty())
                    .map(PathBuf::from)
            })
            .unwrap_or_else(|| home.clone());
        let workdir = canonical_potential_path(&workdir_source)?;
        Ok(Scope { home, workdir, lexical_roots, canonical_roots })
    }

    /// Resolve one request path: validate, expand, enforce every root list
    /// lexically, canonicalize (`allow_missing` = create target), enforce
    /// again on the canonical path. Missing paths refuse `not_found` unless
    /// `allow_missing`.
    pub fn resolve(&self, raw: &str, allow_missing: bool) -> Result<PathBuf, Refusal> {
        validate_request_path(raw).map_err(Refusal::path_forbidden)?;
        let absolute_request = is_absolute_request(raw);
        if !absolute_request && relative_path_escapes(raw) {
            return Err(Refusal::path_forbidden(
                "a relative path cannot escape the workspace root",
            ));
        }
        let lexical = expand_path(raw, &self.home, &self.workdir);
        for roots in &self.lexical_roots {
            if !roots.iter().any(|root| within_root(&lexical, root)) {
                return Err(Refusal::path_forbidden(format!(
                    "path {} is outside this machine's allowed roots",
                    lexical.display()
                )));
            }
        }
        if !absolute_request && !within_root(&lexical, &self.workdir) {
            return Err(Refusal::path_forbidden(format!(
                "relative path {} is outside the workspace root",
                lexical.display()
            )));
        }
        let canonical = if allow_missing {
            canonical_potential_path(&lexical)?
        } else {
            std::fs::canonicalize(&lexical).map_err(|error| {
                if error.kind() == std::io::ErrorKind::NotFound {
                    Refusal::not_found(format!("{raw} does not exist"))
                } else {
                    Refusal::failed(format!("could not resolve {raw}: {error}"))
                }
            })?
        };
        for roots in &self.canonical_roots {
            if !roots.iter().any(|root| within_root(&canonical, root)) {
                return Err(Refusal::path_forbidden(format!(
                    "path {} resolves outside this machine's allowed roots",
                    canonical.display()
                )));
            }
        }
        if !absolute_request && !within_root(&canonical, &self.workdir) {
            return Err(Refusal::path_forbidden(format!(
                "path {} resolves outside the workspace root",
                canonical.display()
            )));
        }
        Ok(canonical)
    }

    /// The workspace root for ops without an explicit root; refuses when it
    /// does not exist on disk.
    pub fn existing_workdir(&self) -> Result<PathBuf, Refusal> {
        if self.workdir.is_dir() {
            Ok(self.workdir.clone())
        } else {
            Err(Refusal::not_found(format!(
                "workspace root {} does not exist",
                self.workdir.display()
            )))
        }
    }

    fn validate_git_pathspec(&self, raw: &str) -> Result<(), Refusal> {
        validate_request_path(raw).map_err(Refusal::path_forbidden)?;
        if is_absolute_request(raw) || relative_path_escapes(raw) {
            return Err(Refusal::path_forbidden(
                "git pathspec must stay within the workspace root",
            ));
        }
        let lexical = expand_path(raw, &self.home, &self.workdir);
        for roots in &self.lexical_roots {
            if !roots.iter().any(|root| within_root(&lexical, root)) {
                return Err(Refusal::path_forbidden(format!(
                    "path {} is outside this machine's allowed roots",
                    lexical.display()
                )));
            }
        }
        if !within_root(&lexical, &self.workdir) {
            return Err(Refusal::path_forbidden("git pathspec is outside the workspace root"));
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Filesystem ops (sync bodies; the dispatcher runs them on the blocking
// pool under the request timeout)
// ---------------------------------------------------------------------------

fn clamp_i64(value: i64, low: i64, high: i64) -> i64 {
    value.clamp(low, high)
}

#[cfg(unix)]
fn open_no_follow(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt as _;
    std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(path)
}

#[cfg(not(unix))]
fn open_no_follow(path: &Path) -> std::io::Result<std::fs::File> {
    std::fs::OpenOptions::new().read(true).open(path)
}

/// Read a scoped file without following a final-component symlink swapped
/// in after the canonical check (actions.mjs readUtf8NoFollow).
fn read_bytes_no_follow(path: &Path, max_bytes: usize) -> std::io::Result<Vec<u8>> {
    use std::io::Read as _;
    let kind = std::fs::symlink_metadata(path)?.file_type();
    if !kind.is_file() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "workspace read requires a regular file",
        ));
    }
    let file = open_no_follow(path)?;
    let mut bytes = Vec::with_capacity(max_bytes.saturating_add(1));
    file.take(max_bytes.saturating_add(1) as u64).read_to_end(&mut bytes)?;
    Ok(bytes)
}

/// Read at most `max_bytes + 1` bytes, without following a final symlink.
/// The extra byte is only used to detect truncation. This keeps both memory
/// use and hashing work bounded by the response cap.
fn read_bounded_no_follow(path: &Path, max_bytes: usize) -> std::io::Result<(Vec<u8>, bool, u64)> {
    use std::io::Read as _;
    let kind = std::fs::symlink_metadata(path)?.file_type();
    if !kind.is_file() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "workspace read requires a regular file",
        ));
    }
    let file = open_no_follow(path)?;
    let size = file.metadata()?.len();
    let mut bytes = Vec::with_capacity(max_bytes.min(64 * 1024));
    file.take(max_bytes.saturating_add(1) as u64).read_to_end(&mut bytes)?;
    let truncated = bytes.len() > max_bytes;
    if truncated {
        bytes.truncate(max_bytes);
    }
    Ok((bytes, truncated, size))
}

#[cfg(not(unix))]
fn write_bytes_no_follow(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// Create the parent directory chain without accepting a symlink in any
/// existing component. `resolve` checks this chain before the operation, but
/// `create_dir_all` otherwise follows a swapped-in symlink and can write
/// outside the scoped roots.
#[cfg(not(unix))]
fn create_parent_dirs_no_symlink(path: &Path) -> Result<(), Refusal> {
    let Some(parent) = path.parent() else { return Ok(()) };
    let mut missing = Vec::new();
    let mut cursor = parent.to_path_buf();
    loop {
        match std::fs::symlink_metadata(&cursor) {
            Ok(meta) => {
                if meta.file_type().is_symlink() {
                    return Err(Refusal::path_forbidden(format!(
                        "parent {} is a symlink",
                        cursor.display()
                    )));
                }
                if !meta.is_dir() {
                    return Err(Refusal::failed(format!(
                        "parent {} is not a directory",
                        cursor.display()
                    )));
                }
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let Some(name) = cursor.file_name().map(std::ffi::OsStr::to_os_string) else {
                    return Err(Refusal::failed("parent has no name"));
                };
                missing.push(name);
                let Some(next) = cursor.parent() else {
                    return Err(Refusal::failed("parent has no resolvable ancestor"));
                };
                cursor = next.to_path_buf();
            }
            Err(error) => {
                return Err(Refusal::failed(format!(
                    "could not inspect {}: {error}",
                    cursor.display()
                )));
            }
        }
    }
    for name in missing.iter().rev() {
        cursor.push(name);
        match std::fs::create_dir(&cursor) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                let meta = std::fs::symlink_metadata(&cursor).map_err(|e| {
                    Refusal::failed(format!("could not inspect {}: {e}", cursor.display()))
                })?;
                if meta.file_type().is_symlink() || !meta.is_dir() {
                    return Err(Refusal::path_forbidden(format!(
                        "parent {} is not a directory",
                        cursor.display()
                    )));
                }
            }
            Err(error) => {
                return Err(Refusal::failed(format!(
                    "could not create {}: {error}",
                    cursor.display()
                )));
            }
        }
    }
    Ok(())
}

// The lexical/canonical checks above are necessary, but a path can still be
// redirected between that check and a later filesystem call. Unix mutations
// use directory descriptors for every lookup so a swapped-in parent symlink
// cannot redirect the operation outside the scoped root. The non-Unix path
// keeps the existing fail-closed checks; execute() refuses configured roots on
// platforms that cannot provide this descriptor guarantee.
#[cfg(unix)]
struct DescriptorPath {
    anchor: std::fs::File,
    relative: PathBuf,
}

#[cfg(unix)]
fn descriptor_io_refusal(path: &Path, error: std::io::Error) -> Refusal {
    if error.kind() == std::io::ErrorKind::NotFound {
        Refusal::not_found(format!("{} does not exist", path.display()))
    } else if error.raw_os_error() == Some(libc::ELOOP) {
        Refusal::path_forbidden(format!("path {} changed to a symlink", path.display()))
    } else {
        Refusal::failed(format!("could not access {}: {error}", path.display()))
    }
}

#[cfg(unix)]
fn open_descriptor_dir(path: &Path, create_missing: bool) -> Result<std::fs::File, Refusal> {
    use std::os::fd::{AsRawFd as _, FromRawFd as _};
    use std::os::unix::ffi::OsStrExt as _;

    let root = std::ffi::CString::new("/").expect("root has no NUL");
    let root_fd =
        unsafe { libc::open(root.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC) };
    if root_fd < 0 {
        return Err(Refusal::failed(format!(
            "could not open descriptor root: {}",
            std::io::Error::last_os_error()
        )));
    }
    let mut current = unsafe { std::fs::File::from_raw_fd(root_fd) };
    for component in path.components() {
        let Component::Normal(name) = component else { continue };
        let name = std::ffi::CString::new(name.as_bytes())
            .map_err(|_| Refusal::path_forbidden("path contains an embedded NUL byte"))?;
        let mut fd = unsafe {
            libc::openat(
                current.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 && create_missing {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::NotFound {
                let made = unsafe { libc::mkdirat(current.as_raw_fd(), name.as_ptr(), 0o777) };
                if made < 0 {
                    let create_error = std::io::Error::last_os_error();
                    if create_error.raw_os_error() != Some(libc::EEXIST) {
                        return Err(Refusal::failed(format!(
                            "could not create descriptor parent: {create_error}"
                        )));
                    }
                }
                fd = unsafe {
                    libc::openat(
                        current.as_raw_fd(),
                        name.as_ptr(),
                        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                    )
                };
            }
        }
        if fd < 0 {
            return Err(descriptor_io_refusal(path, std::io::Error::last_os_error()));
        }
        current = unsafe { std::fs::File::from_raw_fd(fd) };
    }
    Ok(current)
}

#[cfg(unix)]
fn descriptor_anchor(
    scope: &Scope,
    path: &Path,
    create_missing: bool,
) -> Result<DescriptorPath, Refusal> {
    let mut anchor_path = scope
        .canonical_roots
        .iter()
        .flatten()
        .filter(|root| path.starts_with(root))
        .max_by_key(|root| root.components().count())
        .cloned();
    if anchor_path.is_none() && path.starts_with(&scope.workdir) {
        anchor_path = Some(scope.workdir.clone());
    }
    let anchor_path = anchor_path.unwrap_or_else(|| PathBuf::from("/"));
    let relative = path
        .strip_prefix(&anchor_path)
        .map_err(|_| Refusal::path_forbidden("path is outside its descriptor-relative anchor"))?;
    let anchor = open_descriptor_dir(&anchor_path, create_missing)?;
    Ok(DescriptorPath { anchor, relative: relative.to_path_buf() })
}

#[cfg(unix)]
fn descriptor_parent(
    target: &DescriptorPath,
    create_missing: bool,
) -> Result<(std::fs::File, std::ffi::CString), Refusal> {
    use std::os::fd::{AsRawFd as _, FromRawFd as _};
    use std::os::unix::ffi::OsStrExt as _;

    let parts = target
        .relative
        .components()
        .map(|component| match component {
            Component::Normal(name) => Ok(name),
            _ => Err(Refusal::path_forbidden("invalid descriptor-relative path")),
        })
        .collect::<Result<Vec<_>, _>>()?;
    let Some(last) = parts.last() else {
        return Err(Refusal::path_forbidden("operation cannot target a directory root"));
    };
    let mut current = target
        .anchor
        .try_clone()
        .map_err(|error| Refusal::failed(format!("could not clone descriptor anchor: {error}")))?;
    for name in &parts[..parts.len() - 1] {
        let name = std::ffi::CString::new(name.as_bytes())
            .map_err(|_| Refusal::path_forbidden("path contains an embedded NUL byte"))?;
        let mut fd = unsafe {
            libc::openat(
                current.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 && create_missing {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::NotFound {
                let made = unsafe { libc::mkdirat(current.as_raw_fd(), name.as_ptr(), 0o777) };
                if made < 0 {
                    let create_error = std::io::Error::last_os_error();
                    if create_error.raw_os_error() != Some(libc::EEXIST) {
                        return Err(Refusal::failed(format!(
                            "could not create descriptor parent: {create_error}"
                        )));
                    }
                }
                fd = unsafe {
                    libc::openat(
                        current.as_raw_fd(),
                        name.as_ptr(),
                        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                    )
                };
            }
        }
        if fd < 0 {
            return Err(descriptor_io_refusal(&target.relative, std::io::Error::last_os_error()));
        }
        current = unsafe { std::fs::File::from_raw_fd(fd) };
    }
    let name = std::ffi::CString::new(last.as_bytes())
        .map_err(|_| Refusal::path_forbidden("path contains an embedded NUL byte"))?;
    Ok((current, name))
}

#[cfg(unix)]
fn open_descriptor_file(
    scope: &Scope,
    path: &Path,
    flags: libc::c_int,
    create_parents: bool,
) -> Result<std::fs::File, Refusal> {
    use std::os::fd::AsRawFd as _;
    let target = descriptor_anchor(scope, path, create_parents)?;
    let (parent, name) = descriptor_parent(&target, create_parents)?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o666,
        )
    };
    if fd < 0 {
        return Err(descriptor_io_refusal(path, std::io::Error::last_os_error()));
    }
    use std::os::fd::FromRawFd as _;
    Ok(unsafe { std::fs::File::from_raw_fd(fd) })
}

#[cfg(unix)]
fn write_descriptor_bytes(scope: &Scope, path: &Path, bytes: &[u8]) -> Result<(), Refusal> {
    use std::io::Write as _;
    let mut file =
        open_descriptor_file(scope, path, libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC, true)?;
    file.write_all(bytes)
        .and_then(|()| file.sync_all())
        .map_err(|error| descriptor_io_refusal(path, error))
}

#[cfg(unix)]
fn descriptor_stat(
    parent: &std::fs::File,
    name: &std::ffi::CString,
) -> Result<Option<libc::stat>, Refusal> {
    use std::os::fd::AsRawFd as _;
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    let result = unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if result == 0 {
        return Ok(Some(unsafe { stat.assume_init() }));
    }
    let error = std::io::Error::last_os_error();
    if error.kind() == std::io::ErrorKind::NotFound {
        Ok(None)
    } else {
        Err(Refusal::failed(format!("could not inspect directory entry: {error}")))
    }
}

#[cfg(unix)]
fn descriptor_is_directory(stat: &libc::stat) -> bool {
    (stat.st_mode & libc::S_IFMT) == libc::S_IFDIR
}

#[cfg(unix)]
fn descriptor_unlink(
    parent: &std::fs::File,
    name: &std::ffi::CString,
    flags: libc::c_int,
) -> Result<(), Refusal> {
    use std::os::fd::AsRawFd as _;
    let result = unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), flags) };
    if result == 0 {
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    if error.kind() == std::io::ErrorKind::NotFound {
        Err(Refusal::not_found("path does not exist"))
    } else {
        Err(Refusal::failed(format!("could not remove directory entry: {error}")))
    }
}

#[cfg(unix)]
fn read_directory_names(directory: &std::fs::File) -> Result<Vec<std::ffi::CString>, Refusal> {
    use std::ffi::CStr;
    use std::os::fd::AsRawFd as _;
    let fd = unsafe { libc::dup(directory.as_raw_fd()) };
    if fd < 0 {
        return Err(Refusal::failed(format!(
            "could not duplicate directory descriptor: {}",
            std::io::Error::last_os_error()
        )));
    }
    let stream = unsafe { libc::fdopendir(fd) };
    if stream.is_null() {
        unsafe { libc::close(fd) };
        return Err(Refusal::failed(format!(
            "could not read directory: {}",
            std::io::Error::last_os_error()
        )));
    }
    let mut names = Vec::new();
    loop {
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            break;
        }
        let entry = unsafe { &*entry };
        let name = unsafe { CStr::from_ptr(entry.d_name.as_ptr()) }.to_bytes();
        if name == b"." || name == b".." {
            continue;
        }
        let name = std::ffi::CString::new(name)
            .map_err(|_| Refusal::failed("directory entry contained an embedded NUL byte"))?;
        names.push(name);
    }
    if unsafe { libc::closedir(stream) } != 0 {
        return Err(Refusal::failed(format!(
            "could not close directory: {}",
            std::io::Error::last_os_error()
        )));
    }
    Ok(names)
}

#[cfg(unix)]
fn remove_descriptor_tree(directory: &std::fs::File) -> Result<(), Refusal> {
    use std::os::fd::{AsRawFd as _, FromRawFd as _};
    let names = read_directory_names(directory)?;
    for name in names {
        let Some(stat) = descriptor_stat(directory, &name)? else { continue };
        if descriptor_is_directory(&stat) {
            let child_fd = unsafe {
                libc::openat(
                    directory.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if child_fd < 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::NotFound {
                    continue;
                }
                return Err(if error.raw_os_error() == Some(libc::ELOOP) {
                    Refusal::path_forbidden("refusing a directory that changed to a symlink")
                } else {
                    Refusal::failed(format!("could not open directory for deletion: {error}"))
                });
            }
            let child = unsafe { std::fs::File::from_raw_fd(child_fd) };
            remove_descriptor_tree(&child)?;
            descriptor_unlink(directory, &name, libc::AT_REMOVEDIR)?;
        } else {
            descriptor_unlink(directory, &name, 0)?;
        }
    }
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn rename_descriptor_noreplace(
    source_parent: std::os::fd::RawFd,
    source_name: &std::ffi::CString,
    destination_parent: std::os::fd::RawFd,
    destination_name: &std::ffi::CString,
) -> std::io::Result<()> {
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            source_parent,
            source_name.as_ptr(),
            destination_parent,
            destination_name.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if result == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
}

#[cfg(target_vendor = "apple")]
fn rename_descriptor_noreplace(
    source_parent: std::os::fd::RawFd,
    source_name: &std::ffi::CString,
    destination_parent: std::os::fd::RawFd,
    destination_name: &std::ffi::CString,
) -> std::io::Result<()> {
    let result = unsafe {
        libc::renameatx_np(
            source_parent,
            source_name.as_ptr(),
            destination_parent,
            destination_name.as_ptr(),
            libc::RENAME_EXCL,
        )
    };
    if result == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "android", target_vendor = "apple"))))]
fn rename_descriptor_noreplace(
    _source_parent: std::os::fd::RawFd,
    _source_name: &std::ffi::CString,
    _destination_parent: std::os::fd::RawFd,
    _destination_name: &std::ffi::CString,
) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "atomic no-replace rename is unavailable on this platform",
    ))
}

#[cfg(unix)]
fn rename_descriptor(
    scope: &Scope,
    from: &Path,
    to: &Path,
    overwrite: bool,
) -> Result<(), Refusal> {
    use std::os::fd::AsRawFd as _;
    let source = descriptor_anchor(scope, from, false)?;
    let destination = descriptor_anchor(scope, to, true)?;
    let (source_parent, source_name) = descriptor_parent(&source, false)?;
    let (destination_parent, destination_name) = descriptor_parent(&destination, true)?;
    if descriptor_stat(&source_parent, &source_name)?.is_none() {
        return Err(Refusal::not_found(format!("{} does not exist", from.display())));
    }
    if descriptor_stat(&destination_parent, &destination_name)?.is_some() && !overwrite {
        return Err(Refusal::new(
            wire::WorkspaceErrorCode::DestinationExists,
            format!("{} already exists", to.display()),
        ));
    }
    let rename_result = if overwrite {
        let result = unsafe {
            libc::renameat(
                source_parent.as_raw_fd(),
                source_name.as_ptr(),
                destination_parent.as_raw_fd(),
                destination_name.as_ptr(),
            )
        };
        if result == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
    } else {
        rename_descriptor_noreplace(
            source_parent.as_raw_fd(),
            &source_name,
            destination_parent.as_raw_fd(),
            &destination_name,
        )
    };
    rename_result.map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            Refusal::not_found(format!("{} does not exist", from.display()))
        } else if !overwrite && error.kind() == std::io::ErrorKind::AlreadyExists {
            Refusal::new(
                wire::WorkspaceErrorCode::DestinationExists,
                format!("{} already exists", to.display()),
            )
        } else {
            Refusal::failed(format!(
                "could not rename {} -> {}: {error}",
                from.display(),
                to.display()
            ))
        }
    })
}

#[cfg(unix)]
fn delete_descriptor(scope: &Scope, path: &Path, recursive: bool) -> Result<(), Refusal> {
    use std::os::fd::{AsRawFd as _, FromRawFd as _};
    let target = descriptor_anchor(scope, path, false)?;
    let (parent, name) = descriptor_parent(&target, false)?;
    let Some(stat) = descriptor_stat(&parent, &name)? else {
        return Err(Refusal::not_found(format!("{} does not exist", path.display())));
    };
    if descriptor_is_directory(&stat) {
        if recursive {
            let fd = unsafe {
                libc::openat(
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if fd < 0 {
                return Err(descriptor_io_refusal(path, std::io::Error::last_os_error()));
            }
            let directory = unsafe { std::fs::File::from_raw_fd(fd) };
            remove_descriptor_tree(&directory)?;
        }
        descriptor_unlink(&parent, &name, libc::AT_REMOVEDIR).map_err(|refusal| {
            if refusal.message.to_ascii_lowercase().contains("directory not empty") {
                Refusal::new(
                    wire::WorkspaceErrorCode::DirectoryNotEmpty,
                    format!("{} is a non-empty directory (pass recursive)", path.display()),
                )
            } else {
                refusal
            }
        })
    } else {
        descriptor_unlink(&parent, &name, 0)
    }
}

/// Gitignore-aware walker shared by fs_tree and fs_search (`rg --files`
/// semantics: .gitignore/.ignore/.git/info/exclude respected, hidden files
/// listed, `.git` itself always excluded).
fn workspace_walker(root: &Path, include_ignored: bool) -> ignore::WalkBuilder {
    let mut builder = ignore::WalkBuilder::new(root);
    builder
        .hidden(false)
        .follow_links(false)
        .sort_by_file_name(std::ffi::OsStr::cmp)
        .filter_entry(|entry| entry.file_name() != std::ffi::OsStr::new(".git"));
    if include_ignored {
        builder.git_ignore(false).git_global(false).git_exclude(false).ignore(false).parents(false);
    }
    builder
}

fn run_tree(scope: &Scope, op: &wire::FsTreeOp) -> Result<wire::WorkspaceResultBody, Refusal> {
    let root = match &op.root {
        Some(raw) => scope.resolve(raw, false)?,
        None => scope.existing_workdir()?,
    };
    if !root.is_dir() {
        return Err(Refusal::not_found(format!("{} is not a directory", root.display())));
    }
    let cap = usize::try_from(clamp_i64(op.max_entries, 1, TREE_MAX_ENTRIES)).unwrap_or(1);
    let include_ignored = op.include_ignored == Some(true);
    let mut entries: Vec<wire::FsTreeEntry> = Vec::new();
    let mut truncated = false;
    for entry in workspace_walker(&root, include_ignored).build() {
        let Ok(entry) = entry else { continue };
        if entry.depth() == 0 {
            continue;
        }
        if entries.len() >= cap {
            truncated = true;
            break;
        }
        let Ok(relative) = entry.path().strip_prefix(&root) else { continue };
        let Some(file_type) = entry.file_type() else { continue };
        let kind = if file_type.is_symlink() {
            wire::FsTreeEntryKind::Symlink
        } else if file_type.is_dir() {
            wire::FsTreeEntryKind::Dir
        } else {
            wire::FsTreeEntryKind::File
        };
        let meta = if kind == wire::FsTreeEntryKind::File { entry.metadata().ok() } else { None };
        let size = meta.as_ref().map(|meta| meta.len() as f64);
        let mtime_ms = meta
            .as_ref()
            .and_then(|meta| meta.modified().ok())
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|elapsed| elapsed.as_millis() as f64);
        entries.push(wire::FsTreeEntry { path: slash_path(relative), kind, size, mtime_ms });
    }
    Ok(wire::WorkspaceResultBody::FsTree(wire::FsTreeResult {
        op: wire::TagFsTree::FsTree,
        root: root.to_string_lossy().into_owned(),
        entries,
        truncated,
    }))
}

fn run_read(scope: &Scope, op: &wire::FsReadOp) -> Result<wire::WorkspaceResultBody, Refusal> {
    // std::fs::OpenOptions follows Windows reparse points. Until reads use a
    // handle-relative CreateFileW call with FILE_FLAG_OPEN_REPARSE_POINT,
    // refuse them rather than allowing a post-canonicalization redirect.
    #[cfg(windows)]
    return Err(Refusal::path_forbidden("scoped reads are unavailable on Windows relays"));

    let path = scope.resolve(&op.path, false)?;
    let max = usize::try_from(clamp_i64(op.max_bytes, 1, READ_MAX_BYTES)).unwrap_or(1);
    let (bytes, truncated, size) = read_bounded_no_follow(&path, max).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            Refusal::not_found(format!("{} does not exist", op.path))
        } else {
            Refusal::failed(format!("could not read {}: {error}", op.path))
        }
    })?;
    let (content, encoding) = match std::str::from_utf8(&bytes) {
        Ok(text) => (text.to_owned(), wire::FsContentEncoding::Utf8),
        Err(error) if truncated && error.error_len().is_none() && error.valid_up_to() > 0 => {
            // The byte cap cut a multi-byte character; trim to the last
            // whole character instead of downgrading the file to base64.
            let valid = error.valid_up_to();
            match std::str::from_utf8(&bytes[..valid]) {
                Ok(text) => (text.to_owned(), wire::FsContentEncoding::Utf8),
                Err(_) => (base64_encode(&bytes), wire::FsContentEncoding::Base64),
            }
        }
        Err(_) => (base64_encode(&bytes), wire::FsContentEncoding::Base64),
    };
    Ok(wire::WorkspaceResultBody::FsRead(wire::FsReadResult {
        op: wire::TagFsRead::FsRead,
        content,
        encoding,
        sha256: sha256_hex(&bytes),
        size: i64::try_from(size).unwrap_or(i64::MAX),
        truncated,
    }))
}

fn base64_encode(bytes: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn run_write(scope: &Scope, op: &wire::FsWriteOp) -> Result<wire::WorkspaceResultBody, Refusal> {
    // Windows OpenOptions follows reparse points. Until writes use a
    // handle-relative CreateFile path with FILE_FLAG_OPEN_REPARSE_POINT,
    // fail closed rather than allowing a post-canonicalization redirect.
    #[cfg(windows)]
    return Err(Refusal::path_forbidden("scoped writes are unavailable on Windows relays"));

    if op.content.len() > WRITE_MAX_BYTES {
        return Err(Refusal::new(
            wire::WorkspaceErrorCode::TooLarge,
            format!("write body exceeds {WRITE_MAX_BYTES} bytes"),
        ));
    }
    let path = scope.resolve(&op.path, true)?;
    #[cfg(unix)]
    {
        if let Some(base) = &op.base_sha256 {
            use std::io::{Read as _, Seek as _, Write as _};
            let mut file = match open_descriptor_file(scope, &path, libc::O_RDWR, false) {
                Ok(file) => file,
                Err(refusal) if refusal.code == wire::WorkspaceErrorCode::NotFound => {
                    return Err(Refusal {
                        code: wire::WorkspaceErrorCode::WriteConflict,
                        message: format!("{} changed on disk", op.path),
                        current_sha256: None,
                    });
                }
                Err(refusal) => return Err(refusal),
            };
            let mut existing = Vec::with_capacity(WRITE_MAX_BYTES.saturating_add(1));
            std::io::Read::by_ref(&mut file)
                .take(WRITE_MAX_BYTES.saturating_add(1) as u64)
                .read_to_end(&mut existing)
                .map_err(|error| descriptor_io_refusal(&path, error))?;
            let current = Some(sha256_hex(&existing));
            if current.as_deref() != Some(base.as_str()) {
                return Err(Refusal {
                    code: wire::WorkspaceErrorCode::WriteConflict,
                    message: format!("{} changed on disk", op.path),
                    current_sha256: current,
                });
            }
            file.set_len(0)
                .and_then(|()| file.rewind())
                .and_then(|()| file.write_all(op.content.as_bytes()))
                .and_then(|()| file.sync_all())
                .map_err(|error| descriptor_io_refusal(&path, error))?;
        } else {
            // Do not read the old file for an unconditional write. This keeps
            // the common save path bounded by the new content size.
            write_descriptor_bytes(scope, &path, op.content.as_bytes())?;
        }
    }
    #[cfg(not(unix))]
    {
        // Windows scoped writes are rejected above until handle-relative
        // reparse-point traversal is available. Keep this branch safe for
        // other non-Unix targets and read only when compare-and-swap asks for
        // the old bytes.
        let existing = if op.base_sha256.is_some() {
            match read_bytes_no_follow(&path, WRITE_MAX_BYTES) {
                Ok(bytes) => Some(bytes),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
                Err(error) => {
                    return Err(Refusal::failed(format!("could not read {}: {error}", op.path)));
                }
            }
        } else {
            None
        };
        if let Some(base) = &op.base_sha256 {
            let current = existing.as_deref().map(sha256_hex);
            if current.as_deref() != Some(base.as_str()) {
                return Err(Refusal {
                    code: wire::WorkspaceErrorCode::WriteConflict,
                    message: format!("{} changed on disk", op.path),
                    current_sha256: current,
                });
            }
        }
        create_parent_dirs_no_symlink(&path)?;
        write_bytes_no_follow(&path, op.content.as_bytes())
            .map_err(|error| Refusal::failed(format!("could not write {}: {error}", op.path)))?;
    }
    Ok(wire::WorkspaceResultBody::FsWrite(wire::FsWriteResult {
        op: wire::TagFsWrite::FsWrite,
        sha256: sha256_hex(op.content.as_bytes()),
        size: i64::try_from(op.content.len()).unwrap_or(i64::MAX),
    }))
}

fn run_rename(scope: &Scope, op: &wire::FsRenameOp) -> Result<wire::WorkspaceResultBody, Refusal> {
    let from = scope.resolve(&op.from_path, false).map_err(|refusal| {
        if refusal.code == wire::WorkspaceErrorCode::NotFound {
            Refusal::not_found(format!("{} does not exist", op.from_path))
        } else {
            refusal
        }
    })?;
    let to = scope.resolve(&op.to_path, true)?;
    #[cfg(unix)]
    {
        rename_descriptor(scope, &from, &to, op.overwrite == Some(true))?;
    }
    #[cfg(not(unix))]
    {
        let destination_exists = std::fs::symlink_metadata(&to).is_ok();
        if destination_exists && op.overwrite != Some(true) {
            return Err(Refusal::new(
                wire::WorkspaceErrorCode::DestinationExists,
                format!("{} already exists", op.to_path),
            ));
        }
        create_parent_dirs_no_symlink(&to)?;
        std::fs::rename(&from, &to).map_err(|error| {
            Refusal::failed(format!("could not rename {} -> {}: {error}", op.from_path, op.to_path))
        })?;
    }
    Ok(wire::WorkspaceResultBody::FsRename(wire::FsRenameResult {
        op: wire::TagFsRename::FsRename,
    }))
}

pub(crate) fn run_delete(
    scope: &Scope,
    op: &wire::FsDeleteOp,
) -> Result<wire::WorkspaceResultBody, Refusal> {
    let path = scope.resolve(&op.path, false).map_err(|refusal| {
        if refusal.code == wire::WorkspaceErrorCode::NotFound {
            Refusal::not_found(format!("{} does not exist", op.path))
        } else {
            refusal
        }
    })?;
    #[cfg(unix)]
    {
        delete_descriptor(scope, &path, op.recursive == Some(true))?;
    }
    #[cfg(not(unix))]
    {
        let meta = std::fs::symlink_metadata(&path)
            .map_err(|_| Refusal::not_found(format!("{} does not exist", op.path)))?;
        if meta.is_dir() {
            let populated = std::fs::read_dir(&path)
                .map_err(|error| Refusal::failed(format!("could not read {}: {error}", op.path)))?
                .next()
                .is_some();
            if populated && op.recursive != Some(true) {
                return Err(Refusal::new(
                    wire::WorkspaceErrorCode::DirectoryNotEmpty,
                    format!("{} is a non-empty directory (pass recursive)", op.path),
                ));
            }
            std::fs::remove_dir_all(&path).map_err(|error| {
                Refusal::failed(format!("could not delete {}: {error}", op.path))
            })?;
        } else {
            // The canonical path (symlinks were resolved and re-scoped by
            // resolve(), like every other workspace op).
            std::fs::remove_file(&path).map_err(|error| {
                Refusal::failed(format!("could not delete {}: {error}", op.path))
            })?;
        }
    }
    Ok(wire::WorkspaceResultBody::FsDelete(wire::FsDeleteResult {
        op: wire::TagFsDelete::FsDelete,
    }))
}

fn utf16_units(text: &str) -> usize {
    text.chars().map(char::len_utf16).sum()
}

/// Truncate to at most `max` UTF-16 code units on a char boundary.
pub(crate) fn cap_utf16(text: &str, max: usize) -> (&str, usize) {
    let mut units = 0;
    for (byte_index, character) in text.char_indices() {
        let next = units + character.len_utf16();
        if next > max {
            return (&text[..byte_index], units);
        }
        units = next;
    }
    (text, units)
}

fn run_search(scope: &Scope, op: &wire::FsSearchOp) -> Result<wire::WorkspaceResultBody, Refusal> {
    let root = match &op.root {
        Some(raw) => scope.resolve(raw, false)?,
        None => scope.existing_workdir()?,
    };
    let cap = usize::try_from(clamp_i64(op.max_results, 1, SEARCH_MAX_RESULTS)).unwrap_or(1);
    let query = op.query.as_str();
    let query_units = utf16_units(query);
    let mut matches: Vec<wire::FsSearchMatch> = Vec::new();
    'files: for entry in workspace_walker(&root, false).build() {
        let Ok(entry) = entry else { continue };
        if entry.depth() == 0 || !entry.file_type().is_some_and(|kind| kind.is_file()) {
            continue;
        }
        let Ok(relative) = entry.path().strip_prefix(&root) else { continue };
        let Ok(bytes) = read_bytes_no_follow(entry.path(), READ_MAX_BYTES as usize) else {
            continue;
        };
        // Binary files are skipped (ripgrep's default behavior).
        let Ok(text) = std::str::from_utf8(&bytes) else { continue };
        let path = slash_path(relative);
        for (index, line) in text.lines().enumerate() {
            if matches.len() >= cap {
                break 'files;
            }
            if !line.contains(query) {
                continue;
            }
            let (capped, capped_units) = cap_utf16(line, SEARCH_MAX_TEXT_UNITS);
            let mut spans = Vec::new();
            for (byte_index, _) in line.match_indices(query) {
                let start = utf16_units(&line[..byte_index]);
                let end = start + query_units;
                // Spans that truncation pushed past the capped text are
                // dropped rather than pointing outside `text`.
                if end <= capped_units {
                    spans.push(wire::FsSearchSpan {
                        start: i64::try_from(start).unwrap_or(0),
                        end: i64::try_from(end).unwrap_or(0),
                    });
                }
            }
            matches.push(wire::FsSearchMatch {
                path: path.clone(),
                line: i64::try_from(index + 1).unwrap_or(i64::MAX),
                text: capped.to_owned(),
                spans,
            });
        }
    }
    let truncated = matches.len() >= cap;
    Ok(wire::WorkspaceResultBody::FsSearch(wire::FsSearchResult {
        op: wire::TagFsSearch::FsSearch,
        matches,
        truncated,
    }))
}

// ---------------------------------------------------------------------------
// Dispatch: session.rs hands every v6 frame here; requests run as tasks so
// a slow op never blocks heartbeats, and every answer rides the outbound
// channel back onto the one relay socket.
// ---------------------------------------------------------------------------

/// Ops that mutate the machine (or open a listener); refused at observe
/// trust. Mirrors WORKSPACE_MUTATING_OPS in chatmux packages/protocol —
/// exhaustive on purpose so a re-vendored op set fails compilation until
/// this policy names it.
fn is_mutating(op: &wire::WorkspaceOp) -> bool {
    match op {
        wire::WorkspaceOp::FsWrite(_)
        | wire::WorkspaceOp::FsRename(_)
        | wire::WorkspaceOp::FsDelete(_)
        | wire::WorkspaceOp::PreviewOpen(_) => true,
        wire::WorkspaceOp::FsTree(_)
        | wire::WorkspaceOp::FsRead(_)
        | wire::WorkspaceOp::FsSearch(_)
        | wire::WorkspaceOp::GitStatus(_)
        | wire::WorkspaceOp::GitDiff(_)
        | wire::WorkspaceOp::PreviewConsoleTail(_) => false,
    }
}

fn uses_scoped_file_paths(op: &wire::WorkspaceOp) -> bool {
    match op {
        wire::WorkspaceOp::FsTree(_)
        | wire::WorkspaceOp::FsRead(_)
        | wire::WorkspaceOp::FsWrite(_)
        | wire::WorkspaceOp::FsRename(_)
        | wire::WorkspaceOp::FsDelete(_)
        | wire::WorkspaceOp::FsSearch(_)
        | wire::WorkspaceOp::GitStatus(_)
        | wire::WorkspaceOp::GitDiff(_) => true,
        wire::WorkspaceOp::PreviewOpen(_) | wire::WorkspaceOp::PreviewConsoleTail(_) => false,
    }
}

/// State that outlives one relay socket: the preview proxies (and their
/// console ring) keep serving across reconnects because the tunnel keeps
/// pointing at their ports.
pub struct SharedRuntime {
    pub preview: PreviewRegistry,
    /// This machine's own `--allow-root` scoping (config authority).
    pub local_roots: Option<Vec<String>>,
    /// Process-wide bound for notify watcher teardown owners. The runtime is
    /// shared across reconnecting sockets, so one connection cannot consume a
    /// single-registry budget needed by another connection.
    pub watch_teardown_slots: Arc<Semaphore>,
    /// Process-wide bound for non-abortable watcher setup walks. Reconnects
    /// share this lane so abandoned blocking tasks cannot multiply per socket.
    pub watch_setup_slots: Arc<Semaphore>,
}

impl SharedRuntime {
    pub fn new(local_roots: Option<Vec<String>>) -> SharedRuntime {
        SharedRuntime {
            preview: PreviewRegistry::new(),
            local_roots,
            watch_teardown_slots: Arc::new(Semaphore::new(
                crate::watch::WATCH_TEARDOWN_CONCURRENCY,
            )),
            watch_setup_slots: Arc::new(Semaphore::new(crate::watch::WATCH_SETUP_CONCURRENCY)),
        }
    }
}

fn ensure_workspace_platform_capabilities(
    supports_descriptor_scoping: bool,
    request: &wire::RelayWorkspaceRequest,
    runtime: &SharedRuntime,
) -> Result<(), Refusal> {
    if !uses_scoped_file_paths(&request.op) {
        return Ok(());
    }
    let roots: RootLists<'_> = [runtime.local_roots.as_deref(), request.allowed_roots.as_deref()];
    ensure_scoped_file_roots_available(supports_descriptor_scoping, &roots)
        .map_err(|message| Refusal::new(wire::WorkspaceErrorCode::UnsupportedVerb, message))
}

/// Per-socket workspace state: watches die with the connection (the Worker
/// re-opens them), requests answer onto this connection's outbound queue.
pub struct Connection {
    runtime: Arc<SharedRuntime>,
    outbound: OutboundSink,
    /// Machine-side trust re-check: when the LOCAL effective trust is
    /// observe, mutating ops refuse regardless of what the server claims.
    local_observe: Arc<AtomicBool>,
    watches: WatchRegistry,
    /// Request tasks are owned by the socket connection. Dropping the
    /// connection must stop in-flight work instead of letting it outlive the
    /// outbound queue and the relay session that created it.
    requests: std::sync::Mutex<tokio::task::JoinSet<()>>,
    admission: Arc<Semaphore>,
    request_cancel: CancellationToken,
}

impl Connection {
    pub(crate) fn new(runtime: Arc<SharedRuntime>, outbound: OutboundSink) -> Connection {
        let watches = WatchRegistry::new_with_resource_slots(
            outbound.clone(),
            Arc::clone(&runtime.watch_setup_slots),
            Arc::clone(&runtime.watch_teardown_slots),
        );
        Connection {
            runtime,
            outbound,
            local_observe: Arc::new(AtomicBool::new(false)),
            watches,
            requests: std::sync::Mutex::new(tokio::task::JoinSet::new()),
            admission: Arc::new(Semaphore::new(MAX_IN_FLIGHT_WORKSPACE_REQUESTS)),
            request_cancel: CancellationToken::new(),
        }
    }

    pub fn set_local_observe(&self, observe: bool) {
        self.local_observe.store(observe, Ordering::Relaxed);
    }

    /// Cancel and await requests owned by this socket. Joining is required so
    /// Git requests can run their bounded kill-and-wait cleanup before the
    /// connection releases its process and admission resources.
    pub async fn shutdown(&self) -> bool {
        self.request_cancel.cancel();
        let mut requests = {
            let mut requests = match self.requests.lock() {
                Ok(requests) => requests,
                Err(poisoned) => poisoned.into_inner(),
            };
            std::mem::take(&mut *requests)
        };
        if tokio::time::timeout(CONNECTION_REQUEST_SHUTDOWN_TIMEOUT, async {
            while requests.join_next().await.is_some() {}
        })
        .await
        .is_ok()
        {
            return true;
        }
        // A started spawn_blocking task cannot be aborted. Bound the final
        // join too, then release the JoinSet; started blocking work can finish
        // in Tokio's blocking pool without holding this connection owner.
        requests.abort_all();
        let _ = tokio::time::timeout(CONNECTION_REQUEST_ABORT_TIMEOUT, async {
            while requests.join_next().await.is_some() {}
        })
        .await;
        false
    }

    /// Entry point for the three v6 server frame types. Never blocks; never
    /// closes the socket (W23: a bad frame gets a typed answer or silence).
    pub fn handle_frame(&self, frame: Value) {
        let Some(frame_type) = frame.get("type").and_then(Value::as_str) else { return };
        match frame_type {
            "workspace_request" => {
                if let Err(message) = validate_allowed_roots_value(&frame) {
                    if let Some(request_id) = frame.get("requestId").and_then(Value::as_str) {
                        let refusal =
                            Refusal::new(wire::WorkspaceErrorCode::PathForbidden, message);
                        self.send_critical(error_frame(request_id, &refusal));
                    }
                    return;
                }
                match serde_json::from_value::<wire::RelayWorkspaceRequest>(frame.clone()) {
                    Ok(request) => self.spawn_request(request),
                    Err(_) => {
                        // The envelope decoded as v6 upstream but the op is
                        // one this build does not know (W23): answer typed,
                        // never close.
                        if let Some(request_id) = frame.get("requestId").and_then(Value::as_str) {
                            let refusal = Refusal::new(
                                wire::WorkspaceErrorCode::UnsupportedVerb,
                                "this relay build does not know this workspace op",
                            );
                            self.send_critical(error_frame(request_id, &refusal));
                        }
                    }
                }
            }
            "fs_watch_open" => {
                if let Err(message) = validate_allowed_roots_value(&frame) {
                    if let Some(watch_id) = frame.get("watchId").and_then(Value::as_str) {
                        self.watches.refuse(
                            watch_id,
                            wire::WorkspaceErrorCode::PathForbidden,
                            message,
                        );
                    }
                    return;
                }
                match serde_json::from_value::<wire::RelayFsWatchOpen>(frame.clone()) {
                    Ok(open) => self.watches.open(open, self.runtime.local_roots.as_deref()),
                    Err(_) => {
                        if let Some(watch_id) = frame.get("watchId").and_then(Value::as_str) {
                            self.watches.refuse(
                                watch_id,
                                wire::WorkspaceErrorCode::Failed,
                                "unreadable fs_watch_open frame",
                            );
                        }
                    }
                }
            }
            "fs_watch_close" => {
                if let Ok(close) = serde_json::from_value::<wire::RelayFsWatchClose>(frame) {
                    self.watches.close(&close.watch_id);
                }
            }
            _ => {}
        }
    }

    fn spawn_request(&self, request: wire::RelayWorkspaceRequest) {
        if self.request_cancel.is_cancelled() {
            return;
        }
        let runtime = Arc::clone(&self.runtime);
        let outbound = self.outbound.clone();
        let local_observe = Arc::clone(&self.local_observe);
        let cancellation = self.request_cancel.clone();
        let permit = match self.admission.clone().try_acquire_owned() {
            Ok(permit) => permit,
            Err(_) => {
                let refusal = Refusal::failed("workspace request limit reached; retry later");
                self.send_critical(error_frame(&request.request_id, &refusal));
                return;
            }
        };
        let task = async move {
            let request_id = request.request_id.clone();
            let outcome =
                execute(&runtime, &local_observe, request, permit, cancellation.clone()).await;
            if cancellation.is_cancelled() {
                return;
            }
            let text = match outcome {
                Ok(body) => ok_frame(&request_id, body),
                Err(refusal) => error_frame(&request_id, &refusal),
            };
            let _ = tokio::select! {
                biased;
                _ = cancellation.cancelled() => Err(()),
                result = outbound.critical_text(text) => result,
            };
        };
        if let Ok(mut requests) = self.requests.lock() {
            if !self.request_cancel.is_cancelled() {
                // JoinSet removes completed tasks without rescanning every
                // in-flight request. This keeps admission proportional to the
                // number of completions since the previous frame.
                while requests.try_join_next().is_some() {}
                requests.spawn(task);
            }
        } else {
            // The task has not been spawned yet, so a poisoned registry does
            // not leak work beyond this connection.
        }
    }

    fn send_critical(&self, text: String) {
        if self.request_cancel.is_cancelled() {
            return;
        }
        let outbound = self.outbound.clone();
        let cancellation = self.request_cancel.clone();
        if let Ok(mut requests) = self.requests.lock()
            && !self.request_cancel.is_cancelled()
        {
            requests.spawn(async move {
                let _ = tokio::select! {
                    biased;
                    _ = cancellation.cancelled() => Err(()),
                    result = outbound.critical_text(text) => result,
                };
            });
        }
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        self.request_cancel.cancel();
        let mut requests = match self.requests.lock() {
            Ok(requests) => requests,
            Err(poisoned) => poisoned.into_inner(),
        };
        requests.abort_all();
    }
}

fn ok_frame(request_id: &str, body: wire::WorkspaceResultBody) -> String {
    let frame = wire::RelayWorkspaceResultOk {
        version: WORKSPACE_FRAME_VERSION,
        r#type: wire::TagWorkspaceResult::WorkspaceResult,
        request_id: request_id.to_owned(),
        ok: wire::ConstTrue,
        result: body,
    };
    serde_json::to_string(&frame).unwrap_or_else(|_| String::new())
}

fn error_frame(request_id: &str, refusal: &Refusal) -> String {
    // Path checks may include host paths for local diagnostics. Never expose
    // those details to a remote client, which could learn HOME or configured
    // allowed roots from a refusal.
    let message = match refusal.code {
        wire::WorkspaceErrorCode::PathForbidden => {
            Some("path is forbidden by the workspace policy".to_owned())
        }
        _ => Some(refusal.message.clone()),
    };
    let frame = wire::RelayWorkspaceResultError {
        version: WORKSPACE_FRAME_VERSION,
        r#type: wire::TagWorkspaceResult::WorkspaceResult,
        request_id: request_id.to_owned(),
        ok: wire::ConstFalse,
        code: refusal.code,
        message,
        current_sha256: refusal.current_sha256.clone(),
    };
    serde_json::to_string(&frame).unwrap_or_else(|_| String::new())
}

async fn execute(
    runtime: &Arc<SharedRuntime>,
    local_observe: &AtomicBool,
    request: wire::RelayWorkspaceRequest,
    permit: OwnedSemaphorePermit,
    cancellation: CancellationToken,
) -> Result<wire::WorkspaceResultBody, Refusal> {
    ensure_workspace_platform_capabilities(cfg!(unix), &request, runtime)?;
    if is_mutating(&request.op)
        && (request.trust == wire::TrustLevel::Observe || local_observe.load(Ordering::Relaxed))
    {
        return Err(Refusal::new(
            wire::WorkspaceErrorCode::TrustRefused,
            "observe trust refuses mutating workspace ops",
        ));
    }
    let timeout_ms = clamp_i64(request.timeout_ms, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS);
    // `run_op` may contain spawn_blocking work. Tokio cannot abort a started
    // blocking task when a timeout future is dropped, so returning early would
    // report a destructive operation as timed out while it keeps running.
    // Await completion first, then classify the elapsed duration. This keeps
    // the timeout an honest response-time diagnostic and preserves operation
    // ordering and permit ownership.
    let started = std::time::Instant::now();
    let deadline = started + Duration::from_millis(timeout_ms as u64);
    let outcome = run_op(runtime, request, permit, cancellation, deadline).await;
    if started.elapsed() > Duration::from_millis(timeout_ms.unsigned_abs()) {
        Err(Refusal::new(
            wire::WorkspaceErrorCode::Timeout,
            format!("workspace op exceeded {timeout_ms}ms"),
        ))
    } else {
        outcome
    }
}

async fn run_op(
    runtime: &Arc<SharedRuntime>,
    request: wire::RelayWorkspaceRequest,
    permit: OwnedSemaphorePermit,
    cancellation: CancellationToken,
    deadline: std::time::Instant,
) -> Result<wire::WorkspaceResultBody, Refusal> {
    let scope = Scope::build(request.allowed_roots.as_deref(), runtime.local_roots.as_deref())?;
    match request.op {
        wire::WorkspaceOp::FsTree(op) => blocking(move || run_tree(&scope, &op), permit).await,
        wire::WorkspaceOp::FsRead(op) => blocking(move || run_read(&scope, &op), permit).await,
        wire::WorkspaceOp::FsWrite(op) => blocking(move || run_write(&scope, &op), permit).await,
        wire::WorkspaceOp::FsRename(op) => blocking(move || run_rename(&scope, &op), permit).await,
        wire::WorkspaceOp::FsDelete(op) => blocking(move || run_delete(&scope, &op), permit).await,
        wire::WorkspaceOp::FsSearch(op) => blocking(move || run_search(&scope, &op), permit).await,
        wire::WorkspaceOp::GitStatus(_) => {
            run_git_status_with_cancel_until(&scope, &cancellation, deadline).await
        }
        wire::WorkspaceOp::GitDiff(op) => {
            run_git_diff_with_cancel_until(&scope, &op, &cancellation, deadline).await
        }
        wire::WorkspaceOp::PreviewOpen(op) => runtime.preview.open(op.target_port).await,
        wire::WorkspaceOp::PreviewConsoleTail(op) => runtime.preview.tail(op.max_events),
    }
}

async fn blocking<F>(
    body: F,
    permit: OwnedSemaphorePermit,
) -> Result<wire::WorkspaceResultBody, Refusal>
where
    F: FnOnce() -> Result<wire::WorkspaceResultBody, Refusal> + Send + 'static,
{
    match tokio::task::spawn_blocking(move || {
        let _permit = permit;
        body()
    })
    .await
    {
        Ok(outcome) => outcome,
        Err(join_error) => Err(Refusal::failed(format!("workspace op crashed: {join_error}"))),
    }
}

#[cfg(test)]
#[path = "workspace_tests.rs"]
mod tests;
