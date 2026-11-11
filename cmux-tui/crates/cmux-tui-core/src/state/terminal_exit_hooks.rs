//! Terminal exit hooks (`terminal-exit-hooks-v1`): an agent or the person
//! starts a job and is told, once, how it ended, with no wait loop. One
//! path arms every hook: the `notify_on_exit` / `on_exit_send` fields of
//! `pane.run` and `workspace.run`, `terminal.exit_hook.add` (`cmux terminal
//! <t> exit-hook add`) and `acpmux watch add --terminal <t> --until exit`,
//! which runs that CLI verb. The exit hook pump
//! (`mux/terminal_exit_hook_pump.rs`) fires a hook from the terminal's
//! durable exit receipt: a notice for the person and an agent message for
//! the recipient, each as the actor that armed it. A signal is reported as
//! that signal, never as an exit code.

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::Mux;
use crate::resource::{ResourceError, TerminalPublicId};
use crate::state::commit::StateEffects;
use crate::state::store::{StateChanges, StateCommit};
use crate::state::terminal_exit_hook_store as store;
use crate::workspace_registry::{Actor, WorkspaceMutation};

/// The capability that advertises exit hooks.
pub(crate) const CAPABILITY: &str = "terminal-exit-hooks-v1";

/// The notice title when the caller gives none (the CLI sends its locale's).
pub(crate) const DEFAULT_TITLE: &str = "Job ended: {name}";
/// The message when the caller gives none (the CLI sends its locale's).
pub(crate) const DEFAULT_TEXT: &str = "cmux: the job {name} ({terminal}) ended: {status}.";
/// Longest job name taken from a run's command, in characters.
const NAME_FROM_COMMAND_CHARS: usize = 80;

/// What a caller asks of one hook, before its recipient is resolved.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct ExitHookRequest {
    pub(crate) notify: bool,
    pub(crate) send_to: Option<String>,
    pub(crate) label: Option<String>,
    pub(crate) title: Option<String>,
    pub(crate) text: Option<String>,
}

/// A hook request whose recipient is resolved, ready to arm.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PreparedExitHook {
    request: ExitHookRequest,
    actor: Actor,
}

/// The run fields that ask for a hook; `pane.run` and `workspace.run` take
/// them out before the run commits.
const RUN_FIELDS: [&str; 5] =
    ["notify_on_exit", "on_exit_send", "on_exit_label", "on_exit_title", "on_exit_text"];

impl ExitHookRequest {
    /// The hook a run's fields ask for (`None` when they ask for none), taken
    /// out of `fields`. The job's name defaults to the run's name, then its
    /// command.
    pub(crate) fn take_from_run(
        fields: &mut Map<String, Value>,
    ) -> Result<Option<Self>, ResourceError> {
        if !RUN_FIELDS.iter().any(|name| fields.contains_key(*name)) {
            return Ok(None);
        }
        let mut taken = Map::new();
        for name in RUN_FIELDS {
            if let Some(value) = fields.remove(name) {
                taken.insert(name.to_owned(), value);
            }
        }
        let notify = match taken.get("notify_on_exit") {
            None => false,
            Some(Value::Bool(notify)) => *notify,
            Some(_) => {
                return Err(ResourceError::validation_invalid(
                    Some("notify_on_exit"),
                    "notify_on_exit must be a boolean",
                ));
            }
        };
        let label = text_field(&taken, "on_exit_label")?.or_else(|| run_name(fields));
        let request = Self {
            notify,
            send_to: text_field(&taken, "on_exit_send")?,
            label,
            title: text_field(&taken, "on_exit_title")?,
            text: text_field(&taken, "on_exit_text")?,
        };
        if !request.notify && request.send_to.is_none() {
            return Ok(None);
        }
        if fields.get("on_exit").and_then(Value::as_str) == Some("shell") {
            return Err(ResourceError::validation_invalid(
                Some("on_exit"),
                "an exit hook needs a job that ends: on_exit shell starts a new shell in its place",
            ));
        }
        Ok(Some(request))
    }

    /// The hook `terminal.exit_hook.add`'s fields ask for.
    pub(crate) fn from_add(fields: &Map<String, Value>) -> Result<Self, ResourceError> {
        let notify = match fields.get("notify") {
            None => false,
            Some(Value::Bool(notify)) => *notify,
            Some(_) => {
                return Err(ResourceError::validation_invalid(
                    Some("notify"),
                    "notify must be a boolean",
                ));
            }
        };
        let request = Self {
            notify,
            send_to: text_field(fields, "send_to")?,
            label: text_field(fields, "label")?,
            title: text_field(fields, "title")?,
            text: text_field(fields, "text")?,
        };
        if !request.notify && request.send_to.is_none() {
            return Err(ResourceError::validation_invalid(
                None,
                "an exit hook needs notify, send_to or both",
            ));
        }
        Ok(request)
    }
}

