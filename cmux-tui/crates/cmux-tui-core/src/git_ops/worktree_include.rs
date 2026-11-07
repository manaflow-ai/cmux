//! `.worktreeinclude`: the files a new worktree needs that git does not
//! give it (`.env`, a local settings file, an installed dependency folder).
//! `git.worktree.create` copies them from the main checkout.
//!
//! The syntax is close to `.gitignore`, with the rules of the earlier
//! worktree-seed reader:
//!
//! - Every pattern is a path from the repository root: `.env` is the root's
//!   `.env` and nothing else, so no pattern walks the whole tree unless it
//!   writes `**`. A leading `/`, a `~` or a `..` segment is a problem, not a
//!   pattern: copying never reaches outside the repository.
//! - `*` and `?` match within one name, `**` any number of folders; a
//!   trailing `/` matches folders only; `!` takes back what an earlier
//!   pattern selected (the last match wins); `#` starts a comment and `\`
//!   escapes a leading `!` or `#`.
//! - A matched folder is copied whole, less what a later `!` takes back.
//! - A symlink is a leaf, as git reads one: the walk never goes through
//!   one, and one is copied (as a link) only when what it points at
//!   resolves inside the repository.
//! - Nothing in the new worktree is overwritten, so a tracked file stays as
//!   the branch has it, and nothing is written through a symlink out of it.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// The file at the repository root that lists what to copy.
pub(crate) const FILE_NAME: &str = ".worktreeinclude";
/// The folders the walk may visit, for every pattern together.
const MAX_VISITED_DIRECTORIES: usize = 20_000;
/// The paths a report lists in each of its lists.
const MAX_LISTED: usize = 20;

/// One pattern line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Pattern {
    segments: Vec<String>,
    negated: bool,
    directory_only: bool,
}

/// The patterns of some lines, and the lines that are not patterns.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Patterns {
    pub patterns: Vec<Pattern>,
    pub problems: Vec<String>,
}

/// Reads pattern lines (the file's, or a saved list's).
pub(crate) fn parse<'a>(lines: impl IntoIterator<Item = &'a str>) -> Patterns {
    let mut parsed = Patterns::default();
    for (index, line) in lines.into_iter().enumerate() {
        match pattern(line) {
            Ok(Some(pattern)) => parsed.patterns.push(pattern),
            Ok(None) => {}
            Err(reason) => {
                parsed.problems.push(format!("line {}: {}: {reason}", index + 1, line.trim()));
            }
        }
    }
    parsed
}

fn pattern(line: &str) -> Result<Option<Pattern>, &'static str> {
    let text = trim_line(line);
    if text.is_empty() || text.starts_with('#') {
        return Ok(None);
    }
    let (negated, rest) = match text.strip_prefix('!') {
        Some(rest) => (true, rest.trim_start()),
        None => (false, text.as_str()),
    };
    let rest = match rest.strip_prefix('\\') {
        Some(escaped) if escaped.starts_with(['!', '#']) => escaped,
        _ => rest,
    };
    if rest.starts_with('/') {
        return Err("patterns start at the repository root already; drop the leading /");
    }
    if rest.starts_with('~') {
        return Err("a pattern cannot start at the home folder");
    }
    let directory_only = rest.ends_with('/');
    let segments: Vec<String> =
        rest.split('/').filter(|segment| !segment.is_empty()).map(str::to_string).collect();
    if segments.is_empty() {
        return Err("nothing is left of this line to match");
    }
    if segments.iter().any(|segment| segment == ".." || segment == ".") {
        return Err("a pattern cannot contain . or ..; copying stays inside the repository");
    }
    Ok(Some(Pattern { segments, negated, directory_only }))
}

/// Leading whitespace goes; trailing whitespace too, except one a `\`
/// escaped (a name can end in a space).
fn trim_line(line: &str) -> String {
    let mut text: Vec<char> = line.trim_start().chars().collect();
    while matches!(text.last(), Some(' ' | '\t' | '\r')) {
        let escapes = text[..text.len() - 1].iter().rev().take_while(|c| **c == '\\').count();
        if escapes % 2 == 1 {
            text.remove(text.len() - 2);
            break;
        }
        text.pop();
    }
    text.into_iter().collect()
}

