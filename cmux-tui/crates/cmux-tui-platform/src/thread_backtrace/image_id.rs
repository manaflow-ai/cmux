//! The build id of a loaded image, which ties a frame's offset to one build
//! for offline symbolication, as Chrome's base/profiler/module_cache.h
//! `Module::GetId` does: the Mach-O `LC_UUID` on macOS, the ELF
//! `NT_GNU_BUILD_ID` on Linux. Read after the captured thread runs again.

/// The build id of the image loaded at `base` that holds `address`, or
/// `None` when it has none: the Mach-O `LC_UUID` as `dwarfdump --uuid`
/// prints it, or the ELF `NT_GNU_BUILD_ID` in lowercase hex as `readelf -n`
/// prints it.
#[cfg(target_os = "macos")]
pub(super) fn of(base: usize, _address: usize) -> Option<String> {
    const HEADER_SIZE: usize = 32;
    let header = base as *const u8;
    // SAFETY: `base` is dladdr's `dli_fbase`, a loaded image's mapped
    // mach_header_64; dyld keeps it and the load commands after it mapped
    // while the image is loaded, and sizeofcmds bounds the commands.
    let commands_size = unsafe { header.add(20).cast::<u32>().read_unaligned() };
    let size = HEADER_SIZE.checked_add(usize::try_from(commands_size).ok()?)?;
    // SAFETY: as above, the header and its `size` bytes of commands.
    let image = unsafe { std::slice::from_raw_parts(header, size) };
    mach_uuid(image)
}

/// See the macOS `of`; on Linux the object is found by `address`, since
/// `dli_fbase` of the main program need not be its load bias.
#[cfg(target_os = "linux")]
pub(super) fn of(_base: usize, address: usize) -> Option<String> {
    struct Search {
        address: usize,
        id: Option<String>,
    }

    /// dl_iterate_phdr's callback: stops (1) at the object holding the
    /// address.
    unsafe extern "C" fn visit(
        info: *mut libc::dl_phdr_info,
        _size: libc::size_t,
        data: *mut libc::c_void,
    ) -> libc::c_int {
        // SAFETY: `data` is the `Search` passed below; `info` is the
        // loader's description of one object, valid for this call.
        let (search, info) = unsafe { (&mut *data.cast::<Search>(), &*info) };
        if info.dlpi_phdr.is_null() {
            return 0;
        }
        // SAFETY: the loader's program headers, `dlpi_phnum` of them.
        let headers =
            unsafe { std::slice::from_raw_parts(info.dlpi_phdr, usize::from(info.dlpi_phnum)) };
        let bias = info.dlpi_addr as usize;
        let holds = headers.iter().any(|header| {
            let start = bias.wrapping_add(header.p_vaddr as usize);
            header.p_type == libc::PT_LOAD
                && (start..start.wrapping_add(header.p_memsz as usize)).contains(&search.address)
        });
        if !holds {
            return 0;
        }
        search.id =
            headers.iter().filter(|header| header.p_type == libc::PT_NOTE).find_map(|header| {
                let start = bias.wrapping_add(header.p_vaddr as usize);
                // SAFETY: a PT_NOTE segment lies in a loaded PT_LOAD one.
                let notes = unsafe {
                    std::slice::from_raw_parts(start as *const u8, header.p_memsz as usize)
                };
                gnu_build_id(notes).map(hex)
            });
        1
    }

    let mut search = Search { address, id: None };
    // SAFETY: `visit` matches the callback type and only reads the loader's
    // headers and the segments of loaded objects.
    unsafe { libc::dl_iterate_phdr(Some(visit), (&raw mut search).cast()) };
    search.id
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(super) fn of(_base: usize, _address: usize) -> Option<String> {
    None
}

/// `bytes` in lowercase hex.
#[cfg(any(target_os = "macos", target_os = "linux"))]
pub(super) fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;

    bytes.iter().fold(String::with_capacity(bytes.len() * 2), |mut text, byte| {
        let _ = write!(text, "{byte:02x}");
        text
    })
}

/// The `u32` at `at` in `bytes`, in this machine's byte order.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn u32_at(bytes: &[u8], at: usize) -> Option<u32> {
    let word = bytes.get(at..at.checked_add(4)?)?;
    word.try_into().ok().map(u32::from_ne_bytes)
}

/// The `LC_UUID` of a Mach-O image's header and load commands, formatted
/// as `dwarfdump --uuid` prints it.
#[cfg(any(target_os = "macos", all(test, target_os = "linux")))]
pub(super) fn mach_uuid(header: &[u8]) -> Option<String> {
    const MH_MAGIC_64: u32 = 0xfeed_facf;
    const HEADER_SIZE: usize = 32;
    const LC_UUID: u32 = 0x1b;
    if u32_at(header, 0)? != MH_MAGIC_64 {
        return None;
    }
    let commands = u32_at(header, 16)?;
    let mut at = HEADER_SIZE;
    for _ in 0..commands {
        let command = u32_at(header, at)?;
        let size = usize::try_from(u32_at(header, at + 4)?).ok()?;
        if command == LC_UUID {
            let uuid = hex(header.get(at + 8..at + 24)?).to_uppercase();
            return Some(format!(
                "{}-{}-{}-{}-{}",
                &uuid[..8],
                &uuid[8..12],
                &uuid[12..16],
                &uuid[16..20],
                &uuid[20..]
            ));
        }
        if size < 8 {
            return None;
        }
        at = at.checked_add(size)?;
    }
    None
}

/// The `NT_GNU_BUILD_ID` in an ELF note segment. Fields are padded to 4
/// bytes, as Chrome's base/debug/elf_reader.cc reads them: one segment can
/// hold a 4-aligned build id after an 8-aligned `.note.gnu.property` (whose
/// sizes keep it 8-aligned either way), so the segment's `p_align` is not
/// each note's.
#[cfg(any(target_os = "linux", all(test, target_os = "macos")))]
pub(super) fn gnu_build_id(notes: &[u8]) -> Option<&[u8]> {
    const NT_GNU_BUILD_ID: u32 = 3;
    const ALIGN: usize = 4;
    let end_of = |start: usize, size: u32| start.checked_add(usize::try_from(size).ok()?);
    let mut at = 0;
    while let (Some(name_size), Some(desc_size), Some(kind)) =
        (u32_at(notes, at), u32_at(notes, at + 4), u32_at(notes, at + 8))
    {
        let name_at = at + 12;
        let name_end = end_of(name_at, name_size)?;
        let desc_at = name_end.next_multiple_of(ALIGN);
        let desc_end = end_of(desc_at, desc_size)?;
        if kind == NT_GNU_BUILD_ID && notes.get(name_at..name_end) == Some(b"GNU\0") {
            return notes.get(desc_at..desc_end);
        }
        at = desc_end.next_multiple_of(ALIGN);
    }
    None
}
