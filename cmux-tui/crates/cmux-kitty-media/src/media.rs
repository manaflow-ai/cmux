//! Reading the bytes a file-medium command names, with the checks Kitty and
//! libghostty apply: regular files only, no `/proc`, `/sys` or `/dev`,
//! temporary files only inside a temporary directory and with
//! `tty-graphics-protocol` in their name, and a size cap.

use std::path::{Path, PathBuf};

use base64::Engine as _;
use base64::engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig};
use base64::engine::{DecodePaddingMode, general_purpose};

use crate::command::Medium;

/// Why a file-medium command was passed through instead of rewritten.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MediaRefusal {
    /// The payload is not base64 of a path or name.
    BadEncoding,
    /// The path is relative or holds a NUL byte.
    BadPath,
    /// The path resolves into `/proc`, `/sys` or `/dev`.
    Forbidden,
    /// A temporary file outside the temporary directories or without
    /// `tty-graphics-protocol` in its name.
    NotTemporary,
    /// Not a regular file (a directory, FIFO, socket or device).
    NotRegular,
    /// The requested bytes exceed the cap.
    TooLarge,
    /// The file holds fewer bytes than the offset and size ask for.
    Short,
    /// The size or offset key is not a number.
    BadRange,
    /// The platform has no such medium (shared memory off Unix).
    Unsupported,
    /// Opening or reading failed.
    Io(std::io::ErrorKind),
}

impl From<std::io::Error> for MediaRefusal {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error.kind())
    }
}

const PAYLOAD_BASE64: GeneralPurpose = GeneralPurpose::new(
    &base64::alphabet::STANDARD,
    GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
);

const TEMP_FILE_MARKER: &[u8] = b"tty-graphics-protocol";

/// The bytes `medium` names, `size` bytes from `offset` (`size` 0: to the
/// end). A temporary file or shared-memory object is deleted once read, as
/// the protocol requires.
pub(crate) fn read(
    medium: Medium,
    payload: &[u8],
    offset: u64,
    size: u64,
    max_bytes: u64,
) -> Result<Vec<u8>, MediaRefusal> {
    let name = PAYLOAD_BASE64
        .decode(payload)
        .or_else(|_| general_purpose::STANDARD_NO_PAD.decode(payload))
        .map_err(|_| MediaRefusal::BadEncoding)?;
    if name.is_empty() || name.contains(&0) {
        return Err(MediaRefusal::BadPath);
    }
    match medium {
        Medium::File => read_file(&name, offset, size, max_bytes, false),
        Medium::TempFile => read_file(&name, offset, size, max_bytes, true),
        Medium::SharedMemory => read_shared_memory(&name, offset, size, max_bytes),
        Medium::Direct | Medium::Unknown => Err(MediaRefusal::Unsupported),
    }
}

/// The byte count to read: the whole remainder for `size` 0, else exactly
/// `size`, which must fit in `available - offset` and the cap.
fn span(available: u64, offset: u64, size: u64, max_bytes: u64) -> Result<u64, MediaRefusal> {
    let remainder = available.checked_sub(offset).ok_or(MediaRefusal::Short)?;
    let wanted = if size == 0 { remainder } else { size };
    if wanted > remainder {
        return Err(MediaRefusal::Short);
    }
    if wanted > max_bytes {
        return Err(MediaRefusal::TooLarge);
    }
    Ok(wanted)
}

fn is_forbidden(canonical: &Path, temporary: bool) -> bool {
    if temporary && canonical.starts_with("/dev/shm") {
        return false;
    }
    ["/proc", "/sys", "/dev"].iter().any(|root| canonical.starts_with(root))
}

fn temporary_roots() -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> =
        ["/tmp", "/dev/shm", "/private/tmp", "/var/tmp"].iter().map(PathBuf::from).collect();
    if let Some(dir) = std::env::var_os("TMPDIR") {
        roots.push(PathBuf::from(dir));
    }
    roots.iter().filter_map(|root| std::fs::canonicalize(root).ok()).collect()
}

