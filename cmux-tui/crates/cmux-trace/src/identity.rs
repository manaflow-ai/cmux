//! Who wrote a ring: the process (pid, start time, build) and each thread (tid, QoS, name).
//! Everything here reads the system once, off the record path.

use crate::layout::THREAD_NAME_BYTES;

/// A thread as its thread-table entry names it. Read once per thread, at its first registration,
/// and kept in TLS, so registering in a later ring is stores only.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ThreadIdentity {
    /// `pthread_threadid_np` (Linux `gettid`, Windows `GetCurrentThreadId`).
    pub tid: u64,
    /// `qos_class_t` at registration (`pthread_get_qos_class_np`; 0 elsewhere).
    pub qos: u8,
    name: [u8; THREAD_NAME_BYTES],
    name_len: u8,
}

impl ThreadIdentity {
    /// An identity with these fields; `name` is cut at 46 bytes on a character boundary.
    pub fn new(tid: u64, qos: u8, name: &str) -> ThreadIdentity {
        let mut identity = ThreadIdentity { tid, qos, name: [0; THREAD_NAME_BYTES], name_len: 0 };
        let bytes = crate::layout::utf8_prefix(name, THREAD_NAME_BYTES);
        identity.name[..bytes.len()].copy_from_slice(bytes);
        identity.name_len = bytes.len() as u8;
        identity
    }

    /// The calling thread, read with no allocation.
    pub fn current() -> ThreadIdentity {
        let mut identity = ThreadIdentity {
            tid: current_tid(),
            qos: current_qos(),
            name: [0; THREAD_NAME_BYTES],
            name_len: 0,
        };
        identity.name_len = current_name(&mut identity.name);
        identity
    }

    pub fn name(&self) -> &[u8] {
        &self.name[..usize::from(self.name_len)]
    }

    /// Entry bytes 16-63: `qos`, `name_len`, the NUL-padded name.
    pub(crate) fn packed(&self) -> [u8; 48] {
        let mut out = [0u8; 48];
        out[0] = self.qos;
        out[1] = self.name_len;
        out[2..].copy_from_slice(&self.name);
        out
    }
}

#[cfg(target_os = "macos")]
fn current_tid() -> u64 {
    let mut id = 0u64;
    // SAFETY: a null thread names the calling thread; `id` is a valid out pointer.
    unsafe { libc::pthread_threadid_np(0, &mut id) };
    id
}

#[cfg(target_os = "linux")]
fn current_tid() -> u64 {
    // SAFETY: gettid has no preconditions.
    unsafe { libc::gettid() as u64 }
}

#[cfg(windows)]
fn current_tid() -> u64 {
    unsafe extern "system" {
        fn GetCurrentThreadId() -> u32;
    }
    // SAFETY: no preconditions.
    u64::from(unsafe { GetCurrentThreadId() })
}

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
fn current_tid() -> u64 {
    0
}

#[cfg(target_os = "macos")]
fn current_qos() -> u8 {
    let mut qos: libc::qos_class_t = libc::qos_class_t::QOS_CLASS_UNSPECIFIED;
    let mut relative = 0;
    // SAFETY: the calling thread's handle and two valid out pointers.
    unsafe { libc::pthread_get_qos_class_np(libc::pthread_self(), &mut qos, &mut relative) };
    qos as u32 as u8
}

