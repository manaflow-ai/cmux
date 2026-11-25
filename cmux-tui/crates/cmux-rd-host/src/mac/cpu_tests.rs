use super::*;
#[test]
fn process_cpu_native_self_and_child_identity() {
    let first = sample(std::process::id() as i32).expect("self usage");
    let second = sample(std::process::id() as i32).expect("self usage");
    assert_eq!(first.start_abstime, second.start_abstime);
    assert!(second.cpu_ns >= first.cpu_ns);
    assert!(interval(Ok(first), Ok(second)).cpu_pct.is_some());
    let mut child =
        std::process::Command::new("/bin/sleep").arg("0.2").spawn().expect("owned child");
    let pid = child.id() as i32;
    let usage = sample(pid);
    child.wait().expect("reap owned child");
    assert_eq!(usage.expect("child usage").pid, pid);
    assert!(sample(pid).is_err());
    assert!(sample(-1).is_err());
}

#[test]
fn process_cpu_native_one_busy_thread_reads_about_one_core() {
    // One thread spinning for 300 ms is close to 100% of one core. Raw Mach ticks on
    // Apple Silicon read about 4% here, so this catches a missing timebase scale.
    let pid = std::process::id() as i32;
    let before = sample(pid).expect("self usage");
    let start = std::time::Instant::now();
    let mut spin = 0u64;
    while start.elapsed() < std::time::Duration::from_millis(300) {
        spin = std::hint::black_box(spin.wrapping_add(1));
    }
    let after = sample(pid).expect("self usage");
    let pct = interval(Ok(before), Ok(after)).cpu_pct.expect("cpu interval");
    // Other test threads share this process, so the ceiling is every core the machine has.
    let cores = std::thread::available_parallelism().map_or(64, |n| n.get()) as f64;
    assert!(
        (40.0..=cores * 100.0 + 50.0).contains(&pct),
        "one busy thread read {pct:.1}% of a core ({cores} cores)"
    );
}
