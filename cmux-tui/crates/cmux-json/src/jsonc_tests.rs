use super::strip_jsonc;

#[test]
fn comments_and_trailing_commas_go_strings_stay() {
    let text = "{\n  // note é\n  \"a\": \"x // y, }\", /* b */ \"b\": [1, 2,],\n}";
    assert_eq!(strip_jsonc(text), "{\n  \n  \"a\": \"x // y, }\",  \"b\": [1, 2]\n}");
    assert_eq!(strip_jsonc("\"é\\\"\" // tail"), "\"é\\\"\" ");
    assert_eq!(strip_jsonc("[1 /* open"), "[1 ");
    assert_eq!(strip_jsonc("\"unterminated \\"), "\"unterminated \\");
    assert_eq!(strip_jsonc(""), "");
}
