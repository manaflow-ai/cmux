use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use cmux_remote_protocol::{RpcError, WorkspaceId};
use tokio::sync::Mutex;

#[cfg(unix)]
use std::ffi::{CStr, CString};
#[cfg(unix)]
use std::fs::File;
#[cfg(unix)]
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
#[cfg(unix)]
use std::os::unix::ffi::OsStrExt as _;
#[cfg(unix)]
use std::os::unix::fs::MetadataExt as _;

const MAX_PROTOCOL_PATH_BYTES: usize = 16 * 1024;
const MAX_PROTOCOL_PATH_COMPONENTS: usize = 1_024;

/// One daemon-owned workspace root.
///
/// Paths sent over the protocol are always interpreted relative to `canonical`.
/// The mutation lock serializes cmux-originated writes and patch commits. It does
/// not attempt to isolate an enrolled client from other processes owned by the
/// same operating-system user.
#[derive(Debug)]
pub(crate) struct WorkspaceRoot {
    pub(crate) id: WorkspaceId,
    canonical: PathBuf,
    #[cfg(unix)]
    unix: UnixWorkspaceRoot,
    pub(crate) mutation: Mutex<()>,
}

impl WorkspaceRoot {
    pub(crate) async fn open(id: WorkspaceId, root: &str) -> Result<Arc<Self>, RpcError> {
        if root.contains('\0') {
            return Err(invalid_path("workspace root contains a NUL byte"));
        }
        if root.len() > MAX_PROTOCOL_PATH_BYTES {
            return Err(invalid_path("workspace root is too long"));
        }
        let supplied = PathBuf::from(root);
        if !supplied.is_absolute() {
            return Err(invalid_path("workspace root must be absolute"));
        }
        let canonical = tokio::fs::canonicalize(&supplied)
            .await
            .map_err(|error| io_error("open-workspace", &supplied, error))?;
        let metadata = tokio::fs::metadata(&canonical)
            .await
            .map_err(|error| io_error("open-workspace", &canonical, error))?;
        if !metadata.is_dir() {
            return Err(RpcError::new(
                "not-a-directory",
                format!("workspace root is not a directory: {}", canonical.display()),
            ));
        }
        #[cfg(unix)]
        let unix = {
            let canonical = canonical.clone();
            tokio::task::spawn_blocking(move || UnixWorkspaceRoot::open(canonical)).await.map_err(
                |error| {
                    RpcError::new("internal", format!("workspace root open task failed: {error}"))
                },
            )??
        };
        Ok(Arc::new(Self {
            id,
            canonical,
            #[cfg(unix)]
            unix,
            mutation: Mutex::new(()),
        }))
    }

    pub(crate) fn display_root(&self) -> String {
        self.canonical.to_string_lossy().into_owned()
    }

    pub(crate) fn canonical_root(&self) -> &Path {
        &self.canonical
    }

    #[cfg(unix)]
    pub(crate) fn unix_root(&self) -> UnixWorkspaceRoot {
        self.unix.clone()
    }

    pub(crate) async fn resolve_existing(&self, input: &str) -> Result<PathBuf, RpcError> {
        let relative = validate_relative(input)?;
        let candidate = self.canonical.join(relative);
        let resolved = tokio::fs::canonicalize(&candidate)
            .await
            .map_err(|error| io_error("resolve", &candidate, error))?;
        self.require_contained(&resolved)?;
        Ok(resolved)
    }

    /// Resolve a path without following its final component.
    pub(crate) async fn resolve_entry(&self, input: &str) -> Result<PathBuf, RpcError> {
        let relative = validate_relative(input)?;
        if relative.as_os_str().is_empty() {
            return Ok(self.canonical.clone());
        }
        let file_name = relative
            .file_name()
            .ok_or_else(|| invalid_path("path does not name an entry"))?
            .to_owned();
        let parent = relative.parent().unwrap_or_else(|| Path::new(""));
        let parent = self.resolve_directory_components(parent, false).await?;
        Ok(parent.join(file_name))
    }

