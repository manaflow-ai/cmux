//! acpmux in the Release trace ring (plans/cmux-next/chrome-parity/p09-observability.md, task 017).
//!
//! - [`TraceLayer`]: a `tracing_subscriber` layer that writes each `tracing` event as a ring
//!   instant while a recording runs, under one name per callsite (`<target>:<line>`), with the
//!   level in arg0. Fields are dropped: the ring holds catalog names and numbers only. acpmux has no
//!   spans, so the layer maps none. Chrome writes its log messages into the trace the same way, as
//!   instants of the `log` category (`base/logging.cc`, `TRACE_EVENT_INSTANT`).
//! - [`RequestSlice`]: one async slice per JSON-RPC request, from its dispatch to its reply, keyed
//!   by the connection and the request id, like Chrome's nestable async request events
//!   (`TRACE_EVENT_NESTABLE_ASYNC_BEGIN0`, base/trace_event/common/trace_event_common.h).
//!
//! Off, each trace point is one relaxed load and a branch ([`cmux_trace::enabled`]), with no
//! allocation. The rings exist only after the process called `cmux_trace::init_blackbox`.

use std::sync::atomic::{AtomicPtr, AtomicUsize, Ordering};

use cmux_trace::{FLAG_ID, InternedName, Phase, category};
use serde_json::Value;
use tracing::{Event, Level, Metadata, Subscriber};
use tracing_subscriber::layer::{Context, Layer};

/// Events record only while a recording runs: any recording-only category is on.
const EVENT_CATEGORIES: u64 = category::RECORDING;
/// Requests record in the black box too, as the daemon's do.
const REQUEST_CATEGORY: u64 = category::DAEMON;
/// The bit index of [`category::DAEMON`], for the name entries (trace.md "category bits").
const DAEMON_BIT: u8 = category::DAEMON.trailing_zeros() as u8;

/// The async slice of one request: AB at dispatch, AE at the reply. arg0 is
/// [`method_hash`] of the method, arg1 the slice id ([`request_slice_id`]).
static REQUEST: InternedName = InternedName::new("acpmux.request", DAEMON_BIT);

/// log2 of the callsites the layer names; past them, events of new callsites are not recorded.
const CALLSITE_BITS: u32 = 10;
const CALLSITE_SLOTS: usize = 1 << CALLSITE_BITS;
/// The longest probe for a callsite's slot.
const MAX_PROBE: usize = 32;

/// See the module text. Install it beside the log:
/// `registry().with(filter).with(fmt::layer()).with(TraceLayer::new())`.
pub struct TraceLayer {
    callsites: Box<[CallsiteSlot]>,
}

/// One callsite's interned name: `key` is the address of its `'static` metadata (0 for a free slot),
/// `name` its name once made (null while the thread that claimed the slot makes it).
struct CallsiteSlot {
    key: AtomicUsize,
    name: AtomicPtr<InternedName>,
}

impl Default for TraceLayer {
    fn default() -> Self {
        Self::new()
    }
}

impl TraceLayer {
    pub fn new() -> Self {
        let callsites = (0..CALLSITE_SLOTS)
            .map(|_| CallsiteSlot {
                key: AtomicUsize::new(0),
                name: AtomicPtr::new(std::ptr::null_mut()),
            })
            .collect();
        Self { callsites }
    }

    /// The interned name of the callsite of `metadata`, made at its first event while a recording
    /// runs (the only allocation, once per callsite, leaked: a ring name lives for the process).
    /// None while another thread makes it, or when the table has no slot for it.
    fn name_of(&self, metadata: &'static Metadata<'static>) -> Option<&'static InternedName> {
        let key = std::ptr::from_ref(metadata) as usize;
        // Fibonacci hashing: the top bits of the address times 2^64 / phi.
        let start =
            key.wrapping_mul(0x9E37_79B9_7F4A_7C15_u64 as usize) >> (usize::BITS - CALLSITE_BITS);
        for probe in 0..MAX_PROBE {
            let slot = &self.callsites[(start + probe) % CALLSITE_SLOTS];
            let claimed = match slot.key.load(Ordering::Acquire) {
                0 => slot
                    .key
                    .compare_exchange(0, key, Ordering::AcqRel, Ordering::Acquire)
                    .map_or_else(|current| current, |_| 0),
                current => current,
            };
            if claimed == 0 {
                let name: &'static InternedName =
                    Box::leak(Box::new(InternedName::new(callsite_text(metadata), DAEMON_BIT)));
                slot.name.store(std::ptr::from_ref(name).cast_mut(), Ordering::Release);
                return Some(name);
            }
            if claimed == key {
                let name = slot.name.load(Ordering::Acquire);
                // SAFETY: a non-null name was leaked by `Box::leak` above and is never freed.
                return unsafe { name.as_ref() };
            }
        }
        None
    }
}

