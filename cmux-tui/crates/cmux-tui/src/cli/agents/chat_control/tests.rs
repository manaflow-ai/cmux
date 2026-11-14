use super::{parse_new, take_attach};

#[test]
fn attach_flags_come_before_the_text_and_repeat() {
    let words = ["--attach", "a.png", "--attach=b.txt", "--", "look"];
    let (attach, rest) = take_attach(&words, "agents chat send").unwrap();
    assert_eq!(attach, ["a.png", "b.txt"]);
    assert_eq!(rest, ["--", "look"]);
    let (attach, rest) = take_attach(&["look"], "agents chat send").unwrap();
    assert!(attach.is_empty());
    assert_eq!(rest, ["look"]);
    for bad in [&["--attach"][..], &["--attach="], &["--attach", "--"]] {
        assert!(take_attach(bad, "agents chat send").is_err(), "{bad:?}");
    }
}

#[test]
fn chat_new_takes_files_only_with_a_first_prompt() {
    let chat = parse_new(&["--attach", "a.png", "--attach=b.txt", "--", "look"]).unwrap();
    assert_eq!(chat.attach, ["a.png", "b.txt"]);
    assert_eq!(chat.prompt.as_deref(), Some("look"));
    assert!(parse_new(&["--attach", "a.png"]).is_err());
}
