//! Argv modes that run before the daemon's startup, all private (`__…`):
//! they stay out of public help, and no public verb (`cmux capabilities`
//! asks the app) is taken from the app scopes.

use crate::client_log;

/// Runs the mode `args` names and returns its exit code; nil for
/// every other invocation.
pub(crate) fn run(args: &[String]) -> Option<i32> {
    let rest = crate::panic_free::rest_after(args, 1);
    match args.first().map(String::as_str) {
        #[cfg(unix)]
        Some("__agent-browser-provider") => Some(crate::agent_browser_provider::run()),
        // The store schemas this build reads, or (`--stored`) the state
        // directory holds: the app's build stamp and rollback check.
        Some("__store-schemas") => Some(match cmux_tui_core::store_schemas::run(rest) {
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
        Some("__adopt-build-homes") => Some(crate::build_adopt::run(rest)),
        // The machine side of `cmux link machine update` (cx-rppd.13).
        #[cfg(unix)]
        Some(crate::link::machine_update::apply::MODE) => {
            Some(crate::link::machine_update::apply::run(rest))
        }
        // What every daemon of this build advertises, with none running: the
        // app bundle records it for the web pages (daemon-capabilities.json).
        Some(DAEMON_CAPABILITIES) => Some(capabilities(rest)),
        // One api-compat translation in this build: the oracle's api-compat
        // suite (scripts/cmux-next/oracle/gen_api_compat.py).
        #[cfg(any(debug_assertions, feature = "oracle"))]
        Some(ORACLE_API_COMPAT) => Some(oracle_api_compat(rest)),
        _ => None,
    }
}

/// The oracle's api-compat mode; debug and `--features oracle` builds only.
#[cfg(any(debug_assertions, feature = "oracle"))]
pub(crate) const ORACLE_API_COMPAT: &str = "__oracle-api-compat";

/// `__oracle-api-compat`: one [`cmux_api_compat::fixtures::Vector`] as JSON
/// on stdin, as the fixture file holds it. The build translates it and checks
/// the result against the vector's `expect`: a match prints the comparable
/// result and exits 0, a mismatch prints a typed `api_compat.mismatch` error
/// and exits 1, unreadable input exits 2.
#[cfg(any(debug_assertions, feature = "oracle"))]
fn oracle_api_compat(args: &[String]) -> i32 {
    use std::io::Read;

    if !args.is_empty() {
        client_log::stderr_log!("startup", "usage: {BIN} {ORACLE_API_COMPAT} < vector.json");
        return 2;
    }
    let mut input = Vec::new();
    if let Err(error) = std::io::stdin().lock().read_to_end(&mut input) {
        client_log::stderr_log!("startup", "{BIN}: {ORACLE_API_COMPAT}: stdin: {error}");
        return 2;
    }
    let reply = match oracle_api_compat_reply(&input) {
        Ok(reply) => reply,
        Err(error) => {
            client_log::stderr_log!("startup", "{BIN}: {ORACLE_API_COMPAT}: {error}");
            return 2;
        }
    };
    match serde_json::to_string(&reply) {
        Ok(line) => {
            println!("{line}");
            reply.exit_code()
        }
        Err(error) => {
            client_log::stderr_log!("startup", "{BIN}: {ORACLE_API_COMPAT}: reply: {error}");
            2
        }
    }
}

/// What `__oracle-api-compat` prints: the result without the refusal's free
/// text (it is not part of the translator contract), or why it is wrong.
#[cfg(any(debug_assertions, feature = "oracle"))]
#[derive(Debug, PartialEq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
enum OracleApiCompatReply {
    /// The translated message, as the vector expects.
    Output(String),
    /// The refusal of the kind the vector expects.
    Refused(cmux_api_compat::fixtures::ErrorKind),
    /// The translation gave something else.
    Error { code: &'static str, message: String },
}

#[cfg(any(debug_assertions, feature = "oracle"))]
impl OracleApiCompatReply {
    const MISMATCH: &'static str = "api_compat.mismatch";

    fn exit_code(&self) -> i32 {
        match self {
            Self::Output(_) | Self::Refused(_) => 0,
            Self::Error { .. } => 1,
        }
    }
}

/// The reply for one vector.
#[cfg(any(debug_assertions, feature = "oracle"))]
fn oracle_api_compat_reply(input: &[u8]) -> Result<OracleApiCompatReply, serde_json::Error> {
    use cmux_api_compat::fixtures::{Outcome, Vector};

    let vector: Vector = serde_json::from_slice(input)?;
    let outcome = vector.translation.run();
    if let Some(message) = vector.mismatch(&outcome) {
        return Ok(OracleApiCompatReply::Error { code: OracleApiCompatReply::MISMATCH, message });
    }
    Ok(match outcome {
        Outcome::Output(output) => OracleApiCompatReply::Output(output),
        Outcome::Error { kind, .. } => OracleApiCompatReply::Refused(kind),
    })
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

    /// The oracle's api-compat cases send a fixture vector and read the
    /// checked result: a matching output or refusal exits 0, a result the
    /// vector does not expect is a typed error that exits 1, bad JSON is not
    /// a reply.
    #[cfg(any(debug_assertions, feature = "oracle"))]
    #[test]
    fn oracle_api_compat_checks_the_vector_expectation() {
        use super::{OracleApiCompatReply, oracle_api_compat_reply};
        use cmux_api_compat::fixtures::ErrorKind;

        let schema = serde_json::json!({"protocol": "t", "base": 1, "revisions": [{"rev": 2,
            "changes": [{"message": "event:x", "op": "rename", "path": "/a", "to": "b"}]}]});
        let request = |input: &str, expect: serde_json::Value| {
            serde_json::json!({"id": "v", "title": "t", "expect": expect, "translation": {
                "schema": schema, "message": "event:x", "from": 1, "to": 2, "input": input}})
            .to_string()
        };
        let reply = |input: &str, expect: serde_json::Value| {
            oracle_api_compat_reply(request(input, expect).as_bytes()).unwrap()
        };

        let renamed = reply(r#"{"a":1}"#, serde_json::json!({"bytes": r#"{"b":1}"#}));
        assert_eq!(renamed, OracleApiCompatReply::Output(r#"{"b":1}"#.to_owned()));
        assert_eq!(renamed.exit_code(), 0);
        assert_eq!(serde_json::to_string(&renamed).unwrap(), r#"{"output":"{\"b\":1}"}"#);

        let refused = reply("{", serde_json::json!({"error": "malformed"}));
        assert_eq!(refused, OracleApiCompatReply::Refused(ErrorKind::Malformed));
        assert_eq!(refused.exit_code(), 0);
        assert_eq!(serde_json::to_string(&refused).unwrap(), r#"{"refused":"malformed"}"#);

        // A translator that drops the rename, gives other bytes, or refuses a
        // valid message fails the case in the build that does it.
        for (input, expect) in [
            (r#"{"a":1}"#, serde_json::json!({"bytes": r#"{"a":1}"#})),
            (r#"{"a":1}"#, serde_json::json!({"json": {"b": 2}})),
            (r#"{"a":1}"#, serde_json::json!({"error": "malformed"})),
            ("{", serde_json::json!({"error": "unsupported_revision"})),
        ] {
            let wrong = reply(input, expect.clone());
            assert_eq!(wrong.exit_code(), 1, "{expect}");
            let printed: serde_json::Value =
                serde_json::from_str(&serde_json::to_string(&wrong).unwrap()).unwrap();
            assert_eq!(printed["error"]["code"], "api_compat.mismatch", "{printed}");
            assert!(
                printed["error"]["message"].as_str().unwrap().contains("vector v"),
                "{printed}"
            );
        }

        assert!(oracle_api_compat_reply(br#"{"schema": 1}"#).is_err());
        let no_expect = serde_json::json!({"id": "v", "title": "t", "translation": {
            "schema": schema, "message": "event:x", "from": 1, "to": 2, "input": "{}"}});
        assert!(oracle_api_compat_reply(no_expect.to_string().as_bytes()).is_err());
    }
}
