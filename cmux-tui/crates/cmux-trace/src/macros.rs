//! The trace points: Chrome's `TRACE_EVENT*` macros (`base/trace_event/common/trace_event_common.h`)
//! over the process ring. Each call site owns one `static` [`TraceSite`]: its category, its catalog id
//! (resolved at compile time from [`crate::names::CATALOG`]) or, for a name outside the catalog, its
//! per-ring interned ids.
//!
//! ```
//! # use cmux_trace::{trace_scope, trace_instant, trace_async_begin, trace_async_end};
//! # let (method, request_hash, request_id) = (3u16, 7u64, 41u64);
//! let _request = trace_scope!(daemon, "daemon.request", method, request_hash);
//! trace_instant!(daemon, "daemon.request.parsed");
//! trace_async_begin!(daemon, "daemon.url_open", request_id);
//! trace_async_end!(daemon, "daemon.url_open", request_id);
//! ```
//!
//! The first argument names a category (`cmux_trace::category`, lower case); the second is a string
//! literal. Arguments are numbers ([`TraceArg`]) and are evaluated only while the category records.
//! A category that is off costs one relaxed load and one branch, as Chrome's
//! `category_group_enabled` read does; `trace_instant!(ghostty, "ghostty.x", n)` expands to
//!
//! ```text
//! {
//!     const __CMUX_TRACE_CATEGORY: u64 = ::cmux_trace::__categories::ghostty;
//!     static __CMUX_TRACE_SITE: ::cmux_trace::TraceSite =
//!         ::cmux_trace::TraceSite::new(__CMUX_TRACE_CATEGORY, "ghostty.x");
//!     if ::cmux_trace::enabled(__CMUX_TRACE_CATEGORY) {
//!         __CMUX_TRACE_SITE.emit(::cmux_trace::Phase::Instant, 0,
//!             ::cmux_trace::TraceArg::trace_arg(n), ::cmux_trace::TraceArg::trace_arg(0u64));
//!     }
//! }
//! ```
//!
//! [`trace_scope!`](crate::trace_scope) also keeps the thread's open scopes on a fixed stack ([`scope_stack`]), for the
//! panic lines (task 082) and the crash-key page (task 098).

use std::cell::Cell;
use std::marker::PhantomData;

use crate::Phase;
use crate::ring::Record;
use crate::tracer::InternedName;

/// The categories by their lower-case names, for the macros' first argument.
#[doc(hidden)]
#[allow(non_upper_case_globals)]
pub mod categories {
    use crate::category as c;

    pub const action: u64 = c::ACTION;
    pub const key: u64 = c::KEY;
    pub const switch: u64 = c::SWITCH;
    pub const create: u64 = c::CREATE;
    pub const cef: u64 = c::CEF;
    pub const launch: u64 = c::LAUNCH;
    pub const daemon: u64 = c::DAEMON;
    pub const hang: u64 = c::HANG;
    pub const crash: u64 = c::CRASH;
    pub const motion: u64 = c::MOTION;
    pub const frame: u64 = c::FRAME;
    pub const stall: u64 = c::STALL;
    pub const task: u64 = c::TASK;
    pub const burst: u64 = c::BURST;
    pub const input: u64 = c::INPUT;
    pub const webview: u64 = c::WEBVIEW;
    pub const remote: u64 = c::REMOTE;
    pub const control: u64 = c::CONTROL;
    pub const ghostty: u64 = c::GHOSTTY;
    pub const resize: u64 = c::RESIZE;
}

/// One trace point: a `static` the macros declare at each call site.
#[derive(Debug)]
pub struct TraceSite {
    category: u64,
    catalog_id: u16,
    text: &'static str,
    interned: InternedName,
}

impl TraceSite {
    /// The site of `text` in `category` (one bit of `cmux_trace::category`). Runs at compile time
    /// in the macros' `static`: a catalog text takes its fixed id, and a catalog text under another
    /// category, an empty name or one longer than a name entry holds does not compile.
    pub const fn new(category: u64, text: &'static str) -> TraceSite {
        assert!(category.count_ones() == 1, "a trace point has exactly one category");
        assert!(!text.is_empty(), "a trace point has a name");
        assert!(text.len() <= crate::layout::NAME_TEXT_BYTES, "a trace name is at most 55 bytes");
        let bit = category.trailing_zeros() as u8;
        let catalog_id = crate::names::catalog_id(text);
        if let Some(entry) = crate::names::catalog_name(catalog_id) {
            assert!(entry.category == bit, "this catalog name belongs to another category");
        }
        TraceSite { category, catalog_id, text, interned: InternedName::new(text, bit) }
    }

