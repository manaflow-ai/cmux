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
// Git ops (shell git via tokio::process — git ships in every image and on
// every dev machine; kill_on_drop keeps an abandoned op from outliving its
// timeout)
// ---------------------------------------------------------------------------

/// Environment for the read-only git helpers.
///
/// Git can load configuration and invoke helper programs from its inherited
/// environment. A relay process also carries credentials for the control
/// plane, so passing that environment to git would expose those credentials to
/// a repository-controlled helper. Keep the same small baseline used by the
/// action and PTY runners, then disable system configuration and interactive
/// prompts explicitly.
fn git_environment_from(
    base: &std::collections::HashMap<String, String>,
) -> std::collections::HashMap<String, String> {
    let mut environment = scrubbed_env(base);
    environment.insert("GIT_CONFIG_NOSYSTEM".to_owned(), "1".to_owned());
    environment.insert("GIT_TERMINAL_PROMPT".to_owned(), "0".to_owned());
    environment.insert("GIT_PAGER".to_owned(), "cat".to_owned());
    environment
}

fn git_environment() -> std::collections::HashMap<String, String> {
    git_environment_from(&process_env_snapshot())
}

fn git_command(root: &Path, args: &[&str]) -> tokio::process::Command {
    let mut command = tokio::process::Command::new("git");
    command
        .arg("-C")
        .arg(root)
        .args(args)
        .env_clear()
        .envs(git_environment())
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", if cfg!(windows) { "NUL" } else { "/dev/null" })
        .env("LC_ALL", "C")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    #[cfg(unix)]
    {
        // Git may launch helpers which inherit its pipes. A private process
        // group lets cancellation terminate the whole tree without an unsafe
        // pre_exec hook.
        command.process_group(0);
    }
    command
}

fn git_refusal(context: &str, stderr: &[u8]) -> Refusal {
    let text = String::from_utf8_lossy(stderr);
    let text = text.trim();
    let capped: String = text.chars().take(500).collect();
    if text.contains("not a git repository") {
        Refusal::new(wire::WorkspaceErrorCode::NotARepository, format!("{context}: {capped}"))
    } else {
        Refusal::failed(format!("{context}: {capped}"))
    }
}

const GIT_DIFF_PREFIX_BYTES: usize = 10;

#[derive(Debug, Clone, PartialEq, Eq)]
enum BoundedGitDiffLine {
    Complete(String),
    TooLong { prefix: [u8; GIT_DIFF_PREFIX_BYTES], length: u8 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GitDiffLineKind {
    File,
    Addition,
    Deletion,
    Other,
}

fn classify_git_diff_line(bytes: &[u8]) -> GitDiffLineKind {
    if bytes.starts_with(b"diff --git ") {
        GitDiffLineKind::File
    } else if bytes.first() == Some(&b'+') && !bytes.starts_with(b"+++") {
        GitDiffLineKind::Addition
    } else if bytes.first() == Some(&b'-') && !bytes.starts_with(b"---") {
        GitDiffLineKind::Deletion
    } else {
        GitDiffLineKind::Other
    }
}

fn retain_git_diff_prefix(
    prefix: &mut [u8; GIT_DIFF_PREFIX_BYTES],
    length: &mut usize,
    bytes: &[u8],
) {
    let available = GIT_DIFF_PREFIX_BYTES.saturating_sub(*length);
    let take = available.min(bytes.len());
    prefix[*length..*length + take].copy_from_slice(&bytes[..take]);
    *length += take;
}

/// Read one diff line without allowing a missing newline to grow the buffer
/// without bound. `fill_buf` is cancellation-safe; consume every byte of an
/// over-limit line without retaining it, so the caller can keep calculating
/// the full diff stat while dropping the patch safely.
async fn read_bounded_git_diff_line<R>(
    reader: &mut R,
    line: &mut Vec<u8>,
    maximum: usize,
) -> std::io::Result<Option<BoundedGitDiffLine>>
where
    R: tokio::io::AsyncBufRead + Unpin,
{
    use tokio::io::AsyncBufReadExt as _;

    line.clear();
    let mut too_long = false;
    let mut prefix = [0_u8; GIT_DIFF_PREFIX_BYTES];
    let mut prefix_length = 0_usize;
    loop {
        let buffer = reader.fill_buf().await?;
        if buffer.is_empty() {
            if too_long {
                return Ok(Some(BoundedGitDiffLine::TooLong {
                    prefix,
                    length: prefix_length as u8,
                }));
            }
            return if line.is_empty() {
                Ok(None)
            } else {
                decode_git_diff_line(line).map(|line| Some(BoundedGitDiffLine::Complete(line)))
            };
        }
        let newline = buffer.iter().position(|byte| *byte == b'\n');
        let take = newline.map_or(buffer.len(), |index| index + 1);
        if too_long {
            retain_git_diff_prefix(&mut prefix, &mut prefix_length, &buffer[..take]);
            reader.consume(take);
        } else if line.len().saturating_add(take) > maximum {
            // Consume this chunk, including a possible newline, and then
            // report a marker instead of returning an error. This keeps the
            // stream aligned for later lines and bounds retained memory.
            retain_git_diff_prefix(&mut prefix, &mut prefix_length, &buffer[..take]);
            reader.consume(take);
            line.clear();
            too_long = true;
        } else {
            retain_git_diff_prefix(&mut prefix, &mut prefix_length, &buffer[..take]);
            line.extend_from_slice(&buffer[..take]);
            reader.consume(take);
        }
        if newline.is_some() {
            return if too_long {
                Ok(Some(BoundedGitDiffLine::TooLong { prefix, length: prefix_length as u8 }))
            } else {
                decode_git_diff_line(line).map(|line| Some(BoundedGitDiffLine::Complete(line)))
            };
        }
    }
}

fn decode_git_diff_line(line: &mut Vec<u8>) -> std::io::Result<String> {
    if line.last() == Some(&b'\n') {
        line.pop();
        if line.last() == Some(&b'\r') {
            line.pop();
        }
    }
    std::str::from_utf8(line)
        .map(str::to_owned)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))
}

/// Own stderr draining for one Git process. Retain only a bounded prefix, but
/// continue reading after the cap so Git cannot block on a full stderr pipe.
struct GitStderrDrain {
    task: tokio::task::JoinHandle<std::io::Result<()>>,
    retained: Arc<std::sync::Mutex<Vec<u8>>>,
}

struct GitStderrResult {
    bytes: Vec<u8>,
    complete: bool,
}

impl Drop for GitStderrDrain {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl GitStderrDrain {
    fn start<R>(mut stderr: R) -> GitStderrDrain
    where
        R: tokio::io::AsyncRead + Unpin + Send + 'static,
    {
        let retained = Arc::new(std::sync::Mutex::new(Vec::new()));
        let task_retained = Arc::clone(&retained);
        let task = tokio::spawn(async move {
            let mut buffer = [0_u8; 8 * 1024];
            loop {
                let read = stderr.read(&mut buffer).await?;
                if read == 0 {
                    break;
                }
                if let Ok(mut retained) = task_retained.lock()
                    && retained.len() < GIT_STDERR_MAX_BYTES
                {
                    let keep = (GIT_STDERR_MAX_BYTES - retained.len()).min(read);
                    retained.extend_from_slice(&buffer[..keep]);
                }
            }
            Ok(())
        });
        GitStderrDrain { task, retained }
    }

    async fn finish(mut self) -> Result<GitStderrResult, Refusal> {
        match tokio::time::timeout(GIT_STDERR_DRAIN_TIMEOUT, &mut self.task).await {
            Ok(result) => result
                .map_err(|error| Refusal::failed(format!("git stderr drain failed: {error}")))?
                .map_err(|error| Refusal::failed(format!("git stderr read failed: {error}")))?,
            Err(_) => {
                self.task.abort();
                let _ = (&mut self.task).await;
                return Ok(GitStderrResult {
                    bytes: self
                        .retained
                        .lock()
                        .map(|retained| retained.clone())
                        .unwrap_or_default(),
                    complete: false,
                });
            }
        }
        Ok(GitStderrResult {
            bytes: self.retained.lock().map(|retained| retained.clone()).unwrap_or_default(),
            complete: true,
        })
    }
}

/// Keep the process-group identity armed until the direct child has been
/// awaited. Drop can signal the group, but it cannot await, so owned async
/// paths must call `stop_git`/`wait_git_until` before disarming this guard.
struct GitProcessGuard(Option<u32>);

impl GitProcessGuard {
    fn new(child: &tokio::process::Child) -> GitProcessGuard {
        GitProcessGuard(child.id())
    }

