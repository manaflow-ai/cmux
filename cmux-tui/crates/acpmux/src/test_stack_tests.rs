/// A unit test's thread has the daemon's worker stack: a frame that needs more than std's
/// 2 MiB, but fits the daemon's 8 MiB, does not abort.
#[test]
fn a_unit_test_thread_has_the_daemons_worker_stack() {
    #[inline(never)]
    fn deep(depth: usize) -> u8 {
        let mut buf = [0u8; 64 * 1024];
        std::hint::black_box(&mut buf);
        let here = buf.get(depth).copied().unwrap_or_default();
        if depth == 0 { here } else { deep(depth - 1).wrapping_add(here) }
    }
    // 48 frames of 64 KiB: about 3 MiB, past 2 MiB and well within 8 MiB.
    assert_eq!(std::hint::black_box(deep(48)), 0);
}
