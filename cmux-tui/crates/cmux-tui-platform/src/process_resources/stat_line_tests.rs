//! The stat line of a process: the read of its bytes and the parse of its
//! fields. The tests give their own lines, so they run on each system.

use super::{parse_proc_stat, stat_line};

/// The fields after the name: ppid 77, utime 5, stime 6, start 987654.
const AFTER_THE_NAME: &str = " S 77 1234 1234 0 -1 4194304 0 0 0 0 5 6 0 0 20 0 1 0 987654 1 2 3";

#[test]
fn the_fields_are_read_after_the_last_close_for_each_program_name() {
    let names = [
        "plain",
        "a) S 1 1 1 0 -1",
        ") R 0 0 0 0 0 0",
        "x\ny) (z",
        "(((((((((((((((",
        ")))))))))))))))",
        "\u{fffd}\u{fffd})\u{fffd}",
        "a\u{85}b\u{a0}c) 1",
        "\u{2028}\u{2029})",
        " ",
        "\t\r\n) 0 0 0",
        "1 (2) 3 (4) 5",
    ];
    for name in names {
        let line = format!("1234 ({name}){AFTER_THE_NAME}\n");
        let Some(stat) = parse_proc_stat(&line) else { panic!("no answer for the name {name:?}") };
        assert_eq!(
            (stat.ppid, stat.cpu_ticks, stat.start_ticks, stat.name.as_str()),
            (77, 11, 987_654, name),
            "the name {name:?}"
        );
    }
}

#[test]
fn a_line_that_ends_before_the_start_gives_no_answer() {
    // 19 fields after the name: the start (index 19) is not there.
    let line = "1234 (plain) S 77 1234 1234 0 -1 4194304 0 0 0 0 5 6 0 0 20 0 1 0\n";
    assert!(parse_proc_stat(line).is_none());
}

#[test]
fn a_start_that_is_not_a_number_gives_no_answer() {
    let line = "1234 (plain) S 77 1234 1234 0 -1 4194304 0 0 0 0 5 6 0 0 20 0 1 0 -1 1 2 3\n";
    assert!(parse_proc_stat(line).is_none());
}

/// The line of a file whose name field ends in the first byte of a character
/// of 2 bytes, as the system writes it for a name that it cut there.
#[test]
fn the_line_is_read_for_each_program_name() {
    let dir = std::env::temp_dir().join(format!("cmux-stat-line-{}", std::process::id()));
    // An earlier process with this id can have left its folder.
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("stat");
    let mut bytes = b"1234 (".to_vec();
    bytes.extend_from_slice("\u{e9}".repeat(7).as_bytes());
    bytes.push(0xc3);
    bytes.extend_from_slice(format!("){AFTER_THE_NAME}\n").as_bytes());
    assert!(std::str::from_utf8(&bytes).is_err(), "the line of this test is not UTF-8");
    std::fs::write(&path, &bytes).unwrap();
    let line = stat_line(&path);
    let _ = std::fs::remove_dir_all(&dir);
    let stat = line.ok().and_then(|line| parse_proc_stat(&line));
    assert_eq!(stat.map(|stat| (stat.ppid, stat.start_ticks)), Some((77, 987_654)));
    assert!(stat_line(&path).is_err(), "a file that is gone gives an error");
}
