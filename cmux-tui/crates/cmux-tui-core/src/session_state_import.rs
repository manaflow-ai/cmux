//! A one-time copy of a session's workspace registry from the default
//! durable state root into an explicit state root (cx-0b8z).
//!
//! Before an explicit `remote-link --state-dir` reached the mux owner, the
//! owner kept that link's workspaces in the default root. On the first start
//! with an empty explicit root, the session's default-root registry is copied
//! there once, so its workspaces do not vanish. The source is never changed:
//! the copy is a consistent `VACUUM INTO` snapshot of a read-only connection
//! (WAL content included), staged and renamed into place. The schema
//! migration runs when the mux owner opens the copy.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context;
use rusqlite::{Connection, OpenFlags, OptionalExtension};

const REGISTRY_FILE: &str = "workspace-registry.sqlite3";
/// Root-level identity files a registry is bound to; the copy needs the same.
const ROOT_IDENTITY_FILES: [&str; 2] = ["resource-effect-pepper", "machine-id"];
const MARKER_PREFIX: &str = ".imported-default-root-";

/// What [`import_default_root_session`] did.
#[derive(Debug, PartialEq, Eq)]
pub enum SessionStateImport {
    /// The registry at `from` was copied to `to`.
    Imported { from: PathBuf, to: PathBuf },
    /// Nothing to do: no source, the target has a store, or it was done once.
    Skipped,
}

/// Copies the registry of `session` from `default_root` into `target_root`
/// once. It never copies when the target has a registry for the session, a
/// marker records an earlier import, or the target root is bound to another
/// resource pepper.
pub fn import_default_root_session(
    default_root: &Path,
    target_root: &Path,
    session: &str,
) -> anyhow::Result<SessionStateImport> {
    if same_path(default_root, target_root) {
        return Ok(SessionStateImport::Skipped);
    }
    let Some(source) = find_session_registry(default_root, session)? else {
        return Ok(SessionStateImport::Skipped);
    };
    let component = source
        .parent()
        .and_then(Path::file_name)
        .context("default-root registry has no session directory")?
        .to_owned();
    let marker = target_root.join(format!("{MARKER_PREFIX}{}", component.to_string_lossy()));
    let target_dir = target_root.join(&component);
    let target = target_dir.join(REGISTRY_FILE);
    if marker.exists() || target.exists() || target_has_other_identity(default_root, target_root)? {
        return Ok(SessionStateImport::Skipped);
    }
    fs::create_dir_all(&target_dir)
        .with_context(|| format!("create {}", target_dir.display()))?;
    crate::platform::restrict_directory(target_root)?;
    crate::platform::restrict_directory(&target_dir)?;
    for name in ROOT_IDENTITY_FILES {
        let from = default_root.join(name);
        let to = target_root.join(name);
        if from.is_file() && !to.exists() {
            copy_private(&from, &to)?;
        }
    }
    let staged = target_dir.join(format!(".{REGISTRY_FILE}.import"));
    let _ = fs::remove_file(&staged);
    {
        let connection = Connection::open_with_flags(&source, OpenFlags::SQLITE_OPEN_READ_ONLY)
            .with_context(|| format!("open {}", source.display()))?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        let staged_text = staged.to_str().context("import path is not UTF-8")?;
        connection
            .execute("VACUUM INTO ?1", [staged_text])
            .with_context(|| format!("snapshot {}", source.display()))?;
    }
    crate::platform::restrict_file(&staged)?;
    fs::File::open(&staged)?.sync_all()?;
    fs::rename(&staged, &target).with_context(|| format!("install {}", target.display()))?;
    crate::platform::sync_directory(&target_dir)?;
    fs::write(&marker, b"1\n")?;
    crate::platform::restrict_file(&marker)?;
    crate::platform::sync_directory(target_root)?;
    Ok(SessionStateImport::Imported { from: source, to: target })
}

/// The default-root registry whose stored `session_name` is `session`.
fn find_session_registry(root: &Path, session: &str) -> anyhow::Result<Option<PathBuf>> {
    let Ok(entries) = fs::read_dir(root) else { return Ok(None) };
    for entry in entries.flatten() {
        let path = entry.path().join(REGISTRY_FILE);
        if !path.is_file() {
            continue;
        }
        let Ok(connection) = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        else {
            continue;
        };
        let stored = connection
            .query_row("SELECT value FROM meta WHERE key = 'session_name'", [], |row| {
                row.get::<_, String>(0)
            })
            .optional()
            .ok()
            .flatten();
        if stored.as_deref() == Some(session) {
            return Ok(Some(path));
        }
    }
    Ok(None)
}

/// True when the target root already holds a different identity file: its
/// other sessions are bound to it, so a copied registry would not open.
fn target_has_other_identity(default_root: &Path, target_root: &Path) -> anyhow::Result<bool> {
    for name in ROOT_IDENTITY_FILES {
        let to = target_root.join(name);
        if to.is_file() {
            let from = default_root.join(name);
            if !from.is_file() || fs::read(&from)? != fs::read(&to)? {
                return Ok(true);
            }
        }
    }
    Ok(false)
}

fn copy_private(from: &Path, to: &Path) -> anyhow::Result<()> {
    let bytes = fs::read(from).with_context(|| format!("read {}", from.display()))?;
    let staged = to.with_extension("import");
    fs::write(&staged, bytes)?;
    crate::platform::restrict_file(&staged)?;
    fs::File::open(&staged)?.sync_all()?;
    fs::rename(&staged, to)?;
    Ok(())
}

fn same_path(left: &Path, right: &Path) -> bool {
    match (left.canonicalize(), right.canonicalize()) {
        (Ok(left), Ok(right)) => left == right,
        _ => left == right,
    }
}
