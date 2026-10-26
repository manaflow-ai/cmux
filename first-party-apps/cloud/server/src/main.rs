//! `cmux-cloud`: the native server of the `cmux/cloud` app. The host
//! supervisor starts it on demand and speaks JSON lines on stdin and stdout
//! (shape in `api/relay.rs`). Nothing else is written to stdout. Panics
//! go to `<CMUX_APP_DATA_DIR>/panics.jsonl` (`panic_log.rs`).

use cmux_cloud::api::{HostRelay, serve};
use cmux_cloud::app_env::AppEnv;
use cmux_cloud::panic_log;
use std::io::{self, BufReader};

fn main() -> io::Result<()> {
    if let Some(path) = panic_log::log_path(&AppEnv::from_process()) {
        cmux_panic_log::install(path, panic_log::fields(), |_| false);
    }
    // The serve loop reads stdin on its own thread (a stdin lock cannot move
    // there), so link events wake it while it waits for the host.
    serve(HostRelay::new(BufReader::new(io::stdin()), io::stdout().lock()))
}
