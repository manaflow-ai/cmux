//! The customization tree: every file a person or an agent changes to
//! customize cmux, under one set of logical paths.
//!
//! cmux already hot reloads each of these on save (the settings owner's
//! watcher, the theme folder watcher, the customize app's local reload, the
//! automations runner), so a write to the live tree *is* the preview. This
//! module only names the files and reads and writes them; it starts no
//! watcher and no timer.

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::paths::Roots;

/// A file larger than this is left out of generations and named in
/// [`Scan::skipped`]: a customization is text, not media.
pub const MAX_FILE_BYTES: u64 = 2 * 1024 * 1024;
/// More files than this in one part is a mistake (a `node_modules`), not a
/// customization; the rest are named in [`Scan::skipped`].
pub const MAX_FILES_PER_PART: usize = 2000;

/// One kind of customization. The table in [`Part::ALL`] is the whole
/// definition of what a generation holds: adding a row adds a part.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Part {
    Settings,
    Keybindings,
    Themes,
    Views,
    Styles,
    Automations,
}

impl Part {
    pub const ALL: &'static [Part] = &[
        Part::Settings,
        Part::Keybindings,
        Part::Themes,
        Part::Views,
        Part::Styles,
        Part::Automations,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Part::Settings => "settings",
            Part::Keybindings => "keybindings",
            Part::Themes => "themes",
            Part::Views => "views",
            Part::Styles => "styles",
            Part::Automations => "automations",
        }
    }

    /// One line a person or an agent reads to know what the part is.
    pub fn about(self) -> &'static str {
        match self {
            Part::Settings => "settings (every key in `cmux settings list`)",
            Part::Keybindings => "keyboard shortcuts",
            Part::Themes => "theme files (colors, type, slots); pick one with appearance.themeFile",
            Part::Views => {
                "your own views app (sidebar sections, panes, widgets, commands): cmux-app.json + main.js"
            }
            Part::Styles => "per-surface stylesheets (agent-pane/theme.css and the like)",
            Part::Automations => "automations (when X happens, do Y): one automation.json each",
        }
    }

    /// The part a logical path belongs to.
    pub fn of(path: &str) -> Part {
        match path.split('/').next().unwrap_or_default() {
            SETTINGS => Part::Settings,
            "keybindings.json" => Part::Keybindings,
            "themes" => Part::Themes,
            "customize" => Part::Views,
            "automations" => Part::Automations,
            _ => Part::Styles,
        }
    }
}

/// The settings file's logical path, whatever the file is called on disk.
pub const SETTINGS: &str = "settings.json";
/// Surfaces with a user stylesheet (`<config dir>/<surface>/theme.css`).
const STYLE_SURFACES: &[&str] = &["agent-pane", "markdown", "diff", "picker", "fileViewer"];

/// One file of a tree, by content.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub sha: String,
    pub size: u64,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub exec: bool,
}

/// Logical path to content, in path order.
pub type Tree = BTreeMap<String, Entry>;

/// A file the scan left out, and why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Skipped {
    pub path: String,
    pub reason: String,
}

/// The live tree as read.
#[derive(Debug, Default)]
pub struct Scan {
    pub tree: Tree,
    pub skipped: Vec<Skipped>,
    /// The newest modification time among the files, in milliseconds.
    pub newest_ms: u64,
    /// Modification time per path, in milliseconds.
    pub mtimes: BTreeMap<String, u64>,
}

