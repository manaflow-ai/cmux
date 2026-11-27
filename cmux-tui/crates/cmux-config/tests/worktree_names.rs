//! `worktrees.location` and `worktrees.branchPrefix`: text rows whose defaults keep the folder
//! and branch names cmux always used, read by the daemon and acpmux where worktrees are made.

use std::path::{Path, PathBuf};

use cmux_config::Schema;
use cmux_config::worktree_names::{
    BRANCH_PREFIX_KEY, DEFAULT_BRANCH_PREFIX, DEFAULT_LOCATION, LOCATION_KEY, branch_prefix,
    location,
};
use serde_json::json;

#[test]
fn the_embedded_schema_has_both_rows_with_todays_defaults() {
    let schema = Schema::embedded();
    let default = |key: &str| {
        let row = schema.rows.iter().find(|row| row.key == key);
        row.unwrap_or_else(|| panic!("{key} is in the schema")).default.clone()
    };
    assert_eq!(default(LOCATION_KEY), Some(json!(DEFAULT_LOCATION)));
    assert_eq!(default(BRANCH_PREFIX_KEY), Some(json!(DEFAULT_BRANCH_PREFIX)));
    assert_eq!(DEFAULT_BRANCH_PREFIX, "cmux/");
}

#[test]
fn a_location_is_an_absolute_folder_or_the_default() {
    let home = Path::new("/home/u");
    let at = |value: serde_json::Value| location(Some(&value), home);
    assert_eq!(location(None, home), None);
    assert_eq!(at(json!(DEFAULT_LOCATION)), None);
    assert_eq!(at(json!("~/.cmux/worktrees/")), None);
    assert_eq!(at(json!("/home/u/.cmux/worktrees")), None);
    assert_eq!(at(json!("")), None);
    assert_eq!(at(json!("relative/folder")), None);
    assert_eq!(at(json!("~other/wt")), None);
    assert_eq!(at(json!(true)), None);
    assert_eq!(at(json!("~/code/worktrees")), Some(PathBuf::from("/home/u/code/worktrees")));
    assert_eq!(at(json!(" /Volumes/Fast/wt/ ")), Some(PathBuf::from("/Volumes/Fast/wt")));
}

#[test]
fn a_branch_prefix_is_one_git_takes_or_the_default() {
    let prefix = |value: serde_json::Value| branch_prefix(Some(&value));
    assert_eq!(branch_prefix(None), "cmux/");
    assert_eq!(prefix(json!("leo/")), "leo/");
    assert_eq!(prefix(json!("agents/cmux-")), "agents/cmux-");
    assert_eq!(prefix(json!("")), "");
    for refused in ["-x/", "/x", "a..b/", "a//b", "x.lock/", "a b/", "a~/", "a/.b", "x.", ".x"] {
        assert_eq!(prefix(json!(refused)), "cmux/", "{refused:?}");
    }
    assert_eq!(prefix(json!(3)), "cmux/");
}
