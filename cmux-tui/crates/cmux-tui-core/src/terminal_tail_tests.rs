use super::*;

#[test]
fn the_tail_is_the_last_non_empty_line_without_escapes() {
    let mut line = TailLine::default();
    assert!(line.feed(b"\x1b[1;32m   Compiling\x1b[0m cmux v0.1.0\r\n\r\n   \r\n"));
    assert_eq!(line.tail(), Some("Compiling cmux v0.1.0"));
    // A blank line, or one that is blank once its escapes are gone, keeps the tail.
    line.feed(b"\x1b[2K\x1b]0;title\x07\n\t \n");
    assert_eq!(line.tail(), Some("Compiling cmux v0.1.0"));
}

#[test]
fn osc_titles_links_and_control_bytes_never_reach_the_tail() {
    let mut line = TailLine::default();
    line.feed(b"\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\ done\x07\x08\n");
    assert_eq!(line.tail(), Some("link done"));
    // A DCS query or APC graphics payload never shows: the line before it stays.
    line.feed(b"ready\x1bP$qm\x1b\\\n\x1b_Gf=100;AAAA\x1b\\\n");
    assert_eq!(line.tail(), Some("ready"));
    line.feed(b"a\tb    c\n");
    assert_eq!(line.tail(), Some("a b c"), "tabs become spaces and runs fold to one");
}

#[test]
fn a_progress_bar_redrawn_after_a_carriage_return_shows_its_newest_frame() {
    let mut line = TailLine::default();
    line.feed(b"[==>   ] 10%\r[====> ] 50%\r[======] 100%");
    assert_eq!(
        line.tail(),
        Some("[====> ] 50%"),
        "the frame still being drawn is not the tail yet"
    );
    line.feed(b"\n");
    assert_eq!(line.tail(), Some("[======] 100%"));
}

#[test]
fn a_line_split_across_chunks_and_escapes_is_one_line() {
    let mut line = TailLine::default();
    assert!(!line.feed(b"Deployed web@a1b2\x1b["));
    assert!(!line.feed(b"1mc3\x1b[0"));
    assert!(line.feed(b"m to staging\n"));
    assert_eq!(line.tail(), Some("Deployed web@a1b2c3 to staging"));
}

#[test]
fn take_change_reports_each_new_tail_once() {
    let mut line = TailLine::default();
    line.feed(b"one\n");
    assert_eq!(line.take_change().as_deref(), Some("one"));
    assert_eq!(line.take_change(), None);
    // The same line again is no change.
    assert!(!line.feed(b"one\n"));
    assert_eq!(line.take_change(), None);
    line.feed(b"two\nthree\n");
    assert_eq!(line.take_change().as_deref(), Some("three"), "only the newest line publishes");
}

#[test]
fn a_long_line_is_bounded() {
    let mut line = TailLine::default();
    let long = vec![b'x'; MAX_LINE_BYTES * 8];
    line.feed(&long);
    line.feed(&long);
    assert!(line.pending.len() <= MAX_LINE_BYTES);
    line.feed(b"\n");
    assert_eq!(line.tail().map(|tail| tail.chars().count()), Some(MAX_TAIL_CHARS));
    // Multibyte text is cut on a char, never mid-way.
    let wide = "é".repeat(MAX_TAIL_CHARS * 2);
    assert_eq!(clean_line(&wide).chars().count(), MAX_TAIL_CHARS);
    // Four-byte chars hit the byte bound first, under the status store's limit.
    let emoji = clean_line(&"🚀".repeat(MAX_TAIL_CHARS));
    assert!(emoji.len() <= MAX_TAIL_BYTES && emoji.len() > MAX_TAIL_BYTES - 4, "{}", emoji.len());
}

#[test]
fn the_throttle_lets_one_publication_through_per_interval() {
    let start = Instant::now();
    let mut throttle = Throttle::default();
    assert_eq!(throttle.next_at(start), start, "the first publication runs at once");
    throttle.ran(start);
    let soon = start + PUBLISH_INTERVAL / 5;
    assert_eq!(throttle.next_at(soon), start + PUBLISH_INTERVAL, "a change soon after waits");
    let later = start + PUBLISH_INTERVAL * 3;
    assert_eq!(throttle.next_at(later), later, "after a quiet interval it runs at once");
}
