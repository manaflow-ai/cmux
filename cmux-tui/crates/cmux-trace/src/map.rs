//! Ring memory: the zeroed heap block a ring starts in, and the shared file mapping of a ring file.
//!
//! A file mapping is never unmapped while the process lives ([`Mapping`] has no `Drop`): a writer
//! that read the old active ring a moment before a swap still writes into mapped memory, so it
//! cannot fault (the use-after-unmap the review found in the first design). On unix the file's
//! blocks are reserved first ([`reserve_blocks`]) and it is mapped `MAP_SHARED`, so the kernel
//! keeps every written page after a crash and a full disk cannot fault a write. Elsewhere
//! [`map_file`] reports `Unsupported` and the ring stays on the heap (task 132 adds
//! `CreateFileMapping`).

use std::alloc::Layout;
use std::io;
use std::path::Path;
use std::ptr::NonNull;

/// The alignment of every ring block (one page on every target cmux ships).
pub(crate) const BLOCK_ALIGN: usize = 16384;

/// A zeroed, page-aligned heap block, freed on drop. Neither `Send` nor `Sync` itself: the
/// [`crate::ring::Ring`] that owns it carries the one cross-thread argument for its memory.
pub(crate) struct HeapBlock {
    ptr: NonNull<u8>,
    layout: Layout,
}

impl HeapBlock {
    /// A zeroed block of `len` bytes (`len` > 0).
    pub(crate) fn zeroed(len: usize) -> HeapBlock {
        // A size past isize::MAX is an allocation that cannot succeed (rings are capped far below it).
        let layout = Layout::from_size_align(len.max(1), BLOCK_ALIGN)
            .unwrap_or_else(|_| std::alloc::handle_alloc_error(Layout::new::<u8>()));
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

/// Reserves the disk blocks of a ring file's first `len` bytes before it is mapped. A
/// `MAP_SHARED` page with no block behind it raises SIGBUS at its first write when the
/// filesystem is full or a quota is reached. The tracer injects it
/// ([`crate::TracerConfig::reserve`]); [`reserve_blocks`] is the real one.
pub type Reserve = fn(&std::fs::File, u64) -> io::Result<()>;

/// Linux: `posix_fallocate` (glibc writes the zeros itself where the filesystem has no fallocate).
#[cfg(target_os = "linux")]
pub fn reserve_blocks(file: &std::fs::File, len: u64) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let len =
        libc::off_t::try_from(len).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: a descriptor opened for writing; the call takes no pointers.
    match unsafe { libc::posix_fallocate(file.as_raw_fd(), 0, len) } {
        0 => Ok(()),
        errno => Err(io::Error::from_raw_os_error(errno)),
    }
}

/// macOS: `fcntl(F_PREALLOCATE)` of every block, from the physical end of the (empty) file.
#[cfg(target_os = "macos")]
pub fn reserve_blocks(file: &std::fs::File, len: u64) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let len =
        libc::off_t::try_from(len).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    let mut store = libc::fstore_t {
        fst_flags: libc::F_ALLOCATEALL,
        fst_posmode: libc::F_PEOFPOSMODE,
        fst_offset: 0,
        fst_length: len,
        fst_bytesalloc: 0,
    };
    // SAFETY: a descriptor opened for writing and a valid fstore_t for the call.
    if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_PREALLOCATE, &raw mut store) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Other unix: write the zeros, which allocates every block.
#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
pub fn reserve_blocks(file: &std::fs::File, len: u64) -> io::Result<()> {
    use std::io::Write;
    let zeros = [0u8; 16384];
    let mut writer = file;
    let mut left = len;
    while left > 0 {
        let step = left.min(zeros.len() as u64) as usize;
        writer.write_all(&zeros[..step])?;
        left -= step as u64;
    }
    Ok(())
}

/// No ring files on this platform yet (task 132).
#[cfg(not(unix))]
pub fn reserve_blocks(_file: &std::fs::File, _len: u64) -> io::Result<()> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "cmux-trace maps ring files on unix only"))
}

/// Maps `path` as `len` zeroed bytes: a file of another size or with old contents is cut to 0,
/// its blocks are reserved with `reserve`, it is sized, then mapped `MAP_SHARED`. When a step
/// fails the file is removed and the error returned, so the ring stays on the heap. The
/// descriptor closes on return; the mapping stays. Never call it on the main thread.
#[cfg(unix)]
pub(crate) fn map_file(path: &Path, len: usize, reserve: Reserve) -> io::Result<Mapping> {
    map_reserved(path, len, reserve).inspect_err(|_| {
        let _ = std::fs::remove_file(path);
    })
}

