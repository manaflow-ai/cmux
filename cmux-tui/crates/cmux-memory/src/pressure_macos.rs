//! The macOS kernel pressure source: one libdispatch memory-pressure source
//! per process (Chrome's
//! `components/memory_pressure/system_memory_pressure_evaluator_mac.cc`).
//!
//! As in Chrome, the event's data is only a wakeup: coalesced events OR their
//! levels together (a WARN then NORMAL pair reads as warning), so each event
//! re-reads `kern.memorystatus_vm_pressure_level`. The level is also read
//! once at start, and the source votes it through its [`Voter`]; the
//! registry delivers only changes. No thread or timer of its own. The voter
//! lives in the source's context, so the vote is withdrawn when libdispatch
//! finalizes the source.

use std::ffi::{CStr, c_void};

use crate::{PressureLevel, Voter, WatchError};

#[allow(non_camel_case_types)]
type dispatch_object_t = *mut c_void;

const DISPATCH_MEMORYPRESSURE_NORMAL: usize = 0x01;
const DISPATCH_MEMORYPRESSURE_WARN: usize = 0x02;
const DISPATCH_MEMORYPRESSURE_CRITICAL: usize = 0x04;
/// `QOS_CLASS_UTILITY`: nobody waits on a pressure change.
const QOS_CLASS_UTILITY: isize = 0x11;

const PRESSURE_SYSCTL: &CStr = c"kern.memorystatus_vm_pressure_level";

unsafe extern "C" {
    static _dispatch_source_type_memorypressure: c_void;
    fn dispatch_get_global_queue(identifier: isize, flags: usize) -> dispatch_object_t;
    fn dispatch_source_create(
        kind: *const c_void,
        handle: usize,
        mask: usize,
        queue: dispatch_object_t,
    ) -> dispatch_object_t;
    fn dispatch_set_context(object: dispatch_object_t, context: *mut c_void);
    fn dispatch_set_finalizer_f(object: dispatch_object_t, finalizer: extern "C" fn(*mut c_void));
    fn dispatch_source_set_event_handler_f(
        source: dispatch_object_t,
        handler: extern "C" fn(*mut c_void),
    );
    fn dispatch_resume(object: dispatch_object_t);
    fn dispatch_source_cancel(source: dispatch_object_t);
    fn dispatch_release(object: dispatch_object_t);
    fn dispatch_source_get_data(source: dispatch_object_t) -> usize;
}

/// The kernel's level bits (`DISPATCH_MEMORYPRESSURE_*` and the sysctl share
/// them: 1 normal, 2 warn, 4 critical); the worst bit set wins.
fn level_from_bits(bits: usize) -> PressureLevel {
    if bits & DISPATCH_MEMORYPRESSURE_CRITICAL != 0 {
        PressureLevel::Critical
    } else if bits & DISPATCH_MEMORYPRESSURE_WARN != 0 {
        PressureLevel::Warning
    } else {
        PressureLevel::Normal
    }
}

