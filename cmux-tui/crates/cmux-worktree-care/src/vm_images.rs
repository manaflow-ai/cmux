//! Tart and Lume virtual machines and images:
//!
//! - `tart-images`: OCI images Tart pulled (`~/.tart/cache/OCIs/**/sha256:*`),
//!   regenerable: a pull makes them again;
//! - `tart-vms` (`~/.tart/vms/<name>`) and `lume-vms` (`~/.lume/<name>`, a folder
//!   with a `config.json`): local machines, unique, so archived first (a
//!   `tar.gz` in the archive store, listed back whole before anything goes).
//!
//! One goes only when it is older than the family's age ([`DEFAULT_DAYS`], or
//! `CMUX_CARE_IMAGE_DAYS`), its program answers `list` and no VM it lists as
//! running is this one (for an image: no running name resolves to it), no
//! program has its folder open, and the never-delete list does not hold it.
//! The program itself removes it (`tart delete`, `lume delete --force`), so
//! its own records stay true. A program that is absent or does not answer
//! keeps everything.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use serde_json::Value;

use crate::caches::{Entry, Family, Kind, Outcome, Source};
use crate::policy::{Action, Verdict};

/// The default age, in days, past which an image or a stopped VM may go.
pub const DEFAULT_DAYS: u64 = 30;
const LIST: Duration = Duration::from_secs(30);
const DELETE: Duration = Duration::from_secs(300);
/// Archiving a VM disk is slow; it stays bounded.
const ARCHIVE: Duration = Duration::from_secs(2 * 60 * 60);

/// Which program owns the folder.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Vm {
    Tart,
    Lume,
}

/// What the family's entries are.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shape {
    /// One folder per VM directly in the root (its name is the folder's).
    Machines,
    /// Tart's OCI cache: `sha256:*` folders below the root.
    OciImages,
}

/// The age from `CMUX_CARE_IMAGE_DAYS`, or [`DEFAULT_DAYS`]; never under one day.
pub fn days() -> u64 {
    std::env::var("CMUX_CARE_IMAGE_DAYS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(DEFAULT_DAYS)
        .max(1)
}

/// A VM family; `program` is `tart`/`lume` (found on PATH) or a path.
pub fn family(
    name: &'static str,
    root: PathBuf,
    vm: Vm,
    shape: Shape,
    program: PathBuf,
    days: u64,
) -> Family {
    let hours = Some(days.max(1) * 24);
    Family {
        name,
        root,
        per_child: false,
        idle_hours: [hours; 3],
        kind: if shape == Shape::OciImages { Kind::Regenerable } else { Kind::Unique },
        source: Source::Vms { vm, shape, program },
    }
}

/// A VM as its program lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Listed {
    pub name: String,
    pub oci: bool,
    pub running: bool,
}

fn search_path() -> std::ffi::OsString {
    let mut dirs: Vec<PathBuf> =
        vec!["/opt/homebrew/bin".into(), "/usr/local/bin".into(), "/usr/bin".into()];
    if let Some(home) = std::env::var_os("HOME") {
        dirs.push(PathBuf::from(home).join(".local/bin"));
    }
    dirs.extend(std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()));
    std::env::join_paths(dirs).unwrap_or_default()
}

fn run(program: &Path, args: &[&str], limit: Duration) -> Result<String, String> {
    let mut command = Command::new(program);
    command
        .env("PATH", search_path())
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let output = crate::git::run_within(command, limit)
        .map_err(|e| format!("{}: {e}", program.display()))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(format!("{} {}: {stderr}", program.display(), args.join(" ")));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Every VM and image the program lists, with its running state.
pub fn list(vm: Vm, program: &Path) -> Result<Vec<Listed>, String> {
    let text = match vm {
        Vm::Tart => run(program, &["list", "--format", "json"], LIST)?,
        Vm::Lume => run(program, &["ls", "--format", "json"], LIST)?,
    };
    parse_list(&text)
}

fn field<'a>(value: &'a Value, names: &[&str]) -> Option<&'a Value> {
    let object = value.as_object()?;
    names
        .iter()
        .find_map(|n| object.iter().find(|(k, _)| k.eq_ignore_ascii_case(n)).map(|(_, v)| v))
}

