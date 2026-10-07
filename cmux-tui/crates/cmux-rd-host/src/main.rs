//! `cmux-rd`: the Linux remote desktop host engine (phase 1, virtual X display) and its
//! measurement tools. Subcommands:
//!   host     --owner USER --token-fd N [--bind 127.0.0.1] [--single-tenant-overlay 1] [--display :99] [--port 4103] [--max-fps 60] [--codec x264|openh264] [--openh264-lib PATH] [--profile high|baseline]
//!   bench    --addr HOST:4103 --token-fd N [--carrier udp|stream] [--samples 300] [--user USER]
//!   testapp  --display :99 --workload marker|text|motion|idle
//!   encode-selftest --codec videotoolbox|x264|openh264 --workload marker|text [--width 1920 --height 1080 --frames 300]
//! The host and the test app are Linux (X11); encode-selftest and bench also build on macOS.
//! Design: plans/cmux-next/remote-desktop.md. Wire: crate cmux-rd-proto.

// macOS builds only the encoder self-test and the bench; the host (X11) is Linux.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

mod args;
#[cfg(feature = "bench")]
mod bench;
#[cfg(target_os = "linux")]
mod capture;
mod clock;
mod encoder;
mod fdwait;
#[cfg(target_os = "linux")]
mod host;
#[cfg(target_os = "linux")]
mod inject;
#[cfg(target_os = "linux")]
mod keymap;
mod marker;
mod selftest;
#[cfg(target_os = "linux")]
mod shm;
#[cfg(target_os = "linux")]
mod stream;
#[cfg(target_os = "linux")]
mod testapp;
mod token;
mod wire;
#[cfg(target_os = "linux")]
mod workload;
#[cfg(feature = "x264")]
mod x264;

pub type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    let Some(cmd) = argv.get(1) else {
        eprintln!("usage: cmux-rd host|bench|testapp [--key value ...]");
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
        #[cfg(target_os = "linux")]
        "host" => host::run(&opts),
        #[cfg(feature = "bench")]
        "bench" => bench::run(&opts),
        #[cfg(target_os = "linux")]
        "testapp" => testapp::run(&opts),
        "encode-selftest" => selftest::run(&opts),
        other => Err(format!("unknown command {other}").into()),
    };
    if let Err(e) = result {
        eprintln!("cmux-rd {cmd}: {e}");
        std::process::exit(1);
    }
}
