//! The task role and PRIO_DARWIN_BG are process-wide: suppressing them would
//! slow the other tests' threads, so these get their own binary.

use cmux_threads::process_role::{
    self, ProcessRole, darwin_background, darwin_background_of, set_child_suppressed,
    set_default_role, set_role,
};

#[cfg(target_vendor = "apple")]
use cmux_threads::process_role::DarwinBackground;

/// This process's internal PRIO_DARWIN_BG flag, the one [`set_role`] sets.
/// The external one is whatever the test runner passed down.
#[cfg(target_vendor = "apple")]
fn internal_flag() -> Option<bool> {
    darwin_background().map(|bg| bg.internal)
}

#[cfg(target_vendor = "apple")]
#[test]
fn the_default_role_reads_foreground_and_suppression_clears_on_foreground() {
    let inherited = darwin_background().map(|bg| bg.external);
    assert_eq!(set_default_role(), Ok(()));
    assert_eq!(process_role::current(), Some(process_role::TaskRole::Foreground));

    assert_eq!(set_role(ProcessRole::BackgroundSuppressed), Ok(()));
    assert_eq!(process_role::current(), Some(process_role::TaskRole::Background));
    assert_eq!(internal_flag(), Some(true), "suppressed sets this process's internal flag");

    assert_eq!(set_role(ProcessRole::Background), Ok(()));
    assert_eq!(internal_flag(), Some(false), "plain background is not suppressed");

    assert_eq!(set_role(ProcessRole::BackgroundSuppressed), Ok(()));
    assert_eq!(set_role(ProcessRole::Foreground), Ok(()));
    assert_eq!(process_role::current(), Some(process_role::TaskRole::Foreground));
    assert_eq!(internal_flag(), Some(false), "foreground clears PRIO_DARWIN_BG");
    assert_eq!(
        darwin_background().map(|bg| bg.external),
        inherited,
        "only another process changes the external flag"
    );
}

/// A parent suppresses a real child by pid, reads the child's external flag,
/// then clears it. The test process keeps its own flags.
#[cfg(target_vendor = "apple")]
#[test]
fn a_parent_suppresses_and_clears_a_child_by_pid() {
    struct Reap(std::process::Child);
    impl Drop for Reap {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let inherited = darwin_background().map(|bg| bg.external);
    let child = Reap(std::process::Command::new("/bin/sleep").arg("30").spawn().expect("spawn"));
    let pid = i32::try_from(child.0.id()).expect("pid fits");

    assert_eq!(set_child_suppressed(pid, true), Ok(()));
    let suppressed = darwin_background_of(pid);
    assert_eq!(
        suppressed,
        Some(DarwinBackground { internal: false, external: true }),
        "a parent sets the child's external flag"
    );
    assert!(suppressed.is_some_and(DarwinBackground::suppressed));

    assert_eq!(set_child_suppressed(pid, false), Ok(()));
    assert_eq!(
        darwin_background_of(pid),
        Some(DarwinBackground { internal: false, external: false }),
        "the parent clears it again"
    );
    assert_eq!(darwin_background().map(|bg| bg.external), inherited, "the parent is untouched");
}

#[cfg(not(target_vendor = "apple"))]
#[test]
fn every_role_change_is_a_no_op_without_task_roles() {
    assert_eq!(set_default_role(), Ok(()));
    assert_eq!(set_role(ProcessRole::BackgroundSuppressed), Ok(()));
    assert_eq!(process_role::current(), None);
    assert_eq!(darwin_background(), None);
    assert_eq!(set_child_suppressed(1, true), Ok(()));
    assert_eq!(darwin_background_of(1), None);
    assert_eq!(set_role(ProcessRole::Foreground), Ok(()));
    assert_eq!(process_role::current(), None);
}
