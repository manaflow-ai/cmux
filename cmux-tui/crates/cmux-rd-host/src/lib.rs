//! `cmux-rd`: the remote desktop host engine, as a library: the `cmux-rd` binary (main.rs)
//! and, on macOS, `cmux rd ...` in the cmux binary run [`run_cli`]. The host engine (Linux: a virtual X display; macOS: the Mac's
//! own display) and its measurement tools. Subcommands:
//!   host     --listen-systemd --peer-uid 0 [--display :99] [--xauthority PATH] [--idle-exit-s 120] [--codec openh264] [--no-udp-link] [--link-stun HOST:PORT,...]
//!            (Linux, the production Cloud mode: the socket comes from systemd; src/systemd.rs;
//!            media moves to a UDP link when the viewer offers one: src/hybrid.rs)
//!   host     [--browser URL (Linux) [--browser-bin google-chrome] [--browser-cdp-port N]] --owner USER --token-fd N [--bind 127.0.0.1] [--single-tenant-overlay 1] [--display :99 | --display main|N on macOS] [--monitor N | --window ID (Linux X11: one monitor, or one X window followed through moves; ends when it is closed or resized)] [--port 4103] [--max-fps N (default: the display's refresh rate, else 60)] [--input-frame-now 1] [--rtt-tail-probe 1] [--resolution-ladder 1 [--max-qp N (default 40)]] [--max-width PX (macOS)] [--codec auto|vaapi|openh264|x264|videotoolbox (auto: VAAPI on a GPU, else openh264)] [--openh264-lib PATH] [--profile high|baseline] [--upstream-record DIR]
//!            [--source synthetic|synthetic-still|synthetic-tick [--synthetic-size WxH] [--synthetic-scene bars|text|noise|churn]] (macOS bench builds, `host` and `serve`:
//!            a generated picture with the marker instead of the display; no grants needed; src/synthetic.rs)
//!   bench    --addr HOST:4103 --token-fd N [--carrier udp|stream] [--input key|click|scroll|none] [--samples 300] [--duration-s 30 (none)] [--marker-log 1 (none: each marker change with its decode time)] [--rtt-nack-retry 1] [--user USER] [--upstream mic|camera|screen] [--at X,Y] [--marker-origin X,Y] [--caps video.scaled (read a smaller picture scaled up to the stream)] [--decoder videotoolbox|openh264 (macOS)] [--snapshot FILE.ppm] [--record FILE.h264] [--present :N (Linux: draws each decoded frame in a window on that X display)]
//!   observe  --mode passive --pid VIEWER_PID --window CGWINDOW_ID --start-file PATH --marker-origin X,Y --cell-size N [--expected-nonce 32 lowercase hex] [--duration-s 10] [--interval-ms 1000]
//!   testapp  --display :99 --workload marker|text|motion|idle [--geometry WxH+X+Y (a titled window there, not full screen)]
//!   serve    one device hub session over the secure link, driven by the app in JSON lines on
//!            stdin and stdout (src/serve.rs); macOS and Linux
//!   connect  the viewer side of a hub session: bridges the pane's framed byte stream on a
//!            private Unix socket to the secure link (src/connect.rs)
//!   view     [DEVICE] [--scope full|view] (Linux) view and control another of your devices
//!            through the device hub, in an X11 window (src/view/)
//!   linux-host enable|share on|off|run|requests|approve|deny|status   (Linux) this desktop as a
//!            device hub screen host a Mac views: its own device key, the hub link and
//!            consent, driving `serve` per approved session (src/linux_host/)
//!   windows-host enable|run|status|share off   (Windows) this PC on the device hub as a
//!            `windows` device with the same hub client (src/screen_host/, src/windows_host.rs);
//!            it lists and captures, and serves no session until `serve` has a Windows port
//!   permissions  read-only Screen Recording and Accessibility snapshot as JSON (macOS)
//!   request-permission screen-recording|accessibility   macOS's prompt for that one grant,
//!            then the snapshot (src/permissions.rs; the Screen Sharing helper's)
//!   encode-selftest --codec videotoolbox|vaapi|x264|openh264 --workload marker|text [--width 1920 --height 1080 --frames 300]
//!   openh264-install [--dir PATH]   the host enable flow's step: downloads Cisco's OpenH264
//!            from Cisco into the per-user data directory (pinned SHA-256) and prints its path
//! The host runs on Linux (X11; Wayland view-only through the ScreenCast portal with feature
//! `portal`: src/portal.rs) and macOS (ScreenCaptureKit, VideoToolbox, CGEvent); the test
//! app is Linux only. Design: plans/cmux-next/remote-desktop.md and remote-desktop-mac-host.md.
//! Wire: crate cmux-rd-proto.

