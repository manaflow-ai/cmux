use super::*;

#[test]
fn an_old_host_is_off_for_every_turn_but_the_persons_and_never_against_the_chats_pick() {
    // The chat's pick on: off before an agent's turn, on again before the person's.
    assert_eq!(suggestion_step(true, false, None), Some(false));
    assert_eq!(suggestion_step(true, false, Some(Told::Off)), None, "already off");
    assert_eq!(suggestion_step(true, true, Some(Told::Off)), Some(true));
    assert_eq!(suggestion_step(true, true, None), None, "on already");
    // The chat's pick off, or a host that refused: nothing is sent.
    assert_eq!(suggestion_step(false, false, None), None);
    assert_eq!(suggestion_step(false, true, Some(Told::Off)), None);
    assert_eq!(suggestion_step(true, false, Some(Told::Refused)), None);
    assert_eq!(suggestion_step(true, true, Some(Told::Refused)), None);
}
