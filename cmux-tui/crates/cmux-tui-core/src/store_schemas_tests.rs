//! Rows for the rules of the read that makes no file ([`version_at_rest`]):
//! when a store file is at rest, what the look before the read must see, and
//! what the look after it must see. Each time in a row is a fixed number: no
//! row reads a clock, and no row reads a file.

use super::*;

/// The wall clock of the look in each row: 1,700,000,000 seconds after 1970.
const NOW_MS: Option<u64> = Some(1_700_000_000_000);

/// A look at a store at rest at [`NOW_MS`]: a store file that was written
/// long before, no `-wal` file with bytes and no `-journal` file.
fn a_look() -> StoreLook {
    StoreLook {
        length: 12_288,
        written: (1_600_000_000, 500),
        device: 7,
        file: 11,
        wal_bytes: 0,
        journal: false,
    }
}

#[test]
fn a_file_written_1_ms_before_the_margin_is_at_rest() {
    assert!(at_rest((1_699_999_997, 999_000_000), NOW_MS));
}

#[test]
fn a_file_written_at_the_margin_is_not_at_rest() {
    assert!(!at_rest((1_699_999_998, 0), NOW_MS));
}

#[test]
fn a_file_written_1_ms_after_the_margin_is_not_at_rest() {
    assert!(!at_rest((1_699_999_998, 1_000_000), NOW_MS));
}

#[test]
fn a_part_of_a_millisecond_does_not_count() {
    assert!(at_rest((1_699_999_997, 999_999_999), NOW_MS));
    assert!(!at_rest((1_699_999_998, 999_999), NOW_MS));
}

#[test]
fn a_file_written_at_the_time_of_the_look_is_not_at_rest() {
    assert!(!at_rest((1_700_000_000, 0), NOW_MS));
}

#[test]
fn a_file_with_a_time_ahead_of_the_look_is_not_at_rest() {
    assert!(!at_rest((1_700_000_000, 1_000_000), NOW_MS));
    assert!(!at_rest((4_102_444_800, 0), NOW_MS));
    assert!(!at_rest((i64::MAX, 0), NOW_MS));
}

#[test]
fn a_file_with_a_time_before_1970_is_not_at_rest() {
    assert!(!at_rest((-1, 0), NOW_MS));
    assert!(!at_rest((1_600_000_000, -1), NOW_MS));
}

#[test]
fn no_file_is_at_rest_when_the_clock_cannot_be_read() {
    assert!(!at_rest((1_600_000_000, 0), None));
}

#[test]
fn the_look_before_takes_a_store_at_rest_with_no_side_file() {
    assert!(can_read_at_rest(&a_look(), NOW_MS));
}

#[test]
fn the_look_before_does_not_take_a_wal_file_with_bytes() {
    assert!(!can_read_at_rest(&StoreLook { wal_bytes: 1, ..a_look() }, NOW_MS));
}

#[test]
fn the_look_before_does_not_take_a_journal_file() {
    assert!(!can_read_at_rest(&StoreLook { journal: true, ..a_look() }, NOW_MS));
}

#[test]
fn the_look_before_does_not_take_a_store_file_that_is_not_at_rest() {
    assert!(!can_read_at_rest(&StoreLook { written: (1_699_999_999, 0), ..a_look() }, NOW_MS));
    assert!(!can_read_at_rest(&a_look(), None));
}

#[test]
fn the_look_after_takes_a_store_that_did_not_change() {
    assert!(stayed_at_rest(&a_look(), &a_look()));
}

#[test]
fn the_look_after_does_not_take_another_length() {
    assert!(!stayed_at_rest(&a_look(), &StoreLook { length: 12_289, ..a_look() }));
}

#[test]
fn the_look_after_does_not_take_another_time_of_the_last_write() {
    assert!(!stayed_at_rest(&a_look(), &StoreLook { written: (1_600_000_001, 500), ..a_look() }));
    assert!(!stayed_at_rest(&a_look(), &StoreLook { written: (1_600_000_000, 501), ..a_look() }));
}

#[test]
fn the_look_after_does_not_take_another_device() {
    assert!(!stayed_at_rest(&a_look(), &StoreLook { device: 8, ..a_look() }));
}

#[test]
fn the_look_after_does_not_take_another_file_number() {
    assert!(!stayed_at_rest(&a_look(), &StoreLook { file: 12, ..a_look() }));
}

#[test]
fn the_look_after_does_not_take_a_wal_file_with_bytes() {
    assert!(!stayed_at_rest(&a_look(), &StoreLook { wal_bytes: 1, ..a_look() }));
    let with_bytes = StoreLook { wal_bytes: 1, ..a_look() };
    assert!(!stayed_at_rest(&with_bytes, &StoreLook { wal_bytes: 1, ..a_look() }));
}

#[test]
fn the_look_after_does_not_take_a_journal_file() {
    assert!(!stayed_at_rest(&a_look(), &StoreLook { journal: true, ..a_look() }));
    let with_journal = StoreLook { journal: true, ..a_look() };
    assert!(!stayed_at_rest(&with_journal, &StoreLook { journal: true, ..a_look() }));
}

#[test]
fn the_name_for_the_read_has_each_byte_of_the_path_that_a_uri_can_not_hold_as_hex() {
    use std::os::unix::ffi::OsStrExt;
    let path = Path::new(OsStr::from_bytes(b"/a b/?#%41/\xc3\xa9/\xff~-._/store.sqlite3"));
    assert_eq!(
        immutable_uri(path).as_deref(),
        Some("file:///a%20b/%3f%23%2541/%c3%a9/%ff~-._/store.sqlite3?immutable=1")
    );
}
