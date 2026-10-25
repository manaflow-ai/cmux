//! Ring memory: the zeroed heap block a ring starts in, and the shared file mapping it moves to.
//!
//! A file mapping is never unmapped while the process lives ([`Mapping`] has no `Drop`): a writer
//! that read the old base a moment before a swap still writes into mapped memory, so it cannot
//! fault (the use-after-unmap the review found in the first design). On unix the file is mapped
//! `MAP_SHARED`, so the kernel keeps every written page after a crash. Elsewhere [`map_file`]
//! reports `Unsupported` and the ring stays on the heap (task 132 adds `CreateFileMapping`).

use std::alloc::Layout;
use std::io;
use std::path::Path;
use std::ptr::NonNull;

/// The alignment of every ring block (one page on every target cmux ships).
pub(crate) const BLOCK_ALIGN: usize = 4096;

/// A zeroed, page-aligned heap block, freed on drop.
pub(crate) struct HeapBlock {
    ptr: NonNull<u8>,
    layout: Layout,
}

impl HeapBlock {
    /// A zeroed block of `len` bytes (`len` > 0).
    pub(crate) fn zeroed(len: usize) -> HeapBlock {
        let layout = Layout::from_size_align(len.max(1), BLOCK_ALIGN).expect("ring block layout");
        // SAFETY: the layout has a nonzero size.
        let raw = unsafe { std::alloc::alloc_zeroed(layout) };
        let Some(ptr) = NonNull::new(raw) else { std::alloc::handle_alloc_error(layout) };
        HeapBlock { ptr, layout }
    }

    pub(crate) fn as_ptr(&self) -> *mut u8 {
        self.ptr.as_ptr()
    }
}

impl Drop for HeapBlock {
    fn drop(&mut self) {
        // SAFETY: allocated in `zeroed` with this layout and freed only here.
        unsafe { std::alloc::dealloc(self.ptr.as_ptr(), self.layout) };
    }
}

// SAFETY: the block is plain memory; the ring that owns it accesses it only through atomics.
unsafe impl Send for HeapBlock {}
// SAFETY: as for Send.
unsafe impl Sync for HeapBlock {}

/// A file mapped read-write and shared, zeroed at map time. Never unmapped (see the module doc).
#[derive(Clone, Copy)]
pub(crate) struct Mapping {
    ptr: NonNull<u8>,
}

impl Mapping {
    pub(crate) fn as_ptr(self) -> *mut u8 {
        self.ptr.as_ptr()
    }
}

/// Maps `path` as `len` zeroed bytes: a file of another size or with old contents is cut to 0 and
/// grown again (sparse), then mapped `MAP_SHARED`. The descriptor closes on return; the mapping
/// stays. Never call it on the main thread.
#[cfg(unix)]
pub(crate) fn map_file(path: &Path, len: usize) -> io::Result<Mapping> {
    use std::os::fd::AsRawFd;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(true)
        .open(path)?;
    file.set_len(len as u64)?;
    // SAFETY: a fresh read-write mapping of a descriptor opened read-write, `len` bytes long.
    let raw = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            len,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            file.as_raw_fd(),
            0,
        )
    };
    if raw == libc::MAP_FAILED {
        return Err(io::Error::last_os_error());
    }
    NonNull::new(raw.cast::<u8>())
        .map(|ptr| Mapping { ptr })
        .ok_or_else(|| io::Error::other("mmap returned null"))
}

/// No file mapping on this platform yet (task 132): the ring stays on its heap block.
#[cfg(not(unix))]
pub(crate) fn map_file(_path: &Path, _len: usize) -> io::Result<Mapping> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "cmux-trace maps ring files on unix only"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_heap_block_is_zeroed_and_page_aligned() {
        let block = HeapBlock::zeroed(10_000);
        assert_eq!(block.as_ptr() as usize % BLOCK_ALIGN, 0);
        // SAFETY: the block holds 10_000 initialised (zeroed) bytes.
        let bytes = unsafe { std::slice::from_raw_parts(block.as_ptr(), 10_000) };
        assert!(bytes.iter().all(|&byte| byte == 0));
    }

    #[cfg(unix)]
    #[test]
    fn a_mapped_file_is_zeroed_and_shared() {
        let path = std::env::temp_dir().join(format!("cmux-trace-map-{}.bin", std::process::id()));
        std::fs::write(&path, vec![0xAB; 9000]).expect("stale file");
        let mapping = map_file(&path, 8192).expect("maps");
        // SAFETY: the mapping holds 8192 bytes and is never unmapped.
        let bytes = unsafe { std::slice::from_raw_parts_mut(mapping.as_ptr(), 8192) };
        assert!(bytes.iter().all(|&byte| byte == 0), "old contents survived the map");
        bytes[100] = 7;
        let on_disk = std::fs::read(&path).expect("reads");
        assert_eq!(on_disk.len(), 8192);
        assert_eq!(on_disk[100], 7, "a MAP_SHARED write did not reach the file");
        let _ = std::fs::remove_file(&path);
    }
}
