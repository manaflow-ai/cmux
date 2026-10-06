//! `cmux-remote-browser-host`: serves remote browser tabs (remote-tab-r2.md).
//! r2 skeleton: the macOS binary runs the shim; the rd source and the
//! encoder are wired when lane 17's `cmux-encode` and `cmux-rd-engine` APIs
//! (remote-tab-r2.md section 5) land.

#[cfg(target_os = "macos")]
fn main() -> std::process::ExitCode {
    use std::ffi::{CString, c_char, c_int};

    use cmux_remote_browser_host::ffi::{RbCallbacks, rb_shim_run};

    let args: Vec<CString> =
        std::env::args().map(|a| CString::new(a).unwrap_or_default()).collect();
    let mut argv: Vec<*mut c_char> = args.iter().map(|a| a.as_ptr().cast_mut()).collect();
    // `--smoke OUT_DIR` (browser process only; helpers carry --type=).
    let helper = std::env::args().any(|a| a.starts_with("--type="));
    let smoke_out = if helper {
        None
    } else {
        let a: Vec<String> = std::env::args().collect();
        a.iter()
            .position(|x| x == "--smoke")
            .and_then(|i| a.get(i + 1))
            .map(std::path::PathBuf::from)
    };
    if let Some(out) = smoke_out {
        let code = cmux_remote_browser_host::smoke::run(&mut argv, out);
        return std::process::ExitCode::from(u8::try_from(code).unwrap_or(1));
    }
    let cache = std::env::var("CMUX_RB_CACHE_DIR").unwrap_or_else(|_| "/tmp/cmux-rb-host".into());
    let cache = CString::new(cache).unwrap_or_default();
    let callbacks = RbCallbacks {
        context: std::ptr::null_mut(),
        on_ready: None,
        on_tab_created: None,
        on_tab_closed: None,
        on_title: None,
        on_url: None,
        on_frame: None,
        on_key_unhandled: None,
        on_context_menu: None,
        on_popup_menu: None,
        on_needs_begin_frames: None,
    };
    // SAFETY: argv and the strings outlive the call; the callbacks are valid.
    let code = unsafe {
        rb_shim_run(
            c_int::try_from(argv.len()).unwrap_or(0),
            argv.as_mut_ptr(),
            cache.as_ptr(),
            0,
            &callbacks,
        )
    };
    std::process::ExitCode::from(u8::try_from(code).unwrap_or(1))
}

#[cfg(not(target_os = "macos"))]
fn main() -> std::process::ExitCode {
    eprintln!("cmux-remote-browser-host: the macOS host is the only host in r2 (Linux follows)");
    std::process::ExitCode::from(2)
}
