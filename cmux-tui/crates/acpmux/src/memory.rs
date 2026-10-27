//! acpmux's memory response: one [`MemoryRegistry`] per process, and its
//! kernel pressure source (`cmux-memory`, after Chrome's
//! `base/memory_coordinator/`). `host_pressure.rs` still only warns about the
//! host's budget; this is where acpmux gives memory back.
//!
//! The daemon's consumers are in `hub/memory_consumers.rs`, the TUI's in
//! `tui/run.rs`. Lossless ones (rebuilt on demand) empty at warning; lossy
//! ones (per-session state past its tail, the live model lists) at critical.
//! `daemon status` reports each consumer's bytes (`hub/views/memory.rs`).
//!
//! The kernel source runs only with the `memoryAcpmuxPressure` feature
//! (schemas/features/features.d/memoryAcpmuxPressure.json); without it nothing
//! votes, so no consumer hears a level.

use cmux_memory::{MemoryRegistry, PressureWatch, WatchError};
use std::sync::OnceLock;

/// The feature that starts the kernel pressure source.
pub const FEATURE: &str = "memoryAcpmuxPressure";

/// One process's registry and its kernel source, once started.
#[derive(Default)]
pub struct AcpmuxMemory {
    registry: MemoryRegistry,
    watch: OnceLock<Option<PressureWatch>>,
}

impl AcpmuxMemory {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn registry(&self) -> &MemoryRegistry {
        &self.registry
    }

    /// Whether the kernel source runs.
    pub fn watching(&self) -> bool {
        self.watch.get().is_some_and(Option::is_some)
    }

    /// Starts the kernel source when [`FEATURE`] is on in this process's
    /// feature lists; later calls do nothing. Whether it runs.
    pub fn watch_if_enabled(&self) -> bool {
        cmux_features::listed_in_env(FEATURE) && self.watch_system_pressure()
    }

    /// Starts the kernel source once; later calls do nothing. Where this
    /// process may not use it (no PSI, an unprivileged Linux before 6.5),
    /// nothing votes. Whether it runs.
    pub fn watch_system_pressure(&self) -> bool {
        self.watch
            .get_or_init(|| match self.registry.watch_system_pressure() {
                Ok(watch) => Some(watch),
                Err(WatchError::Unsupported | WatchError::NotPermitted(_)) => None,
                Err(error) => {
                    tracing::warn!("acpmux: {error}");
                    None
                }
            })
            .is_some()
    }
}

/// The bytes a string keeps on the heap.
pub(crate) fn string_bytes(s: &str) -> u64 {
    s.len() as u64
}

/// `count` values of `T` held inline in a collection.
pub(crate) fn inline_bytes<T>(count: usize) -> u64 {
    (count as u64).saturating_mul(std::mem::size_of::<T>() as u64)
}

/// This process's memory footprint in bytes: macOS `phys_footprint` (what
/// Activity Monitor shows), Linux resident pages. `None` where it cannot be read.
pub fn footprint_bytes() -> Option<u64> {
    imp::footprint_bytes()
}

#[cfg(target_os = "macos")]
mod imp {
    use std::os::raw::{c_int, c_void};

    /// `struct rusage_info_v4` from `<sys/resource.h>`, up to `phys_footprint`.
    #[repr(C)]
    struct RusageInfoV4 {
        uuid: [u8; 16],
        user_time: u64,
        system_time: u64,
        pkg_idle_wkups: u64,
        interrupt_wkups: u64,
        pageins: u64,
        wired_size: u64,
        resident_size: u64,
        phys_footprint: u64,
        /// proc_start_abstime through runnable_time: 27 more `uint64_t`.
        rest: [u64; 27],
    }

    const RUSAGE_INFO_V4: c_int = 4;

    unsafe extern "C" {
        fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *mut c_void) -> c_int;
    }

    pub(super) fn footprint_bytes() -> Option<u64> {
        let pid = c_int::try_from(std::process::id()).ok()?;
        let mut usage = std::mem::MaybeUninit::<RusageInfoV4>::zeroed();
        // SAFETY: `usage` is a writable buffer of sizeof(rusage_info_v4)
        // bytes, the size the V4 flavor writes.
        if unsafe { proc_pid_rusage(pid, RUSAGE_INFO_V4, usage.as_mut_ptr().cast()) } != 0 {
            return None;
        }
        // SAFETY: zero-initialized and then filled by the kernel; every field
        // is a plain integer.
        let usage = unsafe { usage.assume_init() };
        Some(usage.phys_footprint)
    }
}

#[cfg(target_os = "linux")]
mod imp {
    /// Resident pages from `/proc/self/statm` (a kernel table, not a disk read).
    pub(super) fn footprint_bytes() -> Option<u64> {
        let statm = std::fs::read_to_string("/proc/self/statm").ok()?;
        let pages: u64 = statm.split_whitespace().nth(1)?.parse().ok()?;
        // SAFETY: sysconf has no preconditions; it returns -1 on failure.
        let page = u64::try_from(unsafe { libc::sysconf(libc::_SC_PAGESIZE) }).ok()?;
        pages.checked_mul(page)
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod imp {
    pub(super) fn footprint_bytes() -> Option<u64> {
        None
    }
}
