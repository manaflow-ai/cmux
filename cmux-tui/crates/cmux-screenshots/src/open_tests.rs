use super::*;

#[test]
fn only_the_persons_run_selects_and_every_other_run_is_told() {
    assert_eq!(answer(true, false, false), None);
    assert_eq!(answer(true, true, true), None);
    assert_eq!(
        answer(false, false, true),
        Some(Answer {
            opened: Opened::Background,
            listing: false,
            note: Some(Note::OpenedInBackground)
        })
    );
    assert_eq!(
        answer(false, true, true),
        Some(Answer { opened: Opened::Existing, listing: true, note: None })
    );
    assert_eq!(
        answer(false, true, false),
        Some(Answer {
            opened: Opened::Existing,
            listing: false,
            note: Some(Note::ExistingNeedsClick)
        })
    );
}
