use super::*;

#[test]
fn glob_tails_handle_empty_and_repeated_wildcards() {
    assert!(glob(&[], &[]));
    assert!(!glob(&[], &["file"]));
    assert!(!glob(&["file"], &[]));
    assert!(glob(&["**", "**"], &[]));
    assert!(glob(&["**", "file"], &["a", "b", "file"]));
    assert!(!glob(&["**", "file"], &["a", "b"]));
    assert!(part_matches(b"**", b""));
    assert!(part_matches(b"a**b", b"ab"));
    assert!(!part_matches(b"a*b", b"a"));
    assert!(matches("**/é*.rs", "src/étude.rs"));
}

#[test]
fn patterns_are_paths_folders_or_globs() {
    assert!(matches("src/click", "src/click/core.py"));
    assert!(matches("src/click/", "src/click/core.py"));
    assert!(matches("src/click/**", "src/click/a/b.py"));
    assert!(matches("pyproject.toml", "pyproject.toml"));
    assert!(!matches("src/click", "src/clickety.py"));
    assert!(matches("tests/test_*.py", "tests/test_utils.py"));
    assert!(!matches("tests/test_*.py", "tests/sub/test_utils.py"));
    assert!(matches("**/conftest.py", "conftest.py"));
    assert!(matches("**/conftest.py", "tests/a/conftest.py"));
    assert!(!matches("*.py", "a/b.py"));
}

#[test]
fn paths_stay_inside_the_repository() {
    for ok in ["a", "a/b.py", "docs/x y.md"] {
        assert!(check_path(ok).is_ok(), "{ok}");
    }
    for bad in ["", "/etc/passwd", "a/../b", "../a", "a//b", "a/", ".git/config", "a/.git/x", "./a"]
    {
        assert!(check_path(bad).is_err(), "{bad}");
    }
}

#[test]
fn links_that_leave_the_folder_are_not_projected() {
    assert!(link_stays_inside("a/b", b"c"));
    assert!(link_stays_inside("a/b", b"../d"));
    assert!(!link_stays_inside("a/b", b"../../d"));
    assert!(!link_stays_inside("a", b"/etc/passwd"));
}