/// What a copy did, for the setup output and the status.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Report {
    /// Files and links made in the new worktree.
    pub copied: u64,
    /// Paths left alone because the worktree already has them.
    pub kept: u64,
    /// Links left out because they point outside the repository.
    pub outside: Vec<String>,
    /// Lines that are not patterns, and paths that could not be copied.
    pub problems: Vec<String>,
}

impl Report {
    fn note(list: &mut Vec<String>, entry: String) {
        if list.len() < MAX_LISTED {
            list.push(entry);
        }
    }
}

/// Copies what `patterns` select from `source` (the main checkout) into
/// `destination` (the new worktree), until `cancelled` says to stop.
pub(crate) fn copy(
    source: &Path,
    destination: &Path,
    patterns: &Patterns,
    cancelled: &dyn Fn() -> bool,
) -> Report {
    let mut report = Report::default();
    for problem in &patterns.problems {
        Report::note(&mut report.problems, problem.clone());
    }
    let (Ok(source_root), Ok(destination_root)) =
        (fs::canonicalize(source), fs::canonicalize(destination))
    else {
        Report::note(&mut report.problems, "the checkout or the worktree is gone".into());
        return report;
    };
    let mut copier =
        Copier { source_root, destination_root, report, patterns: &patterns.patterns, cancelled };
    let (paths, ran_out) = select(&copier.source_root, &patterns.patterns);
    if ran_out {
        Report::note(
            &mut copier.report.problems,
            format!(
                "stopped looking after {MAX_VISITED_DIRECTORIES} folders: some matches are not copied"
            ),
        );
    }
    for path in paths {
        copier.entry(&path);
    }
    copier.report
}

/// The paths (relative to `root`) the patterns select: each positive
/// pattern's matches that [`deciding`] keeps, and whether
/// the walk stopped at its folder budget before it was done.
pub(crate) fn select(root: &Path, patterns: &[Pattern]) -> (Vec<PathBuf>, bool) {
    let mut budget = Budget { left: MAX_VISITED_DIRECTORIES, ran_out: false };
    let mut found = BTreeSet::new();
    for pattern in patterns.iter().filter(|pattern| !pattern.negated) {
        expand(
            root,
            Path::new(""),
            &pattern.segments,
            pattern.directory_only,
            &mut budget,
            &mut found,
        );
    }
    let selected = found
        .into_iter()
        .filter(|(path, is_directory)| {
            deciding(patterns, path, *is_directory).is_some_and(|pattern| !pattern.negated)
        })
        .map(|(path, _)| path)
        .collect();
    (selected, budget.ran_out)
}

/// The pattern that decides `path`: the last one in the list that matches
/// it or one of its folders, so `!private/` after `**/*.env` keeps
/// `private/token.env` out, and `private/*.env` after `!private/` takes it
/// back.
fn deciding<'a>(patterns: &'a [Pattern], path: &Path, is_directory: bool) -> Option<&'a Pattern> {
    let names: Vec<String> = path.iter().map(|name| name.to_string_lossy().into_owned()).collect();
    patterns.iter().rev().find(|pattern| {
        (1..=names.len()).any(|depth| {
            let folder = depth < names.len() || is_directory;
            (!pattern.directory_only || folder) && matches(&pattern.segments, &names[..depth])
        })
    })
}

/// Adds to `found` the paths under `relative` that `segments` reach, with
/// whether each is a folder. Never goes through a symlink or into `.git`.
fn expand(
    root: &Path,
    relative: &Path,
    segments: &[String],
    directory_only: bool,
    budget: &mut Budget,
    found: &mut BTreeSet<(PathBuf, bool)>,
) {
    let Some((segment, rest)) = segments.split_first() else { return };
    if segment == "**" {
        // A trailing `**` is everything under the folder: each entry, a
        // folder copied whole.
        if rest.is_empty() {
            for (name, is_directory) in children(root, relative, budget) {
                if !directory_only || is_directory {
                    found.insert((relative.join(name), is_directory));
                }
            }
            return;
        }
        expand(root, relative, rest, directory_only, budget, found);
        for (name, is_directory) in children(root, relative, budget) {
            if is_directory {
                expand(root, &relative.join(name), segments, directory_only, budget, found);
            }
        }
        return;
    }
    let candidates: Vec<(String, bool)> = if is_glob(segment) {
        children(root, relative, budget)
            .into_iter()
            .filter(|(name, _)| glob(segment.as_bytes(), name.as_bytes()))
            .collect()
    } else {
        match fs::symlink_metadata(root.join(relative).join(segment)) {
            Ok(metadata) => vec![(segment.clone(), metadata.is_dir())],
            Err(_) => Vec::new(),
        }
    };
    for (name, is_directory) in candidates {
        if name == ".git" {
            continue;
        }
        let path = relative.join(&name);
        if rest.is_empty() {
            if !directory_only || is_directory {
                found.insert((path, is_directory));
            }
        } else if is_directory {
            expand(root, &path, rest, directory_only, budget, found);
        }
    }
}

