use super::*;

#[test]
fn strip_ansi_removes_color_and_title_escapes() {
    let vite = "  \x1b[32m➜\x1b[39m  \x1b[1mLocal\x1b[22m:   \x1b[36mhttp://localhost:\x1b[1m5173\x1b[22m/\x1b[39m";
    assert_eq!(strip_ansi(vite), "  ➜  Local:   http://localhost:5173/");
    assert_eq!(strip_ansi("\x1b]0;title\x07a\x1b]8;;x\x1b\\b\x1b=c"), "abc");
    assert_eq!(strip_ansi("cut \x1b[1"), "cut ");
    // DCS queries and APC graphics drop their payloads too.
    assert_eq!(strip_ansi("ready\x1bP$qm\x1b\\"), "ready");
    assert_eq!(strip_ansi("a\x1b_Gf=100;AAAA\x1b\\b\x1b^pm\x1b\\c"), "abc");
    assert!(matches!(strip_ansi("plain"), Cow::Borrowed("plain")));
}
