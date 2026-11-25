use super::*;

#[test]
fn plain_screen_bytes_draw_rows_without_control_characters() {
    assert_eq!(plain_screen_bytes("a\u{1b}b\nc"), b"\x1b[0m\x1b[H\x1b[2Jab\r\nc".to_vec());
}
