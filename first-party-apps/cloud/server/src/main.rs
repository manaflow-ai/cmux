//! `cmux-cloud`: the native server of the `cmux/cloud` app. The host
//! supervisor starts it on demand and speaks JSON lines on stdin and stdout
//! (shape in `api/relay.rs`). Nothing else is written to stdout. The cmux-next
//! app runs the same code from bin/cmux by argv[0] ([`cmux_cloud::run_stdio`]).

fn main() -> std::io::Result<()> {
    cmux_cloud::run_stdio()
}