#[cfg(not(target_os = "macos"))]
fn current_qos() -> u8 {
    0
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn current_name(out: &mut [u8; THREAD_NAME_BYTES]) -> u8 {
    let mut buffer = [0u8; 64];
    // SAFETY: the calling thread's handle and a buffer of the length passed.
    let status = unsafe {
        libc::pthread_getname_np(libc::pthread_self(), buffer.as_mut_ptr().cast(), buffer.len())
    };
    if status != 0 {
        return 0;
    }
    let end = buffer.iter().position(|&byte| byte == 0).unwrap_or(buffer.len());
    let raw = &buffer[..end];
    // A name cut mid-character by the kernel keeps its valid prefix (no allocation).
    let valid = std::str::from_utf8(raw).unwrap_or_else(|error| {
        std::str::from_utf8(&raw[..error.valid_up_to()]).unwrap_or_default()
    });
    let bytes = crate::layout::utf8_prefix(valid, THREAD_NAME_BYTES);
    out[..bytes.len()].copy_from_slice(bytes);
    bytes.len() as u8
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn current_name(_out: &mut [u8; THREAD_NAME_BYTES]) -> u8 {
    0
}

/// The process fields of a ring header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ProcessIdentity {
    pub pid: u32,
    /// The kernel's start time of `pid` (with `kill(pid, 0)`, cleanup tells a reused pid).
    pub process_start_unix_us: u64,
    /// `kern.bootsessionuuid` (Linux `boot_id`, Windows zero).
    pub boot_session_uuid: [u8; 16],
    /// `LC_UUID` of the main image (Linux: the first 16 bytes of the GNU build id; zero when none).
    pub build_uuid: [u8; 16],
    /// ASCII, NUL padded: version, build number and short commit.
    pub build_version: [u8; 32],
}

impl ProcessIdentity {
    /// The fields that need no system call: the pid, the build uuid (read from the loaded image
    /// in memory) and the build version. The other two are zero until [`ProcessIdentity::read_slow`].
    pub fn current_fast() -> ProcessIdentity {
        ProcessIdentity {
            pid: std::process::id(),
            process_start_unix_us: 0,
            boot_session_uuid: [0; 16],
            build_uuid: build_uuid(),
            build_version: build_version(),
        }
    }

    /// Fills the fields that read a sysctl or a file. Call it off the main thread.
    pub fn read_slow(&mut self) {
        self.process_start_unix_us = process_start_unix_us();
        self.boot_session_uuid = crate::clock::boot_session();
    }
}

/// `CMUX_BUILD_VERSION` at compile time (the release scripts set version, build number and short
/// commit), else the crate version.
pub fn build_version() -> [u8; 32] {
    let text = option_env!("CMUX_BUILD_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"));
    let mut out = [0u8; 32];
    let bytes = crate::layout::utf8_prefix(text, 32);
    out[..bytes.len()].copy_from_slice(bytes);
    out
}

/// The main image's `LC_UUID` (`_dyld_get_image_header(0)`); zero when it has none.
#[cfg(target_os = "macos")]
pub fn build_uuid() -> [u8; 16] {
    const MH_MAGIC_64: u32 = 0xfeed_facf;
    const LC_UUID: u32 = 0x1b;
    // Declared here (libc deprecates its copy for the mach2 crate; this crate is std and libc only).
    unsafe extern "C" {
        fn _dyld_get_image_header(image_index: u32) -> *const u8;
    }
    // SAFETY: image 0 is the main executable, whose header dyld keeps mapped for the process's life.
    let header = unsafe { _dyld_get_image_header(0) };
    if header.is_null() {
        return [0; 16];
    }
    let read32 = |at: usize| {
        // SAFETY: `at` is inside the mach header or its load commands (bounded by `sizeofcmds`).
        unsafe { header.add(at).cast::<u32>().read_unaligned() }
    };
    if read32(0) != MH_MAGIC_64 {
        return [0; 16];
    }
    let (count, size) = (read32(16) as usize, read32(20) as usize);
    let (mut at, end) = (32usize, 32 + size);
    for _ in 0..count {
        if at + 8 > end {
            break;
        }
        let (command, command_size) = (read32(at), read32(at + 4) as usize);
        if command == LC_UUID && command_size >= 24 && at + 24 <= end {
            let mut out = [0u8; 16];
            // SAFETY: the 16 uuid bytes follow the 8-byte command header inside the commands.
            unsafe { std::ptr::copy_nonoverlapping(header.add(at + 8), out.as_mut_ptr(), 16) };
            return out;
        }
        if command_size < 8 {
            break;
        }
        at += command_size;
    }
    [0; 16]
}

