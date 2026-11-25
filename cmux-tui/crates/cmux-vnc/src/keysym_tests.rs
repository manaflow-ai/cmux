use super::*;

#[test]
fn keysyms_match_x11() {
    assert_eq!(keysym(Key::Char('a')), Some(0x61));
    assert_eq!(keysym(Key::Char('é')), Some(0xE9));
    assert_eq!(keysym(Key::Char('€')), Some(0x0100_20AC));
    assert_eq!(keysym(Key::Enter), Some(0xFF0D));
    assert_eq!(keysym(Key::F(1)), Some(0xFFBE));
    assert_eq!(keysym(Key::F(12)), Some(0xFFC9));
    assert_eq!(keysym(Key::F(0)), None);
    assert_eq!(keysym(Key::Super), Some(0xFFEB));
    assert_eq!(char_keysym('\r'), 0xFF0D);
}
