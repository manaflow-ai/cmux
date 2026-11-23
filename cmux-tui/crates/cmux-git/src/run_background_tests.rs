use super::*;

#[test]
fn window_keeps_only_its_bytes_but_hashes_the_complete_output() {
    let source = "head café tail".as_bytes();
    let (first, more, first_window) = drain_window(source, 0, 8);
    let (second, more_second, second_window) = drain_window(source, 8, 8);
    assert!(more);
    assert!(!more_second);
    assert_eq!([first, second].concat(), source);
    let first_window = first_window.unwrap();
    let second_window = second_window.unwrap();
    assert_eq!(first_window.total_bytes, source.len() as u64);
    assert_eq!(first_window.read(4, 5).unwrap(), source[4..9]);
    assert_eq!(first_window.sha256, second_window.sha256);
    assert_eq!(
        first_window.sha256,
        "62d58f00ac6da603f09e3abd398469875f74f1ce760d50daca81b2cc89febf13"
    );
}

#[cfg(unix)]
#[test]
fn an_alternate_with_a_colon_or_quote_is_c_quoted() {
    assert_eq!(alternate_entry(Path::new("/r/.git/objects")), "/r/.git/objects");
    assert_eq!(alternate_entry(Path::new("/r:copy/objects")), "\"/r:copy/objects\"");
    assert_eq!(alternate_entry(Path::new("/a\"b\\c\nd")), "\"/a\\\"b\\\\c\\012d\"");
}

#[test]
fn background_holds_for_the_guard_and_this_thread_only() {
    assert!(!in_background());
    {
        let _outer = background();
        assert!(in_background());
        {
            let _inner = background();
        }
        assert!(in_background(), "an inner guard restores the outer one's state");
        assert!(!thread::spawn(in_background).join().unwrap());
    }
    assert!(!in_background());
}
