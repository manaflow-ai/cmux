//! Values read from disk or a peer that are too short or malformed are
//! rejected, never indexed past their end.

use super::*;

#[test]
fn short_or_malformed_reset_ids_are_not_canonical() {
    assert!(is_canonical_reset_uuid_v4("0f8fad5b-d9cb-469f-a165-70867728950e"));
    for value in [
        "",
        "0f8fad5b",
        "0f8fad5b-d9cb-469f-a165-70867728950",
        "0f8fad5b-d9cb-469f-a165-70867728950e0",
        "0f8fad5b-d9cb-369f-a165-70867728950e",
        "0f8fad5b-d9cb-469f-c165-70867728950e",
        "0f8fad5b-d9cb-469f-a165-7086772895é",
    ] {
        assert!(!is_canonical_reset_uuid_v4(value), "{value:?}");
    }
}

#[test]
fn short_terminal_identities_are_rejected() {
    assert!(validate_terminal_identity("terminal", TERMINAL_ONE).is_ok());
    for value in
        ["", "0000", "00000000000040008000000000000001ff", "000000000000300080000000000000ff"]
    {
        assert!(validate_terminal_identity("terminal", value).is_err(), "{value:?}");
    }
}

#[test]
fn hex_bytes_is_two_lowercase_digits_a_byte() {
    assert_eq!(hex_bytes(&[]), "");
    assert_eq!(hex_bytes(&[0x00, 0x0f, 0xa0, 0xff]), "000fa0ff");
    let digest: [u8; 32] = Sha256::digest(b"cmux").into();
    let expected = digest.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    assert_eq!(hex_sha256(digest), expected);
}

#[test]
fn pending_reset_names_need_both_prefix_and_suffix() {
    let root = temp_root("reset-names");
    fs::create_dir_all(&root).unwrap();
    let component = session_storage_component("reset-names");
    // A name whose prefix and suffix overlap, or that carries no canonical
    // id, is skipped.
    for name in [
        format!(".reset-{component}-.deleting"),
        format!(".reset-{component}-x.deleting"),
        format!(".reset-{component}-0f8fad5b-d9cb-469f-a165-70867728950e"),
    ] {
        fs::create_dir_all(root.join(name)).unwrap();
    }
    assert!(pending_session_reset_dirs(&root, "reset-names").unwrap().is_empty());
    fs::remove_dir_all(root).unwrap();
}
