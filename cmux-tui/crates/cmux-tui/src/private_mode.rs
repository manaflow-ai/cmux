//! Private argv modes that run before the daemon's startup and stay out of
//! public help.

use crate::client_log;

/// Runs the private mode `args` names and returns its exit code; nil for
/// every other invocation.
pub(crate) fn run(args: &[String]) -> Option<i32> {
    match args.first().map(String::as_str) {
        #[cfg(unix)]
        Some("__agent-browser-provider") => Some(crate::agent_browser_provider::run()),
        // The store schemas this build reads, or (`--stored`) the state
        // directory holds: the app's build stamp and rollback check.
        Some("__store-schemas") => Some(match cmux_tui_core::store_schemas::run(&args[1..]) {
            Ok(json) => {
                println!("{json}");
                0
            }
            Err(error) => {
                client_log::stderr_log!("startup", "{BIN}: {error}");
                1
            }
        }),
        // cmux NEXT's one-time adoption of its pre-isolation homes, run by the
        // app before it starts acpmux or the Chief owner (build_adopt.rs).
        #[cfg(unix)]
        Some("__adopt-build-homes") => Some(crate::build_adopt::run(&args[1..])),
        // The machine side of `cmux link machine update` (cx-rppd.13).
        #[cfg(unix)]
        Some(crate::link::machine_update::apply::MODE) => {
            Some(crate::link::machine_update::apply::run(&args[1..]))
        }
        // cmux NEXT's out-of-process watcher of one app run (app_watch.rs).
        #[cfg(unix)]
        Some(crate::app_watch::MODE) => Some(crate::app_watch::run(&args[1..])),
        _ => None,
    }
}
