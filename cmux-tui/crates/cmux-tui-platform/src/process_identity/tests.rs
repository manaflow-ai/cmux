/// A process has its name, its parent and its start whatever bytes the
/// name of its program has.
#[test]
fn a_process_is_identified_for_each_program_name() {
    let child = crate::CutNameChild::start("identity").expect("child");
    let identity = super::identity(child.id());
    assert_eq!(
        identity.as_ref().map(|process| process.ppid),
        Some(std::process::id()),
        "the parent of a child of this test"
    );
    assert!(
        identity.is_some_and(|process| process.started_ms > 0 && !process.name.is_empty()),
        "the start and the name of a child of this test"
    );
}
