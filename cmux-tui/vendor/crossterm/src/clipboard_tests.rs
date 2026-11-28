use super::*;

#[test]
fn test_clipboard_string_to_selection() {
    assert_eq!(
        ClipboardSelection::from_str("p").unwrap(),
        ClipboardSelection(vec![ClipboardType::Primary])
    );
    assert_eq!(ClipboardSelection::from_str("").unwrap(), ClipboardSelection(vec![]));
    assert_eq!(
        ClipboardSelection::from_str("cp").unwrap(),
        ClipboardSelection(vec![ClipboardType::Clipboard, ClipboardType::Primary])
    );
}
#[test]
fn test_clipboard_selection_to_osc52_pc() {
    assert_eq!(ClipboardSelection(vec![]).to_osc52_pc(), "");
    assert_eq!(ClipboardSelection(vec![ClipboardType::Clipboard]).to_osc52_pc(), "c");
    assert_eq!(ClipboardSelection(vec![ClipboardType::Primary]).to_osc52_pc(), "p");
    assert_eq!(
        ClipboardSelection(vec![ClipboardType::Primary, ClipboardType::Clipboard]).to_osc52_pc(),
        "pc"
    );
    assert_eq!(
        ClipboardSelection(vec![ClipboardType::Clipboard, ClipboardType::Primary]).to_osc52_pc(),
        "cp"
    );
    assert_eq!(ClipboardSelection(vec![ClipboardType::Other('s')]).to_osc52_pc(), "s");
}

#[test]
fn test_clipboard_copy_string_osc52() {
    let mut buffer = String::new();
    super::CopyToClipboard {
        content: "foo",
        destination: ClipboardSelection(vec![ClipboardType::Clipboard]),
    }
    .write_ansi(&mut buffer)
    .unwrap();
    assert_eq!(buffer, "\x1b]52;c;Zm9v\x1b\\");

    buffer.clear();
    super::CopyToClipboard {
        content: "foo",
        destination: ClipboardSelection(vec![ClipboardType::Primary]),
    }
    .write_ansi(&mut buffer)
    .unwrap();
    assert_eq!(buffer, "\x1b]52;p;Zm9v\x1b\\");

    buffer.clear();
    super::CopyToClipboard {
        content: "foo",
        destination: ClipboardSelection(vec![ClipboardType::Primary, ClipboardType::Clipboard]),
    }
    .write_ansi(&mut buffer)
    .unwrap();
    assert_eq!(buffer, "\x1b]52;pc;Zm9v\x1b\\");

    buffer.clear();
    super::CopyToClipboard { content: "foo", destination: ClipboardSelection(vec![]) }
        .write_ansi(&mut buffer)
        .unwrap();
    assert_eq!(buffer, "\x1b]52;;Zm9v\x1b\\");
}

#[test]
fn test_clipboard_copy_string_osc52_constructor() {
    let mut buffer = String::new();
    super::CopyToClipboard::to_clipboard_from("foo").write_ansi(&mut buffer).unwrap();
    assert_eq!(buffer, "\x1b]52;c;Zm9v\x1b\\");

    let mut buffer = String::new();
    super::CopyToClipboard::to_primary_from("foo").write_ansi(&mut buffer).unwrap();
    assert_eq!(buffer, "\x1b]52;p;Zm9v\x1b\\");
}
