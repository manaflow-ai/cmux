//! `agent hook status` names what blocks `install` instead of reporting it
//! as absent: a symlink, a non-file, a plugin file cmux-tui did not write, or a
//! target it cannot inspect. The checks mirror install's own refusals, which
//! `ensure_replaceable_target` keeps here beside them.

use std::fs;
use std::io;
use std::path::Path;

use anyhow::Context as _;
use serde_json::{Value, json};

use super::{Format, Provider, is_owned_plugin};

/// The status row for a provider whose target install would refuse.
pub(super) fn conflict_row(provider: Provider, path: &Path) -> Option<Value> {
    let conflict = install_conflict(provider, path)?;
    Some(json!({
        "provider":provider.id,
        "path":path,
        "state":conflict.state(),
        "reason":conflict.reason,
        "detail":conflict.detail,
        "changed":false,
    }))
}

/// Why an existing hook target blocks `install`. `status` reports it instead
/// of "absent" so a caller does not offer an install the installer refuses.
#[derive(Debug)]
struct Conflict {
    /// `symlink`, `not_a_file`, `not_a_directory`, `not_owned` or `unreadable`.
    reason: &'static str,
    detail: String,
}

impl Conflict {
    fn new(reason: &'static str, detail: String) -> Self {
        Self { reason, detail }
    }

    fn state(&self) -> &'static str {
        if self.reason == "unreadable" { "unavailable" } else { "conflict" }
    }
}

/// Mirrors the refusals in `install_provider`: `ensure_replaceable_target`,
/// `ensure_owned_plugin_directory` and the plugin ownership check.
fn install_conflict(provider: Provider, path: &Path) -> Option<Conflict> {
    match provider.format {
        Format::Nested { .. } | Format::Flat { .. } | Format::AntigravityJson => {
            target_kind_conflict(path, false)
        }
        Format::Plugin { .. } => {
            target_kind_conflict(path, false).or_else(|| foreign_plugin_conflict(path))
        }
        Format::HermesPlugin { .. } => target_kind_conflict(path, true)
            .or_else(|| hermes_directory_conflict(path))
            .or_else(|| {
                ["__init__.py", "plugin.yaml"].into_iter().find_map(|name| {
                    let file = path.join(name);
                    target_kind_conflict(&file, false).or_else(|| foreign_plugin_conflict(&file))
                })
            }),
        Format::RovoYaml | Format::KimiToml => None,
    }
}

fn target_kind_conflict(path: &Path, directory: bool) -> Option<Conflict> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return None,
        Err(error) => {
            return Some(Conflict::new(
                "unreadable",
                format!("cannot inspect {}: {error}", path.display()),
            ));
        }
    };
    if metadata.file_type().is_symlink() {
        return Some(Conflict::new(
            "symlink",
            format!("{} is a symlink, which cmux-tui will not replace", path.display()),
        ));
    }
    match (directory, metadata.is_dir(), metadata.is_file()) {
        (true, false, _) => Some(Conflict::new(
            "not_a_directory",
            format!("{} exists and is not a directory", path.display()),
        )),
        (false, _, false) => Some(Conflict::new(
            "not_a_file",
            format!("{} exists and is not a regular file", path.display()),
        )),
        _ => None,
    }
}

fn foreign_plugin_conflict(path: &Path) -> Option<Conflict> {
    match fs::read(path) {
        Ok(content) if is_owned_plugin(&content) => None,
        Ok(_) => Some(Conflict::new(
            "not_owned",
            format!("{} exists and is not owned by cmux-tui", path.display()),
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => {
            Some(Conflict::new("unreadable", format!("cannot read {}: {error}", path.display())))
        }
    }
}

fn hermes_directory_conflict(path: &Path) -> Option<Conflict> {
    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return None,
        Err(error) => {
            return Some(Conflict::new(
                "unreadable",
                format!("cannot inspect {}: {error}", path.display()),
            ));
        }
    };
    for entry in entries {
        let name = match entry {
            Ok(entry) => entry.file_name(),
            Err(error) => {
                return Some(Conflict::new(
                    "unreadable",
                    format!("cannot inspect {}: {error}", path.display()),
                ));
            }
        };
        if !matches!(name.to_str(), Some("__init__.py" | "plugin.yaml" | "__pycache__")) {
            return Some(Conflict::new(
                "not_owned",
                format!("{} contains an unowned entry", path.display()),
            ));
        }
    }
    None
}

pub(super) fn ensure_replaceable_target(path: &Path) -> anyhow::Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error).with_context(|| format!("inspect {}", path.display())),
    };
    anyhow::ensure!(
        !metadata.file_type().is_symlink(),
        "refusing to replace symlink {}",
        path.display()
    );
    anyhow::ensure!(metadata.is_file(), "refusing to replace non-file {}", path.display());
    Ok(())
}

#[cfg(test)]
#[path = "status_conflict_tests.rs"]
mod tests;
