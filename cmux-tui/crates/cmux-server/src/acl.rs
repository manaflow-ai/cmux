//! macOS extended ACLs (`ACL_TYPE_EXTENDED`, what `ls -le` shows). An
//! allow entry can let another account write a folder or file whose mode
//! bits say 0700 or 0600, so the mode checks alone miss it (Codex R-004).
//! Only allow entries that grant a write-class permission count: deny
//! entries (macOS puts `group:everyone deny delete` on home folders) only
//! take access away. An allow entry is counted whoever it names: one that
//! names this account adds nothing the mode bits do not already give.
//! On other systems there are no such entries here, and both calls are
//! no-ops.

use std::io;
use std::path::Path;

/// True when `path` (not followed if it is a symlink) has an ACL entry
/// that allows writing, adding, deleting, or changing its permissions or
/// owner.
pub fn write_grants(path: &Path) -> io::Result<bool> {
    imp::write_grants(path)
}

/// [`write_grants`] for the open file or folder `file`: the ACL of what
/// the descriptor reaches, wherever a symlink on its path pointed.
pub fn fd_write_grants(file: &std::fs::File) -> io::Result<bool> {
    imp::fd_write_grants(file)
}

/// Removes the write-class allow entries from the ACL of the open file
/// or folder `file`, keeping every other entry. True when it removed one.
pub fn strip_write_grants(file: &std::fs::File) -> io::Result<bool> {
    imp::strip_write_grants(file)
}

/// True when the open file or folder `file` has any allow entry (read
/// included): another account may open it, whatever its mode says.
pub fn fd_any_grants(file: &std::fs::File) -> io::Result<bool> {
    imp::fd_any_grants(file)
}

#[cfg(target_os = "macos")]
mod imp {
    use std::ffi::{CString, c_char, c_int, c_void};
    use std::io;
    use std::os::fd::AsRawFd as _;
    use std::os::unix::ffi::OsStrExt as _;
    use std::path::Path;

    type Acl = *mut c_void;
    type AclEntry = *mut c_void;

