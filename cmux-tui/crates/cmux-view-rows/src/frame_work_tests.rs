use super::*;

fn work(n: usize, all: bool) -> FrameWork {
    measure(|| {
        walked(if all { n } else { n.min(40) });
        built(n.min(40));
    })
}

#[test]
fn a_flat_list_passes_and_a_growing_one_is_named() {
    assert!(contract("visible", Expect::Flat, |n| work(n, false)).is_ok());
    let err = contract("whole", Expect::Flat, |n| work(n, true)).unwrap_err();
    assert!(err.contains("walked 10000"), "{err}");
}

#[test]
fn a_baseline_fails_once_its_list_is_flat() {
    assert!(contract("whole", Expect::Grows("lane x"), |n| work(n, true)).is_ok());
    let err = contract("fixed", Expect::Grows("lane x"), |n| work(n, false)).unwrap_err();
    assert!(err.contains("flip"), "{err}");
}

#[test]
fn measure_counts_only_its_frame() {
    cloned(5);
    assert_eq!(measure(|| cloned(2)), FrameWork { cloned: 2, ..FrameWork::default() });
}
