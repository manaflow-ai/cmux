use super::*;

fn temp_root(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "cmux-placement-{name}-{}-{:?}",
        std::process::id(),
        Instant::now()
    ));
    std::fs::create_dir_all(&root).ok();
    root
}

#[test]
fn the_wait_ends_on_the_kernel_event_when_the_scope_becomes_populated() {
    let root = temp_root("ok");
    std::fs::write(root.join("cgroup.controllers"), "cpu memory\n").ok();
    let watch = PlacementWatch::new(&root, "s.slice", "h.scope");
    assert!(watch.is_ok(), "{:?}", watch.as_ref().err());
    let writer_root = root.clone();
    let writer = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(50));
        let scope = writer_root.join("s.slice").join("h.scope");
        std::fs::create_dir_all(&scope).ok();
        std::fs::write(scope.join("cgroup.events"), "populated 0\nfrozen 0\n").ok();
        std::thread::sleep(Duration::from_millis(50));
        std::fs::write(scope.join("cgroup.events"), "populated 1\nfrozen 0\n").ok();
    });
    let started = Instant::now();
    let result = watch.map(|watch| watch.wait(Duration::from_secs(5)));
    writer.join().ok();
    assert_eq!(result, Ok(Ok(())));
    assert!(started.elapsed() < Duration::from_secs(4), "the wait did not end on the event");
    std::fs::remove_dir_all(&root).ok();
}

/// cx-nvhp: the scope directory can be visible before its
/// `cgroup.events` file. The watch must still see the file appear and
/// then its change, instead of sleeping to the deadline.
#[test]
fn the_wait_ends_on_the_event_when_cgroup_events_appears_after_the_scope() {
    let root = temp_root("late-events");
    std::fs::write(root.join("cgroup.controllers"), "cpu memory\n").ok();
    let scope = root.join("s.slice").join("h.scope");
    std::fs::create_dir_all(&scope).ok();
    let watch = PlacementWatch::new(&root, "s.slice", "h.scope");
    assert!(watch.is_ok(), "{:?}", watch.as_ref().err());
    let writer = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(50));
        std::fs::write(scope.join("cgroup.events"), "populated 0\nfrozen 0\n").ok();
        std::thread::sleep(Duration::from_millis(50));
        std::fs::write(scope.join("cgroup.events"), "populated 1\nfrozen 0\n").ok();
    });
    let started = Instant::now();
    let result = watch.map(|watch| watch.wait(Duration::from_secs(5)));
    writer.join().ok();
    assert_eq!(result, Ok(Ok(())));
    assert!(started.elapsed() < Duration::from_secs(4), "the wait did not end on the event");
    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn a_scope_that_never_fills_times_out_and_fails_open() {
    let root = temp_root("timeout");
    std::fs::write(root.join("cgroup.controllers"), "cpu\n").ok();
    let result = PlacementWatch::new(&root, "s.slice", "h.scope")
        .map(|watch| watch.wait(Duration::from_millis(150)));
    assert_eq!(result, Ok(Err(PlacementMiss::TimedOut)));
    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn a_cgroup_v1_host_is_reported_without_waiting() {
    let root = temp_root("v1");
    let started = Instant::now();
    let result = PlacementWatch::new(&root, "s.slice", "h.scope").map(|_| ());
    assert_eq!(result, Err(PlacementMiss::NotCgroupV2));
    assert!(started.elapsed() < Duration::from_millis(100));
    std::fs::remove_dir_all(&root).ok();
}
