//! A composer or Feed send through the host's input path: the PTY child reads the paste, then Return alone
//! (`paste_pacing`).

use super::*;
use crate::paste_pacing::SETTLE;
use std::time::Instant;

/// One flush: the bytes and when they were flushed.
type Flush = (Vec<u8>, Instant);

/// The PTY's writer: one entry per flush (each write the child can read), with when it was flushed.
#[derive(Clone, Default)]
struct FlushLog {
    flushed: Arc<Mutex<Vec<Flush>>>,
    pending: Arc<Mutex<Vec<u8>>>,
}

impl Write for FlushLog {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.pending.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        let bytes = std::mem::take(&mut *self.pending.lock().unwrap());
        if !bytes.is_empty() {
            self.flushed.lock().unwrap().push((bytes, Instant::now()));
        }
        Ok(())
    }
}

fn draft(len: usize) -> Vec<u8> {
    (0..len).map(|index| b"the connection is actually working "[index % 35]).collect()
}

fn bracketed(text: &[u8]) -> Vec<u8> {
    let mut bytes = b"\x1b[200~".to_vec();
    bytes.extend_from_slice(text);
    bytes.extend_from_slice(b"\x1b[201~");
    bytes
}

fn host_with_log() -> (Arc<HostShared>, FlushLog, HostTap, Receiver<Arc<Frame>>, UnixStream) {
    let host = test_host_shared();
    let log = FlushLog::default();
    *host.writer.lock().unwrap() = Box::new(log.clone());
    let (target_socket, target_peer) = UnixStream::pair().unwrap();
    let (target_tx, target_rx) = mpsc_channel();
    let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
    (host, log, target, target_rx, target_peer)
}

#[test]
fn a_multi_kb_draft_and_its_return_in_one_input_frame_reach_the_child_as_the_paste_then_return_alone()
 {
    // The phone's batch held the composer's paste and its Return (one `send`, one Input frame).
    let (host, log, target, _rx, _peer) = host_with_log();
    let paste = bracketed(&draft(8 * 1024));
    let mut frame = paste.clone();
    frame.push(b'\r');
    assert!(host.write_input(&frame, 0, &target));
    let flushed = log.flushed.lock().unwrap();
    assert_eq!(flushed.len(), 2, "the paste and Return are two writes");
    assert_eq!(flushed[0].0, paste, "exactly one paste, through its end marker");
    assert_eq!(flushed[1].0, b"\r", "Return alone");
    assert!(
        flushed[1].1 - flushed[0].1 >= SETTLE,
        "Return waited {:?}",
        flushed[1].1 - flushed[0].1
    );
}

#[test]
fn return_as_its_own_frame_right_after_a_paste_frame_waits_for_the_settle() {
    // `send` with `submit` (a Feed reply): a Paste frame, then Return with no gap.
    let (host, log, target, _rx, _peer) = host_with_log();
    host.term.lock().unwrap().vt_write(b"\x1b[?2004h");
    let text = draft(6 * 1024);
    host.write_paste_frame(&text);
    assert!(host.write_input(b"\r", 0, &target));
    let flushed = log.flushed.lock().unwrap();
    assert_eq!(flushed.len(), 2);
    assert_eq!(flushed[0].0, bracketed(&text));
    assert_eq!(flushed[1].0, b"\r");
    assert!(
        flushed[1].1 - flushed[0].1 >= SETTLE,
        "Return waited {:?}",
        flushed[1].1 - flushed[0].1
    );
}

#[test]
fn typing_with_no_paste_before_it_is_not_held() {
    let (host, log, target, _rx, _peer) = host_with_log();
    let start = Instant::now();
    assert!(host.write_input(b"ls\r", 0, &target));
    assert!(host.write_input(b"x", 0, &target));
    assert!(start.elapsed() < SETTLE);
    let flushed = log.flushed.lock().unwrap();
    assert_eq!(
        flushed.iter().map(|(bytes, _)| bytes.clone()).collect::<Vec<_>>(),
        vec![b"ls\r".to_vec(), b"x".to_vec()]
    );
}