/// Creates `dir` (and its missing parents) for this user only (0700). An
/// existing `dir` must be a real directory, not a symlink, that this user
/// owns and other users cannot write: a ring never lands in a directory
/// another user prepared.
#[cfg(unix)]
pub(crate) fn create_private_dir(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    let meta = std::fs::symlink_metadata(dir)?;
    // SAFETY: getuid cannot fail and takes no pointers.
    let uid = unsafe { libc::getuid() };
    if !meta.is_dir() || meta.uid() != uid || meta.mode() & 0o002 != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} is not a private directory of this user", dir.display()),
        ));
    }
    Ok(())
}

#[cfg(not(unix))]
pub(crate) fn create_private_dir(dir: &Path) -> io::Result<()> {
    std::fs::create_dir_all(dir)
}

#[cfg(unix)]
fn map_reserved(path: &Path, len: usize, reserve: Reserve) -> io::Result<Mapping> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    // A new file, never one a symlink names: an old ring of a reused pid is
    // removed first (`remove_file` unlinks a symlink itself, not its target),
    // and a file that appears in between fails the exclusive create.
    match std::fs::remove_file(path) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
        _ => {}
    }
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    reserve(&file, len as u64)?;
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
pub(crate) fn map_file(_path: &Path, _len: usize, _reserve: Reserve) -> io::Result<Mapping> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "cmux-trace maps ring files on unix only"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn scratch(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("cmux-trace-{name}-{}.bin", std::process::id()))
    }

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
        let path = scratch("map");
        std::fs::write(&path, vec![0xAB; 9000]).expect("stale file");
        let mapping = map_file(&path, 8192, reserve_blocks).expect("maps");
        // SAFETY: the mapping holds 8192 bytes and is never unmapped.
        let bytes = unsafe { std::slice::from_raw_parts_mut(mapping.as_ptr(), 8192) };
        assert!(bytes.iter().all(|&byte| byte == 0), "old contents survived the map");
        bytes[100] = 7;
        let on_disk = std::fs::read(&path).expect("reads");
        assert_eq!(on_disk.len(), 8192);
        assert_eq!(on_disk[100], 7, "a MAP_SHARED write did not reach the file");
        let _ = std::fs::remove_file(&path);
    }

    /// The blocks are on disk before the map, so a full disk cannot SIGBUS a later write.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_mapped_file_has_its_blocks_reserved() {
        use std::os::unix::fs::MetadataExt;
        let path = scratch("reserve");
        let len = 1 << 20;
        map_file(&path, len, reserve_blocks).expect("maps");
        let blocks = std::fs::metadata(&path).expect("stats").blocks();
        assert!(blocks * 512 >= len as u64, "only {blocks} blocks of a {len}-byte ring");
        let _ = std::fs::remove_file(&path);
    }

    #[cfg(unix)]
    #[test]
    fn a_failed_reservation_maps_nothing_and_removes_the_file() {
        fn full(_: &std::fs::File, _: u64) -> io::Result<()> {
            Err(io::Error::from_raw_os_error(libc::ENOSPC))
        }
        let path = scratch("full");
        let error = map_file(&path, 8192, full).err().expect("a full disk fails the map");
        assert_eq!(error.raw_os_error(), Some(libc::ENOSPC));
        assert!(!path.exists(), "a ring file with no blocks was left behind");
    }

    /// A symlink planted at the ring's name is replaced, never written
    /// through: its target keeps its contents.
    #[cfg(unix)]
    #[test]
    fn a_ring_never_writes_through_a_symlink_at_its_name() {
        let target = scratch("symlink-target");
        std::fs::write(&target, b"the owner's file").expect("target");
        let path = scratch("symlink-ring");
        let _ = std::fs::remove_file(&path);
        std::os::unix::fs::symlink(&target, &path).expect("symlink");
        map_file(&path, 8192, reserve_blocks).expect("maps a new file");
        assert_eq!(std::fs::read(&target).expect("reads"), b"the owner's file");
        assert!(!std::fs::symlink_metadata(&path).expect("stats").is_symlink());
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(&target);
    }

    /// The ring directory is this user's; one other users can write is refused.
    #[cfg(unix)]
    #[test]
    fn a_ring_directory_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let dir = scratch("private-dir");
        let _ = std::fs::remove_dir_all(&dir);
        create_private_dir(&dir.join("trace")).expect("creates");
        let mode = std::fs::metadata(dir.join("trace")).expect("stats").permissions().mode();
        assert_eq!(mode & 0o077, 0, "mode {mode:o}");
        std::fs::set_permissions(dir.join("trace"), std::fs::Permissions::from_mode(0o777))
            .expect("chmod");
        assert!(create_private_dir(&dir.join("trace")).is_err(), "a shared directory was taken");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
