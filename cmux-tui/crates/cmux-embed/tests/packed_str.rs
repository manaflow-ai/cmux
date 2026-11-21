use cmux_embed::{PackedStr, packed_str};

static RELATIVE: PackedStr = packed_str!(include_str!("fixtures/catalog.json"));
static MANIFEST: PackedStr =
    packed_str!(include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/catalog.json")));
static EMPTY: PackedStr = packed_str!(include_str!("fixtures/empty.txt"));

const PLAIN: &str = include_str!("fixtures/catalog.json");

#[test]
fn inflates_to_the_file() {
    assert_eq!(RELATIVE.inflate(), PLAIN);
    assert_eq!(RELATIVE.len(), PLAIN.len());
}

#[test]
fn get_is_the_file_and_inflates_once() {
    let first = MANIFEST.get();
    assert_eq!(first, PLAIN);
    assert!(std::ptr::eq(first, MANIFEST.get()));
    assert_eq!(MANIFEST.inflate(), PLAIN);
}

#[test]
fn compiled_in_smaller_than_the_text() {
    assert!(
        RELATIVE.packed_len() * 4 < RELATIVE.len(),
        "{} of {}",
        RELATIVE.packed_len(),
        RELATIVE.len()
    );
}

#[test]
fn empty_file() {
    assert!(EMPTY.is_empty());
    assert_eq!(EMPTY.get(), "");
    assert_eq!(EMPTY.inflate(), "");
}