/// The folders a walk may still visit.
struct Budget {
    left: usize,
    ran_out: bool,
}

/// A folder's entries, with whether each is a real folder (a symlink to one
/// is not), while the budget lasts.
fn children(root: &Path, relative: &Path, budget: &mut Budget) -> Vec<(String, bool)> {
    if budget.left == 0 {
        budget.ran_out = true;
        return Vec::new();
    }
    budget.left -= 1;
    let Ok(entries) = fs::read_dir(root.join(relative)) else { return Vec::new() };
    let mut listed: Vec<(String, bool)> = entries
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            let is_directory = entry.file_type().ok()?.is_dir();
            (name != ".git").then_some((name, is_directory))
        })
        .collect();
    listed.sort();
    listed
}

/// Whether a path's names match a pattern's segments.
fn matches(segments: &[String], names: &[String]) -> bool {
    match segments.split_first() {
        None => names.is_empty(),
        Some((segment, rest)) if segment == "**" => {
            (0..=names.len()).any(|skip| matches(rest, &names[skip..]))
        }
        Some((segment, rest)) => names.split_first().is_some_and(|(name, names)| {
            glob(segment.as_bytes(), name.as_bytes()) && matches(rest, names)
        }),
    }
}

fn is_glob(segment: &str) -> bool {
    segment.contains(['*', '?'])
}

/// `*` (any run) and `?` (one byte) within one name.
fn glob(pattern: &[u8], name: &[u8]) -> bool {
    let (mut p, mut n) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while n < name.len() {
        match pattern.get(p) {
            Some(b'*') => {
                star = Some((p, n));
                p += 1;
            }
            Some(b'?') => {
                p += 1;
                n += 1;
            }
            Some(byte) if *byte == name[n] => {
                p += 1;
                n += 1;
            }
            _ => match star {
                Some((star_p, star_n)) => {
                    p = star_p + 1;
                    n = star_n + 1;
                    star = Some((star_p, star_n + 1));
                }
                None => return false,
            },
        }
    }
    pattern[p..].iter().all(|byte| *byte == b'*')
}

struct Copier<'a> {
    source_root: PathBuf,
    destination_root: PathBuf,
    report: Report,
    /// A `!` pattern takes a path back inside a selected folder too.
    patterns: &'a [Pattern],
    cancelled: &'a dyn Fn() -> bool,
}

impl Copier<'_> {
    fn entry(&mut self, relative: &Path) {
        let source = self.source_root.join(relative);
        if (self.cancelled)() {
            return;
        }
        let Ok(metadata) = fs::symlink_metadata(&source) else { return };
        if deciding(self.patterns, relative, metadata.is_dir()).is_some_and(|last| last.negated) {
            return;
        }
        if metadata.is_dir() {
            if let Err(error) = destination::folder(&self.destination_root, relative) {
                self.problem(relative, &error);
                return;
            }
            let Ok(entries) = fs::read_dir(&source) else { return };
            let mut names: Vec<_> = entries.flatten().map(|entry| entry.file_name()).collect();
            names.sort();
            for name in names.into_iter().filter(|name| name != ".git") {
                self.entry(&relative.join(name));
            }
            return;
        }
        let is_link = metadata.file_type().is_symlink();
        if !is_link && !metadata.is_file() {
            Report::note(
                &mut self.report.problems,
                format!("{}: not a regular file", relative.display()),
            );
            return;
        }
        if is_link
            && !fs::canonicalize(&source).is_ok_and(|target| target.starts_with(&self.source_root))
        {
            Report::note(&mut self.report.outside, relative.display().to_string());
            return;
        }
        let made = if is_link {
            fs::read_link(&source)
                .and_then(|target| destination::link(&self.destination_root, relative, &target))
        } else {
            destination::copy(&source, &self.destination_root, relative, &metadata)
        };
        match made {
            Ok(()) => self.report.copied += 1,
            // The worktree's own file (one saved since the walk began too).
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                self.report.kept += 1;
            }
            Err(error) => self.problem(relative, &error),
        }
    }

    fn problem(&mut self, relative: &Path, error: &std::io::Error) {
        let entry = if destination::is_link_error(error) {
            format!("{}: the worktree has a link there", relative.display())
        } else {
            format!("{}: {error}", relative.display())
        };
        Report::note(&mut self.report.problems, entry);
    }
}

