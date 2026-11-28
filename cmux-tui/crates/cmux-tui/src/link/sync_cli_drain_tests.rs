use std::time::Duration;

use super::drain_heard;

/// A slow write with nothing else landing still lets the app hear from
/// the upload: the quiet stretch is reported while the result waits.
#[test]
fn a_quiet_stretch_with_no_result_is_heard() {
    let (send, results) = std::sync::mpsc::channel::<u32>();
    let slow = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(400));
        send.send(7).unwrap();
    });
    let (mut heard, mut got) = (0, Vec::new());
    let mut idle = || heard += 1;
    drain_heard(&results, Some((Duration::from_millis(50), &mut idle)), &mut |item| {
        got.push(item);
    });
    slow.join().unwrap();
    assert_eq!(got, vec![7]);
    assert!(heard >= 2, "the quiet stretch was heard {heard} times");
}

/// Without an idle beat every result is still handed on, then it ends.
#[test]
fn every_result_is_handed_on_without_a_beat() {
    let (send, results) = std::sync::mpsc::channel::<u32>();
    for item in 0..3 {
        send.send(item).unwrap();
    }
    drop(send);
    let mut got = Vec::new();
    drain_heard(&results, None, &mut |item| got.push(item));
    assert_eq!(got, vec![0, 1, 2]);
}
