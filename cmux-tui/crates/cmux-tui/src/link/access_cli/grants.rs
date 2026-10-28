//! The grants `cmux link access` keeps on this Mac, and which folders may be
//! shared at all.
//!
//! A grant names one folder of this Mac, one Cloud machine (`machine`, the
//! app's id for it), one chat there (`session`, its agent session on the
//! machine), the folder's copy on the machine (`remote`) and its mode. The
//! record is `<state>/link-access/grants.json` (0600, its folder 0700),
//! written to a temporary name and renamed; every command holds
//! `<state>/link-access/grants.lock` (an exclusive `flock`) from reading it
//! until its last push ends, so a revoke that returned is never followed by
//! a push of what it revoked. A record this version can't read refuses
//! every command (nothing is pushed) rather than starting over.
//!
//! What may be shared ([`shareable`]): an existing folder strictly under the
//! home folder (both canonical, so a symlink is judged by where it leads),
//! not the home folder itself, not `~/Library` or anything in it, and not in
//! any dot folder (`~/.ssh`, `~/.config`, `~/projects/.secret`, ...) or
//! credential folder (`gcloud`, ...). Each sync checks the folder again.

use std::collections::BTreeMap;
use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Component, Path, PathBuf};

use anyhow::{Context as _, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

const VERSION: u32 = 1;
/// Longest machine or session id.
const MAX_ID_BYTES: usize = 200;
const MAX_REMOTE_BYTES: usize = 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum Mode {
    /// This Mac's changes go; the machine's never come back.
    Read,
    /// The machine's changes come back too (a three-way merge).
    Write,
}

impl Mode {
    pub(super) fn parse(text: &str) -> Option<Self> {
        match text {
            "read" => Some(Self::Read),
            "write" => Some(Self::Write),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Grant {
    pub machine: String,
    pub session: String,
    /// Canonical, on this Mac.
    pub folder: String,
    /// Absolute, on the machine.
    pub remote: String,
    pub mode: Mode,
}

#[derive(Serialize, Deserialize)]
struct Record {
    version: u32,
    grants: Vec<Grant>,
}

/// Why a folder may not be shared.
#[derive(Debug)]
pub(super) struct Refused(pub String);

impl std::fmt::Display for Refused {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for Refused {}

/// The canonical folder at `folder`, when it may be shared.
pub(super) fn shareable(folder: &Path) -> Result<PathBuf, Refused> {
    let refused = |why: &str| Refused(format!("{} cannot be shared: {why}", folder.display()));
    let home = home().ok_or_else(|| refused("this Mac has no home folder"))?;
    let canonical =
        cmux_blocking::fs::canonicalize(folder).map_err(|_| refused("it does not exist"))?;
    if !cmux_blocking::fs::metadata(&canonical).is_ok_and(|meta| meta.is_dir()) {
        return Err(refused("it is not a folder"));
    }
    let Ok(inside) = canonical.strip_prefix(&home) else {
        return Err(refused("only folders in your home folder can be shared"));
    };
    let mut parts = inside.components().peekable();
    if parts.peek().is_none() {
        return Err(refused("the home folder itself is never shared"));
    }
    for (index, part) in parts.enumerate() {
        let Component::Normal(name) = part else { return Err(refused("not a plain path")) };
        let name = name.to_string_lossy();
        if name.starts_with('.') {
            return Err(refused("folders in a dot folder are never shared"));
        }
        if index == 0 && name.eq_ignore_ascii_case("Library") {
            return Err(refused("~/Library is never shared"));
        }
        if super::SECRET_FOLDERS.contains(&name.to_ascii_lowercase().as_str()) {
            return Err(refused("credential folders are never shared"));
        }
    }
    Ok(canonical)
}

/// The canonical file or folder at `path`, and whether it is a folder, when
/// it may be shared on its own (a file request): the rules of
/// [`shareable`], and a file must not be a secret file.
pub(super) fn shareable_item(path: &Path) -> Result<(PathBuf, bool), Refused> {
    let refused = |why: &str| Refused(format!("{} cannot be shared: {why}", path.display()));
    let canonical =
        cmux_blocking::fs::canonicalize(path).map_err(|_| refused("it does not exist"))?;
    let meta = cmux_blocking::fs::metadata(&canonical).map_err(|_| refused("it does not exist"))?;
    if meta.is_dir() {
        return Ok((shareable(&canonical)?, true));
    }
    if !meta.is_file() {
        return Err(refused("it is not a file or a folder"));
    }
    let folder = canonical.parent().ok_or_else(|| refused("it has no folder"))?;
    let name = canonical.file_name().map(|name| name.to_string_lossy().into_owned());
    let name = name.unwrap_or_default();
    // A file right in the home folder may go on its own; its folder never.
    let home = homes().into_iter().any(|home| home == folder);
    if !home {
        shareable(folder).map_err(|_| refused("its folder may not be shared"))?;
    }
    if name.starts_with('.') || super::is_secret(&name) {
        return Err(refused("secret files are never shared"));
    }
    Ok((canonical, false))
}

/// This Mac's home folder, canonical: `HOME` when it names a folder at
/// least two levels deep (never `/` or `/Users`, which would make other
/// people's folders shareable).
fn home() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").filter(|home| !home.is_empty())?;
    let home = cmux_blocking::fs::canonicalize(home).ok()?;
    (home.components().filter(|part| matches!(part, Component::Normal(_))).count() >= 2)
        .then_some(home)
}

/// This Mac's home folder ([`home`]) canonical and as `HOME` writes it.
pub(super) fn homes() -> Vec<PathBuf> {
    let Some(canonical) = home() else { return Vec::new() };
    let mut homes = vec![canonical.clone()];
    if let Some(literal) = std::env::var_os("HOME").map(PathBuf::from)
        && literal != canonical
    {
        homes.push(literal);
    }
    homes
}

/// Whether `id` can name a machine or a session.
pub(super) fn plain_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ID_BYTES
        && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte))
}

/// `root` without trailing slashes, when it is an absolute machine path of
/// plain names.
pub(super) fn remote_root(root: &str) -> Option<String> {
    let root = root.trim_end_matches('/');
    let plain = root.starts_with('/')
        && root.len() <= MAX_REMOTE_BYTES
        && root[1..].split('/').all(|name| !matches!(name, "" | "." | ".."))
        && !root.chars().any(char::is_control);
    plain.then(|| root.to_string())
}

/// Where `folder`'s copy goes under the machine's `root`:
/// `<root>/local/<name>-<12 hex>`, the start of the SHA-256 of the folder's
/// path here, so two folders with one name never share a copy, and a shared
/// folder never lands on a moved one (those go right under `<root>`).
pub(super) fn remote_of(root: &str, folder: &Path) -> String {
    let digest = Sha256::digest(folder.as_os_str().as_encoded_bytes());
    let hash: String = digest[..6].iter().map(|byte| format!("{byte:02x}")).collect();
    let name = folder.file_name().map(|name| name.to_string_lossy().into_owned());
    let mut name: String = name
        .unwrap_or_default()
        .chars()
        .map(|c| if c == '/' || c.is_control() { '_' } else { c })
        .collect();
    // A name on the machine holds 255 bytes; keep room for the hash.
    while name.len() > 120 {
        name.pop();
    }
    let name = if name.is_empty() { "folder".to_string() } else { name };
    format!("{root}/local/{name}-{hash}")
}

/// The grants record, locked for as long as this lives.
pub(super) struct Store {
    path: PathBuf,
    _lock: std::fs::File,
    pub grants: Vec<Grant>,
}

impl Store {
    /// Locks the record and reads it.
    pub(super) fn open() -> anyhow::Result<Self> {
        let Some(state) = cmux_tui_core::platform::workspace_state_dir() else {
            bail!("this Mac has no state folder to keep grants in");
        };
        let dir = state.join("link-access");
        crate::blocking::fs::create_dir_with(
            std::fs::DirBuilder::new().recursive(true).mode(0o700),
            &dir,
        )
        .with_context(|| format!("cannot make {}", dir.display()))?;
        // A folder made earlier with other permissions is this user's only.
        crate::blocking::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))
            .with_context(|| format!("cannot protect {}", dir.display()))?;
        let lock = crate::blocking::fs::open_with(
            std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW),
            dir.join("grants.lock"),
        )
        .context("cannot open the grants lock")?;
        lock.lock().context("cannot lock the grants")?;
        let path = dir.join("grants.json");
        let grants = match cmux_blocking::fs::read(&path) {
            Ok(bytes) => {
                let record: Record = serde_json::from_slice(&bytes)
                    .with_context(|| format!("{} is not a grants record", path.display()))?;
                if record.version != VERSION {
                    bail!("{} is a grants record of another version", path.display());
                }
                record.grants
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(error) => {
                return Err(error).with_context(|| format!("cannot read {}", path.display()));
            }
        };
        Ok(Self { path, _lock: lock, grants })
    }

    pub(super) fn save(&self) -> anyhow::Result<()> {
        let record = Record { version: VERSION, grants: self.grants.clone() };
        let part = self.path.with_extension(format!("{}.part", std::process::id()));
        let _ = cmux_blocking::fs::remove_file(&part);
        let mut file = crate::blocking::fs::open_with(
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW),
            &part,
        )
        .with_context(|| format!("cannot write {}", part.display()))?;
        file.write_all(&serde_json::to_vec(&record)?)?;
        crate::blocking::fs::sync_all(&file)?;
        cmux_blocking::fs::rename(&part, &self.path)
            .with_context(|| format!("cannot write {}", self.path.display()))
    }

    /// The grants of `machine` (and of `session` when given), by their copy
    /// on the machine: chats that share one folder share its copy.
    pub(super) fn copies(
        &self,
        machine: &str,
        session: Option<&str>,
    ) -> BTreeMap<(String, String), Mode> {
        self.grants
            .iter()
            .filter(|grant| grant.machine == machine)
            .filter(|grant| session.is_none_or(|session| grant.session == session))
            .map(|grant| ((grant.folder.clone(), grant.remote.clone()), grant.mode))
            .collect()
    }
}
