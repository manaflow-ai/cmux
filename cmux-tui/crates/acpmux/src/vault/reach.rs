//! What a Cloud chat's daemon and agents can reach after it moves to its VM (AutoCloud proof plan R10: "the moved
//! chat carries the owner's login and nothing else"). `acpmux machine vault audit` runs it as the work user, the
//! user the daemon and its agents run as, so "reachable" means reachable by that user: the environment of this
//! machine's acpmux daemon (`daemon.pid`) and of every process under it (its agent hosts and harnesses, read one
//! pid at a time through `agent_host::tree`, no listing of its own), and the credential files below.
//!
//! It prints names and paths only, never a value: a value is looked at only to see whether it starts like a
//! credential (`cmm_`, `sk-`, `ghp_`), and is dropped without being copied or logged. It fails closed: a folder or
//! file it cannot read for any reason but "not there" or "not allowed" makes the audit an error, never a pass.
//!
//! The rule, one line per thing a VM can hold:
//!
//! | Thing | Class | Allowed when |
//! |---|---|---|
//! | `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CMUX_CHATGPT_ACCESS_TOKEN` in an env | owner's harness login | always (`agent_credentials::NAMES`) |
//! | `~/.claude/.credentials.json`, `~/.codex/auth.json`, `$CLAUDE_CONFIG_DIR/.credentials.json` | owner's harness login | always |
//! | `ACPMUX_LAUNCH_CREDENTIAL` | marker (names only) | always |
//! | `/run/cmux-inference-gateway/token` | machine identity (this install's minutes-lived token) | the person's opt-in marker `~/.config/cmux/inference-gateway/enabled` exists |
//! | `/var/lib/cmux/install/platform-scope-key.json`, `identity.json`'s key | machine identity (this VM's install key) | the work user cannot read it |
//! | `/var/lib/cmux/install/platform-scope-identity.json`, `identity.json` | machine identity (receipts) | always |
//! | `$ACPMUX_HOME/machine-credential.json` (`host join`) | machine identity (revocable per machine) | always; what it pulls is judged by the vault row |
//! | `$ACPMUX_HOME/vault-state.json` entries | the person's vault: user secrets | never (each name is a finding) |
//! | `~/.config/cmux/machine.env`, `machine-secrets.env` secret-shaped names | the person's declared secrets | never (each name is a finding) |
//! | `/var/lib/cmux/harness-login-sync.json` | obsolete state cmux-host removes at bind (`role.rs`) | never |
//! | any other secret-shaped env name or value, or `~/.ssh/id_*`, `~/.git-credentials`, `~/.netrc`, `~/.config/gh/hosts.yml`, `~/.aws/credentials`, `~/.docker/config.json`, `~/.npmrc` | unknown | never |
//!
//! Secret-shaped env: a name containing TOKEN, KEY, SECRET, PASSWORD or CREDENTIAL, or a value starting `cmm_`,
//! `sk-` or `ghp_`.

use serde::Serialize;
use std::collections::BTreeSet;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

/// The owner's harness login: the names a Cloud chat's launch credential carries.
pub const LOGIN_NAMES: [&str; 4] = crate::agent_credentials::NAMES;
/// Names that match the shape but hold no secret.
const NOT_SECRET: [&str; 2] = [crate::agent_credentials::MARKER, "SSH_AUTH_SOCK"];
const NAME_WORDS: [&str; 5] = ["TOKEN", "KEY", "SECRET", "PASSWORD", "CREDENTIAL"];
const VALUE_PREFIXES: [&str; 3] = ["cmm_", "sk-", "ghp_"];
const MAX_STATE: u64 = 4 << 20;

pub const GATEWAY_TOKEN: &str = cmux_host::cloud::gateway_token::TOKEN_FILE;
pub const INSTALL_KEYS: [&str; 1] = ["/var/lib/cmux/install/platform-scope-key.json"];
pub const INSTALL_RECEIPTS: [&str; 2] =
    ["/var/lib/cmux/install/platform-scope-identity.json", "/var/lib/cmux/install/identity.json"];
pub const OLD_LOGIN_SYNC: &str = "/var/lib/cmux/harness-login-sync.json";
/// Beside `machine.env`: the secrets file it sources (cmux-remote `secrets/files.rs`).
pub const MACHINE_SECRETS: &str = "machine-secrets.env";
/// Beside `machine.env`: a shared team Claude login (cloud-journey's sign-in probe reads it).
pub const TEAM_LOGIN: &str = "claude-team/.credentials.json";
pub const LOGIN_FILES: [&str; 2] = [".claude/.credentials.json", ".codex/auth.json"];
pub const OTHER_FILES: [&str; 6] = [
    ".git-credentials",
    ".netrc",
    ".config/gh/hosts.yml",
    ".aws/credentials",
    ".docker/config.json",
    ".npmrc",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Class {
    /// The owner's harness login: allowed.
    Login,
    /// Scoped to this VM, not the person: allowed under its row's rule.
    Machine,
    /// Anything else: a finding.
    Leak,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize)]
