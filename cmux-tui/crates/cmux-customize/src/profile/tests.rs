use super::*;

#[test]
fn a_profile_name_is_a_plain_file_name() {
    assert!(valid_name("compact-night"));
    assert!(valid_name("v2_work"));
    for bad in ["", "../x", "Night", "a b", "-x", "a/b", "x.json"] {
        assert!(!valid_name(bad), "{bad}");
    }
}
