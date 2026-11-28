use super::*;

/// A copy of the note the person pasted in a fenced example stays; the generated one goes.
#[test]
fn a_fenced_copy_of_the_note_stays_and_the_generated_one_goes() {
    let note = note(&["browser-use"]).unwrap();
    let typed = format!("use @browser-use\n\n```\n\n{note}\n```");
    let delivered = format!("{typed}\n\n{note}");
    assert_eq!(without_own_note(&delivered), typed);
    assert_eq!(without_own_note(&typed), typed, "nothing generated to strip");
}
