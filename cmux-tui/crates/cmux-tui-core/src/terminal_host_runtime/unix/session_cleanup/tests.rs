use super::{current_session, session_groups};

/// The groups of a session are read whatever bytes the name of a program
/// on the system has. The child is in the session of this test and in a
/// group of its own.
#[test]
fn the_groups_of_a_session_are_read_for_each_program_name() {
    let child = cmux_tui_platform::CutNameChild::start("session-groups").expect("child");
    let group = libc::pid_t::try_from(child.id()).ok();
    let groups = session_groups(current_session());
    assert!(groups.is_ok(), "the scan of the session gave no answer");
    assert!(
        groups.is_ok_and(|groups| group.is_some_and(|group| groups.contains(&group))),
        "the group of a child of this test is in the session of this test"
    );
}
