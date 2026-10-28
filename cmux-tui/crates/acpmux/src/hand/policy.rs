//! The hand's own decision for each request, made on this machine.
//!
//! The Cloud checks who may call a hand; the hand checks what that call may
//! touch. A path is resolved (symlinks followed for the part that exists)
//! before it is compared with a root, so `root/link -> /etc` is outside.

use super::config::{HandConfig, Profile};
use std::path::{Component, Path, PathBuf};

#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    Allow,
    /// Runs only after the owner approves this one request (`mac` profile).
    Ask,
    Deny(String),
}

/// Words of a program run that are clearly destructive on a person's Mac:
/// these are refused on the hand itself, whatever the Cloud's classifier says.
fn destructive_exec(argv: &[String], home: Option<&Path>) -> Option<String> {
    let line = argv.join(" ");
    let words: Vec<&str> = line
        .split(|c: char| c.is_whitespace() || c == ';' || c == '&' || c == '|')
        .filter(|w| !w.is_empty())
        .collect();
    let home = home.map(|h| h.to_string_lossy().trim_end_matches('/').to_owned());
    let is_root_target = |w: &str| {
        let w = w.trim_matches(|c| c == '"' || c == '\'');
        matches!(
            w,
            "/" | "/*"
                | "~"
                | "~/"
                | "~/*"
                | "$HOME"
                | "$HOME/"
                | "$HOME/*"
                | "${HOME}"
                | "${HOME}/"
                | "/Users"
                | "/System"
                | "/Applications"
                | "/Library"
                | "/usr"
                | "/bin"
                | "/etc"
        ) || home
            .as_deref()
            .is_some_and(|h| w == h || w == format!("{h}/") || w == format!("{h}/*"))
    };
    for (i, w) in words.iter().enumerate() {
        let base = w.rsplit('/').next().unwrap_or(w);
        let rest = words.get(i + 1..).unwrap_or_default();
        match base {
            "rm" | "srm" => {
                let recursive = rest.iter().any(|a| {
                    a.starts_with('-')
                        && !a.starts_with("--")
                        && (a.contains('r') || a.contains('R'))
                        || *a == "--recursive"
                });
                if recursive && rest.iter().any(|a| is_root_target(a)) {
                    return Some(format!("{line:.120}: removes the home folder or the disk"));
                }
            }
            "find"
                if rest.iter().take(3).any(|a| is_root_target(a))
                    && rest.iter().any(|a| *a == "-delete" || *a == "rm") =>
            {
                return Some("find deletes from the home folder or the disk".into());
            }
            "mkfs" | "newfs_apfs" | "newfs_hfs" | "fdisk" | "gpt" => {
                return Some(format!("{base} formats a disk"));
            }
            "diskutil"
                if rest.iter().any(|a| {
                    a.starts_with("erase")
                        || a.starts_with("zero")
                        || *a == "secureErase"
                        || *a == "partitionDisk"
                        || a.starts_with("reformat")
                }) =>
            {
                return Some("diskutil erases or repartitions a disk".into());
            }
            "dd" if rest.iter().any(|a| a.starts_with("of=/dev/")) => {
                return Some("dd writes to a raw disk".into());
            }
            _ if base.starts_with(":(){") => return Some("a fork bomb".into()),
            _ => {}
        }
    }
    None
}

/// `p` with symlinks resolved when it exists (the form `resolve` gives).
fn canon(p: PathBuf) -> PathBuf {
    std::fs::canonicalize(&p).unwrap_or(p)
}

/// Folders and files of the hand itself and of the agent daemon it drives:
/// a request that changes them could switch off this policy.
fn self_paths() -> Vec<PathBuf> {
    // The person's own agent daemon home too (the hand's daemon has its own, below the hand home).
    let mut out = vec![super::config::home(), crate::config::home(), crate::config::default_home()];
    if let Some(h) = dirs::home_dir() {
        out.push(h.join("Library/LaunchAgents/dev.cmux.hand.plist"));
        out.push(h.join(".config/systemd/user/cmux-hand.service"));
        out.push(h.join(".config/cmux"));
    }
    if let Ok(exe) = std::env::current_exe() {
        out.push(exe);
    }
    out.into_iter().map(canon).collect()
}

/// Paths a write may never touch on a person's Mac: raw disks, the system
/// volume, and the hand's own files (its config, key, binary, service).
fn destructive_path(action: &str, p: &Path) -> Option<String> {
    let writes = matches!(action, "fs.write" | "fs.edit" | "fs.patch");
    let s = p.to_string_lossy();
    if writes && (s.starts_with("/dev/") || s.starts_with("/System/") || s == "/System") {
        return Some(format!("{s}: a disk device or the system volume"));
    }
    if writes && self_paths().iter().any(|own| p.starts_with(own)) {
        return Some(format!("{s}: the hand's own files"));
    }
    None
}

