//! acpmux in the Release trace ring (plans/cmux-next/chrome-parity/p09-observability.md, task 017).
//!
//! - [`TraceLayer`]: a `tracing_subscriber` layer that writes each `tracing` event as a ring
//!   instant while the recording-only `log` category records, under one name per callsite
//!   (`log.<target>:<line>`, [`site_text`]), with the level in arg0. Fields are dropped: the ring
//!   holds catalog names and numbers only. acpmux has no spans, so the layer maps none. Chrome
//!   writes its log messages into the trace the same way, as instants of their own `log` category
//!   (`TRACE_LOG_MESSAGE` in `base/logging.cc`).
//!   Events of the `log` crate (acpmux's dependencies, through tracing-log's `LogTracer`) share one
//!   fake callsite per level; the layer names them by the record's own target and line.
//! - [`RequestSlice`]: one async slice per JSON-RPC request (the catalog's `daemon.request`), from
//!   its dispatch to its reply, keyed by the connection and the request id, like Chrome's nestable async request events
//!   (`TRACE_EVENT_NESTABLE_ASYNC_BEGIN0`, base/trace_event/common/trace_event_common.h).
//!   [`RequestSlice::wrap`] ties the end to the request's future.
//!
//! Off, each trace point is one relaxed load and a branch ([`cmux_trace::enabled`]), with no
//! allocation. The rings exist only after the process called `cmux_trace::init_blackbox`.

use std::future::Future;
use std::sync::atomic::{AtomicPtr, AtomicU64, Ordering};

use cmux_trace::{
    InternedName, NAME_TEXT_BYTES, Phase, category, trace_async_begin, trace_async_end,
};
use serde_json::Value;
use tracing::{Event, Level, Metadata, Subscriber};
use tracing_log::NormalizeEvent;
use tracing_subscriber::layer::{Context, Layer};

/// Event instants: a recording-only category, so the black box never holds log noise.
const EVENT_CATEGORY: u64 = category::LOG;
/// Requests record in the black box too, as the daemon's do.
const REQUEST_CATEGORY: u64 = category::DAEMON;

/// The bit index of a category, for its name entries (trace.md "category bits").
const fn bit(category: u64) -> u8 {
    category.trailing_zeros() as u8
}

/// The name of [`EVENT_CATEGORY`], read at compile time.
const EVENT_CATEGORY_NAME: &str =
    match cmux_trace::category::NAMES.split_at_checked(bit(EVENT_CATEGORY) as usize) {
        Some((_, [name, ..])) => name,
        _ => "",
    };
// A category bit past the name table fails the build, not a trace.
const _: () = assert!(!EVENT_CATEGORY_NAME.is_empty(), "the log category has no name");

/// log2 of the `tracing` callsites the layer names; past them, events of new callsites are not
/// recorded.
const CALLSITE_BITS: u32 = 10;
/// log2 of the `log` crate sites (target and line) the layer names.
const LOG_SITE_BITS: u32 = 8;
/// The longest probe for a key's slot.
const MAX_PROBE: usize = 32;

/// See the module text. Install it beside the log:
/// `registry().with(filter).with(fmt::layer()).with(TraceLayer::new())`.
pub struct TraceLayer {
    /// Keyed by the address of a callsite's `'static` metadata.
    callsites: NameTable,
    /// Keyed by [`log_site_key`] of a `log` record's target and line.
    log_sites: NameTable,
}

impl Default for TraceLayer {
    fn default() -> Self {
        Self::new()
    }
}

impl TraceLayer {
    pub fn new() -> Self {
        Self { callsites: NameTable::new(CALLSITE_BITS), log_sites: NameTable::new(LOG_SITE_BITS) }
    }

    /// The interned name of a `tracing` callsite, made at its first event while a recording runs.
    fn name_of(&self, metadata: &'static Metadata<'static>) -> Option<&'static InternedName> {
        let key = std::ptr::from_ref(metadata) as usize as u64;
        self.callsites.name_of(key, || site_text(metadata.target(), metadata.line()))
    }

    /// The interned name of a `log` crate site (its record's target and line).
    fn log_name_of(&self, target: &str, line: Option<u32>) -> Option<&'static InternedName> {
        self.log_sites.name_of(log_site_key(target, line), || site_text(target, line))
    }
}

/// A fixed, lock-free open-addressing table of interned names. A slot's `key` is 0 while free;
/// its `name` is null while the thread that claimed the slot makes it.
struct NameTable {
    bits: u32,
    slots: Box<[NameSlot]>,
}

struct NameSlot {
    key: AtomicU64,
    name: AtomicPtr<InternedName>,
}

impl NameTable {
    fn new(bits: u32) -> Self {
        let slots = (0..1usize << bits)
            .map(|_| NameSlot {
                key: AtomicU64::new(0),
                name: AtomicPtr::new(std::ptr::null_mut()),
            })
            .collect();
        Self { bits, slots }
    }

