//! The files `secrets-v1` writes: owner-only (0600) in owner-only (0700)
//! folders, replaced atomically by a rename, never through a symlink.

use std::io;
#[cfg(unix)]
use std::io::Write as _;
use std::path::{Path, PathBuf};

/// `~/.config/cmux/machine-secrets.env`, which the machine's `machine.env`
/// sources (`export NAME='value'` lines).
pub const MACHINE_SECRETS_FILE: &str = ".config/cmux/machine-secrets.env";
/// The machine config applier's status: the secret names `.cmux/machine.toml`
/// declares (`secrets.declared`).
pub const MACHINE_CONFIG_STATUS_FILE: &str = ".cmux/machine-config/status.json";
/// The largest machine-secrets.env the applier reads: 4 MiB.
pub const MAX_ENV_FILE_BYTES: usize = 4 << 20;
/// The largest single value: 16 KiB.
pub const MAX_VALUE_BYTES: usize = 16 * 1024;

/// The machine config's name rule (`[A-Za-z_][A-Za-z0-9_]*`, at most 128),
/// and not a name the machine's shell, libc, python or cmux owns: the same
/// list as the applier and `cmux cloud secret set`.
pub fn is_secret_name(name: &str) -> bool {
    let mut bytes = name.bytes();
    let Some(first) = bytes.next() else {
        return false;
    };
    if name.len() > 128
        || !(first.is_ascii_alphabetic() || first == b'_')
        || !bytes.all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
    {
        return false;
    }
    let upper = name.to_ascii_uppercase();
    !RESERVED_NAMES.contains(&upper.as_str())
        && !RESERVED_PREFIXES.iter().any(|prefix| upper.starts_with(prefix))
}

const RESERVED_NAMES: &[&str] = &[
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "IFS",
    "ENV",
    "BASH_ENV",
    "PROMPT_COMMAND",
    "PWD",
    "OLDPWD",
    "TERM",
    "BASH",
    "BASHOPTS",
    "BASHPID",
    "CDPATH",
    "COLUMNS",
    "DIRSTACK",
    "EPOCHREALTIME",
    "EPOCHSECONDS",
    "EUID",
    "EXECIGNORE",
    "FCEDIT",
    "FIGNORE",
    "FUNCNAME",
    "FUNCNEST",
    "GLOBIGNORE",
    "GROUPS",
    "HOSTFILE",
    "HOSTNAME",
    "HOSTTYPE",
    "IGNOREEOF",
    "INPUTRC",
    "LINENO",
    "LINES",
    "MACHTYPE",
    "MAIL",
    "MAILCHECK",
    "MAILPATH",
    "OPTARG",
    "OPTERR",
    "OPTIND",
    "OSTYPE",
    "PIPESTATUS",
    "POSIXLY_CORRECT",
    "PPID",
    "RANDOM",
    "REPLY",
    "SECONDS",
    "SHELLOPTS",
    "SHLVL",
    "SRANDOM",
    "TIMEFORMAT",
    "TMOUT",
    "TMPDIR",
    "UID",
    "_",
    "PS0",
    "PS1",
    "PS2",
    "PS3",
    "PS4",
    "HISTCMD",
    "HISTCONTROL",
    "HISTFILE",
    "HISTFILESIZE",
    "HISTIGNORE",
    "HISTSIZE",
    "HISTTIMEFORMAT",
    "LANG",
    "LANGUAGE",
    "TZ",
    "TZDIR",
    "NLSPATH",
    "ZDOTDIR",
    "FPATH",
    "MODULE_PATH",
    "PROMPT",
    "PROMPT2",
    "PROMPT3",
    "PROMPT4",
    "RPROMPT",
    "RPROMPT2",
    "RPS1",
    "RPS2",
    "NULLCMD",
    "READNULLCMD",
    "HISTCHARS",
    "WATCHFMT",
    "PERIOD",
    "KEYTIMEOUT",
    "SAVEHIST",
    "STTY",
    "PYTHONHOME",
    "PYTHONPATH",
    "PYTHONSTARTUP",
    "PYTHONINSPECT",
    "PYTHONUSERBASE",
    "PYTHONSAFEPATH",
    "OPENAI_API_KEY",
    "OPENAI_BASE_URL",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
];
const RESERVED_PREFIXES: &[&str] =
    &["LD_", "DYLD_", "CMUX_", "BASH_", "COMP_", "PROMPT_", "READLINE_", "COPROC", "LC_", "ZSH_"];

/// A value `cmux cloud secret set` would take: at least 8 Unicode scalars, at
/// most 16 KiB, one line, no NUL.
pub fn is_secret_value(value: &str) -> bool {
    value.chars().count() >= 8
        && value.len() <= MAX_VALUE_BYTES
        && !value.chars().any(|c| matches!(c, '\n' | '\r' | '\0'))
}

/// One `export NAME='value'` line per item, each `'` as `'\''`: the format
/// the terminal receiver wrote and `machine.env` sources.
pub fn render_env(values: &[(String, zeroize::Zeroizing<String>)]) -> zeroize::Zeroizing<String> {
    let mut out = zeroize::Zeroizing::new(String::new());
    for (name, value) in values {
        out.push_str("export ");
        out.push_str(name);
        out.push_str("='");
        for c in value.chars() {
            if c == '\'' {
                out.push_str("'\\''");
            } else {
                out.push(c);
            }
        }
        out.push_str("'\n");
    }
    out
}

