//! The Mac's memory pressure: an event from libdispatch when the level
//! changes, and the level that holds now. Event-driven; no thread or timer
//! of our own. Users: the spare terminal host
//! (`terminal_work/standby_host.rs`) and the line of the respawn gate
//! (`terminal_respawn/line_pause.rs`).

use std::ffi::c_void;

#[allow(non_camel_case_types)]
type dispatch_object_t = *mut c_void;
const DISPATCH_MEMORYPRESSURE_NORMAL: usize = 0x01;
const DISPATCH_MEMORYPRESSURE_WARN: usize = 0x02;
const DISPATCH_MEMORYPRESSURE_CRITICAL: usize = 0x04;

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
    fn dispatch_source_set_event_handler_f(
        source: dispatch_object_t,
        handler: extern "C" fn(*mut c_void),
    );
    fn dispatch_resume(object: dispatch_object_t);
    fn dispatch_source_get_data(source: dispatch_object_t) -> usize;
}

/// The source, for reading the pressure level in the handler.
struct Watch {
    on_change: Box<dyn Fn(bool) + Send + Sync>,
    source: dispatch_object_t,
}

extern "C" fn on_pressure(context: *mut c_void) {
    // SAFETY: the context is the leaked `Watch` set in `watch`, alive for
    // the source's lifetime (the process); its source is that source.
    let watch = unsafe { &*(context as *const Watch) };
    let level = unsafe { dispatch_source_get_data(watch.source) };
    (watch.on_change)(level & DISPATCH_MEMORYPRESSURE_NORMAL == 0);
}

/// Calls `on_change` for the rest of the process each time the memory
/// pressure level changes, with whether the event says warning or critical.
/// It runs in a C callback on a libdispatch queue: a panic there aborts the
/// daemon, so it must not unwrap a poisoned lock. A caller that has to be
/// right about the level reads it in `on_change` ([`above_normal_now`]): an
/// event can be late, and the source reports no level at its start.
pub(in crate::mux) fn watch(on_change: impl Fn(bool) + Send + Sync + 'static) {
    // SAFETY: plain libdispatch calls on a source this function creates;
    // the context outlives it (leaked, one per caller).
    unsafe {
        let queue = dispatch_get_global_queue(0, 0);
        let source = dispatch_source_create(
            &raw const _dispatch_source_type_memorypressure,
            0,
            DISPATCH_MEMORYPRESSURE_NORMAL
                | DISPATCH_MEMORYPRESSURE_WARN
                | DISPATCH_MEMORYPRESSURE_CRITICAL,
            queue,
        );
        if source.is_null() {
            return;
        }
        let watch = Watch { on_change: Box::new(on_change), source };
        dispatch_set_context(source, Box::into_raw(Box::new(watch)).cast());
        dispatch_source_set_event_handler_f(source, on_pressure);
        dispatch_resume(source);
    }
}

/// Whether the kernel's memory pressure level is above normal now
/// (`kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4
/// critical). None when the level cannot be read.
pub(in crate::mux) fn above_normal_now() -> Option<bool> {
    let mut level: libc::c_int = 0;
    let mut size = size_of::<libc::c_int>();
    // SAFETY: the out buffer is a c_int and `size` is its size; the name is NUL-terminated.
    let read = unsafe {
        libc::sysctlbyname(
            c"kern.memorystatus_vm_pressure_level".as_ptr(),
            (&raw mut level).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    (read == 0 && level > 0).then_some(level > 1)
}
