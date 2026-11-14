//! Part of `remote_sandbox`: whether a group-writable folder on a remote
//! chain's paths is still writable by this user alone.
//!
//! Ubuntu and Debian make every account its own group (a user-private group:
//! `leo` in group `leo`, no one else in it) and set umask 002, so the user's
//! own folders are group-writable by default. Group write on such a folder
//! adds no writer, so the path check accepts it. Any other group, a group it
//! cannot look up, an access control list (whose mask the group bits then
//! are), or world write stays refused.

use std::ffi::CStr;
use std::path::Path;

/// An account entry: its name, its uid and its primary group.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Account {
    pub(super) name: String,
    pub(super) uid: u32,
    pub(super) gid: u32,
}

/// A group entry: its name and the accounts it lists as members.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Group {
    pub(super) name: String,
    pub(super) members: Vec<String>,
}

/// The account lookups the check needs. Any error refuses.
pub(super) trait Accounts {
    fn user(&self, uid: u32) -> Result<Account, String>;
    fn group(&self, gid: u32) -> Result<Group, String>;
    /// Every account in the local account file, to find another account
    /// whose primary group is this one (the group file does not list it).
    fn local_accounts(&self) -> Result<Vec<Account>, String>;
}

/// Ok when `gid` is `uid`'s user-private group: its primary group, named as
/// the user, listing no member, and no other local account's primary group.
/// Otherwise the reason, which names the group.
pub(super) fn private_group(uid: u32, gid: u32, accounts: &dyn Accounts) -> Result<(), String> {
    let group =
        accounts.group(gid).map_err(|e| format!("its group (gid {gid}) cannot be checked: {e}"))?;
    let shown = format!("its group {} (gid {gid})", group.name);
    let user = accounts.user(uid).map_err(|e| format!("{shown} cannot be checked: {e}"))?;
    let not_private = |why: String| format!("{shown} is not {}'s private group: {why}", user.name);
    if user.gid != gid {
        return Err(not_private(format!("{}'s primary group is gid {}", user.name, user.gid)));
    }
    if group.name != user.name {
        return Err(not_private("it is not named after the user".into()));
    }
    if !group.members.is_empty() {
        return Err(not_private(format!("it lists members {}", group.members.join(", "))));
    }
    let local = accounts.local_accounts().map_err(|e| format!("{shown} cannot be checked: {e}"))?;
    let others: Vec<&str> =
        local.iter().filter(|a| a.gid == gid && a.uid != uid).map(|a| a.name.as_str()).collect();
    if !others.is_empty() {
        return Err(not_private(format!("it is the primary group of {}", others.join(", "))));
    }
    Ok(())
}

/// The extended attributes that hold an access control list: POSIX ACLs and
/// NFSv4 ACLs (on NFS and some other filesystems).
const ACL_XATTRS: [&CStr; 2] = [c"system.posix_acl_access", c"system.nfs4_acl"];

/// Ok when `path` (not followed if a link) has no access control list, or
/// its filesystem supports none. An ACL, or a failed check, is the reason it
/// does not count as private.
pub(super) fn no_extended_acl(path: &Path) -> Result<(), String> {
    let text = std::ffi::CString::new(path.as_os_str().as_encoded_bytes())
        .map_err(|_| "its path has a NUL byte".to_owned())?;
    for name in ACL_XATTRS {
        // SAFETY: NUL-terminated strings; a null buffer of size 0 asks only for the size.
        let rc = unsafe { libc::lgetxattr(text.as_ptr(), name.as_ptr(), std::ptr::null_mut(), 0) };
        if rc >= 0 {
            return Err(format!(
                "has an access control list ({}), which can let others write",
                name.to_string_lossy()
            ));
        }
        let error = std::io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::ENODATA) | Some(libc::EOPNOTSUPP) => {}
            _ => return Err(format!("its access control list cannot be checked: {error}")),
        }
    }
    Ok(())
}

/// The system's own account database: getpwuid_r, getgrgid_r and the local
/// account file.
pub(super) struct System;

/// Largest buffer a lookup may grow to before it counts as failed.
const MAX_LOOKUP_BUFFER: usize = 1 << 20;