/// `tart list --format json` / `lume ls --format json`: an array of objects
/// with a name, a source (`OCI`/`local`) and a state or running flag.
pub fn parse_list(text: &str) -> Result<Vec<Listed>, String> {
    let value: Value = serde_json::from_str(text.trim()).map_err(|e| format!("list: {e}"))?;
    let items = value.as_array().ok_or("list: not an array")?;
    let mut out = Vec::new();
    for item in items {
        let name =
            field(item, &["name"]).and_then(Value::as_str).ok_or("list: a VM has no name")?;
        let oci = field(item, &["source"])
            .and_then(Value::as_str)
            .is_some_and(|s| s.eq_ignore_ascii_case("oci"));
        let state = field(item, &["state", "status"]).and_then(Value::as_str);
        let running = field(item, &["running"]).and_then(Value::as_bool).unwrap_or(false)
            || state.is_some_and(|s| {
                !matches!(s.to_ascii_lowercase().as_str(), "stopped" | "suspended")
            });
        out.push(Listed { name: name.to_string(), oci, running });
    }
    Ok(out)
}

fn real_dir(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|m| m.is_dir())
}

/// The folders of the family: machines directly in the root, or Tart's
/// `sha256:*` image folders below it.
pub(crate) fn entries(index: usize, family: &Family, found: &mut Vec<Entry>) {
    let Source::Vms { vm, shape, program } = &family.source else { return };
    if !real_dir(&family.root) {
        return;
    }
    let mut paths = Vec::new();
    match shape {
        Shape::Machines => {
            let Ok(read) = std::fs::read_dir(&family.root) else { return };
            for child in read.flatten() {
                let path = child.path();
                let lume_vm = *vm != Vm::Lume || path.join("config.json").is_file();
                if real_dir(&path) && lume_vm {
                    paths.push(path);
                }
            }
        }
        Shape::OciImages => {
            let mut stack = vec![(family.root.clone(), 0usize)];
            while let Some((dir, depth)) = stack.pop() {
                let Ok(read) = std::fs::read_dir(&dir) else { continue };
                for child in read.flatten() {
                    let path = child.path();
                    if !real_dir(&path) {
                        continue;
                    }
                    if child.file_name().to_string_lossy().starts_with("sha256:") {
                        paths.push(path);
                    } else if depth < 8 {
                        stack.push((path, depth + 1));
                    }
                }
            }
        }
    }
    paths.sort();
    // Without its program, nothing says which of them runs: their use is unknown.
    let answers = list(*vm, program).is_ok();
    for path in paths {
        let last_activity_ms = if answers { crate::caches::last_activity(&path) } else { None };
        found.push(Entry { family: index, guard: path.clone(), path, last_activity_ms });
    }
}

/// The names the program lists that are the folder at `path`.
fn names_of(family: &Family, shape: Shape, listed: &[Listed], path: &Path) -> Vec<Listed> {
    let real = std::fs::canonicalize(path).ok();
    listed
        .iter()
        .filter(|l| match shape {
            Shape::Machines => !l.oci && path.file_name().is_some_and(|n| n == l.name.as_str()),
            Shape::OciImages => {
                l.oci && {
                    let at = oci_path(&family.root, &l.name);
                    at == path || (real.is_some() && std::fs::canonicalize(&at).ok() == real)
                }
            }
        })
        .cloned()
        .collect()
}

/// Where Tart keeps the image `name` (`host/repo:tag` or `host/repo@sha256:…`).
pub fn oci_path(root: &Path, name: &str) -> PathBuf {
    if let Some((repo, digest)) = name.split_once('@') {
        return root.join(repo).join(digest);
    }
    // The tag is after the last ':' that follows the last '/' (a port has a '/' after it).
    let slash = name.rfind('/').unwrap_or(0);
    match name[slash..].rfind(':') {
        Some(at) => root.join(&name[..slash + at]).join(&name[slash + at + 1..]),
        None => root.join(name).join("latest"),
    }
}

fn keep(reason: impl Into<String>) -> Verdict {
    Verdict { action: Action::Keep, reason: reason.into(), idle_ms: None }
}