pub fn sha256(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(64);
    for byte in digest {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// Where a logical path is on disk; `None` for a path no part owns (a
/// manifest from a newer cmux, or a tampered one: never written).
pub fn locate(roots: &Roots, path: &str) -> Option<PathBuf> {
    if path.is_empty()
        || path.split('/').any(|piece| piece.is_empty() || piece == "." || piece == "..")
    {
        return None;
    }
    if path.contains('\\') || Path::new(path).is_absolute() {
        return None;
    }
    let (first, rest) = path.split_once('/').unwrap_or((path, ""));
    match (first, rest) {
        (SETTINGS, "") => Some(roots.settings_file.clone()),
        ("keybindings.json", "") => Some(cmux_config::keybindings_path(&roots.settings_file)),
        ("customize", rest) if !rest.is_empty() => Some(roots.customize_dir.join(rest)),
        ("themes", rest) if !rest.is_empty() => Some(roots.config_dir.join("themes").join(rest)),
        ("automations", rest)
            if rest.ends_with("/automation.json") && rest.matches('/').count() == 1 =>
        {
            Some(roots.config_dir.join("automations").join(rest))
        }
        (surface, "theme.css") if STYLE_SURFACES.contains(&surface) => {
            Some(roots.config_dir.join(surface).join("theme.css"))
        }
        _ => None,
    }
}

/// Whether the scan would read `path`: a path a part owns that is no dot
/// file, editor backup or `node_modules` entry, and for a theme a `.json`.
/// Only such a path may be written by a profile, because only such a path is
/// in the generation a discard puts back.
pub fn tracked(roots: &Roots, path: &str) -> bool {
    locate(roots, path).is_some()
        && !path.split('/').any(hidden_name)
        && (!path.starts_with("themes/") || path.ends_with(".json"))
}

/// Why writing `path` could lose something for good, given the tree a scan
/// just read: `None` when the write is safe. Safe is a file the scan read
/// (a generation holds its content before the write), or a place where
/// nothing is yet and every folder on the way is a real folder. Anything
/// else is on disk without a copy: a file too large or past the count the
/// scan keeps, or a folder that is a link into somewhere the scan never
/// reads (a dotfiles repo), which a write would follow.
pub fn in_the_way(roots: &Roots, path: &str, live: &Tree) -> Option<Skipped> {
    if live.contains_key(path) {
        return None;
    }
    let skipped = |reason: &str| Some(Skipped { path: path.to_owned(), reason: reason.to_owned() });
    let Some(file) = locate(roots, path) else { return skipped("not a customization path") };
    // `customize/a/b.js`: `customize/a` must be a folder of its own. The
    // part's root may be a link; the scan reads through that one.
    let mut folder = file.parent();
    for _ in 1..path.matches('/').count() {
        let Some(dir) = folder else { break };
        match fs::symlink_metadata(dir) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return skipped("inside a linked folder, which cmux does not read");
            }
            Ok(metadata) if !metadata.is_dir() => return skipped("its folder is a file"),
            _ => {}
        }
        folder = dir.parent();
    }
    match fs::symlink_metadata(&file) {
        Err(_) => None,
        Ok(metadata) if metadata.is_file() && metadata.len() > MAX_FILE_BYTES => {
            skipped(&format!("larger than {} MiB", MAX_FILE_BYTES / 1024 / 1024))
        }
        Ok(_) => skipped("on disk, and not a file cmux keeps a copy of"),
    }
}

/// A name the scan steps over.
fn hidden_name(name: &str) -> bool {
    name.starts_with('.') || name.ends_with('~') || name == "node_modules"
}

/// Reads the live tree. A missing file or folder is simply absent.
pub fn scan(roots: &Roots) -> io::Result<Scan> {
    let mut scan = Scan::default();
    add_file(&mut scan, SETTINGS, &roots.settings_file)?;
    add_file(&mut scan, "keybindings.json", &cmux_config::keybindings_path(&roots.settings_file))?;
    add_dir(&mut scan, "themes", &roots.config_dir.join("themes"), &|name| {
        name.ends_with(".json")
    })?;
    add_dir(&mut scan, "customize", &roots.customize_dir, &|_| true)?;
    for surface in STYLE_SURFACES {
        add_file(
            &mut scan,
            &format!("{surface}/theme.css"),
            &roots.config_dir.join(surface).join("theme.css"),
        )?;
    }
    let automations = roots.config_dir.join("automations");
    for name in sorted_names(&automations)? {
        if name.starts_with('.') {
            continue;
        }
        add_file(
            &mut scan,
            &format!("automations/{name}/automation.json"),
            &automations.join(&name).join("automation.json"),
        )?;
    }
    Ok(scan)
}

/// The bytes of one live file; `None` when it is not there.
pub fn read(roots: &Roots, path: &str) -> io::Result<Option<Vec<u8>>> {
    let Some(file) = locate(roots, path) else { return Ok(None) };
    match fs::read(file) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

/// Writes one live file atomically, through a symlink when the file is one
/// (a dotfiles repo keeps its link).
pub fn write(roots: &Roots, path: &str, bytes: &[u8], exec: bool) -> io::Result<()> {
    let file = locate(roots, path).ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, format!("{path}: not a customization path"))
    })?;
    let target = cmux_config::fsio::resolve_symlinks(&file);
    cmux_config::fsio::write_atomic(&target, bytes)?;
    set_exec(&target, exec)
}

/// Removes one live file, then its folder when that left it empty (never
/// the part's own root).
pub fn remove(roots: &Roots, path: &str) -> io::Result<()> {
    let Some(file) = locate(roots, path) else { return Ok(()) };
    match fs::remove_file(&file) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    // `customize/a/b.js` may leave `customize/a` empty; `customize` stays.
    let depth = path.matches('/').count();
    let mut dir = file.parent();
    for _ in 1..depth {
        let Some(folder) = dir else { break };
        if fs::remove_dir(folder).is_err() {
            break;
        }
        dir = folder.parent();
    }
    Ok(())
}