impl Accounts for System {
    fn user(&self, uid: u32) -> Result<Account, String> {
        let mut size = 1024;
        loop {
            let mut buf = vec![0 as libc::c_char; size];
            // SAFETY: an all-zero passwd is a valid out parameter.
            let mut entry = unsafe { std::mem::zeroed::<libc::passwd>() };
            let mut found: *mut libc::passwd = std::ptr::null_mut();
            // SAFETY: every pointer is valid for the call and `buf` is `size` long.
            let rc = unsafe {
                libc::getpwuid_r(uid as _, &mut entry, buf.as_mut_ptr(), buf.len(), &mut found)
            };
            if rc == libc::ERANGE && size < MAX_LOOKUP_BUFFER {
                size *= 4;
                continue;
            }
            if rc != 0 {
                return Err(format!(
                    "uid {uid} lookup failed: {}",
                    std::io::Error::from_raw_os_error(rc)
                ));
            }
            if found.is_null() || entry.pw_name.is_null() {
                return Err(format!("uid {uid} has no account entry"));
            }
            // SAFETY: getpwuid_r succeeded, so pw_name points into `buf`.
            let name = unsafe { CStr::from_ptr(entry.pw_name) }.to_string_lossy().into_owned();
            return Ok(Account { name, uid: entry.pw_uid as _, gid: entry.pw_gid as _ });
        }
    }

    fn group(&self, gid: u32) -> Result<Group, String> {
        let mut size = 1024;
        loop {
            let mut buf = vec![0 as libc::c_char; size];
            // SAFETY: an all-zero group is a valid out parameter.
            let mut entry = unsafe { std::mem::zeroed::<libc::group>() };
            let mut found: *mut libc::group = std::ptr::null_mut();
            // SAFETY: every pointer is valid for the call and `buf` is `size` long.
            let rc = unsafe {
                libc::getgrgid_r(gid as _, &mut entry, buf.as_mut_ptr(), buf.len(), &mut found)
            };
            if rc == libc::ERANGE && size < MAX_LOOKUP_BUFFER {
                size *= 4;
                continue;
            }
            if rc != 0 {
                return Err(format!(
                    "gid {gid} lookup failed: {}",
                    std::io::Error::from_raw_os_error(rc)
                ));
            }
            if found.is_null() || entry.gr_name.is_null() {
                return Err(format!("gid {gid} has no group entry"));
            }
            // SAFETY: getgrgid_r succeeded, so gr_name and the NULL-terminated
            // gr_mem array point into `buf`.
            let name = unsafe { CStr::from_ptr(entry.gr_name) }.to_string_lossy().into_owned();
            let mut members = Vec::new();
            let mut cursor = entry.gr_mem;
            while !cursor.is_null() {
                // SAFETY: `cursor` walks the NULL-terminated gr_mem array in `buf`.
                let member = unsafe { *cursor };
                if member.is_null() {
                    break;
                }
                // SAFETY: a gr_mem entry is a NUL-terminated string in `buf`.
                members.push(unsafe { CStr::from_ptr(member) }.to_string_lossy().into_owned());
                // SAFETY: the array has its NULL terminator after `member`.
                cursor = unsafe { cursor.add(1) };
            }
            return Ok(Group { name, members });
        }
    }

    fn local_accounts(&self) -> Result<Vec<Account>, String> {
        let text =
            std::fs::read_to_string("/etc/passwd").map_err(|e| format!("/etc/passwd: {e}"))?;
        parse_passwd(&text)
    }
}

/// The accounts in a passwd file. A NIS include line (`+`/`-`) means the
/// file does not list every account, so it fails.
pub(super) fn parse_passwd(text: &str) -> Result<Vec<Account>, String> {
    let mut out = Vec::new();
    for line in text.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')) {
        if line.starts_with('+') || line.starts_with('-') {
            return Err("/etc/passwd includes accounts from elsewhere".into());
        }
        let fields: Vec<&str> = line.split(':').collect();
        let (Some(name), Some(uid), Some(gid)) = (fields.first(), fields.get(2), fields.get(3))
        else {
            return Err(format!("/etc/passwd has a malformed line: {line}"));
        };
        let (Ok(uid), Ok(gid)) = (uid.parse(), gid.parse()) else {
            return Err(format!("/etc/passwd has a malformed line: {line}"));
        };
        out.push(Account { name: (*name).to_owned(), uid, gid });
    }
    Ok(out)
}

#[cfg(test)]
pub(super) mod tests;
