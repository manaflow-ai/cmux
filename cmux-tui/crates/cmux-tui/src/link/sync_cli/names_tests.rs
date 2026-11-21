use super::*;

#[test]
fn a_path_folds_as_a_macs_disk_compares_it() {
    assert_eq!(folded_path("\u{c4}/up"), folded_path("\u{e4}/UP"));
    assert_eq!(folded_path("A\u{308}/x"), folded_path("\u{e4}/x"));
    assert_ne!(folded_path("a/x"), folded_path("b/x"));
}

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
