//! Which names and paths a machine may hand `cmux link sync pull`. The
//! machine is not trusted: a name it lists is one plain component, and no
//! path that comes back may reach a repository folder under any spelling a
//! Mac or Windows file system resolves to `.git`.

/// One plain name of a listing: not empty, not `.` or `..`, no `/` or NUL.
pub(super) fn plain_name(name: &str) -> bool {
    !matches!(name, "" | "." | "..") && !name.contains(['/', '\0'])
}

/// A relative path that may come back: plain names, none of them a
/// repository folder ([`is_dotgit`]).
pub(super) fn safe_relative(relative: &str) -> bool {
    super::plain_relative(relative)
        && relative.split('/').all(|name| plain_name(name) && !is_dotgit(name))
}

/// Whether a file system could resolve `name` to `.git`: git's own rules
/// (`is_hfs_dotgit`, `is_ntfs_dotgit` in git's path.c and utf8.c), case
/// ignored. HFS+ drops the code points git calls ignorable; NTFS drops
/// trailing dots and spaces, an alternate stream (`:...`) and knows the
/// 8.3 short name `git~1`. A backslash counts as a separator there.
pub(super) fn is_dotgit(name: &str) -> bool {
    name.split('\\').any(|part| is_hfs_dotgit(part) || is_ntfs_dotgit(part))
}

fn is_hfs_dotgit(name: &str) -> bool {
    hfs_folded(name) == ".git"
}

/// `name` as an HFS+ or APFS disk may resolve it: ignorable code points
/// dropped, ASCII case folded.
fn hfs_folded(name: &str) -> String {
    name.chars().filter(|c| !is_hfs_ignorable(*c)).collect::<String>().to_ascii_lowercase()
}

/// Whether `name` makes the folder holding it a repository to git's
/// discovery (`is_git_directory`: a `HEAD`, or a linked worktree's
/// `commondir`), under any spelling a Mac's disk resolves to one.
pub(super) fn is_repository_marker(name: &str) -> bool {
    matches!(hfs_folded(name).as_str(), "head" | "commondir")
}

/// Whether `relative` is `folder` or below it, as a Mac's disk compares
/// names (case and HFS-ignorable code points ignored).
pub(super) fn folded_within(relative: &str, folder: &str) -> bool {
    let mut parts = relative.split('/');
    folder
        .split('/')
        .all(|name| parts.next().is_some_and(|part| hfs_folded(part) == hfs_folded(name)))
}

/// Whether a path of a tree the machine sends (a commit, staged entries)
/// carries a repository or a hook here: a `.git` under any spelling, a
/// repository marker in a subfolder, or anything in `hooks`.
pub(super) fn carries_repository_or_hook(relative: &str, hooks: &[String]) -> bool {
    let parts: Vec<&str> = relative.split('/').collect();
    parts.iter().any(|name| is_dotgit(name))
        || (parts.len() > 1 && parts.last().is_some_and(|name| is_repository_marker(name)))
        || hooks.iter().any(|folder| folded_within(relative, folder))
}

/// The names of a repository's own files and folders: what stays out of a
/// top folder that has a [`is_repository_marker`] name.
pub(super) fn is_repository_part(name: &str) -> bool {
    matches!(
        hfs_folded(name).as_str(),
        "head"
            | "commondir"
            | "gitdir"
            | "config"
            | "config.worktree"
            | "objects"
            | "refs"
            | "packed-refs"
            | "hooks"
            | "info"
            | "logs"
            | "index"
            | "worktrees"
            | "modules"
    )
}

/// The code points HFS+ ignores in names (git's `next_hfs_char`).
fn is_hfs_ignorable(c: char) -> bool {
    matches!(c as u32, 0x200c..=0x200f | 0x202a..=0x202e | 0x206a..=0x206f | 0xfeff)
}

fn is_ntfs_dotgit(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    let stem = lower.split(':').next().unwrap_or_default();
    let stem = stem.trim_end_matches(['.', ' ']);
    stem == ".git" || stem == "git~1"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_spelling_a_mac_or_windows_resolves_to_dotgit_is_refused() {
        for name in [
            ".git",
            ".GIT",
            ".Git",
            ".gIt",
            ".g\u{200c}it",
            "\u{feff}.git",
            ".git\u{200d}",
            ".git.",
            ".git ",
            ".git. . ",
            ".git::$INDEX_ALLOCATION",
            "GIT~1",
            "git~1",
            "x\\.git",
        ] {
            assert!(is_dotgit(name), "{name:?} reads as .git");
            assert!(!safe_relative(&format!("{name}/hooks/pre-commit")), "{name:?}");
            assert!(!safe_relative(&format!("sub/{name}/config")), "{name:?}");
        }
        for name in [".gitignore", ".gitmodules", "git", ".github", "my.git", ".git2"] {
            assert!(!is_dotgit(name), "{name:?} is a plain name");
        }
    }

    #[test]
    fn a_listed_name_is_one_plain_component() {
        for name in ["", ".", "..", "x/../.git", "../evil", "a/b", "nul\0"] {
            assert!(!plain_name(name), "{name:?}");
        }
        for relative in ["../evil", "x/../.git/hooks/pre-commit", "/etc/passwd", "a//b", "a/./b"] {
            assert!(!safe_relative(relative), "{relative:?}");
        }
        assert!(safe_relative("src/a.txt"));
    }
}
