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
/// The names a pattern may have, and the `**` among them: both bound the
/// walk's and the match's recursion.
const MAX_SEGMENTS: usize = 64;
const MAX_ANY_DEPTH: usize = 8;
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
    let mut segments: Vec<String> =
        rest.split('/').filter(|segment| !segment.is_empty()).map(str::to_string).collect();
    // `**/**` is `**`.
    segments.dedup_by(|next, last| next == "**" && last == "**");
    if segments.len() > MAX_SEGMENTS
        || segments.iter().filter(|segment| *segment == "**").count() > MAX_ANY_DEPTH
    {
        return Err("this pattern has too many names or ** to follow");
    }
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
        let escapes = text
            .split_last()
            .map_or(0, |(_, rest)| rest.iter().rev().take_while(|c| **c == '\\').count());
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
/// `destination` (the new worktree), until `cancelled` says to stop. Both
/// trees are opened once and then only gone through by folder handle,
/// never through a link, so neither can be swapped for one mid-copy.
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
    let roots = fs::canonicalize(source).and_then(|source_root| {
        let destination_root = fs::canonicalize(destination)?;
        Ok((at::root(&source_root)?, at::root(&destination_root)?, source_root))
    });
    let (source, destination, source_root) = match roots {
        Ok(roots) => roots,
        Err(error) if error.kind() == std::io::ErrorKind::Unsupported => {
            Report::note(&mut report.problems, error.to_string());
            return report;
        }
        Err(_) => {
            Report::note(&mut report.problems, "the checkout or the worktree is gone".into());
            return report;
        }
    };
    let (paths, ran_out) = select(&source_root, &patterns.patterns);
    if !paths.is_empty()
        && let Err(error) = destination.make_private()
    {
        let problem =
            format!("nothing is copied: the worktree could not be made private ({error})");
        Report::note(&mut report.problems, problem);
        return report;
    }
    if ran_out {
        Report::note(
            &mut report.problems,
            format!(
                "stopped looking after {MAX_VISITED_DIRECTORIES} folders: some matches are not copied"
            ),
        );
    }
    let mut copier = Copier {
        source,
        destination,
        source_root,
        report,
        patterns: &patterns.patterns,
        cancelled,
        folders_left: MAX_VISITED_DIRECTORIES,
    };
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
            (!pattern.directory_only || folder)
                && names.get(..depth).is_some_and(|names| matches(&pattern.segments, names))
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

/// Whether a path's names match a pattern's segments. One table row per
/// segment, from the last: each `**` costs a pass over the names, never a
/// search through every way to split them.
fn matches(segments: &[String], names: &[String]) -> bool {
    let at = |row: &[bool], index: usize| row.get(index).copied().unwrap_or(false);
    let width = names.len().saturating_add(1);
    // `after[j]`: whether the segments after this one match `names[j..]`.
    let mut after: Vec<bool> = (0..width).map(|index| index == names.len()).collect();
    for segment in segments.iter().rev() {
        let mut here = vec![false; width];
        for index in (0..width).rev() {
            let next = index.saturating_add(1);
            let value = if segment == "**" {
                at(&after, index) || at(&here, next)
            } else {
                names.get(index).is_some_and(|name| glob(segment.as_bytes(), name.as_bytes()))
                    && at(&after, next)
            };
            if let Some(slot) = here.get_mut(index) {
                *slot = value;
            }
        }
        after = here;
    }
    at(&after, 0)
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
            Some(byte) if Some(byte) == name.get(n) => {
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
    pattern.get(p..).is_none_or(|rest| rest.iter().all(|byte| *byte == b'*'))
}

struct Copier<'a> {
    source: at::Folder,
    destination: at::Folder,
    /// Where the checkout is, to list a folder's names and to tell a link
    /// inside it from one out of it; every read goes through `source`.
    source_root: PathBuf,
    report: Report,
    /// A `!` pattern takes a path back inside a selected folder too.
    patterns: &'a [Pattern],
    cancelled: &'a dyn Fn() -> bool,
    /// The folders a selected folder's copy may still walk into.
    folders_left: usize,
}

