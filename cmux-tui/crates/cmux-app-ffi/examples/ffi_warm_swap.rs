//! Opt-in runtime proof for the app FFI warm-swap artifact.
//!
//! This intentionally loads the published `libcmux_app_ffi.dylib` and calls
//! the ABI entry point the app uses. It is a diagnostic experiment; current app
//! packaging and defaults are unchanged.

use std::env;
#[cfg(target_os = "macos")]
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::path::PathBuf;

#[cfg(target_os = "macos")]
#[link(name = "System")]
unsafe extern "C" {
    fn dlopen(path: *const c_char, flags: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
    fn dlclose(handle: *mut c_void) -> c_int;
    fn dlerror() -> *const c_char;
}

#[cfg(target_os = "macos")]
const RTLD_NOW: c_int = 2;

fn usage() -> ! {
    eprintln!("usage: ffi_warm_swap <libcmux_app_ffi.dylib> [--expect-abi N]");
    std::process::exit(2);
}

#[cfg(target_os = "macos")]
fn last_error() -> String {
    // SAFETY: dlerror returns a process-owned NUL-terminated diagnostic or null.
    let ptr = unsafe { dlerror() };
    if ptr.is_null() {
        "unknown dynamic loader error".to_owned()
    } else {
        // SAFETY: the loader owns a valid diagnostic string until the next call.
        unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
    }
}

#[cfg(target_os = "macos")]
fn run(path: PathBuf, expected: Option<u32>) -> Result<(), String> {
    type AbiVersion = unsafe extern "C" fn() -> u32;
    let c_path = CString::new(path.as_os_str().as_encoded_bytes())
        .map_err(|_| "library path contains NUL".to_owned())?;
    let symbol = CString::new("cmux_layout_reducer_ffi_abi_version").expect("literal has no NUL");
    // SAFETY: c_path and symbol are NUL-terminated and remain alive for each call.
    let handle = unsafe { dlopen(c_path.as_ptr(), RTLD_NOW) };
    if handle.is_null() {
        return Err(format!("dlopen {}: {}", path.display(), last_error()));
    }
    // SAFETY: handle is a successful dlopen result; the symbol is converted to
    // the C ABI function declared by cmux-layout-reducer-ffi's public header.
    let raw = unsafe { dlsym(handle, symbol.as_ptr()) };
    if raw.is_null() {
        let error = format!("dlsym cmux_layout_reducer_ffi_abi_version: {}", last_error());
        unsafe { dlclose(handle) };
        return Err(error);
    }
    // SAFETY: the release smoke artifact exports this exact extern "C" symbol.
    let actual = unsafe { std::mem::transmute::<*mut c_void, AbiVersion>(raw)() };
    // SAFETY: handle was opened above and is no longer needed.
    unsafe { dlclose(handle) };
    println!("loaded {}: cmux_layout_reducer_ffi_abi_version={actual}", path.display());
    if let Some(expected) = expected {
        if actual != expected {
            return Err(format!("ABI mismatch: loaded {actual}, expected {expected}"));
        }
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn run(_path: PathBuf, _expected: Option<u32>) -> Result<(), String> {
    Err("ffi_warm_swap requires macOS (the app FFI artifact is a macOS dylib)".to_owned())
}

fn main() {
    let mut args = env::args().skip(1);
    let path = args.next().map(PathBuf::from).unwrap_or_else(|| usage());
    let mut expected = None;
    while let Some(arg) = args.next() {
        if arg != "--expect-abi" {
            usage();
        }
        expected =
            Some(args.next().and_then(|value| value.parse().ok()).unwrap_or_else(|| usage()));
    }
    if let Err(error) = run(path, expected) {
        eprintln!("ffi_warm_swap: {error}");
        std::process::exit(3);
    }
}