/// A trimmed, bounded, non-empty text field.
fn text_field(fields: &Map<String, Value>, name: &str) -> Result<Option<String>, ResourceError> {
    let Some(value) = fields.get(name) else { return Ok(None) };
    let Some(text) = value.as_str() else {
        return Err(ResourceError::validation_invalid(Some(name), format!("{name} must be text")));
    };
    let text = text.trim();
    if text.is_empty() {
        return Ok(None);
    }
    let limit =
        if name.ends_with("label") { store::MAX_LABEL_CHARS } else { store::MAX_TEMPLATE_CHARS };
    if text.chars().count() > limit {
        return Err(ResourceError::validation_invalid(
            Some(name),
            format!("{name} exceeds {limit} characters"),
        ));
    }
    if text.chars().any(|ch| ch.is_control() && ch != '\n' && ch != '\t') {
        return Err(ResourceError::validation_invalid(
            Some(name),
            format!("{name} contains a control character"),
        ));
    }
    Ok(Some(text.to_owned()))
}

/// A run's name, else its command, as a job name.
fn run_name(fields: &Map<String, Value>) -> Option<String> {
    let named = fields.get("name").and_then(Value::as_str).map(str::trim);
    let command = || match (fields.get("argv"), fields.get("shell")) {
        (Some(Value::Array(argv)), _) => {
            Some(argv.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "))
        }
        (_, Some(Value::String(shell))) => Some(shell.clone()),
        _ => None,
    };
    let name = named.filter(|name| !name.is_empty()).map(str::to_owned).or_else(command)?;
    let name: String = name.chars().filter(|ch| !ch.is_control()).collect();
    let name = name.trim();
    if name.is_empty() {
        return None;
    }
    if name.chars().count() <= NAME_FROM_COMMAND_CHARS {
        return Some(name.to_owned());
    }
    let mut short: String = name.chars().take(NAME_FROM_COMMAND_CHARS - 1).collect();
    short.push('…');
    Some(short)
}

/// The hook id for request key `key` on `terminal`: the same request arms
/// the same hook, so a retry never arms a second one.
pub(crate) fn exit_hook_id(key: &str, terminal: &TerminalPublicId) -> String {
    let digest = Sha256::new()
        .chain_update(key.as_bytes())
        .chain_update([0])
        .chain_update(terminal.as_str().as_bytes())
        .finalize();
    let hex: String = digest.iter().take(16).map(|byte| format!("{byte:02x}")).collect();
    format!("hook_{hex}")
}

/// The idempotency key of a run's hook, from the run's key (bounded: a
/// caller key may already use the whole length).
pub(crate) fn run_hook_key(run_key: &str) -> String {
    let digest = Sha256::digest(run_key.as_bytes());
    let hex: String = digest.iter().take(16).map(|byte| format!("{byte:02x}")).collect();
    format!("exit-hook-run-{hex}")
}

impl Mux {
    /// Checks `request` and resolves its recipient to an exact address
    /// (`acp:<session id>` or `term_<hex>`), before a run starts, so no job
    /// runs whose end nobody hears.
    pub(crate) fn prepare_terminal_exit_hook(
        &self,
        actor: &Actor,
        selectors: &crate::ResourceSelectors,
        mut request: ExitHookRequest,
    ) -> Result<PreparedExitHook, ResourceError> {
        if let Some(target) = request.send_to.take() {
            // An app reaches no agent's input (page_access.rs denies
            // agent.message.send); a hook would be a way around that.
            if matches!(actor, Actor::App { .. }) {
                return Err(ResourceError::operation_failed(
                    "terminal.exit_hook.add",
                    "an app cannot send agent messages",
                    json!({"field": "send_to"}),
                ));
            }
            request.send_to = Some(self.resolve_exit_hook_recipient(selectors, &target)?);
        }
        Ok(PreparedExitHook { request, actor: actor.clone() })
    }

    /// `acp:<x>` is an acpmux session (by name or id); `term_<hex>` a
    /// terminal agent; anything else an acpmux session name, then a
    /// terminal selector (a tab or agent name).
    fn resolve_exit_hook_recipient(
        &self,
        selectors: &crate::ResourceSelectors,
        target: &str,
    ) -> Result<String, ResourceError> {
        let refused = |reason: String| {
            ResourceError::validation_invalid(
                Some("send_to"),
                format!("cannot send the exit to {target:?}: {reason}"),
            )
        };
        let session_selectors = crate::ResourceSelectors {
            machine: selectors.machine.clone(),
            session: selectors.session.clone(),
            ..crate::ResourceSelectors::default()
        };
        let terminal = |selector: &str| {
            let mut lookup = session_selectors.clone();
            lookup.terminal = Some(selector.to_owned());
            self.resolve_resource_path(crate::ResourceTarget::Terminal, &lookup)
                .ok()
                .and_then(|path| path.terminal)
        };
        if let Some(session) = target.strip_prefix("acp:") {
            return match self.acp_session_lookup(session) {
                Ok(Some(id)) => Ok(format!("acp:{id}")),
                Ok(None) => Err(refused(format!("acpmux runs no session {session:?}"))),
                Err(reason) => Err(refused(reason)),
            };
        }
        if crate::state::agent_message_store::is_recipient_address(target) {
            return terminal(target)
                .map(|id| id.as_str().to_owned())
                .ok_or_else(|| refused("no such terminal".to_owned()));
        }
        if let Ok(Some(id)) = self.acp_session_lookup(target) {
            return Ok(format!("acp:{id}"));
        }
        terminal(target)
            .map(|id| id.as_str().to_owned())
            .ok_or_else(|| refused("no agent session or terminal has that name".to_owned()))
    }

    /// Arms `prepared` on `terminal` as hook `hook_id` (a retry of the same
    /// request keeps the first) and wakes the pump, which fires it at once
    /// when the job already ended.
    pub(crate) fn arm_terminal_exit_hook(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        terminal: &TerminalPublicId,
        hook_id: &str,
        prepared: &PreparedExitHook,
    ) -> anyhow::Result<StateCommit> {
        let request = &prepared.request;
        let hook = store::NewExitHook {
            id: hook_id.to_owned(),
            terminal_id: terminal.as_str().to_owned(),
            actor: prepared.actor.wire(),
            notify: request.notify,
            send_to: request.send_to.clone(),
            label: request.label.clone(),
            title: request.title.clone(),
            text: request.text.clone(),
        };
        let fingerprint = json!({"operation": "terminal.exit_hook.add", "hook": hook});
        let commit = self.commit_state(
            mutation,
            "terminal.exit_hook.add",
            &fingerprint,
            expected_revision,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                store::insert_hook(transaction, &hook, crate::mux::now_ms())?;
                Ok(StateChanges::new(store::hook_snapshot(transaction, &hook.id)?, Vec::new()))
            },
        )?;
        self.wake_terminal_exit_hooks(Some(terminal.as_str()));
        Ok(commit)
    }

    /// Hooks, newest first: one terminal's (`selectors.terminal`), or the
    /// session's.
    pub(crate) fn terminal_exit_hook_snapshots(
        &self,
        selectors: &crate::ResourceSelectors,
    ) -> Result<Vec<Value>, ResourceError> {
        let terminal = match selectors.terminal {
            Some(_) => {
                Some(crate::resource_router::resolve_terminal_wait_exit_id(self, selectors)?)
            }
            None => {
                self.resolve_resource_path(crate::ResourceTarget::Session, selectors)?;
                None
            }
        };
        self.read_registry_state(|connection| {
            store::hook_snapshots(connection, terminal.as_ref().map(TerminalPublicId::as_str), None)
        })
        .map_err(crate::resource_api::operation_failed)
    }
}

