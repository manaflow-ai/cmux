//! rdhost: measurement prototype for rdproto/0.
//!
//! Subcommands:
//!   testapp --display :99 --workload marker|text|motion|idle
//!   serve   --display :99 --port 7400 [--capture damage|poll] [--qp 24] [--threads N] [--testapp auto|external]
//!   client  --addr IP:7400 --workload W --samples 300 [--capture damage|poll] [--out FILE]

mod args;
mod capture;
mod client;
mod client_rx;
mod clock;
mod convert;
mod encoder;
mod fdwait;
mod inject;
mod marker;
mod proto;
mod serve;
mod session;
mod shm;
mod stats;
mod sysinfo;
mod testapp;
mod workload;
#[cfg(feature = "x264")]
mod x264;

pub type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let Some((cmd, rest)) = argv.split_first() else {
        usage();
    };
    let opts = match args::Opts::parse(rest) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("rdhost: {e}");
            usage();
        }
    };
    let result = match cmd.as_str() {
        "testapp" => testapp::run(&opts),
        "serve" => serve::run(&opts),
        "client" => client::run(&opts),
        _ => usage(),
    };
    if let Err(e) = result {
        eprintln!("rdhost {cmd}: {e}");
        std::process::exit(1);
    }
}

fn usage() -> ! {
    eprintln!(
        "usage:\n  rdhost testapp --display :99 --workload marker|text|motion|idle\n  \
         rdhost serve --display :99 --port 7400 [--capture damage|poll] [--max-fps 60] [--qp 24|--bitrate-kbps N] \
         [--threads N] [--usage screen|camera] [--codec openh264|x264] [--x264-preset P] [--x264-profile baseline|main|high] [--testapp auto|external] [--log-dir DIR]\n  \
         rdhost client --addr IP:7400 --workload W --samples 300 [--capture damage|poll] [--max-fps 60] [--out FILE]"
    );
    std::process::exit(2);
}
