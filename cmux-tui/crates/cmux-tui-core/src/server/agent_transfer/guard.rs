//! The receive guard: which folder a receive may land in, and the plain
//! ids and names acpmux is asked about. Only `plain_cwd` runs on the request
//! thread; `guard_for` resolves paths on disk on the worker.

use std::path::{Component, Path};

use cmux_threads::checked::fs as files;
use serde_json::{Value, json};

use super::{AgentTransferHost, Failure, MAX_PATH_BYTES, Refusal};

/// A receive's `cwd` is an absolute path within the length bound: checked on
/// the request thread, from the request alone.
pub(super) fn plain_cwd(cwd: &str) -> bool {
    !cwd.is_empty() && cwd.len() <= MAX_PATH_BYTES && Path::new(cwd).is_absolute()
}

/// The receive guard and the canonical folder for `cwd` on `host`. It
/// resolves paths on disk: the worker calls it, never the request thread.
pub(super) fn guard_for(host: &AgentTransferHost, cwd: &str) -> Result<(Value, String), Failure> {
    let path = Path::new(cwd);
    if !plain_cwd(cwd) {
        return Err(Refusal::BadRequest.into());
    }
    let home = files::canonicalize(&host.home).map_err(|_| Refusal::Unavailable)?;
    let folder = files::canonicalize(path)
        .ok()
        .filter(|folder| files::metadata(folder).is_ok_and(|metadata| metadata.is_dir()))
        .ok_or(Refusal::OutsideRoots)?;
    let (control, root) = if host.cloud {
        let root = files::canonicalize(home.join("work"))
            .ok()
            .filter(|root| files::metadata(root).is_ok_and(|metadata| metadata.is_dir()))
            .ok_or(Refusal::OutsideRoots)?;
        ("peer", root)
    } else {
        // Strictly under home, and not in a dot folder of home.
        let rel = folder.strip_prefix(&home).map_err(|_| Refusal::OutsideRoots)?;
        let first = rel.components().next();
        let plain = matches!(first, Some(Component::Normal(name))
            if !name.to_string_lossy().starts_with('.'));
        if !plain {
            return Err(Refusal::OutsideRoots.into());
        }
        ("web", folder.clone())
    };
    if !folder.starts_with(&root) {
        return Err(Refusal::OutsideRoots.into());
    }
    let text = |path: &Path| path.to_str().map(str::to_owned).ok_or(Refusal::BadRequest);
    let guard = json!({"control": control, "roots": [text(&root)?]});
    Ok((guard, text(&folder)?))
}

/// An acpmux receive or transfer id (a UUID): 1 to 128 of `[A-Za-z0-9_-]`.
pub(super) fn is_plain_id(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// A chat name for finish: 1 to 128 bytes, no control characters (acpmux
/// checks the rest).
pub(super) fn is_chat_name(name: &str) -> bool {
    (1..=128).contains(&name.len()) && !name.chars().any(char::is_control)
}