#[cfg(unix)]
fn read_file(
    name: &[u8],
    offset: u64,
    size: u64,
    max_bytes: u64,
    temporary: bool,
) -> Result<Vec<u8>, MediaRefusal> {
    use std::io::{Read as _, Seek as _, SeekFrom};
    use std::os::unix::ffi::OsStrExt as _;
    use std::os::unix::fs::OpenOptionsExt as _;

    let path = Path::new(std::ffi::OsStr::from_bytes(name));
    if !path.is_absolute() {
        return Err(MediaRefusal::BadPath);
    }
    let canonical = std::fs::canonicalize(path)?;
    if is_forbidden(&canonical, temporary) {
        return Err(MediaRefusal::Forbidden);
    }
    if temporary {
        let marked = memchr::memmem::find(name, TEMP_FILE_MARKER).is_some();
        if !marked || !temporary_roots().iter().any(|root| canonical.starts_with(root)) {
            return Err(MediaRefusal::NotTemporary);
        }
    }
    // O_NONBLOCK: a FIFO swapped in after canonicalize must not block the
    // PTY reader; the regular-file check below then refuses it.
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(&canonical)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(MediaRefusal::NotRegular);
    }
    let wanted = span(metadata.len(), offset, size, max_bytes)?;
    file.seek(SeekFrom::Start(offset))?;
    let capacity = usize::try_from(wanted).map_err(|_| MediaRefusal::TooLarge)?;
    let mut data = Vec::with_capacity(capacity);
    file.take(wanted).read_to_end(&mut data)?;
    if data.len() != capacity {
        return Err(MediaRefusal::Short);
    }
    if temporary {
        // The protocol hands the file to the terminal, which deletes it.
        let _ = std::fs::remove_file(&canonical);
    }
    Ok(data)
}

#[cfg(not(unix))]
fn read_file(
    _name: &[u8],
    _offset: u64,
    _size: u64,
    _max_bytes: u64,
    _temporary: bool,
) -> Result<Vec<u8>, MediaRefusal> {
    Err(MediaRefusal::Unsupported)
}

#[cfg(unix)]
fn read_shared_memory(
    name: &[u8],
    offset: u64,
    size: u64,
    max_bytes: u64,
) -> Result<Vec<u8>, MediaRefusal> {
    use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};

    // POSIX names are one component; accept the bare form too
    // (ghostty-org/ghostty#14750).
    let mut object = Vec::with_capacity(name.len().saturating_add(1));
    if name.first() != Some(&b'/') {
        object.push(b'/');
    }
    object.extend_from_slice(name);
    if object.len() < 2 || object.iter().skip(1).any(|&byte| byte == b'/') {
        return Err(MediaRefusal::BadPath);
    }
    let object = std::ffi::CString::new(object).map_err(|_| MediaRefusal::BadPath)?;
    // SAFETY: `object` is a NUL-terminated string that outlives the call.
    let raw = unsafe { libc::shm_open(object.as_ptr(), libc::O_RDONLY, 0) };
    if raw < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    // SAFETY: shm_open returned a new descriptor that nothing else owns.
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    let result = (|| {
        let file = std::fs::File::from(fd.try_clone()?);
        let available = file.metadata()?.len();
        let wanted = span(available, offset, size, max_bytes)?;
        let length = usize::try_from(wanted).map_err(|_| MediaRefusal::TooLarge)?;
        if length == 0 {
            return Ok(Vec::new());
        }
        let start = usize::try_from(offset).map_err(|_| MediaRefusal::BadRange)?;
        let mapped_len = start.checked_add(length).ok_or(MediaRefusal::BadRange)?;
        // SAFETY: a fresh read-only shared mapping of `mapped_len` bytes,
        // which fstat says the object holds; unmapped below.
        let base = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                mapped_len,
                libc::PROT_READ,
                libc::MAP_SHARED,
                fd.as_raw_fd(),
                0,
            )
        };
        if base == libc::MAP_FAILED {
            return Err(std::io::Error::last_os_error().into());
        }
        // SAFETY: `base..base + mapped_len` is mapped readable and
        // `start + length == mapped_len`.
        let data =
            unsafe { std::slice::from_raw_parts(base.cast::<u8>().add(start), length) }.to_vec();
        // SAFETY: unmaps exactly the mapping made above.
        unsafe { libc::munmap(base, mapped_len) };
        Ok(data)
    })();
    if result.is_ok() {
        // SAFETY: `object` is a NUL-terminated string that outlives the call.
        unsafe { libc::shm_unlink(object.as_ptr()) };
    }
    result
}

#[cfg(not(unix))]
fn read_shared_memory(
    _name: &[u8],
    _offset: u64,
    _size: u64,
    _max_bytes: u64,
) -> Result<Vec<u8>, MediaRefusal> {
    Err(MediaRefusal::Unsupported)
}
