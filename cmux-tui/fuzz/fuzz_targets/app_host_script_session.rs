//! cmux-app-host script session (`script/session.rs`): what a script host,
//! whose VM runs the script, writes on its channel to the daemon. JSON lines
//! of `FromHost` (ready, call, subscribe, log, done, fatal, ...), cut off,
//! over the line limit or not JSON at all, go through the session's own
//! reader and handlers; the session then ends as when the host exits.
//!
//! Invariants past "no panic": at most `MAX_INFLIGHT` op calls run at once,
//! subscriptions stay under their cap, the router is watched at most once,
//! the session is told it started at most once, and a dead session keeps no
//! waiter, subscription, watch or call in flight.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| cmux_app_host::script::fuzzing::one_input(data));
