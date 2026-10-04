//! `cmux-cloud`: the native server of the `cmux/cloud` app. The host
//! supervisor starts it on demand and speaks JSON lines on stdin and stdout
//! (shape in `api/relay.rs`). Nothing else is written to stdout.

use cmux_cloud::api::{HostRelay, serve};
use std::io::{self, BufReader};

fn main() -> io::Result<()> {
    serve(HostRelay::new(BufReader::new(io::stdin().lock()), io::stdout().lock()))
}
