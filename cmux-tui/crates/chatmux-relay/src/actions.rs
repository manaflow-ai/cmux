//! Relay-side execution verbs (relay wire v3, W57; v5 process credentials).
//!
//! Behavior port of `packages/relay/bin/actions.mjs` (chatmux repo); tests
//! mirror `actions.test.mjs`. The Worker sends `action_request` frames over
//! the paired socket; this module runs them with the relay user's
//! permissions and answers `action_result`.
//!
//! Discipline:
//! - trust is re-checked HERE from the machine's own reconciled config
//!   (observe = the read-only verbs only), so a compromised or buggy server
//!   still cannot run anything the owner did not allow;
//! - path scoping: when allowed roots exist (local `--allow-root` config
//!   and/or the machine row echoed by the server) every file path and exec
//!   cwd must resolve inside them — enforced against BOTH lists, first
//!   lexically and then against the canonical (realpath) host view;
//! - scoped Unix file operations resolve every component relative to pinned
//!   directory descriptors, with O_NOFOLLOW on each lookup;
//! - Windows refuses scoped file operations until equivalent handle-relative
//!   traversal is available;
//! - exec spawns with a scrubbed environment (no inherited API keys) and a
//!   hard timeout (whole process group: SIGTERM, then SIGKILL after grace);
//! - all output is truncated to bounded sizes before it goes on the wire.

use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use serde_json::{Map, Value, json};

pub const READ_ONLY_VERBS: [&str; 4] = ["read", "ls", "grep", "find"];
pub const ACTION_VERBS: [&str; 6] = ["exec", "read", "write", "ls", "grep", "find"];

/// Bounded sizes so one action can never flood the socket.
pub const MAX_OUTPUT_CHARS: usize = 60_000;
pub const MAX_READ_BYTES: u64 = 2_000_000;
pub const MAX_LISTING_ENTRIES: usize = 1_000;

pub const DEFAULT_TIMEOUT_MS: u64 = 30_000;
pub const MAX_TIMEOUT_MS: u64 = 300_000;
pub const MAX_PATH_CHARS: usize = 4_096;

const MAX_RUNTIME_ENVIRONMENT_ENTRIES: usize = 64;
const MAX_RUNTIME_ENVIRONMENT_BYTES: usize = 256_000;
const MAX_RUNTIME_FILES: usize = 8;
pub(crate) const MAX_BLOCKING_FILE_ACTIONS: usize = 8;
const MAX_WAIT_RETRIES: u32 = 50;

// ---------------------------------------------------------------------------
// Path policy (pure)
// ---------------------------------------------------------------------------

/// Node `path.resolve` equivalent: absolute values normalize on their own,
/// relative values join the base first; `.` and `..` collapse lexically.
fn lexical_resolve(base: &Path, value: &str) -> PathBuf {
    let candidate = Path::new(value);
    let joined =
        if candidate.is_absolute() { candidate.to_path_buf() } else { base.join(candidate) };
    let mut out = PathBuf::new();
    for component in joined.components() {
        match component {
            Component::Prefix(prefix) => out.push(prefix.as_os_str()),
            Component::RootDir => out.push(Component::RootDir.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    // Above the root: Node clamps at the root.
                }
            }
            Component::Normal(part) => out.push(part),
        }
    }
    if out.as_os_str().is_empty() { base.to_path_buf() } else { out }
}

/// Expand a leading `~` and resolve to an absolute path.
pub fn expand_path(raw_path: &str, home: &Path, base: &Path) -> PathBuf {
    if raw_path == "~" {
        return home.to_path_buf();
    }
    if let Some(rest) = raw_path.strip_prefix("~/").or_else(|| raw_path.strip_prefix("~\\")) {
        return lexical_resolve(home, rest);
    }
    lexical_resolve(base, raw_path)
}

fn within_root(path: &Path, root: &Path) -> bool {
    path.starts_with(root)
}

fn relative_path_escapes(raw_path: &str) -> bool {
    let mut depth: i64 = 0;
    for segment in raw_path.split(['/', '\\']) {
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

fn is_tilde_request(value: &str) -> bool {
    value == "~" || value.starts_with("~/") || value.starts_with("~\\")
}

fn has_encoded_path_syntax(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    ["%00", "%25", "%2e", "%2f", "%5c"].iter().any(|needle| lower.contains(needle))
}

pub fn validate_request_path(value: &str) -> Result<(), String> {
    if value.len() > MAX_PATH_CHARS {
        return Err(format!("path exceeds {MAX_PATH_CHARS} characters"));
    }
    if value.chars().any(|c| c <= '\u{001f}' || c == '\u{007f}') {
        return Err("path contains a control character".to_owned());
    }
    if has_encoded_path_syntax(value) {
        return Err("percent-encoded path syntax is not accepted".to_owned());
    }
    if value.starts_with("//") || value.starts_with("\\\\") {
        return Err("ambiguous leading path separators are not accepted".to_owned());
    }
    if cfg!(windows) {
        let drive_relative = value.len() >= 2
            && value.as_bytes()[1] == b':'
            && value.as_bytes()[0].is_ascii_alphabetic()
            && !Path::new(value).is_absolute();
        if drive_relative {
            return Err("drive-relative paths are not accepted".to_owned());
        }
    }
    // A backslash is a filename character on POSIX but a separator on
    // Windows. Refuse that ambiguous spelling on POSIX so one request cannot
    // acquire different authority after crossing hosts.
    if cfg!(not(windows)) && value.contains('\\') {
        return Err("use '/' as the path separator on this machine".to_owned());
    }
    Ok(())
}

pub struct ScopedPath {
    pub path: PathBuf,
    pub absolute_request: bool,
    pub workdir: PathBuf,
}

/// Root lists: local config roots and the server-echoed roots. Empty or
/// absent lists impose nothing; every NON-empty list must contain the path.
pub type RootLists<'a> = [Option<&'a [String]>; 2];

/// Windows does not yet have the handle-relative directory traversal needed
/// to enforce a scoped file root across a symlink or rename race. Keep the
/// refusal typed at the action boundary instead of treating this as a path
/// error or silently using an unsafe path walk.
pub(crate) const SCOPED_FILE_ROOTS_UNSUPPORTED: &str =
    "scoped filesystem operations are unavailable on this relay platform";

pub(crate) fn ensure_scoped_file_roots_available(
    supports_descriptor_scoping: bool,
    root_lists: &RootLists<'_>,
) -> Result<(), &'static str> {
    if supports_descriptor_scoping || !root_lists.iter().flatten().any(|roots| !roots.is_empty()) {
        Ok(())
    } else {
        Err(SCOPED_FILE_ROOTS_UNSUPPORTED)
    }
}

/// Resolve a request path and enforce every non-empty root list.
pub fn resolve_scoped_path(
    raw_path: &str,
    root_lists: &RootLists<'_>,
    home: &Path,
    workdir: &str,
) -> Result<ScopedPath, String> {
    validate_request_path(raw_path)?;
    let absolute_request = Path::new(raw_path).is_absolute() || is_tilde_request(raw_path);
    if !absolute_request && relative_path_escapes(raw_path) {
        return Err("a relative path cannot escape the target workdir".to_owned());
    }
    let resolved_workdir = expand_path(workdir, home, home);
    let path = expand_path(raw_path, home, &resolved_workdir);
    if !path.is_absolute() {
        return Err(format!("path did not resolve absolute: {}", path.display()));
    }
    if !absolute_request && !within_root(&path, &resolved_workdir) {
        return Err(format!(
            "relative path {} is outside the target workdir {}",
            path.display(),
            resolved_workdir.display(),
        ));
    }
    for roots in root_lists.iter().flatten() {
        if roots.is_empty() {
            continue;
        }
        let resolved: Vec<PathBuf> =
            roots.iter().map(|root| expand_path(root, home, home)).collect();
        if !resolved.iter().any(|root| within_root(&path, root)) {
            let joined =
                resolved.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(", ");
            return Err(format!(
                "path {} is outside this machine's allowed roots ({joined})",
                path.display(),
            ));
        }
    }
    Ok(ScopedPath { path, absolute_request, workdir: resolved_workdir })
}

// ---------------------------------------------------------------------------
// Host-aware second pass (realpath + O_NOFOLLOW)
// ---------------------------------------------------------------------------

/// A typed refusal from the canonical host pass (mapped to path_forbidden).
struct HostPathRefusal(String);

enum HostError {
    Refusal(String),
    Io(std::io::Error),
}

impl From<HostPathRefusal> for HostError {
    fn from(refusal: HostPathRefusal) -> HostError {
        HostError::Refusal(refusal.0)
    }
}

impl From<std::io::Error> for HostError {
    fn from(error: std::io::Error) -> HostError {
        HostError::Io(error)
    }
}

fn is_not_found(error: &std::io::Error) -> bool {
    error.kind() == std::io::ErrorKind::NotFound
}

#[cfg(unix)]
fn is_already_exists(error: &std::io::Error) -> bool {
    error.raw_os_error() == Some(libc::EEXIST)
}

fn is_eloop(error: &std::io::Error) -> bool {
    #[cfg(unix)]
    {
        error.raw_os_error() == Some(libc::ELOOP)
    }
    #[cfg(not(unix))]
    {
        // `FilesystemLoop` is unstable on Windows. Symlink races are
        // rejected by the metadata checks and O_NOFOLLOW where available.
        let _ = error;
        false
    }
}

fn assert_not_dangling_link(path: &Path) -> Result<(), HostError> {
    match std::fs::symlink_metadata(path) {
        Ok(info) => {
            if info.file_type().is_symlink() {
                return Err(HostError::Refusal(format!(
                    "path {} is a symlink whose target cannot be resolved",
                    path.display(),
                )));
            }
            Ok(())
        }
        Err(error) if is_not_found(&error) => Ok(()),
        Err(error) => Err(HostError::Io(error)),
    }
}

/// realpath the nearest existing ancestor and re-append the missing suffix.
/// realpath reports NotFound for both a genuinely absent component and a
/// dangling symlink; never reinterpret the latter as a safe create target.
fn canonical_potential_path(path: &Path) -> Result<PathBuf, HostError> {
    let mut cursor = path.to_path_buf();
    let mut suffix: Vec<std::ffi::OsString> = Vec::new();
    loop {
        match std::fs::canonicalize(&cursor) {
            Ok(canonical) => {
                let mut out = canonical;
                for part in suffix.iter().rev() {
                    out.push(part);
                }
                return Ok(out);
            }
            Err(error) if is_not_found(&error) => {
                assert_not_dangling_link(&cursor)?;
                let Some(parent) = cursor.parent().map(Path::to_path_buf) else {
                    return Err(HostError::Io(error));
                };
                if parent == cursor {
                    return Err(HostError::Io(error));
                }
                let Some(name) = cursor.file_name().map(std::ffi::OsStr::to_os_string) else {
                    return Err(HostError::Io(error));
                };
                suffix.push(name);
                cursor = parent;
            }
            Err(error) => return Err(HostError::Io(error)),
        }
    }
}

fn canonical_root_lists(
    root_lists: &[&[String]],
    home: &Path,
) -> Result<Vec<Vec<PathBuf>>, HostError> {
    let mut canonical = Vec::new();
    for roots in root_lists {
        if roots.is_empty() {
            continue;
        }
        let mut list = Vec::new();
        for root in *roots {
            list.push(canonical_potential_path(&expand_path(root, home, home))?);
        }
        canonical.push(list);
    }
    Ok(canonical)
}

fn enforce_canonical_roots(path: &Path, root_lists: &[Vec<PathBuf>]) -> Result<(), String> {
    for roots in root_lists {
        if !roots.iter().any(|root| within_root(path, root)) {
            let joined =
                roots.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(", ");
            return Err(format!(
                "path {} resolves outside this machine's allowed roots ({joined})",
                path.display(),
            ));
        }
    }
    Ok(())
}

pub struct HostScopedPath {
    pub path: PathBuf,
    roots: Vec<Vec<PathBuf>>,
    #[cfg(unix)]
    anchor: std::fs::File,
    #[cfg(unix)]
    relative: PathBuf,
}

