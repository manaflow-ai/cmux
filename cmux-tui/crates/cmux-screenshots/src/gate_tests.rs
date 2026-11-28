use super::*;

#[test]
fn unlocking_one_pane_lets_detection_run() {
    let mut gate = Gate::default();
    assert!(!gate.may_detect());
    assert!(gate.starts_when_shown("a", true));
    assert!(!gate.starts_when_shown("a", false));
    gate.unlock("a");
    assert!(gate.may_detect());
    assert!(gate.is_unlocked("a"));
    assert!(!gate.is_unlocked("b"));
    assert!(!gate.starts_when_shown("a", true));
    assert!(gate.starts_when_shown("b", true));
}