/// Writes into the worktree one name at a time from its root, never
/// through a link: a folder swapped for a link mid-copy fails the write
/// instead of carrying it out of the worktree.
#[cfg(unix)]
mod destination {
    use std::ffi::{CString, OsStr};
    use std::fs::{self, File};
    use std::io;
    use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};
    use std::os::unix::ffi::OsStrExt as _;
    use std::os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _};
    use std::path::{Component, Path};

    fn name(name: &OsStr) -> io::Result<CString> {
        CString::new(name.as_bytes()).map_err(|_| io::ErrorKind::InvalidInput.into())
    }

    fn opened(fd: libc::c_int) -> io::Result<OwnedFd> {
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a descriptor openat(2) just returned, owned by no one else.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    /// The folder `relative` names under `root`, made where missing.
    pub(super) fn folder(root: &Path, relative: &Path) -> io::Result<OwnedFd> {
        let root = name(root.as_os_str())?;
        let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC;
        // SAFETY: a NUL-terminated path; the result is checked.
        let mut folder = opened(unsafe { libc::open(root.as_ptr(), flags) })?;
        for component in relative.components() {
            let Component::Normal(part) = component else {
                return Err(io::ErrorKind::InvalidInput.into());
            };
            let part = name(part)?;
            // SAFETY: a live descriptor and a NUL-terminated name.
            if unsafe { libc::mkdirat(folder.as_raw_fd(), part.as_ptr(), 0o777) } < 0 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::AlreadyExists {
                    return Err(error);
                }
            }
            // SAFETY: as above; O_NOFOLLOW refuses a link in the folder's place.
            folder = opened(unsafe {
                libc::openat(folder.as_raw_fd(), part.as_ptr(), flags | libc::O_NOFOLLOW)
            })?;
        }
        Ok(folder)
    }

    fn split(relative: &Path) -> io::Result<(&Path, CString)> {
        let file = relative.file_name().ok_or(io::ErrorKind::InvalidInput)?;
        Ok((relative.parent().unwrap_or(Path::new("")), name(file)?))
    }

    /// A new link at `relative`.
    pub(super) fn link(root: &Path, relative: &Path, target: &Path) -> io::Result<()> {
        let (parent, file) = split(relative)?;
        let folder = folder(root, parent)?;
        let target = name(target.as_os_str())?;
        // SAFETY: a live descriptor and NUL-terminated strings.
        if unsafe { libc::symlinkat(target.as_ptr(), folder.as_raw_fd(), file.as_ptr()) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    /// A new file at `relative` with `source`'s bytes and mode. The create
    /// is exclusive, so a file already there (or saved meanwhile) is kept,
    /// and the source must still be a regular file once open.
    pub(super) fn copy(
        source: &Path,
        root: &Path,
        relative: &Path,
        metadata: &fs::Metadata,
    ) -> io::Result<()> {
        // Non-blocking, so a FIFO put in the file's place cannot hang the copy.
        let mut reader = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(source)?;
        if !reader.metadata()?.is_file() {
            return Err(io::Error::other("not a regular file"));
        }
        let (parent, file) = split(relative)?;
        let folder = folder(root, parent)?;
        let flags =
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        let mode = metadata.permissions().mode() & 0o7777;
        // SAFETY: a live descriptor and a NUL-terminated name; the result is checked.
        let made = opened(unsafe {
            libc::openat(folder.as_raw_fd(), file.as_ptr(), flags, mode as libc::c_uint)
        })?;
        let mut writer = File::from(made);
        if let Err(error) = io::copy(&mut reader, &mut writer) {
            drop(writer);
            // SAFETY: as above; removes only the file this copy made.
            unsafe { libc::unlinkat(folder.as_raw_fd(), file.as_ptr(), 0) };
            return Err(error);
        }
        Ok(())
    }

    /// The error a link where a folder should be gives.
    pub(super) fn is_link_error(error: &io::Error) -> bool {
        matches!(error.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR))
    }
}

