//! The files `secrets-v1` writes: owner-only (0600) in owner-only (0700)
//! folders, replaced atomically by a rename, never through a symlink.

use std::io;
use std::path::{Path, PathBuf};

/// `~/.config/cmux/machine-secrets.env`, which the machine's `machine.env`
/// sources (`export NAME='value'` lines).
pub const MACHINE_SECRETS_FILE: &str = ".config/cmux/machine-secrets.env";
/// The machine config applier's status: the secret names `.cmux/machine.toml`
/// declares (`secrets.declared`).
pub const MACHINE_CONFIG_STATUS_FILE: &str = ".cmux/machine-config/status.json";
/// The largest machine-secrets.env the applier reads: 4 MiB.
pub const MAX_ENV_FILE_BYTES: usize = 4 << 20;
/// Names a machine takes without its machine config declaring them, once a
/// config has applied: the Mac sends each one it holds globally to every
/// machine (`CloudMachineSecrets.alwaysDelivered`, the same list). The
/// Claude setup token signs Claude Code in; cmux keeps it only in the Mac's
/// Keychain, never on its servers. The applier keeps them too (applier.py
/// `ALWAYS_DELIVERED`).
pub const ALWAYS_DELIVERED: &[&str] = &["CLAUDE_CODE_OAUTH_TOKEN"];

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

/// `~/.config/cmux/git-hosts`: one file per git host, the person's own token
/// for it (`git-host-tokens-v1`), read by `cmux gitlab credential` and, for
/// `github.com`, `cmux github credential` and `gh` (cmux-host `gitlab_cli.rs`
/// `TOKENS_DIR`, the same folder). Beside [`MACHINE_SECRETS_FILE`].
pub fn git_hosts_dir(home: &Path) -> PathBuf {
    let config = Path::new(MACHINE_SECRETS_FILE).parent().unwrap_or(Path::new(""));
    home.join(config).join("git-hosts")
}
/// The longest git host token taken (GitHub's and GitLab's are under 300 bytes).
pub const MAX_GIT_HOST_TOKEN_BYTES: usize = 4096;

/// A git host as a file name: a lowercase host of letters, digits, `.` and
/// `-` (not starting with `.` or `-`, no `..`) with an optional port.
pub fn is_git_host(authority: &str) -> bool {
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (authority, None),
    };
    !host.is_empty()
        && host.len() <= 253
        && !host.starts_with(['.', '-'])
        && !host.contains("..")
        && host
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'.' || b == b'-')
        && port
            .is_none_or(|p| !p.is_empty() && p.len() <= 5 && p.bytes().all(|b| b.is_ascii_digit()))
}

/// The token file for `host`, when it is a git host name.
pub fn git_host_path(home: &Path, host: &str) -> Option<PathBuf> {
    is_git_host(host).then(|| git_hosts_dir(home).join(host))
}

/// A token as one plain line: printable ASCII, no space, at most
/// [`MAX_GIT_HOST_TOKEN_BYTES`].
pub fn is_git_host_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_GIT_HOST_TOKEN_BYTES
        && value.bytes().all(|b| b.is_ascii_graphic())
}

/// Every file `secrets-v1` may write under `home`: the machine secrets, and
/// for a `git-host-tokens-v1` request the one host's token file. A write to
/// any other path is refused.
pub fn allowed_paths(home: &Path) -> Vec<PathBuf> {
    vec![home.join(MACHINE_SECRETS_FILE)]
}

/// [`allowed_paths`], with `host`'s token file.
fn allowed_with_host(home: &Path, host: Option<&str>) -> Vec<PathBuf> {
    let mut paths = allowed_paths(home);
    paths.extend(host.and_then(|host| git_host_path(home, host)));
    paths
}

/// Replace `path` with `bytes`, mode 0600 (see [`super::commit`]), only when
/// it is one [`allowed_paths`] lists. `_lock` is the request lock: every
/// write of `secrets-v1` happens under it.
pub fn write_allowed(lock: &super::Lock, home: &Path, path: &Path, bytes: &[u8]) -> io::Result<()> {
    write_allowed_for(lock, home, None, path, bytes)
}

/// [`write_allowed`] for a request that may also write `host`'s token file.
pub fn write_allowed_for(
    _lock: &super::Lock,
    home: &Path,
    host: Option<&str>,
    path: &Path,
    bytes: &[u8],
) -> io::Result<()> {
    if !allowed_with_host(home, host).iter().any(|allowed| allowed == path) {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "path outside secrets-v1"));
    }
    let relative = path
        .strip_prefix(home)
        .map_err(|_| io::Error::new(io::ErrorKind::PermissionDenied, "path outside secrets-v1"))?;
    replace(home, relative, bytes)
}

/// Remove `host`'s token file, when there is one. Never through a symlink:
/// the folders are checked as a write checks them, and the file is unlinked
/// by name (unlinking a symlink removes the link, not its target).
pub fn remove_git_host_token(_lock: &super::Lock, home: &Path, host: &str) -> io::Result<bool> {
    let path = git_host_path(home, host)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "not a git host"))?;
    let folder = git_hosts_dir(home);
    match std::fs::symlink_metadata(&folder) {
        Ok(meta) if meta.file_type().is_symlink() || !meta.is_dir() => {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "git-hosts is not a folder",
            ));
        }
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    }
    match std::fs::remove_file(&path) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
use super::commit::replace;

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn replace(_: &Path, _: &Path, _: &[u8]) -> io::Result<()> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "secrets-v1 writes need Linux"))
}
