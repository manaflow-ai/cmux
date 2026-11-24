use super::*;

#[test]
fn hub_text_is_printed_without_control_characters() {
    assert_eq!(printable("Ann's Mac"), "Ann's Mac");
    assert_eq!(printable("\u{1b}[2J\u{1b}[31mEvil\u{1b}[0m"), "Evil");
    assert_eq!(printable("a\u{1b}]0;title\u{7}b"), "ab");
    assert_eq!(printable("x\ny\rz\t\u{0}\u{7f}\u{9b}1m"), "xyz1m");
    assert_eq!(printable("\u{202e}cod.exe\u{202c}\u{2066}\u{200f}"), "cod.exe");
}
