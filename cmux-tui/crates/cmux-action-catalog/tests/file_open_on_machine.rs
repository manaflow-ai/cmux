//! `cmux file open --machine B --path P` opens a file of another machine (an own Mac joined by
//! sign-in included) in the pane's file pages, read through that machine. The argument is
//! optional, so `cmux file open --path P` and the palette row are unchanged, and the run waits
//! for its work (a joined Mac is dialed first) under the 40 s result deadline.
//! Leo: "Own machines as good as Cloud".
use cmux_action_catalog::find;

#[test]
fn file_open_takes_an_optional_machine_and_waits_for_the_open() {
    let action = find("file.open").expect("Open File…");
    assert_eq!(action.cli_name, "file open");
    let names: Vec<&str> = action.arguments.iter().map(|argument| argument.name).collect();
    assert_eq!(names, ["path", "where", "asText", "machine"]);
    assert!(
        action.arguments.iter().all(|argument| !argument.required),
        "every argument stays optional"
    );
    assert!(action.waits_for_result, "a joined Mac's dial outlasts the 2 s control-plane deadline");
}
