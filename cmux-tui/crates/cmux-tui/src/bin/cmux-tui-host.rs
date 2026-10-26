//! The Windows per-terminal host process (cx-1vlzr).
//!
//! Since per-terminal hosts (cx-ko2e) every `tab create terminal` on Windows
//! re-exec's the 49 MB `cmux-tui.exe` as the host, and that host then calls
//! `CreateProcessW` to spawn the shell. Windows Defender's behavior monitor
//! scans the creating process's on-disk image on its first child, and the
//! cost scales with the image size (measured on the GPUI Windows VM: a 0.3 MB
//! creator spawns a shell in ~30 ms, a 50 MB creator in ~1.9 s, and the scan
//! re-runs for every fresh process of a large image, not once per file). The
//! old single daemon paid it once; a fresh 49 MB host per terminal paid
//! ~2.6 s each time.
//!
//! This binary is that host, built as its own small executable that links
//! only the terminal-host runtime (PTY I/O, VT parsing, the host protocol and
//! records), so the creator image Defender scans on each terminal is a few MB
//! instead of 49 MB. The daemon spawns this sibling binary (resolved next to
//! the running `cmux-tui.exe`, never from `PATH`) instead of re-exec'ing
//! itself; see `terminal_host_runtime::sys::windows::standby`.
//!
//! macOS runs every terminal host from it too (a content-addressed copy, see
//! `cmux_tui_platform::host_exe`): a host re-exec'd from the 66-85 MB
//! `cmux-tui` mapped its ~390 dylib images (CoreFoundation, CFNetwork,
//! Security, ...) and paid ~3.7 MB footprint per idle terminal for their dirty
//! data, malloc and page tables. The macOS build links it with
//! `-dead_strip_dylibs` (build.rs), so it loads only the dylibs it calls.
//! Linux keeps re-exec'ing `/proc/self/exe`.
//!
//! Its arguments are the host's bootstrap arguments, exactly what
//! `cmux-tui __terminal-host` forwards to the runtime: `--bootstrap-stdio
//! <pipe base>`. A leading `__terminal-host` is skipped, so a daemon passes
//! one argument list to either binary (and `pgrep -f __terminal-host` finds
//! both). The daemon drives it over the private bootstrap pipes named by its
//! last argument. `--version` prints `cmux-tui-host <build identity>`: a macOS
//! daemon runs this sibling only when it is the daemon's own build.

fn main() -> std::process::ExitCode {
    let mut args = std::env::args().skip(1).collect::<Vec<_>>();
    #[cfg(unix)]
    if args.first().map(String::as_str) == Some("--version") {
        println!("cmux-tui-host {}", cmux_build_identity::BUILD_IDENTITY);
        return std::process::ExitCode::SUCCESS;
    }
    // The holder of every PTY (cmux-holder) runs from this small binary too.
    #[cfg(unix)]
    if args.first().map(String::as_str) == Some("__holder") {
        return match cmux_holder::serve(&args[1..]) {
            Ok(()) => std::process::ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("cmux-tui-host holder: {error}");
                std::process::ExitCode::FAILURE
            }
        };
    }
    if args.first().map(String::as_str) == Some("__terminal-host") {
        args.remove(0);
    }
    match run(&args) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cmux-tui-host: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}

fn run(args: &[String]) -> anyhow::Result<()> {
    cmux_tui_core::terminal_host_runtime::enter_terminal_host_process()?;
    cmux_tui_core::terminal_host_runtime::serve_terminal_host_process(args)
}