impl Copier<'_> {
    /// Whether a link in `parent` to `target` stays in the repository, both
    /// as written (no `..` climbs out of it) and once every link it passes
    /// is followed.
    fn inside(&self, parent: &Path, target: &Path) -> bool {
        let mut lexical =
            if target.is_absolute() { PathBuf::new() } else { self.source_root.join(parent) };
        for component in target.components() {
            match component {
                std::path::Component::ParentDir => {
                    lexical.pop();
                }
                std::path::Component::CurDir => {}
                other => lexical.push(other),
            }
        }
        lexical.starts_with(&self.source_root)
            && fs::canonicalize(self.source_root.join(parent).join(target))
                .is_ok_and(|resolved| resolved.starts_with(&self.source_root))
    }

    fn entry(&mut self, relative: &Path) {
        if (self.cancelled)() {
            return;
        }
        let Some(name) = relative.file_name() else { return };
        let parent = relative.parent().unwrap_or(Path::new(""));
        // A source folder swapped for a link since the walk fails here.
        let Ok(source_parent) = self.source.folder(parent, None) else { return };
        let Ok(kind) = source_parent.kind(name) else { return };
        if deciding(self.patterns, relative, kind == at::Kind::Folder)
            .is_some_and(|last| last.negated)
        {
            return;
        }
        let made = match kind {
            at::Kind::Folder => {
                let Some(left) = self.folders_left.checked_sub(1) else {
                    let note = format!(
                        "stopped copying after {MAX_VISITED_DIRECTORIES} folders: some files are not copied"
                    );
                    if !self.report.problems.contains(&note) {
                        Report::note(&mut self.report.problems, note);
                    }
                    return;
                };
                self.folders_left = left;
                if let Err(error) = self.destination.folder(relative, Some(&self.source)) {
                    self.problem(relative, &error);
                    return;
                }
                let Ok(entries) = fs::read_dir(self.source_root.join(relative)) else { return };
                let mut names: Vec<_> = entries.flatten().map(|entry| entry.file_name()).collect();
                names.sort();
                for name in names.into_iter().filter(|name| name != ".git") {
                    self.entry(&relative.join(name));
                }
                return;
            }
            at::Kind::Other => {
                let entry = format!("{}: not a regular file", relative.display());
                Report::note(&mut self.report.problems, entry);
                return;
            }
            at::Kind::Link => {
                // The target is read once, and that value is both checked and copied.
                let target = match source_parent.read_link(name) {
                    Ok(target) => target,
                    Err(error) => {
                        self.problem(relative, &error);
                        return;
                    }
                };
                if !self.inside(parent, &target) {
                    Report::note(&mut self.report.outside, relative.display().to_string());
                    return;
                }
                self.destination
                    .folder(parent, Some(&self.source))
                    .and_then(|folder| folder.link(name, &target))
            }
            at::Kind::File => {
                self.destination.folder(parent, Some(&self.source)).and_then(|destination| {
                    destination.copy_from(&source_parent, name, self.cancelled)
                })
            }
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
        let entry = if at::is_link_error(error) {
            format!("{}: the worktree has a link there", relative.display())
        } else {
            format!("{}: {error}", relative.display())
        };
        Report::note(&mut self.report.problems, entry);
    }
}

