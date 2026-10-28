use super::*;
use std::time::Duration;

fn timeline() -> (StartupMarks, Instant) {
    let origin = Instant::now();
    (
        StartupMarks::starting_at(
            origin,
            UNIX_EPOCH + Duration::from_micros(1_700_000_000_000_000),
        ),
        origin,
    )
}

#[test]
fn wire_reports_only_reached_steps_with_their_offsets() {
    let (marks, origin) = timeline();
    // Recorded out of order: each step keeps its own time.
    marks.mark_at(StartupMark::FirstIdentifyServed, origin + Duration::from_micros(900));
    marks.mark_at(StartupMark::ConfigLoaded, origin + Duration::from_micros(10));
    marks.mark_at(StartupMark::SocketBound, origin + Duration::from_micros(300));

    let wire = marks.wire();
    let mut keys = wire.as_object().unwrap().keys().cloned().collect::<Vec<_>>();
    keys.sort();
    assert_eq!(keys, ["config_loaded", "first_identify_served", MAIN_START_FIELD, "socket_bound"]);
    assert_eq!(wire[MAIN_START_FIELD], 1_700_000_000_000_000_u64);
    assert_eq!(wire["config_loaded"], 10);
    assert_eq!(wire["socket_bound"], 300);
    assert_eq!(wire["first_identify_served"], 900);
}

#[test]
fn a_step_keeps_its_first_time() {
    let (marks, origin) = timeline();
    marks.mark_at(StartupMark::MuxRestored, origin + Duration::from_micros(40));
    marks.mark_at(StartupMark::MuxRestored, origin + Duration::from_micros(70));
    marks.mark(StartupMark::MuxRestored);
    assert_eq!(marks.reached(StartupMark::MuxRestored), Some(40));
}

#[test]
fn a_step_at_the_origin_is_reached_and_one_before_it_counts_as_the_origin() {
    let origin = Instant::now() + Duration::from_secs(1);
    let marks = StartupMarks::starting_at(origin, SystemTime::now());
    marks.mark_at(StartupMark::ConfigLoaded, origin);
    marks.mark_at(StartupMark::OwnerPrepared, origin - Duration::from_millis(5));
    assert_eq!(marks.reached(StartupMark::ConfigLoaded), Some(0));
    assert_eq!(marks.reached(StartupMark::OwnerPrepared), Some(0));
    assert_eq!(marks.reached(StartupMark::SocketBound), None);
}

#[test]
fn every_step_has_its_own_slot_and_wire_name_in_declaration_order() {
    for (position, mark) in StartupMark::ALL.into_iter().enumerate() {
        assert_eq!(mark.slot(), position, "{mark:?}");
    }
    let names = StartupMark::ALL.map(StartupMark::wire_name);
    assert_eq!(
        names,
        [
            "config_loaded",
            "owner_prepared",
            "socket_bound",
            "mux_restored",
            "owner_event_loop",
            "websocket_ready",
            "launch_snapshot_writer_started",
            "lifecycle_ready",
            "first_identify_served",
        ]
    );
}

#[test]
fn a_server_without_a_timeline_records_nothing_and_keeps_the_first_one_installed() {
    let startup = ServerStartup::default();
    startup.mark(StartupMark::ConfigLoaded);
    startup.mark_ready();
    assert!(startup.is_ready());
    assert!(startup.marks().is_none());

    let (first, _) = timeline();
    let first = Arc::new(first);
    startup.install(first.clone());
    startup.install(Arc::new(timeline().0));
    startup.mark(StartupMark::LifecycleReady);
    assert!(std::ptr::eq(startup.marks().unwrap(), first.as_ref()));
    assert!(first.reached(StartupMark::LifecycleReady).is_some());
    // Marked before the timeline was installed, so never recorded.
    assert!(first.reached(StartupMark::ConfigLoaded).is_none());
}

#[test]
fn an_identify_before_readiness_is_not_the_first_identify_served() {
    let startup = ServerStartup::default();
    let (marks, _) = timeline();
    let marks = Arc::new(marks);
    startup.install(marks.clone());
    startup.mark(StartupMark::FirstIdentifyServed);
    assert!(marks.reached(StartupMark::FirstIdentifyServed).is_none());

    startup.mark_ready();
    startup.mark(StartupMark::FirstIdentifyServed);
    let ready = marks.reached(StartupMark::LifecycleReady).unwrap();
    assert!(marks.reached(StartupMark::FirstIdentifyServed).unwrap() >= ready);
}
