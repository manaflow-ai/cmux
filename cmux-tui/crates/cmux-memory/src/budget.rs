//! The daemon's memory budget, sized from installed RAM.
//!
//! Chrome sizes its limits from physical memory rather than fixed constants
//! (`base::SysInfo::AmountOfPhysicalMemory` in
//! `content/browser/renderer_host/render_process_host_impl.cc`,
//! `GetPlatformMaxRendererProcessCount`). The cmux daemon does the same
//! here: one table, one place for every Rust memory cap (the MQ-RUST-CAPS queue in
//! plans/cmux-next/chrome-parity/p07-memory.md). The per-terminal constants
//! below are the only literals: cmux-tui-core's `DEFAULT_SCROLLBACK_LIMIT_BYTES`,
//! ghostty-vt's `MAX_KITTY_IMAGE_BYTES` and cmux-holder's `RING_BYTES` and
//! `LINK_QUEUE_BYTES` are defined as them. The totals are process-wide: read
//! [`DaemonBudget::for_host`] once per process, never per terminal.
//!
//! | Field | Formula (M = installed bytes) | 8 GB | 16 GB | 32 GB | 64 GB | 128 GB |
//! | --- | --- | --- | --- | --- | --- | --- |
//! | scrollback_total | clamp(M/64, 64 MiB, 1 GiB) | 128 MiB | 256 MiB | 512 MiB | 1 GiB | 1 GiB |
//! | kitty_total | clamp(M/128, 64 MiB, 512 MiB) | 64 MiB | 128 MiB | 256 MiB | 512 MiB | 512 MiB |
//! | holder_ring_bytes | clamp(M/16384, 512 KiB, 1 MiB) | 512 KiB | 1 MiB | 1 MiB | 1 MiB | 1 MiB |
//! | cold_scrollback_after | 10 min | | | | | |
//! | scrollback_per_terminal | 10 MB | | | | | |
//! | kitty_image_bytes_per_terminal | 10 MB | | | | | |
//!
//! At 16 GB every value equals the fixed cap the daemon used before
//! (256 MiB scrollback total, 128 MiB kitty total, 1 MiB holder ring), and a
//! host whose RAM cannot be read gets the 16 GB row.

use std::time::Duration;

const KIB: u64 = 1024;
const MIB: u64 = 1024 * KIB;
const GIB: u64 = 1024 * MIB;

/// Most scrollback backing storage one terminal keeps by default, in bytes
/// (about 15,000 rows at 80 columns). Ghostty's own default is 50 MB, but the
/// daemon keeps every terminal's scrollback resident: ten printing terminals
/// grew the daemon by 500 MB in a 24 h soak (cx-urd.4). The Ghostty config's
/// `scrollback-limit-bytes` raises it.
pub const SCROLLBACK_BYTES_PER_TERMINAL: usize = 10_000_000;

/// Most kitty image bytes one terminal stores, and the largest single image
/// the decoder accepts (ghostty-vt's `MAX_KITTY_IMAGE_BYTES` is this value).
pub const KITTY_IMAGE_BYTES_PER_TERMINAL: usize = 10_000_000;

/// The largest holder output ring per terminal (cmux-holder's `RING_BYTES` is
/// this value). [`DaemonBudget::holder_ring_bytes`] never exceeds it.
pub const HOLDER_RING_BYTES_MAX: usize = 1 << 20;

/// Output the holder queues on its daemon link before it stops making DATA
/// frames; the rest waits in the rings (cmux-holder's `LINK_QUEUE_BYTES`).
pub const HOLDER_LINK_QUEUE_BYTES: usize = 1 << 20;

/// The smallest holder ring: still twice the holder's 256 KiB unsent
/// high-water mark, so an attached daemon never loses an unsent byte.
const HOLDER_RING_BYTES_MIN: usize = 512 << 10;

/// RAM assumed when the host's cannot be read: the row whose values equal
/// the daemon's old fixed caps.
const FALLBACK_INSTALLED_BYTES: u64 = 16 * GIB;

/// How long a terminal with no viewer and no output waits before its
/// scrollback counts as cold.
const COLD_SCROLLBACK_AFTER: Duration = Duration::from_secs(10 * 60);

/// The daemon's memory limits for one machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DaemonBudget {
    /// Scrollback RAM across all terminals, in bytes: the default of
    /// `terminal.scrollback.maxTotalMemoryBytes`.
    pub scrollback_total: u64,
    /// A terminal with no viewer and no output for this long is cold.
    pub cold_scrollback_after: Duration,
    /// Kitty image bytes across all terminals.
    pub kitty_total: u64,
    /// Output ring per terminal in the holder, in bytes.
    pub holder_ring_bytes: usize,
    /// Default scrollback limit of one terminal, in bytes.
    pub scrollback_per_terminal: usize,
    /// Kitty image storage limit of one terminal, in bytes.
    pub kitty_image_bytes_per_terminal: usize,
}

impl DaemonBudget {
    /// The budget for a machine with `installed_bytes` of RAM
    /// (`hw.memsize` on macOS). Pure: the table test pins every row.
    pub fn for_memory(installed_bytes: u64) -> Self {
        let ring = (installed_bytes / (16 * KIB))
            .clamp(HOLDER_RING_BYTES_MIN as u64, HOLDER_RING_BYTES_MAX as u64);
        Self {
            scrollback_total: (installed_bytes / 64).clamp(64 * MIB, GIB),
            cold_scrollback_after: COLD_SCROLLBACK_AFTER,
            kitty_total: (installed_bytes / 128).clamp(64 * MIB, 512 * MIB),
            // At most HOLDER_RING_BYTES_MAX, so it fits a usize everywhere.
            holder_ring_bytes: usize::try_from(ring).unwrap_or(HOLDER_RING_BYTES_MAX),
            scrollback_per_terminal: SCROLLBACK_BYTES_PER_TERMINAL,
            kitty_image_bytes_per_terminal: KITTY_IMAGE_BYTES_PER_TERMINAL,
        }
    }