/// The first 16 bytes of the main program's GNU build id (`NT_GNU_BUILD_ID` in a `PT_NOTE`
/// segment, found with `dl_iterate_phdr`); zero when it has none.
#[cfg(target_os = "linux")]
pub fn build_uuid() -> [u8; 16] {
    unsafe extern "C" fn first_object(
        info: *mut libc::dl_phdr_info,
        _size: libc::size_t,
        data: *mut libc::c_void,
    ) -> libc::c_int {
        // SAFETY: dl_iterate_phdr passes a valid info for the call and our `data` pointer.
        let (info, out) = unsafe { (&*info, &mut *data.cast::<[u8; 16]>()) };
        if info.dlpi_phdr.is_null() {
            return 1;
        }
        // SAFETY: the loader's program headers for this object, `dlpi_phnum` long.
        let headers = unsafe { std::slice::from_raw_parts(info.dlpi_phdr, info.dlpi_phnum.into()) };
        for header in headers.iter().filter(|header| header.p_type == libc::PT_NOTE) {
            let start = (info.dlpi_addr as usize).wrapping_add(header.p_vaddr as usize);
            // SAFETY: a PT_NOTE segment of a loaded object is mapped readable for its memsz.
            let notes =
                unsafe { std::slice::from_raw_parts(start as *const u8, header.p_memsz as usize) };
            if let Some(id) = gnu_build_id(notes) {
                *out = id;
                break;
            }
        }
        1 // The first object is the main program: stop.
    }
    let mut out = [0u8; 16];
    // SAFETY: the callback only reads loader data and writes `out`, which outlives the call.
    unsafe { libc::dl_iterate_phdr(Some(first_object), (&raw mut out).cast()) };
    out
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub fn build_uuid() -> [u8; 16] {
    [0; 16]
}

/// The first 16 bytes of the `GNU` note of type 3 (`NT_GNU_BUILD_ID`) in an ELF note segment.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) fn gnu_build_id(mut notes: &[u8]) -> Option<[u8; 16]> {
    const NT_GNU_BUILD_ID: u32 = 3;
    let word = |bytes: &[u8], at: usize| {
        bytes.get(at..).and_then(<[u8]>::first_chunk).map(|word| u32::from_le_bytes(*word))
    };
    while notes.len() >= 12 {
        let (name_size, desc_size, kind) = (word(notes, 0)?, word(notes, 4)?, word(notes, 8)?);
        let name_end = 12 + (name_size as usize).next_multiple_of(4);
        let desc_end = name_end + (desc_size as usize).next_multiple_of(4);
        let name = notes.get(12..12 + name_size as usize)?;
        let desc = notes.get(name_end..name_end + desc_size as usize)?;
        if kind == NT_GNU_BUILD_ID && name == b"GNU\0" {
            let mut out = [0u8; 16];
            let len = desc.len().min(16);
            out[..len].copy_from_slice(&desc[..len]);
            return Some(out);
        }
        notes = notes.get(desc_end..)?;
    }
    None
}

fn process_start_unix_us() -> u64 {
    process_start_unix_us_of(std::process::id())
}

/// The kernel's start time of process `pid` in us since 1970 (`proc_pidinfo` `PROC_PIDTBSDINFO`);
/// 0 when it cannot be read. The header's `process_start_unix_us`, and what cleanup compares it with.
#[cfg(target_os = "macos")]
pub(crate) fn process_start_unix_us_of(pid: u32) -> u64 {
    let Ok(pid) = libc::c_int::try_from(pid) else { return 0 };
    // SAFETY: proc_bsdinfo is plain old data; all zero is a valid value.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = size_of::<libc::proc_bsdinfo>() as libc::c_int;
    // SAFETY: any pid (a missing one fails the call), a buffer of `size` bytes.
    let read =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size) };
    if read != size {
        return 0;
    }
    info.pbi_start_tvsec.saturating_mul(1_000_000).saturating_add(info.pbi_start_tvusec)
}