#[cfg(not(unix))]
mod destination {
    use std::fs;
    use std::io;
    use std::path::Path;

    pub(super) fn folder(root: &Path, relative: &Path) -> io::Result<()> {
        fs::create_dir_all(root.join(relative))
    }

    pub(super) fn link(_root: &Path, _relative: &Path, _target: &Path) -> io::Result<()> {
        Err(io::Error::other("links are not copied on this platform"))
    }

    pub(super) fn copy(
        source: &Path,
        root: &Path,
        relative: &Path,
        _metadata: &fs::Metadata,
    ) -> io::Result<()> {
        if let Some(parent) = relative.parent() {
            folder(root, parent)?;
        }
        let mut target =
            fs::OpenOptions::new().write(true).create_new(true).open(root.join(relative))?;
        io::copy(&mut fs::File::open(source)?, &mut target).map(|_| ())
    }

    pub(super) fn is_link_error(_error: &io::Error) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(text: &str) -> Patterns {
        parse(text.lines())
    }

    #[test]
    fn parses_like_gitignore_from_the_root() {
        let parsed =
            lines("# env\n.env\n\n!.env.test\nconfig/*.local/\n\\#hash\n/abs\n../out\n~/x\n");
        assert_eq!(parsed.patterns.len(), 4);
        assert!(parsed.patterns[1].negated);
        assert!(parsed.patterns[2].directory_only);
        assert_eq!(parsed.patterns[3].segments, ["#hash"]);
        assert_eq!(parsed.problems.len(), 3);
        assert!(parsed.problems[0].starts_with("line 7"));
    }

    #[test]
    fn keeps_an_escaped_trailing_space() {
        assert_eq!(trim_line("  name\\  "), "name ");
        assert_eq!(trim_line("name \t"), "name");
    }

    #[test]
    fn globs_within_one_name() {
        assert!(glob(b"*.env", b"dev.env"));
        assert!(glob(b".env*", b".env"));
        assert!(glob(b"a?c", b"abc"));
        assert!(!glob(b"*.env", b"dev.env.bak"));
        assert!(matches(&["**".into(), ".env".into()], &["a".into(), "b".into(), ".env".into()]));
        assert!(matches(&["**".into(), ".env".into()], &[".env".into()]));
    }

    fn scratch(name: &str) -> PathBuf {
        let mut bytes = [0_u8; 6];
        getrandom::fill(&mut bytes).unwrap();
        let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        let path = std::env::temp_dir().join(format!("cmux-include-{name}-{hex}"));
        fs::create_dir_all(&path).unwrap();
        fs::canonicalize(path).unwrap()
    }

    #[test]
    fn copies_what_is_selected_and_overwrites_nothing() {
        let source = scratch("source");
        let destination = scratch("destination");
        fs::write(source.join(".env"), "SECRET=1").unwrap();
        fs::write(source.join(".env.test"), "x").unwrap();
        fs::create_dir_all(source.join("app/config")).unwrap();
        fs::write(source.join("app/config/local.json"), "{}").unwrap();
        fs::create_dir_all(source.join("node_modules/pkg")).unwrap();
        fs::write(source.join("node_modules/pkg/index.js"), "1").unwrap();
        fs::write(source.join("tracked.txt"), "main's edit").unwrap();
        fs::write(destination.join("tracked.txt"), "branch").unwrap();
        fs::create_dir_all(source.join("config/deep")).unwrap();
        fs::write(source.join("config/deep/a.json"), "a").unwrap();
        fs::write(source.join("config/private.env"), "p").unwrap();
        fs::create_dir_all(source.join("keys")).unwrap();
        fs::write(source.join("keys/k"), "k").unwrap();
        let patterns = lines(
            ".env*\n!.env.test\n**/local.json\nnode_modules/\ntracked.txt\nconfig/\n!config/private.env\nkeys/**\n",
        );
        let report = copy(&source, &destination, &patterns, &|| false);
        assert_eq!(fs::read_to_string(destination.join(".env")).unwrap(), "SECRET=1");
        assert!(!destination.join(".env.test").exists());
        assert!(destination.join("app/config/local.json").is_file());
        assert!(destination.join("node_modules/pkg/index.js").is_file());
        assert_eq!(fs::read_to_string(destination.join("tracked.txt")).unwrap(), "branch");
        assert!(destination.join("config/deep/a.json").is_file());
        assert!(!destination.join("config/private.env").exists());
        assert!(destination.join("keys/k").is_file());
        assert_eq!(report.copied, 5);
        assert_eq!(report.kept, 1);
        fs::remove_dir_all(source).unwrap();
        fs::remove_dir_all(destination).unwrap();
    }

