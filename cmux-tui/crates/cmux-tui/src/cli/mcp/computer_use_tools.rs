//! Computer Use status and saved app approvals for agents and the CLI
//! (docs/computer-use-approvals.md, "Controls"). One code path: the MCP
//! tools here and `cmux computer-use` (cli/computer_use.rs) call the same
//! functions on a [`Backend`].
//!
//! Only the person raises trust. These tools read (`cua_status`,
//! `cua_approvals_list`) and lower (`cua_approvals_revoke`); no MCP tool
//! answers a pending question, saves an app or changes the mode, and the
//! daemon refuses any such `computer_use.*` method anyway
//! (`cmux-tui-core/src/server/remote_host_command.rs`). The CLI's `deny`
//! lowers trust too; its `approve` only asks the collector to show the
//! question again ([`prompt`]), and the person still decides there.
//!
//! The driver's own tools (`cua_click`, ...) are the `cmux-cua` upstream's
//! (upstream.rs); the CLI reaches them through acpmux ([`mcp_request`]).

use std::time::Duration;

use serde_json::{Map, Value, json};

use super::transport::{CallFailure, FailureKind};
use super::{Backend, envelope, failure_result, success, tool_error, v2_tools};

/// The acpmux method that runs one MCP request through the daemon's own
/// Computer Use bridge (acpmux `cua_v2/cli_bridge.rs`).
pub(in crate::cli) const MCP_METHOD: &str = "_acpmux/computer_use_mcp";
/// A call may wait 2 minutes for the person; the bridge answers within 150 s.
const MCP_TIMEOUT: Duration = Duration::from_secs(160);
/// The app re-shows its card at once.
const PROMPT_TIMEOUT: Duration = Duration::from_secs(10);

pub(super) struct ComputerUseTool {
    pub name: &'static str,
    description: &'static str,
    schema: fn() -> Value,
    read_only: bool,
}

fn no_arguments() -> Value {
    json!({"type": "object", "properties": {}, "additionalProperties": false})
}

fn revoke_schema() -> Value {
    json!({"type": "object", "properties": {
        "app": {"type": "string", "minLength": 1,
                "description": "The saved app to forget: its bundle id (com.apple.Safari), executable path or name, from cua_approvals_list"},
        "all": {"type": "boolean", "description": "Forget every saved app of this cmux client"}},
        "additionalProperties": false})
}

pub(super) const TOOLS: &[ComputerUseTool] = &[
    ComputerUseTool {
        name: "cua_status",
        description: "Computer Use on this machine: its permission mode (ask, standard, bounded, unrestricted), the agent sessions and the apps each may use, the saved apps of this cmux client, and the collectors that can ask the person. Read only.",
        schema: no_arguments,
        read_only: true,
    },
    ComputerUseTool {
        name: "cua_approvals_list",
        description: "The apps the person saved with Always Allow for this cmux client, which every agent session may use. Read only: only the person adds an app, on cmux's approval card or their phone.",
        schema: no_arguments,
        read_only: true,
    },
    ComputerUseTool {
        name: "cua_approvals_revoke",
        description: "Forget a saved app approval (app) or all of them (all: true). This only lowers trust: running sessions lose the app at once, and the next use asks the person again. No tool can approve an app.",
        schema: revoke_schema,
        read_only: false,
    },
];

pub(super) fn find(name: &str) -> Option<&'static ComputerUseTool> {
    TOOLS.iter().find(|tool| tool.name == name)
}

impl ComputerUseTool {
    pub(super) fn descriptor_json(&self) -> Value {
        json!({
            "name": self.name,
            "description": self.description,
            "inputSchema": (self.schema)(),
            "annotations": {"readOnlyHint": self.read_only, "destructiveHint": false,
                            "idempotentHint": true, "openWorldHint": false},
        })
    }

