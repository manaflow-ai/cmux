use super::id_head;

#[test]
fn a_session_name_takes_8_characters_after_each_prefix() {
    assert_eq!(id_head("auto_abcdefgh234567abcdef", "auto_"), "abcdefgh");
    assert_eq!(id_head("run_234567abcdefghijklmn", "run_"), "234567ab");
    // An id of another form is used whole, never a panic.
    assert_eq!(id_head("auto_é", "auto_"), "auto_é");
    assert_eq!(id_head("other", "run_"), "other");
}
