use super::mach_to_protocol_us;

/// Apple silicon's timebase: 125/3 ns a tick, so 24 ticks a µs.
const NUMER: u32 = 125;
const DENOM: u32 = 3;

#[test]
fn a_mach_time_lands_on_the_protocol_clock_on_either_side_of_now() {
    let (now_us, now) = (1_000_000, 10_000_000);
    // 3 ms ago and 3 ms ahead (a display time ScreenCaptureKit schedules for a coming vsync).
    assert_eq!(mach_to_protocol_us(now_us, now, now - 72_000, NUMER, DENOM), 997_000);
    assert_eq!(mach_to_protocol_us(now_us, now, now + 72_000, NUMER, DENOM), 1_003_000);
    assert_eq!(mach_to_protocol_us(now_us, now, now, NUMER, DENOM), now_us);
    // An identity timebase (Intel): ticks are ns.
    assert_eq!(mach_to_protocol_us(now_us, now, now + 5_000_000, 1, 1), 1_005_000);
    // Never before the protocol clock's zero.
    assert_eq!(mach_to_protocol_us(10, now, 0, 1, 1), 0);
}
