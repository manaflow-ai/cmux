use super::valid_id;

#[test]
fn a_request_id_names_one_path_segment_and_nothing_else() {
    assert!(valid_id("bg-1"));
    assert!(valid_id("01J9:ab_c.d"));
    for bad in ["", "a/b", "../x", "a b", "a?b", &"x".repeat(129)] {
        assert!(!valid_id(bad), "{bad}");
    }
}
