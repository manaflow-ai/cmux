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
    #[cfg(windows)]
    {
        windows::ensure_secure_directory(path, access)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = (path, access);
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "secure state directories require platform owner-access enforcement",
        ))
    }
}

#[cfg(windows)]
mod windows {
    use std::ffi::{OsString, c_void};
    use std::fs;
    use std::io;
    use std::mem::size_of;
    use std::os::windows::ffi::{OsStrExt, OsStringExt};
    use std::path::{Component, Path, PathBuf};

    use windows_sys::Win32::Foundation::{
        CloseHandle, ERROR_INSUFFICIENT_BUFFER, GENERIC_ALL, GENERIC_WRITE, HANDLE,
        INVALID_HANDLE_VALUE, LocalFree,
    };
    use windows_sys::Win32::Security::Authorization::{
        GetNamedSecurityInfoW, SE_FILE_OBJECT, SetNamedSecurityInfoW,
    };
    use windows_sys::Win32::Security::{
        ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, ACL_REVISION, AddAccessAllowedAceEx,
        CONTAINER_INHERIT_ACE, DACL_SECURITY_INFORMATION, EqualSid, GetAce, GetLengthSid,
        GetTokenInformation, InitializeAcl, OBJECT_INHERIT_ACE, OWNER_SECURITY_INFORMATION,
        PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID, TOKEN_QUERY, TOKEN_USER,
        TokenUser,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        BY_HANDLE_FILE_INFORMATION, CreateFileW, DELETE, FILE_ALL_ACCESS, FILE_APPEND_DATA,
        FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT, FILE_DELETE_CHILD,
        FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_WRITE_ATTRIBUTES, FILE_WRITE_DATA, FILE_WRITE_EA,
        GetFileInformationByHandle, GetLongPathNameW, OPEN_EXISTING, WRITE_DAC, WRITE_OWNER,
    };
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    use super::DirectoryAccess;

    pub(super) fn ensure_secure_directory(path: &Path, access: DirectoryAccess) -> io::Result<()> {
        validate_path(path)?;
        let created = create_local_app_data_path(path)?;
        if created || matches!(access, DirectoryAccess::ManagedOwnerOnly) {
            restrict_to_current_user(path)?;
        } else {
            validate_current_user_access(path, access)?;
        }
        Ok(())
    }

    fn validate_path(path: &Path) -> io::Result<()> {
        if !path.is_absolute() {
            return Err(invalid_path(path, "must be absolute"));
        }
        if path.components().any(|component| matches!(component, Component::ParentDir)) {
            return Err(invalid_path(path, "must not contain '..' traversal"));
        }
        Ok(())
    }

