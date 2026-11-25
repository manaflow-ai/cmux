use super::*;

#[test]
fn a_fast_tick_reports_nothing() {
    let mut steps = MaintenanceSteps::default();
    steps.record("ledgers", Duration::from_millis(3));
    steps.record("incremental_vacuum", Duration::from_millis(40));
    assert_eq!(steps.slow_report(SLOW_MAINTENANCE_TICK), None);
}

#[test]
fn a_slow_tick_names_its_slowest_step() {
    let mut steps = MaintenanceSteps::default();
    steps.record("ledgers", Duration::from_millis(5));
    steps.record("checkpoint", Duration::from_millis(900));
    steps.record("seal", Duration::from_millis(11_000));
    steps.record("incremental_vacuum", Duration::from_millis(400));
    assert_eq!(
        steps.slow_report(SLOW_MAINTENANCE_TICK).as_deref(),
        Some("slow journal maintenance: 12305 ms (4 steps; slowest seal 11000 ms)")
    );
}
