//! The `cmux-tui` executable. The program is the `cmux_tui` library
//! (src/main.rs).
//!
//! Windows with the `windows-thin-exe` feature (cx-w0uha): this executable is
//! a thin launcher that loads `cmux_tui.dll` from its own folder and calls its
//! entry point. Windows Defender scans every large executable image in a new
//! PowerShell 7 process's lineage, and the 41 MB daemon is the ancestor of
//! every terminal's shell (measured on the GPUI Windows VM: daemon -> host ->
//! pwsh 515 ms with a 41 MB daemon exe, 30 ms with a small exe that loads the
//! same code as a DLL). The DLL is loaded only by its full path in this
//! executable's folder, with the DLL's folder and System32 as its dependency
//! search path, never the default search order (no current directory, no
//! PATH).

// Threads start through cmux_threads (named, registered, at a declared QoS):
// plans/cmux-next/chrome-parity/p02-threads.md, tasks 213-218.
#![cfg_attr(not(test), deny(clippy::disallowed_methods))]

#[cfg(not(all(windows, feature = "windows-thin-exe")))]
fn main() -> std::process::ExitCode {
    cmux_tui::main()
}

#[cfg(all(windows, feature = "windows-thin-exe"))]
fn main() -> std::process::ExitCode {
    match thin::run() {
        Ok(code) => std::process::ExitCode::from(u8::try_from(code).unwrap_or(1)),
        Err(error) => {
            eprintln!("cmux-tui: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}

#[cfg(all(windows, feature = "windows-thin-exe"))]
mod thin {
    use std::os::windows::ffi::OsStrExt;
    use std::path::{Path, PathBuf};

    use windows_sys::Win32::System::LibraryLoader::{
        GetProcAddress, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR, LOAD_LIBRARY_SEARCH_SYSTEM32,
        LoadLibraryExW,
    };

    /// The library file name `cargo rustc -p cmux-tui --lib --crate-type
    /// cdylib` writes; packaging ships it under this name beside the exe.
    const DLL_NAME: &str = "cmux_tui.dll";
    const ENTRY: &[u8] = b"cmux_tui_dll_main\0";

    type Entry = unsafe extern "C" fn() -> i32;

    pub(crate) fn run() -> Result<i32, String> {
        let dll = dll_path()?;
        let wide: Vec<u16> = dll.as_os_str().encode_wide().chain(Some(0)).collect();
        // SAFETY: `wide` is a NUL-terminated absolute path. The flags restrict
        // the DLL's dependency search to its own folder and System32.
        let module = unsafe {
            LoadLibraryExW(
                wide.as_ptr(),
                std::ptr::null_mut(),
                LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32,
            )
        };
        if module.is_null() {
            return Err(format!(
                "cannot load {} ({}); reinstall cmux-tui",
                dll.display(),
                std::io::Error::last_os_error()
            ));
        }
        // SAFETY: `module` is a loaded module and ENTRY is NUL-terminated.
        let Some(entry) = (unsafe { GetProcAddress(module, ENTRY.as_ptr()) }) else {
            return Err(format!(
                "{} has no cmux_tui_dll_main ({}); reinstall cmux-tui",
                dll.display(),
                std::io::Error::last_os_error()
            ));
        };
        // SAFETY: cmux_tui_dll_main is `extern "C" fn() -> i32` in the
        // cmux_tui library (src/main.rs). The module stays loaded until exit.
        let entry: Entry = unsafe { std::mem::transmute::<_, Entry>(entry) };
        // SAFETY: called once, on the main thread, as the program's entry.
        Ok(unsafe { entry() })
    }

    fn dll_path() -> Result<PathBuf, String> {
        let exe = std::env::current_exe()
            .map_err(|error| format!("cannot find the cmux-tui executable path: {error}"))?;
        let dir = exe
            .parent()
            .filter(|dir| dir.is_absolute())
            .ok_or_else(|| format!("{} has no absolute folder", exe.display()))?;
        Ok(Path::new(dir).join(DLL_NAME))
    }
}