/// How a job ended, as the placeholders of a hook's title and text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ExitReport {
    /// `exit 3`, `signal 15 (SIGTERM)`, `signal 11 (SIGSEGV), core dumped`
    /// or `unknown: <reason>`: exact, never a code for a signal.
    pub(crate) status: String,
    pub(crate) code: Option<i64>,
    pub(crate) signal: Option<i64>,
    /// Exit 0.
    pub(crate) success: bool,
}

impl ExitReport {
    /// The report of a durable exit outcome (`TerminalExitOutcome`'s JSON).
    pub(crate) fn of(outcome: &Value) -> Self {
        match outcome.get("kind").and_then(Value::as_str) {
            Some("exit") => {
                let code = outcome.get("code").and_then(Value::as_i64);
                Self {
                    status: code.map_or_else(|| "exit".to_owned(), |code| format!("exit {code}")),
                    code,
                    signal: None,
                    success: code == Some(0),
                }
            }
            Some("signal") => {
                let signal = outcome.get("signal").and_then(Value::as_i64);
                let mut status = match signal {
                    Some(number) => match signal_name(number) {
                        Some(name) => format!("signal {number} ({name})"),
                        None => format!("signal {number}"),
                    },
                    None => "signal".to_owned(),
                };
                if outcome.get("core_dumped").and_then(Value::as_bool) == Some(true) {
                    status.push_str(", core dumped");
                }
                Self { status, code: None, signal, success: false }
            }
            _ => {
                let reason = outcome.get("reason").and_then(Value::as_str).unwrap_or("no status");
                Self {
                    status: format!("unknown: {reason}"),
                    code: None,
                    signal: None,
                    success: false,
                }
            }
        }
    }