    /// The budget for this machine's installed RAM, or the 16 GB row when it
    /// cannot be read.
    pub fn for_host() -> Self {
        Self::for_memory(installed_memory_bytes().unwrap_or(FALLBACK_INSTALLED_BYTES))
    }
}

impl Default for DaemonBudget {
    /// The 16 GB row: the daemon's caps before they came from RAM.
    fn default() -> Self {
        Self::for_memory(FALLBACK_INSTALLED_BYTES)
    }
}

/// Installed RAM in bytes: macOS `hw.memsize`.
#[cfg(target_os = "macos")]
pub fn installed_memory_bytes() -> Option<u64> {
    let mut bytes = 0u64;
    let mut len = size_of::<u64>();
    // SAFETY: a NUL-terminated name and a writable u64 with its length; no
    // new value is written.
    let rc = unsafe {
        libc::sysctlbyname(
            c"hw.memsize".as_ptr(),
            (&raw mut bytes).cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    (rc == 0 && bytes > 0).then_some(bytes)
}

/// Installed RAM in bytes: physical pages times the page size.
#[cfg(all(unix, not(target_os = "macos")))]
pub fn installed_memory_bytes() -> Option<u64> {
    // SAFETY: sysconf only reads system configuration.
    let (pages, size) =
        unsafe { (libc::sysconf(libc::_SC_PHYS_PAGES), libc::sysconf(libc::_SC_PAGESIZE)) };
    let bytes = u64::try_from(pages).ok()?.checked_mul(u64::try_from(size).ok()?)?;
    (bytes > 0).then_some(bytes)
}

/// Installed RAM is not read on this platform; callers use the 16 GB row.
#[cfg(not(unix))]
pub fn installed_memory_bytes() -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// (GB, scrollback_total, kitty_total, holder_ring_bytes) as literals.
    const TABLE: [(u64, u64, u64, usize); 6] = [
        (8, 134_217_728, 67_108_864, 524_288),
        (16, 268_435_456, 134_217_728, 1_048_576),
        (24, 402_653_184, 201_326_592, 1_048_576),
        (32, 536_870_912, 268_435_456, 1_048_576),
        (64, 1_073_741_824, 536_870_912, 1_048_576),
        (128, 1_073_741_824, 536_870_912, 1_048_576),
    ];

    #[test]
    fn budget_table_at_8_16_24_32_64_128_gb() {
        for (gb, scrollback_total, kitty_total, holder_ring_bytes) in TABLE {
            let budget = DaemonBudget::for_memory(gb << 30);
            assert_eq!(
                budget,
                DaemonBudget {
                    scrollback_total,
                    cold_scrollback_after: Duration::from_secs(600),
                    kitty_total,
                    holder_ring_bytes,
                    scrollback_per_terminal: 10_000_000,
                    kitty_image_bytes_per_terminal: 10_000_000,
                },
                "{gb} GB"
            );
        }
    }

    /// The per-terminal constants ghostty-vt and cmux-holder are defined as.
    #[test]
    fn budget_per_terminal_constants_keep_their_values() {
        assert_eq!(SCROLLBACK_BYTES_PER_TERMINAL, 10_000_000);
        assert_eq!(KITTY_IMAGE_BYTES_PER_TERMINAL, 10_000_000);
        assert_eq!(HOLDER_RING_BYTES_MAX, 1_048_576);
        assert_eq!(HOLDER_LINK_QUEUE_BYTES, 1_048_576);
    }

    #[test]
    fn budget_16_gb_row_keeps_the_old_fixed_caps() {
        let budget = DaemonBudget::default();
        assert_eq!(budget, DaemonBudget::for_memory(16 << 30));
        assert_eq!(budget.scrollback_total, 256 * 1024 * 1024);
        assert_eq!(budget.kitty_total, 128 * 1024 * 1024);
        assert_eq!(budget.holder_ring_bytes, 1 << 20);
    }

    #[test]
    fn budget_floors_hold_on_tiny_and_unknown_machines() {
        let budget = DaemonBudget::for_memory(0);
        assert_eq!(budget.scrollback_total, 64 * MIB);
        assert_eq!(budget.kitty_total, 64 * MIB);
        assert_eq!(budget.holder_ring_bytes, 512 * 1024);
        let huge = DaemonBudget::for_memory(u64::MAX);
        assert_eq!(huge.scrollback_total, GIB);
        assert_eq!(huge.holder_ring_bytes, HOLDER_RING_BYTES_MAX);
    }

    #[test]
    fn budget_per_terminal_caps_fit_under_the_totals() {
        for gb in [0, 1, 4, 8, 16, 24, 32, 64, 128, 1024] {
            let budget = DaemonBudget::for_memory(gb << 30);
            assert!(budget.scrollback_per_terminal as u64 <= budget.scrollback_total, "{gb} GB");
            assert!(budget.kitty_image_bytes_per_terminal as u64 <= budget.kitty_total, "{gb} GB");
        }
    }

    #[cfg(unix)]
    #[test]
    fn budget_for_host_reads_installed_memory() {
        let installed = installed_memory_bytes().expect("unix hosts report installed RAM");
        assert_eq!(DaemonBudget::for_host(), DaemonBudget::for_memory(installed));
    }
}
