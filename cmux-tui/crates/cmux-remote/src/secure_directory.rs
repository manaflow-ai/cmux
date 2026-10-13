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

/// Creates `path` and verifies that the resulting directory is owned by this
/// process and cannot be replaced by another user under its platform policy.
///
/// On Unix outside iOS, every component is opened relative to the preceding directory
/// descriptor with `O_NOFOLLOW`. Missing components are created as mode `0700`.
/// An existing final directory is validated without changing its permissions
/// unless the caller explicitly selects `ManagedOwnerOnly`.
/// Root-owned symlinks in root-owned, non-writable directories are expanded
/// component by component so standard system aliases such as macOS `/var` and
/// `/tmp` remain usable without permitting user-controlled aliases.
/// On iOS the sandbox protects ancestors, which the app may not open. The
/// final directory is opened directly without following a final symlink and
/// receives the same ownership and permission checks.
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
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
    use std::path::{Component, Path, PathBuf};

    use super::DirectoryAccess;

    const MAX_TRUSTED_SYMLINK_EXPANSIONS: usize = 16;
    const MAX_SYMLINK_TARGET_BYTES: usize = 64 * 1024;

    /// Whether the directories above the final one are checked for other
    /// users' write access.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub(super) enum AncestorPolicy {
        /// Every ancestor must be root- or owner-controlled and not writable
        /// by others without the sticky bit. Any ancestor another user can
        /// rename or replace defeats the final directory's protection.
        Enforce,
        /// Ancestors are not inspected. Only the final directory is validated.
        TrustSandbox,
    }

    /// iOS runs every app in its own sandbox container; no other user can
    /// reach, rename, or replace anything above the app's directories, so the
    /// ancestor walk adds nothing there. Physical devices deny opening global
    /// ancestors such as /var, and the Simulator's per-device `data` directory
    /// can be mode 0775. The final directory's ownership and access policy are
    /// still enforced. Everywhere else the walk is the guarantee.
    pub(super) fn ancestor_policy() -> AncestorPolicy {
        #[cfg(target_os = "ios")]
        {
            AncestorPolicy::TrustSandbox
        }
        #[cfg(not(target_os = "ios"))]
        {
            AncestorPolicy::Enforce
        }
    }

    pub(super) fn ensure_secure_directory(path: &Path, access: DirectoryAccess) -> io::Result<()> {
        ensure_secure_directory_with_policy(path, access, ancestor_policy())
    }

    pub(super) fn ensure_secure_directory_with_policy(
        path: &Path,
        access: DirectoryAccess,
        policy: AncestorPolicy,
    ) -> io::Result<()> {
        let (absolute, mut pending) = validated_components(path)?;
        if policy == AncestorPolicy::TrustSandbox {
            // A trailing slash or '/.' must not turn a final symlink into an
            // intermediate component and bypass O_NOFOLLOW.
            let mut normalized = PathBuf::new();
            if absolute {
                normalized.push("/");
            }
            for component in pending {
                normalized.push(component);
            }
            if normalized.as_os_str().is_empty() {
                normalized.push(".");
            }
            return ensure_sandbox_directory(&normalized, access);
        }
        let mut directory = open_anchor(absolute)?;
        let mut trusted_symlinks = 0_usize;
        let mut final_component_created = false;
        // The directory being checked, for an error that names it (cx-hgyq).
        let mut walked = PathBuf::from(if absolute { "/" } else { "." });
        if !pending.is_empty() {
            validate_ancestor(&directory, path, &walked, policy)?;
        }

        while let Some(component) = pending.pop_front() {
            match open_directory_at(directory.as_raw_fd(), &component) {
                Ok(next) => {
                    walked.push(&component);
                    validate_ancestor(&next, path, &walked, policy)?;
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
                        let absolute_target = expand_trusted_symlink(
                            path,
                            &mut directory,
                            &mut pending,
                            &component,
                            status.expect("symlink status is present"),
                        )?;
                        // The walk now follows the target: from the root for
                        // an absolute one, else from the symlink's directory.
                        if absolute_target {
                            walked = PathBuf::from("/");
                        }
                        continue;
                    }
                    if open_error.raw_os_error() != Some(libc::ENOENT) {
                        return Err(with_component_context(path, &component, open_error));
                    }
                    let created = create_directory_at(directory.as_raw_fd(), &component)?;
                    let next = open_directory_at(directory.as_raw_fd(), &component)
                        .map_err(|error| with_component_context(path, &component, error))?;
                    walked.push(&component);
                    validate_ancestor(&next, path, &walked, policy)?;
                    directory = next;
                    final_component_created = created;
                }
            }
        }

        validate_final(&directory, path, access, final_component_created)
    }

    fn ensure_sandbox_directory(path: &Path, access: DirectoryAccess) -> io::Result<()> {
        // Let the kernel traverse sandbox-protected ancestors instead of
        // opening them for reading. O_NOFOLLOW still protects the final node;
        // validation and any permission tightening use that owned descriptor.
        let (directory, created) = match open_directory_at(libc::AT_FDCWD, path.as_os_str()) {
            Ok(directory) => (directory, false),
            Err(error) if error.raw_os_error() == Some(libc::ENOENT) => {
                if let Some(parent) = path.parent().filter(|parent| !parent.as_os_str().is_empty())
                {
                    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent)?;
                }
                let created = create_directory_at(libc::AT_FDCWD, path.as_os_str())?;
                let directory = open_directory_at(libc::AT_FDCWD, path.as_os_str())?;
                (directory, created)
            }
            Err(error) => return Err(error),
        };
        validate_final(&directory, path, access, created)
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
    ) -> io::Result<bool> {
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
        Ok(absolute)
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

    pub(super) fn validate_ancestor(
        directory: &File,
        path: &Path,
        ancestor: &Path,
        policy: AncestorPolicy,
    ) -> io::Result<()> {
        if policy == AncestorPolicy::TrustSandbox {
            return Ok(());
        }
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
            // The user-private-group rule (OpenSSH's user-group-modes, as
            // Debian and Ubuntu ship it): a directory of the effective user
            // that only its own private group may write is the user's alone.
            // Ubuntu's umask 0002 makes ~/.local 775 (cx-hgyq).
            let why = if mode & 0o002 != 0 {
                "it is writable by every user".to_owned()
            } else if owner == 0 || owner != effective_uid() {
                "it is owned by root and writable by its group".to_owned()
            } else {
                match private_group_problem(metadata.gid()) {
                    None => return Ok(()),
                    Some(problem) => problem,
                }
            };
            return Err(invalid_path(
                path,
                &format!(
                    "has an ancestor {} (mode {:04o}) writable by other users without sticky-directory protection: {why}",
                    ancestor.display(),
                    mode & 0o7777
                ),
            ));
        }
        Ok(())
    }

    /// Why group `gid` is not the effective user's LOCAL private group, or
    /// None when it is. Only the local files count, so a directory-service
    /// group (LDAP, sssd, AD "Domain Users") never passes (cx-hgyq review):
    /// /etc/passwd has the user's line with the same name and primary gid
    /// the system reports, /etc/group names that gid after the user with no
    /// member but the user, and no other /etc/passwd line has the gid. NIS
    /// compat lines (`+`, `-`), an unparsable line, or a read error refuse.
    fn private_group_problem(gid: u32) -> Option<String> {
        let uid = effective_uid();
        let Some((user, primary)) = passwd_name_and_gid(uid) else {
            return Some("the effective user has no account entry".to_owned());
        };
        if gid != primary {
            return Some(format!("its group {gid} is not your primary group {primary}"));
        }
        let (Ok(passwd), Ok(groups)) =
            (std::fs::read_to_string("/etc/passwd"), std::fs::read_to_string("/etc/group"))
        else {
            return Some("/etc/passwd or /etc/group cannot be read".to_owned());
        };
        let passwd = match local_entries(&passwd, "/etc/passwd") {
            Ok(entries) => entries,
            Err(problem) => return Some(problem),
        };
        let groups = match local_entries(&groups, "/etc/group") {
            Ok(entries) => entries,
            Err(problem) => return Some(problem),
        };
        let mut own_line = false;
        for fields in &passwd {
            let (Some(name), Some(line_uid), Some(line_gid)) =
                (fields.first(), fields.get(2), fields.get(3))
            else {
                return Some("/etc/passwd has a line without uid and gid fields".to_owned());
            };
            let (Ok(line_uid), Ok(line_gid)) = (line_uid.parse::<u32>(), line_gid.parse::<u32>())
            else {
                return Some("/etc/passwd has a line with an unparsable uid or gid".to_owned());
            };
            if line_uid == uid && *name == user && line_gid == gid {
                own_line = true;
            } else if line_gid == gid {
                return Some(format!("another account has group {gid} as its primary group"));
            }
        }
        if !own_line {
            return Some(format!("{user} has no local /etc/passwd line with group {gid}"));
        }
        let mut own_group = false;
        for fields in &groups {
            let (Some(name), Some(line_gid)) = (fields.first(), fields.get(2)) else {
                return Some("/etc/group has a line without a gid field".to_owned());
            };
            let Ok(line_gid) = line_gid.parse::<u32>() else {
                return Some("/etc/group has a line with an unparsable gid".to_owned());
            };
            if line_gid != gid {
                continue;
            }
            let members = fields.get(3).copied().unwrap_or_default();
            if *name != user
                || members.split(',').any(|member| !member.is_empty() && member != user)
            {
                return Some(format!("group {gid} is not {user}'s private group"));
            }
            own_group = true;
        }
        if !own_group {
            return Some(format!("group {gid} has no local /etc/group line"));
        }
        None
    }

    /// The colon-separated fields of every entry line of a local account
    /// file; Err for a NIS compat line (`+...`, `-...`), which would pull in
    /// accounts this check cannot see.
    fn local_entries<'a>(text: &'a str, file: &str) -> Result<Vec<Vec<&'a str>>, String> {
        let mut entries = Vec::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if line.starts_with('+') || line.starts_with('-') {
                return Err(format!("{file} has NIS compat entries"));
            }
            entries.push(line.split(':').collect());
        }
        Ok(entries)
    }

    /// The account name and primary gid that the system reports for `uid`
    /// (`getpwuid_r`).
    fn passwd_name_and_gid(uid: u32) -> Option<(String, u32)> {
        let mut buffer = vec![0_u8; 16 * 1024];
        let mut entry = MaybeUninit::<libc::passwd>::uninit();
        let mut result: *mut libc::passwd = std::ptr::null_mut();
        // SAFETY: every pointer is valid for the call; the buffer outlives
        // the reads of the entry's strings below.
        let status = unsafe {
            libc::getpwuid_r(
                uid,
                entry.as_mut_ptr(),
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut result,
            )
        };
        if status != 0 || result.is_null() {
            return None;
        }
        // SAFETY: getpwuid_r succeeded, so the entry is initialized and a
        // non-NULL name is a NUL-terminated string inside `buffer`.
        unsafe {
            let entry = entry.assume_init();
            if entry.pw_name.is_null() {
                return None;
            }
            Some((
                std::ffi::CStr::from_ptr(entry.pw_name).to_string_lossy().into_owned(),
                entry.pw_gid,
            ))
        }
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
