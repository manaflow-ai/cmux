use super::*;

/// Review of #37239 at fda360ba, F1: Computer Use runs only on a screen known to be unlocked.
/// An unknown state (no session dictionary, a failed read) waits like a lock; off a Mac there
/// is no screen to lock.
#[test]
fn computer_use_waits_unless_the_screen_is_confirmed_unlocked() {
    assert!(holds_computer_use(Lock::Locked));
    assert!(holds_computer_use(Lock::Unknown));
    assert!(!holds_computer_use(Lock::Unlocked));
    assert!(!holds_computer_use(Lock::None));
}

/// The window server sets the key only while locked: absent is unlocked, a Boolean says
/// which, and a value of any other type is unknown, never unlocked.
#[test]
fn a_lock_flag_that_is_not_a_boolean_is_unknown() {
    assert_eq!(classify(None), Lock::Unlocked);
    assert_eq!(classify(Some(Some(true))), Lock::Locked);
    assert_eq!(classify(Some(Some(false))), Lock::Unlocked);
    assert_eq!(classify(Some(None)), Lock::Unknown);
}
