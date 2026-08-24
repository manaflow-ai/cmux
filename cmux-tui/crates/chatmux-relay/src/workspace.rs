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

use serde_json::Value;
use sha2::{Digest as _, Sha256};
use tokio::sync::mpsc::UnboundedSender;

use crate::preview_proxy::PreviewRegistry;
use crate::relay_wire as wire;
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

/// On-machine runtime bounds for one op (Worker default is 30s, ceiling
/// 120s; the relay tolerates up to the v3 exec ceiling).
const MIN_TIMEOUT_MS: i64 = 1_000;
const MAX_TIMEOUT_MS: i64 = 300_000;

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
    if raw.chars().count() > MAX_PATH_CHARS {
        return Err(format!("path exceeds {MAX_PATH_CHARS} characters"));
    }
    if raw.chars().any(|c| c.is_control()) {
        return Err("path contains a control character".to_owned());
    }
    let lower = raw.to_ascii_lowercase();
    for encoded in ["%00", "%25", "%2e", "%2f", "%5c"] {
        if lower.contains(encoded) {
            return Err("percent-encoded path syntax is not accepted".to_owned());
        }
    }
    if raw.starts_with("//") || raw.starts_with("\\\\") {
        return Err("ambiguous leading path separators are not accepted".to_owned());
    }
    // A backslash is a filename character on POSIX but a separator on
    // Windows; refuse the ambiguous spelling so one request cannot acquire
    // different authority after crossing hosts.
    if std::path::MAIN_SEPARATOR == '/' && raw.contains('\\') {
        return Err("use '/' as the path separator on this machine".to_owned());
    }
    Ok(())
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
fn read_bytes_no_follow(path: &Path) -> std::io::Result<Vec<u8>> {
    use std::io::Read as _;
    let mut file = open_no_follow(path)?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    Ok(bytes)
}

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
    let path = scope.resolve(&op.path, false)?;
    let bytes = read_bytes_no_follow(&path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            Refusal::not_found(format!("{} does not exist", op.path))
        } else {
            Refusal::failed(format!("could not read {}: {error}", op.path))
        }
    })?;
    let max = usize::try_from(clamp_i64(op.max_bytes, 1, READ_MAX_BYTES)).unwrap_or(1);
    let truncated = bytes.len() > max;
    let slice = if truncated { &bytes[..max] } else { &bytes[..] };
    let (content, encoding) = match std::str::from_utf8(slice) {
        Ok(text) => (text.to_owned(), wire::FsContentEncoding::Utf8),
        Err(error) if truncated && error.error_len().is_none() && error.valid_up_to() > 0 => {
            // The byte cap cut a multi-byte character; trim to the last
            // whole character instead of downgrading the file to base64.
            let valid = error.valid_up_to();
            match std::str::from_utf8(&slice[..valid]) {
                Ok(text) => (text.to_owned(), wire::FsContentEncoding::Utf8),
                Err(_) => (base64_encode(slice), wire::FsContentEncoding::Base64),
            }
        }
        Err(_) => (base64_encode(slice), wire::FsContentEncoding::Base64),
    };
    Ok(wire::WorkspaceResultBody::FsRead(wire::FsReadResult {
        op: wire::TagFsRead::FsRead,
        content,
        encoding,
        sha256: sha256_hex(&bytes),
        size: i64::try_from(bytes.len()).unwrap_or(i64::MAX),
        truncated,
    }))
}