/// The declared names in the applier's status, or `None` while it has not
/// finished an apply (or the file is missing or not that shape).
pub fn declared_names(status: &[u8]) -> Option<Vec<String>> {
    let root: serde_json::Value = serde_json::from_slice(status).ok()?;
    let state = root.get("state")?.as_str()?;
    if state != "done" && state != "failed" {
        return None;
    }
    root.get("secrets")?
        .get("declared")?
        .as_array()?
        .iter()
        .map(|name| name.as_str().map(str::to_owned))
        .collect()
}

/// Replace `home/relative` with `bytes`, mode 0600, without following a
/// symlink anywhere below `home`: each folder is opened relative to the one
/// above it with `O_NOFOLLOW` (made 0700 when missing), must be a folder this
/// user owns, and the last is set to 0700. The bytes go to a fresh file in
/// that folder, synced, then renamed over the target by the folder's
/// descriptor, so a reader sees the old file or the new one and no path is
/// resolved twice.
#[cfg(unix)]
pub fn write_private_atomic(home: &Path, relative: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::ffi::{CString, OsStr};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::path::Component;

    fn c_name(name: &OsStr) -> io::Result<CString> {
        CString::new(name.as_bytes()).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
    }
    fn check(result: libc::c_int) -> io::Result<libc::c_int> {
        if result < 0 { Err(io::Error::last_os_error()) } else { Ok(result) }
    }
    fn open_dir_at(parent: libc::c_int, name: &CString) -> io::Result<OwnedFd> {
        let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: `name` is NUL-terminated; a non-negative result is an owned fd.
        let fd = check(unsafe { libc::openat(parent, name.as_ptr(), flags) })?;
        // SAFETY: `fd` was just opened and is owned by nobody else.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }
    fn owned_by_us(fd: &OwnedFd) -> io::Result<()> {
        let mut status = std::mem::MaybeUninit::<libc::stat>::uninit();
        // SAFETY: `status` is a valid out pointer for fstat.
        check(unsafe { libc::fstat(fd.as_raw_fd(), status.as_mut_ptr()) })?;
        // SAFETY: fstat succeeded, so `status` is initialized.
        let status = unsafe { status.assume_init() };
        // SAFETY: geteuid has no preconditions and cannot fail.
        if status.st_uid != unsafe { libc::geteuid() } {
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, "folder is not ours"));
        }
        Ok(())
    }

    let mut names = Vec::new();
    for component in relative.components() {
        match component {
            Component::Normal(name) => names.push(c_name(name)?),
            _ => return Err(io::Error::new(io::ErrorKind::InvalidInput, "not a plain path")),
        }
    }
    let file_name =
        names.pop().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "no file name"))?;
    let home = c_name(home.as_os_str())?;
    let mut directory = open_dir_at(libc::AT_FDCWD, &home)?;
    owned_by_us(&directory)?;
    for name in &names {
        // SAFETY: `name` is NUL-terminated and `directory` is an open folder.
        let made = unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o700) };
        if made < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::AlreadyExists {
                return Err(error);
            }
        }
        directory = open_dir_at(directory.as_raw_fd(), name)?;
        owned_by_us(&directory)?;
    }
    // SAFETY: `directory` is an open folder this user owns.
    check(unsafe { libc::fchmod(directory.as_raw_fd(), 0o700) })?;

    let suffix =
        super::seal::fresh_nonce().map_err(|_| io::Error::other("no system random source"))?;
    let mut temporary = b".".to_vec();
    temporary.extend_from_slice(file_name.as_bytes());
    temporary.extend_from_slice(format!(".{suffix}.tmp").as_bytes());
    let temporary =
        CString::new(temporary).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    let flags = libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: `temporary` is NUL-terminated; mode is passed as the variadic third argument.
    let fd = check(unsafe {
        libc::openat(directory.as_raw_fd(), temporary.as_ptr(), flags, 0o600 as libc::c_uint)
    })?;
    // SAFETY: `fd` was just opened and is owned by nobody else.
    let mut file = std::fs::File::from(unsafe { OwnedFd::from_raw_fd(fd) });
    let result = (|| {
        file.write_all(bytes)?;
        file.sync_all()?;
        // SAFETY: both names are NUL-terminated and relative to the same open folder.
        check(unsafe {
            libc::renameat(
                directory.as_raw_fd(),
                temporary.as_ptr(),
                directory.as_raw_fd(),
                file_name.as_ptr(),
            )
        })?;
        // SAFETY: `directory` is an open folder.
        check(unsafe { libc::fsync(directory.as_raw_fd()) }).map(|_| ())
    })();
    if result.is_err() {
        // SAFETY: `temporary` is NUL-terminated and relative to the open folder.
        unsafe { libc::unlinkat(directory.as_raw_fd(), temporary.as_ptr(), 0) };
    }
    result
}

#[cfg(not(unix))]
pub fn write_private_atomic(_: &Path, _: &Path, _: &[u8]) -> io::Result<()> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "secrets-v1 writes need Unix"))
}

/// Every file `secrets-v1` may write under `home`: the machine secrets and
/// the harness login files. A write to any other path is refused.
pub fn allowed_paths(home: &Path) -> Vec<PathBuf> {
    let mut paths = vec![home.join(MACHINE_SECRETS_FILE)];
    for login in super::harness::HarnessLogin::ALL {
        paths.extend(login.paths(home));
    }
    paths
}

/// [`write_private_atomic`], only to a path [`allowed_paths`] lists.
pub fn write_allowed(home: &Path, path: &Path, bytes: &[u8]) -> io::Result<()> {
    if !allowed_paths(home).iter().any(|allowed| allowed == path) {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "path outside secrets-v1"));
    }
    let relative = path
        .strip_prefix(home)
        .map_err(|_| io::Error::new(io::ErrorKind::PermissionDenied, "path outside secrets-v1"))?;
    write_private_atomic(home, relative, bytes)
}