    /// Its category's mask.
    pub fn category(&self) -> u64 {
        self.category
    }

    /// Its catalog id; 0 for a name interned at run time.
    pub fn catalog_id(&self) -> u16 {
        self.catalog_id
    }

    pub fn text(&self) -> &'static str {
        self.text
    }

    /// Writes one record now. The macros call it only after [`crate::enabled`] said yes.
    #[doc(hidden)]
    #[inline(never)]
    pub fn emit(&self, phase: Phase, flags: u8, arg0: u64, arg1: u64) {
        let record = Record {
            t_ns: crate::clock::now_ns(),
            name: self.catalog_id,
            phase,
            flags,
            arg0,
            arg1,
        };
        crate::write_process(record, (self.catalog_id == 0).then_some(&self.interned));
    }
}

/// A trace argument: integers and `bool` as their u64 bits (a signed value as two's complement).
pub trait TraceArg: Copy {
    fn trace_arg(self) -> u64;
}

macro_rules! trace_arg_lossless {
    ($($ty:ty),*) => {$(
        impl TraceArg for $ty {
            #[inline(always)]
            fn trace_arg(self) -> u64 {
                u64::from(self)
            }
        }
    )*};
}
trace_arg_lossless!(u8, u16, u32, u64, bool);

macro_rules! trace_arg_bits {
    ($($ty:ty),*) => {$(
        impl TraceArg for $ty {
            #[inline(always)]
            fn trace_arg(self) -> u64 {
                self as u64
            }
        }
    )*};
}
trace_arg_bits!(usize, i8, i16, i32, i64, isize);

/// The open scopes a thread's stack keeps (deeper ones are counted in [`ScopeStack::depth`]).
pub const SCOPE_STACK_DEPTH: usize = 16;

struct Scopes {
    sites: [Cell<Option<&'static TraceSite>>; SCOPE_STACK_DEPTH],
    depth: Cell<u32>,
}

thread_local! {
    static SCOPES: Scopes = const {
        Scopes { sites: [const { Cell::new(None) }; SCOPE_STACK_DEPTH], depth: Cell::new(0) }
    };
}

/// The guard index of a scope that is not on the stack (the thread's TLS was already destroyed).
const NOT_ON_STACK: u32 = u32::MAX;

/// An open [`trace_scope!`](crate::trace_scope): writes the slice's end (E) on the thread that opened it when dropped,
/// like Chrome's `ScopedTracer`. Not `Send`: a same-thread slice ends on its own thread.
#[must_use = "the scope ends when this guard drops: bind it with `let _scope = trace_scope!(..)`"]
pub struct ScopeGuard {
    site: Option<&'static TraceSite>,
    index: u32,
    end: (u64, u64),
    not_send: PhantomData<*const ()>,
}

impl ScopeGuard {
    /// The guard of a scope whose category was off when it opened: its drop writes nothing.
    #[doc(hidden)]
    pub const OFF: ScopeGuard =
        ScopeGuard { site: None, index: NOT_ON_STACK, end: (0, 0), not_send: PhantomData };

    /// Writes the slice's begin (B) and pushes it on the thread's scope stack. The macro calls it
    /// only after [`crate::enabled`] said yes.
    #[doc(hidden)]
    #[inline(never)]
    pub fn begin(site: &'static TraceSite, arg0: u64, arg1: u64) -> ScopeGuard {
        site.emit(Phase::Begin, 0, arg0, arg1);
        let index = SCOPES
            .try_with(|scopes| {
                let depth = scopes.depth.get();
                if let Some(slot) = scopes.sites.get(depth as usize) {
                    slot.set(Some(site));
                }
                scopes.depth.set(depth.saturating_add(1));
                depth
            })
            .unwrap_or(NOT_ON_STACK);
        ScopeGuard { site: Some(site), index, end: (0, 0), not_send: PhantomData }
    }

    /// The numbers the slice's end record carries (its result, as Swift's `end(_:arg0:arg1:)`).
    pub fn set_end_args(&mut self, arg0: impl TraceArg, arg1: impl TraceArg) {
        self.end = (arg0.trace_arg(), arg1.trace_arg());
    }

