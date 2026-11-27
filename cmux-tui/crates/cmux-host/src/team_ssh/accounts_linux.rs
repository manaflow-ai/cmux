//! The Linux [`Accounts`]: NSS lookups through libc and `groupadd`,
//! `useradd`, `usermod`, `gpasswd`, `groupdel`, `loginctl` and `systemctl`
//! by absolute path with a fixed environment (root runs these; PATH is not
//! consulted).

use std::ffi::{CStr, CString};
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use super::accounts::{Accounts, NOLOGIN, UserInfo, WantedUser};

const BUF: usize = 64 * 1024;

pub struct LinuxAccounts {
    pub groupadd: PathBuf,
    pub groupdel: PathBuf,
    pub useradd: PathBuf,
    pub usermod: PathBuf,
    pub gpasswd: PathBuf,
    pub loginctl: PathBuf,
    pub systemctl: PathBuf,
}

impl Default for LinuxAccounts {
    fn default() -> Self {
        Self {
            groupadd: PathBuf::from("/usr/sbin/groupadd"),
            groupdel: PathBuf::from("/usr/sbin/groupdel"),
            useradd: PathBuf::from("/usr/sbin/useradd"),
            usermod: PathBuf::from("/usr/sbin/usermod"),
            gpasswd: PathBuf::from("/usr/bin/gpasswd"),
            loginctl: PathBuf::from("/usr/bin/loginctl"),
            systemctl: PathBuf::from("/usr/bin/systemctl"),
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

/// Whether the shadow expiry date of `user` has passed (getspnam_r); a
/// missing shadow entry counts as not expired.
fn expired(user: &str) -> io::Result<bool> {
    let cname = CString::new(user).map_err(io::Error::other)?;
    let mut sp = std::mem::MaybeUninit::<libc::spwd>::uninit();
    let mut buf = vec![0 as libc::c_char; BUF];
    let mut result: *mut libc::spwd = std::ptr::null_mut();
    // SAFETY: every pointer is valid for the call; `result` is set to `sp` on success.
    let rc = unsafe {
        libc::getspnam_r(cname.as_ptr(), sp.as_mut_ptr(), buf.as_mut_ptr(), buf.len(), &mut result)
    };
    if rc != 0 && rc != libc::ENOENT {
        return Err(io::Error::from_raw_os_error(rc));
    }
    if result.is_null() {
        return Ok(false);
    }
    // SAFETY: `result` points at the initialized `sp`.
    let expire = unsafe { sp.assume_init() }.sp_expire;
    let today = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| (d.as_secs() / 86_400) as libc::c_long);
    Ok(expire >= 0 && expire <= today)
}

/// `user`'s passwd entry (getpwnam_r), `None` when there is no such user.
fn passwd(user: &str) -> io::Result<Option<(u32, u32, String)>> {
    let cname = CString::new(user).map_err(io::Error::other)?;
    let mut pwd = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut buf = vec![0 as libc::c_char; BUF];
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: every pointer is valid for the call; `result` is set to `pwd` on success.
    let rc = unsafe {
        libc::getpwnam_r(cname.as_ptr(), pwd.as_mut_ptr(), buf.as_mut_ptr(), buf.len(), &mut result)
    };
    if rc != 0 {
        return Err(io::Error::from_raw_os_error(rc));
    }
    if result.is_null() {
        return Ok(None);
    }
    // SAFETY: `result` points at the initialized `pwd`, whose strings live in `buf`.
    let pwd = unsafe { pwd.assume_init() };
    let shell = unsafe { CStr::from_ptr(pwd.pw_shell) }.to_string_lossy().into_owned();
    Ok(Some((pwd.pw_uid, pwd.pw_gid, shell)))
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
    fn user(&self, user: &str) -> io::Result<Option<UserInfo>> {
        let Some((uid, gid, shell)) = passwd(user)? else { return Ok(None) };
        Ok(Some(UserInfo { uid, gid, shell, expired: expired(user)? }))
    }

    fn user_of_uid(&self, uid: u32) -> io::Result<Option<String>> {
        user_of(uid)
    }

    fn group_exists(&self, group: &str) -> io::Result<bool> {
        Ok(group_members(group)?.is_some())
    }

    fn create(&self, user: &WantedUser, groups: &[&str]) -> io::Result<()> {
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
        let joined = groups.join(",");
        if !groups.is_empty() {
            args.extend(["--groups", &joined]);
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

    fn remove_from_group(&self, user: &str, group: &str) -> io::Result<()> {
        run_tool(&self.gpasswd, &["--delete", user, group])
    }

    fn activate(&self, user: &WantedUser) -> io::Result<()> {
        run_tool(&self.usermod, &["--expiredate", "", "--shell", user.class.shell(), &user.user])
    }

    fn retire(&self, user: &str, uid: u32) -> io::Result<()> {
        // Expire first, so no new login opens while the sessions end.
        run_tool(&self.usermod, &["--expiredate", "1", "--shell", NOLOGIN, user])?;
        // Not logged in and not lingering are fine: these fail only then.
        let _ = run_tool(&self.loginctl, &["terminate-user", user]);
        let _ = run_tool(&self.loginctl, &["disable-linger", user]);
        run_tool(&self.systemctl, &["--no-block", "stop", &format!("user@{uid}.service")])
    }
}