pub struct Item {
    pub class: Class,
    /// `env:NAME`, `file:PATH` or `vault:NAME`.
    pub what: String,
    /// Where it was seen: `pid N (comm)`, a path, or a short reason.
    pub at: String,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub items: Vec<Item>,
    pub processes: usize,
    /// Same-user processes whose environment could not be read (gone, or not dumpable).
    pub unreadable: usize,
    pub elapsed_ms: f64,
}

impl Report {
    pub fn findings(&self) -> impl Iterator<Item = &Item> {
        self.items.iter().filter(|i| i.class == Class::Leak)
    }
    pub fn green(&self) -> bool {
        self.findings().next().is_none()
    }
}

/// One process the audit reads: the daemon or a process under it, and the environment it was
/// started with (`None`: it ended, or it is another user's).
pub struct Proc {
    pub pid: u32,
    pub role: &'static str,
    pub env: Option<Vec<(String, String)>>,
}

/// This machine's acpmux daemon and every process under it. Fails closed with no running daemon:
/// after a move there must be one, and an audit of nothing is no pass.
pub fn live_processes() -> io::Result<Vec<Proc>> {
    use crate::agent_host::tree;
    let daemon = crate::cli::process_owner::daemon_pid()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no acpmux daemon.pid"))?;
    let env = tree::environ(daemon).ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, "the acpmux daemon is not running or not readable")
    })?;
    let mut out = vec![Proc { pid: daemon, role: "daemon", env: Some(env) }];
    for p in tree::descendants(&[daemon]) {
        out.push(Proc { pid: p.pid, role: "agent", env: tree::environ(p.pid) });
    }
    Ok(out)
}

/// Where to look; [`Roots::live`] on a machine, a scratch tree in tests.
pub struct Roots {
    /// The work user's home.
    pub home: PathBuf,
    /// `$ACPMUX_HOME`.
    pub acpmux_home: PathBuf,
    /// Prefixed to every absolute machine path (`/` live).
    pub root: PathBuf,
    /// `$CLAUDE_CONFIG_DIR`, when set.
    pub claude_config: Option<PathBuf>,
}

impl Roots {
    pub fn live() -> io::Result<Roots> {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .ok_or_else(|| io::Error::other("HOME is not an absolute path"))?;
        Ok(Roots {
            home,
            acpmux_home: crate::config::home(),
            root: PathBuf::from("/"),
            claude_config: std::env::var_os("CLAUDE_CONFIG_DIR").map(PathBuf::from),
        })
    }
    fn at(&self, abs: &str) -> PathBuf {
        self.root.join(abs.trim_start_matches('/'))
    }
}

/// Whether an env entry is secret-shaped. Looks at the value's first bytes only.
pub fn secret_shaped(name: &str, value: &[u8]) -> bool {
    if NOT_SECRET.contains(&name) {
        return false;
    }
    let upper = name.to_ascii_uppercase();
    NAME_WORDS.iter().any(|w| upper.contains(w))
        || VALUE_PREFIXES.iter().any(|p| value.starts_with(p.as_bytes()))
}

fn env_class(name: &str) -> Class {
    if LOGIN_NAMES.contains(&name) { Class::Login } else { Class::Leak }
}

/// Runs the audit. `Err` is a fail-closed error: the audit could not see what it must.
pub fn audit(roots: &Roots, procs: impl FnOnce() -> io::Result<Vec<Proc>>) -> io::Result<Report> {
    let started = std::time::Instant::now();
    let mut report = Report::default();
    let mut items = BTreeSet::new();
    read_processes(procs()?, &mut report, &mut items);
    scan_files(roots, &mut items)?;
    report.items = items.into_iter().collect();
    report.elapsed_ms = started.elapsed().as_secs_f64() * 1000.0;
    Ok(report)
}

fn read_processes(procs: Vec<Proc>, report: &mut Report, items: &mut BTreeSet<Item>) {
    for p in procs {
        report.processes += 1;
        let Some(env) = p.env else {
            report.unreadable += 1;
            continue;
        };
        let at = format!("pid {} ({})", p.pid, p.role);
        for (name, value) in env {
            let value = zeroize::Zeroizing::new(value);
            if secret_shaped(&name, value.as_bytes()) {
                let what = format!("env:{name}");
                items.insert(Item { class: env_class(&name), what, at: at.clone() });
            }
        }
    }
}

/// `Ok(true)`: the work user can open it for reading. `Ok(false)`: not there, or not allowed.
fn readable(path: &Path) -> io::Result<bool> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NONBLOCK);
    }
    match options.open(path) {
        Ok(_) => Ok(true),
        Err(e) if matches!(e.kind(), io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied) => {
            Ok(false)
        }
        Err(e) if e.raw_os_error() == Some(libc::ENOTDIR) => Ok(false),
        Err(e) => Err(e),
    }
}

fn exists(path: &Path) -> io::Result<bool> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(e) if matches!(e.kind(), io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied) => {
            Ok(false)
        }
        Err(e) if e.raw_os_error() == Some(libc::ENOTDIR) => Ok(false),
        Err(e) => Err(e),
    }
}

fn file(items: &mut BTreeSet<Item>, class: Class, path: &Path, at: &str) {
    items.insert(Item { class, what: format!("file:{}", path.display()), at: at.to_owned() });
}