    fn create_local_app_data_path(path: &Path) -> io::Result<bool> {
        let local_app_data = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .ok_or_else(|| invalid_path(path, "requires LOCALAPPDATA"))?;
        validate_path(&local_app_data)?;
        let trusted_root = local_app_data.canonicalize()?;
        // Environment variables can use an 8.3 alias such as RUNNER~1 while
        // LOCALAPPDATA uses the long spelling. Expand only existing names;
        // unlike canonicalize(), GetLongPathNameW does not resolve junctions.
        let long_path = long_path_with_missing_suffix(path)?;
        let long_local_app_data = long_path_with_missing_suffix(&local_app_data)?;
        let relative = relative_components_case_insensitive(path, &local_app_data)
            .or_else(|| relative_components_case_insensitive(path, &trusted_root))
            .or_else(|| relative_components_case_insensitive(&long_path, &long_local_app_data))
            .or_else(|| relative_components_case_insensitive(&long_path, &trusted_root))
            .ok_or_else(|| invalid_path(path, "must stay within LOCALAPPDATA"))?;
        let mut current = trusted_root.clone();
        let mut open_directories = vec![open_directory_no_follow(&trusted_root, path)?];
        let component_count = relative.len();
        let mut final_created = false;
        for (index, component) in relative.into_iter().enumerate() {
            current.push(component);
            let created = match fs::create_dir(&current) {
                Ok(()) => true,
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => false,
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    return Err(invalid_path(path, "a validated parent directory disappeared"));
                }
                Err(error) => return Err(error),
            };
            if created && index + 1 == component_count {
                final_created = true;
            }
            open_directories.push(open_directory_no_follow(&current, path)?);
        }
        Ok(final_created)
    }

    fn long_path_with_missing_suffix(path: &Path) -> io::Result<PathBuf> {
        let mut existing = path.to_path_buf();
        let mut missing = Vec::new();
        loop {
            match fs::symlink_metadata(&existing) {
                Ok(_) => break,
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    let component = existing
                        .file_name()
                        .ok_or_else(|| invalid_path(path, "has no existing Windows path prefix"))?;
                    missing.push(PathBuf::from(component));
                    existing = existing
                        .parent()
                        .ok_or_else(|| invalid_path(path, "has no existing Windows path prefix"))?
                        .to_path_buf();
                }
                Err(error) => return Err(error),
            }
        }

        let mut long = get_long_path_name(&existing)?;
        for component in missing.into_iter().rev() {
            long.push(component);
        }
        Ok(long)
    }

    fn get_long_path_name(path: &Path) -> io::Result<PathBuf> {
        let encoded = path.as_os_str().encode_wide().chain(Some(0)).collect::<Vec<_>>();
        // SAFETY: `encoded` is live and NUL-terminated. The null output query
        // only asks Windows for the required buffer size.
        let required = unsafe { GetLongPathNameW(encoded.as_ptr(), std::ptr::null_mut(), 0) };
        if required == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut buffer = vec![0_u16; required as usize];
        // SAFETY: both buffers remain live and the output buffer has the size
        // returned by the query above.
        let written =
            unsafe { GetLongPathNameW(encoded.as_ptr(), buffer.as_mut_ptr(), buffer.len() as u32) };
        if written == 0 {
            return Err(io::Error::last_os_error());
        }
        if written as usize >= buffer.len() {
            return Err(io::Error::other("Windows long-path expansion changed during validation"));
        }
        Ok(PathBuf::from(OsString::from_wide(&buffer[..written as usize])))
    }

    struct OwnedSecurityDescriptor(PSECURITY_DESCRIPTOR);

    impl Drop for OwnedSecurityDescriptor {
        fn drop(&mut self) {
            // SAFETY: GetNamedSecurityInfoW allocated this descriptor with
            // LocalAlloc and ownership was transferred to this wrapper.
            unsafe {
                LocalFree(self.0);
            }
        }
    }

    fn validate_current_user_access(path: &Path, access: DirectoryAccess) -> io::Result<()> {
        let mut encoded = path.as_os_str().encode_wide().chain(Some(0)).collect::<Vec<_>>();
        let mut owner: PSID = std::ptr::null_mut();
        let mut dacl: *mut ACL = std::ptr::null_mut();
        let mut descriptor: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
        // SAFETY: all output pointers are writable and `encoded` is a live,
        // NUL-terminated path for the duration of the synchronous call.
        let status = unsafe {
            GetNamedSecurityInfoW(
                encoded.as_mut_ptr(),
                SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                &mut owner,
                std::ptr::null_mut(),
                &mut dacl,
                std::ptr::null_mut(),
                &mut descriptor,
            )
        };
        if status != 0 {
            return Err(io::Error::from_raw_os_error(status as i32));
        }
        if descriptor.is_null() {
            return Err(invalid_path(path, "has no security descriptor"));
        }
        let _descriptor = OwnedSecurityDescriptor(descriptor);
        if owner.is_null() || dacl.is_null() {
            return Err(invalid_path(path, "has no owner-only access control list"));
        }

        let current_user = current_user_sid()?;
        let current_sid = current_user.as_ptr().cast_mut().cast::<c_void>();
        // SAFETY: both pointers refer to live SIDs.
        if unsafe { EqualSid(owner, current_sid) } == 0 {
            return Err(invalid_path(path, "is not owned by the current user"));
        }

        // A non-owner may not have any allowed access for OwnerOnly, or any
        // write/delete/control access for OwnerControlled.
        const ACCESS_ALLOWED_ACE_TYPE: u8 = 0;
        const ACCESS_ALLOWED_COMPOUND_ACE_TYPE: u8 = 4;
        const ACCESS_ALLOWED_OBJECT_ACE_TYPE: u8 = 5;
        const ACCESS_ALLOWED_CALLBACK_ACE_TYPE: u8 = 9;
        const ACCESS_ALLOWED_CALLBACK_OBJECT_ACE_TYPE: u8 = 11;
        let forbidden_write = GENERIC_ALL
            | GENERIC_WRITE
            | FILE_WRITE_DATA
            | FILE_APPEND_DATA
            | FILE_WRITE_EA
            | FILE_WRITE_ATTRIBUTES
            | FILE_DELETE_CHILD
            | DELETE
            | WRITE_DAC
            | WRITE_OWNER;
        // SAFETY: `dacl` belongs to the live descriptor. Each successful
        // GetAce call returns an ACE within that descriptor.
        let ace_count = unsafe { (*dacl).AceCount };
        for index in 0..u32::from(ace_count) {
            let mut raw_ace: *mut c_void = std::ptr::null_mut();
            if unsafe { GetAce(dacl, index, &mut raw_ace) } == 0 {
                return Err(io::Error::last_os_error());
            }
            if raw_ace.is_null() {
                return Err(invalid_path(path, "contains an invalid access rule"));
            }
            let header = unsafe { &*raw_ace.cast::<ACE_HEADER>() };
            match header.AceType {
                ACCESS_ALLOWED_ACE_TYPE => {
                    if usize::from(header.AceSize) < size_of::<ACCESS_ALLOWED_ACE>() {
                        return Err(invalid_path(path, "contains a truncated access rule"));
                    }
                    let allowed = unsafe { &*raw_ace.cast::<ACCESS_ALLOWED_ACE>() };
                    let sid = std::ptr::addr_of!(allowed.SidStart).cast_mut().cast::<c_void>();
                    let belongs_to_owner = unsafe { EqualSid(sid, current_sid) } != 0;
                    let forbidden = match access {
                        DirectoryAccess::OwnerControlled => forbidden_write,
                        DirectoryAccess::OwnerOnly | DirectoryAccess::ManagedOwnerOnly => u32::MAX,
                    };
                    if !belongs_to_owner && allowed.Mask & forbidden != 0 {
                        return Err(invalid_path(path, "grants forbidden access to another user"));
                    }
                }
                ACCESS_ALLOWED_COMPOUND_ACE_TYPE
                | ACCESS_ALLOWED_OBJECT_ACE_TYPE
                | ACCESS_ALLOWED_CALLBACK_ACE_TYPE
                | ACCESS_ALLOWED_CALLBACK_OBJECT_ACE_TYPE => {
                    return Err(invalid_path(path, "contains an unsupported allow rule"));
                }
                _ => {}
            }
        }
        Ok(())
    }

    struct DirectoryHandle(HANDLE);

    impl Drop for DirectoryHandle {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }

    fn open_directory_no_follow(
        directory: &Path,
        requested_path: &Path,
    ) -> io::Result<DirectoryHandle> {
        let mut wide = directory.as_os_str().encode_wide().collect::<Vec<_>>();
        wide.push(0);
        let handle = unsafe {
            CreateFileW(
                wide.as_ptr(),
                FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                std::ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                std::ptr::null_mut(),
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        let handle = DirectoryHandle(handle);
        let mut information = unsafe { std::mem::zeroed::<BY_HANDLE_FILE_INFORMATION>() };
        if unsafe { GetFileInformationByHandle(handle.0, &mut information) } == 0 {
            return Err(io::Error::last_os_error());
        }
        if information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(invalid_path(requested_path, "contains a reparse-point component"));
        }
        if information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0 {
            return Err(invalid_path(requested_path, "contains a non-directory component"));
        }
        Ok(handle)
    }

    fn relative_components_case_insensitive(path: &Path, root: &Path) -> Option<Vec<PathBuf>> {
        let path_components = path.components().collect::<Vec<_>>();
        let root_components = root.components().collect::<Vec<_>>();
        if path_components.len() < root_components.len()
            || !root_components.iter().zip(&path_components).all(|(expected, actual)| {
                actual
                    .as_os_str()
                    .to_string_lossy()
                    .eq_ignore_ascii_case(&expected.as_os_str().to_string_lossy())
            })
        {
            return None;
        }
        path_components[root_components.len()..]
            .iter()
            .map(|component| match component {
                Component::Normal(value) => Some(PathBuf::from(value)),
                _ => None,
            })
            .collect()
    }

    fn restrict_to_current_user(path: &Path) -> io::Result<()> {
        let sid = current_user_sid()?;
        let sid = sid.as_ptr().cast_mut().cast::<c_void>();
        // SAFETY: `sid` points into the live SID buffer.
        let sid_length = unsafe { GetLengthSid(sid) };
        if sid_length == 0 {
            return Err(io::Error::last_os_error());
        }
        let acl_bytes = size_of::<ACL>()
            .checked_add(size_of::<ACCESS_ALLOWED_ACE>() - size_of::<u32>())
            .and_then(|size| size.checked_add(sid_length as usize))
            .ok_or_else(|| io::Error::other("Windows ACL size overflow"))?;
        let mut acl_storage = vec![0_u32; acl_bytes.div_ceil(size_of::<u32>())];
        let acl = acl_storage.as_mut_ptr().cast::<ACL>();
        // SAFETY: `acl_storage` is aligned, writable, and at least `acl_bytes`.
        if unsafe { InitializeAcl(acl, acl_bytes as u32, ACL_REVISION) } == 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `acl` is initialized and has room for this ACE; `sid` stays
        // live until SetNamedSecurityInfoW returns.
        if unsafe {
            AddAccessAllowedAceEx(
                acl,
                ACL_REVISION,
                OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE,
                FILE_ALL_ACCESS,
                sid,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        let mut encoded = path.as_os_str().encode_wide().chain(Some(0)).collect::<Vec<_>>();
        // SAFETY: `encoded` is a mutable NUL-terminated path, and `sid` and
        // `acl` remain live for the duration of the synchronous call.
        let status = unsafe {
            SetNamedSecurityInfoW(
                encoded.as_mut_ptr(),
                SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION
                    | DACL_SECURITY_INFORMATION
                    | PROTECTED_DACL_SECURITY_INFORMATION,
                sid,
                std::ptr::null_mut::<c_void>() as PSID,
                acl,
                std::ptr::null(),
            )
        };
        if status == 0 { Ok(()) } else { Err(io::Error::from_raw_os_error(status as i32)) }
    }

    fn current_user_sid() -> io::Result<Vec<u32>> {
        let token = current_process_token()?;
        let mut required = 0_u32;
        // SAFETY: `token` is valid and the null-buffer query writes only the
        // required byte count.
        let queried = unsafe {
            GetTokenInformation(token.0, TokenUser, std::ptr::null_mut(), 0, &mut required)
        };
        if queried != 0
            || io::Error::last_os_error().raw_os_error() != Some(ERROR_INSUFFICIENT_BUFFER as i32)
        {
            return Err(io::Error::last_os_error());
        }
        let mut token_user = vec![0_u64; usize::try_from(required).unwrap_or(0).div_ceil(8)];
        // SAFETY: the aligned buffer contains at least `required` writable
        // bytes and `token` remains open for this call.
        if unsafe {
            GetTokenInformation(
                token.0,
                TokenUser,
                token_user.as_mut_ptr().cast(),
                required,
                &mut required,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: successful TokenUser lookup initialized a TOKEN_USER at the
        // beginning of the aligned buffer.
        let sid = unsafe { (*(token_user.as_ptr().cast::<TOKEN_USER>())).User.Sid };
        // SAFETY: `sid` points into the live token information buffer.
        let sid_length = unsafe { GetLengthSid(sid) };
        if sid_length == 0 {
            return Err(io::Error::last_os_error());
        }
        let sid_bytes = sid_length as usize;
        let mut owned = vec![0_u32; sid_bytes.div_ceil(size_of::<u32>())];
        // SAFETY: both SID pointers are valid for `sid_length` bytes.
        unsafe {
            std::ptr::copy_nonoverlapping(
                sid.cast::<u8>(),
                owned.as_mut_ptr().cast::<u8>(),
                sid_bytes,
            );
        }
        Ok(owned)
    }

    struct OwnedHandle(HANDLE);

    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            // SAFETY: this wrapper owns the real token handle.
            unsafe { CloseHandle(self.0) };
        }
    }

    fn current_process_token() -> io::Result<OwnedHandle> {
        let mut token = std::ptr::null_mut();
        // SAFETY: `token` is writable and GetCurrentProcess returns the
        // current process pseudo-handle.
        if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(OwnedHandle(token))
        }
    }

    fn invalid_path(path: &Path, reason: &str) -> io::Error {
        io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("insecure state directory {}: {reason}", path.display()),
        )
    }
}

