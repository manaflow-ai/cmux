//! `cmux-cloud`: the native server of the `cmux/cloud` app. The host
//! supervisor starts it on demand and speaks JSON lines on stdin and stdout
//! (shape in `api/relay.rs`). Nothing else is written to stdout. Panics
//! go to `<CMUX_APP_DATA_DIR>/panics.jsonl` (`panic_log.rs`).

use cmux_cloud::api::{HostRelay, serve};
use cmux_cloud::app_env::AppEnv;
use std::io::{self, BufReader};

fn main() -> io::Result<()> {
    cmux_cloud::panic_log::install(&AppEnv::from_process());
    // The serve loop reads stdin on its own thread (a stdin lock cannot move
    // there), so link events wake it while it waits for the host.
    serve(HostRelay::new(BufReader::new(io::stdin()), io::stdout().lock()))
}
