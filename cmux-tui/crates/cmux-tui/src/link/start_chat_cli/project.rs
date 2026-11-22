//! Project identity is independent of workspace, transport, branch and send.
//! Local-only folders include a persisted installation ID, so equal paths on
//! different computers do not accidentally choose the same paid machine.

use std::io::Write as _;
use std::os::unix::fs::OpenOptionsExt as _;
use std::path::Path;

use anyhow::Context as _;
use sha2::{Digest as _, Sha256};

use super::{git_common_dir, ledger::Ledger, origin_url};

pub(super) fn normalize_key(key: &str) -> Option<String> {
    if let Some(remote) = key.strip_prefix("git:") {
        return remote_key(&format!("https://{remote}"));
    }
    let id = key.strip_prefix("folder:")?;
    (!id.is_empty()
        && id.len() <= 1024
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_')))
    .then(|| key.to_string())
}

/// Normalize network remotes only. Nonstandard ports and unsupported remotes
/// fall back to a folder ID rather than aliasing distinct servers.
pub(super) fn remote_key(remote: &str) -> Option<String> {
    let remote = remote.trim();
    if remote.is_empty() || remote.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return None;
    }
    let (host, path) = if let Some((scheme, rest)) = remote.split_once("://") {
        let standard_port = match scheme.to_ascii_lowercase().as_str() {
            "https" => "443",
            "http" => "80",
            "ssh" | "git+ssh" => "22",
            _ => return None,
        };
        let (authority, path) = rest.split_once('/')?;
        let authority = authority.rsplit('@').next()?;
        let host = match authority.split_once(':') {
            Some((host, port)) if port == standard_port => host,
            Some(_) => return None,
            None => authority,
        };
        (host, path)
    } else {
        let (authority, path) = remote.split_once(':')?;
        (authority.rsplit('@').next()?, path)
    };
    if host.is_empty()
        || !host.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.'))
        || host.split('.').any(|part| part.is_empty())
    {
        return None;
    }
    let path = path.trim_end_matches('/').to_ascii_lowercase();
    let path = path.strip_suffix(".git").unwrap_or(&path);
    if path.split('/').count() < 2
        || path.split('/').any(|part| {
            part.is_empty()
                || matches!(part, "." | "..")
                || !part
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        })
    {
        return None;
    }
    let key = format!("git:{}/{path}", host.to_ascii_lowercase());
    (key.len() <= 2048).then_some(key)
}

pub(super) fn folder_key(ledger: &Path, local: &str) -> anyhow::Result<Option<String>> {
    let folder = Path::new(local);
    if !folder.is_absolute() || !folder.is_dir() {
        return Ok(None);
    }
    let folder = folder.canonicalize().context("cannot resolve project folder")?;
    let common = git_common_dir(&folder);
    if let Some(key) = common
        .as_ref()
        .and_then(|dir| std::fs::read_to_string(dir.join("config")).ok())
        .and_then(|config| origin_url(&config))
        .and_then(|remote| remote_key(&remote))
    {
        return Ok(Some(key));
    }
    // Worktrees of a local repository still share its common directory.
    let identity =
        common.unwrap_or(folder).canonicalize().context("cannot resolve project identity")?;
    let installation = Ledger::update(ledger, |_| installation_id(ledger))??;
    let mut hash = Sha256::new();
    hash.update(installation.as_bytes());
    hash.update([0]);
    hash.update(identity.as_os_str().as_encoded_bytes());
    Ok(Some(format!("folder:{:x}", hash.finalize())))
}

/// Called only while holding the ledger's lock. Keep the ID in its own file so
/// older clients rewriting their ledger cannot silently drop it.
fn installation_id(ledger: &Path) -> anyhow::Result<String> {
    let path = ledger.with_file_name("project-installation-id");
    match std::fs::read_to_string(&path) {
        Ok(id) => {
            uuid::Uuid::parse_str(&id).context("invalid project installation ID")?;
            Ok(id)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let id = uuid::Uuid::new_v4().to_string();
            let part = path.with_extension(format!("{id}.part"));
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&part)?;
            file.write_all(id.as_bytes())?;
            file.sync_all()?;
            std::fs::rename(&part, &path)?;
            Ok(id)
        }
        Err(error) => Err(error).context("cannot read project installation ID"),
    }
}
