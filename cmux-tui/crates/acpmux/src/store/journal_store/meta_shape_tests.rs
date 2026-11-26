//! A save's patch and shape (`meta.rs`): each field hashed once, the previous image's name list
//! reused when the fields are the same, and a removed or added field still seen.

use super::*;

fn last_of(image: &[u8]) -> LastImage {
    let fields = raw_fields(image).unwrap();
    let hashes = field_hashes(&fields);
    let (names, hashes) = shape(&fields, &hashes, None);
    LastImage { lsn: 7, folder: FolderId { ino: 1, birth_ns: 0 }, names, hashes, saw: None, whole_next: false }
}

#[test]
fn a_save_with_the_same_fields_reuses_the_name_list_and_patches_only_the_change() {
    let last = last_of(br#"{"b":1,"a":"x","c":[1,2]}"#);
    let next = br#"{"b":2,"a":"x","c":[1,2]}"#;
    let fields = raw_fields(next).unwrap();
    let hashes = field_hashes(&fields);
    let (names, ordered) = shape(&fields, &hashes, Some(&last));
    assert!(Arc::ptr_eq(&names, &last.names), "the same fields reuse the list");
    // The same as a shape made from nothing.
    let (fresh_names, fresh) = shape(&fields, &hashes, None);
    assert_eq!(&*fresh_names, &*names);
    assert_eq!(fresh, ordered);
    let body = patch_body(&fields, &hashes, &last).unwrap().expect("b changed");
    assert_eq!(String::from_utf8(body).unwrap(), r#"{"set":{"b":2},"unset":[]}"#);
    let same = raw_fields(br#"{"b":1,"a":"x","c":[1,2]}"#).unwrap();
    assert!(patch_body(&same, &field_hashes(&same), &last).unwrap().is_none());
}

#[test]
fn a_removed_or_renamed_field_is_unset_and_gets_a_new_name_list() {
    let last = last_of(br#"{"a":1,"b":2,"c":3}"#);
    // Same count, one name swapped: `c` is gone and `d` is new.
    let fields = raw_fields(br#"{"a":1,"b":2,"d":3}"#).unwrap();
    let hashes = field_hashes(&fields);
    let body = patch_body(&fields, &hashes, &last).unwrap().unwrap();
    assert_eq!(String::from_utf8(body).unwrap(), r#"{"set":{"d":3},"unset":["c"]}"#);
    let (names, _) = shape(&fields, &hashes, Some(&last));
    assert_eq!(names.iter().map(|n| &**n).collect::<Vec<_>>(), ["a", "b", "d"]);
    // One fewer.
    let fewer = raw_fields(br#"{"b":2,"a":1}"#).unwrap();
    let body = patch_body(&fewer, &field_hashes(&fewer), &last).unwrap().unwrap();
    assert_eq!(String::from_utf8(body).unwrap(), r#"{"set":{},"unset":["c"]}"#);
    // An escaped name reads as its text.
    let escaped = raw_fields(br#"{"ab":1}"#).unwrap();
    assert_eq!(&*escaped[0].0, "ab");
}