    #[inline(never)]
    fn close(&self, site: &'static TraceSite) {
        // Chrome's ScopedTracer checks the category again at the end: a recording stopped inside
        // the scope leaves its begin open rather than an end in the black box with no begin.
        if crate::enabled(site.category) {
            site.emit(Phase::End, 0, self.end.0, self.end.1);
        }
        if self.index != NOT_ON_STACK {
            // Truncate to this scope's place: a scope dropped out of order takes the ones above it.
            let _ = SCOPES.try_with(|scopes| {
                if scopes.depth.get() > self.index {
                    scopes.depth.set(self.index);
                }
            });
        }
    }
}

impl Drop for ScopeGuard {
    #[inline]
    fn drop(&mut self) {
        if let Some(site) = self.site {
            self.close(site);
        }
    }
}

/// A copy of a thread's open scopes, taken with no allocation.
#[derive(Clone, Copy, Debug)]
pub struct ScopeStack {
    sites: [Option<&'static TraceSite>; SCOPE_STACK_DEPTH],
    depth: u32,
}

impl ScopeStack {
    /// How many scopes are open, those past [`SCOPE_STACK_DEPTH`] too.
    pub fn depth(&self) -> u32 {
        self.depth
    }

    /// The kept scopes, innermost first (the outermost [`SCOPE_STACK_DEPTH`] of them).
    pub fn sites(&self) -> impl Iterator<Item = &'static TraceSite> + '_ {
        let kept = (self.depth as usize).min(SCOPE_STACK_DEPTH);
        self.sites[..kept].iter().rev().filter_map(|site| *site)
    }