    /// `template` with `{status}`, `{code}`, `{signal}`, `{name}` and
    /// `{terminal}` filled in (an absent code or signal is empty).
    pub(crate) fn render(&self, template: &str, name: &str, terminal: &str) -> String {
        let number = |value: Option<i64>| value.map(|value| value.to_string()).unwrap_or_default();
        template
            .replace("{status}", &self.status)
            .replace("{code}", &number(self.code))
            .replace("{signal}", &number(self.signal))
            .replace("{name}", name)
            .replace("{terminal}", terminal)
    }
}

/// The name of a signal whose number is the same on macOS and Linux.
fn signal_name(number: i64) -> Option<&'static str> {
    Some(match number {
        1 => "SIGHUP",
        2 => "SIGINT",
        3 => "SIGQUIT",
        4 => "SIGILL",
        5 => "SIGTRAP",
        6 => "SIGABRT",
        8 => "SIGFPE",
        9 => "SIGKILL",
        11 => "SIGSEGV",
        13 => "SIGPIPE",
        14 => "SIGALRM",
        15 => "SIGTERM",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_codes_and_signals_exactly() {
        let exit = ExitReport::of(&json!({"kind": "exit", "code": 3}));
        assert_eq!(exit.status, "exit 3");
        assert!(!exit.success);
        assert!(ExitReport::of(&json!({"kind": "exit", "code": 0})).success);
        let term = ExitReport::of(&json!({"kind": "signal", "signal": 15, "core_dumped": false}));
        assert_eq!(term.status, "signal 15 (SIGTERM)");
        assert_eq!(term.code, None);
        let segv = ExitReport::of(&json!({"kind": "signal", "signal": 11, "core_dumped": true}));
        assert_eq!(segv.status, "signal 11 (SIGSEGV), core dumped");
        let lost = ExitReport::of(&json!({"kind": "unknown", "reason": "host lost"}));
        assert_eq!(lost.status, "unknown: host lost");
        assert_eq!(
            term.render("{name} {status} {code}/{signal} {terminal}", "build", "term_1"),
            "build signal 15 (SIGTERM) /15 term_1"
        );
    }

    #[test]
    fn a_run_names_its_job_and_refuses_a_shell_restart() {
        let mut fields =
            json!({"argv": ["make", "test"], "notify_on_exit": true}).as_object().unwrap().clone();
        let request = ExitHookRequest::take_from_run(&mut fields).unwrap().unwrap();
        assert_eq!(request.label.as_deref(), Some("make test"));
        assert!(!fields.contains_key("notify_on_exit"), "the run never sees the hook fields");
        let mut shell = json!({"shell": "x", "on_exit": "shell", "on_exit_send": "acp:b"})
            .as_object()
            .unwrap()
            .clone();
        assert!(ExitHookRequest::take_from_run(&mut shell).is_err());
        let mut none = json!({"argv": ["x"]}).as_object().unwrap().clone();
        assert_eq!(ExitHookRequest::take_from_run(&mut none).unwrap(), None);
    }

    #[test]
    fn hook_ids_are_stable_per_request_and_terminal() {
        let terminal = TerminalPublicId::parse(format!("term_{}", "a".repeat(32))).unwrap();
        let other = TerminalPublicId::parse(format!("term_{}", "b".repeat(32))).unwrap();
        assert_eq!(exit_hook_id("k", &terminal), exit_hook_id("k", &terminal));
        assert_ne!(exit_hook_id("k", &terminal), exit_hook_id("k", &other));
        assert_eq!(exit_hook_id("k", &terminal).len(), "hook_".len() + 32);
        assert!(run_hook_key(&"x".repeat(128)).len() <= 128);
    }
}
