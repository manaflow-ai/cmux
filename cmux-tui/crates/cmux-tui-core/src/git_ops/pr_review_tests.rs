use std::ffi::OsStr;

use super::*;

#[test]
fn file_paths_stay_inside_the_worktree() {
    let root = Path::new("/w/review-1");
    assert_eq!(file_path(Some("./src/a.rs"), root).unwrap(), "src/a.rs");
    assert_eq!(file_path(Some("/w/review-1/src/a.rs"), root).unwrap(), "src/a.rs");
    for refused in ["", "../a.rs", "/elsewhere/a.rs", "src/../../a.rs", "."] {
        assert!(file_path(Some(refused), root).is_err(), "{refused}");
    }
    assert!(file_path(None, root).is_err());
}

#[test]
fn gh_is_looked_up_by_absolute_path() {
    if let Some(program) = gh_program() {
        assert!(program.is_absolute());
        assert_eq!(program.file_name(), Some(OsStr::new("gh")));
    }
}
