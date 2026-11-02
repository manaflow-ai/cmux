//! The QoS of a connection's threads (TYPING FIX 2, F7): which threads carry the person's keys, and the test hook
//! that reads each thread's own QoS.

/// Test hook: each connection thread (`mux-conn` reader, `mux-control-dispatch`, `mux-line-out` writer) records its
/// own QoS before each line, request or reply, so a test reads it after that reply arrives (no timing).
#[cfg(test)]
pub(super) fn note_thread_qos(role: &'static str) {
    OBSERVED
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .insert(role, current_thread_qos());
}

#[cfg(not(test))]
#[inline(always)]
pub(super) fn note_thread_qos(_role: &'static str) {}

/// The QoS a connection thread last recorded (test hook).
#[cfg(test)]
pub(super) fn observed_thread_qos(role: &'static str) -> Option<u32> {
    OBSERVED.lock().unwrap_or_else(std::sync::PoisonError::into_inner).get(role).copied()
}

#[cfg(test)]
static OBSERVED: std::sync::LazyLock<
    std::sync::Mutex<std::collections::HashMap<&'static str, u32>>,
> = std::sync::LazyLock::new(Default::default);

/// This thread's QoS class (`qos_class_t` as u32); 0 off macOS.
#[cfg(test)]
pub(super) fn current_thread_qos() -> u32 {
    #[cfg(target_os = "macos")]
    {
        let mut qos = libc::qos_class_t::QOS_CLASS_UNSPECIFIED;
        let mut relative = 0;
        // SAFETY: valid out pointers for this thread's own QoS.
        unsafe { libc::pthread_get_qos_class_np(libc::pthread_self(), &mut qos, &mut relative) };
        qos as u32
    }
    #[cfg(not(target_os = "macos"))]
    {
        0
    }
}
