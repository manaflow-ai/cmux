//! A cmux Cloud machine's identity, as its model-plane env names it.
//!
//! Every Cloud image bakes `/etc/cmux/model-plane.env`: its Cloud origin
//! (`CMUX_CODEROUTER_URL`, the image's variable name) and, per machine,
//! `CMUX_VM_ID` (see [`machine_source`] for where each comes from). The file
//! server (`link/cloud_fs.rs`) reads both to tell a Cloud host, and
//! `secrets-v1` (`machine_secrets.rs`) reads the `vm_…` id it seals for.
//!
//! The machine spend readout that polled CodeRouter with this identity is gone
//! with CodeRouter (Leo, 2026-11-25: "For cmux next, just rip it out for now").

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub(crate) const CODEROUTER_URL_VAR: &str = "CMUX_CODEROUTER_URL";
pub(crate) const VM_ID_VAR: &str = "CMUX_VM_ID";
const ENV_FILE_RELATIVE_PATH: &str = ".config/cmux/model-plane.env";
/// The model-plane env every Cloud image bakes (`/etc/cmux/model-plane.env`,
/// web/services/coderouter/vmGuestEnv.ts): the same bytes on every machine,
/// so it carries the coderouter origin but no `CMUX_VM_ID`.
const IMAGE_ENV_FILE: &str = "model-plane.env";
/// The instance id the bind agent wrote for this machine before it started
/// the daemon (`/etc/cmux/daemon-instance-id`, cmux-host `BOUND_INSTANCE_FILE`).
const BOUND_INSTANCE_FILE: &str = "daemon-instance-id";
/// Longest instance id read.
const MAX_INSTANCE_ID_BYTES: usize = 128;

/// The machine's identity: its Cloud origin and its VM id.
/// Only its presence decides today; tests read the fields.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) struct MachineIdentity {
    pub origin: String,
    pub vm_id: String,
}

/// Parse the `export KEY='value'` lines the model-plane env file uses.
///
/// Accepts an optional `export ` prefix, single-quoted values with the
/// POSIX `'\''` escape, double-quoted values with backslash escapes, and
/// bare values. Blank lines and `#` comments are skipped; a malformed line
/// is ignored rather than failing the whole file, so one odd entry cannot
/// hide the two keys this module needs.
pub(crate) fn parse_env_exports(contents: &str) -> BTreeMap<String, String> {
    let mut values = BTreeMap::new();
    for raw_line in contents.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = line.strip_prefix("export ").map_or(line, str::trim_start);
        let Some((key, value)) = line.split_once('=') else { continue };
        let key = key.trim();
        if key.is_empty()
            || !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
            || key.starts_with(|c: char| c.is_ascii_digit())
        {
            continue;
        }
        let Some(value) = parse_shell_value(value.trim()) else { continue };
        values.insert(key.to_string(), value);
    }
    values
}

fn parse_shell_value(raw: &str) -> Option<String> {
    let mut chars = raw.chars().peekable();
    let mut out = String::new();
    while let Some(c) = chars.next() {
        match c {
            '\'' => loop {
                match chars.next() {
                    Some('\'') => break,
                    Some(c) => out.push(c),
                    None => return None,
                }
            },
            '"' => loop {
                match chars.next() {
                    Some('"') => break,
                    Some('\\') => match chars.next() {
                        Some(escaped @ ('"' | '\\' | '$' | '`')) => out.push(escaped),
                        Some(other) => {
                            out.push('\\');
                            out.push(other);
                        }
                        None => return None,
                    },
                    Some(c) => out.push(c),
                    None => return None,
                }
            },
            '\\' => out.push(chars.next()?),
            '#' if out.is_empty() => return None,
            c if c.is_whitespace() => break,
            c => out.push(c),
        }
    }
    Some(out)
}

/// Resolve the identity from the process environment first, then from
/// the env file. Each key resolves independently so a daemon started with
/// only one of the two in its environment still finds the other in the file.
#[cfg(test)]
pub(crate) fn resolve_source(
    env: impl Fn(&str) -> Option<String>,
    env_file: Option<&str>,
) -> Option<MachineIdentity> {
    resolve_layered_source(env, &[env_file], None)
}

