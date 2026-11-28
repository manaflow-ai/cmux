use super::*;

#[test]
fn a_made_id_is_kept_once_and_the_oldest_ones_go() {
    let replay = ForkReplay::default();
    for i in 0..MADE_KEPT + 2 {
        replay.made(&format!("ses-{i}"));
        replay.made(&format!("ses-{i}"));
    }
    assert!(!replay.is_made("ses-0") && !replay.is_made("ses-1"));
    assert!(replay.is_made("ses-2") && replay.is_made(&format!("ses-{}", MADE_KEPT + 1)));
    assert_eq!(replay.made.lock().unwrap().len(), MADE_KEPT);
}

#[test]
fn the_wait_ends_with_its_guard() {
    let replay = ForkReplay::default();
    let a = replay.asking();
    let b = replay.asking();
    assert_eq!(replay.asking.load(Ordering::SeqCst), 2);
    drop(a);
    drop(b);
    assert_eq!(replay.asking.load(Ordering::SeqCst), 0);
}
