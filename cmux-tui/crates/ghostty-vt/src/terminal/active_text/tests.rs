use super::*;

#[test]
fn active_text_reads_the_live_screen_while_the_viewport_is_scrolled_back() {
    let mut term = Terminal::new(10, 3, 1_000, Callbacks::default()).unwrap();
    let output: String = (1..=20).map(|line| format!("{line}\r\n")).collect();
    term.vt_write(output.as_bytes());
    let live = term.viewport_text().unwrap();
    assert_eq!(term.active_text().unwrap(), live, "at the live bottom they agree");

    term.scroll_delta(-5);
    assert!(term.scrollbar().unwrap().scrolled_back());
    assert_ne!(term.viewport_text().unwrap(), live, "the viewport shows history");
    assert_eq!(term.active_text().unwrap(), live, "the live screen does not move");
}
