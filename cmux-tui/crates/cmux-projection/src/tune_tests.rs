use super::*;

#[test]
fn unset_or_bad_keeps_the_default() {
    assert_eq!(parse(None, 3, level_ok), 3);
    assert_eq!(parse(Some("fast"), 3, level_ok), 3);
    assert_eq!(parse(Some("23"), 3, level_ok), 3);
    assert_eq!(parse(Some("-8"), 3, level_ok), 3);
    assert_eq!(parse(Some("0"), 256usize, files_ok), 256);
    assert_eq!(parse(Some("2000"), 256usize, files_ok), 256);
    assert_eq!(parse(Some("0"), 16u64 << 20, bytes_ok), 16 << 20);
    assert_eq!(parse(Some(&(wire::MAX_ANSWER).to_string()), 16u64 << 20, bytes_ok), 16 << 20);
}

#[test]
fn a_value_in_range_is_taken() {
    assert_eq!(parse(Some(" 0 "), 3, level_ok), 0);
    assert_eq!(parse(Some("-1"), 3, level_ok), -1);
    assert_eq!(parse(Some("19"), 3, level_ok), 19);
    assert_eq!(parse(Some("1"), 256usize, files_ok), 1);
    assert_eq!(parse(Some("1024"), 256usize, files_ok), 1024);
    assert_eq!(parse(Some("4194304"), 16u64 << 20, bytes_ok), 4 << 20);
}

#[test]
fn the_shipped_defaults_are_unchanged() {
    assert_eq!(wire::ZSTD_LEVEL, 3);
    assert_eq!(DEFAULT_READAHEAD_FILES, 256);
    assert_eq!(DEFAULT_READAHEAD_BYTES, 16 * 1024 * 1024);
}
