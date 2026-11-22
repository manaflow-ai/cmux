use super::*;

#[test]
fn parses_bel_and_st_rgb_replies() {
    let colors =
        parse_replies(b"noise\x1b]10;rgb:eeee/dddd/cccc\x1b\\more\x1b]11;rgb:13/14/15\x07");
    assert_eq!(colors.fg, Some(Rgb { r: 0xee, g: 0xdd, b: 0xcc }));
    assert_eq!(colors.bg, Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }));
}

#[test]
fn ignores_malformed_replies() {
    let colors = parse_replies(b"\x1b]11;rgb:1/2/3\x07\x1b]10;rgb:zz/00/00\x1b\\");
    assert_eq!(colors, DefaultColors::default());
}
