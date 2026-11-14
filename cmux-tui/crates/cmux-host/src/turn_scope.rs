//! Trusted logical workspace scope provisioned before the session host starts.
//! The provider VM/carrier may change on rewind; these logical identities do not.

use std::fs::{self, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

use serde::Deserialize;

use crate::config::Paths;

pub const SCOPE_FILE: &str = "/var/lib/cmux/turn-scope.json";
const MAX_BYTES: u64 = 4096;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Scope {
    origin: String,
    workspace: String,
    machine: String,
}

fn invalid() -> io::Error {
    // Never include the file content in diagnostics.
    io::Error::new(io::ErrorKind::InvalidData, "invalid trusted Cloud turn scope")
}

fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value != "."
        && value != ".."
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.:".contains(&b))
}

fn parse(text: &[u8]) -> io::Result<Vec<(String, String)>> {
    let scope: Scope = serde_json::from_slice(text).map_err(|_| invalid())?;
    let origin = url::Url::parse(&scope.origin).map_err(|_| invalid())?;
    if origin.scheme() != "https"
        || origin.host_str().is_none()
        || origin.path() != "/"
        || !origin.username().is_empty()
        || origin.password().is_some()
        || origin.query().is_some()
        || origin.fragment().is_some()
        || !valid_id(&scope.workspace)
        || !valid_id(&scope.machine)
    {
        return Err(invalid());
    }
    Ok(vec![
        ("CMUX_PLATFORM_ORIGIN".into(), scope.origin),
        ("CMUX_PLATFORM_WORKSPACE_ID".into(), scope.workspace),
        ("CMUX_PLATFORM_MACHINE_ID".into(), scope.machine),
    ])
}

fn read(path: &Path, owner: u32) -> io::Result<Vec<(String, String)>> {
    let mut file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let metadata = file.metadata()?;
    let parent = fs::symlink_metadata(path.parent().ok_or_else(invalid)?)?;
    if !metadata.is_file()
        || metadata.uid() != owner
        || metadata.mode() & 0o777 != 0o600
        || metadata.len() > MAX_BYTES
        || !parent.is_dir()
        || parent.uid() != owner
        || parent.mode() & 0o022 != 0
    {
        return Err(invalid());
    }
    let mut bytes = Vec::new();
    (&mut file).take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(invalid());
    }
    parse(&bytes)
}

/// A missing file keeps existing machines unchanged. A malformed or untrusted file must fail
/// startup, never quietly turn a configured workspace into an unfenced daemon.
pub fn environment(paths: &Paths) -> io::Result<Vec<(String, String)>> {
    read(&paths.at(SCOPE_FILE), 0)
}

#[cfg(test)]
mod tests;
