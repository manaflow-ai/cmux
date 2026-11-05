//! The image's store (web/scripts/cmux-vm-image/lock.ts, plans/cmux-next/vm-image.md 4.5):
//! `/opt/cmux/store/<sha256>/` holds one immutable package, `/opt/cmux/profiles/<n>/bin`
//! is a symlink farm into it, and `/opt/cmux/current` points at one profile.
//! Every unit and `PATH` names only `/opt/cmux/current/bin`, as do the work
//! user's `~/.cmux/bin/cmux-tui` and `~/.local/bin/acpmux` links, so one
//! `rename(2)` of `current` moves every one of them to another build.
//!
//! An update adds a profile that is a copy of the current one with the
//! cmux-tui and cmux-tui-hook links pointed at their new store entries
//! (every other program stays as the image baked it), then flips `current`.
//! A rollback flips it back. Every path is resolved under a root, so tests
//! run all of it in a temporary folder.

use std::fs;
use std::io::{self, Read as _};
use std::path::{Path, PathBuf};

use sha2::{Digest as _, Sha256};

use super::channel::lower_hex;
use crate::config::Paths;

pub const STORE_ROOT: &str = "/opt/cmux";
pub const STORE_DIR: &str = "/opt/cmux/store";
pub const PROFILES_DIR: &str = "/opt/cmux/profiles";
pub const CURRENT_LINK: &str = "/opt/cmux/current";
/// The generation the bake creates; it is never removed.
pub const BAKED_GENERATION: u64 = 1;
/// Profiles kept besides the current one and the baked one.
pub const KEEP_PROFILES: usize = 3;

fn other(message: impl Into<String>) -> io::Error {
    io::Error::other(message.into())
}

/// The generation `current` points at (`profiles/<n>`).
pub fn current_generation(paths: &Paths) -> io::Result<u64> {
    let target = fs::read_link(paths.at(CURRENT_LINK))?;
    let text = target.to_string_lossy();
    let n = text.trim_end_matches('/').rsplit('/').next().unwrap_or_default();
    n.parse().map_err(|_| other(format!("{CURRENT_LINK} points at {text}, not a profile")))
}

pub fn profile_dir(paths: &Paths, generation: u64) -> PathBuf {
    paths.at(PROFILES_DIR).join(generation.to_string())
}

/// Every generation in `profiles/`, ascending.
pub fn generations(paths: &Paths) -> Vec<u64> {
    let mut out: Vec<u64> = fs::read_dir(paths.at(PROFILES_DIR))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().to_str()?.parse().ok())
        .collect();
    out.sort_unstable();
    out
}

/// The store entry (sha256) a profile's `bin/<command>` link points into.
pub fn linked_package(paths: &Paths, generation: u64, command: &str) -> io::Result<String> {
    let link = profile_dir(paths, generation).join("bin").join(command);
    let target = fs::read_link(&link)?;
    package_of(&target).ok_or_else(|| {
        other(format!("{} points at {}, not a store entry", link.display(), target.display()))
    })
}

/// `<sha>` of `/opt/cmux/store/<sha>/<file…>`.
fn package_of(target: &Path) -> Option<String> {
    let rest = target.strip_prefix(STORE_DIR).ok()?;
    let sha = rest.components().next()?.as_os_str().to_str()?;
    lower_hex(sha, 64).then(|| sha.to_owned())
}

/// The lowercase hex SHA-256 of a file.
pub fn sha256_file(path: &Path) -> io::Result<String> {
    let mut file = fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 16];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(buf.get(..n).unwrap_or_default());
    }
    Ok(hasher.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// Whether `store/<sha>/<file>` is there with that sha256.
pub fn has_entry(paths: &Paths, sha: &str, file: &str) -> bool {
    let path = paths.at(STORE_DIR).join(sha).join(file);
    sha256_file(&path).is_ok_and(|got| got == sha)
}

/// Moves a downloaded, checked file into `store/<sha>/<file>` (0555, the
/// folder read-only), as the bake's install does: staged beside, renamed.
pub fn add_entry(paths: &Paths, sha: &str, file: &str, downloaded: &Path) -> io::Result<()> {
    if !lower_hex(sha, 64) {
        return Err(other("not a sha256"));
    }
    if sha256_file(downloaded)? != sha {
        return Err(other(format!("{} does not have sha256 {sha}", downloaded.display())));
    }
    let store = paths.at(STORE_DIR);
    let entry = store.join(sha);
    let stage = store.join(format!("{sha}.partial"));
    remove_tree(&stage)?;
    fs::create_dir_all(&stage)?;
    let staged = stage.join(file);
    if fs::rename(downloaded, &staged).is_err() {
        fs::copy(downloaded, &staged)?;
        let _ = fs::remove_file(downloaded);
    }
    set_mode(&staged, 0o555)?;
    set_mode(&stage, 0o555)?;
    remove_tree(&entry)?;
    fs::rename(&stage, &entry)
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt as _;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) -> io::Result<()> {
    Ok(())
}

/// Removes a tree whose folders may be read-only (store entries are).
fn remove_tree(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
        Ok(meta) if !meta.is_dir() => return fs::remove_file(path),
        Ok(_) => {}
    }
    for entry in fs::read_dir(path)?.flatten() {
        let p = entry.path();
        if entry.file_type()?.is_dir() {
            set_mode(&p, 0o755)?;
        }
    }
    set_mode(path, 0o755)?;
    fs::remove_dir_all(path)
}

