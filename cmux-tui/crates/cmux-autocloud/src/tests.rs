use super::*;

fn app() -> App {
    App {
        spec: Spec::Local,
        sides: Vec::new(),
        focus: 0,
        beside: Vec::new(),
        readiness: Readiness::default(),
        transcript: Transcript::default(),
        session: Some("first".to_owned()),
        link_note: String::new(),
        reconnects: 0,
        input: String::new(),
        scroll: 0,
        ticks: 0,
        generation: 0,
        link: None,
        early: Vec::new(),
        first_prompt: None,
        sent_any: false,
        turns_at_send: 0,
        failures: 0,
        next_prompt: 0,
    }
}

#[test]
fn a_side_opens_once_takes_the_focus_and_tab_cycles() {
    let mut a = app();
    a.side_opened("s2".to_owned(), &[]);
    a.side_opened("s3".to_owned(), &[]);
    // A re-attach after a drop adds nothing.
    a.side_opened("s2".to_owned(), &[]);
    assert_eq!(a.sides.iter().map(|s| s.session.as_str()).collect::<Vec<_>>(), ["s2", "s3"]);
    assert_eq!(a.focus, 2);
    a.focus_next();
    assert_eq!(a.focus, 0);
    a.focus_next();
    assert_eq!(a.focus, 1);
}

#[test]
fn a_prompt_goes_to_the_focused_chat_and_close_keeps_the_first() {
    let mut a = app();
    a.side_opened("s2".to_owned(), &[]);
    a.prompt_focused("to the side".to_owned());
    assert_eq!(a.sides.first().map(|s| s.transcript.unconfirmed().len()), Some(1));
    assert!(a.transcript.unconfirmed().is_empty());
    a.close_focused();
    assert!(a.sides.is_empty());
    assert_eq!(a.focus, 0);
    // The first chat is never closed.
    a.close_focused();
    a.prompt_focused("to the first".to_owned());
    assert_eq!(a.transcript.unconfirmed().len(), 1);
}