/// Archives the machine folder at `path` as a verified `tar.gz` in the store.
fn archive(
    store: &crate::store::Store,
    family: &Family,
    path: &Path,
    now_ms: u64,
) -> Result<String, String> {
    let folder = store.dir.join("vms").join(family.name);
    std::fs::create_dir_all(&folder).map_err(|e| format!("{}: {e}", folder.display()))?;
    let id = crate::store::new_id(now_ms, path);
    let dest = folder.join(format!("{id}.tar.gz"));
    let temporary = folder.join(format!(".{id}.tar.gz.tmp"));
    let parent = path.parent().ok_or("no parent folder")?;
    let name = path.file_name().ok_or("no folder name")?;
    let tar = |args: Vec<&std::ffi::OsStr>| -> Result<(), String> {
        let mut command = Command::new("tar");
        command.args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped());
        let output = crate::git::run_within(command, ARCHIVE)?;
        if output.status.success() {
            Ok(())
        } else {
            Err(format!("tar: {}", String::from_utf8_lossy(&output.stderr).trim()))
        }
    };
    let made =
        tar(vec!["-czf".as_ref(), temporary.as_os_str(), "-C".as_ref(), parent.as_os_str(), name])
            .and_then(|()| tar(vec!["-tzf".as_ref(), temporary.as_os_str()]))
            .and_then(|()| std::fs::rename(&temporary, &dest).map_err(|e| e.to_string()));
    if let Err(error) = made {
        let _ = std::fs::remove_file(&temporary);
        return Err(error);
    }
    Ok(dest.strip_prefix(&store.dir).unwrap_or(&dest).to_string_lossy().into_owned())
}

/// The last-moment checks, the archive of a machine, then its program's delete.
pub(crate) fn remove(
    options: &crate::caches::Options,
    family: &Family,
    path: &Path,
    bytes: u64,
) -> Result<Option<Outcome>, Verdict> {
    let Source::Vms { vm, shape, program } = &family.source else { return Ok(None) };
    if let Some(glob) = options.never.holds(options.home, path) {
        return Err(keep(format!("never-delete: {glob}")));
    }
    let inside = match shape {
        Shape::Machines => path.parent() == Some(family.root.as_path()),
        Shape::OciImages => path.starts_with(&family.root),
    };
    if !real_dir(path) || !inside || !path.starts_with(options.home) {
        return Err(keep("no longer a VM folder of its family"));
    }
    let fresh = |what: &str| -> Result<(), Verdict> {
        let again = crate::caches::decide(
            family,
            crate::caches::last_activity(path),
            options.pressure,
            crate::inventory::now_ms(),
        );
        if again.action == Action::Reclaim {
            Ok(())
        } else {
            Err(keep(format!("{what}{}", again.reason)))
        }
    };
    let idle = || -> Result<Vec<Listed>, Verdict> {
        let listed =
            list(*vm, program).map_err(|e| keep(format!("cannot tell which VMs run: {e}")))?;
        let names = names_of(family, *shape, &listed, path);
        if let Some(running) = names.iter().find(|l| l.running) {
            return Err(keep(format!("{} is running", running.name)));
        }
        match (options.open)(path) {
            Ok(Some(pid)) => return Err(keep(format!("open in pid {pid}"))),
            Ok(None) => {}
            Err(error) => return Err(keep(format!("could not check open files: {error}"))),
        }
        if names.is_empty() {
            return Err(keep("its program does not list it"));
        }
        Ok(names)
    };
    fresh("")?;
    idle()?;
    if let Some(why) = options.never.holds_tree(options.home, path) {
        return Err(keep(format!("never-delete: {why}")));
    }
    let mut archived = None;
    if family.kind == Kind::Unique {
        let Some(store) = options.store else {
            return Err(keep("no archive store: unique data stays"));
        };
        let id = archive(store, family, path, crate::inventory::now_ms())
            .map_err(|e| keep(format!("not archived: {e}")))?;
        archived = Some(id);
        // It may have started or changed while the archive was written.
        fresh("changed while archived: ")?;
    }
    let mut names = idle()?;
    // Tags first, so the digest folder goes last.
    names.sort_by_key(|l| l.name.contains("@sha256:"));
    for listed in &names {
        let deleted = match vm {
            Vm::Tart => run(program, &["delete", &listed.name], DELETE),
            Vm::Lume => run(program, &["delete", &listed.name, "--force"], DELETE),
        };
        if let Err(error) = deleted {
            return Ok(Some(Outcome {
                ok: false,
                freed: 0,
                archive: archived,
                error: Some(error),
            }));
        }
    }
    if path.exists() {
        return Ok(Some(Outcome {
            ok: false,
            freed: 0,
            archive: archived,
            error: Some("its program left the folder in place".into()),
        }));
    }
    Ok(Some(Outcome { ok: true, freed: bytes, archive: archived, error: None }))
}

#[cfg(test)]
#[path = "vm_images_tests.rs"]
mod tests;
