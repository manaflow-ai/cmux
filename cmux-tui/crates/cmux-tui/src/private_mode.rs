//! Argv modes that run before the daemon's startup, all private (`__…`):
//! they stay out of public help, and no public verb (`cmux capabilities`
//! asks the app) is taken from the app scopes.

use crate::client_log;

#[cfg(unix)]
use crate::terminal_paste;

/// Runs the mode `args` names and returns its exit code; nil for
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
        // cmux NEXT NIGHTLY's install check after an update: whether this
        // build is due its canary chat, and what its result decides
        // (cmux-install-check).
        Some("__install-check") => Some(install_check(args.get(1..).unwrap_or_default())),
        // cmux NEXT's one-time adoption of its pre-isolation homes, run by the
        // app before it starts acpmux or the Chief owner (build_adopt.rs).
        #[cfg(unix)]
        Some("__adopt-build-homes") => Some(crate::build_adopt::run(&args[1..])),
        #[cfg(unix)]
        Some(terminal_paste::MODE) => Some(terminal_paste::run()),
        // The Files pane's folder reads, which a DEV build runs under cmux Files (dev)
        // (files_lister.rs).
        #[cfg(unix)]
        Some(crate::files_lister::MODE) => Some(crate::files_lister::run()),
        // A tagged DEV build's reaper: ends the build's helpers once its app exits
        // (dev_reaper.rs, issue 55842).
        #[cfg(unix)]
        Some(crate::dev_reaper::MODE) => Some(crate::dev_reaper::run(&args[1..])),
        // The machine side of `cmux link machine update` (cx-rppd.13).
        #[cfg(unix)]
        Some(crate::link::machine_update::apply::MODE) => {
            Some(crate::link::machine_update::apply::run(&args[1..]))
        }
        // What every daemon of this build advertises, with none running: the
        // app bundle records it for the web pages (daemon-capabilities.json).
        Some(DAEMON_CAPABILITIES) => Some(capabilities(&args[1..])),
        // The Linux and Windows Computer Use worker the daemon supervises.
        #[cfg(not(target_os = "macos"))]
        Some(cmux_tui_core::computer_use_host::WORKER_MODE) => {
            Some(crate::computer_use_worker::run(args.get(1..).unwrap_or_default()))
        }
        // The terminal scroll-integrity probe (scroll_probe.rs) against any
        // daemon socket: local, SSH or Cloud
        // (scripts/measure/terminal-scroll-stress-linux.sh).
        #[cfg(unix)]
        Some(crate::scroll_probe::MODE) => {
            Some(crate::scroll_probe::run(args.get(1..).unwrap_or_default()))
        }
        _ => None,
    }
}

/// The offline capabilities mode, which write-daemon-capabilities.sh runs.
pub(crate) const DAEMON_CAPABILITIES: &str = "__daemon-capabilities";

/// `__daemon-capabilities [--json]`: [`cmux_tui_core::server::static_capabilities`],
/// one per line, or `{"capabilities": [...]}`.
fn capabilities(args: &[String]) -> i32 {
    match args {
        [] => {
            print!("{}", render_capabilities(false));
            0
        }
        [json] if json == "--json" => {
            print!("{}", render_capabilities(true));
            0
        }
        _ => {
            client_log::stderr_log!("startup", "usage: {BIN} {DAEMON_CAPABILITIES} [--json]");
            2
        }
    }
}

fn render_capabilities(json: bool) -> String {
    let capabilities = cmux_tui_core::server::static_capabilities();
    if json {
        format!("{}\n", serde_json::json!({ "capabilities": capabilities }))
    } else {
        capabilities.iter().map(|capability| format!("{capability}\n")).collect()
    }
}

#[cfg(test)]
#[path = "private_mode_tests.rs"]
mod tests;

fn install_check(args: &[String]) -> i32 {
    let mut stdin = String::new();
    if args.first().map(String::as_str) == Some("decide")
        && let Err(error) = std::io::Read::read_to_string(&mut std::io::stdin(), &mut stdin)
    {
        client_log::stderr_log!("startup", "{BIN}: install check: {error}");
        return 1;
    }
    match cmux_install_check::run(args, &stdin) {
        Ok(json) => {
            println!("{json}");
            0
        }
        Err(error) => {
            client_log::stderr_log!("startup", "{BIN}: install check: {error}");
            1
        }
    }
}