#[cfg(all(test, windows))]
mod windows_tests {
    use std::ffi::OsString;
    use std::fs;
    use std::io;
    use std::os::windows::ffi::{OsStrExt, OsStringExt};
    use std::path::PathBuf;
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::{DirectoryAccess, ensure_secure_directory};
    use windows_sys::Win32::Storage::FileSystem::GetShortPathNameW;

    fn short_path(path: &std::path::Path) -> PathBuf {
        let encoded = path.as_os_str().encode_wide().chain(Some(0)).collect::<Vec<_>>();
        let required = unsafe { GetShortPathNameW(encoded.as_ptr(), std::ptr::null_mut(), 0) };
        assert!(required > 0, "short-path size query failed: {}", io::Error::last_os_error());
        let mut buffer = vec![0_u16; required as usize];
        let written = unsafe {
            GetShortPathNameW(encoded.as_ptr(), buffer.as_mut_ptr(), buffer.len() as u32)
        };
        assert!(written > 0 && (written as usize) < buffer.len());
        PathBuf::from(OsString::from_wide(&buffer[..written as usize]))
    }

    #[test]
    fn rejects_an_outside_root_before_creating_it() {
        let local_app_data = PathBuf::from(std::env::var_os("LOCALAPPDATA").unwrap());
        let outside = local_app_data.parent().unwrap().join(format!(
            "cmux-outside-root-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));

        let result = ensure_secure_directory(&outside, DirectoryAccess::ManagedOwnerOnly);

        assert!(result.is_err());
        assert!(!outside.exists(), "an invalid state path created an outside-root directory");
    }

    #[test]
    fn newly_created_directory_passes_owner_only_validation() {
        let local_app_data = PathBuf::from(std::env::var_os("LOCALAPPDATA").unwrap());
        let directory = local_app_data.join(format!(
            "cmux-secure-owner-only-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));

        ensure_secure_directory(&directory, DirectoryAccess::OwnerControlled).unwrap();
        ensure_secure_directory(&directory, DirectoryAccess::OwnerOnly).unwrap();

        fs::remove_dir(&directory).unwrap();
    }

    #[test]
    fn accepts_short_path_alias_within_local_app_data() {
        let temp = std::env::temp_dir();
        let short_temp = short_path(&temp);
        let directory = short_temp.join(format!(
            "cmux-secure-short-path-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));

        ensure_secure_directory(&directory, DirectoryAccess::ManagedOwnerOnly).unwrap();

        fs::remove_dir(&directory).unwrap();
    }

    #[test]
    fn rejects_a_junction_without_creating_through_it() {
        let local_app_data = PathBuf::from(std::env::var_os("LOCALAPPDATA").unwrap());
        let suffix = format!(
            "{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        );
        let base = local_app_data.join(format!("cmux-secure-junction-{suffix}"));
        ensure_secure_directory(&base, DirectoryAccess::OwnerControlled).unwrap();
        let outside =
            local_app_data.parent().unwrap().join(format!("cmux-junction-target-{suffix}"));
        fs::create_dir(&outside).unwrap();
        let junction = base.join("redirect");
        let output = Command::new("cmd.exe")
            .args(["/D", "/C", "mklink", "/J"])
            .arg(&junction)
            .arg(&outside)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "mklink failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
        let through_junction = junction.join("created");

        let result = ensure_secure_directory(&through_junction, DirectoryAccess::OwnerControlled);
        let escaped = outside.join("created").exists();
        fs::remove_dir(&junction).unwrap();
        fs::remove_dir(&base).unwrap();
        fs::remove_dir(&outside).unwrap();

        assert!(result.is_err());
        assert!(!escaped, "a rejected junction created a directory outside LOCALAPPDATA");
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
