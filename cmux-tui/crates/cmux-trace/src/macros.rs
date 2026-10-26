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
//! literal that starts with that category's name and a dot ([`crate::category::NAMES`]), checked at
//! compile time: the upload filter drops records by category, so a `key.*` name is always a key
//! record. Arguments are numbers ([`TraceArg`]) and are evaluated only while the category records.
//!
//! A category that is off costs one relaxed load and one branch ([`crate::enabled`]), as Chrome's
//! `category_group_enabled` read does; a [`trace_scope!`](crate::trace_scope) that is off returns a
//! guard whose drop the optimizer folds away. `tests/macros.rs` compiles a call site of each macro
//! (`tests/fixtures/off_path.rs`) with `-C opt-level=3` and checks that in its LLVM IR.
//!
//! [`trace_scope!`](crate::trace_scope) also keeps the thread's innermost open scopes on a fixed
//! stack ([`scope_stack`]), for the panic lines (task 082) and the crash-key page (task 098).

use std::cell::Cell;
use std::marker::PhantomData;

use crate::Phase;
use crate::ring::Record;
use crate::tracer::{InternedName, RingId};

/// Declares the macros' category idents (`categories::daemon`) and [`CATEGORY_NAMES`] from one list.
macro_rules! category_table {
    ($($name:ident: $mask:ident),* $(,)?) => {
        /// The categories by their lower-case names, for the macros' first argument.
        #[doc(hidden)]
        #[allow(non_upper_case_globals)]
        pub mod categories {
            $(pub const $name: u64 = crate::category::$mask;)*
        }

        /// Each category's name, indexed by its bit ([`crate::category::NAMES`]).
        pub const CATEGORY_NAMES: [&str; [$(stringify!($name)),*].len()] = {
            let mut names = [""; [$(stringify!($name)),*].len()];
            $(names[crate::category::$mask.trailing_zeros() as usize] = stringify!($name);)*
            names
        };
    };
}

category_table! {
    action: ACTION,
    key: KEY,
    switch: SWITCH,
    create: CREATE,
    cef: CEF,
    launch: LAUNCH,
    daemon: DAEMON,
    hang: HANG,
    crash: CRASH,
    motion: MOTION,
    frame: FRAME,
    stall: STALL,
    task: TASK,
    burst: BURST,
    input: INPUT,
    webview: WEBVIEW,
    remote: REMOTE,
    control: CONTROL,
    ghostty: GHOSTTY,
    resize: RESIZE,
    webui: WEBUI,
    log: LOG,
}

// Every bit below the table's length names a category.
const _: () = {
    let mut bit = 0;
    while bit < CATEGORY_NAMES.len() {
        assert!(!CATEGORY_NAMES[bit].is_empty(), "two categories share a bit");
        bit += 1;
    }
};