    // <sys/acl.h>
    const ACL_TYPE_EXTENDED: c_int = 0x0000_0100;
    const ACL_FIRST_ENTRY: c_int = 0;
    const ACL_NEXT_ENTRY: c_int = -1;
    const ACL_EXTENDED_ALLOW: c_int = 1;
    /// <sys/acl.h>: `acl_permset_mask_t` is `u_int64_t`; `acl_tag_t` and
    /// the entry ids are C enums (int-sized).
    /// ACL_WRITE_DATA (ADD_FILE), ACL_DELETE, ACL_APPEND_DATA
    /// (ADD_SUBDIRECTORY), ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES,
    /// ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER.
    const WRITE_CLASS: u64 =
        (1 << 2) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 8) | (1 << 10) | (1 << 12) | (1 << 13);

    unsafe extern "C" {
        fn acl_get_link_np(path: *const c_char, kind: c_int) -> Acl;
        fn acl_get_fd_np(fd: c_int, kind: c_int) -> Acl;
        fn acl_set_fd_np(fd: c_int, acl: Acl, kind: c_int) -> c_int;
        fn acl_get_entry(acl: Acl, entry_id: c_int, entry: *mut AclEntry) -> c_int;
        fn acl_get_tag_type(entry: AclEntry, tag: *mut c_int) -> c_int;
        fn acl_get_permset_mask_np(entry: AclEntry, mask: *mut u64) -> c_int;
        fn acl_delete_entry(acl: Acl, entry: AclEntry) -> c_int;
        fn acl_free(obj: *mut c_void) -> c_int;
    }

    /// An ACL from `acl_get_*`, freed on drop. None: the file has no ACL.
    struct Owned(Acl);

    impl Drop for Owned {
        fn drop(&mut self) {
            // SAFETY: self.0 came from acl_get_*_np and is freed once.
            unsafe { acl_free(self.0) };
        }
    }

    fn owned(acl: Acl) -> io::Result<Option<Owned>> {
        if !acl.is_null() {
            return Ok(Some(Owned(acl)));
        }
        let err = io::Error::last_os_error();
        // ENOENT: no ACL at all. ENOTSUP: a file system without ACLs.
        match err.raw_os_error() {
            Some(libc::ENOENT | libc::ENOTSUP) => Ok(None),
            _ => Err(err),
        }
    }

    /// The first write-class allow entry of `acl`, if any. An error
    /// (an entry cmux cannot read, or a walk that fails before the end)
    /// is an error, never "no grant" and never an entry to delete.
    fn first_grant(acl: &Owned) -> io::Result<Option<AclEntry>> {
        first_allow(acl, WRITE_CLASS)
    }

    /// The first allow entry of `acl` that grants any permission in `class`.
    fn first_allow(acl: &Owned, class: u64) -> io::Result<Option<AclEntry>> {
        let mut entry: AclEntry = std::ptr::null_mut();
        let mut which = ACL_FIRST_ENTRY;
        loop {
            // SAFETY: acl.0 is a live ACL and entry a valid out pointer.
            if unsafe { acl_get_entry(acl.0, which, &mut entry) } != 0 {
                let err = io::Error::last_os_error();
                // Darwin ends the walk with EINVAL (no more entries).
                return match err.raw_os_error() {
                    Some(libc::EINVAL) => Ok(None),
                    _ => Err(err),
                };
            }
            which = ACL_NEXT_ENTRY;
            let (mut tag, mut mask) = (0, 0u64);
            // SAFETY: entry was just yielded by acl_get_entry for acl.
            if unsafe { acl_get_tag_type(entry, &mut tag) } != 0
                || unsafe { acl_get_permset_mask_np(entry, &mut mask) } != 0
            {
                return Err(io::Error::last_os_error());
            }
            if tag == ACL_EXTENDED_ALLOW && mask & class != 0 {
                return Ok(Some(entry));
            }
        }
    }

    pub fn write_grants(path: &Path) -> io::Result<bool> {
        let name = CString::new(path.as_os_str().as_bytes())
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
        // SAFETY: a valid C string; the result is checked by owned().
        let acl = owned(unsafe { acl_get_link_np(name.as_ptr(), ACL_TYPE_EXTENDED) })?;
        match acl {
            Some(acl) => Ok(first_grant(&acl)?.is_some()),
            None => Ok(false),
        }
    }

    pub fn fd_write_grants(file: &std::fs::File) -> io::Result<bool> {
        // SAFETY: the descriptor is open for the life of `file`.
        match owned(unsafe { acl_get_fd_np(file.as_raw_fd(), ACL_TYPE_EXTENDED) })? {
            Some(acl) => Ok(first_grant(&acl)?.is_some()),
            None => Ok(false),
        }
    }

    pub fn fd_any_grants(file: &std::fs::File) -> io::Result<bool> {
        // SAFETY: the descriptor is open for the life of `file`.
        match owned(unsafe { acl_get_fd_np(file.as_raw_fd(), ACL_TYPE_EXTENDED) })? {
            Some(acl) => Ok(first_allow(&acl, u64::MAX)?.is_some()),
            None => Ok(false),
        }
    }

    pub fn strip_write_grants(file: &std::fs::File) -> io::Result<bool> {
        let fd = file.as_raw_fd();
        // SAFETY: fd is open for the life of `file`.
        let Some(acl) = owned(unsafe { acl_get_fd_np(fd, ACL_TYPE_EXTENDED) })? else {
            return Ok(false);
        };
        let mut removed = false;
        while let Some(entry) = first_grant(&acl)? {
            // SAFETY: entry belongs to acl; iteration restarts after it.
            if unsafe { acl_delete_entry(acl.0, entry) } != 0 {
                return Err(io::Error::last_os_error());
            }
            removed = true;
        }
        // SAFETY: fd and acl are live.
        if removed && unsafe { acl_set_fd_np(fd, acl.0, ACL_TYPE_EXTENDED) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(removed)
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use std::io;
    use std::path::Path;

    pub fn write_grants(_path: &Path) -> io::Result<bool> {
        Ok(false)
    }

    pub fn fd_write_grants(_file: &std::fs::File) -> io::Result<bool> {
        Ok(false)
    }

    pub fn strip_write_grants(_file: &std::fs::File) -> io::Result<bool> {
        Ok(false)
    }

    pub fn fd_any_grants(_file: &std::fs::File) -> io::Result<bool> {
        Ok(false)
    }
}
