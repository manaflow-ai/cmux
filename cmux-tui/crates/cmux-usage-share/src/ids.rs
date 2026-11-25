//! Hashed ids: `sha256(salt || value)`, its first 24 hex. The salt is random per install and never
//! leaves the machine, so the server can group by an id but not reverse it, and two installs hash
//! the same session or repository differently. The install id is the same hash of a random
//! install uuid kept beside the salt.

use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};

/// The salt file: two lines, the salt (64 hex) and the install uuid (32 hex).
pub const SALT_FILE: &str = "salt";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    salt: String,
    /// The install id the uploads name (24 hex).
    pub install: String,
}

impl Identity {
    /// An identity from a known salt and install secret (tests).
    pub fn from_parts(salt: &str, install_secret: &str) -> Self {
        let salt = salt.to_owned();
        let install = hash_with(&salt, install_secret);
        Self { salt, install }
    }

    /// `value` hashed with this install's salt.
    pub fn hash(&self, value: &str) -> String {
        hash_with(&self.salt, value)
    }

    /// The identity kept in `dir`, made (and written 0600) on first use. None when the folder
    /// cannot be made or the file cannot be read or written.
    pub fn load_or_create(dir: &Path) -> Option<Self> {
        let path = dir.join(SALT_FILE);
        if let Ok(text) = std::fs::read_to_string(&path) {
            let mut lines = text.lines().map(str::trim);
            if let (Some(salt), Some(secret)) = (lines.next(), lines.next())
                && is_hex(salt, 64)
                && is_hex(secret, 32)
            {
                return Some(Self::from_parts(salt, secret));
            }
        }
        crate::spool::private_dir(dir).ok()?;
        let salt = random_hex::<32>()?;
        let secret = random_hex::<16>()?;
        write_private_new(&path, format!("{salt}\n{secret}\n").as_bytes()).ok()?;
        // Another process may have won the race: read back what is on disk.
        let text = std::fs::read_to_string(&path).ok()?;
        let mut lines = text.lines().map(str::trim);
        match (lines.next(), lines.next()) {
            (Some(salt), Some(secret)) if is_hex(salt, 64) && is_hex(secret, 32) => {
                Some(Self::from_parts(salt, secret))
            }
            _ => None,
        }
    }
}

fn hash_with(salt: &str, value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(salt.as_bytes());
    hasher.update(value.as_bytes());
    let mut hex = hex::encode(hasher.finalize());
    hex.truncate(24);
    hex
}

fn is_hex(text: &str, len: usize) -> bool {
    text.len() == len && text.bytes().all(|b| b.is_ascii_hexdigit())
}

fn random_hex<const N: usize>() -> Option<String> {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes).ok()?;
    Some(hex::encode(bytes))
}

/// Writes `bytes` to a new 0600 file at `path`, replacing one that holds no valid identity.
fn write_private_new(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = tmp_path(path);
    {
        let mut file = crate::spool::open_private(&tmp, false)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    std::fs::rename(&tmp, path)
}

pub(crate) fn tmp_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().map(|n| n.to_os_string()).unwrap_or_default();
    name.push(format!(".{}.tmp", std::process::id()));
    path.with_file_name(name)
}

/// A git remote URL in one form for every way of writing it: host and path, lowercase host, no
/// scheme, user, port, trailing slash or `.git`. `git@github.com:Org/Repo.git`,
/// `https://github.com/Org/Repo` and `ssh://git@github.com/Org/Repo.git` all give
/// `github.com/Org/Repo`. None for a local path.
pub fn normalize_remote(url: &str) -> Option<String> {
    let url = url.trim();
    let (host, path) = if let Some((_, rest)) = url.split_once("://") {
        let (authority, path) = rest.split_once('/')?;
        let host = authority.rsplit('@').next().unwrap_or(authority);
        let host = host.split(':').next().unwrap_or(host);
        (host, path)
    } else if let Some((before, path)) = url.split_once(':') {
        // scp form: [user@]host:path. A Windows drive (`C:\...`) or a path is not one.
        if before.contains('/') || before.len() < 2 {
            return None;
        }
        (before.rsplit('@').next().unwrap_or(before), path)
    } else {
        return None;
    };
    let path = path.trim_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    if host.is_empty() || path.is_empty() {
        return None;
    }
    Some(format!("{}/{}", host.to_ascii_lowercase(), path))
}

/// The `origin` remote URL of the git repository holding `cwd`, read from its config (a worktree's
/// `.git` file and `commondir` followed), without running git. None outside a repository or with
/// no origin.
pub fn origin_url(cwd: &Path) -> Option<String> {
    let git = cwd.ancestors().map(|dir| dir.join(".git")).find(|p| p.exists())?;
    let mut git_dir = git.clone();
    if git.is_file() {
        let text = std::fs::read_to_string(&git).ok()?;
        let target = text.lines().find_map(|l| l.strip_prefix("gitdir:"))?.trim();
        git_dir = git.parent()?.join(target);
    }
    if let Ok(common) = std::fs::read_to_string(git_dir.join("commondir")) {
        git_dir = git_dir.join(common.trim());
    }
    let config = std::fs::read_to_string(git_dir.join("config")).ok()?;
    origin_in_config(&config)
}

/// `remote "origin"`'s `url` in a git config's text.
pub fn origin_in_config(config: &str) -> Option<String> {
    let mut in_origin = false;
    for line in config.lines().map(str::trim) {
        if line.starts_with('[') {
            let header: String = line.chars().filter(|c| !c.is_whitespace()).collect();
            in_origin = header == "[remote\"origin\"]";
            continue;
        }
        if in_origin
            && let Some((key, value)) = line.split_once('=')
            && key.trim() == "url"
        {
            return Some(value.trim().to_owned());
        }
    }
    None
}
