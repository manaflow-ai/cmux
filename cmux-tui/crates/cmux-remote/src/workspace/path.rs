use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use cmux_remote_protocol::{RpcError, WorkspaceId};
use tokio::sync::Mutex;

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
        Ok(Arc::new(Self { id, canonical, mutation: Mutex::new(()) }))
    }

    pub(crate) fn display_root(&self) -> String {
        self.canonical.to_string_lossy().into_owned()
    }

    pub(crate) fn canonical_root(&self) -> &Path {
        &self.canonical
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
