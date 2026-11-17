//! `cmux-rd`: the remote desktop host engine, as a library: the `cmux-rd` binary (main.rs)
//! and, on macOS, `cmux rd ...` in the cmux binary run [`run_cli`]. The host engine (Linux: a virtual X display; macOS: the Mac's
//! own display) and its measurement tools. Subcommands:
//!   host     --listen-systemd --peer-uid 0 [--display :99] [--xauthority PATH] [--idle-exit-s 120] [--codec openh264] [--no-udp-link] [--link-stun HOST:PORT,...]
//!            (Linux, the production Cloud mode: the socket comes from systemd; src/systemd.rs;
//!            media moves to a UDP link when the viewer offers one: src/hybrid.rs)
//!   host     [--browser URL (Linux) [--browser-bin google-chrome] [--browser-cdp-port N]] --owner USER --token-fd N [--bind 127.0.0.1] [--single-tenant-overlay 1] [--display :99 | --display main|N on macOS] [--port 4103] [--max-fps N (default: the display's refresh rate, else 60)] [--input-frame-now 1] [--max-width PX (macOS)] [--codec auto|vaapi|openh264|x264|videotoolbox (auto: VAAPI on a GPU, else openh264)] [--openh264-lib PATH] [--profile high|baseline] [--upstream-record DIR]
//!            [--source synthetic|synthetic-still|synthetic-tick [--synthetic-size WxH]] (macOS bench builds, `host` and `serve`:
//!            a generated picture with the marker instead of the display; no grants needed; src/synthetic.rs)
//!   bench    --addr HOST:4103 --token-fd N [--carrier udp|stream] [--input key|click|scroll|none] [--samples 300] [--duration-s 30 (none)] [--user USER] [--upstream mic|camera|screen] [--at X,Y] [--marker-origin X,Y] [--decoder videotoolbox|openh264 (macOS)] [--snapshot FILE.ppm] [--record FILE.h264] [--present :N (Linux: draws each decoded frame in a window on that X display)]
//!   observe  --mode passive --pid VIEWER_PID --window CGWINDOW_ID --start-file PATH --marker-origin X,Y --cell-size N [--expected-nonce 32 lowercase hex] [--duration-s 10] [--interval-ms 1000]
//!   testapp  --display :99 --workload marker|text|motion|idle
//!   serve    one device hub session over the secure link, driven by the app in JSON lines on
//!            stdin and stdout (src/serve.rs); macOS and Linux
//!   connect  the viewer side of a hub session: bridges the pane's framed byte stream on a
//!            private Unix socket to the secure link (src/connect.rs)
//!   view     [DEVICE] [--scope full|view] (Linux) view and control another of your devices
//!            through the device hub, in an X11 window (src/view/)
//!   linux-host enable|share on|off|run|requests|approve|deny|status   (Linux) this desktop as a
//!            device hub screen host a Mac views: its own device key, the hub link and
//!            consent, driving `serve` per approved session (src/linux_host/)
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
mod clock;
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
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod selftest;
#[cfg(all(feature = "link", any(target_os = "linux", target_os = "macos")))]
mod serve;
#[cfg(target_os = "linux")]
mod shm;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod stream;
#[cfg(feature = "bench")]
mod synthetic;
#[cfg(target_os = "linux")]
mod systemd;
#[cfg(target_os = "linux")]
mod testapp;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod token;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod upstream;
#[cfg(all(feature = "link", any(target_os = "linux", target_os = "macos")))]
mod viewer_hop;
// `cmux-rd view`: the Linux viewer of a device hub session (Windows follows from the same module).
#[cfg(all(feature = "link", feature = "openh264", target_os = "linux"))]
mod view;
#[cfg(all(target_os = "macos", feature = "bench"))]
mod vtdecode;
#[cfg(windows)]
mod windows;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod wire;
#[cfg(target_os = "linux")]
mod workload;
#[cfg(target_os = "linux")]
mod x11;
#[cfg(feature = "x264")]
mod x264;

pub type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

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

pub fn run_cli(args: &[String]) -> i32 {
    let Some(cmd) = args.first() else {
        eprintln!(
            "usage: cmux-rd host|bench|observe|observe-cpu|testapp|serve|connect|view|permissions|request-permission|linux-host|encode-selftest|openh264-install [--key value ...]"
        );
        return 2;
    };
    // Subcommands and positional words of its own (`share on`, `approve SESSION`).
    #[cfg(all(feature = "link", target_os = "linux"))]
    if cmd == "linux-host" {
        return linux_host::run_cli(&args[1..]);
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
        other => Err(format!("unknown command {other}").into()),
    };
    match result {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("cmux-rd {cmd}: {e}");
            1
        }
    }
}