    /// The kept scopes' names, innermost first.
    pub fn names(&self) -> impl Iterator<Item = &'static str> + '_ {
        self.sites().map(TraceSite::text)
    }
}

/// The calling thread's open [`trace_scope!`](crate::trace_scope)s. Empty once the thread's TLS is gone.
pub fn scope_stack() -> ScopeStack {
    SCOPES
        .try_with(|scopes| ScopeStack {
            sites: std::array::from_fn(|index| scopes.sites[index].get()),
            depth: scopes.depth.get(),
        })
        .unwrap_or(ScopeStack { sites: [None; SCOPE_STACK_DEPTH], depth: 0 })
}

/// Writes one record of `$phase` at a call site's static [`TraceSite`] while its category records.
#[doc(hidden)]
#[macro_export]
macro_rules! __trace_emit {
    ($cat:ident, $name:literal, $phase:ident, $flags:expr, $arg0:expr, $arg1:expr) => {{
        const __CMUX_TRACE_CATEGORY: u64 = $crate::__categories::$cat;
        static __CMUX_TRACE_SITE: $crate::TraceSite =
            $crate::TraceSite::new(__CMUX_TRACE_CATEGORY, $name);
        if $crate::enabled(__CMUX_TRACE_CATEGORY) {
            __CMUX_TRACE_SITE.emit(
                $crate::Phase::$phase,
                $flags,
                $crate::TraceArg::trace_arg($arg0),
                $crate::TraceArg::trace_arg($arg1),
            );
        }
    }};
}

/// Opens a same-thread slice (B) and returns its [`ScopeGuard`], which ends it (E) when dropped:
/// `let _scope = trace_scope!(daemon, "daemon.request", method, request_hash);`
/// (Chrome's `TRACE_EVENT2`). The arguments go in the begin record's `arg0` and `arg1`;
/// [`ScopeGuard::set_end_args`] sets the end record's.
///
/// The guard ends the slice on the thread that opened it:
///
/// ```compile_fail
/// fn send<T: Send>(_: T) {}
/// send(cmux_trace::trace_scope!(daemon, "daemon.request"));
/// ```
///
/// A catalog name only goes with its own category:
///
/// ```compile_fail
/// let _scope = cmux_trace::trace_scope!(key, "daemon.request");
/// ```
#[macro_export]
macro_rules! trace_scope {
    ($cat:ident, $name:literal $(,)?) => {
        $crate::trace_scope!($cat, $name, 0u64, 0u64)
    };
    ($cat:ident, $name:literal, $arg0:expr $(,)?) => {
        $crate::trace_scope!($cat, $name, $arg0, 0u64)
    };
    ($cat:ident, $name:literal, $arg0:expr, $arg1:expr $(,)?) => {{
        const __CMUX_TRACE_CATEGORY: u64 = $crate::__categories::$cat;
        static __CMUX_TRACE_SITE: $crate::TraceSite =
            $crate::TraceSite::new(__CMUX_TRACE_CATEGORY, $name);
        if $crate::enabled(__CMUX_TRACE_CATEGORY) {
            $crate::ScopeGuard::begin(
                &__CMUX_TRACE_SITE,
                $crate::TraceArg::trace_arg($arg0),
                $crate::TraceArg::trace_arg($arg1),
            )
        } else {
            $crate::ScopeGuard::OFF
        }
    }};
}

/// Records an instant (I) with up to two numbers (Chrome's `TRACE_EVENT_INSTANT*`).
#[macro_export]
macro_rules! trace_instant {
    ($cat:ident, $name:literal $(,)?) => {
        $crate::__trace_emit!($cat, $name, Instant, 0, 0u64, 0u64)
    };
    ($cat:ident, $name:literal, $arg0:expr $(,)?) => {
        $crate::__trace_emit!($cat, $name, Instant, 0, $arg0, 0u64)
    };
    ($cat:ident, $name:literal, $arg0:expr, $arg1:expr $(,)?) => {
        $crate::__trace_emit!($cat, $name, Instant, 0, $arg0, $arg1)
    };
}

/// Begins an async slice (b) keyed by `id`, which may end on any thread with [`trace_async_end!`](crate::trace_async_end)
/// under the same name and id (Chrome's `TRACE_EVENT_NESTABLE_ASYNC_BEGIN1`). `arg0` is optional.
#[macro_export]
macro_rules! trace_async_begin {
    ($cat:ident, $name:literal, $id:expr $(,)?) => {
        $crate::__trace_emit!($cat, $name, AsyncBegin, $crate::FLAG_ID, 0u64, $id)
    };
    ($cat:ident, $name:literal, $id:expr, $arg0:expr $(,)?) => {
        $crate::__trace_emit!($cat, $name, AsyncBegin, $crate::FLAG_ID, $arg0, $id)
    };
}

/// Ends the async slice (e) named `name` with `id`, with an optional result number in `arg0`.
#[macro_export]
macro_rules! trace_async_end {
    ($cat:ident, $name:literal, $id:expr $(,)?) => {
        $crate::__trace_emit!($cat, $name, AsyncEnd, $crate::FLAG_ID, 0u64, $id)
    };
    ($cat:ident, $name:literal, $id:expr, $arg0:expr $(,)?) => {
        $crate::__trace_emit!($cat, $name, AsyncEnd, $crate::FLAG_ID, $arg0, $id)
    };
}

/// Records that flow `flow` leaves this point (s; Perfetto's `Flow::ProcessScoped`). `arg0` is
/// optional.
#[macro_export]
macro_rules! trace_flow_out {
    ($cat:ident, $name:literal, $flow:expr $(,)?) => {
        $crate::__trace_emit!($cat, $name, FlowOut, 0, 0u64, $flow)
    };
    ($cat:ident, $name:literal, $flow:expr, $arg0:expr $(,)?) => {
        $crate::__trace_emit!($cat, $name, FlowOut, 0, $arg0, $flow)
    };
}

/// Records that flow `flow` arrives at this point (f; Perfetto's `TerminatingFlow`). `arg0` is
/// optional.
#[macro_export]
macro_rules! trace_flow_in {
    ($cat:ident, $name:literal, $flow:expr $(,)?) => {
        $crate::__trace_emit!($cat, $name, FlowIn, 0, 0u64, $flow)
    };
    ($cat:ident, $name:literal, $flow:expr, $arg0:expr $(,)?) => {
        $crate::__trace_emit!($cat, $name, FlowIn, 0, $arg0, $flow)
    };
}

/// Records a counter's `value` (C; Chrome's `TRACE_COUNTER1`), on the optional track `track`.
#[macro_export]
macro_rules! trace_counter {
    ($cat:ident, $name:literal, $value:expr $(,)?) => {
        $crate::__trace_emit!($cat, $name, Counter, 0, $value, 0u64)
    };
    ($cat:ident, $name:literal, $value:expr, $track:expr $(,)?) => {
        $crate::__trace_emit!($cat, $name, Counter, $crate::FLAG_ID, $value, $track)
    };
}
