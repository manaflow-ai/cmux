//! Applies `cmux_server_core::access` policies (POSIX): a missing path is
//! created with its owner and mode; an existing path with another owner,
//! wider permissions, or a symlink is refused and reported, never repaired
//! silently (a wrong owner on a shared directory means someone else
//! created it first).

use std::fs;
use std::io;
use std::path::Path;

use cmux_server_core::access::{Access, PathAccess, PosixOwner};

use crate::error::{Error, Result};
use crate::fsx;
use crate::process::{Cmd, Runner};
use crate::sys;

fn owner_uid(owner: PosixOwner) -> Result<u32> {
    match owner {
        PosixOwner::Root => Ok(0),
        PosixOwner::Uid(uid) => Ok(uid),
        PosixOwner::CurrentUser => Ok(sys::euid()),
        PosixOwner::Named(name) => sys::uid_of(name)
            .map_err(|e| Error::internal(format!("user {name}: {e}")))?
            .ok_or_else(|| Error::not_found(format!("user {name} does not exist"))),
    }
}

fn owner_name(owner: PosixOwner) -> String {
    match owner {
        PosixOwner::Root => "root".to_owned(),
        PosixOwner::Named(name) => name.to_owned(),
        PosixOwner::Uid(uid) => uid.to_string(),
        PosixOwner::CurrentUser => sys::euid().to_string(),
    }
}

/// Checks an existing path against its policy. `Ok(false)` when it does
/// not exist.
pub fn check(policy: &PathAccess) -> Result<bool> {
    let Access::Posix { owner, mode, .. } = policy.access else { return Ok(true) };
    let path = Path::new(policy.path.as_str());
    let meta = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(e) => return Err(Error::io(path.display(), e)),
    };
    if meta.file_type().is_symlink() && policy.no_symlink {
        return Err(Error::rejected(format!("{} is a symlink; refusing", path.display())));
    }
    if !meta.is_dir() {
        return Err(Error::rejected(format!("{} is not a directory; refusing", path.display())));
    }
    let want = owner_uid(owner)?;
    let got = sys::owner_uid(&meta);
    if got != want {
        return Err(Error::rejected(format!(
            "{} is owned by uid {got}, expected {}; refusing (someone else created it)",
            path.display(),
            owner_name(owner)
        )));
    }
    let actual = fsx::mode_of(&meta);
    if actual & !mode != 0 {
        return Err(Error::rejected(format!(
            "{} has mode {actual:o}, wider than {mode:o}; refusing. Fix: chmod {mode:o} {}",
            path.display(),
            path.display()
        )));
    }
    Ok(true)
}

/// Creates or checks every path in `policies`, in order.
pub fn ensure(policies: &[PathAccess], runner: &dyn Runner) -> Result<()> {
    for policy in policies {
        if check(policy)? {
            continue;
        }
        let Access::Posix { owner, group, mode } = policy.access else { continue };
        let path = Path::new(policy.path.as_str());
        fsx::ensure_dir(path, mode)?;
        let want = owner_uid(owner)?;
        if want != sys::euid() {
            // Only root reaches here (system mode); chown takes names.
            let spec = match group {
                Some(g) => format!("{}:{g}", owner_name(owner)),
                None => owner_name(owner),
            };
            runner.check(&Cmd::new("chown").arg(spec).arg(path))?;
        } else if let Some(g) = group {
            runner.check(&Cmd::new("chgrp").arg(g).arg(path))?;
        }
        check(policy)?;
    }
    Ok(())
}
