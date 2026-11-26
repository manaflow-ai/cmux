use super::changed_at_in;

/// An agent restart during a deferral reads back when the build change
/// was found, only from a mark for the same host.
#[test]
fn a_mark_for_the_same_host_keeps_its_build_change_time() {
    let mark = "{\"pid\":4242,\"changed_at\":1794700000}\n";
    assert_eq!(changed_at_in(mark, 4242), Some(1_794_700_000));
    assert_eq!(changed_at_in(mark, 4243), None);
    assert_eq!(changed_at_in("{\"pid\":4242}", 4242), None);
    assert_eq!(changed_at_in("garbage", 4242), None);
}
