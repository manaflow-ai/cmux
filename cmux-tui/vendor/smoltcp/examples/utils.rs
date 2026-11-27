#![allow(dead_code)]

#[cfg(feature = "log")]
use env_logger::Builder;
use getopts::{Matches, Options};
#[cfg(feature = "log")]
use log::{Level, LevelFilter, trace};
use std::env;
use std::fs::File;
use std::io::{self, Write};
use std::process;
use std::str::{self, FromStr};
use std::time::{SystemTime, UNIX_EPOCH};

#[cfg(feature = "phy-tuntap_interface")]
use smoltcp::phy::TunTapInterface;
use smoltcp::phy::{Device, FaultInjector, Medium, Tracer};
use smoltcp::phy::{PcapMode, PcapWriter};
use smoltcp::time::{Duration, Instant};

#[cfg(feature = "log")]
pub fn setup_logging_with_clock<F>(filter: &str, since_startup: F)
where
    F: Fn() -> Instant + Send + Sync + 'static,
{
    Builder::new()
        .format(move |buf, record| {
            let elapsed = since_startup();
            let timestamp = format!("[{elapsed}]");
            if record.target().starts_with("smoltcp::") {
                writeln!(
                    buf,
                    "\x1b[0m{} ({}): {}\x1b[0m",
                    timestamp,
                    record.target().replace("smoltcp::", ""),
                    record.args()
                )
            } else if record.level() == Level::Trace {
                let message = format!("{}", record.args());
                writeln!(
                    buf,
                    "\x1b[37m{} {}\x1b[0m",
                    timestamp,
                    message.replace('\n', "\n             ")
                )
            } else {
                writeln!(
                    buf,
                    "\x1b[32m{} ({}): {}\x1b[0m",
                    timestamp,
                    record.target(),
                    record.args()
                )
            }
        })
        .filter(None, LevelFilter::Trace)
        .parse_filters(filter)
        .parse_env("RUST_LOG")
        .init();
}

#[cfg(feature = "log")]
pub fn setup_logging(filter: &str) {
    setup_logging_with_clock(filter, Instant::now)
}

pub fn create_options() -> (Options, Vec<&'static str>) {
    let mut opts = Options::new();
    opts.optflag("h", "help", "print this help menu");
    (opts, Vec::new())
}

pub fn parse_options(options: &Options, free: Vec<&str>) -> Matches {
    match options.parse(env::args().skip(1)) {
        Err(err) => {
            println!("{err}");
            process::exit(1)
        }
        Ok(matches) => {
            if matches.opt_present("h") || matches.free.len() != free.len() {
                let brief = format!(
                    "Usage: {} [OPTION]... {}",
                    env::args().next().unwrap(),
                    free.join(" ")
                );
                print!("{}", options.usage(&brief));
                process::exit((matches.free.len() != free.len()) as _);
            }
            matches
        }
    }
}

pub fn add_tuntap_options(opts: &mut Options, _free: &mut [&str]) {
    opts.optopt("", "tun", "TUN interface to use", "tun0");
    opts.optopt("", "tap", "TAP interface to use", "tap0");
}

#[cfg(feature = "phy-tuntap_interface")]
pub fn parse_tuntap_options(matches: &mut Matches) -> TunTapInterface {
    let tun = matches.opt_str("tun");
    let tap = matches.opt_str("tap");
    match (tun, tap) {
        (Some(tun), None) => TunTapInterface::new(&tun, Medium::Ip).unwrap(),
        (None, Some(tap)) => TunTapInterface::new(&tap, Medium::Ethernet).unwrap(),
        _ => panic!("You must specify exactly one of --tun or --tap"),
    }
}

pub fn add_middleware_options(opts: &mut Options, _free: &mut [&str]) {
    opts.optopt("", "pcap", "Write a packet capture file", "FILE");
    opts.optopt(
        "",
        "drop-chance",
        "Chance of dropping a packet (%)",
        "CHANCE",
    );
    opts.optopt(
        "",
        "corrupt-chance",
        "Chance of corrupting a packet (%)",
        "CHANCE",
    );
    opts.optopt(
        "",
        "size-limit",
        "Drop packets larger than given size (octets)",
        "SIZE",
    );
    opts.optopt(
        "",
        "tx-rate-limit",
        "Drop packets after transmit rate exceeds given limit \
                                      (packets per interval)",
        "RATE",
    );
    opts.optopt(
        "",
        "rx-rate-limit",
        "Drop packets after transmit rate exceeds given limit \
                                      (packets per interval)",
        "RATE",
    );
    opts.optopt(
        "",
        "shaping-interval",
        "Sets the interval for rate limiting (ms)",
        "RATE",
    );
}

pub fn parse_middleware_options<D>(
    matches: &mut Matches,
    device: D,
    loopback: bool,
) -> FaultInjector<Tracer<PcapWriter<D, Box<dyn io::Write>>>>
where
    D: Device,
{
    let drop_chance = matches
        .opt_str("drop-chance")
        .map(|s| u8::from_str(&s).unwrap())
        .unwrap_or(0);
    let corrupt_chance = matches
        .opt_str("corrupt-chance")
        .map(|s| u8::from_str(&s).unwrap())
        .unwrap_or(0);
    let size_limit = matches
        .opt_str("size-limit")
        .map(|s| usize::from_str(&s).unwrap())
        .unwrap_or(0);
    let tx_rate_limit = matches
        .opt_str("tx-rate-limit")
        .map(|s| u64::from_str(&s).unwrap())
        .unwrap_or(0);
    let rx_rate_limit = matches
        .opt_str("rx-rate-limit")
        .map(|s| u64::from_str(&s).unwrap())
        .unwrap_or(0);
    let shaping_interval = matches
        .opt_str("shaping-interval")
        .map(|s| u64::from_str(&s).unwrap())
        .unwrap_or(0);

    let pcap_writer: Box<dyn io::Write> = match matches.opt_str("pcap") {
        Some(pcap_filename) => Box::new(File::create(pcap_filename).expect("cannot open file")),
        None => Box::new(io::sink()),
    };

    let seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .subsec_nanos();

    let device = PcapWriter::new(
        device,
        pcap_writer,
        if loopback {
            PcapMode::TxOnly
        } else {
            PcapMode::Both
        },
    );

    let device = Tracer::new(device, |_timestamp, _printer| {
        #[cfg(feature = "log")]
        trace!("{}", _printer);
    });

    let mut device = FaultInjector::new(device, seed);
    device.set_drop_chance(drop_chance);
    device.set_corrupt_chance(corrupt_chance);
    device.set_max_packet_size(size_limit);
    device.set_max_tx_rate(tx_rate_limit);
    device.set_max_rx_rate(rx_rate_limit);
    device.set_bucket_interval(Duration::from_millis(shaping_interval));
    device
}