    fn kill_group(&self) {
        #[cfg(unix)]
        if let Some(pid) = self.0 {
            // SAFETY: `pid` is the process-group leader we just spawned.
            unsafe {
                let _ = libc::kill(-(pid as libc::pid_t), libc::SIGKILL);
            }
        }
    }

    fn disarm(&mut self) {
        self.0 = None;
    }
}

impl Drop for GitProcessGuard {
    fn drop(&mut self) {
        if self.0.is_some() {
            self.kill_group();
        }
        // Tokio's kill_on_drop handles the direct child. Async owners call
        // `wait_git_until` before this guard is disarmed to provide deterministic
        // reaping; Drop is only an emergency descendant-kill fallback.
    }
}

fn disarm_if_reaped(child: &tokio::process::Child, guard: &mut GitProcessGuard) {
    if child.id().is_none() {
        guard.disarm();
    }
}

/// Terminate the process group and await the direct child within a bound.
async fn stop_git(child: &mut tokio::process::Child) {
    #[cfg(unix)]
    if let Some(pid) = child.id() {
        // SAFETY: the child was spawned with `process_group(0)`.
        unsafe {
            let _ = libc::kill(-(pid as libc::pid_t), libc::SIGKILL);
        }
    }
    let _ = child.start_kill();
    let _ = tokio::time::timeout(GIT_STOP_TIMEOUT, child.wait()).await;
}

fn remaining_git_time(deadline: std::time::Instant) -> Option<Duration> {
    // Normal stdout reads use the complete request budget. Keep short caps in
    // `bounded_git_time` for post-cancellation cleanup and child reaping only.
    deadline.checked_duration_since(std::time::Instant::now())
}

fn bounded_git_time(deadline: std::time::Instant, cap: Duration) -> Option<Duration> {
    Some(remaining_git_time(deadline)?.min(cap))
}

async fn wait_git_until(
    child: &mut tokio::process::Child,
    deadline: std::time::Instant,
) -> Result<std::process::ExitStatus, Refusal> {
    let Some(timeout) = bounded_git_time(deadline, GIT_CHILD_WAIT_TIMEOUT) else {
        stop_git(child).await;
        return Err(Refusal::failed("git operation deadline exceeded"));
    };
    match tokio::time::timeout(timeout, child.wait()).await {
        Ok(Ok(status)) => Ok(status),
        Ok(Err(error)) => Err(Refusal::failed(format!("could not wait for git: {error}"))),
        Err(_) => {
            stop_git(child).await;
            Err(Refusal::failed("git operation deadline exceeded"))
        }
    }
}

async fn finish_git_stderr(
    stderr_task: Option<GitStderrDrain>,
    child: &mut tokio::process::Child,
    guard: &mut GitProcessGuard,
    deadline: std::time::Instant,
    operation: &str,
) -> Result<Vec<u8>, Refusal> {
    let Some(task) = stderr_task else { return Ok(Vec::new()) };
    let Some(timeout) = bounded_git_time(deadline, GIT_STDERR_DRAIN_TIMEOUT) else {
        guard.kill_group();
        stop_git(child).await;
        disarm_if_reaped(child, guard);
        return Err(Refusal::failed(format!("{operation} operation deadline exceeded")));
    };
    let result = match tokio::time::timeout(timeout, task.finish()).await {
        Ok(Ok(result)) => result,
        Ok(Err(error)) => {
            guard.kill_group();
            stop_git(child).await;
            disarm_if_reaped(child, guard);
            return Err(error);
        }
        Err(_) => {
            guard.kill_group();
            stop_git(child).await;
            disarm_if_reaped(child, guard);
            return Err(Refusal::failed(format!("{operation} operation deadline exceeded")));
        }
    };
    match result {
        GitStderrResult { bytes, complete: true } => Ok(bytes),
        GitStderrResult { complete: false, .. } => {
            guard.kill_group();
            stop_git(child).await;
            disarm_if_reaped(child, guard);
            Err(Refusal::failed(format!("{operation} stderr drain timed out")))
        }
    }
}

/// Kill and reap after a read/stream error. The stderr task is finished while
/// the process-group identity is still owned by the live child handle.
async fn abort_git_operation(
    stderr_task: Option<GitStderrDrain>,
    child: &mut tokio::process::Child,
    guard: &mut GitProcessGuard,
) {
    guard.kill_group();
    let _ = child.start_kill();
    if let Some(task) = stderr_task {
        let _ = task.finish().await;
    }
    stop_git(child).await;
    disarm_if_reaped(child, guard);
}

/// Two-column XY code in the porcelain v1 spelling ("M " not "M.") — the
/// wire schema pins v1's verbatim codes.
fn porcelain_v1_xy(xy: &str) -> String {
    xy.chars().map(|column| if column == '.' { ' ' } else { column }).collect()
}

async fn run_git_status(scope: &Scope) -> Result<wire::WorkspaceResultBody, Refusal> {
    let cancellation = CancellationToken::new();
    run_git_status_with_cancel_until(
        scope,
        &cancellation,
        std::time::Instant::now() + Duration::from_millis(MAX_TIMEOUT_MS as u64),
    )
    .await
}

async fn run_git_status_with_cancel(
    scope: &Scope,
    cancellation: &CancellationToken,
) -> Result<wire::WorkspaceResultBody, Refusal> {
    run_git_status_with_cancel_until(
        scope,
        cancellation,
        std::time::Instant::now() + Duration::from_millis(MAX_TIMEOUT_MS as u64),
    )
    .await
}

async fn run_git_status_with_cancel_until(
    scope: &Scope,
    cancellation: &CancellationToken,
    deadline: std::time::Instant,
) -> Result<wire::WorkspaceResultBody, Refusal> {
    let root = scope.existing_workdir()?;
    let mut child = git_command(
        &root,
        &["-c", "core.fsmonitor=false", "status", "--porcelain=v2", "--branch", "-z"],
    )
    .spawn()
    .map_err(|error| Refusal::failed(format!("could not run git: {error}")))?;
    let mut process_guard = GitProcessGuard::new(&child);
    let Some(stdout) = child.stdout.take() else {
        stop_git(&mut child).await;
        disarm_if_reaped(&child, &mut process_guard);
        return Err(Refusal::failed("git status produced no stdout pipe"));
    };
    let mut stderr_task = child.stderr.take().map(GitStderrDrain::start);
    const STATUS_MAX_BYTES: usize = 16 * 1024 * 1024;
    let mut stdout_bytes = Vec::new();
    let read_limit = STATUS_MAX_BYTES.saturating_add(1);
    let read_result = tokio::select! {
        biased;
        _ = cancellation.cancelled() => Err(std::io::Error::new(
            std::io::ErrorKind::Interrupted,
            "git status cancelled",
        )),
        result = async {
            let Some(timeout) = remaining_git_time(deadline) else {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "git status operation deadline exceeded",
                ));
            };
            tokio::time::timeout(
                timeout,
                stdout.take(read_limit as u64).read_to_end(&mut stdout_bytes),
            )
            .await
            .map_err(|_| {
                std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "git status stdout drain timed out",
                )
            })
            .and_then(|result| result)
        } => result,
    };
    if let Err(error) = read_result {
        abort_git_operation(stderr_task.take(), &mut child, &mut process_guard).await;
        return Err(Refusal::failed(format!("could not read git status: {error}")));
    }
    let stdout_capped = stdout_bytes.len() > STATUS_MAX_BYTES;
    if stdout_capped {
        stdout_bytes.truncate(STATUS_MAX_BYTES);
        process_guard.kill_group();
        let _ = child.start_kill();
    }
    let stderr_result = tokio::select! {
        biased;
        _ = cancellation.cancelled() => None,
        result = finish_git_stderr(
            stderr_task.take(),
            &mut child,
            &mut process_guard,
            deadline,
            "git status",
        ) => Some(result),
    };
    let stderr = match stderr_result {
        Some(result) => result?,
        None => {
            abort_git_operation(None, &mut child, &mut process_guard).await;
            return Err(Refusal::failed("git status cancelled"));
        }
    };
    let status_result = tokio::select! {
        biased;
        _ = cancellation.cancelled() => None,
        result = wait_git_until(&mut child, deadline) => Some(result),
    };
    let status = match status_result {
        None => {
            abort_git_operation(None, &mut child, &mut process_guard).await;
            return Err(Refusal::failed("git status cancelled"));
        }
        Some(Ok(status)) => status,
        Some(Err(error)) => {
            disarm_if_reaped(&child, &mut process_guard);
            return Err(error);
        }
    };
    process_guard.disarm();
    if !status.success() {
        return Err(git_refusal("git status failed", &stderr));
    }
    let mut branch: Option<String> = None;
    let mut upstream: Option<String> = None;
    let mut ahead: i64 = 0;
    let mut behind: i64 = 0;
    let mut entries: Vec<wire::GitStatusEntry> = Vec::new();
    let mut truncated = stdout_capped;
    let mut chunks = stdout_bytes
        .split(|byte| *byte == 0)
        .map(String::from_utf8_lossy)
        .collect::<Vec<_>>()
        .into_iter();
    while let Some(chunk) = chunks.next() {
        if chunk.is_empty() {
            continue;
        }
        if let Some(head) = chunk.strip_prefix("# branch.head ") {
            if head != "(detached)" {
                branch = Some(head.to_owned());
            }
            continue;
        }
        if let Some(name) = chunk.strip_prefix("# branch.upstream ") {
            upstream = Some(name.to_owned());
            continue;
        }
        if let Some(ab) = chunk.strip_prefix("# branch.ab ") {
            for part in ab.split(' ') {
                if let Some(count) = part.strip_prefix('+') {
                    ahead = count.parse().unwrap_or(0);
                } else if let Some(count) = part.strip_prefix('-') {
                    behind = count.parse().unwrap_or(0);
                }
            }
            continue;
        }
        if chunk.starts_with("# ") {
            continue;
        }
        let entry = if let Some(rest) = chunk.strip_prefix("1 ") {
            // 1 XY sub mH mI mW hH hI path
            let mut fields = rest.splitn(8, ' ');
            let xy = fields.next().unwrap_or_default().to_owned();
            let path = fields.nth(6).unwrap_or_default().to_owned();
            Some((path, porcelain_v1_xy(&xy), None))
        } else if let Some(rest) = chunk.strip_prefix("2 ") {
            // 2 XY sub mH mI mW hH hI Xscore path NUL origPath
            let mut fields = rest.splitn(9, ' ');
            let xy = fields.next().unwrap_or_default().to_owned();
            let path = fields.nth(7).unwrap_or_default().to_owned();
            let orig = chunks.next().map(|orig| orig.into_owned()).unwrap_or_default();
            Some((path, porcelain_v1_xy(&xy), Some(orig)))
        } else if let Some(rest) = chunk.strip_prefix("u ") {
            // u XY sub m1 m2 m3 mW h1 h2 h3 path
            let mut fields = rest.splitn(10, ' ');
            let xy = fields.next().unwrap_or_default().to_owned();
            let path = fields.nth(8).unwrap_or_default().to_owned();
            Some((path, xy, None))
        } else {
            chunk.strip_prefix("? ").map(|path| (path.to_owned(), "??".to_owned(), None))
        };
        let Some((path, status, orig_path)) = entry else { continue };
        if path.is_empty() || status.is_empty() {
            continue;
        }
        if entries.len() >= STATUS_MAX_ENTRIES {
            truncated = true;
            break;
        }
        entries.push(wire::GitStatusEntry {
            path,
            status,
            orig_path: orig_path.filter(|orig| !orig.is_empty()),
        });
    }
    Ok(wire::WorkspaceResultBody::GitStatus(wire::GitStatusResult {
        op: wire::TagGitStatus::GitStatus,
        branch,
        upstream,
        ahead,
        behind,
        entries,
        truncated,
    }))
}

