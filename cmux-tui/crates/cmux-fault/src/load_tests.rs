use super::{CpuLoad, RamLoad};
use crate::trace::Trace;
use std::time::Duration;

#[test]
fn cpu_load_spins_only_while_its_duty_is_set_and_stops_on_drop() {
    let trace = Trace::new();
    let cpu = CpuLoad::start(2, &trace);
    assert_eq!(cpu.threads(), 2);
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(cpu.spins(), 0, "idle load spun");
    cpu.set_duty(100);
    std::thread::sleep(Duration::from_millis(100));
    let busy = cpu.spins();
    assert!(busy > 0, "full duty never spun");
    cpu.set_duty(0);
    // A slice in flight finishes; then nothing more.
    std::thread::sleep(Duration::from_millis(30));
    let settled = cpu.spins();
    std::thread::sleep(Duration::from_millis(60));
    assert_eq!(cpu.spins(), settled, "spun after duty 0");
    drop(cpu);
    let lines = trace.lines().join("\n");
    assert!(lines.contains("fault cpu 100% x 2 threads") && lines.contains("heal cpu"), "{lines}");
}

#[test]
fn ram_load_holds_what_it_is_set_to_and_never_past_its_ceiling() {
    let trace = Trace::new();
    let mut ram = RamLoad::with_ceiling(16 << 20, &trace);
    ram.set(8 << 20);
    assert_eq!(ram.held(), 8 << 20);
    ram.set(1 << 30);
    assert_eq!(ram.held(), 16 << 20, "held past the ceiling");
    ram.set_percent(25);
    assert_eq!(ram.held(), 4 << 20);
    ram.set(0);
    assert_eq!(ram.held(), 0);
    let lines = trace.lines().join("\n");
    assert!(lines.contains("fault ram 16 MiB held") && lines.contains("heal ram"), "{lines}");
}