#![cfg_attr(not(any(target_os = "linux", target_os = "macos", windows)), allow(dead_code))]
// Edition 2021 leaves `std::env::set_var`/`remove_var` safe to call; they race every concurrent
// read of the environment (a C library's `getenv` too), so each call needs an `unsafe` block and
// an argument that no other thread exists, as in edition 2024.
#![deny(deprecated_safe_2024)]

mod args;
#[cfg(all(feature = "bench", any(target_os = "linux", target_os = "macos")))]
mod bench;
#[cfg(target_os = "linux")]
mod browser;
#[cfg(target_os = "linux")]
mod capture;
mod capture_backend;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod carrier;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod clipboard;
mod clock;
#[cfg(all(target_os = "macos", feature = "computer-use"))]
pub mod computer_use_worker;
#[cfg(all(feature = "link", any(target_os = "linux", target_os = "macos")))]
mod connect;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod cursor;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod desktop;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod encode_thread;
mod encoder;
#[cfg(all(feature = "bench", any(target_os = "linux", target_os = "macos")))]
mod eval;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod fdwait;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod host;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod hybrid;
#[cfg(target_os = "linux")]
mod inject;
#[cfg(target_os = "linux")]
mod keymap;
#[cfg(all(feature = "link", target_os = "linux"))]
mod linux_host;
#[cfg(target_os = "macos")]
mod mac;
mod marker;
#[cfg(all(feature = "bench", any(target_os = "linux", target_os = "macos")))]
mod observe;
mod permissions;
#[cfg(feature = "bench")]
mod process_cpu;
// Wayland sharing: the portal handshakes and grant (`portal-dbus`) and the PipeWire capture
// (`portal`), chosen by the capture-backend seam in desktop.rs.
#[cfg(all(feature = "portal", target_os = "linux"))]
#[allow(dead_code)]
mod pipewire_capture;
#[cfg(all(feature = "portal-dbus", target_os = "linux"))]
#[allow(dead_code)]
mod portal;
#[cfg(all(feature = "bench", target_os = "linux"))]
mod present;
#[cfg(all(feature = "bench", any(target_os = "linux", target_os = "macos")))]
mod scaled;
// The device hub client of the desktop hosts (`linux-host`, `windows-host`).
#[cfg(any(all(feature = "link", target_os = "linux"), windows))]
mod screen_host;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod selftest;
#[cfg(all(feature = "link", any(target_os = "linux", target_os = "macos")))]
mod serve;
#[cfg(all(feature = "link", any(target_os = "linux", target_os = "macos")))]
mod serve_wish;
#[cfg(target_os = "linux")]
mod shm;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod stream;
#[cfg(feature = "bench")]
mod synthetic;
#[cfg(target_os = "linux")]
mod systemd;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod test_loss;
#[cfg(target_os = "linux")]
mod testapp;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod token;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod upstream;
// `cmux-rd view`: the Linux viewer of a device hub session (Windows follows from the same module).
#[cfg(all(feature = "link", feature = "openh264", target_os = "linux"))]
mod view;
#[cfg(all(target_os = "macos", feature = "bench"))]
mod vtdecode;
#[cfg(windows)]
mod windows;
#[cfg(windows)]
mod windows_host;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod wire;
#[cfg(target_os = "linux")]
mod workload;
#[cfg(target_os = "linux")]
mod x11;
#[cfg(target_os = "linux")]
mod x11_view;
#[cfg(target_os = "linux")]
mod x11_window;
#[cfg(feature = "x264")]
mod x264;

pub type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// cmux Computer Use's screenshots through ScreenCaptureKit, for the helper's Computer Use worker
/// mode to hand to the engine's macOS desktop (`src/mac/cu_host.rs`).
#[cfg(all(target_os = "macos", feature = "computer-use"))]
pub use mac::cu_host::computer_use_host_services;