#[cfg(unix)]
fn set_exec(path: &Path, exec: bool) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut permissions = fs::metadata(path)?.permissions();
    let mode = permissions.mode();
    let wanted = if exec { mode | 0o100 } else { mode & !0o111 };
    if wanted != mode {
        permissions.set_mode(wanted);
        fs::set_permissions(path, permissions)?;
    }
    Ok(())
}

#[cfg(not(unix))]
fn set_exec(_path: &Path, _exec: bool) -> io::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn is_exec(metadata: &fs::Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;
    metadata.permissions().mode() & 0o100 != 0
}

#[cfg(not(unix))]
fn is_exec(_metadata: &fs::Metadata) -> bool {
    false
}

fn sorted_names(dir: &Path) -> io::Result<Vec<String>> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error)
            if matches!(error.kind(), io::ErrorKind::NotFound | io::ErrorKind::NotADirectory) =>
        {
            return Ok(Vec::new());
        }
        Err(error) => return Err(error),
    };
    let mut names = Vec::new();
    for entry in entries {
        if let Some(name) = entry?.file_name().to_str() {
            names.push(name.to_owned());
        }
    }
    names.sort();
    Ok(names)
}

fn add_file(scan: &mut Scan, logical: &str, file: &Path) -> io::Result<()> {
    // `metadata` follows a link: a linked settings file is its target's text.
    let metadata = match fs::metadata(file) {
        Ok(metadata) => metadata,
        Err(error)
            if matches!(error.kind(), io::ErrorKind::NotFound | io::ErrorKind::NotADirectory) =>
        {
            return Ok(());
        }
        Err(error) => return Err(error),
    };
    if !metadata.is_file() {
        return Ok(());
    }
    if metadata.len() > MAX_FILE_BYTES {
        scan.skipped.push(Skipped {
            path: logical.to_owned(),
            reason: format!("larger than {} MiB", MAX_FILE_BYTES / 1024 / 1024),
        });
        return Ok(());
    }
    let bytes = fs::read(file)?;
    let modified = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |since| since.as_millis() as u64);
    scan.newest_ms = scan.newest_ms.max(modified);
    scan.mtimes.insert(logical.to_owned(), modified);
    scan.tree.insert(
        logical.to_owned(),
        Entry { sha: sha256(&bytes), size: bytes.len() as u64, exec: is_exec(&metadata) },
    );
    Ok(())
}

/// Every file under `dir` that `keep` takes, as `<prefix>/<relative path>`.
/// Dot files, editor backups, `node_modules` and linked folders are left out,
/// the way `cmux ext dev` leaves them out.
fn add_dir(
    scan: &mut Scan,
    prefix: &str,
    dir: &Path,
    keep: &dyn Fn(&str) -> bool,
) -> io::Result<()> {
    let mut pending = vec![(prefix.to_owned(), dir.to_path_buf())];
    let mut count = 0usize;
    while let Some((logical_dir, folder)) = pending.pop() {
        for name in sorted_names(&folder)? {
            if hidden_name(&name) {
                continue;
            }
            let path = folder.join(&name);
            let logical = format!("{logical_dir}/{name}");
            let Ok(link) = fs::symlink_metadata(&path) else { continue };
            if link.is_dir() {
                pending.push((logical, path));
            } else if fs::metadata(&path).is_ok_and(|target| target.is_file()) && keep(&name) {
                count += 1;
                if count > MAX_FILES_PER_PART {
                    scan.skipped.push(Skipped {
                        path: logical,
                        reason: format!("more than {MAX_FILES_PER_PART} files in {prefix}"),
                    });
                    continue;
                }
                add_file(scan, &logical, &path)?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_outside_every_part_is_never_located() {
        let roots = Roots::under(Path::new("/r"));
        for path in [
            "",
            "../x",
            "customize/../../x",
            "/etc/passwd",
            "cloud-secrets.json",
            "automations/a/state.json",
            "automations/a/b/automation.json",
            "themes",
            "customize",
            "agent-pane/registry.js",
            "customize\\x",
        ] {
            assert_eq!(locate(&roots, path), None, "{path}");
        }
        assert_eq!(locate(&roots, SETTINGS), Some(PathBuf::from("/r/config/cmux-next.json")));
        assert_eq!(
            locate(&roots, "automations/auto_1/automation.json"),
            Some(PathBuf::from("/r/config/automations/auto_1/automation.json"))
        );
    }

    #[test]
    fn every_located_path_names_its_part() {
        assert_eq!(Part::of(SETTINGS), Part::Settings);
        assert_eq!(Part::of("themes/night.json"), Part::Themes);
        assert_eq!(Part::of("customize/main.js"), Part::Views);
        assert_eq!(Part::of("agent-pane/theme.css"), Part::Styles);
        assert_eq!(Part::of("automations/auto_1/automation.json"), Part::Automations);
    }
}
