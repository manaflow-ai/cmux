//! `cmux-rd`: the Linux remote desktop host engine (phase 1, virtual X display) and its
//! measurement tools. Subcommands:
//!   host     --owner USER --bind ADDR [--display :99] [--port 4103] [--max-fps 60] [--codec openh264|x264]
//!   bench    --addr HOST:4103 [--carrier udp|stream] [--samples 300] [--user USER]
//!   testapp  --display :99 --workload marker|text|motion|idle
//! Design: plans/cmux-next/remote-desktop.md. Wire: crate cmux-rd-proto.

mod args;
#[cfg(feature = "bench")]
mod bench;
mod capture;
mod clock;
mod convert;
mod encoder;
mod fdwait;
mod host;
mod inject;
mod keymap;
mod loss;
mod marker;
mod shm;
mod stream;
mod testapp;
mod wire;
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
        "host" => host::run(&opts),
        #[cfg(feature = "bench")]
        "bench" => bench::run(&opts),
        "testapp" => testapp::run(&opts),
        other => Err(format!("unknown command {other}").into()),
    };
    if let Err(e) = result {
        eprintln!("cmux-rd {cmd}: {e}");
        std::process::exit(1);
    }
}
