//! [`super::reachable`]: the classes a thread can change to without a refusal.

use super::*;

/// A Linux thread at Background (nice 10) reaches it and, with the right to
/// lower nice to theirs, the classes above. On macOS every class.
#[test]
fn reachable_is_the_own_class_and_below_unless_nice_may_be_lowered() {
    let reads = std::thread::spawn(|| {
        let lowered = set_current(ThreadQos::Background) == QosChange::Applied;
        (lowered, ThreadQos::ALL.map(reachable))
    })
    .join()
    .expect("the probe returns");
    let (lowered, reach) = reads;
    #[cfg(target_vendor = "apple")]
    assert_eq!((lowered, reach), (true, [true; 5]));
    #[cfg(any(target_os = "linux", target_os = "android"))]
    if lowered {
        let to_zero = sys::may_lower_nice_to(0);
        assert_eq!(reach, [true, sys::may_lower_nice_to(5), to_zero, to_zero, to_zero]);
    }
    let _ = (lowered, reach);
}
