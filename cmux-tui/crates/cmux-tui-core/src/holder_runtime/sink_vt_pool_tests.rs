//! p01-process-120: a holder terminal's sink on its VT pool shard.

use super::*;

/// A holder terminal's parser on a VT pool shard: reports each chunk it
/// parsed, and an empty one when it finished.
struct ShardParser {
    sink: Arc<HolderSink>,
    parsed: std::sync::mpsc::Sender<Vec<u8>>,
}

impl crate::vt_pool::VtSource for ShardParser {
    fn run(&mut self, _: &mut crate::vt_pool::Slice) -> crate::vt_pool::VtFlow {
        let mut buf = [0u8; 4096];
        loop {
            let Some((n, _)) = self.sink.try_read(&mut buf) else {
                return crate::vt_pool::VtFlow::Idle;
            };
            if n == 0 {
                return crate::vt_pool::VtFlow::Finished;
            }
            self.sink.confirm_parsed();
            let _ = self.parsed.send(buf[..n].to_vec());
        }
    }

    fn finish(self: Box<Self>) {
        let _ = self.parsed.send(Vec::new());
    }
}

fn one_shard_pool() -> crate::vt_pool::VtPool {
    use crate::vt_pool::{SliceBudget, VtPool, VtPoolConfig};
    VtPool::new(VtPoolConfig { shards: 1, slice: SliceBudget::DEFAULT })
}

/// p01-process-120: the credit acknowledgement goes out on the holder
/// link's one writer, which a slow holder holds up (another terminal's
/// snapshot or keys fill its socket). Held there, the terminal blocks
/// only itself: another terminal of its shard still parses.
#[test]
fn an_acknowledgement_held_up_on_the_link_writer_never_stops_its_shard() {
    let wait = std::time::Duration::from_secs(10);
    let pool = one_shard_pool();
    // The holder link's writer.
    let writer = Arc::new(Mutex::new(()));
    let (entered, acking) = std::sync::mpsc::channel();
    let (acked, acks) = std::sync::mpsc::channel();
    let slow = HolderSink::new(0);
    let link = writer.clone();
    slow.set_acker(Box::new(move |offset| {
        let _ = entered.send(offset);
        let _writer = link.lock().recover_poison();
        let _ = acked.send(offset);
    }));
    assert_eq!(acking.recv_timeout(wait), Ok(0), "set_acker acknowledges what was parsed");
    assert_eq!(acks.recv_timeout(wait), Ok(0));
    let (slow_parsed, _slow_chunks) = std::sync::mpsc::channel();
    let wake = pool
        .register(Box::new(ShardParser { sink: slow.clone(), parsed: slow_parsed }))
        .map_err(drop)
        .unwrap();
    slow.set_wake(wake);
    let other = HolderSink::new(0);
    let (parsed, other_chunks) = std::sync::mpsc::channel();
    let wake =
        pool.register(Box::new(ShardParser { sink: other.clone(), parsed })).map_err(drop).unwrap();
    other.set_wake(wake);

    let held = writer.lock().recover_poison();
    let burst = usize::try_from(ACK_EVERY).unwrap();
    slow.data(0, &vec![b'x'; burst]);
    assert_eq!(acking.recv_timeout(wait), Ok(ACK_EVERY), "the acknowledgement came due");
    other.data(0, b"echo");
    assert_eq!(
        other_chunks.recv_timeout(wait).as_deref(),
        Ok(&b"echo"[..]),
        "the shard waited for the link writer"
    );
    drop(held);
    assert_eq!(acks.recv_timeout(wait), Ok(ACK_EVERY));
}

/// p01-process-120: the holder-link thread's DATA and the end wake the
/// terminal's VT pool shard, which reads without waiting: what came
/// before the wake was set runs once it is set, and the end finishes it.
#[test]
fn data_and_the_end_wake_the_terminal_on_its_vt_pool_shard() {
    let wait = std::time::Duration::from_secs(10);
    let pool = one_shard_pool();
    let sink = HolderSink::new(0);
    sink.data(0, b"before ");
    let (parsed, received) = std::sync::mpsc::channel();
    let parser = ShardParser { sink: sink.clone(), parsed };
    let wake = pool.register(Box::new(parser)).map_err(drop).unwrap();
    assert!(received.recv_timeout(std::time::Duration::from_millis(50)).is_err());
    sink.set_wake(wake);
    assert_eq!(received.recv_timeout(wait).unwrap(), b"before ");
    sink.data(7, b"after");
    assert_eq!(received.recv_timeout(wait).unwrap(), b"after");
    assert_eq!(sink.confirmed(), 12);
    sink.exit(ExitStatus::Exited(0), 12);
    assert_eq!(received.recv_timeout(wait).unwrap(), b"", "the end finished it");
    // Nothing queued and no end: the read says so instead of waiting.
    let idle = HolderSink::new(0);
    assert_eq!(idle.try_read(&mut [0u8; 8]), None);
}