/// `/proc/self/stat` field 22 (start time in clock ticks after boot) plus `btime` of `/proc/stat`.
/// Another process's is 0 (unknown): cmux-next reads no other process's `/proc` entry
/// (plans/cmux-next/pty-holder.md, "No process scanning"), so on Linux cleanup tells a dead pid by
/// `kill(pid, 0)` alone.
#[cfg(target_os = "linux")]
pub(crate) fn process_start_unix_us_of(pid: u32) -> u64 {
    if pid != std::process::id() {
        return 0;
    }
    let ticks = std::fs::read_to_string("/proc/self/stat").ok().and_then(|stat| {
        let after_name = &stat[stat.rfind(')')? + 1..];
        after_name.split_whitespace().nth(19)?.parse::<u64>().ok()
    });
    let boot = std::fs::read_to_string("/proc/stat").ok().and_then(|stat| {
        stat.lines().find_map(|line| line.strip_prefix("btime ")?.trim().parse::<u64>().ok())
    });
    // SAFETY: sysconf has no preconditions.
    let hertz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    match (ticks, boot, u64::try_from(hertz)) {
        (Some(ticks), Some(boot), Ok(hertz)) if hertz > 0 => {
            boot.saturating_mul(1_000_000).saturating_add(ticks.saturating_mul(1_000_000) / hertz)
        }
        _ => 0,
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(crate) fn process_start_unix_us_of(_pid: u32) -> u64 {
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(name: &[u8], kind: u32, desc: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend((name.len() as u32).to_le_bytes());
        out.extend((desc.len() as u32).to_le_bytes());
        out.extend(kind.to_le_bytes());
        out.extend(name);
        out.resize(out.len().next_multiple_of(4), 0);
        out.extend(desc);
        out.resize(out.len().next_multiple_of(4), 0);
        out
    }

    #[test]
    fn the_build_id_note_is_found_after_other_notes() {
        let id: Vec<u8> = (1..=20).collect();
        let mut notes = note(b"GNU\0", 1, &[0; 16]);
        notes.extend(note(b"Go\0", 3, &[9; 8]));
        notes.extend(note(b"GNU\0", 3, &id));
        let found = gnu_build_id(&notes).expect("finds the note");
        assert_eq!(found.as_slice(), &id[..16]);
        assert_eq!(gnu_build_id(&notes[..notes.len() - 4]), None, "a cut note is not read");
    }

    /// On Linux the id read from the loaded image is the one in the executable file.
    #[cfg(target_os = "linux")]
    #[test]
    fn the_build_uuid_is_the_executables_gnu_build_id() {
        let file = std::fs::read("/proc/self/exe").expect("reads the test binary");
        let pattern = [4u8, 0, 0, 0, 20, 0, 0, 0, 3, 0, 0, 0, b'G', b'N', b'U', 0];
        let expected = file
            .windows(pattern.len())
            .position(|window| window == pattern)
            .map(|at| <[u8; 16]>::try_from(&file[at + 16..at + 32]).unwrap_or([0; 16]));
        assert_eq!(build_uuid(), expected.unwrap_or([0; 16]));
    }

    #[test]
    fn a_thread_name_is_cut_on_a_character_boundary() {
        let long = "é".repeat(30);
        let identity = ThreadIdentity::new(1, 0x21, &long);
        assert_eq!(identity.name().len(), 46);
        assert!(std::str::from_utf8(identity.name()).is_ok());
        let packed = identity.packed();
        assert_eq!((packed[0], packed[1]), (0x21, 46));
    }

    #[test]
    fn the_slow_identity_reads_a_start_time_before_now() {
        let mut identity = ProcessIdentity::current_fast();
        identity.read_slow();
        if cfg!(any(target_os = "macos", target_os = "linux")) {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |since| since.as_micros() as u64);
            assert!(identity.process_start_unix_us > 0 && identity.process_start_unix_us <= now);
        }
    }
}
