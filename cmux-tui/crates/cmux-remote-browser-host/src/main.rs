//! `cmux-remote-browser-host`: serves remote browser tabs (remote-tab-r2.md).
//!
//! Modes (browser process; CEF helpers carry `--type=`):
//! - `--serve [--listen 127.0.0.1:4103] [--url URL | --ui-page | --picker-page] [--once] [--lifeline]`:
//!   one tab over cmux.rd/1 (service rb/1, stream carrier). macOS. Port 0 binds a free port;
//!   stdout gets one `{"listening":"ADDR"}` line. `--lifeline` is required: the per-launch secret is
//!   the first stdin line (a viewer's hello token must equal it; no secret, no start) and the host
//!   quits at stdin end of file. Loopback only.
//! - `--probe ADDR OUT_DIR [--keys N] [--idle-ms N] [--ui] [--pickers] [--stuck-key]`: the loopback viewer
//!   that measures a serving host (any platform). Its first stdin line is the host's secret.
//! - `--smoke OUT_DIR`: the shim's own capture proof. macOS.

/// `--probe ADDR OUT_DIR [--keys N] [--idle-ms N] [--ui] [--pickers] [--stuck-key]`.
fn probe(args: &[String]) -> Option<std::process::ExitCode> {
    use cmux_remote_browser_host::probe::{Plan, run};
    let i = args.iter().position(|a| a == "--probe")?;
    let usage = || {
        eprintln!(
            "usage: --probe ADDR OUT_DIR [--keys N] [--idle-ms N] [--ui] [--pickers] [--stuck-key] \
             (stdin: the host's secret as the first line)"
        );
        Some(std::process::ExitCode::from(2))
    };
    let (Some(addr), Some(out)) = (args.get(i + 1), args.get(i + 2)) else { return usage() };
    let Ok(addr) = addr.parse() else { return usage() };
    let mut plan = Plan::default();
    let value = |flag: &str| {
        args.iter()
            .position(|a| a == flag)
            .and_then(|j| args.get(j + 1))
            .and_then(|v| v.parse::<u64>().ok())
    };
    if let Some(keys) = value("--keys") {
        plan.keys = usize::try_from(keys).unwrap_or(plan.keys);
    }
    if let Some(ms) = value("--idle-ms") {
        plan.idle_ms = ms;
    }
    plan.ui = args.iter().any(|a| a == "--ui");
    plan.pickers = args.iter().any(|a| a == "--pickers");
    plan.stuck_key = args.iter().any(|a| a == "--stuck-key");
    // The host's per-launch secret: the first stdin line, never argv or env.
    let token = cmux_remote_browser_host::launch::read_secret(&mut std::io::stdin().lock());
    let report = run(addr, std::path::Path::new(out), plan, token.as_deref());
    println!(
        "{}",
        std::fs::read_to_string(std::path::Path::new(out).join("result.json")).unwrap_or_default()
    );
    Some(std::process::ExitCode::from(u8::from(report.error.is_some())))
}

#[cfg(target_os = "macos")]
fn main() -> std::process::ExitCode {
    use std::ffi::{CString, c_char, c_int};

    use cmux_remote_browser_host::ffi::{RbCallbacks, rb_shim_run};

    let all: Vec<String> = std::env::args().collect();
    let helper = all.iter().any(|a| a.starts_with("--type="));
    if !helper && let Some(code) = probe(&all) {
        return code;
    }
    let args: Vec<CString> =
        std::env::args().map(|a| CString::new(a).unwrap_or_default()).collect();
    let mut argv: Vec<*mut c_char> = args.iter().map(|a| a.as_ptr().cast_mut()).collect();
    if !helper && all.iter().any(|a| a == "--serve") {
        let flag = |f: &str| all.iter().position(|a| a == f).and_then(|i| all.get(i + 1)).cloned();
        let listen = flag("--listen").unwrap_or_else(|| "127.0.0.1:4103".into());
        let Some(listen) = listen
            .parse()
            .ok()
            .and_then(|a| cmux_remote_browser_host::launch::loopback_only(a).ok())
        else {
            eprintln!("--listen: expected a loopback ADDR:PORT (127.0.0.1 or ::1)");
            return std::process::ExitCode::from(2);
        };
        let lifeline = all.iter().any(|a| a == "--lifeline");
        // The app writes the per-launch secret as the lifeline's first line.
        // There is no open mode: without a secret the host does not start.
        let secret = if lifeline {
            cmux_remote_browser_host::launch::read_secret(&mut std::io::stdin().lock())
        } else {
            None
        };
        if secret.is_none() {
            eprintln!(
                "--serve needs --lifeline and the per-launch secret as the first stdin line \
                 (by hand: (printf '%s\\n' \"$SECRET\"; cat) | cmux-remote-browser-host --serve --lifeline)"
            );
            return std::process::ExitCode::from(2);
        }
        let opts = cmux_remote_browser_host::serve::Options {
            listen,
            url: flag("--url").unwrap_or_else(|| {
                if all.iter().any(|a| a == "--ui-page") {
                    cmux_remote_browser_host::probe::UI_PAGE.into()
                } else if all.iter().any(|a| a == "--picker-page") {
                    cmux_remote_browser_host::probe::PICKER_PAGE.into()
                } else {
                    cmux_remote_browser_host::smoke::PAGE.into()
                }
            }),
            once: all.iter().any(|a| a == "--once"),
            lifeline,
            secret,
        };
        let code = cmux_remote_browser_host::serve::run(&mut argv, opts);
        return std::process::ExitCode::from(u8::try_from(code).unwrap_or(1));
    }
    // `--smoke OUT_DIR` (browser process only; helpers carry --type=).
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
        on_dialog: None,
        on_dialog_reset: None,
        on_surface: None,
        on_surface_frame: None,
        on_loading_state: None,
        on_cursor: None,
        on_open_tab: None,
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
    let all: Vec<String> = std::env::args().collect();
    if let Some(code) = probe(&all) {
        return code;
    }
    eprintln!("cmux-remote-browser-host: the macOS host is the only host in r2 (Linux follows)");
    std::process::ExitCode::from(2)
}
