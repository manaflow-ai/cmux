//! A file's birth time on Linux, read with `statx`. Rust's
//! `Metadata::created` asks `statx` only on glibc: on musl, the static build
//! every Linux daemon runs, it always fails. acpmux's log copies and
//! cmux-tui-core's copied-home check both read it here.

/// Nanoseconds since the epoch at which `file` was made. None: the kernel or
/// file system keeps no birth time.
#[cfg(target_os = "linux")]
pub fn birth_ns(file: &std::fs::File) -> Option<u64> {
    use std::os::fd::AsRawFd;
    /// The kernel's `struct statx` (`linux/stat.h`): `stx_mask` first, `stx_btime` at byte 80
    /// (after `stx_atime`), padded to its full 256 bytes.
    #[repr(C)]
    struct Statx {
        mask: u32,
        head: [u32; 19],
        btime_sec: i64,
        btime_nsec: u32,
        rest: [u32; 41],
    }
    const _: () = assert!(std::mem::size_of::<Statx>() == 256);
    const _: () = assert!(std::mem::offset_of!(Statx, btime_sec) == 80);
    const STATX_BTIME: u32 = 0x800;
    let mut buf = Statx { mask: 0, head: [0; 19], btime_sec: 0, btime_nsec: 0, rest: [0; 41] };
    // SAFETY: statx writes at most `sizeof(struct statx)` (256) bytes into `buf`, which is that
    // size; the path is an empty C string and `AT_EMPTY_PATH` makes it read the open fd itself.
    let result = unsafe {
        libc::syscall(
            libc::SYS_statx,
            file.as_raw_fd(),
            c"".as_ptr(),
            libc::AT_EMPTY_PATH,
            STATX_BTIME,
            &mut buf as *mut Statx,
        )
    };
    if result != 0 || buf.mask & STATX_BTIME == 0 || buf.btime_sec < 0 {
        return None;
    }
    Some(buf.btime_sec as u64 * 1_000_000_000 + u64::from(buf.btime_nsec))
}

/// None off Linux: no caller needs it there.
#[cfg(not(target_os = "linux"))]
pub fn birth_ns(_file: &std::fs::File) -> Option<u64> {
    None
}
