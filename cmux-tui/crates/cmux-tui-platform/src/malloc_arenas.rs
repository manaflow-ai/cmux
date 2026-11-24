//! A cap on glibc's malloc arenas, set once at process start (CMUX-571
//! infinite items).
//!
//! glibc gives each thread that allocates under contention its own arena, up to
//! eight per core, and an arena keeps the pages of memory it freed. A daemon
//! with dozens of threads per workspace ends up holding most of its resident
//! memory as freed blocks spread across arenas: dhat at 300 workspaces read a
//! 15 MB live heap where PSS read about 120 MB (manaflow-ai/cmux#43824). With
//! `MALLOC_ARENA_MAX=2` the infinite-items harness read 4.81x of empty at 1,000
//! items instead of 6.90x, and the daemon grew 24 MB a simulated day instead of
//! 130 (run 43730217404).
//!
//! Only glibc has arenas: the musl builds and macOS compile this to nothing.
//! A `MALLOC_ARENA_MAX` or a `glibc.malloc.arena_max` tunable in the
//! environment wins over the cap, so a measurement can still set its own.

/// Arenas for the cmux-tui daemon and acpmux: many threads, few of them busy at
/// once (one per client request or agent stream). The slim terminal host
/// (`cmux-tui-host`) keeps glibc's default: a cap of one there measured slower
/// terminal output in #43851.
pub const DAEMON_ARENAS: i32 = 2;

/// Arenas for acpmux. Its peer links, notice shards and client feeds allocate on
/// many threads at once, so two arenas serialize them on the arena lock: on the
/// coord-sim fan-in ramp at 2,000 attached sessions, fan-in p95 read 6.8 ms with
/// two and 1.28 ms with sixteen on the same head (cmux#49864), resident memory
/// 663 vs 792 MB on that pair and 823 vs 798 MB on another. Sixteen bounds what
/// freed pages the arenas can keep, well under glibc's eight per core.
pub const ACPMUX_ARENAS: i32 = 16;

/// Caps glibc's arenas at `max` unless the environment names its own limit.
///
/// # Safety
/// Call it first in `main`, before any thread starts: arenas a thread already
/// attached to stay, and the environment is read without a lock.
pub unsafe fn cap(max: i32) {
    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    if env_leaves_default(
        std::env::var_os("MALLOC_ARENA_MAX").as_deref(),
        std::env::var_os("GLIBC_TUNABLES").as_deref(),
    ) {
        // SAFETY: no pointer is passed; the caller runs it before any thread.
        unsafe { libc::mallopt(libc::M_ARENA_MAX, max) };
    }
    #[cfg(not(all(target_os = "linux", target_env = "gnu")))]
    let _ = max;
}

/// Whether neither variable sets glibc's arena limit itself.
#[cfg_attr(not(all(target_os = "linux", target_env = "gnu")), allow(dead_code))]
fn env_leaves_default(
    arena_max: Option<&std::ffi::OsStr>,
    tunables: Option<&std::ffi::OsStr>,
) -> bool {
    arena_max.is_none()
        && !tunables.is_some_and(|t| t.to_string_lossy().contains("glibc.malloc.arena_max"))
}

#[cfg(test)]
mod tests {
    use super::env_leaves_default;
    use std::ffi::OsStr;

    #[test]
    fn an_environment_limit_wins_over_the_cap() {
        assert!(env_leaves_default(None, None));
        assert!(env_leaves_default(None, Some(OsStr::new("glibc.malloc.tcache_count=0"))));
        assert!(!env_leaves_default(Some(OsStr::new("4")), None));
        assert!(!env_leaves_default(None, Some(OsStr::new("glibc.malloc.arena_max=8"))));
        assert!(!env_leaves_default(
            None,
            Some(OsStr::new("glibc.malloc.tcache_count=0:glibc.malloc.arena_max=1"))
        ));
    }
}