#[cfg(unix)]
fn open_dir_no_symlinks(path: &Path, create_missing: bool) -> Result<std::fs::File, HostError> {
    use std::os::fd::FromRawFd as _;
    use std::os::unix::ffi::OsStrExt as _;

    let root = std::ffi::CString::new("/").expect("root has no NUL");
    let root_fd =
        unsafe { libc::open(root.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC) };
    if root_fd < 0 {
        return Err(HostError::Io(std::io::Error::last_os_error()));
    }
    let mut current = unsafe { std::fs::File::from_raw_fd(root_fd) };
    for component in path.components() {
        let Component::Normal(name) = component else { continue };
        let name = std::ffi::CString::new(name.as_bytes())
            .map_err(|_| HostError::Refusal("path contains an embedded NUL byte".to_owned()))?;
        let mut fd = unsafe {
            libc::openat(
                std::os::fd::AsRawFd::as_raw_fd(&current),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 && create_missing && is_not_found(&std::io::Error::last_os_error()) {
            let made = unsafe {
                libc::mkdirat(std::os::fd::AsRawFd::as_raw_fd(&current), name.as_ptr(), 0o777)
            };
            if made < 0 && !is_already_exists(&std::io::Error::last_os_error()) {
                return Err(HostError::Io(std::io::Error::last_os_error()));
            }
            fd = unsafe {
                libc::openat(
                    std::os::fd::AsRawFd::as_raw_fd(&current),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
        }
        if fd < 0 {
            let error = std::io::Error::last_os_error();
            return Err(if is_eloop(&error) {
                HostError::Refusal("refusing a path whose ancestor changed to a symlink".to_owned())
            } else {
                HostError::Io(error)
            });
        }
        current = unsafe { std::fs::File::from_raw_fd(fd) };
    }
    Ok(current)
}

#[cfg(unix)]
fn deepest_containing_root(path: &Path, roots: &[Vec<PathBuf>]) -> Option<PathBuf> {
    roots
        .iter()
        .flatten()
        .filter(|root| path.starts_with(root))
        .max_by_key(|root| root.components().count())
        .cloned()
}

#[cfg(unix)]
fn open_beneath(
    anchor: &std::fs::File,
    relative: &Path,
    final_flags: libc::c_int,
    create_parents: bool,
) -> Result<std::fs::File, HostError> {
    use std::os::fd::{AsRawFd as _, FromRawFd as _};
    use std::os::unix::ffi::OsStrExt as _;

    let parts = relative
        .components()
        .map(|component| match component {
            Component::Normal(name) => Ok(name),
            _ => Err(HostError::Refusal("invalid descriptor-relative path".to_owned())),
        })
        .collect::<Result<Vec<_>, _>>()?;
    if parts.is_empty() {
        return anchor.try_clone().map_err(HostError::Io);
    }
    let mut current = anchor.try_clone()?;
    for name in &parts[..parts.len() - 1] {
        let name = std::ffi::CString::new(name.as_bytes())
            .map_err(|_| HostError::Refusal("path contains an embedded NUL byte".to_owned()))?;
        let mut fd = unsafe {
            libc::openat(
                current.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 && create_parents && is_not_found(&std::io::Error::last_os_error()) {
            let made = unsafe { libc::mkdirat(current.as_raw_fd(), name.as_ptr(), 0o777) };
            if made < 0 && !is_already_exists(&std::io::Error::last_os_error()) {
                return Err(HostError::Io(std::io::Error::last_os_error()));
            }
            fd = unsafe {
                libc::openat(
                    current.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
        }
        if fd < 0 {
            let error = std::io::Error::last_os_error();
            return Err(if is_eloop(&error) {
                HostError::Refusal("refusing a path whose ancestor changed to a symlink".to_owned())
            } else {
                HostError::Io(error)
            });
        }
        current = unsafe { std::fs::File::from_raw_fd(fd) };
    }
    let name = std::ffi::CString::new(parts.last().expect("nonempty").as_bytes())
        .map_err(|_| HostError::Refusal("path contains an embedded NUL byte".to_owned()))?;
    let fd = unsafe {
        libc::openat(
            current.as_raw_fd(),
            name.as_ptr(),
            final_flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o666,
        )
    };
    if fd < 0 {
        let error = std::io::Error::last_os_error();
        return Err(if is_eloop(&error) {
            HostError::Refusal("refusing a path that changed to a symlink".to_owned())
        } else {
            HostError::Io(error)
        });
    }
    Ok(unsafe { std::fs::File::from_raw_fd(fd) })
}

/// Host-aware second pass. Existing paths are realpathed and operations use
/// that canonical path, so a stable symlink inside a workdir/root cannot
/// redirect an operation outside it. Missing write targets canonicalize
/// from the nearest existing ancestor.
pub fn resolve_scoped_host_path(
    raw_path: &str,
    root_lists: &RootLists<'_>,
    home: &Path,
    workdir: &str,
    allow_missing: bool,
) -> Result<Result<HostScopedPath, String>, std::io::Error> {
    let run = || -> Result<HostScopedPath, HostError> {
        let lexical =
            resolve_scoped_path(raw_path, root_lists, home, workdir).map_err(HostError::Refusal)?;
        let workdir_list: Vec<String>;
        let mut effective: Vec<&[String]> = root_lists.iter().flatten().copied().collect();
        if !lexical.absolute_request {
            workdir_list = vec![lexical.workdir.display().to_string()];
            effective.push(&workdir_list);
        }
        let roots = canonical_root_lists(&effective, home)?;
        let path = if allow_missing {
            canonical_potential_path(&lexical.path)?
        } else {
            std::fs::canonicalize(&lexical.path)?
        };
        enforce_canonical_roots(&path, &roots).map_err(HostError::Refusal)?;
        #[cfg(unix)]
        {
            let anchor_path =
                deepest_containing_root(&path, &roots).unwrap_or_else(|| PathBuf::from("/"));
            let relative = path
                .strip_prefix(&anchor_path)
                .map_err(|_| {
                    HostError::Refusal("path is outside its descriptor anchor".to_owned())
                })?
                .to_path_buf();
            let anchor = open_dir_no_symlinks(&anchor_path, allow_missing)?;
            Ok(HostScopedPath { path, roots, anchor, relative })
        }
        #[cfg(not(unix))]
        {
            if !roots.is_empty() {
                return Err(HostError::Refusal(SCOPED_FILE_ROOTS_UNSUPPORTED.to_owned()));
            }
            Ok(HostScopedPath { path, roots })
        }
    };
    match run() {
        Ok(scoped) => Ok(Ok(scoped)),
        Err(HostError::Refusal(message)) => Ok(Err(message)),
        Err(HostError::Io(error)) => Err(error),
    }
}

// ---------------------------------------------------------------------------
// Bounded file I/O (O_NOFOLLOW where the host supports it)
// ---------------------------------------------------------------------------

#[cfg(not(unix))]
fn open_options_no_follow(read: bool) -> std::fs::OpenOptions {
    let mut options = std::fs::OpenOptions::new();
    if read {
        options.read(true);
    } else {
        options.write(true).create(true).truncate(true);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    options
}

fn read_utf8_no_follow(path: &HostScopedPath) -> Result<String, HostError> {
    use std::io::Read as _;
    #[cfg(unix)]
    let file =
        open_beneath(&path.anchor, &path.relative, libc::O_RDONLY | libc::O_NONBLOCK, false)?;
    #[cfg(not(unix))]
    let mut file = open_options_no_follow(true).open(&path.path).map_err(|error| {
        if is_eloop(&error) {
            HostError::Refusal("refusing a symlink that changed during read".to_owned())
        } else {
            HostError::Io(error)
        }
    })?;
    let info = file.metadata()?;
    if !info.file_type().is_file() {
        return Err(HostError::Refusal("read only supports regular files".to_owned()));
    }
    if info.len() > MAX_READ_BYTES {
        return Err(HostError::Refusal(format!(
            "file is {} bytes (max {MAX_READ_BYTES}); read a smaller file or use grep",
            info.len(),
        )));
    }
    let mut bytes = Vec::new();
    file.take(MAX_READ_BYTES.saturating_add(1)).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_READ_BYTES {
        return Err(HostError::Refusal(format!(
            "file grew beyond the {MAX_READ_BYTES} byte read limit"
        )));
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn write_utf8_no_follow(path: &HostScopedPath, content: &str) -> Result<(), HostError> {
    use std::io::Write as _;
    let parent = path.path.parent().unwrap_or(Path::new("."));
    // Check the requested parent before creating anything. Creating an
    // untrusted directory tree first can mutate paths outside the allowed
    // roots, even when the final file check rejects the write.
    enforce_canonical_roots(parent, &path.roots).map_err(HostError::Refusal)?;
    #[cfg(unix)]
    let mut file = match open_beneath(
        &path.anchor,
        &path.relative,
        libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC | libc::O_NONBLOCK,
        true,
    ) {
        Err(HostError::Io(error)) if error.raw_os_error() == Some(libc::ENXIO) => {
            return Err(HostError::Refusal("write only supports regular files".to_owned()));
        }
        result => result?,
    };
    #[cfg(not(unix))]
    let mut file = {
        create_parent_dirs_no_symlink(parent)?;
        let canonical_parent = std::fs::canonicalize(parent)?;
        let file_name =
            path.path.file_name().map(std::ffi::OsStr::to_os_string).unwrap_or_default();
        let canonical = canonical_parent.join(file_name);
        assert_not_dangling_link(&canonical)?;
        enforce_canonical_roots(&canonical, &path.roots).map_err(HostError::Refusal)?;
        open_options_no_follow(false).open(&canonical).map_err(|error| {
            if is_eloop(&error) {
                HostError::Refusal("refusing a symlink that changed during write".to_owned())
            } else {
                HostError::Io(error)
            }
        })?
    };
    if !file.metadata()?.file_type().is_file() {
        return Err(HostError::Refusal("write only supports regular files".to_owned()));
    }
    file.write_all(content.as_bytes())?;
    Ok(())
}

#[cfg(not(unix))]
fn create_parent_dirs_no_symlink(path: &Path) -> Result<(), HostError> {
    // Preserve Windows drive prefixes while walking absolute paths. A path
    // such as `C:\\work\\out` starts with Prefix and RootDir components.
    let mut current = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(prefix) => {
                current.push(prefix.as_os_str());
                continue;
            }
            Component::RootDir => {
                current.push(Component::RootDir.as_os_str());
                continue;
            }
            Component::CurDir => continue,
            Component::Normal(name) => current.push(name),
            _ => return Err(HostError::Refusal("invalid parent path".to_owned())),
        }
        match std::fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(HostError::Refusal(format!("path {} is a symlink", current.display())));
            }
            Ok(metadata) if !metadata.is_dir() => {
                return Err(HostError::Refusal(format!(
                    "path {} is not a directory",
                    current.display()
                )));
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                std::fs::create_dir(&current)?;
            }
            Err(error) => return Err(HostError::Io(error)),
        }
    }
    Ok(())
}

struct ScopedDirEntry {
    name: std::ffi::OsString,
    is_dir: bool,
}

struct ScopedDirEntries {
    entries: Vec<ScopedDirEntry>,
    truncated: bool,
}

/// Read a bounded directory listing.
///
/// Keep at most one entry beyond the response cap, then stop scanning.
fn read_dir_scoped(path: &HostScopedPath) -> Result<ScopedDirEntries, HostError> {
    #[cfg(unix)]
    {
        use std::ffi::CStr;
        use std::os::fd::AsRawFd as _;
        use std::os::unix::ffi::OsStringExt as _;

        let directory =
            open_beneath(&path.anchor, &path.relative, libc::O_RDONLY | libc::O_DIRECTORY, false)?;
        let fd = unsafe { libc::dup(directory.as_raw_fd()) };
        if fd < 0 {
            return Err(HostError::Io(std::io::Error::last_os_error()));
        }
        let stream = unsafe { libc::fdopendir(fd) };
        if stream.is_null() {
            unsafe { libc::close(fd) };
            return Err(HostError::Io(std::io::Error::last_os_error()));
        }
        let mut entries = Vec::with_capacity(MAX_LISTING_ENTRIES.min(64));
        let mut truncated = false;
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
            if entries.len() < MAX_LISTING_ENTRIES {
                entries.push(ScopedDirEntry {
                    name: std::ffi::OsString::from_vec(name.to_vec()),
                    is_dir: entry.d_type == libc::DT_DIR,
                });
            } else {
                truncated = true;
                break;
            }
        }
        if unsafe { libc::closedir(stream) } != 0 {
            return Err(HostError::Io(std::io::Error::last_os_error()));
        }
        Ok(ScopedDirEntries { entries, truncated })
    }
    #[cfg(not(unix))]
    {
        let mut entries = Vec::with_capacity(MAX_LISTING_ENTRIES.min(64));
        let mut truncated = false;
        for entry in std::fs::read_dir(&path.path).map_err(HostError::Io)? {
            let entry = entry.map_err(HostError::Io)?;
            if entries.len() < MAX_LISTING_ENTRIES {
                entries.push(ScopedDirEntry {
                    name: entry.file_name(),
                    is_dir: entry.file_type().map_err(HostError::Io)?.is_dir(),
                });
            } else {
                truncated = true;
                break;
            }
        }
        Ok(ScopedDirEntries { entries, truncated })
    }
}

#[cfg(unix)]
fn inherited_path(path: &HostScopedPath) -> Result<(std::fs::File, String), HostError> {
    use std::os::fd::AsRawFd as _;
    let target =
        open_beneath(&path.anchor, &path.relative, libc::O_RDONLY | libc::O_NONBLOCK, false)?;
    let metadata = target.metadata()?;
    let suffix = if metadata.is_dir() {
        "/."
    } else if metadata.is_file() {
        ""
    } else {
        return Err(HostError::Refusal("path must be a regular file or directory".to_owned()));
    };
    let fd = target.as_raw_fd();
    if unsafe { libc::fcntl(fd, libc::F_SETFD, 0) } < 0 {
        return Err(HostError::Io(std::io::Error::last_os_error()));
    }
    Ok((target, format!("/dev/fd/{fd}{suffix}")))
}

#[cfg(unix)]
fn inherited_directory_path(path: &HostScopedPath) -> Result<(std::fs::File, String), HostError> {
    let (guard, inherited) = inherited_path(path)?;
    if !inherited.ends_with("/.") {
        return Err(HostError::Refusal("working directory must be a directory".to_owned()));
    }
    Ok((guard, inherited))
}

// ---------------------------------------------------------------------------
// Output bounds, timeouts, environment
// ---------------------------------------------------------------------------

pub struct TruncatedOutput {
    pub output: String,
    pub truncated: bool,
}

pub fn truncate_output(output: &str, cap: usize) -> TruncatedOutput {
    let total = output.chars().count();
    if total <= cap {
        return TruncatedOutput { output: output.to_owned(), truncated: false };
    }
    let head: String = output.chars().take(cap).collect();
    TruncatedOutput {
        output: format!("{head}\n…[truncated {} characters]", total - cap),
        truncated: true,
    }
}

pub fn clamp_timeout(requested: Option<&Value>) -> u64 {
    let value = requested.and_then(Value::as_f64).unwrap_or(0.0);
    if !value.is_finite() || value <= 0.0 {
        return DEFAULT_TIMEOUT_MS;
    }
    (value.trunc() as u64).clamp(1_000, MAX_TIMEOUT_MS)
}

/// Minimal, non-secret environment for spawned commands.
pub fn scrubbed_env(base: &HashMap<String, String>) -> HashMap<String, String> {
    let keep = [
        "PATH",
        "HOME",
        "USER",
        "LOGNAME",
        "SHELL",
        "TMPDIR",
        // cmux-tui and the relay must resolve the same per-user socket dir.
        "XDG_RUNTIME_DIR",
        "LANG",
        "LC_ALL",
    ];
    let mut env = HashMap::new();
    for key in keep {
        if let Some(value) = base.get(key) {
            env.insert(key.to_owned(), value.clone());
        }
    }
    env.insert("TERM".to_owned(), "dumb".to_owned());
    env
}

pub fn process_env_snapshot() -> HashMap<String, String> {
    std::env::vars().collect()
}

fn valid_environment_name(name: &str) -> bool {
    let mut chars = name.chars();
    match chars.next() {
        Some(first) if first.is_ascii_alphabetic() || first == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub struct ProcessRuntime {
    pub environment: HashMap<String, String>,
    pub files: Vec<RuntimeFile>,
}

pub struct RuntimeFile {
    pub content_environment_variable: String,
    pub path_environment_variable: String,
    pub path_hint: String,
}

/// Validate the secret-bearing frame field without returning secret text in
/// errors (v5 one-call process credentials).
pub fn process_runtime(frame_runtime: Option<&Value>) -> Result<ProcessRuntime, String> {
    let Some(runtime) = frame_runtime else {
        return Ok(ProcessRuntime { environment: HashMap::new(), files: Vec::new() });
    };
    let invalid = || "process runtime is invalid".to_owned();
    let object = runtime.as_object().ok_or_else(invalid)?;
    let environment_value =
        object.get("environment").and_then(Value::as_object).ok_or_else(invalid)?;
    let files_value = object.get("files").and_then(Value::as_array).ok_or_else(invalid)?;
    if environment_value.len() > MAX_RUNTIME_ENVIRONMENT_ENTRIES {
        return Err("process runtime has too many environment values".to_owned());
    }
    let mut environment = HashMap::new();
    let mut bytes = 0_usize;
    for (name, value) in environment_value {
        let Some(value) = value.as_str() else {
            return Err("process runtime environment is invalid".to_owned());
        };
        if !valid_environment_name(name) {
            return Err("process runtime environment is invalid".to_owned());
        }
        bytes += name.len() + value.len();
        if bytes > MAX_RUNTIME_ENVIRONMENT_BYTES || value.contains('\0') {
            return Err("process runtime environment is too large or invalid".to_owned());
        }
        environment.insert(name.clone(), value.to_owned());
    }
    if files_value.len() > MAX_RUNTIME_FILES {
        return Err("process runtime has too many files".to_owned());
    }
    let mut files = Vec::new();
    for file in files_value {
        let content = file
            .get("contentEnvironmentVariable")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let path_var = file
            .get("pathEnvironmentVariable")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let path_hint = file.get("pathHint").and_then(Value::as_str);
        if !valid_environment_name(&content)
            || !valid_environment_name(&path_var)
            || path_hint.is_none()
            || !environment.contains_key(&content)
        {
            return Err("process runtime file is invalid".to_owned());
        }
        files.push(RuntimeFile {
            content_environment_variable: content,
            path_environment_variable: path_var,
            path_hint: path_hint.unwrap_or_default().to_owned(),
        });
    }
    Ok(ProcessRuntime { environment, files })
}

/// Build a POSIX supervisor. No secret value enters the command string.
pub fn command_with_process_files(command: &str, files: &[RuntimeFile]) -> String {
    if files.is_empty() {
        return command.to_owned();
    }
    let mut setup: Vec<String> = vec!["set -e".to_owned()];
    let mut initializers: Vec<String> = Vec::new();
    let mut cleanup: Vec<String> = Vec::new();
    for (index, file) in files.iter().enumerate() {
        let sanitized: String = file
            .path_hint
            .chars()
            .map(
                |c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') { c } else { '-' },
            )
            .take(80)
            .collect();
        let hint = if sanitized.is_empty() { "secret".to_owned() } else { sanitized };
        let shell_path = format!("__chatmux_file_{index}");
        initializers.push(format!("{shell_path}="));
        cleanup
            .push(format!("if [ -n \"${{{shell_path}-}}\" ]; then rm -f -- \"${shell_path}\"; fi"));
        setup.push(format!("{shell_path}=$(mktemp \"${{TMPDIR:-/tmp}}/chatmux-{hint}.XXXXXX\")"));
        setup.push(format!("chmod 600 \"${shell_path}\""));
        setup.push(format!(
            "printf '%s' \"${}\" > \"${shell_path}\"",
            file.content_environment_variable,
        ));
        setup.push(format!("unset {}", file.content_environment_variable));
        setup.push(format!("export {}=\"${shell_path}\"", file.path_environment_variable,));
    }
    let cleanup_body = cleanup.join("; ");
    let mut supervisor = vec![
        "set -e".to_owned(),
        format!("__chatmux_cleanup() {{ trap '' HUP INT TERM; set +e; {cleanup_body}; }}"),
    ];
    supervisor.extend(initializers);
    supervisor.extend([
        "trap __chatmux_cleanup 0".to_owned(),
        "trap 'exit 143' HUP INT TERM".to_owned(),
        "umask 077".to_owned(),
    ]);
    supervisor.extend(setup.into_iter().skip(1));
    let mut setup = supervisor;
    setup.push(format!("if ( /bin/sh -c {} ); then", shell_quote(command)));
    setup.push("  __chatmux_status=$?".to_owned());
    setup.push("else".to_owned());
    setup.push("  __chatmux_status=$?".to_owned());
    setup.push("fi".to_owned());
    setup.push("trap '' HUP INT TERM".to_owned());
    setup.push("trap - 0".to_owned());
    setup.push("__chatmux_cleanup".to_owned());
    setup.push("exit $__chatmux_status".to_owned());
    setup.join("\n")
}

// ---------------------------------------------------------------------------
// Bounded spawn with a hard process-group timeout
// ---------------------------------------------------------------------------

enum RunSpec<'a> {
    Shell { command: &'a str },
    Argv { file: &'a str, args: Vec<String> },
}

enum RunOutcome {
    Done { exit_code: i64, output: String },
    TimedOut,
    Failed { message: String },
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum WaitRetryAction {
    Retry,
    Escalate,
}

fn next_wait_retry(retries: &mut u32) -> WaitRetryAction {
    *retries = retries.saturating_add(1);
    if *retries >= MAX_WAIT_RETRIES {
        *retries = 0;
        WaitRetryAction::Escalate
    } else {
        WaitRetryAction::Retry
    }
}

#[cfg(unix)]
struct ProcessTreeOwner {
    child: tokio::process::Child,
    keeper: tokio::process::Child,
    keeper_stdin: Option<tokio::process::ChildStdin>,
    pgid: libc::pid_t,
    armed: bool,
}

#[cfg(unix)]
impl ProcessTreeOwner {
    async fn spawn(mut command: tokio::process::Command) -> Result<Self, ()> {
        use std::os::unix::process::CommandExt as _;

        let mut keeper_command = tokio::process::Command::new("/bin/sh");
        keeper_command
            .args(["-c", "trap '' TERM HUP INT; while read -r _; do :; done"])
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .process_group(0);
        let mut keeper = keeper_command.spawn().map_err(|_| ())?;
        let Some(pgid) = keeper.id().map(|pid| pid as libc::pid_t) else {
            let _ = keeper.start_kill();
            let _ =
                tokio::time::timeout(std::time::Duration::from_millis(250), keeper.wait()).await;
            return Err(());
        };
        let Some(keeper_stdin) = keeper.stdin.take() else {
            let _ = keeper.start_kill();
            let _ =
                tokio::time::timeout(std::time::Duration::from_millis(250), keeper.wait()).await;
            return Err(());
        };
        // SAFETY: setpgid is async-signal-safe. The keeper is already the
        // process-group leader, so this only joins the target to its group.
        unsafe {
            command.as_std_mut().pre_exec(move || {
                if libc::setpgid(0, pgid) == 0 {
                    Ok(())
                } else {
                    Err(std::io::Error::last_os_error())
                }
            });
        }
        let child = match command.spawn() {
            Ok(child) => child,
            Err(_) => {
                drop(keeper_stdin);
                let _ = keeper.start_kill();
                let _ = keeper.wait().await;
                return Err(());
            }
        };
        Ok(Self { child, keeper, keeper_stdin: Some(keeper_stdin), pgid, armed: true })
    }

    fn terminate(&self) {
        // The keeper keeps this PGID alive until cleanup. No existence probe
        // is needed, so there is no check-then-signal PID reuse window.
        unsafe {
            libc::kill(-self.pgid, libc::SIGTERM);
        }
    }

    fn kill(&self) {
        unsafe {
            libc::kill(-self.pgid, libc::SIGKILL);
        }
    }

    async fn finish(mut self) {
        self.armed = false;
        drop(self.keeper_stdin.take());
        let _ =
            tokio::time::timeout(std::time::Duration::from_millis(250), self.keeper.wait()).await;
        if self.keeper.try_wait().ok().flatten().is_none() {
            let _ = self.keeper.start_kill();
            let _ = tokio::time::timeout(std::time::Duration::from_millis(250), self.keeper.wait())
                .await;
        }
    }
}

#[cfg(unix)]
impl Drop for ProcessTreeOwner {
    fn drop(&mut self) {
        if self.armed {
            unsafe {
                libc::kill(-self.pgid, libc::SIGKILL);
            }
        }
    }
}

#[cfg(windows)]
struct ProcessTreeOwner {
    child: tokio::process::Child,
    job: WindowsJob,
    armed: bool,
}

#[cfg(windows)]
fn windows_job_should_terminate(armed: bool) -> bool {
    armed
}

#[cfg(windows)]
impl ProcessTreeOwner {
    async fn spawn(mut command: tokio::process::Command) -> Result<Self, ()> {
        let mut child = command.spawn().map_err(|_| ())?;
        let job = match WindowsJob::attach(&child) {
            Ok(job) => job,
            Err(_) => {
                let _ = child.start_kill();
                let _ =
                    tokio::time::timeout(std::time::Duration::from_millis(250), child.wait()).await;
                return Err(());
            }
        };
        Ok(Self { child, job, armed: true })
    }

    fn terminate(&self) {
        self.job.terminate();
    }

    fn kill(&self) {
        self.job.terminate();
    }

    async fn finish(mut self) {
        self.armed = false;
    }
}

#[cfg(windows)]
impl Drop for ProcessTreeOwner {
    fn drop(&mut self) {
        if windows_job_should_terminate(self.armed) {
            self.job.terminate();
        }
    }
}

#[cfg(unix)]
type ScopedCwdFd = std::os::fd::RawFd;
#[cfg(not(unix))]
type ScopedCwdFd = ();

async fn run_spec(
    spec: RunSpec<'_>,
    cwd: &Path,
    cwd_fd: Option<ScopedCwdFd>,
    timeout_ms: u64,
    env: &HashMap<String, String>,
    cancellation: Option<tokio_util::sync::CancellationToken>,
) -> RunOutcome {
    use tokio::io::AsyncReadExt as _;
    let mut command = match &spec {
        RunSpec::Shell { command } => {
            #[cfg(windows)]
            let shell = {
                let mut command_line = tokio::process::Command::new("cmd.exe");
                command_line.args(["/D", "/S", "/C", command]);
                command_line
            };
            #[cfg(not(windows))]
            let shell = {
                let mut command_line = tokio::process::Command::new("/bin/sh");
                command_line.arg("-c").arg(command);
                command_line
            };
            shell
        }
        RunSpec::Argv { file, args } => {
            let mut argv = tokio::process::Command::new(file);
            argv.args(args);
            argv
        }
    };
    #[cfg(unix)]
    if let Some(cwd_fd) = cwd_fd {
        use std::os::unix::process::CommandExt as _;

        // SAFETY: fchdir is async-signal-safe, and the descriptor remains
        // open through spawn because the caller owns its guard.
        unsafe {
            command.as_std_mut().pre_exec(move || {
                if libc::fchdir(cwd_fd) == 0 {
                    Ok(())
                } else {
                    Err(std::io::Error::last_os_error())
                }
            });
        }
    } else {
        command.current_dir(cwd);
    }
    #[cfg(not(unix))]
    command.current_dir(cwd);
    command.env_clear().envs(env);
    command.stdin(std::process::Stdio::null());
    command.stdout(std::process::Stdio::piped());
    command.stderr(std::process::Stdio::piped());
    command.kill_on_drop(true);
    let mut owner = match ProcessTreeOwner::spawn(command).await {
        Ok(owner) => owner,
        Err(_) => return RunOutcome::Failed { message: "process failed to start".to_owned() },
    };
    // Collect a little past the char cap (bytes over-approximate chars).
    let byte_cap = (MAX_OUTPUT_CHARS + 10_000) * 4;
    let mut stdout = owner.child.stdout.take();
    let mut stderr = owner.child.stderr.take();
    let mut output: Vec<u8> = Vec::new();
    let mut timed_out = false;
    let deadline = tokio::time::sleep(std::time::Duration::from_millis(timeout_ms));
    tokio::pin!(deadline);
    let mut stdout_buf = [0_u8; 8_192];
    let mut stderr_buf = [0_u8; 8_192];
    let mut stdout_open = stdout.is_some();
    let mut stderr_open = stderr.is_some();
    let mut exited: Option<i64> = None;
    let mut kill_deadline: Option<std::pin::Pin<Box<tokio::time::Sleep>>> = None;
    let mut drain_deadline: Option<std::pin::Pin<Box<tokio::time::Sleep>>> = None;
    let mut final_wait_deadline: Option<std::pin::Pin<Box<tokio::time::Sleep>>> = None;
    let mut wait_retry_deadline: Option<std::pin::Pin<Box<tokio::time::Sleep>>> = None;
    let mut wait_retries = 0_u32;
    let mut cancelled = false;
    let mut escalation_pending = false;
    loop {
        // A timed-out process group still needs its escalation pass even when
        // the shell leader has already exited. Otherwise closing inherited
        // pipes can make us return before SIGKILL reaches descendants.
        if exited.is_some()
            && !stdout_open
            && !stderr_open
            && kill_deadline.is_none()
            && final_wait_deadline.is_none()
            && !escalation_pending
        {
            break;
        }
        tokio::select! {
            () = async {
                match cancellation.as_ref() {
                    Some(token) => token.cancelled().await,
                    None => std::future::pending().await,
                }
            }, if !cancelled => {
                cancelled = true;
                owner.terminate();
                escalation_pending = true;
                kill_deadline = Some(Box::pin(tokio::time::sleep(
                    std::time::Duration::from_millis(250),
                )));
            }
            read = async {
                match stdout.as_mut() {
                    Some(stream) => stream.read(&mut stdout_buf).await,
                    None => std::future::pending().await,
                }
            }, if stdout_open => {
                match read {
                    Ok(0) | Err(_) => stdout_open = false,
                    Ok(count) => {
                        if output.len() < byte_cap {
                            output.extend_from_slice(&stdout_buf[..count]);
                        }
                    }
                }
            }
            read = async {
                match stderr.as_mut() {
                    Some(stream) => stream.read(&mut stderr_buf).await,
                    None => std::future::pending().await,
                }
            }, if stderr_open => {
                match read {
                    Ok(0) | Err(_) => stderr_open = false,
                    Ok(count) => {
                        if output.len() < byte_cap {
                            output.extend_from_slice(&stderr_buf[..count]);
                        }
                    }
                }
            }
            status = owner.child.wait(), if exited.is_none() && wait_retry_deadline.is_none() => {
                // The child is gone, but descendants may still own the output
                // pipes. Preserve a timeout escalation that is already in
                // flight, and bound the remaining drain after a timeout.
                final_wait_deadline = None;
                if timed_out && (stdout_open || stderr_open) && drain_deadline.is_none() {
                    drain_deadline = Some(Box::pin(tokio::time::sleep(
                        std::time::Duration::from_millis(250),
                    )));
                }
                match status {
                    Ok(status) => {
                        exited = Some(status.code().map(i64::from).unwrap_or(1));
                        wait_retries = 0;
                    }
                    Err(error) => {
                        #[cfg(unix)]
                        if error.raw_os_error() == Some(libc::ECHILD) {
                            exited = Some(1);
                            wait_retries = 0;
                        } else {
                            match next_wait_retry(&mut wait_retries) {
                                WaitRetryAction::Retry => {
                                    wait_retry_deadline = Some(Box::pin(tokio::time::sleep(
                                        std::time::Duration::from_millis(10),
                                    )));
                                }
                                WaitRetryAction::Escalate => {
                                    owner.kill();
                                    escalation_pending = true;
                                    kill_deadline = Some(Box::pin(tokio::time::sleep(
                                        std::time::Duration::from_millis(250),
                                    )));
                                }
                            }
                        }
                        #[cfg(not(unix))]
                        {
                            let _ = error;
                            match next_wait_retry(&mut wait_retries) {
                                WaitRetryAction::Retry => {
                                    wait_retry_deadline = Some(Box::pin(tokio::time::sleep(
                                        std::time::Duration::from_millis(10),
                                    )));
                                }
                                WaitRetryAction::Escalate => {
                                    owner.kill();
                                    escalation_pending = true;
                                    kill_deadline = Some(Box::pin(tokio::time::sleep(
                                        std::time::Duration::from_millis(250),
                                    )));
                                }
                            }
                        }
                    }
                }
            }
            () = &mut deadline, if !timed_out => {
                timed_out = true;
                // Commands run below a shell and may have descendants that
                // inherited stdout/stderr. Kill the whole POSIX process group
                // so the supervisor gets its EXIT cleanup, then enforce a
                // hard bound for processes that ignore TERM.
                owner.terminate();
                escalation_pending = true;
                // Keep the escalation timer owned by this invocation. A
                // detached task could fire after the process exits and its
                // PID is reused by an unrelated process.
                kill_deadline = Some(Box::pin(tokio::time::sleep(
                    std::time::Duration::from_millis(250),
                )));
                if exited.is_some() && (stdout_open || stderr_open) && drain_deadline.is_none() {
                    drain_deadline = Some(Box::pin(tokio::time::sleep(
                        std::time::Duration::from_millis(250),
                    )));
                }
            }
            () = async {
                match kill_deadline.as_mut() {
                    Some(timer) => timer.as_mut().await,
                    None => std::future::pending().await,
                }
            }, if kill_deadline.is_some() => {
                owner.kill();
                kill_deadline = None;
                escalation_pending = false;
                if exited.is_none() {
                    final_wait_deadline = Some(Box::pin(tokio::time::sleep(
                        std::time::Duration::from_millis(250),
                    )));
                }
            }
            () = async {
                match drain_deadline.as_mut() {
                    Some(timer) => timer.as_mut().await,
                    None => std::future::pending().await,
                }
            }, if drain_deadline.is_some() => {
                stdout_open = false;
                stderr_open = false;
                drain_deadline = None;
            }
            () = async {
                match final_wait_deadline.as_mut() {
                    Some(timer) => timer.as_mut().await,
                    None => std::future::pending().await,
                }
            }, if final_wait_deadline.is_some() && exited.is_none() => {
                let _ = owner.child.start_kill();
                final_wait_deadline = None;
                exited = Some(1);
                if stdout_open || stderr_open {
                    drain_deadline = Some(Box::pin(tokio::time::sleep(
                        std::time::Duration::from_millis(250),
                    )));
                }
            }
            () = async {
                match wait_retry_deadline.as_mut() {
                    Some(timer) => timer.as_mut().await,
                    None => std::future::pending().await,
                }
            }, if wait_retry_deadline.is_some() => {
                wait_retry_deadline = None;
            }
        }
    }
    owner.finish().await;
    if timed_out {
        return RunOutcome::TimedOut;
    }
    if cancelled {
        return RunOutcome::Failed { message: "process cancelled".to_owned() };
    }
    let text = String::from_utf8_lossy(&output);
    RunOutcome::Done { exit_code: exited.unwrap_or(0), output: text.into_owned() }
}

#[cfg(unix)]
fn signal_process_group_id<F>(pid: Option<u32>, kill: bool, send: F) -> bool
where
    F: FnOnce(libc::pid_t, libc::c_int) -> libc::c_int,
{
    let Some(pid) = pid else { return false };
    let signal = if kill { libc::SIGKILL } else { libc::SIGTERM };
    let group = -(pid as i32);
    send(group, signal) == 0
}

#[cfg(windows)]
struct WindowsJob {
    handle: std::os::windows::io::OwnedHandle,
}

#[cfg(windows)]
impl WindowsJob {
    fn attach(child: &tokio::process::Child) -> Result<Self, ()> {
        use std::mem::size_of;
        use std::os::windows::io::{AsRawHandle, FromRawHandle};
        use std::ptr::null_mut;
        use windows_sys::Win32::System::JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
            SetInformationJobObject,
        };
        let raw_handle = unsafe { CreateJobObjectW(null_mut(), null_mut()) };
        if raw_handle.is_null() {
            return Err(());
        }
        // CreateJobObjectW returns a newly owned kernel handle. OwnedHandle
        // supplies the correct CloseHandle drop and is Send + Sync, so the
        // job can remain alive while run_spec awaits on Tokio I/O.
        let handle = unsafe { std::os::windows::io::OwnedHandle::from_raw_handle(raw_handle) };
        let mut information = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        information.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let information_size = u32::try_from(size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>())
            .expect("Windows job information fits in u32");
        if unsafe {
            SetInformationJobObject(
                handle.as_raw_handle(),
                JobObjectExtendedLimitInformation,
                std::ptr::from_ref(&information).cast(),
                information_size,
            )
        } == 0
        {
            return Err(());
        }
        let process = child.raw_handle().ok_or(())?;
        if unsafe { AssignProcessToJobObject(handle.as_raw_handle(), process) } == 0 {
            return Err(());
        }
        Ok(Self { handle })
    }

    fn terminate(&self) {
        use std::os::windows::io::AsRawHandle;
        unsafe {
            windows_sys::Win32::System::JobObjects::TerminateJobObject(
                self.handle.as_raw_handle(),
                1,
            )
        };
    }
}

fn cap_lines(output: &str, truncated: bool, limit: Option<&Value>) -> (String, bool) {
    let Some(limit) = limit.and_then(Value::as_f64).filter(|v| v.is_finite()) else {
        return (output.to_owned(), truncated);
    };
    let cap = (limit.trunc() as i64).clamp(1, 5_000) as usize;
    let lines: Vec<&str> = output.split('\n').collect();
    if lines.len() <= cap {
        return (output.to_owned(), truncated);
    }
    (format!("{}\n…[{} more lines]", lines[..cap].join("\n"), lines.len() - cap), true)
}

// ---------------------------------------------------------------------------
// The verb dispatcher
// ---------------------------------------------------------------------------

pub struct ActionContext {
    /// The machine's reconciled trust (config after the trust_ack handshake),
    /// never the frame's echo alone.
    pub trust: String,
    pub local_roots: Option<Vec<String>>,
    pub home: PathBuf,
    /// Scrubbed base environment for spawns.
    pub env: HashMap<String, String>,
    /// Process-owned capacity retained by file work that outlives a socket.
    pub file_slots: Arc<tokio::sync::Semaphore>,
    pub process_cancellation: tokio_util::sync::CancellationToken,
    #[cfg(test)]
    pub(crate) test_file_operation_barrier: Option<Arc<std::sync::Barrier>>,
}

fn frame_roots(frame: &Value) -> Result<Option<Vec<String>>, &'static str> {
    let Some(value) = frame.get("allowedRoots") else { return Ok(None) };
    if value.is_null() {
        return Ok(None);
    }
    let roots = value.as_array().ok_or("allowedRoots must be an array")?;
    if roots.len() > 32 || roots.iter().any(|root| !root.is_string() || root.as_str() == Some("")) {
        return Err("invalid allowedRoots");
    }
    if roots.iter().any(|root| validate_request_path(root.as_str().unwrap()).is_err()) {
        return Err("invalid allowedRoots");
    }
    if roots.iter().map(|root| root.as_str().unwrap().len()).sum::<usize>() > 16 * 1024 {
        return Err("invalid allowedRoots");
    }
    Ok(Some(roots.iter().map(|root| root.as_str().unwrap().to_owned()).collect()))
}

fn ok_result(version: i64, action_id: &str, result: Value) -> Value {
    json!({
        "version": version,
        "type": "action_result",
        "actionId": action_id,
        "ok": true,
        "result": result,
    })
}

fn run_reply(
    version: i64,
    action_id: &str,
    outcome: RunOutcome,
    limit: Option<&Value>,
    default_limit: Option<i64>,
    timeout_ms: u64,
) -> Value {
    let default_value = default_limit.map(Value::from);
    let limit = limit.or(default_value.as_ref());
    match outcome {
        RunOutcome::Failed { message } => fail_result(version, action_id, "failed", &message),
        RunOutcome::TimedOut => {
            let seconds = (timeout_ms as f64 / 1000.0).round() as u64;
            fail_result(
                version,
                action_id,
                "timeout",
                &format!("command timed out after {seconds}s"),
            )
        }
        RunOutcome::Done { exit_code, output } => {
            let bounded = truncate_output(&output, MAX_OUTPUT_CHARS);
            let (capped, truncated) = cap_lines(&bounded.output, bounded.truncated, limit);
            let mut result = Map::new();
            result.insert("exitCode".to_owned(), Value::from(exit_code));
            result.insert("output".to_owned(), Value::from(capped));
            if truncated {
                result.insert("truncated".to_owned(), Value::from(true));
            }
            ok_result(version, action_id, Value::Object(result))
        }
    }
}

#[cfg(unix)]
fn find_regular_file_output(path: &HostScopedPath, pattern: Option<&str>) -> String {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt as _;

    let matches = pattern.is_none_or(|pattern| {
        let Some(name) = path.path.file_name() else { return false };
        let Ok(name) = CString::new(name.as_bytes()) else { return false };
        let Ok(pattern) = CString::new(pattern) else { return false };
        // SAFETY: both strings are NUL-terminated and contain no interior NUL.
        unsafe { libc::fnmatch(pattern.as_ptr(), name.as_ptr(), 0) == 0 }
    });
    if matches { format!("{}\n", path.path.display()) } else { String::new() }
}

fn fail_result(version: i64, action_id: &str, code: &str, message: &str) -> Value {
    json!({
        "version": version,
        "type": "action_result",
        "actionId": action_id,
        "ok": false,
        "code": code,
        "message": message,
    })
}

#[derive(Clone)]
struct OwnedPathScope {
    local_roots: Option<Vec<String>>,
    server_roots: Option<Vec<String>>,
    home: PathBuf,
    workdir: String,
}

#[cfg(unix)]
fn prepare_grep_paths(
    scope: OwnedPathScope,
    raw: String,
) -> Result<(std::fs::File, String, std::fs::File, String), BlockingFsError> {
    let path = scope.resolve(&raw, false)?;
    let (path_guard, process_path) =
        inherited_path(&path).map_err(|error| operation_error(error, true))?;
    let command_cwd = scope.resolve(".", false)?;
    let (cwd_guard, command_cwd_path) =
        inherited_directory_path(&command_cwd).map_err(|error| operation_error(error, true))?;
    Ok((path_guard, process_path, cwd_guard, command_cwd_path))
}

enum BlockingFsError {
    Refusal(String),
    Io(std::io::Error),
}

impl OwnedPathScope {
    fn resolve(
        &self,
        raw_path: &str,
        allow_missing: bool,
    ) -> Result<HostScopedPath, BlockingFsError> {
        let root_lists: RootLists<'_> = [self.local_roots.as_deref(), self.server_roots.as_deref()];
        match resolve_scoped_host_path(
            raw_path,
            &root_lists,
            &self.home,
            &self.workdir,
            allow_missing,
        ) {
            Ok(Ok(path)) => Ok(path),
            Ok(Err(message)) => Err(BlockingFsError::Refusal(message)),
            Err(error) => Err(BlockingFsError::Io(error)),
        }
    }
}

enum BoundedFileOperation {
    Read { path: String },
    Write { path: String, content: String },
    List { path: String },
}

enum BoundedFileOutput {
    Read(String),
    Written,
    Listing(String),
}

fn operation_error(error: HostError, symlink_loop_is_refusal: bool) -> BlockingFsError {
    match error {
        HostError::Refusal(message) => BlockingFsError::Refusal(message),
        HostError::Io(error) if symlink_loop_is_refusal && is_eloop(&error) => {
            BlockingFsError::Refusal("path contains a symlink loop".to_owned())
        }
        HostError::Io(error) => BlockingFsError::Io(error),
    }
}

fn perform_bounded_file_operation(
    scope: OwnedPathScope,
    operation: BoundedFileOperation,
) -> Result<BoundedFileOutput, BlockingFsError> {
    match operation {
        BoundedFileOperation::Read { path } => {
            let path = scope.resolve(&path, false)?;
            read_utf8_no_follow(&path)
                .map(BoundedFileOutput::Read)
                .map_err(|error| operation_error(error, true))
        }
        BoundedFileOperation::Write { path, content } => {
            let path = scope.resolve(&path, true)?;
            write_utf8_no_follow(&path, &content)
                .map(|()| BoundedFileOutput::Written)
                .map_err(|error| operation_error(error, true))
        }
        BoundedFileOperation::List { path } => {
            let path = scope.resolve(&path, false)?;
            let entries = read_dir_scoped(&path).map_err(|error| operation_error(error, false))?;
            let mut names: Vec<String> = entries
                .entries
                .into_iter()
                .map(|entry| {
                    let name = entry.name.to_string_lossy().into_owned();
                    if entry.is_dir { format!("{name}/") } else { name }
                })
                .collect();
            names.sort();
            let more = if entries.truncated {
                "\n…[more entries omitted]".to_owned()
            } else {
                String::new()
            };
            Ok(BoundedFileOutput::Listing(format!("{}{more}", names.join("\n"))))
        }
    }
}

/// Execute one action_request frame. Returns the `action_result` frame to
/// send back (never fails).
pub async fn perform_action(frame: &Value, context: &ActionContext) -> Value {
    let version = frame.get("version").and_then(Value::as_i64).unwrap_or(3);
    let action_id = frame.get("actionId").and_then(Value::as_str).unwrap_or_default().to_owned();
    let fail = |code: &str, message: &str| fail_result(version, &action_id, code, message);
    let process_cancellation = context.process_cancellation.clone();

    let verb = frame.get("verb").and_then(Value::as_str).unwrap_or_default().to_owned();
    if !ACTION_VERBS.contains(&verb.as_str()) {
        return fail("unsupported_verb", &format!("this relay does not support verb \"{verb}\""));
    }

    // Owner-side trust floor: the server gates too, but the machine's own
    // config is authoritative here.
    if context.trust == "observe" && !READ_ONLY_VERBS.contains(&verb.as_str()) {
        return fail(
            "trust_refused",
            &format!("this machine is paired at observe trust; \"{verb}\" is not a read-only verb"),
        );
    }

    let home = context.home.clone();
    let server_roots = match frame_roots(frame) {
        Ok(roots) => roots,
        Err(message) => return fail("bad_request", message),
    };
    let root_lists: RootLists<'_> = [context.local_roots.as_deref(), server_roots.as_deref()];
    if let Err(message) = ensure_scoped_file_roots_available(cfg!(unix), &root_lists) {
        return fail("unsupported_verb", message);
    }
    let empty_args = Map::new();
    let args = frame.get("args").and_then(Value::as_object).unwrap_or(&empty_args);
    let timeout_ms = clamp_timeout(frame.get("timeoutMs"));
    let runtime = match process_runtime(frame.get("runtime")) {
        Ok(runtime) => runtime,
        Err(message) => return fail("failed", &message),
    };
    if verb != "exec" && (!runtime.environment.is_empty() || !runtime.files.is_empty()) {
        return fail("failed", "process runtime is valid only for exec");
    }
    if cfg!(windows) && !runtime.files.is_empty() {
        return fail("failed", "process file bindings are not available on Windows relays");
    }
    let mut env = context.env.clone();
    env.extend(runtime.environment.clone());
    let first_roots = root_lists.iter().flatten().find(|roots| !roots.is_empty());
    let workdir = match first_roots {
        Some(roots) => expand_path(&roots[0], &home, &home).display().to_string(),
        None => home.display().to_string(),
    };
    let path_scope = OwnedPathScope {
        local_roots: context.local_roots.clone(),
        server_roots: server_roots.clone(),
        home: home.clone(),
        workdir: workdir.clone(),
    };
    let scoped = |raw: &str, allow_missing: bool| {
        resolve_scoped_host_path(raw, &root_lists, &home, &workdir, allow_missing)
    };
    // Host paths and OS errors can contain private filesystem details. Keep
    // those details in local diagnostics, never in the remote action result.
    let io_fail =
        |_error: std::io::Error| fail_result(version, &action_id, "failed", "operation failed");

    let file_operation = match verb.as_str() {
        "read" => {
            let Some(path) = args
                .get("path")
                .and_then(Value::as_str)
                .filter(|path| !path.is_empty())
                .map(str::to_owned)
            else {
                return fail("failed", "read: path is required");
            };
            Some(BoundedFileOperation::Read { path })
        }
        "write" => {
            let Some(path) = args
                .get("path")
                .and_then(Value::as_str)
                .filter(|path| !path.is_empty())
                .map(str::to_owned)
            else {
                return fail("failed", "write: path is required");
            };
            let content =
                args.get("content").and_then(Value::as_str).unwrap_or_default().to_owned();
            Some(BoundedFileOperation::Write { path, content })
        }
        "ls" => {
            let path = args
                .get("path")
                .and_then(Value::as_str)
                .filter(|path| !path.is_empty())
                .unwrap_or(".")
                .to_owned();
            Some(BoundedFileOperation::List { path })
        }
        _ => None,
    };
    if let Some(operation) = file_operation {
        let file_permit = match Arc::clone(&context.file_slots).try_acquire_owned() {
            Ok(permit) => permit,
            Err(_) => {
                return fail(
                    "busy",
                    "relay file actions are busy; retry or restart the relay if this persists",
                );
            }
        };
        #[cfg(test)]
        let test_barrier = context.test_file_operation_barrier.clone();
        // The connection task selects its cancellation token against this
        // await. Tokio keeps a started blocking task alive after the future
        // is dropped, so the closure retains every descriptor guard through
        // the bounded operation instead of returning a checked path. It also
        // retains process-owned capacity across reconnects, which bounds
        // kernel calls that cannot be interrupted in user space.
        let output = match tokio::task::spawn_blocking(move || {
            let _file_permit = file_permit;
            #[cfg(test)]
            if let Some(barrier) = test_barrier {
                barrier.wait();
            }
            perform_bounded_file_operation(path_scope, operation)
        })
        .await
        {
            Ok(Ok(output)) => output,
            Ok(Err(BlockingFsError::Refusal(message))) => {
                return fail("path_forbidden", &message);
            }
            Ok(Err(BlockingFsError::Io(error))) => return io_fail(error),
            Err(_) => return fail("failed", "operation failed"),
        };
        return match output {
            BoundedFileOutput::Read(content) => {
                ok_result(version, &action_id, json!({ "content": content }))
            }
            BoundedFileOutput::Written => ok_result(version, &action_id, json!({})),
            BoundedFileOutput::Listing(listing) => {
                ok_result(version, &action_id, json!({ "listing": listing }))
            }
        };
    }

    match verb.as_str() {
        "grep" => {
            let file_permit = match Arc::clone(&context.file_slots).try_acquire_owned() {
                Ok(permit) => permit,
                Err(_) => {
                    return fail(
                        "busy",
                        "relay file actions are busy; retry or restart the relay if this persists",
                    );
                }
            };
            let raw =
                args.get("path").and_then(Value::as_str).filter(|p| !p.is_empty()).unwrap_or(".");
            let pattern =
                args.get("pattern").and_then(Value::as_str).unwrap_or_default().to_owned();
            if pattern.is_empty() {
                return fail("failed", "grep: pattern is required");
            }
            if cfg!(windows) {
                return fail("unsupported_verb", "grep is not available on Windows relays yet");
            }
            #[cfg(unix)]
            let (_path_guard, process_path, _cwd_guard, command_cwd_path) =
                match tokio::task::spawn_blocking({
                    let scope = path_scope.clone();
                    let raw = raw.to_owned();
                    move || prepare_grep_paths(scope, raw)
                })
                .await
                {
                    Ok(Ok(value)) => value,
                    Ok(Err(BlockingFsError::Refusal(message))) => {
                        return fail("path_forbidden", &message);
                    }
                    Ok(Err(BlockingFsError::Io(error))) => return io_fail(error),
                    Err(_) => return fail("failed", "operation failed"),
                };
            #[cfg(not(unix))]
            let path = match scoped(raw, false) {
                Ok(Ok(path)) => path,
                Ok(Err(message)) => return fail("path_forbidden", &message),
                Err(error) => return io_fail(error),
            };
            #[cfg(not(unix))]
            let process_path = path.path.display().to_string();
            #[cfg(not(unix))]
            let command_cwd_path = match scoped(".", false) {
                Ok(Ok(path)) => path.path.display().to_string(),
                Ok(Err(message)) => return fail("path_forbidden", &message),
                Err(error) => return io_fail(error),
            };
            #[cfg(unix)]
            let command_cwd_fd = {
                use std::os::fd::AsRawFd as _;
                Some(_cwd_guard.as_raw_fd())
            };
            #[cfg(not(unix))]
            let command_cwd_fd = None;
            let outcome = tokio::spawn(async move {
                let _file_permit = file_permit;
                #[cfg(unix)]
                let _path_guard = _path_guard;
                #[cfg(unix)]
                let _cwd_guard = _cwd_guard;
                run_spec(
                    RunSpec::Argv {
                        file: "grep",
                        args: vec![
                            "-rIn".to_owned(),
                            "--exclude-dir=.git".to_owned(),
                            "--exclude-dir=node_modules".to_owned(),
                            "-e".to_owned(),
                            pattern,
                            "--".to_owned(),
                            process_path,
                        ],
                    },
                    Path::new(&command_cwd_path),
                    command_cwd_fd,
                    timeout_ms,
                    &env,
                    Some(process_cancellation.clone()),
                )
                .await
            })
            .await
            .unwrap_or(RunOutcome::Failed { message: "process failed to start".to_owned() });
            run_reply(version, &action_id, outcome, args.get("limit"), Some(200), timeout_ms)
        }
        "find" => {
            let raw =
                args.get("path").and_then(Value::as_str).filter(|p| !p.is_empty()).unwrap_or(".");
            let path = match scoped(raw, false) {
                Ok(Ok(path)) => path,
                Ok(Err(message)) => return fail("path_forbidden", &message),
                Err(error) => return io_fail(error),
            };
            if cfg!(windows) {
                return fail("unsupported_verb", "find is not available on Windows relays yet");
            }
            #[cfg(unix)]
            let (_path_guard, process_path) = match inherited_path(&path) {
                Ok(value) => value,
                Err(HostError::Refusal(message)) => return fail("path_forbidden", &message),
                Err(HostError::Io(error)) => return io_fail(error),
            };
            #[cfg(unix)]
            if path.path.is_file() {
                let pattern = args.get("pattern").and_then(Value::as_str).filter(|p| !p.is_empty());
                return run_reply(
                    version,
                    &action_id,
                    RunOutcome::Done {
                        exit_code: 0,
                        output: find_regular_file_output(&path, pattern),
                    },
                    args.get("limit"),
                    Some(500),
                    timeout_ms,
                );
            }
            #[cfg(not(unix))]
            let process_path = path.path.display().to_string();
            let command_cwd = match scoped(".", false) {
                Ok(Ok(path)) => path,
                Ok(Err(message)) => return fail("path_forbidden", &message),
                Err(error) => return io_fail(error),
            };
            #[cfg(unix)]
            let (_cwd_guard, command_cwd_path) = match inherited_directory_path(&command_cwd) {
                Ok(value) => value,
                Err(HostError::Refusal(message)) => return fail("path_forbidden", &message),
                Err(HostError::Io(error)) => return io_fail(error),
            };
            #[cfg(not(unix))]
            let command_cwd_path = command_cwd.path.display().to_string();
            #[cfg(unix)]
            let command_cwd_fd = {
                use std::os::fd::AsRawFd as _;
                Some(_cwd_guard.as_raw_fd())
            };
            #[cfg(not(unix))]
            let command_cwd_fd = None;
            let mut find_args = vec![process_path];
            if let Some(pattern) =
                args.get("pattern").and_then(Value::as_str).filter(|p| !p.is_empty())
            {
                find_args.push("-name".to_owned());
                find_args.push(pattern.to_owned());
            }
            let outcome = run_spec(
                RunSpec::Argv { file: "find", args: find_args },
                Path::new(&command_cwd_path),
                command_cwd_fd,
                timeout_ms,
                &env,
                Some(process_cancellation.clone()),
            )
            .await;
            run_reply(version, &action_id, outcome, args.get("limit"), Some(500), timeout_ms)
        }
        "exec" => {
            let command = args.get("command").and_then(Value::as_str).unwrap_or_default();
            if command.is_empty() {
                return fail("failed", "exec: command is required");
            }
            // Default and explicit relative cwds use the same canonical
            // workdir policy as every file verb. This also enforces the
            // intersection when the root lists do not overlap.
            let raw_cwd =
                args.get("cwd").and_then(Value::as_str).filter(|p| !p.is_empty()).unwrap_or(".");
            let scoped_cwd = match scoped(raw_cwd, false) {
                Ok(Ok(path)) => path,
                Ok(Err(message)) => return fail("path_forbidden", &message),
                Err(error) => return io_fail(error),
            };
            #[cfg(unix)]
            let (_cwd_guard, scoped_cwd_path) = match inherited_directory_path(&scoped_cwd) {
                Ok(value) => value,
                Err(HostError::Refusal(message)) => return fail("path_forbidden", &message),
                Err(HostError::Io(error)) => return io_fail(error),
            };
            #[cfg(not(unix))]
            let scoped_cwd_path = scoped_cwd.path.display().to_string();
            #[cfg(unix)]
            let scoped_cwd_fd = {
                use std::os::fd::AsRawFd as _;
                Some(_cwd_guard.as_raw_fd())
            };
            #[cfg(not(unix))]
            let scoped_cwd_fd = None;
            let prepared = command_with_process_files(command, &runtime.files);
            let outcome = run_spec(
                RunSpec::Shell { command: &prepared },
                Path::new(&scoped_cwd_path),
                scoped_cwd_fd,
                timeout_ms,
                &env,
                Some(process_cancellation.clone()),
            )
            .await;
            run_reply(version, &action_id, outcome, None, None, timeout_ms)
        }
        _ => fail("unsupported_verb", &format!("verb \"{verb}\" fell through")),
    }
}

// ---------------------------------------------------------------------------
// Tests — mirror packages/relay/test/actions.test.mjs.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn home() -> PathBuf {
        PathBuf::from("/home/u")
    }

    fn ctx(trust: &str, roots: Option<Vec<String>>, home: PathBuf) -> ActionContext {
        ActionContext {
            trust: trust.to_owned(),
            local_roots: roots,
            home,
            env: HashMap::new(),
            file_slots: Arc::new(tokio::sync::Semaphore::new(MAX_BLOCKING_FILE_ACTIONS)),
            process_cancellation: tokio_util::sync::CancellationToken::new(),
            test_file_operation_barrier: None,
        }
    }

    fn scratch(name: &str) -> PathBuf {
        let mut dir = std::env::temp_dir();
        dir.push(format!("chatmux-actions-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // realpath so canonical checks match (macOS /tmp -> /private/tmp).
        std::fs::canonicalize(&dir).unwrap()
    }

    #[cfg(unix)]
    #[test]
    fn process_group_failure_does_not_fallback_to_numeric_pid() {
        let mut targets = Vec::new();
        let signalled = signal_process_group_id(Some(4_321), false, |target, _| {
            targets.push(target);
            -1
        });

        assert!(!signalled);
        assert_eq!(targets, vec![-4_321]);
    }

    #[cfg(windows)]
    #[test]
    fn create_parent_dirs_accepts_windows_drive_prefix() {
        let root =
            std::env::temp_dir().join(format!("chatmux-actions-drive-{}", std::process::id()));
        let parent = root.join("nested").join("deeper");
        let _ = std::fs::remove_dir_all(&root);
        create_parent_dirs_no_symlink(&parent).unwrap();
        assert!(parent.is_dir());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn expand_path_handles_tilde_relative_and_absolute() {
        assert_eq!(expand_path("~", &home(), &home()), home());
        assert_eq!(expand_path("~/x", &home(), &home()), PathBuf::from("/home/u/x"));
        assert_eq!(expand_path("/abs", &home(), Path::new("/base")), PathBuf::from("/abs"));
        assert_eq!(expand_path("rel", &home(), Path::new("/base")), PathBuf::from("/base/rel"));
        assert_eq!(expand_path("a/../b", &home(), Path::new("/base")), PathBuf::from("/base/b"));
    }

    #[test]
    fn resolve_scoped_path_enforces_every_nonempty_root_list() {
        let roots_a = vec!["/home/u/work".to_owned()];
        let roots_b = vec!["/home/u/work/sub".to_owned()];
        let lists: RootLists = [Some(roots_a.as_slice()), Some(roots_b.as_slice())];
        // Inside both: ok.
        let ok = resolve_scoped_path("/home/u/work/sub/file", &lists, &home(), "/home/u/work/sub");
        assert!(ok.is_ok());
        // Inside A but outside B: refused.
        let refused = resolve_scoped_path("/home/u/work/other", &lists, &home(), "/home/u/work");
        assert!(refused.is_err());
    }

    #[test]
    fn relative_paths_stay_in_the_workdir() {
        let roots = vec!["/home/u/work".to_owned()];
        let lists: RootLists = [Some(roots.as_slice()), None];
        assert!(resolve_scoped_path("../escape", &lists, &home(), "/home/u/work").is_err());
        assert!(resolve_scoped_path("./nested/../ok", &lists, &home(), "/home/u/work").is_ok());
        // Encoded and control-character variants are refused.
        assert!(resolve_scoped_path("a%2e%2e/b", &lists, &home(), "/home/u/work").is_err());
        assert!(resolve_scoped_path("a\u{0000}b", &lists, &home(), "/home/u/work").is_err());
    }

    #[test]
    fn truncate_output_caps_and_marks() {
        let short = truncate_output("hi", MAX_OUTPUT_CHARS);
        assert!(!short.truncated);
        let long = "x".repeat(MAX_OUTPUT_CHARS + 5);
        let capped = truncate_output(&long, MAX_OUTPUT_CHARS);
        assert!(capped.truncated);
        assert!(capped.output.contains("truncated 5 characters"));
    }

    #[test]
    fn clamp_timeout_bounds() {
        assert_eq!(clamp_timeout(None), DEFAULT_TIMEOUT_MS);
        assert_eq!(clamp_timeout(Some(&json!(50))), 1_000);
        assert_eq!(clamp_timeout(Some(&json!(9_999_999))), MAX_TIMEOUT_MS);
        assert_eq!(clamp_timeout(Some(&json!(-5))), DEFAULT_TIMEOUT_MS);
    }

    #[test]
    fn scoped_file_capability_refusal_is_typed_and_fail_closed() {
        let roots = vec!["/srv/work".to_owned()];
        let scoped: RootLists<'_> = [Some(roots.as_slice()), None];
        assert!(ensure_scoped_file_roots_available(true, &scoped).is_ok());
        assert_eq!(
            ensure_scoped_file_roots_available(false, &scoped),
            Err(SCOPED_FILE_ROOTS_UNSUPPORTED),
        );
        let unscoped: RootLists<'_> = [None, None];
        assert!(ensure_scoped_file_roots_available(false, &unscoped).is_ok());
    }

    #[test]
    fn scrubbed_env_drops_secrets_keeps_path_home() {
        let base = HashMap::from([
            ("PATH".to_owned(), "/usr/bin".to_owned()),
            ("HOME".to_owned(), "/home/u".to_owned()),
            ("XDG_RUNTIME_DIR".to_owned(), "/run/user/1000".to_owned()),
            ("OPENAI_API_KEY".to_owned(), "sekret".to_owned()),
        ]);
        let env = scrubbed_env(&base);
        assert_eq!(env.get("PATH").map(String::as_str), Some("/usr/bin"));
        assert_eq!(env.get("HOME").map(String::as_str), Some("/home/u"));
        assert_eq!(env.get("XDG_RUNTIME_DIR").map(String::as_str), Some("/run/user/1000"));
        assert!(!env.contains_key("OPENAI_API_KEY"));
        assert_eq!(env.get("TERM").map(String::as_str), Some("dumb"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn read_write_ls_round_trip_inside_allowed_roots() {
        let root = scratch("rw");
        let roots = vec![root.display().to_string()];
        let context = ctx("supervised", Some(roots.clone()), root.clone());
        // write
        let write = perform_action(
            &json!({ "verb": "write", "actionId": "a1", "allowedRoots": roots,
                     "args": { "path": "note.txt", "content": "hello" } }),
            &context,
        )
        .await;
        assert_eq!(write["ok"], true, "{write}");
        // read
        let read = perform_action(
            &json!({ "verb": "read", "actionId": "a2", "allowedRoots": roots,
                     "args": { "path": "note.txt" } }),
            &context,
        )
        .await;
        assert_eq!(read["result"]["content"], "hello");
        // ls
        let ls = perform_action(
            &json!({ "verb": "ls", "actionId": "a3", "allowedRoots": roots, "args": {} }),
            &context,
        )
        .await;
        assert!(ls["result"]["listing"].as_str().unwrap().contains("note.txt"));
        std::fs::remove_dir_all(&root).ok();
    }

    #[cfg(unix)]
    #[tokio::test(flavor = "current_thread")]
    async fn connection_cancellation_wins_while_file_open_is_blocked() {
        use std::os::unix::ffi::OsStrExt as _;
        use tokio_util::sync::CancellationToken;

        let root = scratch("blocked-open-cancellation");
        let fifo = root.join("blocked.fifo");
        let fifo_name = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo_name.as_ptr(), 0o600) }, 0);

        let roots = vec![root.display().to_string()];
        let mut context = ctx("supervised", Some(roots.clone()), root.clone());
        let barrier = Arc::new(std::sync::Barrier::new(2));
        context.test_file_operation_barrier = Some(Arc::clone(&barrier));
        let cancellation = CancellationToken::new();
        let worker_cancellation = cancellation.clone();
        let unblock = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(25));
            worker_cancellation.cancel();
            std::thread::sleep(std::time::Duration::from_millis(175));
            barrier.wait();
        });

        let frame = json!({ "verb": "read", "actionId": "blocked", "allowedRoots": roots,
                            "args": { "path": "blocked.fifo" } });
        let result = tokio::select! {
            biased;
            _ = cancellation.cancelled() => None,
            result = perform_action(&frame, &context) => Some(result),
        };

        assert!(result.is_none(), "connection cancellation must not wait for a blocked file open");
        assert_eq!(
            context.file_slots.available_permits(),
            MAX_BLOCKING_FILE_ACTIONS - 1,
            "cancelled connections must not release capacity held by blocking work"
        );
        unblock.join().unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while context.file_slots.available_permits() != MAX_BLOCKING_FILE_ACTIONS {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("file action capacity must return after the blocking operation finishes");
        std::fs::remove_dir_all(&root).ok();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn file_actions_reject_fifos_without_blocking() {
        use std::os::unix::ffi::OsStrExt as _;

        let root = scratch("special-file-refusal");
        let fifo = root.join("blocked.fifo");
        let fifo_name = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo_name.as_ptr(), 0o600) }, 0);
        let roots = vec![root.display().to_string()];
        let context = ctx("supervised", Some(roots.clone()), root.clone());

        for (verb, args) in [
            ("read", json!({ "path": "blocked.fifo" })),
            ("write", json!({ "path": "blocked.fifo", "content": "no" })),
        ] {
            let frame = json!({
                "verb": verb,
                "actionId": verb,
                "allowedRoots": roots,
                "args": args,
            });
            let result = tokio::time::timeout(
                std::time::Duration::from_secs(1),
                perform_action(&frame, &context),
            )
            .await
            .expect("special-file refusal must not block");
            assert_eq!(result["code"], "path_forbidden", "{result}");
        }

        std::fs::remove_dir_all(&root).ok();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn read_fifo_returns_path_forbidden_without_hanging() {
        use std::os::unix::ffi::OsStrExt as _;

        let root = scratch("read-fifo");
        let fifo = root.join("blocked.fifo");
        let fifo_name = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo_name.as_ptr(), 0o600) }, 0);
        let roots = vec![root.display().to_string()];
        let context = ctx("supervised", Some(roots.clone()), root.clone());
        let read = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            perform_action(
                &json!({ "verb": "read", "actionId": "read-fifo", "allowedRoots": roots,
                         "args": { "path": "blocked.fifo" } }),
                &context,
            ),
        )
        .await
        .expect("FIFO reads must not block");
        assert_eq!(read["code"], "path_forbidden", "{read}");
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn file_action_capacity_is_bounded_across_connections() {
        let root = scratch("file-capacity");
        std::fs::write(root.join("note.txt"), "hello").unwrap();
        let roots = vec![root.display().to_string()];
        let context = ctx("supervised", Some(roots.clone()), root.clone());
        let _capacity = Arc::clone(&context.file_slots)
            .try_acquire_many_owned(MAX_BLOCKING_FILE_ACTIONS as u32)
            .unwrap();

        let read = perform_action(
            &json!({ "verb": "read", "actionId": "busy", "allowedRoots": roots,
                     "args": { "path": "note.txt" } }),
            &context,
        )
        .await;

        assert_eq!(read["ok"], false);
        assert_eq!(read["code"], "busy");
        std::fs::remove_dir_all(&root).ok();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn grep_accepts_a_regular_file_path() {
        let root = scratch("grep-file");
        let file = root.join("note.txt");
        std::fs::write(&file, "needle\n").unwrap();
        let roots = vec![root.display().to_string()];
        let mut context = ctx("supervised", Some(roots.clone()), root.clone());
        context.env =
            scrubbed_env(&HashMap::from([("PATH".to_owned(), "/usr/bin:/bin".to_owned())]));
        let grep = perform_action(
            &json!({ "verb": "grep", "actionId": "a1", "allowedRoots": roots,
                     "args": { "path": file, "pattern": "needle" }, "timeoutMs": 10000 }),
            &context,
        )
        .await;
        assert_eq!(grep["ok"], true, "{grep}");
        assert!(grep["result"]["output"].as_str().unwrap().contains("needle"));
        let find = perform_action(
            &json!({ "verb": "find", "actionId": "a2", "allowedRoots": roots,
                     "args": { "path": file }, "timeoutMs": 10000 }),
            &context,
        )
        .await;
        assert_eq!(find["ok"], true, "{find}");
        let matching_find = perform_action(
            &json!({ "verb": "find", "actionId": "a3", "allowedRoots": roots,
                     "args": { "path": file, "pattern": "note.txt" }, "timeoutMs": 10000 }),
            &context,
        )
        .await;
        assert_eq!(matching_find["ok"], true, "{matching_find}");
        assert!(matching_find["result"]["output"].as_str().unwrap().contains("note.txt"));
        let nonmatching_find = perform_action(
            &json!({ "verb": "find", "actionId": "a4", "allowedRoots": roots,
                     "args": { "path": file, "pattern": "other.txt" }, "timeoutMs": 10000 }),
            &context,
        )
        .await;
        assert_eq!(nonmatching_find["ok"], true, "{nonmatching_find}");
        assert_eq!(nonmatching_find["result"]["output"], "");
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn ls_bounds_retained_entries_and_reports_omitted_names() {
        let root = scratch("ls-bound");
        for index in 0..(MAX_LISTING_ENTRIES + 5) {
            std::fs::write(root.join(format!("entry-{index:04}.txt")), "").unwrap();
        }
        let roots = vec![root.display().to_string()];
        let context = ctx("supervised", Some(roots.clone()), root.clone());
        let ls = perform_action(
            &json!({ "verb": "ls", "actionId": "a1", "allowedRoots": roots, "args": {} }),
            &context,
        )
        .await;
        assert_eq!(ls["ok"], true, "{ls}");
        let listing = ls["result"]["listing"].as_str().unwrap();
        assert!(listing.contains("…[more entries omitted]"));
        assert_eq!(listing.lines().count(), MAX_LISTING_ENTRIES + 1);
        std::fs::remove_dir_all(&root).ok();
    }
    #[tokio::test]
    async fn oversized_regular_file_is_refused_before_reading() {
        let root = scratch("oversized-read");
        let file = root.join("oversized.txt");
        let handle = std::fs::File::create(&file).unwrap();
        // A sparse file keeps this deterministic and avoids allocating a
        // multi-megabyte buffer merely to exercise the size guard.
        handle.set_len(MAX_READ_BYTES + 1).unwrap();
        let roots = vec![root.display().to_string()];
        let context = ctx("supervised", Some(roots.clone()), root.clone());

        let read = perform_action(
            &json!({ "verb": "read", "actionId": "oversized", "allowedRoots": roots,
                     "args": { "path": "oversized.txt" } }),
            &context,
        )
        .await;

        assert_eq!(read["ok"], false);
        assert_eq!(read["code"], "path_forbidden");
        assert!(read["message"].as_str().unwrap().contains("max 2000000"));
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn directory_listing_caps_entries_and_marks_truncation() {
        let root = scratch("listing-cap");
        for index in 0..=MAX_LISTING_ENTRIES {
            std::fs::File::create(root.join(format!("entry-{index:04}.txt"))).unwrap();
        }
        let roots = vec![root.display().to_string()];
        let context = ctx("supervised", Some(roots.clone()), root.clone());

        let listing = perform_action(
            &json!({ "verb": "ls", "actionId": "listing-cap", "allowedRoots": roots,
                     "args": {} }),
            &context,
        )
        .await;

        let output = listing["result"]["listing"].as_str().unwrap();
        assert!(output.ends_with("\n…[more entries omitted]"));
        assert_eq!(output.matches(".txt").count(), MAX_LISTING_ENTRIES);
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn file_verbs_outside_roots_are_path_forbidden() {
        let root = scratch("scoped");
        let roots = vec![root.display().to_string()];
        let context = ctx("supervised", Some(roots.clone()), root.clone());
        let read = perform_action(
            &json!({ "verb": "read", "actionId": "a1", "allowedRoots": roots,
                     "args": { "path": "/etc/hosts" } }),
            &context,
        )
        .await;
        assert_eq!(read["ok"], false);
        assert_eq!(read["code"], "path_forbidden");
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn grep_returns_busy_when_file_action_capacity_is_exhausted() {
        let root = scratch("grep-capacity");
        std::fs::write(root.join("note.txt"), "needle").unwrap();
        let roots = vec![root.display().to_string()];
        let context = ctx("supervised", Some(roots.clone()), root.clone());
        let _capacity = Arc::clone(&context.file_slots)
            .try_acquire_many_owned(MAX_BLOCKING_FILE_ACTIONS as u32)
            .unwrap();

        let grep = perform_action(
            &json!({ "verb": "grep", "actionId": "grep-busy", "allowedRoots": roots,
                     "args": { "path": ".", "pattern": "needle" } }),
            &context,
        )
        .await;

        assert_eq!(grep["ok"], false);
        assert_eq!(grep["code"], "busy");
        std::fs::remove_dir_all(&root).ok();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn symlinks_cannot_escape_allowed_roots() {
        let root = scratch("symlink");
        let outside = scratch("outside");
        std::fs::write(outside.join("secret.txt"), "top secret").unwrap();
        // A symlink inside the root pointing outside it.
        std::os::unix::fs::symlink(&outside, root.join("escape")).unwrap();
        let roots = vec![root.display().to_string()];
        let context = ctx("supervised", Some(roots.clone()), root.clone());
        let read = perform_action(
            &json!({ "verb": "read", "actionId": "a1", "allowedRoots": roots,
                     "args": { "path": "escape/secret.txt" } }),
            &context,
        )
        .await;
        assert_eq!(read["ok"], false);
        assert_eq!(read["code"], "path_forbidden");
        std::fs::remove_dir_all(&root).ok();
        std::fs::remove_dir_all(&outside).ok();
    }

    #[cfg(unix)]
    #[test]
    fn ancestor_replacement_cannot_redirect_a_scoped_read() {
        let root = scratch("read-race");
        let outside = scratch("read-race-outside");
        std::fs::create_dir(root.join("ancestor")).unwrap();
        std::fs::write(root.join("ancestor/secret.txt"), "inside").unwrap();
        std::fs::write(outside.join("secret.txt"), "outside").unwrap();
        let roots = vec![root.display().to_string()];
        let lists: RootLists = [Some(roots.as_slice()), None];
        let scoped = resolve_scoped_host_path(
            "ancestor/secret.txt",
            &lists,
            &root,
            root.to_str().unwrap(),
            false,
        )
        .unwrap()
        .unwrap();

        std::fs::rename(root.join("ancestor"), root.join("original")).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("ancestor")).unwrap();

        let result = read_utf8_no_follow(&scoped);
        assert!(matches!(result, Err(HostError::Refusal(_)) | Err(HostError::Io(_))));
        std::fs::remove_dir_all(&root).ok();
        std::fs::remove_dir_all(&outside).ok();
    }

    #[cfg(unix)]
    #[test]
    fn ancestor_replacement_cannot_redirect_a_scoped_write() {
        let root = scratch("write-race");
        let outside = scratch("write-race-outside");
        std::fs::create_dir(root.join("ancestor")).unwrap();
        let roots = vec![root.display().to_string()];
        let lists: RootLists = [Some(roots.as_slice()), None];
        let scoped = resolve_scoped_host_path(
            "ancestor/new.txt",
            &lists,
            &root,
            root.to_str().unwrap(),
            true,
        )
        .unwrap()
        .unwrap();

        std::fs::rename(root.join("ancestor"), root.join("original")).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("ancestor")).unwrap();

        assert!(write_utf8_no_follow(&scoped, "unsafe").is_err());
        assert!(!outside.join("new.txt").exists());
        std::fs::remove_dir_all(&root).ok();
        std::fs::remove_dir_all(&outside).ok();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn exec_runs_with_cwd_discipline_and_returns_exit_code_and_output() {
        let root = scratch("exec");
        let roots = vec![root.display().to_string()];
        let mut context = ctx("supervised", Some(roots.clone()), root.clone());
        context.env =
            scrubbed_env(&HashMap::from([("PATH".to_owned(), "/usr/bin:/bin".to_owned())]));
        let exec = perform_action(
            &json!({ "verb": "exec", "actionId": "a1", "allowedRoots": roots,
                     "args": { "command": "echo hi && pwd" }, "timeoutMs": 10000 }),
            &context,
        )
        .await;
        assert_eq!(exec["ok"], true, "{exec}");
        assert_eq!(exec["result"]["exitCode"], 0);
        let output = exec["result"]["output"].as_str().unwrap();
        assert!(output.contains("hi"));
        assert!(output.contains(&root.display().to_string()));
        std::fs::remove_dir_all(&root).ok();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn timeout_escalates_after_shell_exits_with_open_descendant_pipe() {
        let env = scrubbed_env(&HashMap::from([("PATH".to_owned(), "/usr/bin:/bin".to_owned())]));
        let outcome = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            run_spec(RunSpec::Shell { command: "sleep 5 &" }, Path::new("/"), None, 20, &env, None),
        )
        .await
        .expect("timeout cleanup must not wait for a descendant pipe");
        assert!(matches!(outcome, RunOutcome::TimedOut));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn timeout_after_leader_reap_kills_descendant_group() {
        let pid_file =
            std::env::temp_dir().join(format!("chatmux-owner-timeout-{}", std::process::id()));
        std::fs::remove_file(&pid_file).ok();
        let command = format!("sleep 30 & echo $! > {}; exit 0", pid_file.display());
        let env = scrubbed_env(&HashMap::from([("PATH".to_owned(), "/usr/bin:/bin".to_owned())]));
        let worker = tokio::spawn(async move {
            run_spec(RunSpec::Shell { command: &command }, Path::new("/"), None, 100, &env, None)
                .await
        });
        let pid = tokio::time::timeout(std::time::Duration::from_secs(1), async {
            loop {
                if let Some(pid) = std::fs::read_to_string(&pid_file)
                    .ok()
                    .and_then(|value| value.trim().parse::<libc::pid_t>().ok())
                {
                    break pid;
                }
                tokio::time::sleep(std::time::Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("descendant pid marker");
        let outcome = tokio::time::timeout(std::time::Duration::from_secs(2), worker)
            .await
            .expect("timeout cleanup must complete")
            .expect("runner task must join");
        assert!(matches!(outcome, RunOutcome::TimedOut));
        assert_ne!(unsafe { libc::kill(pid, 0) }, 0, "descendant must be killed");
        std::fs::remove_file(pid_file).ok();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn cancellation_after_leader_reap_kills_descendant_group() {
        use tokio_util::sync::CancellationToken;

        let pid_file =
            std::env::temp_dir().join(format!("chatmux-owner-cancel-{}", std::process::id()));
        std::fs::remove_file(&pid_file).ok();
        let command = format!("sleep 30 & echo $! > {}; exit 0", pid_file.display());
        let env = scrubbed_env(&HashMap::from([("PATH".to_owned(), "/usr/bin:/bin".to_owned())]));
        let cancellation = CancellationToken::new();
        let worker_cancellation = cancellation.clone();
        let worker = tokio::spawn(async move {
            run_spec(
                RunSpec::Shell { command: &command },
                Path::new("/"),
                None,
                30_000,
                &env,
                Some(worker_cancellation),
            )
            .await
        });
        let pid = tokio::time::timeout(std::time::Duration::from_secs(1), async {
            loop {
                if let Some(pid) = std::fs::read_to_string(&pid_file)
                    .ok()
                    .and_then(|value| value.trim().parse::<libc::pid_t>().ok())
                {
                    break pid;
                }
                tokio::time::sleep(std::time::Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("descendant pid marker");
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        cancellation.cancel();
        let outcome = tokio::time::timeout(std::time::Duration::from_secs(2), worker)
            .await
            .expect("cancellation cleanup must complete")
            .expect("runner task must join");
        assert!(matches!(
            outcome,
            RunOutcome::Failed { message } if message == "process cancelled"
        ));
        assert_ne!(unsafe { libc::kill(pid, 0) }, 0, "descendant must be killed");
        std::fs::remove_file(pid_file).ok();
    }

    #[test]
    fn persistent_wait_errors_escalate_to_bounded_cleanup() {
        let mut retries = 0;
        for _ in 0..MAX_WAIT_RETRIES.saturating_sub(1) {
            assert_eq!(next_wait_retry(&mut retries), WaitRetryAction::Retry);
        }
        assert_eq!(next_wait_retry(&mut retries), WaitRetryAction::Escalate);
    }

    #[cfg(windows)]
    #[test]
    fn successful_windows_owner_cleanup_does_not_terminate_job() {
        assert!(!windows_job_should_terminate(false));
        assert!(windows_job_should_terminate(true));
    }
    #[tokio::test]
    async fn exec_receives_scoped_process_environment_values() {
        let root = scratch("procenv");
        let roots = vec![root.display().to_string()];
        let mut context = ctx("supervised", Some(roots.clone()), root.clone());
        context.env =
            scrubbed_env(&HashMap::from([("PATH".to_owned(), "/usr/bin:/bin".to_owned())]));
        let exec = perform_action(
            &json!({ "verb": "exec", "actionId": "a1", "allowedRoots": roots,
                     "args": { "command": "printf '%s' \"$MY_TOKEN\"" }, "timeoutMs": 10000,
                     "runtime": { "environment": { "MY_TOKEN": "abc123" }, "files": [] } }),
            &context,
        )
        .await;
        assert_eq!(exec["result"]["output"], "abc123");
        std::fs::remove_dir_all(&root).ok();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn process_file_setup_failure_does_not_run_command_or_leak_secret() {
        let root = scratch("process-file-setup-failure");
        let tmpdir_file = root.join("not-a-directory");
        std::fs::write(&tmpdir_file, "").unwrap();
        let marker = root.join("command-ran");
        let roots = vec![root.display().to_string()];
        let mut context = ctx("supervised", Some(roots.clone()), root.clone());
        context.env = scrubbed_env(&HashMap::from([
            ("PATH".to_owned(), "/usr/bin:/bin".to_owned()),
            ("TMPDIR".to_owned(), tmpdir_file.display().to_string()),
        ]));
        let secret = "process-file-secret";
        let exec = perform_action(
            &json!({
                "verb": "exec",
                "actionId": "process-file-setup-failure",
                "allowedRoots": roots,
                "args": {
                    "command": format!("printf '%s' \"$MY_SECRET\" > '{}'", marker.display()),
                },
                "runtime": {
                    "environment": { "MY_SECRET": secret },
                    "files": [{
                        "contentEnvironmentVariable": "MY_SECRET",
                        "pathEnvironmentVariable": "MY_SECRET_PATH",
                        "pathHint": "credentials",
                    }],
                },
                "timeoutMs": 10000,
            }),
            &context,
        )
        .await;

        assert_eq!(exec["ok"], true, "{exec}");
        assert_ne!(exec["result"]["exitCode"], 0, "setup unexpectedly succeeded: {exec}");
        assert!(!marker.exists(), "target command ran after setup failure: {exec}");
        assert!(!exec.to_string().contains(secret), "secret leaked in action result: {exec}");
        std::fs::remove_dir_all(&root).ok();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn observe_trust_refuses_mutating_verbs_allows_reads() {
        let root = scratch("observe");
        std::fs::write(root.join("f.txt"), "data").unwrap();
        let roots = vec![root.display().to_string()];
        let context = ctx("observe", Some(roots.clone()), root.clone());
        let write = perform_action(
            &json!({ "verb": "write", "actionId": "a1", "allowedRoots": roots,
                     "args": { "path": "x.txt", "content": "no" } }),
            &context,
        )
        .await;
        assert_eq!(write["code"], "trust_refused");
        let read = perform_action(
            &json!({ "verb": "read", "actionId": "a2", "allowedRoots": roots,
                     "args": { "path": "f.txt" } }),
            &context,
        )
        .await;
        assert_eq!(read["ok"], true);
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn unknown_verbs_answer_unsupported_verb() {
        let context = ctx("supervised", None, home());
        let result =
            perform_action(&json!({ "verb": "nope", "actionId": "a1", "args": {} }), &context)
                .await;
        assert_eq!(result["ok"], false);
        assert_eq!(result["code"], "unsupported_verb");
    }

    #[cfg(not(unix))]
    #[tokio::test]
    async fn scoped_actions_answer_typed_unsupported() {
        let root = scratch("unsupported-scope");
        std::fs::write(root.join("file.txt"), "content").expect("write fixture");
        let roots = vec![root.display().to_string()];
        let context = ctx("supervised", Some(roots.clone()), root.clone());
        let result = perform_action(
            &json!({
                "version": 3,
                "verb": "read",
                "actionId": "a1",
                "allowedRoots": roots,
                "args": { "path": "file.txt" },
            }),
            &context,
        )
        .await;
        assert_eq!(result["type"], "action_result");
        assert_eq!(result["actionId"], "a1");
        assert_eq!(result["ok"], false);
        assert_eq!(result["code"], "unsupported_verb");
        std::fs::remove_dir_all(root).ok();
    }

    #[tokio::test]
    async fn invalid_process_runtime_does_not_reflect_credential_bytes() {
        let context = ctx("supervised", None, home());
        let result = perform_action(
            &json!({ "verb": "exec", "actionId": "a1", "args": { "command": "true" },
                     "runtime": { "environment": { "BAD NAME": "sekret-value" }, "files": [] } }),
            &context,
        )
        .await;
        assert_eq!(result["ok"], false);
        assert!(!result["message"].as_str().unwrap().contains("sekret-value"));
    }
}
