/// The owner of a status has the start of its process whatever bytes the
/// name of its program has.
#[test]
fn the_owner_of_a_status_has_its_start_for_each_program_name() {
    let child = cmux_tui_platform::CutNameChild::start("status-owner").expect("child");
    let owner = super::OwnerProcess::current(child.id());
    assert_eq!(owner.map(|owner| owner.pid), Some(child.id()));
    assert!(owner.is_some_and(|owner| owner.started > 0), "the start of a child of this test");
}