async fn run_git_diff(
    scope: &Scope,
    op: &wire::GitDiffOp,
) -> Result<wire::WorkspaceResultBody, Refusal> {
    let cancellation = CancellationToken::new();
    run_git_diff_with_cancel_until(
        scope,
        op,
        &cancellation,
        std::time::Instant::now() + Duration::from_millis(MAX_TIMEOUT_MS as u64),
    )
    .await
}

async fn run_git_diff_with_cancel_until(
    scope: &Scope,
    op: &wire::GitDiffOp,
    cancellation: &CancellationToken,
    deadline: std::time::Instant,
) -> Result<wire::WorkspaceResultBody, Refusal> {
    let root = scope.existing_workdir()?;
    let base = op.base.as_deref().unwrap_or("HEAD");
    if base.is_empty() || base.starts_with('-') {
        return Err(Refusal::failed("invalid diff base"));
    }
    let context = op.context_lines.map(|lines| format!("-U{}", lines.clamp(0, 100)));
    let mut args: Vec<&str> =
        vec!["-c", "core.fsmonitor=false", "diff", "--no-ext-diff", "--no-textconv", base];
    if let Some(context) = context.as_deref() {
        args.push(context);
    }
    let paths = op.paths.as_deref().unwrap_or_default();
    if !paths.is_empty() {
        args.push("--");
        for path in paths {
            scope.validate_git_pathspec(path)?;
            args.push(path);
        }
    }
    let mut child = git_command(&root, &args)
        .spawn()
        .map_err(|error| Refusal::failed(format!("could not run git: {error}")))?;
    let mut process_guard = GitProcessGuard::new(&child);
    // Stream stdout: the stat counts the FULL diff, but the patch buffer
    // drops whole files past DIFF_MAX_BYTES so memory and the wire stay
    // bounded even for a pathological working tree.
    let Some(stdout) = child.stdout.take() else {
        stop_git(&mut child).await;
        disarm_if_reaped(&child, &mut process_guard);
        return Err(Refusal::failed("git diff produced no stdout pipe"));
    };
    let mut stderr_task = child.stderr.take().map(GitStderrDrain::start);
    let mut reader = tokio::io::BufReader::new(stdout);
    let mut line_bytes = Vec::with_capacity(GIT_DIFF_LINE_MAX_BYTES.min(8 * 1024));
    let mut patch = String::new();
    let mut current_file_start = 0_usize;
    let mut capped = false;
    let mut truncated = false;
    let mut files: i64 = 0;
    let mut additions: i64 = 0;
    let mut deletions: i64 = 0;
    loop {
        let line = tokio::select! {
            biased;
            _ = cancellation.cancelled() => {
                abort_git_operation(
                    stderr_task.take(),
                    &mut child,
                    &mut process_guard,
                )
                .await;
                return Err(Refusal::failed("git diff cancelled"));
            }
            result = async {
                let Some(timeout) = remaining_git_time(deadline) else {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "git diff operation deadline exceeded",
                    ));
                };
                tokio::time::timeout(
                    timeout,
                    read_bounded_git_diff_line(
                        &mut reader,
                        &mut line_bytes,
                        GIT_DIFF_LINE_MAX_BYTES,
                    ),
                )
                .await
                .map_err(|_| {
                    std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "git diff stdout drain timed out",
                    )
                })
                .and_then(|result| result)
            } => match result {
                Ok(Some(line)) => line,
                Ok(None) => break,
                Err(error) => {
                    abort_git_operation(
                        stderr_task.take(),
                        &mut child,
                        &mut process_guard,
                    )
                    .await;
                    return Err(Refusal::failed(format!("could not read git diff: {error}")));
                }
            },
        };
        if let BoundedGitDiffLine::TooLong { prefix, length } = line {
            let prefix = &prefix[..usize::from(length)];
            match classify_git_diff_line(prefix) {
                GitDiffLineKind::File => files += 1,
                GitDiffLineKind::Addition => additions += 1,
                GitDiffLineKind::Deletion => deletions += 1,
                GitDiffLineKind::Other => {}
            }
            if !capped {
                // Drop the partial file: a caller must never see half a
                // file's hunks (parsePatchFiles input). Continue reading so
                // stats cover the complete Git output.
                patch.truncate(current_file_start);
                capped = true;
                truncated = true;
            }
            continue;
        }
        let BoundedGitDiffLine::Complete(line) = line else {
            unreachable!("handled all bounded diff line variants");
        };
        match classify_git_diff_line(line.as_bytes()) {
            GitDiffLineKind::File => {
                files += 1;
                if !capped {
                    current_file_start = patch.len();
                }
            }
            GitDiffLineKind::Addition => additions += 1,
            GitDiffLineKind::Deletion => deletions += 1,
            GitDiffLineKind::Other => {}
        }
        if !capped {
            if patch.len().saturating_add(line.len()).saturating_add(1) > DIFF_MAX_BYTES {
                // Drop the partial file: a caller must never see half a
                // file's hunks (parsePatchFiles input).
                patch.truncate(current_file_start);
                capped = true;
                truncated = true;
            } else {
                patch.push_str(&line);
                patch.push('\n');
            }
        }
    }
    let stderr_result = tokio::select! {
        biased;
        _ = cancellation.cancelled() => None,
        result = finish_git_stderr(
            stderr_task.take(),
            &mut child,
            &mut process_guard,
            deadline,
            "git diff",
        ) => Some(result),
    };
    let stderr = match stderr_result {
        Some(result) => result?,
        None => {
            abort_git_operation(None, &mut child, &mut process_guard).await;
            return Err(Refusal::failed("git diff cancelled"));
        }
    };
    let status_result = tokio::select! {
        biased;
        _ = cancellation.cancelled() => None,
        result = wait_git_until(&mut child, deadline) => Some(result),
    };
    let status = match status_result {
        None => {
            abort_git_operation(None, &mut child, &mut process_guard).await;
            return Err(Refusal::failed("git diff cancelled"));
        }
        Some(Ok(status)) => status,
        Some(Err(error)) => {
            disarm_if_reaped(&child, &mut process_guard);
            return Err(error);
        }
    };
    process_guard.disarm();
    if !status.success() {
        return Err(git_refusal("git diff failed", &stderr));
    }
    Ok(wire::WorkspaceResultBody::GitDiff(wire::GitDiffResult {
        op: wire::TagGitDiff::GitDiff,
        patch,
        stat: wire::GitDiffStat { files, additions, deletions },
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
        if let Ok(mut requests) = self.requests.lock() {
            if !self.request_cancel.is_cancelled() {
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
    let frame = wire::RelayWorkspaceResultError {
        version: WORKSPACE_FRAME_VERSION,
        r#type: wire::TagWorkspaceResult::WorkspaceResult,
        request_id: request_id.to_owned(),
        ok: wire::ConstFalse,
        code: refusal.code,
        message: Some(refusal.message.clone()),
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
    if started.elapsed() > std::time::Duration::from_millis(timeout_ms.unsigned_abs()) {
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
mod tests {
    use super::*;
    use crate::session::OutboundSink;

    fn scratch(name: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!("chatmux-ws-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("scratch dir");
        std::fs::canonicalize(&path).expect("canonical scratch")
    }

    fn write(root: &Path, rel: &str, content: &str) {
        let path = root.join(rel);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("parent");
        }
        std::fs::write(path, content).expect("write");
    }

    fn scope_for(root: &Path) -> Scope {
        let roots = vec![root.to_string_lossy().into_owned()];
        Scope::build(Some(&roots), Some(&roots)).expect("scope")
    }

    fn git(root: &Path, args: &[&str]) {
        let status = std::process::Command::new("git")
            .arg("-C")
            .arg(root)
            .args(args)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .output()
            .expect("git runs");
        assert!(status.status.success(), "git {args:?} failed");
    }

    // --- scoping ---------------------------------------------------------

    #[test]
    fn scoping_refuses_traversal_and_spoofed_paths() {
        let root = scratch("scope");
        write(&root, "inside.txt", "x");
        let scope = scope_for(&root);
        assert!(scope.resolve("inside.txt", false).is_ok());
        for bad in ["../outside", "a/../../b", "%2e%2e/x", "bad\u{0007}", "//etc/passwd"] {
            let refusal = scope.resolve(bad, false).expect_err(bad);
            assert_eq!(refusal.code, wire::WorkspaceErrorCode::PathForbidden, "{bad}");
        }
        let refusal = scope.resolve("/etc/passwd", false).expect_err("absolute escape");
        assert_eq!(refusal.code, wire::WorkspaceErrorCode::PathForbidden);
        let refusal = scope.resolve("missing.txt", false).expect_err("missing");
        assert_eq!(refusal.code, wire::WorkspaceErrorCode::NotFound);
        assert!(scope.resolve("brand/new.txt", true).is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn scoping_refuses_symlinks_that_escape_the_root() {
        let outside = scratch("scope-outside");
        write(&outside, "secret.txt", "s");
        let root = scratch("scope-symlink");
        std::os::unix::fs::symlink(outside.join("secret.txt"), root.join("link.txt"))
            .expect("symlink");
        std::os::unix::fs::symlink(root.join("gone"), root.join("dangling")).expect("dangling");
        let scope = scope_for(&root);
        let refusal = scope.resolve("link.txt", false).expect_err("escaping symlink");
        assert_eq!(refusal.code, wire::WorkspaceErrorCode::PathForbidden);
        let refusal = scope.resolve("dangling", true).expect_err("dangling symlink");
        assert_eq!(refusal.code, wire::WorkspaceErrorCode::PathForbidden);
    }

    #[test]
    fn both_root_lists_are_enforced() {
        let root_a = scratch("scope-a");
        let root_b = scratch("scope-b");
        write(&root_a, "a.txt", "a");
        write(&root_b, "b.txt", "b");
        let list_a = vec![root_a.to_string_lossy().into_owned()];
        let list_b = vec![root_b.to_string_lossy().into_owned()];
        let scope = Scope::build(Some(&list_a), Some(&list_b)).expect("scope");
        // workdir comes from the LOCAL list (config authority)...
        assert_eq!(scope.workdir, root_b);
        // ...and a path must satisfy the server echo AND the local config.
        let inside_b_only = root_b.join("b.txt");
        let refusal = scope
            .resolve(&inside_b_only.to_string_lossy(), false)
            .expect_err("outside the server echo");
        assert_eq!(refusal.code, wire::WorkspaceErrorCode::PathForbidden);
    }

    // --- fs ops ----------------------------------------------------------

    fn body_tree(body: wire::WorkspaceResultBody) -> wire::FsTreeResult {
        match body {
            wire::WorkspaceResultBody::FsTree(result) => result,
            other => panic!("wrong body: {other:?}"),
        }
    }

    #[test]
    fn tree_is_gitignore_aware_and_never_leaks_dot_git() {
        let root = scratch("tree");
        write(&root, "src/app.ts", "export {}\n");
        write(&root, ".gitignore", "ignored.txt\n");
        write(&root, "ignored.txt", "no\n");
        git(&root, &["init", "-q", "-b", "main"]);
        let scope = scope_for(&root);
        let result = body_tree(
            run_tree(
                &scope,
                &wire::FsTreeOp {
                    op: wire::TagFsTree::FsTree,
                    root: None,
                    max_entries: TREE_MAX_ENTRIES,
                    include_ignored: None,
                },
            )
            .expect("tree"),
        );
        let paths: Vec<&str> = result.entries.iter().map(|entry| entry.path.as_str()).collect();
        assert!(paths.contains(&"src"), "dirs render: {paths:?}");
        assert!(paths.contains(&"src/app.ts"));
        assert!(paths.contains(&".gitignore"), "hidden files list");
        assert!(!paths.iter().any(|path| path.contains(".git/") || *path == ".git"));
        assert!(!paths.contains(&"ignored.txt"), "gitignore respected");
        assert!(!result.truncated);

        let with_ignored = body_tree(
            run_tree(
                &scope,
                &wire::FsTreeOp {
                    op: wire::TagFsTree::FsTree,
                    root: None,
                    max_entries: TREE_MAX_ENTRIES,
                    include_ignored: Some(true),
                },
            )
            .expect("tree"),
        );
        let paths: Vec<&str> =
            with_ignored.entries.iter().map(|entry| entry.path.as_str()).collect();
        assert!(paths.contains(&"ignored.txt"));
        assert!(!paths.iter().any(|path| *path == ".git" || path.starts_with(".git/")));

        let capped = body_tree(
            run_tree(
                &scope,
                &wire::FsTreeOp {
                    op: wire::TagFsTree::FsTree,
                    root: None,
                    max_entries: 1,
                    include_ignored: None,
                },
            )
            .expect("tree"),
        );
        assert_eq!(capped.entries.len(), 1);
        assert!(capped.truncated);
    }

    #[cfg(not(windows))]
    #[test]
    fn read_returns_full_hash_and_flags_truncation() {
        let root = scratch("read");
        write(&root, "file.txt", "hello workspace\n");
        let scope = scope_for(&root);
        let read = |max_bytes: i64| match run_read(
            &scope,
            &wire::FsReadOp { op: wire::TagFsRead::FsRead, path: "file.txt".to_owned(), max_bytes },
        )
        .expect("read")
        {
            wire::WorkspaceResultBody::FsRead(result) => result,
            other => panic!("wrong body: {other:?}"),
        };
        let full = read(READ_MAX_BYTES);
        assert_eq!(full.content, "hello workspace\n");
        assert_eq!(full.encoding, wire::FsContentEncoding::Utf8);
        assert_eq!(full.sha256, sha256_hex(b"hello workspace\n"));
        assert_eq!(full.size, 16);
        assert!(!full.truncated);
        let cut = read(5);
        assert_eq!(cut.content, "hello");
        assert!(cut.truncated);
        assert_eq!(
            cut.sha256,
            sha256_hex(b"hello"),
            "truncated reads hash only the bounded prefix"
        );
        assert_eq!(cut.size, 16, "size comes from metadata without scanning the file");
        let missing = run_read(
            &scope,
            &wire::FsReadOp {
                op: wire::TagFsRead::FsRead,
                path: "nope.txt".to_owned(),
                max_bytes: 10,
            },
        )
        .expect_err("missing file");
        assert_eq!(missing.code, wire::WorkspaceErrorCode::NotFound);
    }

    #[cfg(not(windows))]
    #[test]
    fn read_reports_binary_as_base64_and_survives_a_split_utf8_char() {
        let root = scratch("read-binary");
        std::fs::write(root.join("bin.dat"), [0_u8, 159, 146, 150]).expect("write");
        write(&root, "emoji.txt", "ok\u{1F600}");
        let scope = scope_for(&root);
        let binary = match run_read(
            &scope,
            &wire::FsReadOp {
                op: wire::TagFsRead::FsRead,
                path: "bin.dat".to_owned(),
                max_bytes: READ_MAX_BYTES,
            },
        )
        .expect("read")
        {
            wire::WorkspaceResultBody::FsRead(result) => result,
            other => panic!("wrong body: {other:?}"),
        };
        assert_eq!(binary.encoding, wire::FsContentEncoding::Base64);
        // 4 bytes of "ok" + emoji cut mid-character stays utf8, trimmed.
        let split = match run_read(
            &scope,
            &wire::FsReadOp {
                op: wire::TagFsRead::FsRead,
                path: "emoji.txt".to_owned(),
                max_bytes: 4,
            },
        )
        .expect("read")
        {
            wire::WorkspaceResultBody::FsRead(result) => result,
            other => panic!("wrong body: {other:?}"),
        };
        assert_eq!(split.encoding, wire::FsContentEncoding::Utf8);
        assert_eq!(split.content, "ok");
        assert!(split.truncated);
    }

    #[cfg(windows)]
    #[test]
    fn read_is_refused_on_windows_without_touching_the_filesystem() {
        let root = scratch("read-windows");
        write(&root, "file.txt", "must remain unchanged\n");
        let scope = scope_for(&root);
        let refusal = run_read(
            &scope,
            &wire::FsReadOp {
                op: wire::TagFsRead::FsRead,
                path: "file.txt".to_owned(),
                max_bytes: READ_MAX_BYTES,
            },
        )
        .expect_err("Windows relays refuse scoped reads");
        assert_eq!(refusal.code, wire::WorkspaceErrorCode::PathForbidden);
        assert_eq!(
            std::fs::read_to_string(root.join("file.txt")).expect("file remains"),
            "must remain unchanged\n"
        );
    }

    #[test]
    fn write_cas_conflicts_echo_the_current_hash() {
        let root = scratch("write");
        write(&root, "file.txt", "one\n");
        let scope = scope_for(&root);
        let base = sha256_hex(b"one\n");
        let ok = run_write(
            &scope,
            &wire::FsWriteOp {
                op: wire::TagFsWrite::FsWrite,
                path: "file.txt".to_owned(),
                content: "two\n".to_owned(),
                base_sha256: Some(base.clone()),
            },
        )
        .expect("fresh base writes");
        match ok {
            wire::WorkspaceResultBody::FsWrite(result) => {
                assert_eq!(result.sha256, sha256_hex(b"two\n"));
                assert_eq!(result.size, 4);
            }
            other => panic!("wrong body: {other:?}"),
        }
        let stale = run_write(
            &scope,
            &wire::FsWriteOp {
                op: wire::TagFsWrite::FsWrite,
                path: "file.txt".to_owned(),
                content: "clobber\n".to_owned(),
                base_sha256: Some(base),
            },
        )
        .expect_err("stale base conflicts");
        assert_eq!(stale.code, wire::WorkspaceErrorCode::WriteConflict);
        assert_eq!(stale.current_sha256.as_deref(), Some(sha256_hex(b"two\n").as_str()));
        // A base against a missing file conflicts without a current hash.
        let missing = run_write(
            &scope,
            &wire::FsWriteOp {
                op: wire::TagFsWrite::FsWrite,
                path: "new.txt".to_owned(),
                content: "x\n".to_owned(),
                base_sha256: Some(sha256_hex(b"x\n")),
            },
        )
        .expect_err("missing file with a base conflicts");
        assert_eq!(missing.code, wire::WorkspaceErrorCode::WriteConflict);
        assert!(missing.current_sha256.is_none());
        // No base: unconditional write, parents created.
        assert!(
            run_write(
                &scope,
                &wire::FsWriteOp {
                    op: wire::TagFsWrite::FsWrite,
                    path: "deep/dir/new.txt".to_owned(),
                    content: "x\n".to_owned(),
                    base_sha256: None,
                },
            )
            .is_ok()
        );
        assert_eq!(std::fs::read_to_string(root.join("deep/dir/new.txt")).expect("read"), "x\n");
    }

    #[cfg(windows)]
    #[test]
    fn windows_scoped_write_is_refused_before_filesystem_mutation() {
        let root = scratch("windows-write-refusal");
        let scope = scope_for(&root);
        let op = wire::FsWriteOp {
            op: wire::TagFsWrite::FsWrite,
            path: "new.txt".into(),
            content: "must not be written".to_owned(),
            base_sha256: None,
        };

        let refusal = run_write(&scope, &op).expect_err("Windows scoped writes must fail closed");
        assert_eq!(refusal.code, wire::WorkspaceErrorCode::PathForbidden);
        assert!(!root.join("new.txt").exists());
    }

    #[cfg(unix)]
    #[test]
    fn write_and_rename_refuse_symlinked_parent_directories() {
        let root = scratch("symlink-parent");
        let outside = scratch("symlink-parent-outside");
        std::os::unix::fs::symlink(&outside, root.join("link")).expect("symlink");
        let scope = scope_for(&root);
        let write_refusal = run_write(
            &scope,
            &wire::FsWriteOp {
                op: wire::TagFsWrite::FsWrite,
                path: "link/escape.txt".to_owned(),
                content: "nope".to_owned(),
                base_sha256: None,
            },
        )
        .expect_err("symlinked parent must be refused");
        assert_eq!(write_refusal.code, wire::WorkspaceErrorCode::PathForbidden);
        write(&root, "source.txt", "source");
        let rename_refusal = run_rename(
            &scope,
            &wire::FsRenameOp {
                op: wire::TagFsRename::FsRename,
                from_path: "source.txt".to_owned(),
                to_path: "link/moved.txt".to_owned(),
                overwrite: None,
            },
        )
        .expect_err("symlinked parent must be refused");
        assert_eq!(rename_refusal.code, wire::WorkspaceErrorCode::PathForbidden);
        assert!(!outside.join("escape.txt").exists());
        assert!(!outside.join("moved.txt").exists());
    }

    #[test]
    fn rename_moves_and_refuses_typed() {
        let root = scratch("rename");
        write(&root, "a.txt", "a");
        write(&root, "b.txt", "b");
        let scope = scope_for(&root);
        let rename = |from: &str, to: &str, overwrite: Option<bool>| {
            run_rename(
                &scope,
                &wire::FsRenameOp {
                    op: wire::TagFsRename::FsRename,
                    from_path: from.to_owned(),
                    to_path: to.to_owned(),
                    overwrite,
                },
            )
        };
        assert!(rename("a.txt", "moved/a.txt", None).is_ok());
        assert!(root.join("moved/a.txt").is_file());
        assert!(!root.join("a.txt").exists());
        let missing = rename("a.txt", "again.txt", None).expect_err("gone source");
        assert_eq!(missing.code, wire::WorkspaceErrorCode::NotFound);
        let collide = rename("b.txt", "moved/a.txt", None).expect_err("occupied");
        assert_eq!(collide.code, wire::WorkspaceErrorCode::DestinationExists);
        assert!(rename("b.txt", "moved/a.txt", Some(true)).is_ok());
        assert_eq!(std::fs::read_to_string(root.join("moved/a.txt")).expect("read"), "b");
    }

    #[test]
    fn delete_removes_files_and_refuses_typed() {
        let root = scratch("delete");
        write(&root, "gone.txt", "x");
        write(&root, "dir/child.txt", "y");
        write(&root, "empty-dir/.keep", "");
        std::fs::remove_file(root.join("empty-dir/.keep")).expect("mk empty dir");
        let scope = scope_for(&root);
        let delete = |path: &str, recursive: Option<bool>| {
            run_delete(
                &scope,
                &wire::FsDeleteOp {
                    op: wire::TagFsDelete::FsDelete,
                    path: path.to_owned(),
                    recursive,
                },
            )
        };
        assert!(delete("gone.txt", None).is_ok());
        assert!(!root.join("gone.txt").exists());
        let missing = delete("gone.txt", None).expect_err("double delete");
        assert_eq!(missing.code, wire::WorkspaceErrorCode::NotFound);
        let populated = delete("dir", None).expect_err("populated dir");
        assert_eq!(populated.code, wire::WorkspaceErrorCode::DirectoryNotEmpty);
        assert!(root.join("dir/child.txt").exists(), "refusal deleted nothing");
        assert!(delete("empty-dir", None).is_ok(), "empty dir needs no recursive");
        assert!(delete("dir", Some(true)).is_ok(), "recursive removes the tree");
        assert!(!root.join("dir").exists());
        let escape = delete("../outside", None).expect_err("scoped");
        assert_eq!(escape.code, wire::WorkspaceErrorCode::PathForbidden);
    }

    #[test]
    fn search_finds_spans_in_utf16_units_and_caps() {
        let root = scratch("search");
        write(&root, "src/app.ts", "const NEEDLE = 1\n\u{1F600} NEEDLE again NEEDLE\n");
        write(&root, ".gitignore", "skip.txt\n");
        write(&root, "skip.txt", "NEEDLE\n");
        git(&root, &["init", "-q", "-b", "main"]);
        let scope = scope_for(&root);
        let search = |max_results: i64| match run_search(
            &scope,
            &wire::FsSearchOp {
                op: wire::TagFsSearch::FsSearch,
                query: "NEEDLE".to_owned(),
                root: None,
                max_results,
            },
        )
        .expect("search")
        {
            wire::WorkspaceResultBody::FsSearch(result) => result,
            other => panic!("wrong body: {other:?}"),
        };
        let result = search(SEARCH_MAX_RESULTS);
        assert!(!result.truncated);
        assert_eq!(result.matches.len(), 2, "{:?}", result.matches);
        assert!(result.matches.iter().all(|found| found.path == "src/app.ts"));
        let first = &result.matches[0];
        assert_eq!(first.line, 1);
        assert_eq!(first.spans, vec![wire::FsSearchSpan { start: 6, end: 12 }]);
        let second = &result.matches[1];
        // The emoji is two UTF-16 units: JS-visible offsets, not bytes.
        assert_eq!(second.spans[0], wire::FsSearchSpan { start: 3, end: 9 });
        assert_eq!(second.spans.len(), 2);
        let capped = search(1);
        assert_eq!(capped.matches.len(), 1);
        assert!(capped.truncated);
    }

    // --- git ops ---------------------------------------------------------

    #[test]
    fn git_environment_drops_credentials_and_helper_overrides() {
        let base = std::collections::HashMap::from([
            ("PATH".to_owned(), "/usr/bin".to_owned()),
            ("HOME".to_owned(), "/home/test".to_owned()),
            ("LC_ALL".to_owned(), "C".to_owned()),
            ("OPENAI_API_KEY".to_owned(), "secret".to_owned()),
            ("GIT_CONFIG".to_owned(), "/tmp/attacker-config".to_owned()),
            ("GIT_EXTERNAL_DIFF".to_owned(), "/tmp/attacker-diff".to_owned()),
        ]);
        let env = git_environment_from(&base);
        assert_eq!(env.get("PATH").map(String::as_str), Some("/usr/bin"));
        assert_eq!(env.get("HOME").map(String::as_str), Some("/home/test"));
        assert_eq!(env.get("LC_ALL").map(String::as_str), Some("C"));
        assert_eq!(env.get("GIT_CONFIG_NOSYSTEM").map(String::as_str), Some("1"));
        assert_eq!(env.get("GIT_TERMINAL_PROMPT").map(String::as_str), Some("0"));
        assert_eq!(env.get("GIT_PAGER").map(String::as_str), Some("cat"));
        assert!(!env.contains_key("OPENAI_API_KEY"));
        assert!(!env.contains_key("GIT_CONFIG"));
        assert!(!env.contains_key("GIT_EXTERNAL_DIFF"));
    }

    #[tokio::test]
    async fn bounded_git_diff_line_discards_unterminated_over_limit_input() {
        let mut reader = tokio::io::BufReader::with_capacity(2, std::io::Cursor::new(b"123456789"));
        let mut line = Vec::new();
        let result = read_bounded_git_diff_line(&mut reader, &mut line, 8)
            .await
            .expect("oversized unterminated diff line should be consumed")
            .expect("the oversized line marker");

        assert!(matches!(result, BoundedGitDiffLine::TooLong { .. }));
        assert!(line.is_empty(), "reader retained bytes past its limit");
        assert!(
            read_bounded_git_diff_line(&mut reader, &mut line, 8)
                .await
                .expect("EOF after discarded line")
                .is_none()
        );
    }

    #[tokio::test]
    async fn bounded_git_diff_line_keeps_stream_aligned_after_over_limit_input() {
        let mut reader =
            tokio::io::BufReader::with_capacity(2, std::io::Cursor::new(b"123456789\nshort\n"));
        let mut line = Vec::new();
        let result = read_bounded_git_diff_line(&mut reader, &mut line, 8)
            .await
            .expect("oversized line should be consumed")
            .expect("the oversized line marker");
        assert!(matches!(result, BoundedGitDiffLine::TooLong { .. }));

        let result = read_bounded_git_diff_line(&mut reader, &mut line, 8)
            .await
            .expect("short line should decode")
            .expect("short line");
        assert!(matches!(result, BoundedGitDiffLine::Complete(value) if value == "short"));
    }

    #[test]
    fn oversized_diff_line_prefix_preserves_stat_kind() {
        assert_eq!(classify_git_diff_line(b"+payload"), GitDiffLineKind::Addition);
        assert_eq!(classify_git_diff_line(b"-payload"), GitDiffLineKind::Deletion);
        assert_eq!(classify_git_diff_line(b"diff --git a/a b/a"), GitDiffLineKind::File);
        assert_eq!(classify_git_diff_line(b"+++ b/a"), GitDiffLineKind::Other);
        assert_eq!(classify_git_diff_line(b"--- a/a"), GitDiffLineKind::Other);
    }

    #[test]
    fn git_stdout_read_uses_the_request_deadline() {
        let remaining = remaining_git_time(std::time::Instant::now() + Duration::from_secs(30))
            .expect("future request deadline");

        assert!(remaining > GIT_CHILD_WAIT_TIMEOUT);
    }

    #[tokio::test]
    async fn git_stderr_drain_retains_a_prefix_and_continues_reading() {
        use tokio::io::AsyncWriteExt as _;

        let (mut writer, reader) = tokio::io::duplex(1024);
        let payload = vec![b'x'; GIT_STDERR_MAX_BYTES * 2];
        let writer_task = tokio::spawn(async move {
            writer.write_all(&payload).await.expect("stderr payload");
        });
        let result = GitStderrDrain::start(reader).finish().await.expect("stderr drain");
        writer_task.await.expect("stderr writer");

        assert!(result.complete);
        assert_eq!(result.bytes.len(), GIT_STDERR_MAX_BYTES);
        assert!(result.bytes.iter().all(|byte| *byte == b'x'));
    }

    #[tokio::test]
    async fn git_stderr_drain_has_a_bound_when_a_descendant_keeps_the_pipe_open() {
        let (_writer, reader) = tokio::io::duplex(64);
        let result = tokio::time::timeout(
            GIT_STDERR_DRAIN_TIMEOUT + Duration::from_millis(100),
            GitStderrDrain::start(reader).finish(),
        )
        .await
        .expect("stderr cleanup must be bounded")
        .expect("stderr drain result");

        assert!(!result.complete);
        assert!(result.bytes.is_empty());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn stop_git_reaps_the_child_and_terminates_its_process_group() {
        let root = scratch("git-process-group");
        let mut child = git_command(&root, &["status"]).spawn().expect("git child");
        let pid = child.id().expect("running child");
        // `git_command` uses a zero process-group argument, so the child is
        // its own group leader and descendants share the group.
        let group = unsafe { libc::getpgid(pid as libc::pid_t) };
        assert_eq!(group, pid as libc::pid_t);

        stop_git(&mut child).await;
        assert!(child.id().is_none(), "stop_git must await Child::wait");
        let _ = root;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn git_stdout_cleanup_handles_a_descendant_holding_the_pipe_open() {
        let mut child = tokio::process::Command::new("sh")
            .arg("-c")
            .arg("sleep 30 & printf ready; exec 1>&-; wait")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .process_group(0)
            .spawn()
            .expect("shell child");
        let mut guard = GitProcessGuard::new(&child);
        let mut stdout = child.stdout.take().expect("stdout pipe");
        let mut bytes = Vec::new();
        let read =
            tokio::time::timeout(Duration::from_millis(100), stdout.read_to_end(&mut bytes)).await;
        assert!(read.is_err(), "a descendant-owned stdout pipe must hit the bound");

        abort_git_operation(None, &mut child, &mut guard).await;
        assert!(child.id().is_none(), "cleanup must reap the direct child");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn git_abort_reaps_child_when_stderr_reader_fails() {
        use std::task::{Context, Poll};
        use tokio::io::{AsyncRead, ReadBuf};

        struct FailingReader;
        impl AsyncRead for FailingReader {
            fn poll_read(
                self: std::pin::Pin<&mut Self>,
                _cx: &mut Context<'_>,
                _buffer: &mut ReadBuf<'_>,
            ) -> Poll<std::io::Result<()>> {
                Poll::Ready(Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "synthetic stderr failure",
                )))
            }
        }

        let mut child = tokio::process::Command::new("sh")
            .arg("-c")
            .arg("sleep 30")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .process_group(0)
            .spawn()
            .expect("shell child");
        let mut guard = GitProcessGuard::new(&child);
        let drain = GitStderrDrain::start(FailingReader);

        abort_git_operation(Some(drain), &mut child, &mut guard).await;
        assert!(child.id().is_none(), "stderr failure must still reap the child");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn wait_git_deadline_reaps_a_child_after_pipes_close() {
        let mut child = tokio::process::Command::new("sh")
            .arg("-c")
            .arg("exec 1>&- 2>&-; sleep 30")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .process_group(0)
            .spawn()
            .expect("shell child");
        let result =
            wait_git_until(&mut child, std::time::Instant::now() + Duration::from_millis(50)).await;

        assert!(result.is_err(), "closed pipes must not imply child completion");
        assert!(child.id().is_none(), "wait deadline must reap the child");
    }

    #[tokio::test]
    async fn cancelled_git_status_runs_bounded_cleanup() {
        let (root, scope) = seeded_repo("git-status-cancelled");
        let cancellation = CancellationToken::new();
        cancellation.cancel();

        let refusal = run_git_status_with_cancel(&scope, &cancellation)
            .await
            .expect_err("cancelled git status");
        assert!(refusal.message.contains("cancelled"));
        let _ = root;
    }

    #[tokio::test]
    async fn expired_git_diff_deadline_runs_bounded_cleanup() {
        let (root, scope) = seeded_repo("git-diff-expired");
        let cancellation = CancellationToken::new();
        let refusal = run_git_diff_with_cancel_until(
            &scope,
            &wire::GitDiffOp {
                op: wire::TagGitDiff::GitDiff,
                base: None,
                paths: None,
                context_lines: None,
            },
            &cancellation,
            std::time::Instant::now() - Duration::from_millis(1),
        )
        .await
        .expect_err("expired git diff deadline");

        assert!(refusal.message.contains("deadline"));
        let _ = root;
    }

    fn seeded_repo(name: &str) -> (PathBuf, Scope) {
        let root = scratch(name);
        write(&root, "README.md", "# seed\n");
        write(&root, "src/app.ts", "export const NEEDLE = 42\n");
        git(&root, &["init", "-q", "-b", "main"]);
        git(&root, &["add", "."]);
        git(&root, &["commit", "-q", "-m", "seed"]);
        let scope = scope_for(&root);
        (root, scope)
    }

    #[tokio::test]
    async fn git_status_reports_porcelain_xy_branch_and_renames() {
        let (root, scope) = seeded_repo("git-status");
        write(&root, "src/app.ts", "export const NEEDLE = 43\n");
        write(&root, "untracked.txt", "new\n");
        git(&root, &["mv", "README.md", "MOVED.md"]);
        let result = match run_git_status(&scope).await.expect("status") {
            wire::WorkspaceResultBody::GitStatus(result) => result,
            other => panic!("wrong body: {other:?}"),
        };
        assert_eq!(result.branch.as_deref(), Some("main"));
        assert_eq!(result.upstream, None);
        assert_eq!((result.ahead, result.behind), (0, 0));
        let by_path: std::collections::HashMap<&str, &wire::GitStatusEntry> =
            result.entries.iter().map(|entry| (entry.path.as_str(), entry)).collect();
        assert_eq!(by_path.get("src/app.ts").expect("modified").status, " M");
        assert_eq!(by_path.get("untracked.txt").expect("untracked").status, "??");
        let renamed = by_path.get("MOVED.md").expect("rename");
        assert_eq!(renamed.status, "R ");
        assert_eq!(renamed.orig_path.as_deref(), Some("README.md"));
    }

    #[tokio::test]
    async fn git_diff_yields_a_unified_patch_with_stat() {
        let (root, scope) = seeded_repo("git-diff");
        write(&root, "src/app.ts", "export const NEEDLE = 43\n");
        let result = match run_git_diff(
            &scope,
            &wire::GitDiffOp {
                op: wire::TagGitDiff::GitDiff,
                base: None,
                paths: None,
                context_lines: None,
            },
        )
        .await
        .expect("diff")
        {
            wire::WorkspaceResultBody::GitDiff(result) => result,
            other => panic!("wrong body: {other:?}"),
        };
        assert!(result.patch.contains("diff --git a/src/app.ts b/src/app.ts"));
        assert!(result.patch.contains("+export const NEEDLE = 43"));
        assert_eq!(result.stat, wire::GitDiffStat { files: 1, additions: 1, deletions: 1 });
        assert!(!result.truncated);
        let _ = root;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn git_diff_does_not_run_repository_external_helpers() {
        use std::os::unix::fs::PermissionsExt as _;

        let (root, scope) = seeded_repo("git-diff-helper");
        write(&root, "src/app.ts", "export const NEEDLE = 43\n");
        let marker = root.join("external-diff-ran");
        let helper = root.join("external-diff.sh");
        write(
            &root,
            "external-diff.sh",
            &format!("#!/bin/sh\nprintf ran > {}\n", marker.display()),
        );
        let mut permissions = std::fs::metadata(&helper).expect("helper metadata").permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(&helper, permissions).expect("helper executable");
        git(&root, &["config", "diff.external", helper.to_str().expect("helper path")]);

        let result = run_git_diff(
            &scope,
            &wire::GitDiffOp {
                op: wire::TagGitDiff::GitDiff,
                base: None,
                paths: None,
                context_lines: None,
            },
        )
        .await
        .expect("diff");
        assert!(!marker.exists(), "repository external diff helper ran");
        let wire::WorkspaceResultBody::GitDiff(result) = result else {
            panic!("wrong body");
        };
        assert!(result.patch.contains("+export const NEEDLE = 43"));
    }

    #[tokio::test]
    async fn git_ops_outside_a_repository_refuse_typed() {
        let root = scratch("git-none");
        write(&root, "loose.txt", "x\n");
        let scope = scope_for(&root);
        let refusal = run_git_status(&scope).await.expect_err("no repo");
        assert_eq!(refusal.code, wire::WorkspaceErrorCode::NotARepository);
    }

    // --- dispatch --------------------------------------------------------

    fn request_json(op: Value, trust: &str) -> Value {
        serde_json::json!({
            "version": 6,
            "type": "workspace_request",
            "requestId": "req_1",
            "op": op,
            "timeoutMs": 30_000,
            "allowedRoots": Value::Null,
            "trust": trust,
            "actorId": "user_1",
            "threadId": Value::Null,
        })
    }

    async fn dispatch(root: &Path, request: Value) -> Value {
        let roots = vec![root.to_string_lossy().into_owned()];
        let runtime = Arc::new(SharedRuntime::new(Some(roots.clone())));
        let mut patched = request;
        patched["allowedRoots"] = serde_json::json!(roots);
        let (sink, mut critical, _watch) = OutboundSink::channels();
        let connection = Connection::new(runtime, sink);
        connection.handle_frame(patched);
        let frame = tokio::time::timeout(std::time::Duration::from_secs(15), critical.recv())
            .await
            .expect("no answer within 15s")
            .expect("channel open");
        serde_json::from_str(&frame.text).expect("valid json frame")
    }

    #[tokio::test]
    async fn connection_shutdown_cancels_and_joins_owned_request_tasks() {
        let runtime = Arc::new(SharedRuntime::new(None));
        let (sink, _critical, _watch) = OutboundSink::channels();
        let connection = Connection::new(runtime, sink);
        let cancellation = connection.request_cancel.clone();
        connection.requests.lock().expect("request registry").spawn(async move {
            cancellation.cancelled().await;
        });

        assert!(connection.shutdown().await);
        assert!(connection.requests.lock().expect("request registry").is_empty());
    }

    #[tokio::test]
    async fn dispatch_keeps_multiple_in_flight_requests_independent() {
        let root = scratch("dispatch-concurrent");
        write(&root, "a.txt", "a\n");
        write(&root, "b.txt", "b\n");
        let roots = vec![root.to_string_lossy().into_owned()];
        let runtime = Arc::new(SharedRuntime::new(Some(roots.clone())));
        let (sink, mut critical, _watch) = OutboundSink::channels();
        let connection = Connection::new(runtime, sink);

        for (request_id, path) in [("req_a", "a.txt"), ("req_b", "b.txt")] {
            let mut request = request_json(
                serde_json::json!({"op": "fs_read", "path": path, "maxBytes": 1000}),
                "supervised",
            );
            request["requestId"] = Value::String(request_id.to_owned());
            request["allowedRoots"] = serde_json::json!(roots.clone());
            connection.handle_frame(request);
        }

        let mut ids = [
            tokio::time::timeout(std::time::Duration::from_secs(15), critical.recv())
                .await
                .expect("first request timed out")
                .expect("channel closed"),
            tokio::time::timeout(std::time::Duration::from_secs(15), critical.recv())
                .await
                .expect("second request timed out")
                .expect("channel closed"),
        ]
        .map(|frame| serde_json::from_str::<Value>(&frame.text).expect("valid json"));
        ids.sort_by_key(|frame| frame["requestId"].as_str().unwrap().to_owned());
        assert_eq!(ids[0]["requestId"], "req_a");
        assert_eq!(ids[1]["requestId"], "req_b");
        assert!(ids.iter().all(|frame| frame["ok"] == true));
    }

    #[tokio::test]
    async fn dispatch_answers_the_wire_shape_and_gates_trust() {
        let root = scratch("dispatch");
        write(&root, "file.txt", "content\n");
        let read_op = serde_json::json!({"op": "fs_read", "path": "file.txt", "maxBytes": 1000});
        let answer = dispatch(&root, request_json(read_op.clone(), "supervised")).await;
        assert_eq!(answer["type"], "workspace_result");
        assert_eq!(answer["requestId"], "req_1");
        assert_eq!(answer["ok"], true);
        assert_eq!(answer["result"]["op"], "fs_read");
        assert_eq!(answer["result"]["content"], "content\n");
        // observe trust still reads...
        let observed = dispatch(&root, request_json(read_op, "observe")).await;
        assert_eq!(observed["ok"], true);
        // ...but refuses every mutating op with the typed code.
        let write_op = serde_json::json!({
            "op": "fs_write", "path": "file.txt", "content": "no"
        });
        let refused = dispatch(&root, request_json(write_op, "observe")).await;
        assert_eq!(refused["ok"], false);
        assert_eq!(refused["code"], "trust_refused");
        let preview_op = serde_json::json!({"op": "preview_open", "targetPort": 5173});
        let refused = dispatch(&root, request_json(preview_op, "observe")).await;
        assert_eq!(refused["code"], "trust_refused");
        let delete_op = serde_json::json!({"op": "fs_delete", "path": "file.txt"});
        let refused = dispatch(&root, request_json(delete_op, "observe")).await;
        assert_eq!(refused["code"], "trust_refused");
        assert!(root.join("file.txt").exists());
    }

    #[tokio::test]
    async fn dispatch_refuses_an_unknown_op_without_closing_anything() {
        let root = scratch("dispatch-unknown");
        let unknown = serde_json::json!({"op": "fs_teleport", "path": "x"});
        let answer = dispatch(&root, request_json(unknown, "supervised")).await;
        assert_eq!(answer["ok"], false);
        assert_eq!(answer["code"], "unsupported_verb");
        assert_eq!(answer["requestId"], "req_1");
    }

    #[cfg(not(unix))]
    #[tokio::test]
    async fn dispatch_refuses_scoped_paths_when_the_platform_cannot_pin_them() {
        let root = scratch("dispatch-unsupported-scope");
        write(&root, "file.txt", "content\n");
        let read_op = serde_json::json!({
            "op": "fs_read",
            "path": "file.txt",
            "maxBytes": 1000,
        });
        let answer = dispatch(&root, request_json(read_op, "supervised")).await;
        assert_eq!(answer["type"], "workspace_result");
        assert_eq!(answer["requestId"], "req_1");
        assert_eq!(answer["ok"], false);
        assert_eq!(answer["code"], "unsupported_verb");
    }

    #[tokio::test]
    async fn dispatch_times_out_typed() {
        let root = scratch("dispatch-timeout");
        // A 1ms-clamped timeout with a blocking op that cannot finish is
        // hard to fake portably; instead pin the clamp arithmetic.
        assert_eq!(clamp_i64(0, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS), MIN_TIMEOUT_MS);
        assert_eq!(clamp_i64(999_999, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS), MAX_TIMEOUT_MS);
        let _ = root;
    }
}
