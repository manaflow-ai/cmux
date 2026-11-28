//! The files the cmux vault's pull writes (`vault.rs`), as root into a home the session user owns.
//!
//! [`SecretsFile`]: `<home>/.config/cmux/machine-secrets.env`, reached one folder at a time from the home with
//! `openat(O_NOFOLLOW | O_DIRECTORY)`, so no symlink the user (or an agent running as them) puts on the path is
//! ever followed: each folder must be a real folder of the session user, made 0700 and theirs when missing;
//! `cmux` is kept 0700. The file is replaced by a fresh 0600 temporary of the user's, synced and renamed in
//! that same folder; an existing file is read only when it is a regular file of theirs of at most 4 MiB
//! (the applier's and acpmux's limit). Every failure is a code, never a path's contents.
//!
//! [`ensure_profile_hook`]: `/etc/profile.d/cmux-vault.sh`, so every login shell (a terminal, acpmux's
//! login environment read) sources the file on a machine with no `.cmux/machine.toml` too. Root's, 0644;
//! a file there without the managed header is someone's own and left alone.

use std::ffi::CString;
use std::fs::File;
use std::io::{Read as _, Write as _};
use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};
use std::os::unix::ffi::OsStrExt as _;
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};

use zeroize::Zeroizing;

use super::vault::EnvFile;

/// The largest secrets file read back (the applier's and acpmux's limit).
pub const MAX_SECRETS_BYTES: u64 = 4 << 20;
/// The login profile that sources the secrets file.
pub const PROFILE_HOOK: &str = "/etc/profile.d/cmux-vault.sh";
const PROFILE_HEADER: &str = "# cmux vault (cmux host, managed, do not edit)";
/// The hook's text: the same guard the applier's machine.env uses (a regular file, not a link; never inside
/// a machine setup run, whose output is logged).
pub const PROFILE_TEXT: &str = "# cmux vault (cmux host, managed, do not edit): the names devices sealed to this machine, for login shells\n\
cmux_vault_env=\"${HOME:-}/.config/cmux/machine-secrets.env\"\n\
if [ -z \"${CMUX_MACHINE_SETUP:-}\" ] && [ -n \"${HOME:-}\" ] && [ -f \"$cmux_vault_env\" ] && [ ! -L \"$cmux_vault_env\" ]; then . \"$cmux_vault_env\"; fi\n\
unset cmux_vault_env\n";

const FILE_NAME: &str = "machine-secrets.env";

/// The session user's secrets file under `home` (already rooted by the caller's `Paths`).
pub struct SecretsFile {
    pub home: PathBuf,
    pub uid: u32,
    pub gid: u32,
}

fn c(name: &[u8]) -> Result<CString, &'static str> {
    CString::new(name).map_err(|_| "vault.path")
}

fn open_dir_at(parent: Option<&OwnedFd>, name: &[u8]) -> std::io::Result<OwnedFd> {
    let name = CString::new(name).map_err(|_| std::io::ErrorKind::InvalidInput)?;
    let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    let at = parent.map_or(libc::AT_FDCWD, |p| p.as_raw_fd());
    // SAFETY: `name` is a NUL-terminated string; `at` is an open descriptor or AT_FDCWD.
    let fd = unsafe { libc::openat(at, name.as_ptr(), flags) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: `fd` was just opened and is owned here alone.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

impl SecretsFile {
    /// The `cmux` folder's descriptor: home, `.config`, `cmux`, each a real folder of the user; the two below
    /// the home made (0700, the user's) when missing.
    fn folder(&self) -> Result<OwnedFd, &'static str> {
        let home =
            open_dir_at(None, self.home.as_os_str().as_bytes()).map_err(|_| "vault.no_home")?;
        self.owned_dir(&home)?;
        let mut at = home;
        for (i, part) in [".config", "cmux"].iter().enumerate() {
            let next = match open_dir_at(Some(&at), part.as_bytes()) {
                Ok(fd) => fd,
                Err(e) if e.raw_os_error() == Some(libc::ENOENT) => {
                    let name = c(part.as_bytes())?;
                    // SAFETY: `name` is NUL-terminated; `at` is an open folder.
                    if unsafe { libc::mkdirat(at.as_raw_fd(), name.as_ptr(), 0o700) } != 0
                        && std::io::Error::last_os_error().raw_os_error() != Some(libc::EEXIST)
                    {
                        return Err("vault.folder");
                    }
                    let fd = open_dir_at(Some(&at), part.as_bytes()).map_err(|_| "vault.folder")?;
                    // SAFETY: `fd` is an open folder this process made.
                    if unsafe { libc::fchown(fd.as_raw_fd(), self.uid, self.gid) } != 0 {
                        return Err("vault.folder");
                    }
                    fd
                }
                Err(_) => return Err("vault.folder_not_owned"),
            };
            self.owned_dir(&next)?;
            if i == 1 {
                // SAFETY: `next` is an open folder.
                if unsafe { libc::fchmod(next.as_raw_fd(), 0o700) } != 0 {
                    return Err("vault.folder");
                }
            }
            at = next;
        }
        Ok(at)
    }

    fn owned_dir(&self, fd: &OwnedFd) -> Result<(), &'static str> {
        let meta = File::from(fd.try_clone().map_err(|_| "vault.folder")?)
            .metadata()
            .map_err(|_| "vault.folder")?;
        if !meta.is_dir() || meta.uid() != self.uid {
            return Err("vault.folder_not_owned");
        }
        Ok(())
    }
}

