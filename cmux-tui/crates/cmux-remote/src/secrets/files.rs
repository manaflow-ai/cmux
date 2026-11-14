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

/// Every file `secrets-v1` may write under `home`: the machine secrets. A
/// write to any other path is refused.
pub fn allowed_paths(home: &Path) -> Vec<PathBuf> {
    vec![home.join(MACHINE_SECRETS_FILE)]
}

/// Replace `path` with `bytes`, mode 0600 (see [`super::commit`]), only when
/// it is one [`allowed_paths`] lists. `_lock` is the request lock: every
/// write of `secrets-v1` happens under it.
pub fn write_allowed(
    _lock: &super::Lock,
    home: &Path,
    path: &Path,
    bytes: &[u8],
) -> io::Result<()> {
    if !allowed_paths(home).iter().any(|allowed| allowed == path) {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "path outside secrets-v1"));
    }
    let relative = path
        .strip_prefix(home)
        .map_err(|_| io::Error::new(io::ErrorKind::PermissionDenied, "path outside secrets-v1"))?;
    replace(home, relative, bytes)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
use super::commit::replace;

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn replace(_: &Path, _: &Path, _: &[u8]) -> io::Result<()> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "secrets-v1 writes need Linux"))
}
