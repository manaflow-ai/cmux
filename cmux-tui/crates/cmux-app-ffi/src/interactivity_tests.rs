use super::*;

#[test]
fn note_raises_visible_classes_and_unknowns_are_refused() {
    assert_eq!(cmux_interactivity_qos(9), -1);
    cmux_interactivity_note(99);
    cmux_interactivity_note(0);
    assert!(cmux_interactivity_is_interacting());
    assert_eq!(cmux_interactivity_qos(3), 0x19);
    assert_eq!(cmux_interactivity_qos(0), 0x21);
    assert_eq!(cmux_interactivity_qos(6), 0x09);
}
