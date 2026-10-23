//! Argv modes that run before the daemon's startup, all private (`__…`):
//! they stay out of public help, and no public verb (`cmux capabilities`
//! asks the app) is taken from the app scopes.

use crate::client_log;

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
        // cmux NEXT's one-time adoption of its pre-isolation homes, run by the
        // app before it starts acpmux or the Chief owner (build_adopt.rs).
        #[cfg(unix)]
        Some("__adopt-build-homes") => Some(crate::build_adopt::run(&args[1..])),
        // The machine side of `cmux link machine update` (cx-rppd.13).
        #[cfg(unix)]
        Some(crate::link::machine_update::apply::MODE) => {
            Some(crate::link::machine_update::apply::run(&args[1..]))
        }
        // What every daemon of this build advertises, with none running: the
        // app bundle records it for the web pages (daemon-capabilities.json).
        Some(DAEMON_CAPABILITIES) => Some(capabilities(&args[1..])),
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
mod tests {
    use super::{render_capabilities, run};

    /// `__daemon-capabilities --json` prints the list `identify` always serves, the one
    /// the app bundle's daemon-capabilities.json records.
    #[test]
    fn capabilities_prints_the_static_identify_list() {
        let listed = cmux_tui_core::server::static_capabilities();
        assert!(listed.contains(&"ws-conversations-v1"), "{listed:?}");
        let printed: serde_json::Value = serde_json::from_str(&render_capabilities(true)).unwrap();
        assert_eq!(printed, serde_json::json!({ "capabilities": listed }));
        let lines: Vec<String> = render_capabilities(false).lines().map(str::to_owned).collect();
        assert_eq!(lines, listed);
    }

    /// `cmux capabilities` stays the classic verb that asks the app
    /// (`system.capabilities`); only the private name runs offline.
    #[test]
    fn the_public_capabilities_verb_is_left_to_the_app() {
        for args in [
            &["capabilities"][..],
            &["capabilities", "--json"],
            &["capabilities", "--id-format", "both"],
        ] {
            let args: Vec<String> = args.iter().map(|arg| (*arg).to_owned()).collect();
            assert_eq!(run(&args), None, "{args:?}");
        }
    }
}