    /// Resolve the parent of a write target, optionally creating missing
    /// directories one component at a time.
    pub(crate) async fn resolve_write_target(
        &self,
        input: &str,
        create_parents: bool,
    ) -> Result<PathBuf, RpcError> {
        let relative = validate_relative(input)?;
        if relative.as_os_str().is_empty() {
            return Err(invalid_path("workspace root cannot be replaced as a file"));
        }
        let file_name = relative
            .file_name()
            .ok_or_else(|| invalid_path("path does not name a file"))?
            .to_owned();
        let parent = relative.parent().unwrap_or_else(|| Path::new(""));
        let resolved_parent = self.resolve_directory_components(parent, create_parents).await?;
        Ok(resolved_parent.join(file_name))
    }

    async fn resolve_directory_components(
        &self,
        relative: &Path,
        create_missing: bool,
    ) -> Result<PathBuf, RpcError> {
        let mut current = self.canonical.clone();
        for component in relative.components() {
            let Component::Normal(name) = component else {
                continue;
            };
            let next = current.join(name);
            match tokio::fs::symlink_metadata(&next).await {
                Ok(_) => {
                    let resolved = tokio::fs::canonicalize(&next)
                        .await
                        .map_err(|error| io_error("resolve", &next, error))?;
                    self.require_contained(&resolved)?;
                    let metadata = tokio::fs::metadata(&resolved)
                        .await
                        .map_err(|error| io_error("resolve", &resolved, error))?;
                    if !metadata.is_dir() {
                        return Err(RpcError::new(
                            "not-a-directory",
                            format!("path component is not a directory: {}", next.display()),
                        ));
                    }
                    current = resolved;
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound && create_missing => {
                    tokio::fs::create_dir(&next)
                        .await
                        .map_err(|error| io_error("create-directory", &next, error))?;
                    let resolved = tokio::fs::canonicalize(&next)
                        .await
                        .map_err(|error| io_error("resolve", &next, error))?;
                    self.require_contained(&resolved)?;
                    current = resolved;
                }
                Err(error) => return Err(io_error("resolve", &next, error)),
            }
        }
        Ok(current)
    }

    pub(crate) fn require_contained(&self, path: &Path) -> Result<(), RpcError> {
        if path == self.canonical || path.starts_with(&self.canonical) {
            return Ok(());
        }
        Err(RpcError::new("path-outside-workspace", "resolved path escapes the workspace root"))
    }
}

/// Stable descriptor for a workspace root used by file mutations on Unix.
///
/// Each path component is opened relative to this descriptor with
/// `O_NOFOLLOW`. A pathname swap can invalidate an operation, but cannot
/// redirect it through a symlink outside the opened workspace.
#[cfg(unix)]
#[derive(Clone, Debug)]
pub(crate) struct UnixWorkspaceRoot {
    directory: Arc<File>,
    display: PathBuf,
}

#[cfg(unix)]
impl UnixWorkspaceRoot {
    fn open(display: PathBuf) -> Result<Self, RpcError> {
        let name = path_cstring(&display)?;
        // SAFETY: `name` is a live NUL-terminated string and `open` does not
        // retain its pointer.
        let fd = unsafe {
            libc::open(
                name.as_ptr(),
                libc::O_RDONLY | libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW,
            )
        };
        if fd < 0 {
            return Err(io_error("open-workspace", &display, std::io::Error::last_os_error()));
        }
        // SAFETY: `open` returned a new owned descriptor.
        let directory = unsafe { File::from_raw_fd(fd) };
        Ok(Self { directory: Arc::new(directory), display })
    }

    pub(crate) fn resolve_target(
        &self,
        input: &str,
        create_parents: bool,
    ) -> Result<UnixWorkspaceTarget, RpcError> {
        let relative = validate_relative(input)?;
        if relative.as_os_str().is_empty() {
            return Err(invalid_path("workspace root cannot be replaced as a file"));
        }
        let name = relative.file_name().ok_or_else(|| invalid_path("path does not name a file"))?;
        let name = component_cstring(name)?;
        let parent_relative = relative.parent().unwrap_or_else(|| Path::new("")).to_owned();
        let parent = self.resolve_directory(&parent_relative, create_parents)?;
        Ok(UnixWorkspaceTarget {
            root: self.clone(),
            parent,
            parent_relative,
            name,
            display: self.display.join(relative),
        })
    }

