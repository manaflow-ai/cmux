//! What a terminal holds in memory, as libghostty-vt counts it
//! (`GhosttyTerminalMemoryUsage`, `GHOSTTY_TERMINAL_DATA_MEMORY_USAGE`).

use super::*;

/// Memory one screen of a terminal holds (one `primary_` or `alternate_` set
/// of `GhosttyTerminalMemoryUsage`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ScreenMemory {
    /// Pages, compressed ones included.
    pub pages: u64,
    /// Address space reserved for the pages; at least `resident_bytes`.
    pub virtual_bytes: u64,
    /// Physical memory of the pages; a compressed page counts its compressed
    /// size. The figure to budget against.
    pub resident_bytes: u64,
    pub compressed_pages: u64,
    /// Compressed page data, already part of `resident_bytes`.
    pub compressed_bytes: u64,
    /// Kitty graphics image data, not part of `resident_bytes`.
    pub image_bytes: u64,
}

/// Memory a terminal holds, per screen. The primary screen holds the
/// scrollback; the alternate one is all zero until a program first uses it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TerminalMemoryUsage {
    /// Whether compressing scrollback can free memory on this platform.
    pub compression_supported: bool,
    pub primary: ScreenMemory,
    pub alternate: ScreenMemory,
}

impl Terminal {
    /// Resident bytes of the primary screen's pages (screen and scrollback),
    /// `None` when libghostty-vt cannot report it.
    pub fn primary_resident_bytes(&self) -> Option<u64> {
        self.memory_usage().ok().map(|usage| usage.primary.resident_bytes)
    }

    /// Pages and images of both screens.
    pub fn memory_usage(&self) -> Result<TerminalMemoryUsage> {
        // SAFETY: an all-zero GhosttyTerminalMemoryUsage is a valid value of
        // the plain C struct; `size` is then set to the struct size the
        // getter requires.
        let mut usage: sys::GhosttyTerminalMemoryUsage = unsafe { std::mem::zeroed() };
        usage.size = size_of::<sys::GhosttyTerminalMemoryUsage>();
        // SAFETY: `self.raw` is this Terminal's live handle; MEMORY_USAGE writes a
        // GhosttyTerminalMemoryUsage whose `size` is set above.
        check(unsafe {
            sys::ghostty_terminal_get(
                self.raw,
                sys::GHOSTTY_TERMINAL_DATA_MEMORY_USAGE,
                (&mut usage as *mut sys::GhosttyTerminalMemoryUsage).cast(),
            )
        })?;
        Ok(TerminalMemoryUsage {
            compression_supported: usage.compression_supported,
            primary: ScreenMemory {
                pages: usage.primary_pages,
                virtual_bytes: usage.primary_virtual_bytes,
                resident_bytes: usage.primary_resident_bytes,
                compressed_pages: usage.primary_compressed_pages,
                compressed_bytes: usage.primary_compressed_bytes,
                image_bytes: usage.primary_image_bytes,
            },
            alternate: ScreenMemory {
                pages: usage.alternate_pages,
                virtual_bytes: usage.alternate_virtual_bytes,
                resident_bytes: usage.alternate_resident_bytes,
                compressed_pages: usage.alternate_compressed_pages,
                compressed_bytes: usage.alternate_compressed_bytes,
                image_bytes: usage.alternate_image_bytes,
            },
        })
    }
}
