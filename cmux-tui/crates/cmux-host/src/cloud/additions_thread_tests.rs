use super::*;

#[test]
fn wakes_queued_while_a_pass_runs_count_as_one() {
    let (wake, woken) = mpsc::sync_channel(1);
    let handle = Additions { wake };
    handle.collect();
    handle.collect();
    handle.collect();
    drop(handle);
    let mut passes = 0;
    run(&woken, |_| passes += 1);
    assert_eq!(passes, 1);
}
