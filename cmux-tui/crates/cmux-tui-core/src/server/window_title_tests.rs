use super::window_title_osc;

#[test]
fn window_title_osc_uses_osc_0_and_2_and_strips_controls() {
    assert_eq!(window_title_osc("hello").as_slice(), b"\x1b]0;hello\x07\x1b]2;hello\x07");
    assert_eq!(window_title_osc("a\x1bb\x07c").as_slice(), b"\x1b]0;a b c\x07\x1b]2;a b c\x07");
}
