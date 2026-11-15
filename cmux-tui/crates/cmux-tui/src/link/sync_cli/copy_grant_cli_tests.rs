//! `cmux link copy-grant`: its words, and what a usage error answers.

use super::{Command, parse, run};

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn measure_and_record_take_their_words() {
    assert!(matches!(
        parse(&words(&["measure", "/f"])),
        Some(Command::Measure(folder)) if folder.as_os_str() == "/f"
    ));
    assert!(matches!(
        parse(&words(&["record", "/f", "--bytes", "12", "--files", "3"])),
        Some(Command::Record { folder, bytes: 12, files: 3 }) if folder.as_os_str() == "/f"
    ));
    assert!(matches!(
        parse(&words(&["record", "--files", "3", "--bytes", "12", "/f"])),
        Some(Command::Record { bytes: 12, files: 3, .. })
    ));
}

#[test]
fn a_record_without_its_numbers_is_a_usage_error() {
    for args in [
        &["record", "/f", "--bytes", "12"][..],
        &["record", "/f", "--bytes", "x", "--files", "3"],
        &["record", "/f", "/g", "--bytes", "1", "--files", "1"],
        &["measure"],
        &["count", "/f"],
    ] {
        assert!(parse(&words(args)).is_none(), "{args:?}");
    }
    assert_eq!(run(&words(&["record", "/f"])), 64);
}

#[test]
fn a_count_of_a_folder_that_is_not_there_fails() {
    assert_eq!(run(&words(&["measure", "/nonexistent/cmux-copy-grant-test"])), 1);
}
