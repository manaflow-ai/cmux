#[test]
fn a_mark_line_names_its_phase_and_offset() {
    assert_eq!(super::line("pipe-open", 12.345), "cmux-remote-timing pipe-open +12.3ms");
}
