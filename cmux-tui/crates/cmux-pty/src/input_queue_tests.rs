use super::{CAPACITY, Cut, cut};

#[test]
fn whole_sequences_go_in_up_to_the_last_one_that_starts_in_the_room() {
    let reports = b"\x1b[<65;30;7M\x1b[<65;30;7M\x1b[<65;30;7M";
    // 11 bytes per report: 12 bytes of room take the first report only.
    assert_eq!(cut(reports, 12), Cut::Write(11));
    assert_eq!(cut(reports, 23), Cut::Write(22));
}

#[test]
fn a_sequence_that_does_not_fit_waits_for_room() {
    assert_eq!(cut(b"\x1b[<65;30;7M", 1), Cut::Wait);
    assert_eq!(cut(b"\x1b[<65;30;7M", 5), Cut::Wait);
    assert_eq!(cut(b"\x1b[<65;30;7M", 0), Cut::Wait);
}

#[test]
fn text_fills_the_room_but_never_ends_after_an_escape() {
    assert_eq!(cut(b"abcdef", 4), Cut::Write(4));
    // The room ends right after the ESC that the text holds at its fourth byte.
    assert_eq!(cut(b"abc\x1b[A", 4), Cut::Write(3));
    assert_eq!(cut(b"a\x1b", 1), Cut::Write(1));
}

#[test]
fn a_sequence_longer_than_the_queue_is_cut_where_it_must_be() {
    let mut long = vec![0x1b, b']'];
    long.extend(std::iter::repeat_n(b'x', CAPACITY + 10));
    assert_eq!(cut(&long, 100), Cut::Write(100));
}