/// The kernel's current level, or `None` when the sysctl cannot be read.
fn read_level() -> Option<PressureLevel> {
    let mut value: libc::c_int = 0;
    let mut size = size_of::<libc::c_int>();
    // SAFETY: the name is NUL-terminated and `value` is a writable c_int of
    // `size` bytes; no new value is set.
    let status = unsafe {
        libc::sysctlbyname(
            PRESSURE_SYSCTL.as_ptr(),
            (&raw mut value).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    (status == 0 && size == size_of::<libc::c_int>())
        .then(|| level_from_bits(usize::try_from(value).unwrap_or(0)))
}

/// The handler's context: owned by the source, freed by its finalizer.
struct Context {
    voter: Voter,
    source: dispatch_object_t,
}

extern "C" fn on_event(context: *mut c_void) {
    // SAFETY: the context is the `Context` set in `Watch::start`; libdispatch
    // frees it only in the finalizer, after the last handler returned.
    let context = unsafe { &*(context as *const Context) };
    let level = read_level().unwrap_or_else(|| {
        // SAFETY: `source` is this handler's own source, alive while it runs.
        level_from_bits(unsafe { dispatch_source_get_data(context.source) })
    });
    context.voter.set_level(level);
}

extern "C" fn finalize(context: *mut c_void) {
    // SAFETY: the finalizer runs once, after the source's last handler, on the
    // context `Watch::start` leaked into the source.
    drop(unsafe { Box::from_raw(context.cast::<Context>()) });
}

/// The running source; dropping it cancels and releases the source.
pub(crate) struct Watch {
    source: dispatch_object_t,
}

// SAFETY: the synchronization is libdispatch's own: a dispatch object is
// thread-safe and its cancel and release may run on any thread. `Watch` owns one
// reference and only its `Drop` touches the source; the handler's context is
// owned by the source and freed by its finalizer. Test:
// `pressure_macos::tests::a_watch_starts_on_one_thread_and_drops_on_another` (macOS).
unsafe impl Send for Watch {}
// SAFETY: `&Watch` reaches nothing: `Watch` has no `&self` method, so sharing it
// is sound whatever the source is. Test: as for `Send`.
unsafe impl Sync for Watch {}

impl Watch {
    pub(crate) fn start(voter: Voter) -> Result<Self, WatchError> {
        // The initial level, before any event (Chrome sets its first vote in
        // the evaluator's constructor).
        if let Some(level) = read_level() {
            voter.set_level(level);
        }
        // SAFETY: plain libdispatch calls on a source this function creates;
        // the context it hands the source lives until the source's finalizer.
        unsafe {
            let queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
            let source = dispatch_source_create(
                &raw const _dispatch_source_type_memorypressure,
                0,
                DISPATCH_MEMORYPRESSURE_NORMAL
                    | DISPATCH_MEMORYPRESSURE_WARN
                    | DISPATCH_MEMORYPRESSURE_CRITICAL,
                queue,
            );
            if source.is_null() {
                return Err(WatchError::Unsupported);
            }
            let context = Box::into_raw(Box::new(Context { voter, source }));
            dispatch_set_context(source, context.cast());
            dispatch_set_finalizer_f(source, finalize);
            dispatch_source_set_event_handler_f(source, on_event);
            dispatch_resume(source);
            Ok(Self { source })
        }
    }
}

impl Drop for Watch {
    fn drop(&mut self) {
        // SAFETY: the source this watch created and still owns one reference
        // to; cancel stops new handlers, release lets the finalizer run.
        unsafe {
            dispatch_source_cancel(self.source);
            dispatch_release(self.source);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_worst_level_bit_wins() {
        assert_eq!(level_from_bits(DISPATCH_MEMORYPRESSURE_NORMAL), PressureLevel::Normal);
        assert_eq!(level_from_bits(DISPATCH_MEMORYPRESSURE_WARN), PressureLevel::Warning);
        assert_eq!(
            level_from_bits(DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN),
            PressureLevel::Warning
        );
        assert_eq!(
            level_from_bits(DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL),
            PressureLevel::Critical
        );
        assert_eq!(level_from_bits(0), PressureLevel::Normal);
    }

    /// The `Send`/`Sync` impls of [`Watch`]: started on one thread, shared by
    /// reference with two others, dropped on a fourth.
    #[test]
    fn a_watch_starts_on_one_thread_and_drops_on_another() {
        let registry = crate::MemoryRegistry::new();
        let watch = std::thread::scope(|scope| {
            scope.spawn(|| registry.watch_system_pressure()).join().expect("start thread")
        })
        .expect("the macOS memory-pressure source starts");
        std::thread::scope(|scope| {
            for _ in 0..2 {
                scope.spawn(|| {
                    let _shared: &crate::PressureWatch = &watch;
                });
            }
        });
        std::thread::spawn(move || drop(watch)).join().expect("drop thread");
    }

    #[test]
    fn the_kernel_level_reads_at_start() {
        assert!(read_level().is_some(), "kern.memorystatus_vm_pressure_level reads on macOS");
    }

    #[test]
    fn a_source_starts_and_stops() {
        let registry = crate::MemoryRegistry::new();
        let watch = registry.watch_system_pressure().expect("the source starts");
        assert_eq!(registry.level(), read_level().unwrap());
        drop(watch);
    }
}