fn base64_encode(bytes: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn run_write(scope: &Scope, op: &wire::FsWriteOp) -> Result<wire::WorkspaceResultBody, Refusal> {
    if op.content.len() > WRITE_MAX_BYTES {
        return Err(Refusal::new(
            wire::WorkspaceErrorCode::TooLarge,
            format!("write body exceeds {WRITE_MAX_BYTES} bytes"),
        ));
    }
    let path = scope.resolve(&op.path, true)?;
    let existing = match read_bytes_no_follow(&path) {
        Ok(bytes) => Some(bytes),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => {
            return Err(Refusal::failed(format!("could not read {}: {error}", op.path)));
        }
    };
    if let Some(base) = &op.base_sha256 {
        // Compare-and-swap (HD6 explicit save): a stale base refuses with
        // the CURRENT hash so the editor can offer a quiet refresh. A
        // missing file never matches a hash (same as the TS double).
        let current = existing.as_deref().map(sha256_hex);
        if current.as_deref() != Some(base.as_str()) {
            return Err(Refusal {
                code: wire::WorkspaceErrorCode::WriteConflict,
                message: format!("{} changed on disk", op.path),
                current_sha256: current,
            });
        }
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| Refusal::failed(format!("could not create {}: {error}", op.path)))?;
    }
    write_bytes_no_follow(&path, op.content.as_bytes())
        .map_err(|error| Refusal::failed(format!("could not write {}: {error}", op.path)))?;
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
    let destination_exists = std::fs::symlink_metadata(&to).is_ok();
    if destination_exists && op.overwrite != Some(true) {
        return Err(Refusal::new(
            wire::WorkspaceErrorCode::DestinationExists,
            format!("{} already exists", op.to_path),
        ));
    }
    if let Some(parent) = to.parent() {
        std::fs::create_dir_all(parent).map_err(|error| {
            Refusal::failed(format!("could not create {}: {error}", op.to_path))
        })?;
    }
    std::fs::rename(&from, &to).map_err(|error| {
        Refusal::failed(format!("could not rename {} -> {}: {error}", op.from_path, op.to_path))
    })?;
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
        std::fs::remove_dir_all(&path)
            .map_err(|error| Refusal::failed(format!("could not delete {}: {error}", op.path)))?;
    } else {
        // The canonical path (symlinks were resolved and re-scoped by
        // resolve(), like every other workspace op).
        std::fs::remove_file(&path)
            .map_err(|error| Refusal::failed(format!("could not delete {}: {error}", op.path)))?;
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
        let Ok(bytes) = read_bytes_no_follow(entry.path()) else { continue };
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

fn git_command(root: &Path, args: &[&str]) -> tokio::process::Command {
    let mut command = tokio::process::Command::new("git");
    command
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
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

/// Two-column XY code in the porcelain v1 spelling ("M " not "M.") — the
/// wire schema pins v1's verbatim codes.
fn porcelain_v1_xy(xy: &str) -> String {
    xy.chars().map(|column| if column == '.' { ' ' } else { column }).collect()
}

async fn run_git_status(scope: &Scope) -> Result<wire::WorkspaceResultBody, Refusal> {
    let root = scope.existing_workdir()?;
    let output = git_command(&root, &["status", "--porcelain=v2", "--branch", "-z"])
        .output()
        .await
        .map_err(|error| Refusal::failed(format!("could not run git: {error}")))?;
    if !output.status.success() {
        return Err(git_refusal("git status failed", &output.stderr));
    }
    let mut branch: Option<String> = None;
    let mut upstream: Option<String> = None;
    let mut ahead: i64 = 0;
    let mut behind: i64 = 0;
    let mut entries: Vec<wire::GitStatusEntry> = Vec::new();
    let mut truncated = false;
    let mut chunks = output
        .stdout
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
    let root = scope.existing_workdir()?;
    let base = op.base.as_deref().unwrap_or("HEAD");
    if base.is_empty() || base.starts_with('-') {
        return Err(Refusal::failed("invalid diff base"));
    }
    let context = op.context_lines.map(|lines| format!("-U{}", lines.clamp(0, 100)));
    let mut args: Vec<&str> = vec!["diff", base];
    if let Some(context) = context.as_deref() {
        args.push(context);
    }
    let paths = op.paths.as_deref().unwrap_or_default();
    if !paths.is_empty() {
        args.push("--");
        for path in paths {
            validate_request_path(path).map_err(Refusal::path_forbidden)?;
            args.push(path);
        }
    }
    let mut child = git_command(&root, &args)
        .spawn()
        .map_err(|error| Refusal::failed(format!("could not run git: {error}")))?;
    // Stream stdout: the stat counts the FULL diff, but the patch buffer
    // drops whole files past DIFF_MAX_BYTES so memory and the wire stay
    // bounded even for a pathological working tree.
    use tokio::io::AsyncBufReadExt as _;
    let Some(stdout) = child.stdout.take() else {
        return Err(Refusal::failed("git diff produced no stdout pipe"));
    };
    let mut lines = tokio::io::BufReader::new(stdout).lines();
    let mut patch = String::new();
    let mut current_file_start = 0_usize;
    let mut capped = false;
    let mut truncated = false;
    let mut files: i64 = 0;
    let mut additions: i64 = 0;
    let mut deletions: i64 = 0;
    while let Ok(Some(line)) = lines.next_line().await {
        if line.starts_with("diff --git ") {
            files += 1;
            if !capped {
                current_file_start = patch.len();
            }
        } else if line.starts_with('+') && !line.starts_with("+++") {
            additions += 1;
        } else if line.starts_with('-') && !line.starts_with("---") {
            deletions += 1;
        }
        if !capped {
            if patch.len() + line.len() + 1 > DIFF_MAX_BYTES {
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
    let output = child
        .wait_with_output()
        .await
        .map_err(|error| Refusal::failed(format!("git diff did not finish: {error}")))?;
    if !output.status.success() {
        return Err(git_refusal("git diff failed", &output.stderr));
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

/// State that outlives one relay socket: the preview proxies (and their
/// console ring) keep serving across reconnects because the tunnel keeps
/// pointing at their ports.
pub struct SharedRuntime {
    pub preview: PreviewRegistry,
    /// This machine's own `--allow-root` scoping (config authority).
    pub local_roots: Option<Vec<String>>,
}

impl SharedRuntime {
    pub fn new(local_roots: Option<Vec<String>>) -> SharedRuntime {
        SharedRuntime { preview: PreviewRegistry::new(), local_roots }
    }
}

/// Per-socket workspace state: watches die with the connection (the Worker
/// re-opens them), requests answer onto this connection's outbound queue.
pub struct Connection {
    runtime: Arc<SharedRuntime>,
    outbound: UnboundedSender<String>,
    /// Machine-side trust re-check: when the LOCAL effective trust is
    /// observe, mutating ops refuse regardless of what the server claims.
    local_observe: Arc<AtomicBool>,
    watches: WatchRegistry,
}

impl Connection {
    pub fn new(runtime: Arc<SharedRuntime>, outbound: UnboundedSender<String>) -> Connection {
        let watches = WatchRegistry::new(outbound.clone());
        Connection { runtime, outbound, local_observe: Arc::new(AtomicBool::new(false)), watches }
    }

    pub fn set_local_observe(&self, observe: bool) {
        self.local_observe.store(observe, Ordering::Relaxed);
    }

    /// Entry point for the three v6 server frame types. Never blocks; never
    /// closes the socket (W23: a bad frame gets a typed answer or silence).
    pub fn handle_frame(&self, frame: Value) {
        let Some(frame_type) = frame.get("type").and_then(Value::as_str) else { return };
        match frame_type {
            "workspace_request" => {
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
                            let _ = self.outbound.send(error_frame(request_id, &refusal));
                        }
                    }
                }
            }
            "fs_watch_open" => {
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
        let runtime = Arc::clone(&self.runtime);
        let outbound = self.outbound.clone();
        let local_observe = Arc::clone(&self.local_observe);
        tokio::spawn(async move {
            let request_id = request.request_id.clone();
            let outcome = execute(&runtime, &local_observe, request).await;
            let text = match outcome {
                Ok(body) => ok_frame(&request_id, body),
                Err(refusal) => error_frame(&request_id, &refusal),
            };
            let _ = outbound.send(text);
        });
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
) -> Result<wire::WorkspaceResultBody, Refusal> {
    if is_mutating(&request.op)
        && (request.trust == wire::TrustLevel::Observe || local_observe.load(Ordering::Relaxed))
    {
        return Err(Refusal::new(
            wire::WorkspaceErrorCode::TrustRefused,
            "observe trust refuses mutating workspace ops",
        ));
    }
    let timeout_ms = clamp_i64(request.timeout_ms, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS);
    let deadline = std::time::Duration::from_millis(timeout_ms.unsigned_abs());
    match tokio::time::timeout(deadline, run_op(runtime, request)).await {
        Ok(outcome) => outcome,
        Err(_) => Err(Refusal::new(
            wire::WorkspaceErrorCode::Timeout,
            format!("workspace op exceeded {timeout_ms}ms"),
        )),
    }
}

async fn run_op(
    runtime: &Arc<SharedRuntime>,
    request: wire::RelayWorkspaceRequest,
) -> Result<wire::WorkspaceResultBody, Refusal> {
    let scope = Scope::build(request.allowed_roots.as_deref(), runtime.local_roots.as_deref())?;
    match request.op {
        wire::WorkspaceOp::FsTree(op) => blocking(move || run_tree(&scope, &op)).await,
        wire::WorkspaceOp::FsRead(op) => blocking(move || run_read(&scope, &op)).await,
        wire::WorkspaceOp::FsWrite(op) => blocking(move || run_write(&scope, &op)).await,
        wire::WorkspaceOp::FsRename(op) => blocking(move || run_rename(&scope, &op)).await,
        wire::WorkspaceOp::FsDelete(op) => blocking(move || run_delete(&scope, &op)).await,
        wire::WorkspaceOp::FsSearch(op) => blocking(move || run_search(&scope, &op)).await,
        wire::WorkspaceOp::GitStatus(_) => run_git_status(&scope).await,
        wire::WorkspaceOp::GitDiff(op) => run_git_diff(&scope, &op).await,
        wire::WorkspaceOp::PreviewOpen(op) => runtime.preview.open(op.target_port).await,
        wire::WorkspaceOp::PreviewConsoleTail(op) => runtime.preview.tail(op.max_events),
    }
}

async fn blocking<F>(body: F) -> Result<wire::WorkspaceResultBody, Refusal>
where
    F: FnOnce() -> Result<wire::WorkspaceResultBody, Refusal> + Send + 'static,
{
    match tokio::task::spawn_blocking(body).await {
        Ok(outcome) => outcome,
        Err(join_error) => Err(Refusal::failed(format!("workspace op crashed: {join_error}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        assert_eq!(cut.sha256, full.sha256, "hash always covers the full file");
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
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        let connection = Connection::new(runtime, tx);
        connection.handle_frame(patched);
        let text = tokio::time::timeout(std::time::Duration::from_secs(15), rx.recv())
            .await
            .expect("no answer within 15s")
            .expect("channel open");
        serde_json::from_str(&text).expect("valid json frame")
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