/// [`resolve_source`] over several env files, earlier ones first, each key
/// on its own. `bound_instance_id` is the last place `CMUX_VM_ID` comes
/// from: a fresh Cloud VM's shells never export it (the baked env has none),
/// but the bind agent has written the machine's id.
pub(crate) fn resolve_layered_source(
    env: impl Fn(&str) -> Option<String>,
    env_files: &[Option<&str>],
    bound_instance_id: Option<&str>,
) -> Option<MachineIdentity> {
    let file_values: Vec<_> =
        env_files.iter().flatten().map(|file| parse_env_exports(file)).collect();
    let lookup = |key: &str| {
        env(key)
            .filter(|value| !value.trim().is_empty())
            .into_iter()
            .chain(file_values.iter().filter_map(|values| values.get(key).cloned()))
            .map(|value| value.trim().to_string())
            .find(|value| !value.is_empty())
    };
    let origin = lookup(CODEROUTER_URL_VAR)?;
    let vm_id = lookup(VM_ID_VAR).or_else(|| bound_instance_id.and_then(instance_id))?;
    if !(origin.starts_with("https://") || origin.starts_with("http://")) {
        return None;
    }
    Some(MachineIdentity { origin, vm_id })
}

/// A bound instance id file's text as an id: one token of printable ASCII,
/// at most [`MAX_INSTANCE_ID_BYTES`]; `None` otherwise.
fn instance_id(text: &str) -> Option<String> {
    let id = text.trim();
    (!id.is_empty()
        && id.len() <= MAX_INSTANCE_ID_BYTES
        && id.bytes().all(|byte| byte.is_ascii_graphic()))
    .then(|| id.to_string())
}

pub(crate) fn default_env_file_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(ENV_FILE_RELATIVE_PATH))
}

/// This machine's identity, each key from the first place that has it:
/// the process environment, `$HOME/.config/cmux/model-plane.env` (what a
/// shell persisted from a boot env), the image's `/etc/cmux/model-plane.env`,
/// and for `CMUX_VM_ID` last the bound `/etc/cmux/daemon-instance-id`.
///
/// The daemon's unit carries none of these, and a fresh VM's shells only
/// source the image file without writing a per-home one, so without the two
/// `/etc/cmux` files a fresh VM never learned its identity and served no
/// `fs-v1`. The `/etc/cmux` folder follows the debug-only test seam
/// ([`crate::agent_start_host::cloud_etc`]).
pub(crate) fn machine_source() -> Option<MachineIdentity> {
    let home_env = read_env_file(default_env_file_path().as_deref());
    let etc = crate::agent_start_host::cloud_etc();
    let image_env = read_env_file(Some(&etc.file(IMAGE_ENV_FILE)));
    let bound_id = read_env_file(Some(&etc.file(BOUND_INSTANCE_FILE)));
    resolve_layered_source(
        |key| std::env::var(key).ok(),
        &[home_env.as_deref(), image_env.as_deref()],
        bound_id.as_deref(),
    )
}

/// `CMUX_VM_ID` alone, from the same places as [`machine_source`], with or
/// without a coderouter origin. Never the bound instance id: that is the
/// provider's, not the platform's `vm_…` id `secrets-v1` items are sealed for.
#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn machine_vm_id() -> Option<String> {
    let etc = crate::agent_start_host::cloud_etc();
    let files = [
        read_env_file(default_env_file_path().as_deref()),
        read_env_file(Some(&etc.file(IMAGE_ENV_FILE))),
    ];
    std::env::var(VM_ID_VAR)
        .ok()
        .into_iter()
        .chain(files.iter().flatten().filter_map(|file| parse_env_exports(file).remove(VM_ID_VAR)))
        .map(|value| value.trim().to_owned())
        .find(|value| !value.is_empty())
}

fn read_env_file(path: Option<&Path>) -> Option<String> {
    std::fs::read_to_string(path?).ok()
}

#[cfg(test)]
#[path = "machine_identity_tests.rs"]
mod tests;
