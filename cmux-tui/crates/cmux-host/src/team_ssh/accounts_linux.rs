//! The Linux [`Accounts`]: NSS lookups through libc and `groupadd`,
//! `useradd`, `usermod` and `groupdel` by absolute path with a fixed
//! environment (root runs these; PATH is not consulted).

use std::ffi::{CStr, CString};
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use super::accounts::{Accounts, WantedUser};
use crate::linux::spawn::lookup_user;

const BUF: usize = 64 * 1024;

pub struct LinuxAccounts {
    pub groupadd: PathBuf,
    pub groupdel: PathBuf,
    pub useradd: PathBuf,
    pub usermod: PathBuf,
}

impl Default for LinuxAccounts {
    fn default() -> Self {
        Self {
            groupadd: PathBuf::from("/usr/sbin/groupadd"),
            groupdel: PathBuf::from("/usr/sbin/groupdel"),
            useradd: PathBuf::from("/usr/sbin/useradd"),
            usermod: PathBuf::from("/usr/sbin/usermod"),
        }
    }
}

fn run_tool(tool: &Path, args: &[&str]) -> io::Result<()> {
    let out = Command::new(tool)
        .args(args)
        .env_clear()
        .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
        .stdin(Stdio::null())
        .output()?;
    if out.status.success() {
        return Ok(());
    }
    Err(io::Error::other(format!(
        "{} {}: {}",
        tool.display(),
        args.join(" "),
        String::from_utf8_lossy(&out.stderr).trim()
    )))
}

/// The name of the user that holds `uid` (getpwuid_r), `None` when free.
fn user_of(uid: u32) -> io::Result<Option<String>> {
    let mut pwd = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut buf = vec![0 as libc::c_char; BUF];
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: every pointer is valid for the call; `result` is set to `pwd` on success.
    let rc = unsafe {
        libc::getpwuid_r(uid, pwd.as_mut_ptr(), buf.as_mut_ptr(), buf.len(), &mut result)
    };
    if rc != 0 {
        return Err(io::Error::from_raw_os_error(rc));
    }
    if result.is_null() {
        return Ok(None);
    }
    // SAFETY: `result` points at the initialized `pwd`, whose strings live in `buf`.
    let name = unsafe { CStr::from_ptr(pwd.assume_init().pw_name) };
    Ok(Some(name.to_string_lossy().into_owned()))
}

/// The members of `group` (getgrnam_r), `None` when there is no such group.
fn group_members(group: &str) -> io::Result<Option<Vec<String>>> {
    let cname = CString::new(group).map_err(io::Error::other)?;
    let mut grp = std::mem::MaybeUninit::<libc::group>::uninit();
    let mut buf = vec![0 as libc::c_char; BUF];
    let mut result: *mut libc::group = std::ptr::null_mut();
    // SAFETY: every pointer is valid for the call; `result` is set to `grp` on success.
    let rc = unsafe {
        libc::getgrnam_r(cname.as_ptr(), grp.as_mut_ptr(), buf.as_mut_ptr(), buf.len(), &mut result)
    };
    if rc != 0 {
        return Err(io::Error::from_raw_os_error(rc));
    }
    if result.is_null() {
        return Ok(None);
    }
    // SAFETY: `result` points at the initialized `grp`; gr_mem is a
    // NULL-terminated array of strings in `buf`.
    let mut members = Vec::new();
    unsafe {
        let mut p = grp.assume_init().gr_mem;
        while !p.is_null() && !(*p).is_null() {
            members.push(CStr::from_ptr(*p).to_string_lossy().into_owned());
            p = p.add(1);
        }
    }
    Ok(Some(members))
}

impl Accounts for LinuxAccounts {
    fn uid_of(&self, user: &str) -> io::Result<Option<u32>> {
        Ok(lookup_user(user).map(|u| u.uid))
    }

    fn user_of_uid(&self, uid: u32) -> io::Result<Option<String>> {
        user_of(uid)
    }

    fn group_exists(&self, group: &str) -> io::Result<bool> {
        Ok(group_members(group)?.is_some())
    }

    fn create(&self, user: &WantedUser, login_group: Option<&str>) -> io::Result<()> {
        let uid = user.uid.to_string();
        run_tool(&self.groupadd, &["--gid", &uid, &user.user])?;
        let mut args = vec![
            "--uid",
            &uid,
            "--gid",
            &uid,
            "--no-user-group",
            "--create-home",
            "--shell",
            user.class.shell(),
            "--comment",
            "cmux team",
        ];
        if let Some(group) = login_group {
            args.extend(["--groups", group]);
        }
        args.push(&user.user);
        if let Err(e) = run_tool(&self.useradd, &args) {
            // Leave no half-made account: the group goes with the failed user.
            let _ = run_tool(&self.groupdel, &[&user.user]);
            return Err(e);
        }
        Ok(())
    }

    fn in_group(&self, user: &str, group: &str) -> io::Result<bool> {
        Ok(group_members(group)?.is_some_and(|m| m.iter().any(|u| u == user)))
    }

    fn add_to_group(&self, user: &str, group: &str) -> io::Result<()> {
        run_tool(&self.usermod, &["--append", "--groups", group, user])
    }
}