    /// The name of nonzero `key`, made from `text` at its first lookup (the only allocation, once
    /// per key, leaked: a ring name lives for the process). None while another thread makes it,
    /// or when the table has no slot for it.
    fn name_of(&self, key: u64, text: impl FnOnce() -> String) -> Option<&'static InternedName> {
        // Fibonacci hashing: the top bits of the key times 2^64 / phi.
        let start = (key.wrapping_mul(0x9E37_79B9_7F4A_7C15) >> (u64::BITS - self.bits)) as usize;
        let mask = self.slots.len() - 1;
        for probe in 0..MAX_PROBE {
            // `mask` is the power-of-two length minus one: every probe is a slot.
            let slot = self.slots.get((start + probe) & mask)?;
            let claimed = match slot.key.load(Ordering::Acquire) {
                0 => slot
                    .key
                    .compare_exchange(0, key, Ordering::AcqRel, Ordering::Acquire)
                    .map_or_else(|current| current, |_| 0),
                current => current,
            };
            if claimed == 0 {
                let text: &'static str = Box::leak(text().into_boxed_str());
                let name: &'static InternedName =
                    Box::leak(Box::new(InternedName::new(text, bit(EVENT_CATEGORY))));
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

/// `log.<target>:<line>`: the module path and line of a site, under its category's name like every
/// trace name. A text longer than a ring name holds ([`NAME_TEXT_BYTES`]) keeps its line and the
/// last whole path segments that fit, after a hash of the whole target:
/// `log.<hash>~<tail>:<line>`. So every site keeps its own name, and two long targets with one tail
/// stay apart.
fn site_text(target: &str, line: Option<u32>) -> String {
    let category = EVENT_CATEGORY_NAME;
    let line = line.map(|line| format!(":{line}")).unwrap_or_default();
    let full = format!("{category}.{target}{line}");
    if full.len() <= NAME_TEXT_BYTES {
        return full;
    }
    // The low 32 bits of the hash: enough to tell apart the few long targets of one process.
    let head = format!("{category}.{:08x}~", fnv1a(FNV_OFFSET, target.as_bytes()) as u32);
    let room = NAME_TEXT_BYTES - head.len() - line.len();
    // The last `room` bytes, from the first character boundary in them.
    let start = target.len() - room;
    let tail = (start..=target.len()).find_map(|at| target.get(at..)).unwrap_or_default();
    let tail = tail.split_once("::").map_or(tail, |(_, rest)| rest);
    format!("{head}{tail}{line}")
}

/// The key of a `log` site: FNV-1a 64 of its target and line, never 0.
fn log_site_key(target: &str, line: Option<u32>) -> u64 {
    let hash = fnv1a(FNV_OFFSET, target.as_bytes());
    fnv1a(hash, &line.map_or(u64::MAX, u64::from).to_le_bytes()).max(1)
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
        if !cmux_trace::enabled(EVENT_CATEGORY) {
            return;
        }
        let metadata = event.metadata();
        let name = match event.normalized_metadata() {
            Some(log) => self.log_name_of(log.target(), log.line()),
            None => self.name_of(metadata),
        };
        if let Some(name) = name {
            let level = level_number(metadata.level());
            cmux_trace::write_interned(EVENT_CATEGORY, name, Phase::Instant, 0, level, 0);
        }
    }
}

/// An open request slice; dropping it writes the end, on every path out of the request's task, a
/// panic or a cancel included.
#[must_use = "the slice ends when this is dropped"]
pub struct RequestSlice {
    /// 0 when the request was not recorded.
    id: u64,
}

impl RequestSlice {
    /// Begins the slice of request `request` (its JSON-RPC id) for `method` on connection `conn`:
    /// AB with the slice id ([`request_slice_id`]) in arg1 and [`method_hash`] in arg0.
    pub fn begin(conn: &str, request: &Value, method: &str) -> Self {
        if !cmux_trace::enabled(REQUEST_CATEGORY) {
            return Self { id: 0 };
        }
        let id = request_slice_id(conn, request);
        trace_async_begin!(daemon, "daemon.request", id, method_hash(method));
        Self { id }
    }

    /// `request` with this slice: it ends when the future completes or is dropped.
    pub async fn wrap<F: Future>(self, request: F) -> F::Output {
        let _slice = self;
        request.await
    }
}

impl Drop for RequestSlice {
    fn drop(&mut self) {
        if self.id != 0 {
            trace_async_end!(daemon, "daemon.request", self.id);
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

    #[test]
    fn trace_layer_log_sites_are_named_by_target_and_line() {
        let layer = TraceLayer::new();
        let first = layer.log_name_of("rustls::conn", Some(10)).expect("a slot");
        let again = layer.log_name_of("rustls::conn", Some(10)).expect("the same slot");
        assert!(std::ptr::eq(first, again));
        let other_line = layer.log_name_of("rustls::conn", Some(11)).expect("a slot");
        let other_target = layer.log_name_of("notify::inotify", Some(10)).expect("a slot");
        assert!(!std::ptr::eq(first, other_line));
        assert!(!std::ptr::eq(first, other_target));
    }

    #[test]
    fn trace_layer_names_are_under_the_log_category() {
        assert_eq!(site_text("acpmux::hub", Some(7)), "log.acpmux::hub:7");
        assert_eq!(site_text("acpmux::hub", None), "log.acpmux::hub");
    }

    #[test]
    fn trace_layer_long_targets_keep_their_line_within_a_ring_name() {
        let target = "very_long_dependency_crate::transport::connection::read_loop";
        assert_eq!(target.len(), 60);
        let ten = site_text(target, Some(10));
        let eleven = site_text(target, Some(11));
        assert_ne!(ten, eleven, "two lines of one long target share a name");
        for text in [&ten, &eleven] {
            assert!(text.len() <= NAME_TEXT_BYTES, "{text} is longer than a ring name");
            assert!(text.starts_with("log."), "{text}");
            assert!(text.contains("::read_loop:") || text.contains("~read_loop:"), "{text}");
        }
        assert!(ten.ends_with(":10") && eleven.ends_with(":11"));
        // Another long target with the same tail keeps its own name.
        let other = "another_long_dependency_crate::transport::connection::read_loop";
        assert_ne!(site_text(other, Some(10)), ten);
        // A multi-byte target is cut on a character boundary.
        let wide = "é".repeat(40);
        let text = site_text(&wide, Some(1));
        assert!(text.len() <= NAME_TEXT_BYTES && text.ends_with(":1"), "{text}");
    }
}