/// Whether `text` is `category`, a dot, then at least one byte.
pub(crate) const fn has_category_prefix(text: &str, category: &str) -> bool {
    let (text, category) = (text.as_bytes(), category.as_bytes());
    if text.len() <= category.len() + 1 || text[category.len()] != b'.' {
        return false;
    }
    let mut index = 0;
    while index < category.len() {
        if text[index] != category[index] {
            return false;
        }
        index += 1;
    }
    true
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
    /// in the macros' `static`: a catalog text takes its fixed id, and a text that does not start
    /// with the category's name and a dot, or is longer than a name entry holds, does not compile.
    pub const fn new(category: u64, text: &'static str) -> TraceSite {
        assert!(category.count_ones() == 1, "a trace point has exactly one category");
        assert!(text.len() <= crate::layout::NAME_TEXT_BYTES, "a trace name is at most 55 bytes");
        let bit = category.trailing_zeros() as u8;
        assert!(
            has_category_prefix(text, CATEGORY_NAMES[bit as usize]),
            "a trace name starts with its category's name and a dot"
        );
        TraceSite {
            category,
            catalog_id: crate::names::catalog_id(text),
            text,
            interned: InternedName::new(text, bit),
        }
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
        self.write(phase, flags, arg0, arg1, None);
    }

    /// Writes one record now, with `only_in` only into that ring. The ring it went into.
    fn write(
        &self,
        phase: Phase,
        flags: u8,
        arg0: u64,
        arg1: u64,
        only_in: Option<RingId>,
    ) -> Option<RingId> {
        let record = Record {
            t_ns: crate::clock::now_ns(),
            name: self.catalog_id,
            phase,
            flags,
            arg0,
            arg1,
        };
        crate::write_process(record, (self.catalog_id == 0).then_some(&self.interned), only_in)
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

/// The innermost open scopes a [`ScopeStack`] names (outer ones are counted in
/// [`ScopeStack::depth`]).
pub const SCOPE_STACK_DEPTH: usize = 16;

/// The depths a thread's stack holds: a scope at depth `d` takes slot `d`, with the push that put
/// it there, so a guard knows whether its scope is still on the stack. A scope opened deeper than
/// the last slot is not held and leaves the stack alone (a thread that deep is a runaway
/// recursion; the stack names the scopes up to it).
pub const SCOPE_SLOTS: usize = 64;

/// What a slot holds: a scope and the thread's push count when it went there.
type Slot = (Option<&'static TraceSite>, u64);

/// Where a scope went on its thread's stack: its depth and its push.
#[derive(Clone, Copy, Debug)]
struct ScopePlace {
    index: u32,
    push: u64,
}

/// A thread's open scopes.
struct Scopes {
    slots: [Cell<Slot>; SCOPE_SLOTS],
    depth: Cell<u32>,
    pushed: Cell<u64>,
}

impl Scopes {
    /// Puts `site` on top of the stack; None when the stack is full.
    fn push(&self, site: &'static TraceSite) -> Option<ScopePlace> {
        let index = self.depth.get();
        let slot = self.slots.get(index as usize)?;
        let push = self.pushed.get().wrapping_add(1);
        slot.set((Some(site), push));
        self.pushed.set(push);
        self.depth.set(index + 1);
        Some(ScopePlace { index, push })
    }

    /// Takes the scope at `place` and the ones above it off the stack, when it is still there: a
    /// scope dropped out of order took it off already, and another scope may hold its depth now.
    fn pop(&self, place: ScopePlace) {
        let index = place.index as usize;
        if place.index < self.depth.get() && self.slots[index].get().1 == place.push {
            self.depth.set(place.index);
        }
    }
}

thread_local! {
    static SCOPES: Scopes = const {
        Scopes {
            slots: [const { Cell::new((None, 0)) }; SCOPE_SLOTS],
            depth: Cell::new(0),
            pushed: Cell::new(0),
        }
    };
}

/// A scope whose category was on when it opened.
struct OpenScope {
    site: &'static TraceSite,
    /// The ring its begin went into; None when the begin was not written.
    ring: Option<RingId>,
    /// None when the thread's TLS was already destroyed or its stack was full.
    place: Option<ScopePlace>,
    end: (u64, u64),
}

impl OpenScope {
    /// Chrome's `ScopedTracer` writes its end only while its category is still on; here the end
    /// goes only into the ring the begin went into, so a `trace.start` or `trace.stop` inside the
    /// scope leaves that begin open rather than an end with no begin in the other ring.
    #[inline(never)]
    fn close(&self) {
        if let Some(ring) = self.ring {
            self.site.write(Phase::End, 0, self.end.0, self.end.1, Some(ring));
        }
        if let Some(place) = self.place {
            let _ = SCOPES.try_with(|scopes| scopes.pop(place));
        }
    }
}

/// An open [`trace_scope!`](crate::trace_scope): writes the slice's end (E) on the thread that
/// opened it when dropped, like Chrome's `ScopedTracer`. Not `Send`: a same-thread slice ends on
/// its own thread.
#[must_use = "the scope ends when this guard drops: bind it with `let _scope = trace_scope!(..)`"]
pub struct ScopeGuard {
    open: Option<OpenScope>,
    not_send: PhantomData<*const ()>,
}

impl ScopeGuard {
    /// The guard of a scope whose category was off when it opened: its drop writes nothing.
    #[doc(hidden)]
    pub const OFF: ScopeGuard = ScopeGuard { open: None, not_send: PhantomData };

    /// Writes the slice's begin (B) and pushes it on the thread's scope stack. The macro calls it
    /// only after [`crate::enabled`] said yes.
    #[doc(hidden)]
    #[inline(never)]
    pub fn begin(site: &'static TraceSite, arg0: u64, arg1: u64) -> ScopeGuard {
        let ring = site.write(Phase::Begin, 0, arg0, arg1, None);
        let place = SCOPES.try_with(|scopes| scopes.push(site)).ok().flatten();
        ScopeGuard {
            open: Some(OpenScope { site, ring, place, end: (0, 0) }),
            not_send: PhantomData,
        }
    }

    /// The numbers the slice's end record carries (its result, as Swift's `end(_:arg0:arg1:)`).
    pub fn set_end_args(&mut self, arg0: impl TraceArg, arg1: impl TraceArg) {
        if let Some(open) = &mut self.open {
            open.end = (arg0.trace_arg(), arg1.trace_arg());
        }
    }
}

impl Drop for ScopeGuard {
    #[inline]
    fn drop(&mut self) {
        if let Some(open) = &self.open {
            open.close();
        }
    }
}

/// A copy of a thread's open scopes, taken with no allocation.
#[derive(Clone, Copy, Debug)]
pub struct ScopeStack {
    /// The innermost [`SCOPE_STACK_DEPTH`] held scopes, innermost first.
    sites: [Option<&'static TraceSite>; SCOPE_STACK_DEPTH],
    depth: u32,
}

impl ScopeStack {
    /// How many scopes are open, those past [`SCOPE_STACK_DEPTH`] too, up to [`SCOPE_SLOTS`].
    pub fn depth(&self) -> u32 {
        self.depth
    }

    /// The named scopes, innermost first: the innermost [`SCOPE_STACK_DEPTH`] of the
    /// [`SCOPE_SLOTS`] the stack holds.
    pub fn sites(&self) -> impl Iterator<Item = &'static TraceSite> + '_ {
        self.sites.iter().filter_map(|site| *site)
    }

    /// The named scopes' names, innermost first.
    pub fn names(&self) -> impl Iterator<Item = &'static str> + '_ {
        self.sites().map(TraceSite::text)
    }
}

/// The calling thread's open [`trace_scope!`](crate::trace_scope)s. Empty once the thread's TLS is
/// gone.
pub fn scope_stack() -> ScopeStack {
    SCOPES
        .try_with(|scopes| {
            let depth = scopes.depth.get();
            let mut sites = [None; SCOPE_STACK_DEPTH];
            for (site, slot) in sites.iter_mut().zip((0..depth as usize).rev()) {
                *site = scopes.slots[slot].get().0;
            }
            ScopeStack { sites, depth }
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
///
/// and so does a name outside the catalog, so a `key` name never files as a daemon record:
///
/// ```compile_fail
/// let _scope = cmux_trace::trace_scope!(daemon, "key.secret");
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
///
/// ```compile_fail
/// cmux_trace::trace_instant!(daemon, "key.secret");
/// ```
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

/// Begins an async slice (b) keyed by `id`, which may end on any thread with
/// [`trace_async_end!`](crate::trace_async_end) under the same name and id (Chrome's
/// `TRACE_EVENT_NESTABLE_ASYNC_BEGIN1`). `arg0` is optional.
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
