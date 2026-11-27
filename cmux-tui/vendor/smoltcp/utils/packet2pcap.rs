use getopts::Options;
use smoltcp::phy::{PcapLinkType, PcapSink};
use smoltcp::time::Instant;
use std::env;
use std::fs::File;
use std::io::{self, Read};
use std::path::Path;
use std::process::exit;

fn convert(
    packet_filename: &Path,
    pcap_filename: &Path,
    link_type: PcapLinkType,
) -> io::Result<()> {
    let mut packet_file = File::open(packet_filename)?;
    let mut packet = Vec::new();
    packet_file.read_to_end(&mut packet)?;

    let mut pcap_file = File::create(pcap_filename)?;
    PcapSink::global_header(&mut pcap_file, link_type);
    PcapSink::packet(&mut pcap_file, Instant::from_millis(0), &packet[..]);

    Ok(())
}

fn print_usage(program: &str, opts: Options) {
    let brief = format!("Usage: {program} [options] INPUT OUTPUT");
    print!("{}", opts.usage(&brief));
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let program = args[0].clone();

    let mut opts = Options::new();
    opts.optflag("h", "help", "print this help menu");
    opts.optopt(
        "t",
        "link-type",
        "set link type (one of: ethernet ip)",
        "TYPE",
    );

    let matches = match opts.parse(&args[1..]) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("{e}");
            return;
        }
    };

    let link_type = match matches.opt_str("t").as_ref().map(|s| &s[..]) {
        Some("ethernet") => Some(PcapLinkType::Ethernet),
        Some("ip") => Some(PcapLinkType::Ip),
        _ => None,
    };

    if matches.opt_present("h") || matches.free.len() != 2 || link_type.is_none() {
        print_usage(&program, opts);
        return;
    }

    match convert(
        Path::new(&matches.free[0]),
        Path::new(&matches.free[1]),
        link_type.unwrap(),
    ) {
        Ok(()) => (),
        Err(e) => {
            eprintln!("Cannot convert packet to pcap: {e}");
            exit(1);
        }
    }
}