    pub(super) fn call(&self, backend: &impl Backend, arguments: &Map<String, Value>) -> Value {
        let answer = match self.name {
            "cua_status" => status(backend),
            "cua_approvals_list" => approvals_list(backend),
            "cua_approvals_revoke" => {
                let app =
                    arguments.get("app").and_then(Value::as_str).filter(|a| !a.trim().is_empty());
                let all = arguments.get("all").and_then(Value::as_bool).unwrap_or(false);
                let unknown = arguments.keys().find(|key| !matches!(key.as_str(), "app" | "all"));
                if let Some(key) = unknown {
                    return invalid(&format!("cua_approvals_revoke takes app or all, not {key}"));
                }
                match (app, all) {
                    (Some(app), false) => revoke(backend, Revoke::App(app)),
                    (None, true) => revoke(backend, Revoke::All),
                    _ => return invalid("give exactly one of app or all: true"),
                }
            }
            _ => return invalid("unknown Computer Use tool"),
        };
        match answer {
            Ok(value) => success(value, !self.read_only),
            Err(failure) => failure_result(failure),
        }
    }
}

fn invalid(message: &str) -> Value {
    tool_error(envelope(v2_tools::invalid(message.to_string()), "not_run", None))
}

/// What a revoke forgets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(in crate::cli) enum Revoke<'a> {
    All,
    App(&'a str),
}

/// The saved-app reference for `word`: an executable path, a bundle id or a name.
pub(in crate::cli) fn app_ref(word: &str) -> Value {
    let word = word.trim();
    let path =
        word.contains('/') || word.contains('\\') || word.to_ascii_lowercase().ends_with(".exe");
    let bundle = !path
        && word.contains('.')
        && !word.contains(char::is_whitespace)
        && word.split('.').all(|part| !part.is_empty());
    if path {
        json!({"executable": word})
    } else if bundle {
        json!({"bundle_id": word})
    } else {
        json!({"name": word})
    }
}

/// One Computer Use control. On macOS the cmux app owns approvals (its card,
/// saved list and phone path), so the call goes to the app; on Windows and
/// Linux the daemon forwards it to the cmux Remote host.
fn host(backend: &impl Backend, method: &str, params: Value) -> Result<Value, CallFailure> {
    if cfg!(target_os = "macos") {
        backend.app(method, params, PROMPT_TIMEOUT, None, false)
    } else {
        backend.daemon(json!({"cmd": "remote-host-call", "method": method, "params": params}))
    }
}

/// Mode, sessions, grants and collectors (`computer_use.status`).
pub(in crate::cli) fn status(backend: &impl Backend) -> Result<Value, CallFailure> {
    host(backend, "computer_use.status", json!({}))
}

/// The client's saved apps.
pub(in crate::cli) fn approvals_list(backend: &impl Backend) -> Result<Value, CallFailure> {
    host(backend, "computer_use.approvals.list", json!({}))
}

/// The questions waiting for the person.
pub(in crate::cli) fn approvals_pending(backend: &impl Backend) -> Result<Value, CallFailure> {
    host(backend, "computer_use.approvals.pending", json!({}))
}

/// Forgets saved apps (lowers trust).
pub(in crate::cli) fn revoke(
    backend: &impl Backend,
    what: Revoke<'_>,
) -> Result<Value, CallFailure> {
    let params = match what {
        Revoke::All => json!({"all": true}),
        Revoke::App(word) => json!({"app": saved_app(backend, word)?}),
    };
    host(backend, "computer_use.approvals.revoke", params)
}

/// The saved entry `word` names. The host and the app match a revoke only by
/// bundle id or executable, so a display name ("Safari") is looked up in the
/// saved list first; an unknown name is an error, never a guess.
fn saved_app(backend: &impl Backend, word: &str) -> Result<Value, CallFailure> {
    let wanted = app_ref(word);
    let Some(name) = wanted.get("name").and_then(Value::as_str) else { return Ok(wanted) };
    let saved = approvals_list(backend)?;
    let apps = saved["apps"].as_array().cloned().unwrap_or_default();
    let mut matches = apps.into_iter().filter(|app| {
        app["name"].as_str().is_some_and(|saved| saved.eq_ignore_ascii_case(name))
    });
    match (matches.next(), matches.next()) {
        (Some(app), None) => {
            let mut entry = serde_json::Map::new();
            for key in ["bundle_id", "executable", "name"] {
                if let Some(value) = app.get(key).filter(|value| value.is_string()) {
                    entry.insert(key.to_owned(), value.clone());
                }
            }
            Ok(Value::Object(entry))
        }
        (Some(_), Some(_)) => Err(CallFailure::local(
            FailureKind::Rejected,
            "ambiguous",
            format!("more than one saved app is named {name}; pass its bundle id or executable path"),
        )),
        (None, _) => Err(CallFailure::local(
            FailureKind::Rejected,
            "not_found",
            format!("no saved app is named {name}"),
        )),
    }
}