/// Builds `profiles/<to>` as a copy of `profiles/<from>` whose links into
/// a `replace` source entry point at the same file in its destination
/// entry. Staged beside and renamed; an existing `<to>` is replaced.
pub fn build_profile(
    paths: &Paths,
    from: u64,
    to: u64,
    replace: &[(String, String)],
) -> io::Result<()> {
    let source = profile_dir(paths, from);
    let profiles = paths.at(PROFILES_DIR);
    let stage = profiles.join(format!(".{to}.partial"));
    remove_tree(&stage)?;
    copy_links(&source, &stage, replace)?;
    let dest = profile_dir(paths, to);
    remove_tree(&dest)?;
    fs::rename(&stage, &dest)
}

fn copy_links(from: &Path, to: &Path, replace: &[(String, String)]) -> io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)?.flatten() {
        let kind = entry.file_type()?;
        let dest = to.join(entry.file_name());
        if kind.is_dir() {
            copy_links(&entry.path(), &dest, replace)?;
        } else if kind.is_symlink() {
            let target = fs::read_link(entry.path())?;
            let target = match package_of(&target) {
                Some(sha) => match replace.iter().find(|(old, _)| *old == sha) {
                    Some((_, new)) => {
                        let file = target
                            .strip_prefix(Path::new(STORE_DIR).join(&sha))
                            .map_err(|_| other("a store link outside its entry"))?;
                        Path::new(STORE_DIR).join(new).join(file)
                    }
                    None => target,
                },
                None => target,
            };
            symlink(&target, &dest)?;
        } else {
            return Err(other(format!(
                "{} is not a link: a profile holds only links",
                entry.path().display()
            )));
        }
    }
    Ok(())
}

#[cfg(unix)]
fn symlink(target: &Path, link: &Path) -> io::Result<()> {
    std::os::unix::fs::symlink(target, link)
}

#[cfg(not(unix))]
fn symlink(_target: &Path, _link: &Path) -> io::Result<()> {
    Err(other("symlinks need a Unix host"))
}

/// Points `current` at `profiles/<generation>` with one rename.
pub fn flip(paths: &Paths, generation: u64) -> io::Result<()> {
    if !profile_dir(paths, generation).is_dir() {
        return Err(other(format!("profile {generation} does not exist")));
    }
    let root = paths.at(STORE_ROOT);
    let next = root.join(".current-new");
    let _ = fs::remove_file(&next);
    symlink(Path::new(&format!("profiles/{generation}")), &next)?;
    fs::rename(&next, paths.at(CURRENT_LINK))
}

/// Removes profiles past [`KEEP_PROFILES`] (never the current, the baked
/// one or one in `keep`), then the store entries in `ours` (the ones
/// updates added) that no remaining profile links to. Returns what went.
pub fn gc(paths: &Paths, keep: &[u64], ours: &[String]) -> (Vec<u64>, Vec<String>) {
    let current = current_generation(paths).ok();
    let mut gens = generations(paths);
    gens.reverse();
    let mut removed = Vec::new();
    for (i, generation) in gens.iter().enumerate() {
        let kept = i < KEEP_PROFILES
            || Some(*generation) == current
            || *generation == BAKED_GENERATION
            || keep.contains(generation);
        if !kept && remove_tree(&profile_dir(paths, *generation)).is_ok() {
            removed.push(*generation);
        }
    }
    let mut linked = std::collections::BTreeSet::new();
    for generation in generations(paths) {
        collect_packages(&profile_dir(paths, generation), &mut linked);
    }
    let mut gone = Vec::new();
    for sha in ours {
        if !linked.contains(sha) && remove_tree(&paths.at(STORE_DIR).join(sha)).is_ok() {
            gone.push(sha.clone());
        }
    }
    (removed, gone)
}

fn collect_packages(dir: &Path, out: &mut std::collections::BTreeSet<String>) {
    for entry in fs::read_dir(dir).into_iter().flatten().flatten() {
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_dir() {
            collect_packages(&entry.path(), out);
        } else if let Ok(target) = fs::read_link(entry.path())
            && let Some(sha) = package_of(&target)
        {
            out.insert(sha);
        }
    }
}
