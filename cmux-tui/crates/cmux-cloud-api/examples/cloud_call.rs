//! One Cloud API call with no daemon: the request line on stdin (credentials stay off argv), the
//! answer line (`answer_line`, credentials scrubbed) on stdout; exit 0 for `ok`. The same
//! `perform` the daemon's `cloud.*` ops run, for a headless check on a runner
//! (scripts/cmux-next/cloud-chief-start-check.ts runs `machine.chief_start` through it).

use std::io::{Read, Write};

fn main() {
    let mut input = Vec::new();
    if let Err(e) = std::io::stdin().read_to_end(&mut input) {
        eprintln!("cloud_call: stdin: {e}");
        std::process::exit(2);
    }
    let (request, tail) = match cmux_cloud_api::parse(&input) {
        Ok(parsed) => parsed,
        Err(e) => {
            eprintln!("cloud_call: {e}");
            std::process::exit(2);
        }
    };
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let result = runtime.block_on(cmux_cloud_api::perform(&request, tail));
    let line = cmux_cloud_api::scrub(cmux_cloud_api::answer_line(&result), &request);
    let _ = writeln!(std::io::stdout(), "{line}");
    std::process::exit(if result.is_ok() { 0 } else { 1 });
}