/// `<target>:<line>`: the module path and line of a callsite (a ring name keeps 55 bytes).
fn callsite_text(metadata: &'static Metadata<'static>) -> &'static str {
    let text = match metadata.line() {
        Some(line) => format!("{}:{line}", metadata.target()),
        None => metadata.target().to_owned(),
    };
    Box::leak(text.into_boxed_str())
}

/// arg0 of an event instant: 1 error, 2 warn, 3 info, 4 debug, 5 trace.
fn level_number(level: &Level) -> u64 {
    match *level {
        Level::ERROR => 1,
        Level::WARN => 2,
        Level::INFO => 3,
        Level::DEBUG => 4,
        Level::TRACE => 5,
    }
}

impl<S: Subscriber> Layer<S> for TraceLayer {
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        if !cmux_trace::enabled(EVENT_CATEGORIES) {
            return;
        }
        let metadata = event.metadata();
        if let Some(name) = self.name_of(metadata) {
            let level = level_number(metadata.level());
            cmux_trace::write_interned(EVENT_CATEGORIES, name, Phase::Instant, 0, level, 0);
        }
    }
}

/// An open request slice; dropping it (or [`RequestSlice::end`]) writes the end, on every path out
/// of the request's task, a panic or a cancel included.
#[must_use = "the slice ends when this is dropped"]
pub struct RequestSlice {
    /// 0 when the request was not recorded.
    id: u64,
}

impl RequestSlice {
    /// Begins the slice of request `request` (its JSON-RPC id) for `method` on connection `conn`.
    pub fn begin(conn: &str, request: &Value, method: &str) -> Self {
        if !cmux_trace::enabled(REQUEST_CATEGORY) {
            return Self { id: 0 };
        }
        let id = request_slice_id(conn, request);
        cmux_trace::write_interned(
            REQUEST_CATEGORY,
            &REQUEST,
            Phase::AsyncBegin,
            FLAG_ID,
            method_hash(method),
            id,
        );
        Self { id }
    }

    /// Ends the slice now (the reply is ready).
    pub fn end(self) {}
}

impl Drop for RequestSlice {
    fn drop(&mut self) {
        if self.id != 0 {
            cmux_trace::write_interned(
                REQUEST_CATEGORY,
                &REQUEST,
                Phase::AsyncEnd,
                FLAG_ID,
                0,
                self.id,
            );
        }
    }
}

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

fn fnv1a(mut hash: u64, bytes: &[u8]) -> u64 {
    for byte in bytes {
        hash = (hash ^ u64::from(*byte)).wrapping_mul(FNV_PRIME);
    }
    hash
}

/// arg0 of a request's begin: FNV-1a 64 of the method's UTF-8 bytes, so a trace tool names the
/// slice by hashing the methods it knows (spec/acpmux-protocol.json).
pub fn method_hash(method: &str) -> u64 {
    fnv1a(FNV_OFFSET, method.as_bytes())
}

/// The async id of a request's slice: FNV-1a 64 of the connection id, then a tag and the request
/// id (`n` and the u64 of a number, `s` and the bytes of a string), never 0. Request ids repeat
/// across connections; the pair does not.
pub fn request_slice_id(conn: &str, request: &Value) -> u64 {
    let hash = fnv1a(FNV_OFFSET, conn.as_bytes());
    let hash = match request {
        Value::Number(number) => {
            let bits = number
                .as_u64()
                .or_else(|| number.as_i64().map(i64::cast_unsigned))
                .or_else(|| number.as_f64().map(f64::to_bits))
                .unwrap_or(0);
            fnv1a(fnv1a(hash, b"n"), &bits.to_le_bytes())
        }
        Value::String(text) => fnv1a(fnv1a(hash, b"s"), text.as_bytes()),
        _ => fnv1a(hash, b"-"),
    };
    hash.max(1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn trace_layer_slice_ids_differ_by_connection_and_request() {
        let one = request_slice_id("conn-a", &json!(1));
        assert_eq!(one, request_slice_id("conn-a", &json!(1)));
        assert_ne!(one, request_slice_id("conn-b", &json!(1)));
        assert_ne!(one, request_slice_id("conn-a", &json!(2)));
        assert_ne!(one, request_slice_id("conn-a", &json!("1")));
        assert_ne!(request_slice_id("c", &json!(-1)), 0);
    }

    #[test]
    fn trace_layer_method_hash_is_fnv1a() {
        // The FNV-1a 64 test vectors.
        assert_eq!(method_hash(""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(method_hash("a"), 0xaf63_dc4c_8601_ec8c);
    }

    #[test]
    fn trace_layer_a_callsite_keeps_one_name() {
        let layer = TraceLayer::new();
        let metadata = tracing::info_span!("probe").metadata().expect("span metadata");
        let first = layer.name_of(metadata).expect("a slot");
        let again = layer.name_of(metadata).expect("the same slot");
        assert!(std::ptr::eq(first, again));
    }
}
