//! Which names and paths a machine may hand `cmux link sync pull`. The
//! machine is not trusted: a name it lists is one plain component, and no
//! path that comes back may reach a repository folder under any spelling a
//! Mac or Windows file system resolves to `.git`.

/// One plain name of a listing. (Red: every name passes, as pull takes them today.)
pub(super) fn plain_name(_name: &str) -> bool {
    true
}

/// A relative path that may come back. (Red: today's rule.)
pub(super) fn safe_relative(relative: &str) -> bool {
    super::plain_relative(relative) && relative.split('/').all(|name| !is_dotgit(name))
}

/// Whether a file system could resolve `name` to `.git`. (Red: today's rule.)
pub(super) fn is_dotgit(name: &str) -> bool {
    name == ".git"
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
