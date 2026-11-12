//! The bytes queued for each connection, for `gauges.queues` in `daemon status`. A connection's
//! outbound queue is bounded at 4,096 lines, and a line may be 31 MiB (rework finding C2), and a
//! reply that found the queue full waits in a task of its own that no bound counts (C1). Neither
//! was visible: this counts both, per connection, without touching the writer that drains it.
//!
//! The queue is first in, first out, so the bytes it holds are the sizes of its newest `depth`
//! lines, `depth` being what the channel says it holds now: each line queued notes its size, and
//! a read drops the oldest sizes past `depth`. A reply that waited for room is noted when it got
//! in, so the sum is near, not exact, while such replies land. With the event journal on, the
//! connection queues into its durable gate, so the lines the gate holds and the transport's own
//! queue past it are counted too (`durable_gate.rs`).

use super::*;
use std::collections::VecDeque;
use std::sync::Weak;

/// The connections the status lists by name, the largest queues first.
const TOP: usize = 8;

/// One connection's queued line sizes and the bytes of its replies still waiting for room.
#[derive(Clone, Default)]
pub(crate) struct Queued(Arc<Inner>);

#[derive(Default)]
struct Inner {
    sizes: StdMutex<VecDeque<usize>>,
    waiting: AtomicUsize,
    waiting_replies: AtomicUsize,
}

/// A reply waiting in its own task for room in a full queue: counted until it drops.
pub(super) struct Waiting {
    queued: Queued,
    bytes: usize,
}

impl Drop for Waiting {
    fn drop(&mut self) {
        self.queued.0.waiting.fetch_sub(self.bytes, Ordering::Relaxed);
        self.queued.0.waiting_replies.fetch_sub(1, Ordering::Relaxed);
    }
}

impl Queued {
    /// A line of `bytes` went into `out`.
    pub(super) fn queued(&self, bytes: usize, out: &mpsc::Sender<String>) {
        let mut sizes = self.0.sizes.lock().unwrap_or_else(|e| e.into_inner());
        sizes.push_back(bytes);
        trim(&mut sizes, depth(out));
    }

    /// A reply of `bytes` waits for room in a full queue.
    pub(super) fn waiting(&self, bytes: usize) -> Waiting {
        self.0.waiting.fetch_add(bytes, Ordering::Relaxed);
        self.0.waiting_replies.fetch_add(1, Ordering::Relaxed);
        Waiting { queued: self.clone(), bytes }
    }

    /// The bytes `out` holds now.
    pub(super) fn bytes(&self, out: &mpsc::Sender<String>) -> usize {
        let mut sizes = self.0.sizes.lock().unwrap_or_else(|e| e.into_inner());
        trim(&mut sizes, depth(out));
        sizes.iter().sum()
    }
}

#[cfg(test)]
impl Queued {
    pub(super) fn bytes_for_tests(&self, out: &mpsc::Sender<String>) -> usize {
        self.bytes(out)
    }

    /// The replies waiting for room, and their bytes.
    pub(super) fn waiting_for_tests(&self) -> (usize, usize) {
        (self.0.waiting_replies.load(Ordering::Relaxed), self.0.waiting.load(Ordering::Relaxed))
    }
}

pub(super) fn depth(out: &mpsc::Sender<String>) -> usize {
    out.max_capacity().saturating_sub(out.capacity())
}

fn trim(sizes: &mut VecDeque<usize>, depth: usize) {
    while sizes.len() > depth {
        sizes.pop_front();
    }
}

fn conns() -> &'static StdMutex<Vec<Weak<Conn>>> {
    // test-hook-allow: the served connections, read by `daemon status`; no test sets or clears it.
    static CONNS: std::sync::OnceLock<StdMutex<Vec<Weak<Conn>>>> = std::sync::OnceLock::new();
    CONNS.get_or_init(Default::default)
}

/// `conn` is served: the status counts its queue until it drops.
pub(super) fn register(conn: &Arc<Conn>) {
    let mut conns = conns().lock().unwrap_or_else(|e| e.into_inner());
    conns.retain(|c| c.strong_count() > 0);
    conns.push(Arc::downgrade(conn));
}

/// `gauges.queues` in `_acpmux/status`: totals over every served connection, and the
/// [`TOP`] largest queues by bytes.
pub(crate) fn status() -> Value {
    let live: Vec<Arc<Conn>> = {
        let mut conns = conns().lock().unwrap_or_else(|e| e.into_inner());
        conns.retain(|c| c.strong_count() > 0);
        conns.iter().filter_map(Weak::upgrade).collect()
    };
    let mut rows: Vec<(usize, Value)> = live
        .iter()
        .map(|conn| {
            // With the event journal on, `out` is the gate's input: the lines the gate holds and
            // the transport's queue past it count too (`durable_gate.rs`).
            let (gate_lines, gate_bytes) = conn.gate.as_ref().map_or((0, 0), |gate| gate.backlog());
            let bytes = conn.queued.bytes(&conn.out) + gate_bytes;
            let waiting = conn.queued.0.waiting.load(Ordering::Relaxed);
            let row = json!({
                "conn": conn.id,
                "name": conn.name.lock().unwrap_or_else(|e| e.into_inner()).clone(),
                "origin": origin_usage_key(conn.origin),
                "lines": depth(&conn.out) + gate_lines,
                "bytes": bytes,
                "waitingReplies": conn.queued.0.waiting_replies.load(Ordering::Relaxed),
                "waitingReplyBytes": waiting,
                "dropped": conn.outbound_dropped.load(Ordering::Relaxed),
            });
            (bytes + waiting, row)
        })
        .collect();
    let total: usize = rows.iter().map(|(b, _)| b).sum();
    rows.sort_by_key(|(b, _)| std::cmp::Reverse(*b));
    let top: Vec<Value> = rows.into_iter().take(TOP).map(|(_, row)| row).collect();
    json!({"connections": live.len(), "bytes": total, "largest": top})
}