fn scan_files(roots: &Roots, items: &mut BTreeSet<Item>) -> io::Result<()> {
    let mut logins: Vec<PathBuf> = LOGIN_FILES.iter().map(|f| roots.home.join(f)).collect();
    if let Some(dir) = &roots.claude_config {
        logins.push(dir.join(".credentials.json"));
    }
    for path in logins {
        if readable(&path)? {
            file(items, Class::Login, &path, "harness login");
        }
    }
    let gateway = roots.at(GATEWAY_TOKEN);
    if readable(&gateway)? {
        let opted_in = exists(&cmux_host::cloud::gateway_token::marker(&roots.home))?;
        let (class, why) = if opted_in {
            (Class::Machine, "gateway token, opted in")
        } else {
            (Class::Leak, "gateway token without the opt-in marker")
        };
        file(items, class, &gateway, why);
    }
    for key in INSTALL_KEYS {
        let path = roots.at(key);
        if readable(&path)? {
            file(items, Class::Leak, &path, "install key readable by the work user");
        }
    }
    for receipt in INSTALL_RECEIPTS {
        let path = roots.at(receipt);
        if readable(&path)? {
            file(items, Class::Machine, &path, "install receipt");
        }
    }
    let old = roots.at(OLD_LOGIN_SYNC);
    if exists(&old)? {
        file(items, Class::Leak, &old, "obsolete harness login state, removed at bind");
    }
    let join = roots.acpmux_home.join("machine-credential.json");
    if readable(&join)? {
        file(items, Class::Machine, &join, "machine join credential");
    }
    for name in vault_names(&roots.acpmux_home.join(crate::vault::pull::STATE_FILE))? {
        items.insert(Item {
            class: Class::Leak,
            what: format!("vault:{name}"),
            at: "vault-state.json".to_owned(),
        });
    }
    let machine_env = crate::login_env::machine_env_path(&roots.home);
    let team_login = machine_env.with_file_name(TEAM_LOGIN);
    if readable(&team_login)? {
        file(items, Class::Leak, &team_login, "shared team login, not the owner's");
    }
    for path in [machine_env.clone(), machine_env.with_file_name(MACHINE_SECRETS)] {
        for name in env_file_names(&path)? {
            if secret_shaped(&name, b"") {
                let at = path.display().to_string();
                items.insert(Item { class: env_class(&name), what: format!("env:{name}"), at });
            }
        }
    }
    for rel in OTHER_FILES {
        let path = roots.home.join(rel);
        if readable(&path)? {
            file(items, Class::Leak, &path, "credential file");
        }
    }
    let ssh = roots.home.join(".ssh");
    match std::fs::read_dir(&ssh) {
        Ok(dir) => {
            for entry in dir {
                let entry = entry?;
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if name.starts_with("id_") && !name.ends_with(".pub") && readable(&entry.path())? {
                    file(items, Class::Leak, &entry.path(), "ssh private key");
                }
            }
        }
        Err(e) if matches!(e.kind(), io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied) => {
        }
        Err(e) => return Err(e),
    }
    Ok(())
}

/// Bounded, whole read of a file the work user may read; `None` when it is not there or not allowed.
fn read_small(path: &Path, max: u64) -> io::Result<Option<zeroize::Zeroizing<Vec<u8>>>> {
    let f = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) if matches!(e.kind(), io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied) => {
            return Ok(None);
        }
        Err(e) => return Err(e),
    };
    let mut bytes = zeroize::Zeroizing::new(Vec::new());
    f.take(max + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > max {
        return Err(io::Error::other(format!("{} is larger than the audit reads", path.display())));
    }
    Ok(Some(bytes))
}

/// The entry names of a vault state (it holds names, revisions and fingerprints, never values).
fn vault_names(path: &Path) -> io::Result<Vec<String>> {
    let Some(bytes) = read_small(path, MAX_STATE)? else { return Ok(Vec::new()) };
    let state: serde_json::Value = serde_json::from_slice(&bytes)
        .map_err(|_| io::Error::other(format!("{} is not JSON", path.display())))?;
    let names = state
        .get("env")
        .and_then(|e| e.as_object())
        .map(|m| m.keys().cloned().collect())
        .unwrap_or_default();
    Ok(names)
}

/// The names an env file declares (`NAME=` or `export NAME=` lines); values are never kept.
fn env_file_names(path: &Path) -> io::Result<Vec<String>> {
    let Some(bytes) = read_small(path, MAX_STATE)? else { return Ok(Vec::new()) };
    let text = String::from_utf8_lossy(&bytes);
    Ok(text
        .lines()
        .filter_map(|line| {
            let line = line.trim_start();
            let line = line.strip_prefix("export ").unwrap_or(line);
            let (name, _) = line.split_once('=')?;
            let ok = !name.is_empty()
                && name.bytes().next().is_some_and(|b| b.is_ascii_alphabetic() || b == b'_')
                && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
            ok.then(|| name.to_owned())
        })
        .collect())
}

#[cfg(test)]
#[path = "reach_tests.rs"]
mod tests;