/// Credential, startup and profile places under the home folder.
const UNDER_HOME: &[&str] = &[
    ".ssh",
    ".aws",
    ".gnupg",
    ".netrc",
    ".docker/config.json",
    ".kube",
    ".config/gh",
    ".config/gcloud",
    ".azure",
    ".npmrc",
    ".pypirc",
    ".gitconfig",
    ".git-credentials",
    ".zshrc",
    ".zprofile",
    ".zshenv",
    ".bashrc",
    ".bash_profile",
    ".profile",
    "Library/Keychains",
    "Library/LaunchAgents",
    "Library/Cookies",
    "Library/Application Support/Google/Chrome",
    "Library/Application Support/Firefox",
    "Library/Application Support/BraveSoftware",
    "Library/Safari",
];

/// Paths that always need the owner's answer on a mac hand, whatever the
/// host's verdict: credentials, keychains, shell startup files, launch agents,
/// git config and hooks.
fn sensitive_path(p: &Path) -> bool {
    let Some(home) = dirs::home_dir().map(canon) else { return false };
    UNDER_HOME
        .iter()
        .any(|rel| p.starts_with(home.join(rel)) || p.starts_with(canon(home.join(rel))))
        || p.to_string_lossy().contains("/.git/hooks")
        || p.starts_with("/Library/LaunchAgents")
        || p.starts_with("/Library/LaunchDaemons")
}

/// Whether `root` contains a sensitive or own path (a walk from it reaches one).
fn holds_protected(root: &Path, own: &[PathBuf]) -> bool {
    if own.iter().any(|o| o.starts_with(root)) {
        return true;
    }
    let Some(home) = dirs::home_dir().map(canon) else { return false };
    home.starts_with(root)
        || UNDER_HOME
            .iter()
            .any(|d| canon(home.join(d)).starts_with(root) || home.join(d).starts_with(root))
        || Path::new("/Library/LaunchAgents").starts_with(root)
        || Path::new("/Library/LaunchDaemons").starts_with(root)
}

/// Whether a command line names one of the hand's own folders: the hand home
/// and the agent daemon home, as their resolvers name them (config::home(),
/// crate::config::home()), by full path or by folder name.
fn names_own_files(line: &str) -> bool {
    [super::config::home(), crate::config::home(), crate::config::default_home()].iter().any(
        |own| {
            line.contains(own.to_string_lossy().as_ref())
                || own.file_name().is_some_and(|n| line.contains(n.to_string_lossy().as_ref()))
        },
    )
}

/// An exec whose words name a sensitive or protected path (best effort: a
/// command can always build a path the hand cannot see).
fn sensitive_exec(argv: &[String]) -> bool {
    let line = argv.join(" ");
    let home = dirs::home_dir().map(|h| h.to_string_lossy().into_owned()).unwrap_or_default();
    [
        ".ssh",
        ".aws",
        ".gnupg",
        "Keychains",
        "LaunchAgents",
        ".cmux-hand",
        // Security classifier keyword: this detects commands targeting the shared ACPmux home;
        // it is not a path construction or a product state-root resolver.
        ".acpmux",
        "security ",
        "sudo ",
        "defaults write",
        "launchctl",
        "osascript",
    ]
    .iter()
    .any(|w| line.contains(w))
        || (!home.is_empty() && (line.contains(&format!("{home}/.")) || line.contains("~/.")))
        || names_own_files(&line)
}

/// `path` made absolute against `cwd` and resolved the way the OS will open
/// it: one component at a time, each existing component replaced by its
/// canonical form (symlinks followed) before a later `..` applies, so
/// `root/link/../x` with `link -> /etc/ssh` resolves to `/etc/x`. Components
/// that do not exist yet are kept as written.
pub fn resolve(path: &str, cwd: Option<&Path>) -> Result<PathBuf, String> {
    if path.is_empty() {
        return Err("empty path".into());
    }
    let p = Path::new(path);
    let joined = if p.is_absolute() {
        p.to_path_buf()
    } else {
        match cwd {
            Some(c) => c.join(p),
            None => return Err(format!("{path}: a relative path needs cwd")),
        }
    };
    let mut cur = PathBuf::new();
    for c in joined.components() {
        match c {
            Component::Prefix(_) | Component::RootDir => cur.push(c.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                cur.pop();
            }
            Component::Normal(name) => {
                let next = cur.join(name);
                cur = if std::fs::symlink_metadata(&next).is_ok() {
                    std::fs::canonicalize(&next).map_err(|e| format!("{}: {e}", next.display()))?
                } else {
                    next
                };
            }
        }
    }
    Ok(cur)
}