/// Runs one `cmux-rd` subcommand (`args[0]`) with its options. Returns the process exit
/// code: 0 on success, 1 when the command failed, 2 for a usage error.
/// Whether this start is LaunchServices opening the Screen Sharing helper app by itself (macOS's
/// "Quit & Reopen" after a grant, or a double click): no arguments, or only the old
/// process-serial-number one, from an executable inside an app bundle. There is no app driving
/// it then, so the executable exits at once (main.rs); the next session starts a fresh helper.
pub fn is_launch_services_open(args: &[String], executable: &std::path::Path) -> bool {
    let inside_bundle = executable
        .parent()
        .filter(|dir| dir.ends_with("Contents/MacOS"))
        .and_then(|dir| dir.parent()?.parent())
        .and_then(|bundle| bundle.extension())
        .is_some_and(|extension| extension == "app");
    inside_bundle && args.iter().all(|arg| arg.starts_with("-psn_"))
}

/// The process environment [`run_cli`] relies on, written once at start: `host`/`serve
/// --xauthority PATH` becomes `XAUTHORITY` for every X connection and child, and `host
/// --listen-systemd` takes systemd's `LISTEN_*` variables and clears them so no child inherits
/// them. `run_cli` itself never writes the environment.
///
/// # Safety
///
/// No other thread may exist yet (call it first in `main`): `set_var` and `remove_var` race
/// any concurrent read of the environment, a C library's `getenv` included.
pub unsafe fn prepare_process_env(args: &[String]) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        let Some(cmd) = args.first().filter(|cmd| matches!(cmd.as_str(), "host" | "serve")) else {
            return Ok(());
        };
        // `run_cli` reports a parse error itself.
        let Ok(opts) = args::Opts::parse(&args[1..]) else {
            return Ok(());
        };
        if let Some(path) = opts.get("xauthority") {
            std::fs::File::open(path)
                .map_err(|e| format!("cmux-rd {cmd}: --xauthority {path}: {e}"))?;
            // SAFETY: the caller's: no other thread exists.
            unsafe { std::env::set_var("XAUTHORITY", path) };
        }
        if cmd == "host" && opts.flag("listen-systemd") {
            // SAFETY: as above.
            unsafe { systemd::take_env() };
        }
    }
    #[cfg(not(target_os = "linux"))]
    let _ = args;
    Ok(())
}

const USAGE: &str = "usage: cmux-rd host|bench|observe|observe-cpu|testapp|serve|connect|view|permissions|request-permission|linux-host|windows-host|encode-selftest|openh264-install [--key value ...]";

/// Commands the usage line names that a build may leave out (by feature or platform).
const KNOWN_COMMANDS: &[&str] = &[
    "host",
    "bench",
    "observe",
    "observe-cpu",
    "testapp",
    "serve",
    "connect",
    "view",
    "permissions",
    "request-permission",
    "linux-host",
    "windows-host",
    "windows-selftest",
    "encode-selftest",
    "openh264-install",
];

/// A command this build has no handler for: say whether it is a real command left out
/// of this build (release builds ship without `bench`) or a typo.
fn unknown_command(cmd: &str) -> String {
    if !KNOWN_COMMANDS.contains(&cmd) {
        return format!("unknown command {cmd}\n{USAGE}");
    }
    let bench_only = matches!(cmd, "bench" | "observe" | "observe-cpu");
    if bench_only && !cfg!(feature = "bench") {
        return "not in this build: release builds of cmux-rd ship without the bench feature; \
                build one with `cargo build --release --features bench` in cmux-tui/crates/cmux-rd-host"
            .to_string();
    }
    let link_only = matches!(cmd, "serve" | "connect" | "view" | "linux-host");
    if link_only && !cfg!(feature = "link") {
        return "not in this build: it needs the link feature \
                (`cargo build --release --features link`)"
            .to_string();
    }
    if cmd == "view" && cfg!(target_os = "linux") && !cfg!(feature = "openh264") {
        return "not in this build: it needs the openh264 feature \
                (`cargo build --release --features link,openh264`)"
            .to_string();
    }
    if cmd == "openh264-install" && !cfg!(feature = "openh264") {
        return "not in this build: it needs the openh264 feature \
                (`cargo build --release --features openh264`)"
            .to_string();
    }
    format!("not in this build: cmux-rd {cmd} is not built for {}", std::env::consts::OS)
}