    #[test]
    fn a_later_folder_pattern_decides_what_is_inside_it() {
        let source = scratch("source");
        let destination = scratch("destination");
        for folder in ["private", "public", "back"] {
            fs::create_dir_all(source.join(folder)).unwrap();
            fs::write(source.join(folder).join("token.env"), folder).unwrap();
        }
        let patterns = lines("**/*.env\n!private/\n!back/\nback/*.env\n");
        let report = copy(&source, &destination, &patterns, &|| false);
        assert!(!destination.join("private/token.env").exists());
        assert!(destination.join("public/token.env").is_file());
        assert!(destination.join("back/token.env").is_file());
        assert_eq!(report.copied, 2);
        fs::remove_dir_all(source).unwrap();
        fs::remove_dir_all(destination).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn never_writes_through_a_link_the_worktree_has() {
        let source = scratch("source");
        let destination = scratch("destination");
        let elsewhere = scratch("elsewhere");
        fs::write(source.join(".env"), "SECRET=1").unwrap();
        fs::write(elsewhere.join("target"), "mine").unwrap();
        std::os::unix::fs::symlink(elsewhere.join("target"), destination.join(".env")).unwrap();
        let report = copy(&source, &destination, &lines(".env\n"), &|| false);
        assert_eq!(fs::read_to_string(elsewhere.join("target")).unwrap(), "mine");
        assert_eq!((report.copied, report.kept), (0, 1));
        for folder in [source, destination, elsewhere] {
            fs::remove_dir_all(folder).unwrap();
        }
    }

    #[cfg(unix)]
    #[test]
    fn leaves_out_a_fifo_instead_of_waiting_on_it() {
        let source = scratch("source");
        let destination = scratch("destination");
        let fifo =
            std::ffi::CString::new(source.join("pipe").as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: a NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        fs::write(source.join(".env"), "e").unwrap();
        let report = copy(&source, &destination, &lines("pipe\n.env\n"), &|| false);
        assert_eq!(report.copied, 1);
        assert_eq!(report.problems, ["pipe: not a regular file"]);
        assert!(fs::symlink_metadata(destination.join("pipe")).is_err());
        fs::remove_dir_all(source).unwrap();
        fs::remove_dir_all(destination).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn never_follows_a_link_out_of_the_repository() {
        let outside = scratch("outside");
        fs::write(outside.join("secret"), "s").unwrap();
        let source = scratch("source");
        let destination = scratch("destination");
        std::os::unix::fs::symlink(outside.join("secret"), source.join(".env")).unwrap();
        std::os::unix::fs::symlink(&outside, source.join("shared")).unwrap();
        fs::write(source.join("real"), "r").unwrap();
        std::os::unix::fs::symlink("real", source.join("alias")).unwrap();
        // A tracked link in the worktree must not carry a copy out of it.
        fs::create_dir_all(source.join("out")).unwrap();
        fs::write(source.join("out/file"), "f").unwrap();
        std::os::unix::fs::symlink(&outside, destination.join("out")).unwrap();
        let patterns = lines(".env\nshared/**/secret\nalias\nout/\n");
        let report = copy(&source, &destination, &patterns, &|| false);
        assert!(fs::symlink_metadata(destination.join(".env")).is_err());
        assert_eq!(report.outside, [".env"]);
        assert_eq!(fs::read_link(destination.join("alias")).unwrap(), Path::new("real"));
        assert!(!outside.join("file").exists());
        assert_eq!(report.problems.len(), 1);
        for path in [outside, source, destination] {
            fs::remove_dir_all(path).unwrap();
        }
    }
}
