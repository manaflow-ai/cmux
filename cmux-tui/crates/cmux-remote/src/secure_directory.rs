//! Race-resistant creation and validation for local state and socket directories.

use std::io;
use std::path::Path;

/// Required access policy for the final directory in a secure path walk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DirectoryAccess {
    /// The effective user owns the directory and nobody else may write it.
    OwnerControlled,
    /// The effective user is the only principal with any directory access.
    /// Existing caller-owned directories are validated without mutation.
    OwnerOnly,
    /// The effective user is the only principal with any directory access,
    /// and cmux owns the final directory so it may tighten existing permissions.
    ManagedOwnerOnly,
}

/// Creates `path` without following user-controlled symlinks and verifies that
/// the resulting directory is owned by this process and cannot be replaced by
/// another user.
///
/// On Unix, every component is opened relative to the preceding directory
/// descriptor with `O_NOFOLLOW`. Missing components are created as mode `0700`.
/// An existing final directory is validated without changing its permissions
/// unless the caller explicitly selects `ManagedOwnerOnly`.
/// Root-owned symlinks in root-owned, non-writable directories are expanded
/// component by component so standard system aliases such as macOS `/var` and
/// `/tmp` remain usable without permitting user-controlled aliases.
pub fn ensure_secure_directory(path: &Path, access: DirectoryAccess) -> io::Result<()> {
    #[cfg(unix)]
    {
        unix::ensure_secure_directory(path, access)
    }
    #[cfg(not(unix))]
    {
        let _ = (path, access);
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "secure state directories require platform owner-access enforcement",
        ))
    }
}

#[cfg(unix)]
mod unix {
    use std::collections::VecDeque;
    use std::ffi::{CString, OsStr, OsString};
    use std::fs::File;
    use std::io;
    use std::mem::MaybeUninit;
    use std::os::fd::{AsRawFd, FromRawFd, RawFd};
    use std::os::unix::ffi::{OsStrExt, OsStringExt};
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    use std::path::{Component, Path};

    use super::DirectoryAccess;

    const MAX_TRUSTED_SYMLINK_EXPANSIONS: usize = 16;
    const MAX_SYMLINK_TARGET_BYTES: usize = 64 * 1024;

    pub(super) fn ensure_secure_directory(path: &Path, access: DirectoryAccess) -> io::Result<()> {
        let (absolute, mut pending) = validated_components(path)?;
        let mut directory = open_anchor(absolute)?;
        let mut trusted_symlinks = 0_usize;
        let mut final_component_created = false;
        if !pending.is_empty() {
            validate_ancestor(&directory, path)?;
        }

        while let Some(component) = pending.pop_front() {
            match open_directory_at(directory.as_raw_fd(), &component) {
                Ok(next) => {
                    validate_ancestor(&next, path)?;
                    directory = next;
                    final_component_created = false;
                }
                Err(open_error) => {
                    let status = metadata_at(directory.as_raw_fd(), &component)?;
                    if status.as_ref().is_some_and(is_symlink) {
                        trusted_symlinks = trusted_symlinks.saturating_add(1);
                        if trusted_symlinks > MAX_TRUSTED_SYMLINK_EXPANSIONS {
                            return Err(invalid_path(
                                path,
                                "contains too many trusted system symlinks",
                            ));
                        }
                        expand_trusted_symlink(
                            path,
                            &mut directory,
                            &mut pending,
                            &component,
                            status.expect("symlink status is present"),
                        )?;
                        continue;
                    }
                    if open_error.raw_os_error() != Some(libc::ENOENT) {
                        return Err(with_component_context(path, &component, open_error));
                    }
                    let created = create_directory_at(directory.as_raw_fd(), &component)?;
                    let next = open_directory_at(directory.as_raw_fd(), &component)
                        .map_err(|error| with_component_context(path, &component, error))?;
                    validate_ancestor(&next, path)?;
                    directory = next;
                    final_component_created = created;
                }
            }
        }

        validate_final(&directory, path, access, final_component_created)
    }

    fn validated_components(path: &Path) -> io::Result<(bool, VecDeque<OsString>)> {
        let mut absolute = false;
        let mut normal = VecDeque::new();
        for component in path.components() {
            match component {
                Component::RootDir => absolute = true,
                Component::CurDir => {}
                Component::Normal(component) => normal.push_back(component.to_owned()),
                Component::ParentDir => {
                    return Err(invalid_path(path, "must not contain '..' traversal"));
                }
                Component::Prefix(_) => {
                    return Err(invalid_path(path, "uses an unsupported path prefix"));
                }
            }
        }
        Ok((absolute, normal))
    }