fn inside(path: &Path, root: &Path) -> bool {
    let root = std::fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
    path.starts_with(&root)
}

/// A hand's permission level (set by its owner in the Cloud; a Chief may only
/// lower it). `Full`: only the integrity guard (the hand's own key, config and
/// binary). `Auto`: the classifier's verdict, the hard denies and the asks.
/// `Ask`: every write, program run and agent session asks. `ReadOnly`: reads only.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    Full,
    Auto,
    Ask,
    ReadOnly,
}

impl Level {
    /// The request's level, else the profile's default (sandbox: full, mac: auto).
    /// An unknown name is the strictest level, never a looser one.
    pub fn of(given: Option<&str>, profile: Profile) -> Self {
        match given {
            None => match profile {
                Profile::Sandbox => Self::Full,
                Profile::Mac => Self::Auto,
            },
            Some("full") => Self::Full,
            Some("auto") => Self::Auto,
            Some("ask") => Self::Ask,
            _ => Self::ReadOnly,
        }
    }
}

/// Actions that only read.
/// Reads, and the controls that only stop or refuse agent work.
const READ_ACTIONS: &[&str] = &[
    "fs.read",
    "fs.list",
    "fs.glob",
    "fs.grep",
    "agent.events",
    "agent.cancel",
    "agent.stop",
    "agent.deny",
];

/// The decision for `action` on `paths` (already resolved). `level` and
/// `verdict` come from the Cloud with the request (`_level`, `_verdict`); `argv`
/// is the program of an `exec`.
pub fn decide(
    cfg: &HandConfig,
    action: &str,
    paths: &[PathBuf],
    level: Option<&str>,
    verdict: Option<&str>,
    argv: Option<&[String]>,
) -> Decision {
    for p in paths {
        if !cfg.roots.iter().any(|r| inside(p, r)) {
            return Decision::Deny(format!(
                "{} is outside the hand's approved folders",
                p.display()
            ));
        }
    }
    // The integrity guard, at every level and on every profile: the hand's own key,
    // config, binary and service, and the agent daemon it drives, are never touched.
    // It protects the account, not the person's files.
    let own = self_paths();
    if paths.iter().any(|p| own.iter().any(|o| p.starts_with(o))) {
        return Decision::Deny("the hand's own files".into());
    }
    if argv.is_some_and(|a| names_own_files(&a.join(" "))) {
        return Decision::Deny("the command touches the hand's own files".into());
    }
    let level = Level::of(level, cfg.profile);
    let read = READ_ACTIONS.contains(&action);
    match level {
        Level::Full => return Decision::Allow,
        Level::ReadOnly if !read => {
            return Decision::Deny(format!("{action}: this hand is read-only"));
        }
        _ => {}
    }
    // The hard denies (auto, ask, read-only): a host that says allow cannot skip them.
    if let Some(why) = argv.and_then(|a| destructive_exec(a, dirs::home_dir().as_deref())) {
        return Decision::Deny(why);
    }
    if let Some(why) = paths.iter().find_map(|p| destructive_path(action, p)) {
        return Decision::Deny(why);
    }
    // A search, list or program run over a folder that holds credentials or the
    // hand's files asks first: it would walk into them.
    if matches!(action, "fs.grep" | "fs.glob" | "fs.list" | "exec" | "agent.start")
        && paths.iter().any(|root| holds_protected(root, &own))
    {
        return Decision::Ask;
    }
    // Credentials, startup files and the like: always the owner's answer.
    if paths.iter().any(|p| sensitive_path(p)) || argv.is_some_and(sensitive_exec) {
        return Decision::Ask;
    }
    match level {
        Level::ReadOnly => Decision::Allow,
        Level::Ask if !read => Decision::Ask,
        _ => {
            // A local allow rule, or the classifier's allow, runs at once; anything else
            // (ask, no verdict, an unknown one) waits for the owner.
            let covered = |p: &PathBuf| {
                cfg.allow.iter().any(|rule| {
                    inside(p, &rule.path) && rule.actions.iter().any(|a| a == "*" || a == action)
                })
            };
            if verdict == Some("allow") || (!paths.is_empty() && paths.iter().all(covered)) {
                Decision::Allow
            } else {
                Decision::Ask
            }
        }
    }
}
