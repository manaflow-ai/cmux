//! coord-sim: synthetic coordinator chats and a multi-coordinator load driver.
//!
//! Leo (2026-11-19, paraphrased): simulate a load as heavy as his biggest coordinator chats, without his
//! real chats: many events arriving at once, several coordinators at the same time, and stress
//! everything. The shape comes from histograms only (`coord_shape_probe.py`, schema coord-shape.v1).
//!
//!   coord-sim gen     --shape FILE --seed N --coordinators N --scale X --out DIR   scripts and/or acpmux session dirs
//!   coord-sim agent   --script FILE --rate X                                       a stand-in ACP agent replaying one script
//!   coord-sim drive   --coordinators N --rate X --target acpmux|app-host|ios|relay  N coordinators at once, plus readers
//!   coord-sim degen   --case NAME ...                                              one degenerate case under load
//!   coord-sim surface --target app-host|relay|ios ...                             the app surfaces' load (surfaces/)
//!   coord-sim report  RUN_DIR                                                      one JSON of numbers (coord-sim-run.v1)

mod agent;
mod degen;
mod drive;
mod event;
mod fanin;
mod generate;
mod metrics;
mod rng;
mod shape;
mod surfaces;

fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (cmd, rest) = match args.split_first() {
        Some((c, r)) => (c.as_str(), r),
        None => ("help", &[][..]),
    };
    let result = match cmd {
        "gen" => generate::run(rest),
        "agent" => agent::run(rest),
        "fanin" => fanin::run(rest),
        "drive" => drive::run(rest),
        "degen" => degen::run(rest),
        "report" => metrics::run(rest),
        "surface" => surfaces::run(rest),
        "shape" => shape::Shape::load(rest.first().map(String::as_str)).map(|s| {
            println!("{} sessions, {} kinds", s.acpmux.sessions, s.kind_mix().len());
        }),
        _ => {
            eprintln!("{}", USAGE);
            Ok(())
        }
    };
    match result {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("coord-sim {cmd}: {e}");
            std::process::ExitCode::FAILURE
        }
    }
}

const USAGE: &str =
    "usage: coord-sim gen|agent|drive|degen|report|surface|shape ... (see src/main.rs)";

/// `--name value` from an argument list.
pub fn flag<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).map(String::as_str)
}

pub fn flag_or<T: std::str::FromStr>(args: &[String], name: &str, default: T) -> Result<T, String> {
    match flag(args, name) {
        Some(v) => v.parse().map_err(|_| format!("{name}: bad value {v:?}")),
        None => Ok(default),
    }
}