    fn open_anchor(absolute: bool) -> io::Result<File> {
        let anchor = if absolute { Path::new("/") } else { Path::new(".") };
        let encoded = CString::new(anchor.as_os_str().as_bytes())
            .expect("Unix root and current-directory paths contain no NUL bytes");
        // SAFETY: `encoded` is live and NUL-terminated, and `open` does not
        // retain its pointer.
        let descriptor = unsafe {
            libc::open(
                encoded.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if descriptor < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `open` returned a new owned descriptor.
        Ok(unsafe { File::from_raw_fd(descriptor) })
    }

    fn open_directory_at(parent: RawFd, component: &OsStr) -> io::Result<File> {
        let encoded = component_cstring(component)?;
        // SAFETY: `encoded` is live and NUL-terminated, `parent` is an open
        // directory, and `openat` does not retain either argument.
        let descriptor = unsafe {
            libc::openat(
                parent,
                encoded.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if descriptor < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `openat` returned a new owned descriptor.
        Ok(unsafe { File::from_raw_fd(descriptor) })
    }

    fn create_directory_at(parent: RawFd, component: &OsStr) -> io::Result<bool> {
        let encoded = component_cstring(component)?;
        // SAFETY: `encoded` is live and NUL-terminated, `parent` is an open
        // directory, and `mkdirat` does not retain either argument.
        if unsafe { libc::mkdirat(parent, encoded.as_ptr(), 0o700) } == 0 {
            return Ok(true);
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::EEXIST) {
            return Ok(false);
        }
        Err(error)
    }

    fn metadata_at(parent: RawFd, component: &OsStr) -> io::Result<Option<libc::stat>> {
        let encoded = component_cstring(component)?;
        let mut status = MaybeUninit::<libc::stat>::uninit();
        // SAFETY: `status` points to writable storage, `encoded` is live and
        // NUL-terminated, and `fstatat` does not retain either pointer.
        if unsafe {
            libc::fstatat(parent, encoded.as_ptr(), status.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW)
        } == 0
        {
            // SAFETY: successful `fstatat` initialized `status`.
            return Ok(Some(unsafe { status.assume_init() }));
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ENOENT) { Ok(None) } else { Err(error) }
    }

    fn is_symlink(status: &libc::stat) -> bool {
        status.st_mode & libc::S_IFMT == libc::S_IFLNK
    }

    fn expand_trusted_symlink(
        original: &Path,
        directory: &mut File,
        pending: &mut VecDeque<OsString>,
        component: &OsStr,
        status: libc::stat,
    ) -> io::Result<()> {
        let parent = directory.metadata()?;
        if status.st_uid != 0 || parent.uid() != 0 || parent.permissions().mode() & 0o022 != 0 {
            return Err(invalid_path(
                original,
                &format!("contains symlink component {:?}", component.to_string_lossy()),
            ));
        }
        let target = read_link_at(directory.as_raw_fd(), component)?;
        let target = Path::new(&target);
        let (absolute, components) = validated_components(target)?;
        if components.is_empty() {
            return Err(invalid_path(original, "contains a symlink with an empty target"));
        }
        if absolute {
            *directory = open_anchor(true)?;
        }
        for component in components.into_iter().rev() {
            pending.push_front(component);
        }
        Ok(())
    }

    fn read_link_at(parent: RawFd, component: &OsStr) -> io::Result<OsString> {
        let encoded = component_cstring(component)?;
        let mut capacity = 256_usize;
        loop {
            let mut bytes = Vec::<u8>::with_capacity(capacity);
            // SAFETY: `bytes` has `capacity` writable bytes, `encoded` is live
            // and NUL-terminated, and `readlinkat` writes at most `capacity`.
            let length = unsafe {
                libc::readlinkat(parent, encoded.as_ptr(), bytes.as_mut_ptr().cast(), capacity)
            };
            if length < 0 {
                return Err(io::Error::last_os_error());
            }
            let length = usize::try_from(length).unwrap_or(capacity);
            if length < capacity {
                // SAFETY: successful `readlinkat` initialized `length` bytes.
                unsafe { bytes.set_len(length) };
                return Ok(OsString::from_vec(bytes));
            }
            if capacity >= MAX_SYMLINK_TARGET_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "secure directory symlink target is too long",
                ));
            }
            capacity = (capacity * 2).min(MAX_SYMLINK_TARGET_BYTES);
        }
    }

    fn validate_ancestor(directory: &File, path: &Path) -> io::Result<()> {
        let metadata = directory.metadata()?;
        let mode = metadata.permissions().mode();
        let owner = metadata.uid();
        if owner != 0 && owner != effective_uid() {
            return Err(invalid_path(
                path,
                "has an ancestor not controlled by root or the effective user",
            ));
        }
        if mode & 0o022 != 0 && mode & 0o1000 == 0 {
            return Err(invalid_path(
                path,
                "has an ancestor writable by other users without sticky-directory protection",
            ));
        }
        Ok(())
    }

    fn validate_final(
        directory: &File,
        path: &Path,
        access: DirectoryAccess,
        created: bool,
    ) -> io::Result<()> {
        let mut metadata = directory.metadata()?;
        if metadata.uid() != effective_uid() {
            return Err(invalid_path(path, "must be owned by the effective user"));
        }
        let owner_only =
            matches!(access, DirectoryAccess::OwnerOnly | DirectoryAccess::ManagedOwnerOnly);
        if owner_only {
            if metadata.permissions().mode() & 0o1000 != 0
                && metadata.permissions().mode() & 0o077 != 0
            {
                return Err(invalid_path(
                    path,
                    "is a shared sticky directory and cannot be made owner-only",
                ));
            }
            if created || access == DirectoryAccess::ManagedOwnerOnly {
                // SAFETY: `directory` is a live descriptor for the directory
                // this call created or for a directory the caller explicitly
                // declared cmux-managed. Caller-owned directories are only
                // validated below and never have their permissions changed.
                if unsafe { libc::fchmod(directory.as_raw_fd(), 0o700) } != 0 {
                    return Err(io::Error::last_os_error());
                }
                metadata = directory.metadata()?;
            }
        }
        if metadata.permissions().mode() & 0o022 != 0 {
            return Err(invalid_path(path, "must not be writable by group or other users"));
        }
        if owner_only && metadata.permissions().mode() & 0o077 != 0 {
            return Err(invalid_path(path, "must not be accessible by group or other users"));
        }
        Ok(())
    }

    fn effective_uid() -> u32 {
        // SAFETY: `geteuid` has no preconditions.
        unsafe { libc::geteuid() }
    }

    fn component_cstring(component: &OsStr) -> io::Result<CString> {
        CString::new(component.as_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path contains a NUL byte"))
    }

    fn invalid_path(path: &Path, reason: &str) -> io::Error {
        io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("secure directory {} {reason}", path.display()),
        )
    }

    fn with_component_context(path: &Path, component: &OsStr, error: io::Error) -> io::Error {
        io::Error::new(
            error.kind(),
            format!(
                "could not open component {:?} of secure directory {}: {error}",
                component.to_string_lossy(),
                path.display()
            ),
        )
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::fs;
    use std::os::unix::fs::{PermissionsExt, symlink};

    use super::{DirectoryAccess, ensure_secure_directory};

    #[test]
    fn creates_nested_owner_controlled_directories_through_ordinary_ancestors() {
        let directory = tempfile::tempdir().unwrap();
        let nested = directory.path().join("one/two/three");

        ensure_secure_directory(&nested, DirectoryAccess::OwnerControlled).unwrap();

        assert!(nested.is_dir());
        assert_eq!(fs::metadata(nested).unwrap().permissions().mode() & 0o777, 0o700);
    }

    #[test]
    fn rejects_intermediate_symlinks_before_creating_descendants() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target");
        let alias = directory.path().join("alias");
        fs::create_dir(&target).unwrap();
        symlink(&target, &alias).unwrap();

        let result =
            ensure_secure_directory(&alias.join("missing"), DirectoryAccess::OwnerControlled);

        assert!(result.is_err());
        assert!(!target.join("missing").exists());
    }

    #[test]
    fn rejects_parent_traversal_before_creating_any_component() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("created/../escaped");

        let result = ensure_secure_directory(&path, DirectoryAccess::OwnerControlled);

        assert!(result.is_err());
        assert!(!directory.path().join("created").exists());
    }

