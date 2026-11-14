use super::*;

/// A stdin that never ends (a pipe nobody closes) stops the prompt's read at the deadline; one that ends is read
/// whole. Without the bound the drill waited on such a stdin past any `--timeout`.
#[test]
fn a_stdin_read_stops_at_the_deadline() {
    use std::io::Write as _;
    // A pipe nobody closes: its reader never sees an end.
    let (reader, writer) = std::io::pipe().unwrap();
    let began = Instant::now();
    assert!(read_by(&reader, began + Duration::from_millis(200)).is_err());
    assert!(began.elapsed() < Duration::from_secs(5), "{:?}", began.elapsed());
    // One that ends is read whole.
    let (reader, mut writer_two) = std::io::pipe().unwrap();
    writer_two.write_all(b"count").unwrap();
    drop(writer_two);
    let read = read_by(&reader, began + Duration::from_secs(5));
    assert_eq!(read, Ok("count".to_owned()));
    drop(writer);
}

/// Under a second left after the kill grace and the dispatch margin, no remote script is sent; otherwise the
/// machine's `timeout` holds those whole seconds, the script quoted whole.
#[test]
fn a_remote_script_holds_the_seconds_left() {
    assert_eq!(remote_script("true", Duration::from_millis(3_999)), None);
    assert_eq!(
        remote_script("echo a b", Duration::from_millis(5_900)).as_deref(),
        Some("timeout -k 1 2 sh -c 'echo a b'")
    );
}