    fn resolve_directory(&self, relative: &Path, create_missing: bool) -> Result<File, RpcError> {
        let mut current = self
            .directory
            .try_clone()
            .map_err(|error| io_error("open-workspace", &self.display, error))?;
        let mut display = self.display.clone();
        for component in relative.components() {
            let Component::Normal(name) = component else {
                continue;
            };
            display.push(name);
            let name = component_cstring(name)?;
            match open_directory_at(current.as_raw_fd(), &name) {
                Ok(next) => current = next,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound && create_missing => {
                    match mkdir_at(current.as_raw_fd(), &name) {
                        Ok(()) => {
                            current.sync_all().map_err(|error| {
                                io_error(
                                    "sync-directory",
                                    display.parent().unwrap_or(&display),
                                    error,
                                )
                            })?;
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                        Err(error) => return Err(io_error("create-directory", &display, error)),
                    }
                    current = open_directory_at(current.as_raw_fd(), &name)
                        .map_err(|error| directory_component_error(&display, error))?;
                }
                Err(error) => return Err(directory_component_error(&display, error)),
            }
        }
        Ok(current)
    }
}

#[cfg(unix)]
#[derive(Debug)]
pub(crate) struct UnixWorkspaceTarget {
    root: UnixWorkspaceRoot,
    parent: File,
    parent_relative: PathBuf,
    name: CString,
    display: PathBuf,
}

#[cfg(unix)]
impl UnixWorkspaceTarget {
    pub(crate) fn parent_fd(&self) -> RawFd {
        self.parent.as_raw_fd()
    }

    pub(crate) fn name(&self) -> &CStr {
        &self.name
    }

    pub(crate) fn display(&self) -> &Path {
        &self.display
    }

    pub(crate) fn parent_display(&self) -> &Path {
        self.display.parent().unwrap_or(&self.display)
    }

    pub(crate) fn sync_parent(&self) -> Result<(), RpcError> {
        self.parent
            .sync_all()
            .map_err(|error| io_error("sync-directory", self.parent_display(), error))
    }