impl EnvFile for SecretsFile {
    fn read(&mut self) -> Result<Zeroizing<String>, &'static str> {
        let dir = self.folder()?;
        let name = c(FILE_NAME.as_bytes())?;
        let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;
        // SAFETY: `name` is NUL-terminated; `dir` is an open folder.
        let fd = unsafe { libc::openat(dir.as_raw_fd(), name.as_ptr(), flags) };
        if fd < 0 {
            return match std::io::Error::last_os_error().raw_os_error() {
                Some(libc::ENOENT) => Ok(Zeroizing::new(String::new())),
                Some(libc::ELOOP) => Err("vault.secrets_symlink"),
                _ => Err("vault.secrets_unreadable"),
            };
        }
        // SAFETY: `fd` was just opened and is owned here alone.
        let file = unsafe { File::from_raw_fd(fd) };
        let meta = file.metadata().map_err(|_| "vault.secrets_unreadable")?;
        if !meta.is_file() || meta.uid() != self.uid {
            return Err("vault.secrets_not_owned");
        }
        if meta.len() > MAX_SECRETS_BYTES {
            return Err("vault.secrets_too_large");
        }
        let mut bytes = Zeroizing::new(Vec::new());
        file.take(MAX_SECRETS_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "vault.secrets_unreadable")?;
        let text = std::str::from_utf8(&bytes).map_err(|_| "vault.secrets_not_text")?;
        Ok(Zeroizing::new(text.to_owned()))
    }

    fn write(&mut self, text: &str) -> Result<(), &'static str> {
        let dir = self.folder()?;
        let tmp_name = format!(".{FILE_NAME}.vault-{}", std::process::id());
        let tmp = c(tmp_name.as_bytes())?;
        let target = c(FILE_NAME.as_bytes())?;
        // SAFETY: `tmp` is NUL-terminated; `dir` is an open folder. A leftover temporary of ours goes first.
        unsafe { libc::unlinkat(dir.as_raw_fd(), tmp.as_ptr(), 0) };
        let flags =
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: as above; the mode is an int the variadic openat takes.
        let fd =
            unsafe { libc::openat(dir.as_raw_fd(), tmp.as_ptr(), flags, 0o600 as libc::c_uint) };
        if fd < 0 {
            return Err("vault.secrets_write");
        }
        // SAFETY: `fd` was just opened and is owned here alone.
        let mut file = unsafe { File::from_raw_fd(fd) };
        let written = file
            .write_all(text.as_bytes())
            .and_then(|()| file.set_permissions(std::fs::Permissions::from_mode(0o600)))
            .and_then(|()| std::os::unix::fs::fchown(&file, Some(self.uid), Some(self.gid)))
            .and_then(|()| file.sync_all());
        // SAFETY: both names are NUL-terminated and in the one open folder.
        let renamed = written.is_ok()
            && unsafe {
                libc::renameat(dir.as_raw_fd(), tmp.as_ptr(), dir.as_raw_fd(), target.as_ptr())
            } == 0;
        if !renamed {
            // SAFETY: as above.
            unsafe { libc::unlinkat(dir.as_raw_fd(), tmp.as_ptr(), 0) };
            return Err("vault.secrets_write");
        }
        // The rename is durable once the folder is.
        let _ = File::from(dir).sync_all();
        Ok(())
    }
}

/// Writes [`PROFILE_HOOK`] at `path` (the caller's `Paths` roots it) when it is missing or an older managed
/// copy. `Ok(true)` when it wrote.
pub fn ensure_profile_hook(path: &Path) -> Result<bool, &'static str> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if !meta.is_file() => return Err("vault.profile_not_a_file"),
        Ok(_) => {
            let old = std::fs::read_to_string(path).map_err(|_| "vault.profile")?;
            if old == PROFILE_TEXT {
                return Ok(false);
            }
            if !old.starts_with(PROFILE_HEADER) {
                return Err("vault.profile_not_managed");
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err("vault.profile"),
    }
    let dir = path.parent().ok_or("vault.profile")?;
    std::fs::create_dir_all(dir).map_err(|_| "vault.profile")?;
    let tmp = dir.join(format!(".cmux-vault.sh.{}", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    let written = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o644)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&tmp)
        .and_then(|mut f| {
            f.write_all(PROFILE_TEXT.as_bytes())?;
            f.set_permissions(std::fs::Permissions::from_mode(0o644))?;
            f.sync_all()
        })
        .and_then(|()| std::fs::rename(&tmp, path));
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
        return Err("vault.profile");
    }
    Ok(true)
}
