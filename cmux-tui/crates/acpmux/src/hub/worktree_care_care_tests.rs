use super::*;

#[test]
fn care_passes_come_sooner_as_the_disk_fills() {
    assert!(spacing(Pressure::Normal) > spacing(Pressure::High));
    assert!(spacing(Pressure::High) > spacing(Pressure::Critical));
    assert_eq!(spacing(Pressure::Critical), 10 * MINUTE_MS);
}

#[test]
fn care_one_pass_at_a_time_and_the_flag_clears_on_unwind() {
    let flag = AtomicBool::new(false);
    let held = Running::claim(&flag).expect("free");
    assert!(Running::claim(&flag).is_none());
    drop(held);
    let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _held = Running::claim(&flag).expect("free again");
        panic!("a pass panics");
    }));
    assert!(caught.is_err());
    assert!(Running::claim(&flag).is_some(), "the panic cleared it");
}