/// Files and folders reached one name at a time from a folder handle,
/// never through a link: a folder swapped for a link fails the step
/// instead of carrying a read or a write out of its tree.
#[cfg(unix)]
mod at {
    use std::ffi::{CString, OsStr};
    use std::fs::File;
    use std::io;
    use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};
    use std::os::unix::ffi::{OsStrExt as _, OsStringExt as _};
    use std::os::unix::fs::PermissionsExt as _;
    use std::path::{Component, Path};

    const FOLDER_FLAGS: libc::c_int =
        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub(super) enum Kind {
        Folder,
        File,
        Link,
        Other,
    }

    /// An open folder.
    pub(super) struct Folder(OwnedFd);

    fn c_name(name: &OsStr) -> io::Result<CString> {
        CString::new(name.as_bytes()).map_err(|_| io::ErrorKind::InvalidInput.into())
    }

    fn opened(fd: libc::c_int) -> io::Result<OwnedFd> {
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a descriptor the system just returned, owned by no one else.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    /// A folder's permission bits.
    fn mode_of(folder: &OwnedFd) -> io::Result<u32> {
        Ok(File::from(folder.try_clone()?).metadata()?.permissions().mode() & 0o7777)
    }

    fn checked(result: libc::c_int) -> io::Result<()> {
        if result < 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
    }

    /// The folder at `path` (canonical), held for the whole copy. Each part
    /// is opened through its parent and refuses a link, so a folder swapped
    /// for a link after the path was resolved fails here.
    pub(super) fn root(path: &Path) -> io::Result<Folder> {
        let relative =
            path.strip_prefix("/").map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        let slash = c_name(OsStr::new("/"))?;
        // SAFETY: a NUL-terminated path; the result is checked.
        let top = opened(unsafe { libc::open(slash.as_ptr(), FOLDER_FLAGS) }).map(Folder)?;
        top.folder(relative, None)
    }

    impl Folder {
        /// The folder `relative` names under this one. With `like`, the
        /// missing ones are made, each private at first and then given the
        /// mode of the folder at the same place under `like`, so a copy never
        /// opens up a folder the repository keeps private.
        pub(super) fn folder(&self, relative: &Path, like: Option<&Folder>) -> io::Result<Folder> {
            let dot = c_name(OsStr::new("."))?;
            let reopen = |folder: &OwnedFd| {
                // SAFETY: a live descriptor and a NUL-terminated name.
                opened(unsafe { libc::openat(folder.as_raw_fd(), dot.as_ptr(), FOLDER_FLAGS) })
            };
            let mut folder = reopen(&self.0)?;
            let mut source = like.map(|like| reopen(&like.0)).transpose()?;
            for component in relative.components() {
                let Component::Normal(part) = component else {
                    return Err(io::ErrorKind::InvalidInput.into());
                };
                let part = c_name(part)?;
                let mut made = false;
                if let Some(parent) = &source {
                    // SAFETY: as above; O_NOFOLLOW refuses a link in the folder's place.
                    let next = opened(unsafe {
                        libc::openat(parent.as_raw_fd(), part.as_ptr(), FOLDER_FLAGS)
                    })?;
                    // SAFETY: as above.
                    match checked(unsafe {
                        libc::mkdirat(folder.as_raw_fd(), part.as_ptr(), 0o700)
                    }) {
                        Ok(()) => made = true,
                        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                        Err(error) => return Err(error),
                    }
                    source = Some(next);
                }
                // SAFETY: as above; O_NOFOLLOW refuses a link in the folder's place.
                folder = opened(unsafe {
                    libc::openat(folder.as_raw_fd(), part.as_ptr(), FOLDER_FLAGS)
                })?;
                if let Some(source) = &source {
                    let there = mode_of(source)?;
                    // A folder made here takes the repository's mode, and the owner keeps
                    // writing into it, so a read-only folder still gets its files; one the
                    // worktree already has only loses what the repository denies others.
                    let mode =
                        if made { there | 0o700 } else { mode_of(&folder)? & (there | 0o7700) };
                    // SAFETY: a live descriptor.
                    checked(unsafe { libc::fchmod(folder.as_raw_fd(), mode as libc::mode_t) })?;
                }
            }
            Ok(Folder(folder))
        }

        /// Takes all access from others, so a file the repository keeps
        /// private by any folder above it (the repository's or its
        /// parents') stays private in the worktree.
        pub(super) fn make_private(&self) -> io::Result<()> {
            let here = mode_of(&self.0)?;
            let narrowed = here & 0o7700;
            if narrowed == here {
                return Ok(());
            }
            // SAFETY: a live descriptor; the mode only narrows.
            checked(unsafe { libc::fchmod(self.0.as_raw_fd(), narrowed as libc::mode_t) })
        }

        /// What `name` is here, without following a link.
        pub(super) fn kind(&self, name: &OsStr) -> io::Result<Kind> {
            let name = c_name(name)?;
            // SAFETY: plain data the call fills.
            let mut stat: libc::stat = unsafe { std::mem::zeroed() };
            // SAFETY: a live descriptor, a NUL-terminated name and a live buffer.
            checked(unsafe {
                libc::fstatat(
                    self.0.as_raw_fd(),
                    name.as_ptr(),
                    &raw mut stat,
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            })?;
            Ok(match stat.st_mode & libc::S_IFMT {
                libc::S_IFDIR => Kind::Folder,
                libc::S_IFREG => Kind::File,
                libc::S_IFLNK => Kind::Link,
                _ => Kind::Other,
            })
        }

        /// Where the link `name` points.
        pub(super) fn read_link(&self, name: &OsStr) -> io::Result<std::path::PathBuf> {
            let name = c_name(name)?;
            let mut buffer = vec![0_u8; libc::PATH_MAX as usize];
            // SAFETY: a live descriptor, a NUL-terminated name and a buffer of that length.
            let length = unsafe {
                libc::readlinkat(
                    self.0.as_raw_fd(),
                    name.as_ptr(),
                    buffer.as_mut_ptr().cast(),
                    buffer.len(),
                )
            };
            let length = usize::try_from(length).map_err(|_| io::Error::last_os_error())?;
            buffer.truncate(length);
            Ok(std::path::PathBuf::from(std::ffi::OsString::from_vec(buffer)))
        }

        /// A new link `name` to `target`; one already there is kept.
        pub(super) fn link(&self, name: &OsStr, target: &Path) -> io::Result<()> {
            let (name, target) = (c_name(name)?, c_name(target.as_os_str())?);
            // SAFETY: a live descriptor and NUL-terminated strings.
            checked(unsafe { libc::symlinkat(target.as_ptr(), self.0.as_raw_fd(), name.as_ptr()) })
        }

        /// A new file `name` here with the bytes and mode of `name` in
        /// `source`. It is written under a name of its own and then linked
        /// into place, which fails when a file is there: one already there,
        /// or saved meanwhile, is kept, and a failed copy removes only its
        /// own file.
        /// Copies `name` from `source`, a chunk at a time, so a removal
        /// stops even a large file's copy at once.
        pub(super) fn copy_from(
            &self,
            source: &Folder,
            name: &OsStr,
            cancelled: &dyn Fn() -> bool,
        ) -> io::Result<()> {
            use std::io::{Read as _, Write as _};
            let c = c_name(name)?;
            // Non-blocking, so a FIFO put in the file's place cannot hang the copy.
            let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;
            // SAFETY: a live descriptor and a NUL-terminated name.
            let mut reader = File::from(opened(unsafe {
                libc::openat(source.0.as_raw_fd(), c.as_ptr(), flags)
            })?);
            let metadata = reader.metadata()?;
            if !metadata.is_file() {
                return Err(io::Error::other("not a regular file"));
            }
            let mut bytes = [0_u8; 6];
            getrandom::fill(&mut bytes).map_err(|_| io::Error::other("no random bytes"))?;
            let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
            let staged = c_name(OsStr::new(&format!(".cmux-copy-{hex}")))?;
            let mode = metadata.permissions().mode() & 0o7777;
            let flags =
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC;
            // SAFETY: as above; the result is checked.
            let mut writer = File::from(opened(unsafe {
                libc::openat(self.0.as_raw_fd(), staged.as_ptr(), flags, mode as libc::c_uint)
            })?);
            let mut chunk = vec![0_u8; 1 << 20];
            let copied = loop {
                if cancelled() {
                    break Err(io::Error::new(io::ErrorKind::Interrupted, "stopped"));
                }
                match reader.read(&mut chunk) {
                    Ok(0) => break Ok(()),
                    Ok(read) => {
                        if let Err(error) = writer.write_all(chunk.get(..read).unwrap_or_default())
                        {
                            break Err(error);
                        }
                    }
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                    Err(error) => break Err(error),
                }
            };
            let installed = copied.and_then(|()| {
                drop(writer);
                // SAFETY: a live descriptor and NUL-terminated names.
                checked(unsafe {
                    libc::linkat(
                        self.0.as_raw_fd(),
                        staged.as_ptr(),
                        self.0.as_raw_fd(),
                        c.as_ptr(),
                        0,
                    )
                })
            });
            // SAFETY: as above; removes only the file this copy made.
            unsafe { libc::unlinkat(self.0.as_raw_fd(), staged.as_ptr(), 0) };
            installed
        }
    }

    /// The error a link where a folder should be gives.
    pub(super) fn is_link_error(error: &io::Error) -> bool {
        matches!(error.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR))
    }
}

