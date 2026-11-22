use super::*;

#[test]
fn a_busy_chief_is_not_called_down() {
    assert!(not_read_text(true).contains("in a turn"));
    assert!(!not_read_text(true).contains("brain running"));
    assert!(not_read_text(false).contains("brain running"));
}
