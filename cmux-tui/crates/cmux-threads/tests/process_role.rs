//! The task role and PRIO_DARWIN_BG are process-wide: suppressing them would
//! slow the other tests' threads, so these get their own binary.

use cmux_threads::process_role::{
    self, ProcessRole, darwin_background, set_default_role, set_role,
};

#[cfg(target_vendor = "apple")]
#[test]
fn the_default_role_reads_foreground_and_suppression_clears_on_foreground() {
    assert_eq!(set_default_role(), Ok(()));
    assert_eq!(process_role::current(), Some(process_role::TaskRole::Foreground));

    assert_eq!(set_role(ProcessRole::BackgroundSuppressed), Ok(()));
    assert_eq!(process_role::current(), Some(process_role::TaskRole::Background));
    assert_eq!(darwin_background(), Some(true), "suppressed sets PRIO_DARWIN_BG");

    assert_eq!(set_role(ProcessRole::Background), Ok(()));
    assert_eq!(darwin_background(), Some(false), "plain background is not suppressed");

    assert_eq!(set_role(ProcessRole::BackgroundSuppressed), Ok(()));
    assert_eq!(set_role(ProcessRole::Foreground), Ok(()));
    assert_eq!(process_role::current(), Some(process_role::TaskRole::Foreground));
    assert_eq!(darwin_background(), Some(false), "foreground clears PRIO_DARWIN_BG");
}

#[cfg(not(target_vendor = "apple"))]
#[test]
fn every_role_change_is_a_no_op_without_task_roles() {
    assert_eq!(set_default_role(), Ok(()));
    assert_eq!(set_role(ProcessRole::BackgroundSuppressed), Ok(()));
    assert_eq!(process_role::current(), None);
    assert_eq!(darwin_background(), None);
    assert_eq!(set_role(ProcessRole::Foreground), Ok(()));
    assert_eq!(process_role::current(), None);
}