    #[test]
    fn supports_relative_paths_without_parent_traversal() {
        let current = std::env::current_dir().unwrap();
        let directory = tempfile::tempdir_in(&current).unwrap();
        let relative = directory.path().strip_prefix(&current).unwrap().join("relative-control");

        ensure_secure_directory(&relative, DirectoryAccess::OwnerControlled).unwrap();

        assert!(current.join(relative).is_dir());
    }

    #[test]
    fn owner_only_policy_rejects_an_existing_non_private_directory_without_changing_it() {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o755)).unwrap();

        let error = ensure_secure_directory(directory.path(), DirectoryAccess::OwnerOnly)
            .expect_err("existing caller-owned directory was silently chmodded");

        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
        assert_eq!(fs::metadata(directory.path()).unwrap().permissions().mode() & 0o777, 0o755);
    }

    #[test]
    fn owner_only_policy_creates_a_private_final_directory() {
        let directory = tempfile::tempdir().unwrap();
        let private = directory.path().join("private");

        ensure_secure_directory(&private, DirectoryAccess::OwnerOnly).unwrap();

        assert_eq!(fs::metadata(private).unwrap().permissions().mode() & 0o777, 0o700);
    }

    #[test]
    fn managed_owner_only_policy_tightens_an_existing_managed_directory() {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o755)).unwrap();

        ensure_secure_directory(directory.path(), DirectoryAccess::ManagedOwnerOnly).unwrap();

        assert_eq!(fs::metadata(directory.path()).unwrap().permissions().mode() & 0o777, 0o700);
    }
}
