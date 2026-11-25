//! The calling thread's backtrace as text, named even in a stripped release binary.
//!
//! A release bundle's `bin/cmux` has no symbol table (`strip-release-bundle.sh`),
//! so std's backtrace prints `<unknown>` for each of its frames. Its names are
//! in the side map `Contents/Resources/cmux-tui-symbols.bin` ([`crate::symbol_map`]):
//! when that map holds this executable's `LC_UUID`, the executable's frames
//! are named from it and every other image's through `dladdr`. Builds with no
//! map (dev, tests, other platforms) keep std's backtrace, which reads the
//! symbol table they still have.

/// The backtrace of the calling thread, always captured (`Backtrace::force_capture`).
pub fn force_capture() -> String {
    #[cfg(target_os = "macos")]
    if let Some(text) = mac::named() {
        return text;
    }
    std::backtrace::Backtrace::force_capture().to_string()
}

/// The backtrace of the calling thread when `RUST_BACKTRACE` asks for one
/// (`Backtrace::capture`), else `None`.
pub fn capture() -> Option<String> {
    let backtrace = std::backtrace::Backtrace::capture();
    if backtrace.status() != std::backtrace::BacktraceStatus::Captured {
        return None;
    }
    #[cfg(target_os = "macos")]
    if let Some(text) = mac::named() {
        return Some(text);
    }
    Some(backtrace.to_string())
}

/// The file name of the side map, in the bundle's `Contents/Resources`
/// (the parent of the executable's `bin/`).
pub const SYMBOL_MAP_NAME: &str = "cmux-tui-symbols.bin";

#[cfg(target_os = "macos")]
// libc marks `_dyld_get_image_header` and `mach_header_64` deprecated in favor of the mach2
// crate; they are the same dyld API and struct, and this is their only use here.
#[allow(deprecated)]
mod mac {
    use std::fmt::Write;
    use std::sync::OnceLock;

    use crate::symbol_map::SymbolMap;

    /// Frames kept, as std keeps up to its own limit; the log cuts the text at 16 KiB.
    const MAX_FRAMES: usize = 256;
    const LC_UUID: u32 = 0x1B;
    const MH_MAGIC_64: u32 = 0xFEED_FACF;

    /// The executable's map, read on first use; `None` when the bundle has
    /// none for this build.
    fn map() -> Option<&'static SymbolMap> {
        static MAP: OnceLock<Option<SymbolMap>> = OnceLock::new();
        MAP.get_or_init(|| {
            let uuid = own_uuid()?;
            let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
            let path = exe.parent()?.parent()?.join(super::SYMBOL_MAP_NAME);
            SymbolMap::parse(&std::fs::read(path).ok()?, &uuid)
        })
        .as_ref()
    }

    /// The `LC_UUID` of the executable (image 0).
    pub(super) fn own_uuid() -> Option<[u8; 16]> {
        // SAFETY: image 0 is the main executable, mapped for the process's life.
        let header = unsafe { libc::_dyld_get_image_header(0) };
        if header.is_null() {
            return None;
        }
        // SAFETY: a mapped mach_header_64; load commands follow it, sized by their cmdsize.
        unsafe {
            let header = header.cast::<libc::mach_header_64>();
            if (*header).magic != MH_MAGIC_64 {
                return None;
            }
            let mut command = header.cast::<u8>().add(std::mem::size_of::<libc::mach_header_64>());
            for _ in 0..(*header).ncmds {
                let cmd = command.cast::<u32>().read_unaligned();
                let size = command.add(4).cast::<u32>().read_unaligned();
                if cmd == LC_UUID {
                    return Some(command.add(8).cast::<[u8; 16]>().read_unaligned());
                }
                command = command.add(size as usize);
            }
        }
        None
    }

    /// The backtrace named through the bundle's map, or `None` without one.
    pub(super) fn named() -> Option<String> {
        Some(with_map(map()?))
    }

    /// The backtrace with the executable's frames named through `map` only.
    pub(super) fn with_map(map: &SymbolMap) -> String {
        let mut addresses = [std::ptr::null_mut::<libc::c_void>(); MAX_FRAMES];
        // SAFETY: the buffer holds MAX_FRAMES pointers.
        let count = unsafe { libc::backtrace(addresses.as_mut_ptr(), MAX_FRAMES as libc::c_int) };
        // SAFETY: image 0 is the main executable.
        let executable = unsafe { libc::_dyld_get_image_header(0) }.cast::<libc::c_void>();
        let mut text = String::new();
        for (index, address) in addresses.iter().take(count.max(0) as usize).enumerate() {
            let address = *address as usize;
            // A return address is the instruction after the call: name the call.
            let lookup = if index == 0 || address == 0 { address } else { address - 1 };
            // SAFETY: Dl_info is plain pointers, for which all zeros is valid.
            let mut info: libc::Dl_info = unsafe { std::mem::zeroed() };
            // SAFETY: dladdr only reads the loaded image list.
            let found = unsafe { libc::dladdr(lookup as *const libc::c_void, &mut info) } != 0;
            let base = if found { info.dli_fbase as usize } else { 0 };
            let image = if found && !info.dli_fname.is_null() {
                // SAFETY: dladdr's file name is a NUL-terminated C string.
                let path = unsafe { std::ffi::CStr::from_ptr(info.dli_fname) }.to_string_lossy();
                path.rsplit('/').next().unwrap_or_default().to_string()
            } else {
                "???".to_string()
            };
            let name = if found && info.dli_fbase.cast_const() == executable {
                // The executable has no symbol table: only the map names its frames.
                map.function((lookup - base) as u64).map(|(name, _)| demangle(name))
            } else if found && !info.dli_sname.is_null() {
                // SAFETY: dladdr's symbol name is a NUL-terminated C string.
                Some(demangle(
                    &unsafe { std::ffi::CStr::from_ptr(info.dli_sname) }.to_string_lossy(),
                ))
            } else {
                None
            };
            // One line per frame, so the log's 16 KiB keeps as many as std's text did.
            let name = name.as_deref().unwrap_or("<unknown>");
            let offset = address.wrapping_sub(base);
            let _ = writeln!(text, "{index:>4}: {name} ({image} + 0x{offset:x})");
        }
        text
    }

    /// A Rust name as std prints it (no hash); any other name as it is.
    fn demangle(name: &str) -> String {
        format!("{:#}", rustc_demangle::demangle(name))
    }
}

/// The calling thread's backtrace with this executable's frames named only
/// through `map` (the map file's bytes), as a stripped release binary names
/// them; `None` when `map` holds no slice for this executable.
#[cfg(target_os = "macos")]
pub fn force_capture_with_map(map: &[u8]) -> Option<String> {
    let map = crate::symbol_map::SymbolMap::parse(map, &mac::own_uuid()?)?;
    Some(mac::with_map(&map))
}