    pub(crate) fn verify_parent_identity(&self) -> Result<(), RpcError> {
        let current = self.root.resolve_directory(&self.parent_relative, false)?;
        let expected = self
            .parent
            .metadata()
            .map_err(|error| io_error("stat-directory", self.parent_display(), error))?;
        let found = current
            .metadata()
            .map_err(|error| io_error("stat-directory", self.parent_display(), error))?;
        if expected.dev() == found.dev() && expected.ino() == found.ino() {
            return Ok(());
        }
        Err(RpcError::new(
            "path-changed",
            format!("write parent changed before commit: {}", self.parent_display().display()),
        ))
    }
}

#[cfg(unix)]
fn path_cstring(path: &Path) -> Result<CString, RpcError> {
    CString::new(path.as_os_str().as_bytes()).map_err(|_| invalid_path("path contains a NUL byte"))
}

#[cfg(unix)]
fn component_cstring(component: &std::ffi::OsStr) -> Result<CString, RpcError> {
    CString::new(component.as_bytes()).map_err(|_| invalid_path("path contains a NUL byte"))
}

#[cfg(unix)]
fn open_directory_at(parent: RawFd, name: &CStr) -> Result<File, std::io::Error> {
    // SAFETY: `name` is a live NUL-terminated string, `parent` is an open
    // directory descriptor, and `openat` does not retain either.
    let fd = unsafe {
        libc::openat(
            parent,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: `openat` returned a new owned descriptor.
    Ok(unsafe { File::from_raw_fd(fd) })
}

#[cfg(unix)]
fn mkdir_at(parent: RawFd, name: &CStr) -> Result<(), std::io::Error> {
    // SAFETY: `name` is a live NUL-terminated string, `parent` is an open
    // directory descriptor, and `mkdirat` does not retain either.
    if unsafe { libc::mkdirat(parent, name.as_ptr(), 0o777) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(unix)]
fn directory_component_error(path: &Path, error: std::io::Error) -> RpcError {
    if error.raw_os_error() == Some(libc::ELOOP) {
        return RpcError::new(
            "symlink-not-supported",
            format!("workspace mutation path contains a symlink: {}", path.display()),
        );
    }
    if error.raw_os_error() == Some(libc::ENOTDIR) {
        return RpcError::new(
            "not-a-directory",
            format!("path component is not a directory: {}", path.display()),
        );
    }
    io_error("resolve", path, error)
}

pub(crate) fn validate_relative(input: &str) -> Result<PathBuf, RpcError> {
    if input.contains('\0') {
        return Err(invalid_path("path contains a NUL byte"));
    }
    if looks_like_windows_absolute(input) {
        return Err(invalid_path("path must be workspace-relative"));
    }
    if input.len() > MAX_PROTOCOL_PATH_BYTES {
        return Err(invalid_path("path is too long"));
    }
    if input.contains('\\') {
        return Err(invalid_path("protocol paths must use forward slashes"));
    }
    let path = Path::new(input);
    if path.is_absolute() {
        return Err(invalid_path("path must be workspace-relative"));
    }

    let mut parts = Vec::<OsString>::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => parts.push(part.to_owned()),
            Component::CurDir => {}
            Component::ParentDir => {
                return Err(invalid_path("parent path components are not allowed"));
            }
            Component::RootDir | Component::Prefix(_) => {
                return Err(invalid_path("path must be workspace-relative"));
            }
        }
        if parts.len() > MAX_PROTOCOL_PATH_COMPONENTS {
            return Err(invalid_path("path has too many components"));
        }
    }
    Ok(parts.into_iter().collect())
}

pub(crate) fn normalize_protocol_path(input: &str) -> Result<String, RpcError> {
    Ok(path_to_protocol(&validate_relative(input)?))
}

pub(crate) fn join_protocol_path(parent: &str, child: &str) -> Result<String, RpcError> {
    let mut path = validate_relative(parent)?;
    if child.contains('/') || child.contains('\\') || child == "." || child == ".." {
        return Err(invalid_path("directory entry has an invalid name"));
    }
    path.push(child);
    Ok(path_to_protocol(&path))
}

fn path_to_protocol(path: &Path) -> String {
    path.components()
        .filter_map(|component| match component {
            Component::Normal(part) => Some(part.to_string_lossy().into_owned()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn looks_like_windows_absolute(input: &str) -> bool {
    let bytes = input.as_bytes();
    input.starts_with("\\\\")
        || input.starts_with("//")
        || (bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic())
}

pub(crate) fn invalid_path(message: impl Into<String>) -> RpcError {
    RpcError::new("invalid-path", message)
}

pub(crate) fn io_error(operation: &str, path: &Path, error: std::io::Error) -> RpcError {
    let code = match error.kind() {
        std::io::ErrorKind::NotFound => "not-found",
        std::io::ErrorKind::PermissionDenied => "permission-denied",
        std::io::ErrorKind::AlreadyExists => "already-exists",
        std::io::ErrorKind::InvalidInput | std::io::ErrorKind::InvalidData => "invalid-argument",
        std::io::ErrorKind::TimedOut => "deadline-exceeded",
        _ => "io-error",
    };
    RpcError::new(code, format!("{operation} {}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;

    #[test]
    fn rejects_absolute_and_parent_paths() {
        assert!(validate_relative("/etc/passwd").is_err());
        assert!(validate_relative("../secret").is_err());
        assert!(validate_relative("a/../../secret").is_err());
        assert!(validate_relative("C:\\Windows").is_err());
        assert!(validate_relative("//server/share").is_err());
        assert_eq!(normalize_protocol_path("./src/lib.rs").unwrap(), "src/lib.rs");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn rejects_symlink_escape() {
        use std::os::unix::fs::symlink;

        let root_dir = tempdir().unwrap();
        let outside = tempdir().unwrap();
        symlink(outside.path(), root_dir.path().join("outside")).unwrap();
        let root =
            WorkspaceRoot::open(WorkspaceId("test".into()), root_dir.path().to_str().unwrap())
                .await
                .unwrap();

        let error = root.resolve_existing("outside").await.unwrap_err();
        assert_eq!(error.code, "path-outside-workspace");
        let error = root.resolve_write_target("outside/new", true).await.unwrap_err();
        assert_eq!(error.code, "path-outside-workspace");
    }
}
