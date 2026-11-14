//! Reads of the files an agent can write in a worktree (`.git`, `HEAD`, `gitdir`,
//! `info/exclude`, `info/sparse-checkout`, a reflog): only a regular file, and at most a cap of
//! it. A FIFO put there never blocks the reader (it is opened non-blocking, then refused as no
//! regular file), and a link to `/dev/zero` or a huge file never grows the daemon's memory.

use std::fs::File;
use std::io::Read as _;
use std::path::Path;

/// The most of a one-line git file (`.git`, `HEAD`, `gitdir`) read: far past any path git writes.
pub const GIT_FILE_BYTES: u64 = 64 << 10;
/// The most of a patterns file (`info/exclude`, `info/sparse-checkout`) read.
pub const PATTERNS_BYTES: u64 = 1 << 20;
/// The most of a reflog read.
pub const REFLOG_BYTES: u64 = 32 << 20;

/// The file at `path`, not following a link at its last component, when it is a regular file of
/// at most `cap` bytes; None otherwise.
pub fn read(path: &Path, cap: u64) -> Option<Vec<u8>> {
    let mut open = std::fs::OpenOptions::new();
    open.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        open.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC);
    }
    read_opened(open.open(path).ok()?, cap)
}

/// [`read`] as text: None for a file that is not UTF-8.
pub fn read_text(path: &Path, cap: u64) -> Option<String> {
    String::from_utf8(read(path, cap)?).ok()
}

/// An already opened file (opened with `O_NONBLOCK`, say through `openat`), read as [`read`]
/// reads: only a regular file, at most `cap` bytes, and checked again as it reads, so a file
/// that grew since its `fstat` stops at the cap and is refused.
pub fn read_opened(file: File, cap: u64) -> Option<Vec<u8>> {
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() > cap {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(cap + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 <= cap).then_some(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn only_a_bounded_regular_file_is_read() {
        let dir = std::env::temp_dir().join(format!("care-bounded-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let fifo = dir.join("fifo");
        let c = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let started = std::time::Instant::now();
        assert_eq!(read(&fifo, GIT_FILE_BYTES), None);
        assert!(started.elapsed() < std::time::Duration::from_secs(2), "a FIFO blocked the read");
        let zero = dir.join("zero");
        std::os::unix::fs::symlink("/dev/zero", &zero).unwrap();
        assert_eq!(read(&zero, GIT_FILE_BYTES), None);
        assert_eq!(read(Path::new("/dev/zero"), GIT_FILE_BYTES), None);
        let big = dir.join("big");
        std::fs::write(&big, vec![b'x'; 11]).unwrap();
        assert_eq!(read(&big, 10), None);
        assert_eq!(read(&big, 11).map(|b| b.len()), Some(11));
        let linked = dir.join("linked");
        std::os::unix::fs::symlink(&big, &linked).unwrap();
        assert_eq!(read(&linked, 11), None, "a link at the last component is not followed");
        assert_eq!(read_text(&big, 11).as_deref(), Some("xxxxxxxxxxx"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
