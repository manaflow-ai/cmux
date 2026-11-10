//! The host client writer: frames queued at one wake go out together, in
//! order, and each frame's queue bytes are released after its write.

use super::*;

/// Frames queued for one client, the writer's private wake sentinel last.
fn queue(tap: &HostTap, frames: &[Frame]) {
    for frame in frames {
        assert!(tap.try_send(frame.clone()));
    }
}

fn numbered_output(count: u64, len: usize) -> Vec<Frame> {
    (1..=count)
        .map(|sequence| {
            let mut frame = Frame::new(MessageKind::Output, vec![sequence as u8; len]);
            frame.sequence = sequence;
            frame
        })
        .collect()
}

fn read_all(mut peer: UnixStream) -> Vec<Frame> {
    let mut frames = Vec::new();
    while let Some(frame) = read_frame(&mut peer, MAX_FRAME_PAYLOAD).unwrap() {
        frames.push(frame);
    }
    frames
}

#[test]
fn the_writer_sends_every_queued_frame_in_order_and_releases_its_bytes() {
    let (socket, peer) = UnixStream::pair().unwrap();
    let (sender, receiver) = mpsc_channel();
    let tap = HostTap::new(sender, Arc::new(socket.try_clone().unwrap()), usize::MAX);
    // More frames and bytes than one batch takes, so the writer batches several times.
    let frames = numbered_output(3 * MAX_BATCH_FRAMES as u64 + 5, 3000);
    queue(&tap, &frames);
    tap.wake_writer();
    let reader = thread::spawn(move || read_all(peer));
    let mut stream = socket;
    write_queued_frames(&mut stream, &receiver, &tap);
    drop(stream);
    tap.close();
    assert_eq!(reader.join().unwrap(), frames);
    assert_eq!(tap.queued_bytes.load(Ordering::Acquire), 0);
    assert_eq!(tap.queued_output_bytes.load(Ordering::Acquire), 0);
}

#[test]
fn the_writer_stops_after_exit_and_writes_nothing_queued_behind_it() {
    let (socket, peer) = UnixStream::pair().unwrap();
    let (sender, receiver) = mpsc_channel();
    let tap = HostTap::new(sender, Arc::new(socket.try_clone().unwrap()), usize::MAX);
    let mut frames = numbered_output(3, 10);
    let mut exit = Frame::new(MessageKind::Exit, Vec::new());
    exit.sequence = 4;
    frames.push(exit);
    queue(&tap, &frames);
    queue(&tap, &numbered_output(2, 7));
    let reader = thread::spawn(move || read_all(peer));
    let mut stream = socket;
    write_queued_frames(&mut stream, &receiver, &tap);
    tap.close();
    drop(stream);
    assert_eq!(reader.join().unwrap(), frames);
}

#[test]
fn a_lone_frame_leaves_without_waiting_for_more() {
    let (socket, mut peer) = UnixStream::pair().unwrap();
    let (sender, receiver) = mpsc_channel();
    let tap = HostTap::new(sender, Arc::new(socket.try_clone().unwrap()), usize::MAX);
    let writer = {
        let tap = tap.clone();
        thread::spawn(move || {
            let mut stream = socket;
            write_queued_frames(&mut stream, &receiver, &tap);
        })
    };
    let echo = numbered_output(1, 1);
    queue(&tap, &echo);
    peer.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    // The writer holds the only other frame source open: a writer that
    // waited for a fuller batch would time this read out.
    assert_eq!(read_frame(&mut peer, MAX_FRAME_PAYLOAD).unwrap().as_ref(), echo.first());
    tap.wake_writer();
    writer.join().unwrap();
}

#[test]
fn a_failed_write_ends_the_writer_and_releases_the_batch() {
    let (socket, peer) = UnixStream::pair().unwrap();
    drop(peer);
    let (sender, receiver) = mpsc_channel();
    let tap = HostTap::new(sender, Arc::new(socket.try_clone().unwrap()), usize::MAX);
    queue(&tap, &numbered_output(4, 100));
    let mut stream = socket;
    write_queued_frames(&mut stream, &receiver, &tap);
    assert_eq!(tap.queued_bytes.load(Ordering::Acquire), 0);
}
