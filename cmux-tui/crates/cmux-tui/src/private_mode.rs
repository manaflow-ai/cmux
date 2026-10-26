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
        // One api-compat translation in this build: the oracle's api-compat
        // suite (scripts/cmux-next/oracle/gen_api_compat.py).
        #[cfg(any(debug_assertions, feature = "oracle"))]
        Some(ORACLE_API_COMPAT) => Some(oracle_api_compat(&args[1..])),
        _ => None,
    }
}

/// The oracle's api-compat mode; debug and `--features oracle` builds only.
#[cfg(any(debug_assertions, feature = "oracle"))]
pub(crate) const ORACLE_API_COMPAT: &str = "__oracle-api-compat";

/// `__oracle-api-compat`: one [`cmux_api_compat::fixtures::Translation`] as
/// JSON on stdin, its [`cmux_api_compat::fixtures::Outcome`] on stdout. A
/// refusal is an outcome (exit 0); unreadable input exits 2.
#[cfg(any(debug_assertions, feature = "oracle"))]
fn oracle_api_compat(args: &[String]) -> i32 {
    use std::io::Read;

    if !args.is_empty() {
        client_log::stderr_log!("startup", "usage: {BIN} {ORACLE_API_COMPAT} < translation.json");
        return 2;
    }
    let mut input = Vec::new();
    if let Err(error) = std::io::stdin().lock().read_to_end(&mut input) {
        client_log::stderr_log!("startup", "{BIN}: {ORACLE_API_COMPAT}: stdin: {error}");
        return 2;
    }
    match oracle_api_compat_reply(&input) {
        Ok(reply) => {
            println!("{reply}");
            0
        }
        Err(error) => {
            client_log::stderr_log!("startup", "{BIN}: {ORACLE_API_COMPAT}: {error}");
            2
        }
    }
}

/// The reply line for one translation request.
#[cfg(any(debug_assertions, feature = "oracle"))]
fn oracle_api_compat_reply(input: &[u8]) -> Result<String, serde_json::Error> {
    let translation: cmux_api_compat::fixtures::Translation = serde_json::from_slice(input)?;
    serde_json::to_string(&translation.run())
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

    /// The oracle's api-compat cases send a fixture vector's translation and
    /// read the outcome; a refusal is a reply, bad JSON is not.
    #[cfg(any(debug_assertions, feature = "oracle"))]
    #[test]
    fn oracle_api_compat_replies_with_the_translation_outcome() {
        use super::oracle_api_compat_reply;

        let schema = serde_json::json!({"protocol": "t", "base": 1, "revisions": [{"rev": 2,
            "changes": [{"message": "event:x", "op": "rename", "path": "/a", "to": "b"}]}]});
        let request = |input: &str| {
            serde_json::json!({"schema": schema, "message": "event:x", "from": 1, "to": 2,
                               "input": input})
            .to_string()
        };
        let reply = oracle_api_compat_reply(request(r#"{"a":1}"#).as_bytes()).unwrap();
        assert_eq!(reply, r#"{"output":"{\"b\":1}"}"#);
        let reply: serde_json::Value =
            serde_json::from_str(&oracle_api_compat_reply(request("{").as_bytes()).unwrap())
                .unwrap();
        assert_eq!(reply["error"]["kind"], "malformed", "{reply}");
        assert!(oracle_api_compat_reply(br#"{"schema": 1}"#).is_err());
    }
}
