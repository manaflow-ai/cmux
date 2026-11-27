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
pub(super) mod tests {
    use super::*;

    /// Lookups from fixed answers; None is a failed lookup.
    pub(in crate::hub::remote_sandbox) struct Fake {
        pub(in crate::hub::remote_sandbox) user: Option<Account>,
        pub(in crate::hub::remote_sandbox) group: Option<Group>,
        pub(in crate::hub::remote_sandbox) local: Option<Vec<Account>>,
    }

    impl Fake {
        /// `uid` named `leo`, in its own group `gid` with no one else.
        pub(in crate::hub::remote_sandbox) fn private(uid: u32, gid: u32) -> Self {
            let me = Account { name: "leo".into(), uid, gid };
            Fake {
                user: Some(me.clone()),
                group: Some(Group { name: "leo".into(), members: vec![] }),
                local: Some(vec![Account { name: "root".into(), uid: 0, gid: 0 }, me]),
            }
        }
    }

    impl Accounts for Fake {
        fn user(&self, uid: u32) -> Result<Account, String> {
            self.user.clone().ok_or(format!("uid {uid} lookup failed"))
        }
        fn group(&self, gid: u32) -> Result<Group, String> {
            self.group.clone().ok_or(format!("gid {gid} lookup failed"))
        }
        fn local_accounts(&self) -> Result<Vec<Account>, String> {
            self.local.clone().ok_or("/etc/passwd lookup failed".into())
        }
    }

    /// Give `path` an access ACL with one named entry (`tag` 2 = user,
    /// 8 = group) for `id` with rwx, mask rwx. None when the filesystem has no ACLs.
    pub(in crate::hub::remote_sandbox) fn set_acl(path: &Path, tag: u16, id: u32) -> Option<()> {
        const UNDEFINED: u32 = u32::MAX;
        let mut entries = [
            (1u16, 7u16, UNDEFINED),
            (tag, 7, id),
            (4, 7, UNDEFINED),
            (0x10, 7, UNDEFINED),
            (0x20, 5, UNDEFINED),
        ];
        // The kernel takes entries only in tag order.
        entries.sort_by_key(|e| e.0);
        let mut blob = 2u32.to_le_bytes().to_vec();
        for (tag, perm, id) in entries {
            blob.extend(tag.to_le_bytes());
            blob.extend(perm.to_le_bytes());
            blob.extend(id.to_le_bytes());
        }
        let text = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: NUL-terminated strings and a buffer of its own length.
        let rc = unsafe {
            libc::setxattr(
                text.as_ptr(),
                c"system.posix_acl_access".as_ptr(),
                blob.as_ptr().cast(),
                blob.len(),
                0,
            )
        };
        if rc == 0 {
            return Some(());
        }
        let error = std::io::Error::last_os_error();
        assert_eq!(error.raw_os_error(), Some(libc::EOPNOTSUPP), "setxattr: {error}");
        None
    }

    #[test]
    fn a_folder_without_an_acl_has_none_and_a_missing_one_fails_closed() {
        let dir = std::env::temp_dir().join(format!("acpmux-acl-none-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(no_extended_acl(&dir), Ok(()));
        let _ = std::fs::remove_dir_all(&dir);
        let error = no_extended_acl(&dir).unwrap_err();
        assert!(error.contains("cannot be checked"), "{error}");
    }

    #[test]
    fn a_user_private_group_is_private() {
        assert_eq!(private_group(1000, 1000, &Fake::private(1000, 1000)), Ok(()));
    }

    #[test]
    fn a_group_with_members_is_not_private() {
        let mut fake = Fake::private(1000, 1000);
        fake.group.as_mut().unwrap().members = vec!["bob".into()];
        let error = private_group(1000, 1000, &fake).unwrap_err();
        assert!(error.contains("group leo (gid 1000)") && error.contains("bob"), "{error}");
    }

    #[test]
    fn a_group_that_is_not_the_primary_group_is_not_private() {
        let mut fake = Fake::private(1000, 1000);
        fake.group = Some(Group { name: "developers".into(), members: vec![] });
        let error = private_group(1000, 1001, &fake).unwrap_err();
        assert!(error.contains("group developers (gid 1001)"), "{error}");
    }

    #[test]
    fn a_group_named_for_someone_else_is_not_private() {
        let mut fake = Fake::private(1000, 1000);
        fake.group.as_mut().unwrap().name = "staff".into();
        let error = private_group(1000, 1000, &fake).unwrap_err();
        assert!(error.contains("group staff (gid 1000)"), "{error}");
    }

    #[test]
    fn another_account_whose_primary_group_it_is_makes_it_shared() {
        let mut fake = Fake::private(1000, 1000);
        fake.local.as_mut().unwrap().push(Account { name: "bob".into(), uid: 1001, gid: 1000 });
        let error = private_group(1000, 1000, &fake).unwrap_err();
        assert!(error.contains("group leo (gid 1000)") && error.contains("bob"), "{error}");
    }

    #[test]
    fn a_failed_lookup_is_refused() {
        for fail in 0..3 {
            let mut fake = Fake::private(1000, 1000);
            match fail {
                0 => fake.user = None,
                1 => fake.group = None,
                _ => fake.local = None,
            }
            let error = private_group(1000, 1000, &fake).unwrap_err();
            assert!(error.contains("cannot be checked"), "{error}");
        }
    }

    #[test]
    fn passwd_parsing_reads_primary_groups_and_refuses_includes() {
        let text =
            "# comment\nroot:x:0:0:root:/root:/bin/bash\nleo:x:1000:1000::/home/leo:/bin/bash\n";
        let accounts = parse_passwd(text).unwrap();
        assert_eq!(accounts[1], Account { name: "leo".into(), uid: 1000, gid: 1000 });
        assert!(parse_passwd("+::::::\n").is_err());
        assert!(parse_passwd("leo:x:abc:1000::/home/leo:/bin/sh\n").is_err());
    }

    #[test]
    fn the_system_lookup_reads_root() {
        let root = System.user(0).unwrap();
        assert_eq!((root.name.as_str(), root.uid, root.gid), ("root", 0, 0));
        assert_eq!(System.group(0).unwrap().name, "root");
        assert!(System.local_accounts().unwrap().iter().any(|a| a.uid == 0));
    }
}
