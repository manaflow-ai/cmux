//! The bytes queued for each connection, for `gauges.queues` in `daemon status`. Every line a
//! connection sends, replies included, is counted by its outbound queue until the transport's
//! reader takes it (`outbound.rs`), and a queue past its bound ends the connection; this lists
//! what each holds, without touching the writer that drains it.

use super::*;
use std::sync::Weak;

/// The connections the status lists by name, the largest queues first.
const TOP: usize = 8;

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

/// One connection's row in [`status`].
fn row(conn: &Conn) -> (usize, Value) {
    let gauge = conn.out.gauge();
    let row = json!({
        "conn": conn.id,
        "name": conn.name.lock().unwrap_or_else(|e| e.into_inner()).clone(),
        "origin": origin_usage_key(conn.origin),
        "lines": gauge.lines,
        "bytes": gauge.bytes,
        "bound": gauge.bound,
        "overrun": gauge.overrun,
    });
    (gauge.bytes, row)
}

/// `gauges.queues` in `_acpmux/status`: totals over every served connection, the connections
/// ended for falling past their bound since the daemon started, and the [`TOP`] largest queues by
/// bytes.
pub(crate) fn status() -> Value {
    let live: Vec<Arc<Conn>> = {
        let mut conns = conns().lock().unwrap_or_else(|e| e.into_inner());
        conns.retain(|c| c.strong_count() > 0);
        conns.iter().filter_map(Weak::upgrade).collect()
    };
    let mut rows: Vec<(usize, Value)> = live.iter().map(|conn| row(conn)).collect();
    let total: usize = rows.iter().map(|(b, _)| b).sum();
    rows.sort_by_key(|(b, _)| std::cmp::Reverse(*b));
    let top: Vec<Value> = rows.into_iter().take(TOP).map(|(_, row)| row).collect();
    json!({
        "connections": live.len(),
        "bytes": total,
        "overruns": outbound::OVERRUNS.load(Ordering::Relaxed),
        "largest": top,
    })
}
