//! `cmux-rd`: the remote desktop host engine (Linux: a virtual X display; macOS: the Mac's
//! own display) and its measurement tools. Subcommands:
//!   host     [--browser URL (Linux) [--browser-bin google-chrome] [--browser-cdp-port N]] --owner USER --token-fd N [--bind 127.0.0.1] [--single-tenant-overlay 1] [--display :99 | --display main|N on macOS] [--port 4103] [--max-fps 60] [--max-width PX (macOS)] [--codec openh264|x264|videotoolbox] [--openh264-lib PATH] [--profile high|baseline] [--upstream-record DIR]
//!   bench    --addr HOST:4103 --token-fd N [--carrier udp|stream] [--input key|click|scroll] [--samples 300] [--user USER] [--upstream mic|camera|screen] [--at X,Y] [--marker-origin X,Y] [--decoder videotoolbox|openh264 (macOS)] [--snapshot FILE.ppm] [--record FILE.h264]
//!   testapp  --display :99 --workload marker|text|motion|idle
//!   serve    one device hub session over the secure link, driven by the app in JSON lines on
//!            stdin and stdout (src/serve.rs); macOS and Linux
//!   connect  the viewer side of a hub session: bridges the pane's framed byte stream on a
//!            private Unix socket to the secure link (src/connect.rs)
//!   encode-selftest --codec videotoolbox|x264|openh264 --workload marker|text [--width 1920 --height 1080 --frames 300]
//!   openh264-install [--dir PATH]   the host enable flow's step: downloads Cisco's OpenH264
//!            from Cisco into the per-user data directory (pinned SHA-256) and prints its path
//! The host runs on Linux (X11) and macOS (ScreenCaptureKit, VideoToolbox, CGEvent); the test
//! app is Linux only. Design: plans/cmux-next/remote-desktop.md and remote-desktop-mac-host.md.
//! Wire: crate cmux-rd-proto.

#![cfg_attr(not(any(target_os = "linux", target_os = "macos")), allow(dead_code))]

mod args;
#[cfg(feature = "bench")]
mod bench;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod browser;
#[cfg(target_os = "linux")]
mod capture;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod carrier;
mod clock;
#[cfg(all(feature = "link", any(target_os = "linux", target_os = "macos")))]
mod connect;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod desktop;
mod encoder;
mod fdwait;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod host;
#[cfg(target_os = "linux")]
mod inject;
#[cfg(target_os = "linux")]
mod keymap;
#[cfg(target_os = "macos")]
mod mac;
mod marker;
mod selftest;
#[cfg(all(feature = "link", any(target_os = "linux", target_os = "macos")))]
mod serve;
#[cfg(target_os = "linux")]
mod shm;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod stream;
#[cfg(target_os = "linux")]
mod testapp;
mod token;
mod upstream;
#[cfg(all(target_os = "macos", feature = "bench"))]
mod vtdecode;
mod wire;
#[cfg(target_os = "linux")]
mod workload;
#[cfg(target_os = "linux")]
mod x11;
#[cfg(feature = "x264")]
mod x264;

pub type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    let Some(cmd) = argv.get(1) else {
        eprintln!(
            "usage: cmux-rd host|bench|testapp|encode-selftest|openh264-install [--key value ...]"
        );
        std::process::exit(2);
    };
    let opts = match args::Opts::parse(&argv[2..]) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    let result = match cmd.as_str() {
        #[cfg(any(target_os = "linux", target_os = "macos"))]
        "host" => host::run(&opts),
        #[cfg(feature = "bench")]
        "bench" => bench::run(&opts),
        #[cfg(target_os = "linux")]
        "testapp" => testapp::run(&opts),
        #[cfg(all(feature = "link", any(target_os = "linux", target_os = "macos")))]
        "serve" => serve::run(&opts),
        #[cfg(all(feature = "link", any(target_os = "linux", target_os = "macos")))]
        "connect" => connect::run(),
        "encode-selftest" => selftest::run(&opts),
        #[cfg(feature = "openh264")]
        "openh264-install" => encoder::install_openh264(&opts),
        other => Err(format!("unknown command {other}").into()),
    };
    if let Err(e) = result {
        eprintln!("cmux-rd {cmd}: {e}");
        std::process::exit(1);
    }
}