/// Answers pending question `id` with Deny (lowers trust).
pub(in crate::cli) fn deny(backend: &impl Backend, id: &str) -> Result<Value, CallFailure> {
    host(backend, "computer_use.approvals.deny", json!({"id": id}))
}

/// Shows pending question `id` again on this machine's collector: the cmux
/// app's card on macOS, polkit or Windows Hello elsewhere. It decides nothing.
pub(in crate::cli) fn prompt(backend: &impl Backend, id: &str) -> Result<Value, CallFailure> {
    host(backend, "computer_use.approvals.prompt", json!({"id": id}))
}

/// One MCP request (`tools/list`, `tools/call`) to the driver's tools,
/// through acpmux's own bridge: the worker's admission and approvals apply.
pub(in crate::cli) fn mcp_request(
    backend: &impl Backend,
    method: &str,
    params: Value,
) -> Result<Value, CallFailure> {
    let message = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});
    backend.acpmux(
        MCP_METHOD,
        json!({"message": message}),
        MCP_TIMEOUT,
        None,
        method == "tools/call",
    )
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::time::Instant;

    use super::super::browser_tools;
    use super::super::transport::Prefix;
    use super::*;
    use crate::cli::command::RequestPlan;

    /// Records each request and answers `{}`.
    #[derive(Default)]
    struct Recorder {
        sent: RefCell<Vec<Value>>,
    }

    impl Backend for Recorder {
        fn resource(
            &self,
            _: Option<&str>,
            _: RequestPlan,
            _: &[Prefix],
        ) -> Result<Value, CallFailure> {
            Err(CallFailure::local(FailureKind::NotRun, "test", "no resources"))
        }
        fn app(
            &self,
            method: &str,
            params: Value,
            _: Duration,
            _: Option<&str>,
            _: bool,
        ) -> Result<Value, CallFailure> {
            self.sent.borrow_mut().push(json!({"kind": "app", "method": method, "params": params}));
            Ok(json!({}))
        }
        fn browser(&self, _: browser_tools::Request, _: bool) -> Result<Value, CallFailure> {
            Err(CallFailure::local(FailureKind::NotRun, "test", "no browser"))
        }
        fn daemon(&self, request: Value) -> Result<Value, CallFailure> {
            self.sent.borrow_mut().push(json!({"kind": "daemon", "request": request}));
            Ok(json!({}))
        }
        fn acpmux(
            &self,
            method: &str,
            params: Value,
            _: Duration,
            _: Option<&str>,
            mutation: bool,
        ) -> Result<Value, CallFailure> {
            self.sent.borrow_mut().push(
                json!({"kind": "acpmux", "method": method, "params": params, "mutation": mutation}),
            );
            Ok(json!({}))
        }
        fn session_events(
            &self,
            _: Option<&str>,
            _: Option<&Value>,
            _: Instant,
            _: Duration,
            _: &mut dyn FnMut(Option<&Value>) -> bool,
        ) -> Result<(), CallFailure> {
            Err(CallFailure::local(FailureKind::NotRun, "test", "no events"))
        }
    }

    fn call(name: &str, arguments: Value) -> (Value, Vec<Value>) {
        let backend = Recorder::default();
        let Value::Object(arguments) = arguments else { panic!("arguments") };
        let result = find(name).unwrap().call(&backend, &arguments);
        (result, backend.sent.take())
    }

    /// No MCP tool can approve, answer, save or raise: the three tools read
    /// or lower, and their schemas carry no decision or mode.
    #[test]
    fn no_computer_use_tool_can_raise_trust() {
        let names: Vec<_> = TOOLS.iter().map(|tool| tool.name).collect();
        assert_eq!(names, ["cua_status", "cua_approvals_list", "cua_approvals_revoke"]);
        for tool in TOOLS {
            let text = tool.descriptor_json().to_string();
            for word in ["\"decision\"", "\"mode\"", "\"approve\"", "\"id\""] {
                assert!(!text.contains(word), "{}: {word}", tool.name);
            }
            assert_eq!(tool.descriptor_json()["inputSchema"]["additionalProperties"], false);
        }
        assert!(find("cua_approvals_approve").is_none());
        assert!(find("cua_approvals_deny").is_none());
    }

    /// The method and params of a recorded control, wherever it went
    /// (the app on macOS, the daemon's host call elsewhere).
    fn control(sent: &Value) -> (Value, Value) {
        if cfg!(target_os = "macos") {
            (sent["method"].clone(), sent["params"].clone())
        } else {
            assert_eq!(sent["request"]["cmd"], "remote-host-call");
            (sent["request"]["method"].clone(), sent["request"]["params"].clone())
        }
    }

    #[test]
    fn revoke_sends_only_the_lowering_method() {
        let (result, sent) = call("cua_approvals_revoke", json!({"app": "com.apple.Safari"}));
        assert_ne!(result["isError"], true, "{result}");
        assert_eq!(sent.len(), 1);
        assert_eq!(
            control(&sent[0]),
            (json!("computer_use.approvals.revoke"), json!({"app": {"bundle_id": "com.apple.Safari"}}))
        );
        let (_, sent) = call("cua_approvals_revoke", json!({"all": true}));
        assert_eq!(control(&sent[0]).1, json!({"all": true}));
    }

    #[test]
    fn a_revoke_that_smuggles_a_decision_or_names_nothing_sends_nothing() {
        for arguments in [
            json!({"app": "Safari", "decision": "always"}),
            json!({"app": "Safari", "all": true}),
            json!({}),
            json!({"app": "  "}),
        ] {
            let (result, sent) = call("cua_approvals_revoke", arguments.clone());
            assert_eq!(result["isError"], true, "{arguments}");
            assert!(sent.is_empty(), "{arguments}: {sent:?}");
        }
    }

    #[test]
    fn reads_go_to_the_host() {
        let (_, sent) = call("cua_status", json!({}));
        assert_eq!(control(&sent[0]).0, "computer_use.status");
        let (_, sent) = call("cua_approvals_list", json!({}));
        assert_eq!(control(&sent[0]).0, "computer_use.approvals.list");
    }

    #[test]
    fn app_words_name_an_executable_a_bundle_or_a_name() {
        assert_eq!(app_ref("/usr/bin/firefox"), json!({"executable": "/usr/bin/firefox"}));
        assert_eq!(app_ref("C:\\Apps\\x.exe"), json!({"executable": "C:\\Apps\\x.exe"}));
        assert_eq!(app_ref("notepad.exe"), json!({"executable": "notepad.exe"}));
        assert_eq!(app_ref("com.apple.Safari"), json!({"bundle_id": "com.apple.Safari"}));
        assert_eq!(app_ref("Google Chrome"), json!({"name": "Google Chrome"}));
        assert_eq!(app_ref("Safari"), json!({"name": "Safari"}));
    }

    #[test]
    fn the_cli_reaches_driver_tools_only_through_acpmux() {
        let backend = Recorder::default();
        mcp_request(&backend, "tools/call", json!({"name": "screenshot", "arguments": {}}))
            .unwrap();
        let sent = backend.sent.take();
        assert_eq!(sent[0]["kind"], "acpmux");
        assert_eq!(sent[0]["method"], MCP_METHOD);
        assert_eq!(sent[0]["mutation"], true);
        assert_eq!(sent[0]["params"]["message"]["method"], "tools/call");
        assert_eq!(sent[0]["params"]["message"]["params"]["name"], "screenshot");
    }

    #[test]
    fn approve_only_shows_the_question_again() {
        let backend = Recorder::default();
        prompt(&backend, "q7").unwrap();
        let sent = backend.sent.take();
        assert_eq!(sent.len(), 1);
        assert_eq!(control(&sent[0]).0, "computer_use.approvals.prompt");
        assert!(!sent[0].to_string().contains("decision"));
    }
}
