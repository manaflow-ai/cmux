use super::{on_protocol_clock, RxThread};
use crate::clock::now_ns;
use crate::fdwait::wait_readable;
use std::net::UdpSocket;
use std::time::Duration;

#[test]
fn a_kernel_stamp_lands_as_long_before_the_read_as_its_age() {
    // Received 30 ms before the wall clock was read: 30 ms before the protocol-clock read.
    assert_eq!(on_protocol_clock(1_000_000_000, 1_030_000_000, 500_000_000), 470_000_000);
    // A stamp from the future or over a second old (a clock step): the read time.
    assert_eq!(on_protocol_clock(2_000_000_000, 1_000_000_000, 500_000_000), 500_000_000);
    assert_eq!(on_protocol_clock(1, 3_000_000_000, 500_000_000), 500_000_000);
}

/// The socket-buffer wait the old single loop booked as Network: datagrams sent while the
/// viewer is busy (a decode) arrive stamped when they landed, not when the viewer looked.
#[test]
fn datagrams_that_land_while_the_viewer_is_busy_keep_their_arrival_time() {
    let viewer = UdpSocket::bind("127.0.0.1:0").unwrap();
    viewer.set_nonblocking(true).unwrap();
    let rx = RxThread::start(&viewer).unwrap();
    let host = UdpSocket::bind("127.0.0.1:0").unwrap();
    let sent = now_ns();
    for i in 0..3u8 {
        host.send_to(&[i; 100], viewer.local_addr().unwrap()).unwrap();
    }
    // The viewer is decoding for 50 ms.
    std::thread::sleep(Duration::from_millis(50));
    let looked = now_ns();
    let mut got = Vec::new();
    let deadline = now_ns() + 2_000_000_000;
    while got.len() < 3 && now_ns() < deadline {
        wait_readable(&[rx.wake_fd()], Some(100_000_000)).unwrap();
        rx.drain(|d, at| got.push((d, at))).unwrap();
    }
    assert_eq!(got.iter().map(|(d, _)| d[0]).collect::<Vec<_>>(), vec![0, 1, 2]);
    for (_, at) in &got {
        assert!(*at >= sent.saturating_sub(1_000_000), "arrival {at} before the send {sent}");
        assert!(*at + 30_000_000 < looked, "arrival {at} is the viewer's look {looked}");
    }
    // Sending still works on the viewer's own handle while the thread reads.
    viewer.send_to(b"up", host.local_addr().unwrap()).unwrap();
    drop(rx);
}
