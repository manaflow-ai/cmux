use super::*;

fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<OsString> {
    move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| OsString::from(*v))
}

#[test]
fn an_agent_in_a_cmux_terminal_sees_ghostty_without_a_version() {
    let edits =
        agent_identity_edits(env(&[("TERM_PROGRAM", "cmux"), ("TERM_PROGRAM_VERSION", "1.0.0")]));
    assert_eq!(
        edits,
        vec![
            IdentityEdit::Set("TERM_PROGRAM", "ghostty"),
            IdentityEdit::Remove("TERM_PROGRAM_VERSION")
        ]
    );
}

#[test]
fn an_agent_outside_cmux_keeps_its_terminal_identity() {
    assert!(
        agent_identity_edits(env(&[
            ("TERM_PROGRAM", "iTerm.app"),
            ("TERM_PROGRAM_VERSION", "3.6")
        ]))
        .is_empty()
    );
    assert!(agent_identity_edits(env(&[])).is_empty());
}
