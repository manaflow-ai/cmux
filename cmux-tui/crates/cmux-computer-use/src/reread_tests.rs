use super::*;

#[test]
fn a_read_that_passes_later_is_returned() {
    let mut reads = 0;
    let mut slept = Vec::new();
    let got = reread_with(
        REREAD_WAIT,
        |d| slept.push(d),
        || {
            reads += 1;
            (reads == 3).then_some(reads)
        },
    );
    assert_eq!(got, Some(3));
    assert_eq!(slept, vec![FIRST_STEP, FIRST_STEP * 2]);
}

#[test]
fn a_read_that_never_passes_ends_within_the_bound() {
    let mut slept = Duration::ZERO;
    let got: Option<()> = reread_with(REREAD_WAIT, |d| slept += d, || None);
    assert_eq!(got, None);
    assert!(slept <= REREAD_WAIT, "{slept:?}");
    assert!(slept >= REREAD_WAIT - MAX_STEP, "{slept:?}");
}

#[test]
fn the_first_read_that_passes_does_not_wait() {
    let mut slept = Vec::new();
    assert_eq!(reread_with(REREAD_WAIT, |d| slept.push(d), || Some(1)), Some(1));
    assert!(slept.is_empty());
}

#[test]
fn reread_result_keeps_the_last_error() {
    let mut n = 0;
    let got: Result<(), u32> = reread_result(Duration::from_millis(120), || {
        n += 1;
        Err(n)
    });
    assert_eq!(got, Err(n));
    assert!(n >= 2, "{n}");
}