pub fn run_cli(args: &[String]) -> i32 {
    let Some(cmd) = args.first() else {
        eprintln!("{USAGE}");
        return 2;
    };
    // The Computer Use worker the cmux-tui daemon starts on a Mac with no cmux Remote: its stdin
    // and stdout are the daemon's control channel, so nothing else may print there.
    #[cfg(all(target_os = "macos", feature = "computer-use"))]
    if cmd == computer_use_worker::MODE {
        return computer_use_worker::run(&args[1..]);
    }
    if matches!(cmd.as_str(), "-h" | "--help" | "help") {
        println!("{USAGE}");
        return 0;
    }
    // Subcommands and positional words of its own (`share on`, `approve SESSION`).
    #[cfg(all(feature = "link", target_os = "linux"))]
    if cmd == "linux-host" {
        return linux_host::run_cli(&args[1..]);
    }
    #[cfg(windows)]
    if cmd == "windows-host" {
        return windows_host::run_cli(&args[1..]);
    }
    #[cfg(all(feature = "link", feature = "openh264", target_os = "linux"))]
    if cmd == "view" {
        return view::run_cli(&args[1..]);
    }
    if cmd == "permissions" && args.len() != 1 {
        eprintln!("cmux-rd permissions takes no arguments");
        return 2;
    }
    if cmd == "request-permission" {
        let Some(grant) = (args.len() == 2).then(|| permissions::Grant::parse(&args[1])).flatten()
        else {
            eprintln!("usage: cmux-rd request-permission screen-recording|accessibility");
            return 2;
        };
        return match permissions::run_request(grant) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("cmux-rd request-permission: {e}");
                1
            }
        };
    }
    let opts = match args::Opts::parse(&args[1..]) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("{e}");
            return 2;
        }
    };
    // `--source synthetic` (measurement only): a generated picture instead of the display.
    if matches!(cmd.as_str(), "host" | "serve") {
        #[cfg(feature = "bench")]
        let source = synthetic::configure(&opts);
        #[cfg(not(feature = "bench"))]
        let source = match opts.get("source") {
            None | Some("screen") => Ok(()),
            Some(other) => Err(format!("--source {other} needs a bench build of cmux-rd")),
        };
        if let Err(e) = source {
            eprintln!("cmux-rd {cmd}: {e}");
            return 2;
        }
    }
    let result = match cmd.as_str() {
        #[cfg(any(target_os = "linux", target_os = "macos"))]
        "host" => host::run(&opts),
        #[cfg(windows)]
        "host" => windows::run(&opts),
        #[cfg(windows)]
        "windows-selftest" => windows::selftest(&opts),
        #[cfg(all(feature = "bench", any(target_os = "linux", target_os = "macos")))]
        "bench" => bench::run(&opts),
        #[cfg(all(target_os = "macos", feature = "bench"))]
        "observe" => mac::observe::run(&opts),
        #[cfg(all(target_os = "macos", feature = "bench"))]
        "observe-cpu" => mac::cpu::run(&opts),
        #[cfg(target_os = "linux")]
        "testapp" => testapp::run(&opts),
        #[cfg(all(feature = "link", any(target_os = "linux", target_os = "macos")))]
        "serve" => serve::run(&opts),
        #[cfg(all(feature = "link", any(target_os = "linux", target_os = "macos")))]
        "connect" => connect::run(),
        "permissions" => permissions::run(),
        #[cfg(any(target_os = "linux", target_os = "macos"))]
        "encode-selftest" => selftest::run(&opts),
        #[cfg(feature = "openh264")]
        "openh264-install" => encoder::install_openh264(&opts),
        other => Err(unknown_command(other).into()),
    };
    match result {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("cmux-rd {cmd}: {e}");
            1
        }
    }
}

#[cfg(test)]
mod cli_tests {
    use super::*;

    #[test]
    fn help_prints_usage_and_succeeds() {
        for flag in ["-h", "--help", "help"] {
            assert_eq!(run_cli(&[flag.to_string()]), 0, "{flag}");
        }
    }

    #[test]
    fn a_typo_is_an_unknown_command_with_usage() {
        let msg = unknown_command("bnech");
        assert!(msg.starts_with("unknown command bnech"), "{msg}");
        assert!(msg.contains(USAGE), "{msg}");
    }

    #[test]
    fn a_left_out_command_says_it_is_not_in_this_build() {
        let msg = unknown_command("bench");
        assert!(msg.starts_with("not in this build"), "{msg}");
        if !cfg!(feature = "bench") {
            assert!(msg.contains("--features bench"), "{msg}");
        }
        assert!(unknown_command("windows-host").starts_with("not in this build"));
    }

    #[test]
    fn every_usage_command_is_known() {
        let list = USAGE.trim_start_matches("usage: cmux-rd ").split(' ').next().unwrap();
        for cmd in list.split('|') {
            assert!(KNOWN_COMMANDS.contains(&cmd), "{cmd}");
        }
    }
}
