#[test]
fn launch_record_header_is_checked_in() {
    let header = std::fs::read_to_string("include/cmux_launch_record.h").unwrap();
    assert!(header.contains("cmux_launch_record_front_window"));
    assert!(header.contains("cmux_launch_record_write"));
    assert!(header.contains("window_id[65]"));
}
