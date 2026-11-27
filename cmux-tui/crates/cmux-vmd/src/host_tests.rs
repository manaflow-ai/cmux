use super::*;

#[test]
fn names_are_path_safe() {
    assert!(valid_name("ubuntu-24.04"));
    assert!(!valid_name("../etc"));
    assert!(!valid_name("a/b"));
    assert!(!valid_name(".hidden"));
    assert!(!valid_name(""));
}

#[test]
fn ids_are_path_safe() {
    assert!(valid_name(&new_id("vm")));
}
