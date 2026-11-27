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
    let text = "# comment\nroot:x:0:0:root:/root:/bin/bash\nleo:x:1000:1000::/home/leo:/bin/bash\n";
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