/// Copying needs folder handles that refuse links; elsewhere nothing is
/// copied.
#[cfg(not(unix))]
mod at {
    use std::ffi::OsStr;
    use std::io;
    use std::path::{Path, PathBuf};

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub(super) enum Kind {
        Folder,
        File,
        Link,
        Other,
    }

    pub(super) struct Folder;

    pub(super) fn root(_path: &Path) -> io::Result<Folder> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "files are not copied into a worktree on this platform",
        ))
    }

    impl Folder {
        pub(super) fn folder(
            &self,
            _relative: &Path,
            _like: Option<&Folder>,
        ) -> io::Result<Folder> {
            Err(io::ErrorKind::Unsupported.into())
        }

        pub(super) fn make_private(&self) -> io::Result<()> {
            Err(io::ErrorKind::Unsupported.into())
        }

        pub(super) fn kind(&self, _name: &OsStr) -> io::Result<Kind> {
            Err(io::ErrorKind::Unsupported.into())
        }

        pub(super) fn read_link(&self, _name: &OsStr) -> io::Result<PathBuf> {
            Err(io::ErrorKind::Unsupported.into())
        }

        pub(super) fn link(&self, _name: &OsStr, _target: &Path) -> io::Result<()> {
            Err(io::ErrorKind::Unsupported.into())
        }

        pub(super) fn copy_from(
            &self,
            _source: &Folder,
            _name: &OsStr,
            _cancelled: &dyn Fn() -> bool,
        ) -> io::Result<()> {
            Err(io::ErrorKind::Unsupported.into())
        }
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
        // A long chain of `**` is refused before anything walks or matches it.
        assert!(lines(&format!("{}.env", "a/**/".repeat(40_000))).patterns.is_empty());
        assert!(lines(&format!("{}.env", "a/".repeat(80_000))).patterns.is_empty());
        // `**/**` is `**`, however many there are.
        assert_eq!(lines("a/**/**/b").patterns[0].segments, ["a", "**", "b"]);
        assert_eq!(
            lines(&format!("{}.env", "**/".repeat(80_000))).patterns[0].segments,
            ["**", ".env"]
        );
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
        assert!(!matches(&["**".into(), ".env".into()], &[]));
        assert!(matches(&["a".into(), "**".into()], &["a".into()]));
        // Many `**` over a deep path answer at once.
        let mut deep: Vec<String> = Vec::new();
        for _ in 0..8 {
            deep.extend(["**".into(), "a".into()]);
        }
        deep.push("missing".into());
        let names: Vec<String> = std::iter::repeat_n("a".to_string(), 64).collect();
        assert!(!matches(&deep, &names));
    }

    fn scratch(name: &str) -> PathBuf {
        let mut bytes = [0_u8; 6];
        getrandom::fill(&mut bytes).unwrap();
        let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        let path = std::env::temp_dir().join(format!("cmux-include-{name}-{hex}"));
        fs::create_dir_all(&path).unwrap();
        fs::canonicalize(path).unwrap()
    }

    #[cfg(unix)]
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

    #[cfg(unix)]
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

    #[cfg(not(unix))]
    #[test]
    fn says_why_nothing_is_copied_where_it_cannot_be() {
        let source = scratch("source");
        let destination = scratch("destination");
        fs::write(source.join(".env"), "e").unwrap();
        let report = copy(&source, &destination, &lines(".env\n"), &|| false);
        assert_eq!(report.copied, 0);
        assert_eq!(report.problems.len(), 1);
        assert!(!destination.join(".env").exists());
        fs::remove_dir_all(source).unwrap();
        fs::remove_dir_all(destination).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_folder_it_makes_stays_as_private_as_the_repository_has_it() {
        use std::os::unix::fs::PermissionsExt as _;
        let source = scratch("source");
        let destination = scratch("destination");
        fs::create_dir_all(source.join("private/deeper")).unwrap();
        fs::write(source.join("private/deeper/token"), "t").unwrap();
        fs::write(source.join("private/whole"), "w").unwrap();
        fs::set_permissions(source.join("private"), fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(source.join("private/deeper"), fs::Permissions::from_mode(0o750))
            .unwrap();
        let report =
            copy(&source, &destination, &lines("private/deeper/token\nprivate/whole\n"), &|| false);
        assert_eq!(report.copied, 2);
        let mode = |path: &str| fs::metadata(destination.join(path)).unwrap().permissions().mode();
        assert_eq!(mode("private") & 0o777, 0o700);
        assert_eq!(mode("private/deeper") & 0o777, 0o750);
        fs::set_permissions(&source, fs::Permissions::from_mode(0o755)).unwrap();
        fs::set_permissions(&destination, fs::Permissions::from_mode(0o755)).unwrap();
        copy(&source, &destination, &lines("private/whole\n"), &|| false);
        // A folder the worktree already has loses what the repository's denies others.
        fs::create_dir_all(source.join("config")).unwrap();
        fs::write(source.join("config/token"), "t").unwrap();
        fs::set_permissions(source.join("config"), fs::Permissions::from_mode(0o700)).unwrap();
        fs::create_dir_all(destination.join("config")).unwrap();
        fs::set_permissions(destination.join("config"), fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(copy(&source, &destination, &lines("config/token\n"), &|| false).copied, 1);
        assert_eq!(mode("config") & 0o777, 0o700);
        // A read-only folder still gets its files.
        fs::create_dir_all(source.join("frozen")).unwrap();
        fs::write(source.join("frozen/file"), "f").unwrap();
        fs::set_permissions(source.join("frozen"), fs::Permissions::from_mode(0o555)).unwrap();
        assert_eq!(copy(&source, &destination, &lines("frozen/\n"), &|| false).copied, 1);
        fs::set_permissions(source.join("frozen"), fs::Permissions::from_mode(0o755)).unwrap();
        // A worktree that gets copied files is its owner's only.
        assert_eq!(fs::metadata(&destination).unwrap().permissions().mode() & 0o777, 0o700);
        fs::remove_dir_all(source).unwrap();
        fs::remove_dir_all(destination).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_stopped_copy_leaves_nothing_behind() {
        let source = scratch("source");
        let destination = scratch("destination");
        fs::write(source.join("big"), vec![7_u8; 3 << 20]).unwrap();
        let (from, to) = (at::root(&source).unwrap(), at::root(&destination).unwrap());
        // Stopped after the first chunk.
        let checks = std::cell::Cell::new(0);
        let cancelled = || {
            checks.set(checks.get() + 1);
            checks.get() > 1
        };
        let error = to.copy_from(&from, std::ffi::OsStr::new("big"), &cancelled).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::Interrupted);
        assert_eq!(checks.get(), 2);
        assert_eq!(fs::read_dir(&destination).unwrap().count(), 0);
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
