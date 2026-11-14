use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::time::Duration;

use super::{PtySize, open};

const WHEEL_UP: &[u8] = b"\x1b[<65;30;7M";

fn raw(slave: &std::fs::File) {
    let mut termios = std::mem::MaybeUninit::<libc::termios>::zeroed();
    assert_eq!(unsafe { libc::tcgetattr(slave.as_raw_fd(), termios.as_mut_ptr()) }, 0);
    let mut termios = unsafe { termios.assume_init() };
    unsafe { libc::cfmakeraw(&mut termios) };
    assert_eq!(unsafe { libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &termios) }, 0);
}

#[test]
fn a_full_input_queue_never_ends_in_a_lone_escape() {
    let (master, slave) =
        open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
    let mut slave = slave.0;
    raw(&slave);
    let mut writer = master.take_writer().unwrap();
    // The program is busy: the queue holds 1,021 bytes, one short of full.
    writer.write_all(&[b'x'; 1021]).unwrap();
    let reports = std::thread::spawn(move || {
        writer.write_all(WHEEL_UP).unwrap();
        writer
    });
    // Let the writer reach the full queue (the old writer blocks there, after the ESC).
    std::thread::sleep(Duration::from_millis(200));

    // crossterm reads 1,024 bytes at a time; a short read that ends in ESC is the Esc key.
    let mut buffer = [0u8; 1024];
    let first = slave.read(&mut buffer).unwrap();
    assert!(
        buffer[first - 1] != 0x1b,
        "the program read {first} bytes ending in a lone ESC: the wheel report was cut after its ESC"
    );
    let _writer = reports.join().unwrap();
    let mut got = buffer[..first].to_vec();
    while got.len() < 1021 + WHEEL_UP.len() {
        let n = slave.read(&mut buffer).unwrap();
        got.extend_from_slice(&buffer[..n]);
    }
    assert_eq!(&got[1021..], WHEEL_UP, "the wheel report arrived changed");
}
