use std::collections::BTreeMap;
use std::io::{self, Read};
use std::path::PathBuf;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use cmux_tui_core::resource::{
    OperationClass, ResourceOperation, Selector, validate_idempotency_key,
};
use serde_json::{Map, Value, json};

use super::{GlobalArgs, UsageError};
use flags::{BOOLEAN_FLAGS, SWITCH_OR_VALUE_FLAGS, usage, validate_one_of};

mod agent_focus;
#[cfg(unix)]
mod agent_hook_status;
mod agent_list;
mod agent_message_cmd;
mod browser;
mod bulk_close;
#[cfg(test)]
pub(in crate::cli) mod cases;
mod conversation;
mod flags;
pub(super) mod git;
mod history;
mod journal_flags;
mod list_filter;
mod machine;
mod name_flags;
mod notification;
mod pane_move;
pub(super) use history::DAEMON_VERBS as HISTORY_DAEMON_VERBS;
pub(super) mod plan;
mod screen;
mod session_reset;
pub(super) use session_reset::{end_stopped_terminal_state, run_session_reset_state};
pub(super) use state::parse_duration_ms;
mod server_ensure;
mod settings;
#[cfg(test)]
pub(super) use settings::KEY_ALIASES;
pub(super) use settings::{SettingsList, human_rows as settings_human_rows, resolve_alias};
mod sidebar_doc;
mod state;
mod terminal;
mod values;
mod workspace;
use journal_flags::{add_journal_subscription, apply_journal_hook_context};
#[cfg(test)]
pub(super) use list_filter::CwdFilter;
pub(super) use list_filter::ListFilter;
use notification::{parse_notification, parse_notify};
pub(super) use plan::{
    AgentRosterView, AgentSort, RequestPlan, Resolve, ResponseView, WireOperation, ZoomStep,
};
use screen::{parse_screen, parse_screen_strings};
use terminal::parse_terminal;
use values::*;

pub(super) enum ParsedCommand {
    Help(Option<String>),
    Docs(super::docs::Plan),
    CodeMode(super::code_mode::Plan),
    Command { global: GlobalArgs, plan: CommandPlan },
}
pub(super) enum CommandPlan {
    Server(super::lifecycle::ServerPlan),
    AgentHooks(crate::agent_hook_install::Plan),
    Protocol(Box<RequestPlan>),
    SessionResetState(SessionResetStatePlan),
    Plugin(PluginPlan),
    ProviderAuthority(ProviderAuthorityPlan),
    RawCommand(super::raw::RawCommandPlan),
    AgentMessage(Box<super::agent_message::MessagePlan>),
    AgentInbox(super::agent_message::InboxPlan),
}

#[derive(Clone, Debug)]
pub(super) struct PluginPlan {
    pub positionals: Vec<String>,
    pub name: Option<String>,
    pub force: bool,
    pub builtin: bool,
    pub kind: crate::plugin_manager::PluginKind,
}

#[derive(Clone, Debug)]
pub(super) struct SessionResetStatePlan {
    pub session: String,
    pub state: Option<String>,
    pub force: bool,
    pub confirm_reset: Option<String>,
}

#[derive(Clone, Debug)]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(super) struct ProviderAuthorityPlan {
    pub generation: String,
    pub authority_file: String,
}

#[derive(Default)]
struct Selectors {
    values: BTreeMap<&'static str, String>,
}

impl Selectors {
    fn insert(
        &mut self,
        scope: &'static str,
        prefix: &'static str,
        value: &str,
    ) -> Result<(), UsageError> {
        validate_selector(scope, prefix, value)?;
        if !matches!(Selector::parse(value), Ok(Selector::Id(_))) {
            for ancestor in structural_ancestors(scope) {
                self.values.entry(ancestor).or_insert_with(|| "current".into());
            }
        }
        self.values.insert(scope, value.to_string());
        Ok(())
    }

    fn params(&self) -> Map<String, Value> {
        self.values
            .iter()
            .map(|(key, value)| ((*key).to_string(), Value::String(value.clone())))
            .collect()
    }
}

#[derive(Default)]
struct Flags {
    values: BTreeMap<String, Option<String>>,
}

impl Flags {
    fn take(&mut self, name: &str) -> Option<String> {
        self.values.remove(name).flatten()
    }

    fn required(&mut self, name: &str) -> Result<String, UsageError> {
        self.take(name).ok_or_else(|| UsageError::new(format!("--{name} is required")))
    }

    fn boolean(&mut self, name: &str) -> bool {
        self.values.remove(name).is_some()
    }

    /// Take a flag by its dashed spelling, for compatibility flags whose bare
    /// name is not part of this CLI's public vocabulary.
    fn take_dashed(&mut self, flag: &str) -> Option<String> {
        self.take(flag.trim_start_matches('-'))
    }

    fn reject_remaining(&self) -> Result<(), UsageError> {
        match self.values.keys().next() {
            Some(name) => Err(UsageError::new(format!("unknown flag --{name} for this action"))),
            None => Ok(()),
        }
    }
}

struct Tokens {
    words: Vec<String>,
    flags: Flags,
    argv: Option<Vec<String>>,
}

pub(super) fn parse(args: &[String], surface: super::Surface) -> Result<CommandPlan, UsageError> {
    if let [scope, verb, rest @ ..] = args
        && matches!(scope.as_str(), "settings" | "config")
        && verb == "list"
    {
        return settings::request_list(rest);
    }
    let mut tokens = tokenize(args)?;
    super::shorthand::normalize_words(&mut tokens.words);
    flags::positional_rename(&mut tokens.words, &mut tokens.flags)?;
    let scope = tokens
        .words
        .first()
        .map(String::as_str)
        .ok_or_else(|| UsageError::new("missing resource scope"))?;
    let words = tokens.words.get(1..).unwrap_or_default();
    if tokens.argv.is_some() && !takes_argv(scope, &strs(words)) {
        return Err(UsageError::new(format!(
            "`{}` runs no command: drop the words after --",
            tokens.words.join(" ")
        )));
    }
    let mut selectors = Selectors::default();
    let plan = match scope {
        "server" => parse_server(words, &mut tokens.flags, surface)?,
        "machine" => machine::parse(words, &mut selectors, &mut tokens.flags, surface)?,
        "session" => parse_session(words, &mut selectors, &mut tokens.flags)?,
        "client" => parse_client(words, &mut selectors, &mut tokens.flags)?,
        "workspace" => parse_workspace(words, &mut selectors, &mut tokens.flags, tokens.argv)?,
        "screen" => parse_screen(words, &mut selectors, &mut tokens.flags, tokens.argv)?,
        "settings" | "config" => settings::parse(words, &mut tokens.flags, tokens.argv.as_deref())?,
        "pane" => parse_pane(words, &mut selectors, &mut tokens.flags, tokens.argv)?,
        "tab" => parse_tab(words, &mut selectors, &mut tokens.flags, tokens.argv)?,
        "terminal" => parse_terminal(words, &mut selectors, &mut tokens.flags)?,
        "browser" => parse_browser(words, &mut selectors, &mut tokens.flags)?,
        "notification" => parse_notification(words, &mut tokens.flags)?,
        "attention" => state::parse_attention(&strs(words), &mut selectors, &mut tokens.flags)?,
        "room" => state::parse_room(&strs(words), &mut tokens.flags)?,
        "space" => parse_space(&strs(words), &mut tokens.flags)?,
        "closed" => state::parse_closed(&strs(words), &mut tokens.flags)?,
        "git" => git::parse_git(&strs(words), &mut tokens.flags)?,
        "history" => history::parse_history(&strs(words), &mut tokens.flags)?,
        "conversation" => conversation::parse_conversation(&strs(words), &mut tokens.flags)?,
        "notify" => parse_notify(words, &mut tokens.flags)?,
        "agent" => parse_agent(words, &mut tokens.flags, tokens.argv)?,
        "sidebar" => parse_sidebar(words, &mut selectors, &mut tokens.flags)?,
        "pairing" => parse_pairing(words, &mut selectors, &mut tokens.flags)?,
        "projection" => parse_projection(words, &mut selectors, &mut tokens.flags)?,
        "provider" => parse_provider(words, &mut selectors, &mut tokens.flags)?,
        "raw" => parse_raw(words, &mut tokens.flags)?,
        value => return Err(super::unknown_scope(value, surface)),
    };
    tokens.flags.reject_remaining()?;
    Ok(plan)
}

/// `space list` is the friendly name for the daemon's room listing. Mutating
/// space verbs are app actions and are dispatched by the app parser first.
fn parse_space(words: &[&str], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    match words {
        ["list"] => state::parse_room(&["list"], flags),
        _ => usage("space action"),
    }
}

fn parse_server(
    words: &[String],
    flags: &mut Flags,
    surface: super::Surface,
) -> Result<CommandPlan, UsageError> {
    let action = match strs(words).as_slice() {
        ["status"] => super::lifecycle::ServerAction::Status,
        ["stats"] => super::lifecycle::ServerAction::Stats,
        ["ensure"] => server_ensure::parse(flags)?,
        ["stop"] => stop_action(flags)?,
        ["restart"] => restart_action(flags)?,
        ["reload-config"] => super::lifecycle::ServerAction::ReloadConfig,
        ["compact-registry"] => super::lifecycle::ServerAction::CompactRegistry {
            state_dir: flags.take("state-dir").map(PathBuf::from),
        },
        ["premigrate-registry"] => super::lifecycle::ServerAction::PremigrateRegistry {
            state_dir: flags.take("state-dir").map(PathBuf::from),
            max_duration: premigrate_max_duration(flags)?,
        },
        ["start"] => {
            return Err(UsageError::new(
                crate::localization::catalog().local_server.start_options_after_action,
            ));
        }
        [action] => {
            let messages = &crate::localization::catalog().local_server;
            let scope = if surface == super::Surface::Cmux { "daemon" } else { "server" };
            return Err(UsageError::new(messages.unknown_server_action(
                scope,
                action,
                super::suggestion(
                    action,
                    &[
                        "stats",
                        "start",
                        "ensure",
                        "status",
                        "stop",
                        "restart",
                        "reload-config",
                        "compact-registry",
                        "premigrate-registry",
                    ],
                ),
            )));
        }
        _ => {
            return Err(UsageError::new(
                crate::localization::catalog().local_server.invalid_action_syntax,
            ));
        }
    };
    Ok(CommandPlan::Server(super::lifecycle::ServerPlan { action, session: None }))
}

/// `server stop` and `session <name> stop`: `[--force] [--end-terminals]
/// [--restore-wait-seconds <n>]`. The wait for an owner that still restores
/// defaults to the bound `server ensure` gives a restore
/// (`local_owner::RESTORE_DEADLINE`), and is at most an hour.
fn stop_action(flags: &mut Flags) -> Result<super::lifecycle::ServerAction, UsageError> {
    Ok(super::lifecycle::ServerAction::Stop {
        restore_wait: restore_wait(flags)?,
        force: flags.boolean("force"),
        end_terminals: flags.boolean("end-terminals"),
    })
}

/// `server restart`: `[--force] [--restore-wait-seconds <n>]`, the stop's
/// options. A restart keeps every terminal, so `--end-terminals` is refused.
fn restart_action(flags: &mut Flags) -> Result<super::lifecycle::ServerAction, UsageError> {
    if flags.boolean("end-terminals") {
        return Err(UsageError::new(
            crate::localization::catalog().local_server.restart_end_terminals,
        ));
    }
    Ok(super::lifecycle::ServerAction::Restart {
        restore_wait: restore_wait(flags)?,
        force: flags.boolean("force"),
    })
}

/// `server premigrate-registry --max-seconds <n>`: at most a day, 10 minutes
/// by default (the app's update handoff waits for it; a partial fold still
/// shortens the next start, and the next run resumes it).
fn premigrate_max_duration(flags: &mut Flags) -> Result<Option<std::time::Duration>, UsageError> {
    const DEFAULT_SECONDS: u64 = 600;
    const MAX_SECONDS: u64 = 86_400;
    match flags.take("max-seconds") {
        None => Ok(Some(std::time::Duration::from_secs(DEFAULT_SECONDS))),
        Some(value) => match value.parse::<u64>() {
            Ok(seconds @ 1..=MAX_SECONDS) => Ok(Some(std::time::Duration::from_secs(seconds))),
            _ => Err(UsageError::new(
                crate::localization::catalog().local_server.registry_premigrate_max_seconds_invalid,
            )),
        },
    }
}

fn restore_wait(flags: &mut Flags) -> Result<std::time::Duration, UsageError> {
    const MAX_RESTORE_WAIT_SECONDS: u64 = 3600;
    match flags.take("restore-wait-seconds") {
        None => Ok(crate::local_owner::RESTORE_DEADLINE),
        Some(value) => match value.parse::<u64>() {
            Ok(seconds @ 1..=MAX_RESTORE_WAIT_SECONDS) => {
                Ok(std::time::Duration::from_secs(seconds))
            }
            _ => Err(UsageError::new(
                crate::localization::catalog().local_server.stop_restore_wait_invalid,
            )),
        },
    }
}

fn tokenize(args: &[String]) -> Result<Tokens, UsageError> {
    let mut words = Vec::new();
    let mut flags = Flags::default();
    let mut argv = None;
    let mut index = 0;
    while index < args.len() {
        let value = &args[index];
        if value == "--" {
            argv = Some(args[index + 1..].to_vec());
            break;
        }
        if let Some(flag) = value.strip_prefix("--") {
            let (name, inline) = flag
                .split_once('=')
                .map_or((flag, None), |(name, value)| (name, Some(value.to_string())));
            if name.is_empty() {
                return Err(UsageError::new("empty flag name"));
            }
            let switch = inline.is_none()
                && flag_takes_no_value(name, args.get(index + 1).map(String::as_str));
            let flag_value = if is_boolean_flag(name) || switch {
                if inline.is_some() {
                    return Err(UsageError::new(format!("--{name} does not take a value")));
                }
                None
            } else if let Some(value) = inline {
                Some(value)
            } else {
                let value =
                    args.get(index + 1).cloned().ok_or_else(|| flags::missing_value(name))?;
                index += 1;
                Some(value)
            };
            if flags.values.insert(name.to_string(), flag_value).is_some() {
                return Err(UsageError::new(format!("duplicate flag --{name}")));
            }
        } else if value.starts_with('-') && value != "-" && value.parse::<f64>().is_err() {
            // A lone `-` is a word: standard input, for commands that read it.
            return Err(UsageError::new(format!("unknown short flag {value:?}")));
        } else {
            words.push(value.clone());
        }
        index += 1;
    }
    Ok(Tokens { words, flags, argv })
}

/// Whether the command `scope words…` reads the words after `--`: workspace,
/// screen, pane and terminal-tab create, workspace and pane run, pane split
/// (also under a workspace, screen or pane path), the workspace
/// status/progress/log and checklist commands (which check their own verbs),
/// and agent messages. Every other command would drop
/// them, so the caller is told instead.
fn takes_argv(scope: &str, words: &[&str]) -> bool {
    fn tab(words: &[&str]) -> bool {
        matches!(words, ["create", "terminal"])
    }
    fn pane(words: &[&str]) -> bool {
        matches!(words, ["create"] | [_, "split"] | [_, "run", ..])
            || matches!(words, [_, "tab", tail @ ..] if tab(tail))
    }
    fn screen(words: &[&str]) -> bool {
        matches!(words, ["create"]) || matches!(words, [_, "pane", tail @ ..] if pane(tail))
    }
    fn workspace(words: &[&str]) -> bool {
        let area = |word: &&str| state::STATUS_AREAS.contains(word) || *word == "checklist";
        match words {
            ["create"] | [_, "run", ..] => true,
            [first, ..] if area(first) => true,
            [_, second, ..] if area(second) => true,
            [_, "screen", tail @ ..] => screen(tail),
            _ => false,
        }
    }
    match scope {
        "workspace" => workspace(words),
        "screen" => screen(words),
        "pane" => pane(words),
        "tab" => tab(words),
        "agent" => matches!(words, ["message", ..]),
        "settings" | "config" => {
            matches!(words, ["get", ..] | ["set", ..] | ["reset", ..] | ["unset", ..])
        }
        _ => false,
    }
}

/// `argv` (the words after `--`) or `--shell SCRIPT` for a command that
/// creates a terminal: the new terminal runs it instead of a plain shell.
fn insert_creation_command(
    params: &mut Map<String, Value>,
    argv: Option<Vec<String>>,
    flags: &mut Flags,
) -> Result<(), UsageError> {
    match (argv, flags.take("shell")) {
        (None, None) => Ok(()),
        (Some(argv), None) if argv.first().is_some_and(|program| !program.is_empty()) => {
            params.insert("argv".into(), json!(argv));
            Ok(())
        }
        (None, Some(script)) if !script.is_empty() => {
            params.insert("shell".into(), Value::String(script));
            Ok(())
        }
        _ => Err(UsageError::new("give exact argv after -- or one --shell script")),
    }
}

pub(super) fn is_boolean_flag(name: &str) -> bool {
    BOOLEAN_FLAGS.contains(&name)
}

/// Whether `--name` followed by `next` (the next argument, if any) is a flag
/// without a value: a boolean flag, or a [`SWITCH_OR_VALUE_FLAGS`] one with no
/// value word after it.
pub(super) fn flag_takes_no_value(name: &str, next: Option<&str>) -> bool {
    is_boolean_flag(name)
        || (SWITCH_OR_VALUE_FLAGS.contains(&name) && next.is_none_or(|next| next.starts_with("--")))
}

fn parse_session(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    match strs(words).as_slice() {
        ["list"] => request(ResourceOperation::SessionList, selectors, flags, Map::new()),
        // `session current` alone is `session current show`: an agent's
        // first "which session am I in" (`cmux identify` has the whole path).
        [selector, "show"] | [selector] => {
            selectors.insert("session", "session", selector)?;
            request(ResourceOperation::SessionGet, selectors, flags, Map::new())
        }
        [selector, "snapshot"] => {
            selectors.insert("session", "session", selector)?;
            request(ResourceOperation::SessionSnapshot, selectors, flags, Map::new())
        }
        [selector, "creation", correlation_key, "resolve"] => {
            selectors.insert("session", "session", selector)?;
            validate_correlation_key(correlation_key)?;
            request(
                ResourceOperation::SessionCreationResolve,
                selectors,
                flags,
                map_with("correlation_key", Value::String((*correlation_key).into())),
            )
        }
        [selector, "open"] => {
            selectors.insert("session", "session", selector)?;
            request(ResourceOperation::SessionOpen, selectors, flags, Map::new())
        }
        [selector, "events"] => {
            selectors.insert("session", "session", selector)?;
            let mut params = Map::new();
            add_stream_id(&mut params, flags)?;
            add_optional_cursor(&mut params, flags)?;
            request(ResourceOperation::SessionEvents, selectors, flags, params)
        }
        [selector, "journal", "subscribe"] => {
            selectors.insert("session", "session", selector)?;
            let mut params = Map::new();
            add_stream_id(&mut params, flags)?;
            add_journal_subscription(&mut params, flags, None, true)?;
            request(ResourceOperation::SessionJournalSubscribe, selectors, flags, params)
        }
        [selector, "journal", "read"] => {
            selectors.insert("session", "session", selector)?;
            let mut params = Map::new();
            add_stream_id(&mut params, flags)?;
            add_journal_subscription(&mut params, flags, Some("beginning"), false)?;
            request(ResourceOperation::SessionJournalSubscribe, selectors, flags, params)
        }
        [selector, "journal", "producer", "list"] => {
            selectors.insert("session", "session", selector)?;
            request(ResourceOperation::SessionJournalProducerList, selectors, flags, Map::new())
        }
        [selector, "journal", "producer", "put"] => {
            selectors.insert("session", "session", selector)?;
            let manifest = parse_json_flag(flags, "manifest-json")?;
            request(
                ResourceOperation::SessionJournalProducerPut,
                selectors,
                flags,
                map_with("manifest", manifest),
            )
        }
        [selector, "journal", "append"] => {
            selectors.insert("session", "session", selector)?;
            let mut event = parse_json_flag(flags, "event-json")?;
            let hook_id = std::env::var("CMUX_JOURNAL_HOOK_ID").ok();
            let causation_id = std::env::var("CMUX_JOURNAL_CAUSATION_ID").ok();
            let correlation_id = std::env::var("CMUX_JOURNAL_CORRELATION_ID").ok();
            apply_journal_hook_context(
                &mut event,
                hook_id.as_deref(),
                causation_id.as_deref(),
                correlation_id.as_deref(),
            )?;
            request(
                ResourceOperation::SessionJournalAppend,
                selectors,
                flags,
                map_with("event", event),
            )
        }
        [selector, "journal", "hook", "list"] => {
            selectors.insert("session", "session", selector)?;
            request(ResourceOperation::SessionJournalHookList, selectors, flags, Map::new())
        }
        [selector, "journal", "hook", "put"] => {
            selectors.insert("session", "session", selector)?;
            let manifest = parse_json_flag(flags, "manifest-json")?;
            request(
                ResourceOperation::SessionJournalHookPut,
                selectors,
                flags,
                map_with("manifest", manifest),
            )
        }
        [selector, "journal", "checkpoint", "create"] => {
            selectors.insert("session", "session", selector)?;
            request(ResourceOperation::SessionJournalCheckpointCreate, selectors, flags, Map::new())
        }
        [selector, "journal", "checkpoint", "list"] => {
            selectors.insert("session", "session", selector)?;
            request(ResourceOperation::SessionJournalCheckpointList, selectors, flags, Map::new())
        }
        [selector, "journal", "restore", "preview"] => {
            selectors.insert("session", "session", selector)?;
            let mut params = Map::new();
            if let Some(checkpoint) = flags.take("checkpoint") {
                params.insert("checkpoint".into(), Value::String(checkpoint));
            }
            request(ResourceOperation::SessionJournalRestorePreview, selectors, flags, params)
        }
        [selector, "journal", "segment", "list"] => {
            selectors.insert("session", "session", selector)?;
            request(ResourceOperation::SessionJournalSegmentList, selectors, flags, Map::new())
        }
        [selector, "journal", "segment", "seal"] => {
            selectors.insert("session", "session", selector)?;
            let mut params = Map::new();
            insert_decimal(
                &mut params,
                "through_sequence",
                "--through",
                flags.required("through")?,
            )?;
            request(ResourceOperation::SessionJournalSegmentSeal, selectors, flags, params)
        }
        [selector, "ping"] => {
            selectors.insert("session", "session", selector)?;
            request(ResourceOperation::SessionPing, selectors, flags, Map::new())
        }
        [selector, "shutdown"] => {
            selectors.insert("session", "session", selector)?;
            let mut params = Map::new();
            if flags.boolean("force") {
                params.insert("force".into(), Value::Bool(true));
            }
            request(ResourceOperation::SessionShutdown, selectors, flags, params)
        }
        [selector, "reset-state"] => Ok(CommandPlan::SessionResetState(SessionResetStatePlan {
            session: exact_session_name_for_reset(selector)?,
            state: flags.take("state"),
            force: flags.boolean("force"),
            confirm_reset: flags.take("confirm-reset"),
        })),
        [selector, "stop"] => {
            let session = match Selector::parse(selector).map_err(|_| {
                UsageError::new(crate::localization::catalog().local_server.session_name_required)
            })? {
                Selector::Name(name) if !name.is_empty() => Some(name),
                Selector::Current => None,
                Selector::Name(_) | Selector::Id(_) => {
                    return Err(UsageError::new(
                        crate::localization::catalog().local_server.session_name_required,
                    ));
                }
            };
            Ok(CommandPlan::Server(super::lifecycle::ServerPlan {
                action: stop_action(flags)?,
                session,
            }))
        }
        [selector, "config", "reload"] => {
            selectors.insert("session", "session", selector)?;
            request(ResourceOperation::SessionReloadConfig, selectors, flags, Map::new())
        }
        [selector, "window", "title", "set"] => {
            selectors.insert("session", "session", selector)?;
            let mut params = Map::new();
            params.insert("title".into(), Value::String(flags.required("title")?));
            request(ResourceOperation::SessionWindowTitleSet, selectors, flags, params)
        }
        [selector, "window", "title", "clear"] => {
            selectors.insert("session", "session", selector)?;
            request(ResourceOperation::SessionWindowTitleClear, selectors, flags, Map::new())
        }
        [selector, "terminal", "defaults", "set"] => {
            selectors.insert("session", "session", selector)?;
            let mut params = Map::new();
            for name in [
                "foreground",
                "background",
                "cursor",
                "selection-background",
                "selection-foreground",
                "cursor-style",
            ] {
                insert_optional_nullable_string(&mut params, flags, name)?;
            }
            insert_optional_nullable_bool(&mut params, flags, "cursor-blink")?;
            insert_optional_nullable_json_object(&mut params, flags, "palette")?;
            if flags.boolean("complete") {
                params.insert("complete".into(), Value::Bool(true));
            }
            if params.is_empty() {
                return Err(UsageError::new(
                    "terminal defaults set needs at least one defaults flag or --complete",
                ));
            }
            validate_terminal_defaults(&params)?;
            request(ResourceOperation::SessionTerminalDefaultsUpdate, selectors, flags, params)
        }
        _ => usage("session action"),
    }
}

fn exact_session_name_for_reset(selector: &str) -> Result<String, UsageError> {
    let messages = &crate::localization::catalog().session_reset;
    match Selector::parse(selector).map_err(|_| UsageError::new(messages.exact_name_required))? {
        Selector::Name(name) if !name.is_empty() => Ok(name),
        Selector::Name(_) => Err(UsageError::new(messages.non_empty_name_required)),
        Selector::Current | Selector::Id(_) => Err(UsageError::new(messages.exact_name_required)),
    }
}

fn parse_client(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    match strs(words).as_slice() {
        ["list"] => request(ResourceOperation::ClientList, selectors, flags, Map::new()),
        [selector, "show"] => {
            selectors.insert("client", "client", selector)?;
            request(ResourceOperation::ClientGet, selectors, flags, Map::new())
        }
        [selector, "label", "set"] | [selector, "metadata", "set"] => {
            selectors.insert("client", "client", selector)?;
            let mut params = Map::new();
            insert_optional_clearable_string(&mut params, flags, "name")?;
            insert_optional_clearable_string(&mut params, flags, "kind")?;
            if params.is_empty() {
                return Err(UsageError::new(
                    "client metadata set needs --name, --kind, --clear-name, or --clear-kind",
                ));
            }
            request(ResourceOperation::ClientMetadataUpdate, selectors, flags, params)
        }
        [selector, "sizing", "set"] => {
            selectors.insert("client", "client", selector)?;
            let terminal = flags.required("terminal")?;
            selectors.insert("terminal", "term", &terminal)?;
            let mut params = Map::new();
            params.insert(
                "enabled".into(),
                Value::Bool(parse_bool("--enabled", &flags.required("enabled")?)?),
            );
            if let Some(exclusive) = flags.take("exclusive") {
                params.insert(
                    "exclusive".into(),
                    Value::Bool(parse_bool("--exclusive", &exclusive)?),
                );
            }
            request(ResourceOperation::ClientSizingSet, selectors, flags, params)
        }
        [selector, "sizing", "release"] => {
            selectors.insert("client", "client", selector)?;
            let terminal = flags.required("terminal")?;
            selectors.insert("terminal", "term", &terminal)?;
            request(ResourceOperation::ClientSizingRelease, selectors, flags, Map::new())
        }
        [selector, "cell", "pixels", "set"] => {
            selectors.insert("client", "client", selector)?;
            let mut params = Map::new();
            insert_positive_u32(
                &mut params,
                "width_px",
                "--width-px",
                flags.required("width-px")?,
            )?;
            insert_positive_u32(
                &mut params,
                "height_px",
                "--height-px",
                flags.required("height-px")?,
            )?;
            request(ResourceOperation::ClientCellPixelsSet, selectors, flags, params)
        }
        [selector, "detach"] => {
            selectors.insert("client", "client", selector)?;
            request(ResourceOperation::ClientDetach, selectors, flags, Map::new())
        }
        _ => usage("client action"),
    }
}

fn parse_workspace(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
    argv: Option<Vec<String>>,
) -> Result<CommandPlan, UsageError> {
    let refs = strs(words);
    if let Some(plan) = state::parse_workspace_status(&refs, selectors, flags, argv.as_deref())? {
        return Ok(plan);
    }
    if let Some(plan) = state::parse_workspace_checklist(&refs, selectors, flags, argv.as_deref())?
    {
        return Ok(plan);
    }
    match refs.as_slice() {
        ["group", rest @ ..] => state::parse_workspace_group(rest, selectors, flags),
        ["placement", "list"] => {
            request(ResourceOperation::WorkspacePlacementList, selectors, flags, Map::new())
        }
        ["list"] => state::workspace_list(selectors, flags),
        ["create"] => workspace::workspace_create(selectors, flags, argv),
        [selector, "show"] => {
            selectors.insert("workspace", "ws", selector)?;
            request(ResourceOperation::WorkspaceGet, selectors, flags, Map::new())
        }
        [selector, "rename"] => {
            selectors.insert("workspace", "ws", selector)?;
            request_with_required_name(ResourceOperation::WorkspaceRename, selectors, flags)
        }
        [selector, "update"] => {
            selectors.insert("workspace", "ws", selector)?;
            state::workspace_update(selectors, flags)
        }
        [selector, "move"] => {
            selectors.insert("workspace", "ws", selector)?;
            let mut params = Map::new();
            insert_u32(&mut params, "index", "--index", flags.required("index")?)?;
            request(ResourceOperation::WorkspaceMove, selectors, flags, params)
        }
        [selector, "focus"] => {
            selectors.insert("workspace", "ws", selector)?;
            request(ResourceOperation::WorkspaceFocus, selectors, flags, Map::new())
        }
        // `workspace-open-url-v1`: a web link on the workspace's right side;
        // with no workspace, the home workspace.
        ["open-url"] => workspace_open_url(selectors, flags),
        [selector, "open-url"] => {
            selectors.insert("workspace", "ws", selector)?;
            workspace_open_url(selectors, flags)
        }
        [selector, "close"] => bulk_close::close("workspace", selector, selectors, flags),
        [selector, "run", tail @ ..] => {
            selectors.insert("workspace", "ws", selector)?;
            let mut params = run_params(tail, argv, flags)?;
            add_size(&mut params, flags)?;
            request(ResourceOperation::WorkspaceRun, selectors, flags, params)
        }
        [selector, "layout", "apply"] => {
            selectors.insert("workspace", "ws", selector)?;
            let mut params = Map::new();
            params.insert("layout".into(), parse_json_flag(flags, "layout")?);
            request(ResourceOperation::WorkspaceLayoutApply, selectors, flags, params)
        }
        [selector, "screen", tail @ ..] => {
            selectors.insert("workspace", "ws", selector)?;
            parse_screen_strings(tail, selectors, flags, argv)
        }
        _ => usage("workspace action"),
    }
}

fn workspace_open_url(
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let url = flags.required("url")?;
    if url.is_empty() {
        return Err(UsageError::new("--url cannot be empty"));
    }
    request(
        ResourceOperation::WorkspaceOpenUrl,
        selectors,
        flags,
        map_with("url", Value::String(url)),
    )
}

fn parse_pane(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
    argv: Option<Vec<String>>,
) -> Result<CommandPlan, UsageError> {
    let refs = strs(words);
    parse_pane_strings(&refs, selectors, flags, argv)
}

fn parse_pane_strings(
    words: &[&str],
    selectors: &mut Selectors,
    flags: &mut Flags,
    argv: Option<Vec<String>>,
) -> Result<CommandPlan, UsageError> {
    match words {
        ["list"] => {
            add_optional_parent_selectors(selectors, flags, &["workspace", "screen"])?;
            let filter = list_filter::take(flags, true, true)?;
            request(ResourceOperation::PaneList, selectors, flags, Map::new())
                .map(|plan| plan.filtered(filter))
        }
        ["create"] => {
            let mut params = Map::new();
            add_size(&mut params, flags)?;
            insert_optional_string(&mut params, flags, "cwd", "cwd");
            insert_creation_command(&mut params, argv, flags)?;
            request(ResourceOperation::PaneCreate, selectors, flags, params)
        }
        [selector, "show"] => {
            selectors.insert("pane", "pane", selector)?;
            request(ResourceOperation::PaneGet, selectors, flags, Map::new())
        }
        // `pane move ...` is the caller's pane (`current`).
        ["move"] => pane_move::parse("current", selectors, flags),
        [selector, "move"] => pane_move::parse(selector, selectors, flags),
        [selector, "split"] => {
            selectors.insert("pane", "pane", selector)?;
            let mut params = Map::new();
            let direction = take_direction_switch(flags)?.unwrap_or_else(|| "right".into());
            params.insert("direction".into(), Value::String(direction.clone()));
            if let Some(ratio) = flags.take("ratio") {
                insert_ratio(&mut params, "ratio", "--ratio", ratio)?;
            }
            if flags.values.contains_key("fit") {
                if flags.take("fit").is_some() {
                    return Err(UsageError::new("--fit does not take a value"));
                }
                if direction != "right" {
                    return Err(UsageError::new("--fit requires --right"));
                }
                if flags.values.contains_key("viewport-width") || params.contains_key("ratio") {
                    return Err(UsageError::new(
                        "--fit shares the window; drop --viewport-width and --ratio",
                    ));
                }
                params.insert("fit".into(), Value::Bool(true));
            }
            if let Some(viewport_width) = flags.take("viewport-width") {
                if direction != "right" {
                    return Err(UsageError::new("--viewport-width requires --right"));
                }
                insert_viewport_width(
                    &mut params,
                    "viewport_width",
                    "--viewport-width",
                    viewport_width,
                )?;
            }
            insert_optional_string(&mut params, flags, "cwd", "cwd");
            // The new pane runs this instead of a shell, so no empty shell
            // tab is left beside the command's (agent evals, mode 3).
            insert_creation_command(&mut params, argv, flags)?;
            // A script's split keeps the user's focus unless it asks.
            if flags.boolean("focus") {
                params.insert("focus".into(), Value::Bool(true));
            }
            add_size(&mut params, flags)?;
            request(ResourceOperation::PaneSplit, selectors, flags, params)
        }
        [selector, "rename"] => {
            selectors.insert("pane", "pane", selector)?;
            request_with_required_name(ResourceOperation::PaneRename, selectors, flags)
        }
        [selector, "focus"] => {
            selectors.insert("pane", "pane", selector)?;
            request(ResourceOperation::PaneFocus, selectors, flags, Map::new())
        }
        [selector, "focus", "direction", direction] => {
            selectors.insert("pane", "pane", selector)?;
            validate_direction(direction)?;
            let mut params = Map::new();
            params.insert("direction".into(), Value::String((*direction).into()));
            request(ResourceOperation::PaneFocusDirection, selectors, flags, params)
        }
        [selector, "neighbor", direction] => {
            selectors.insert("pane", "pane", selector)?;
            validate_direction(direction)?;
            let mut params = Map::new();
            params.insert("direction".into(), Value::String((*direction).into()));
            request(ResourceOperation::PaneNeighborGet, selectors, flags, params)
        }
        [selector, "swap"] => {
            selectors.insert("pane", "pane", selector)?;
            let other_workspace = flags.required("other-workspace")?;
            let other_screen = flags.required("other-screen")?;
            let other_pane = flags.required("other-pane")?;
            validate_selector("workspace", "ws", &other_workspace)?;
            validate_selector("screen", "screen", &other_screen)?;
            validate_selector("pane", "pane", &other_pane)?;
            request(
                ResourceOperation::PaneSwap,
                selectors,
                flags,
                json!({
                    "other_workspace": other_workspace,
                    "other_screen": other_screen,
                    "other_pane": other_pane,
                })
                .as_object()
                .cloned()
                .expect("literal object"),
            )
        }
        [selector, "zoom"] => {
            selectors.insert("pane", "pane", selector)?;
            let mut params = Map::new();
            if let Some(enabled) = flags.take("enabled") {
                params.insert("enabled".into(), Value::Bool(parse_bool("--enabled", &enabled)?));
            }
            request(ResourceOperation::PaneZoom, selectors, flags, params)
        }
        [selector, "split", "ratio", "set"] => {
            selectors.insert("pane", "pane", selector)?;
            let mut params = Map::new();
            let split = flags.required("split")?;
            validate_prefixed_id("split", "split", &split)?;
            params.insert("split_id".into(), Value::String(split));
            insert_ratio(&mut params, "ratio", "--ratio", flags.required("ratio")?)?;
            request(ResourceOperation::PaneSplitRatioSet, selectors, flags, params)
        }
        [selector, "viewport", "width", "set"] => {
            selectors.insert("pane", "pane", selector)?;
            let mut params = Map::new();
            insert_positive_u16(&mut params, "columns", "--columns", flags.required("columns")?)?;
            request(ResourceOperation::PaneViewportWidthSet, selectors, flags, params)
        }
        [selector, "close"] => bulk_close::close("pane", selector, selectors, flags),
        [selector, "run", tail @ ..] => {
            selectors.insert("pane", "pane", selector)?;
            let mut params = run_params(tail, argv, flags)?;
            add_size(&mut params, flags)?;
            request(ResourceOperation::PaneRun, selectors, flags, params)
        }
        [selector, "tab", tail @ ..] => {
            selectors.insert("pane", "pane", selector)?;
            parse_tab_strings(tail, selectors, flags, argv)
        }
        _ => usage("pane action"),
    }
}

fn parse_tab(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
    argv: Option<Vec<String>>,
) -> Result<CommandPlan, UsageError> {
    let refs = strs(words);
    parse_tab_strings(&refs, selectors, flags, argv)
}

fn parse_tab_strings(
    words: &[&str],
    selectors: &mut Selectors,
    flags: &mut Flags,
    argv: Option<Vec<String>>,
) -> Result<CommandPlan, UsageError> {
    match words {
        ["group", rest @ ..] => state::parse_tab_group(rest, flags),
        ["list"] => {
            add_optional_parent_selectors(selectors, flags, &["workspace", "screen", "pane"])?;
            request(ResourceOperation::TabList, selectors, flags, Map::new())
        }
        ["create"] => Err(UsageError::new("tab create needs terminal or browser")),
        [selector, "show"] => {
            selectors.insert("tab", "tab", selector)?;
            request(ResourceOperation::TabGet, selectors, flags, Map::new())
        }
        ["create", "terminal"] => {
            let mut params = Map::new();
            insert_optional_string(&mut params, flags, "cwd", "cwd");
            insert_optional_string(&mut params, flags, "name", "name");
            insert_creation_command(&mut params, argv, flags)?;
            add_optional_parent_selectors(selectors, flags, &["workspace", "screen", "pane"])?;
            add_size(&mut params, flags)?;
            request(ResourceOperation::TabCreateTerminal, selectors, flags, params)
        }
        ["create", "browser"] => {
            let mut params = Map::new();
            let url = flags.required("url")?;
            if url.is_empty() {
                return Err(UsageError::new("--url cannot be empty"));
            }
            params.insert("url".into(), Value::String(url));
            insert_optional_string(&mut params, flags, "name", "name");
            browser::insert_engine(&mut params, flags)?;
            add_optional_parent_selectors(selectors, flags, &["workspace", "screen", "pane"])?;
            add_pixel_size(&mut params, flags)?;
            request(ResourceOperation::TabCreateBrowser, selectors, flags, params)
        }
        [selector, "rename"] => {
            selectors.insert("tab", "tab", selector)?;
            add_optional_parent_selectors(selectors, flags, &["workspace", "screen", "pane"])?;
            request_with_required_name(ResourceOperation::TabRename, selectors, flags)
        }
        [selector, "move"] => {
            selectors.insert("tab", "tab", selector)?;
            let params = destination_params(flags)?;
            request(ResourceOperation::TabMove, selectors, flags, params)
        }
        [selector, "focus"] => {
            selectors.insert("tab", "tab", selector)?;
            request(ResourceOperation::TabFocus, selectors, flags, Map::new())
        }
        // browser-devices-v1: emulate a device in a browser tab (the daemon
        // keeps it; the engine that shows the tab applies extra.emulation).
        [selector, "emulate"] => {
            selectors.insert("tab", "tab", selector)?;
            let mut params = Map::new();
            insert_optional_string(&mut params, flags, "device", "device");
            insert_optional_string(&mut params, flags, "orientation", "orientation");
            // --fit 16:9 | 1280: a desktop layout scaled to the tab's width, full height.
            insert_optional_string(&mut params, flags, "fit", "fit");
            if let Some(custom) = flags.take("custom-json") {
                let custom = serde_json::from_str(&custom).map_err(|error| {
                    UsageError::new(format!("invalid --custom-json JSON: {error}"))
                })?;
                params.insert("custom".into(), custom);
            }
            if params.is_empty() {
                return Err(UsageError::new(
                    "tab emulate needs --device, --custom-json, --orientation or --fit 16:9|1280|off; `cmux browser devices list` lists the devices",
                ));
            }
            request(ResourceOperation::BrowserTabEmulate, selectors, flags, params)
        }
        [selector, "emulate", "clear"] => {
            selectors.insert("tab", "tab", selector)?;
            request(ResourceOperation::BrowserTabEmulateClear, selectors, flags, Map::new())
        }
        [selector, action @ ("pin" | "unpin" | "update" | "zoom" | "restart"), rest @ ..] => {
            selectors.insert("tab", "tab", selector)?;
            state::tab_change(action, rest, selectors, flags)
        }
        [selector, "close"] => bulk_close::close("tab", selector, selectors, flags),
        [selector, "terminal", tail @ ..] => {
            selectors.insert("tab", "tab", selector)?;
            let tail = tail.iter().map(|value| (*value).to_string()).collect::<Vec<_>>();
            parse_terminal(&tail, selectors, flags)
        }
        [selector, "browser", tail @ ..] => {
            selectors.insert("tab", "tab", selector)?;
            let tail = tail.iter().map(|value| (*value).to_string()).collect::<Vec<_>>();
            parse_browser(&tail, selectors, flags)
        }
        _ => usage("tab action"),
    }
}

use browser::parse_browser;

fn parse_agent(
    words: &[String],
    flags: &mut Flags,
    argv: Option<Vec<String>>,
) -> Result<CommandPlan, UsageError> {
    let selectors = Selectors::default();
    match strs(words).as_slice() {
        ["message", rest @ ..] => agent_message_cmd::parse(rest, flags, argv),
        ["inbox", rest @ ..] => {
            let state = flags.take("state");
            let limit = flags.take("limit");
            let ack = flags.boolean("ack");
            Ok(CommandPlan::AgentInbox(super::agent_message::parse_inbox(rest, state, limit, ack)?))
        }
        ["plugin", tail @ ..] => {
            parse_plugin(tail, flags, crate::plugin_manager::PluginKind::Agent)
        }
        ["hook", action @ ("install" | "uninstall" | "status"), providers @ ..] => {
            let action = match *action {
                "install" => crate::agent_hook_install::Action::Install,
                "uninstall" => crate::agent_hook_install::Action::Uninstall,
                "status" => crate::agent_hook_install::Action::Status,
                _ => unreachable!(),
            };
            Ok(CommandPlan::AgentHooks(crate::agent_hook_install::Plan {
                action,
                providers: providers.iter().map(|provider| (*provider).to_string()).collect(),
            }))
        }
        ["list"] => agent_list::parse(flags),
        ["hook", "emit"] => {
            const MAX_NATIVE_PAYLOAD_BYTES: u64 = 1024 * 1024;
            let source = flags.required("source")?;
            let native_event = flags.required("event")?;
            let native = match flags.take("payload-json") {
                Some(payload) => serde_json::from_str(&payload).map_err(|error| {
                    UsageError::new(format!("invalid --payload-json JSON: {error}"))
                })?,
                None => {
                    let mut bytes = Vec::new();
                    io::stdin()
                        .take(MAX_NATIVE_PAYLOAD_BYTES + 1)
                        .read_to_end(&mut bytes)
                        .map_err(|error| {
                            UsageError::new(format!("cannot read agent hook stdin: {error}"))
                        })?;
                    if bytes.len() as u64 > MAX_NATIVE_PAYLOAD_BYTES {
                        return Err(UsageError::new(
                            "agent hook payload cannot exceed 1048576 bytes",
                        ));
                    }
                    if bytes.is_empty() {
                        json!({})
                    } else if let Ok(value) = serde_json::from_slice(&bytes) {
                        value
                    } else if let Ok(text) = String::from_utf8(bytes.clone()) {
                        json!({"encoding":"utf8","data":text})
                    } else {
                        json!({"encoding":"base64","data":BASE64.encode(bytes)})
                    }
                }
            };
            let terminal =
                flags.take("terminal").or_else(|| std::env::var("CMUX_TUI_TERMINAL_ID").ok());
            terminal.iter().try_for_each(|id| validate_prefixed_id("terminal", "term", id))?;
            // Read before the journal event redacts them; they travel beside it (memory only).
            let live = cmux_tui_core::agent_hook_live_fields(&source, &native_event, &native);
            let mut ingress = cmux_tui_core::agent_hook_journal_ingress(
                &source,
                &native_event,
                terminal.as_deref(),
                native,
            )
            .map_err(|error| UsageError::new(error.to_string()))?;
            cmux_tui_core::stamp_agent_hook_observed_now(&mut ingress);
            if serde_json::to_vec(&ingress.payload)
                .map_err(|error| UsageError::new(format!("encode agent hook: {error}")))?
                .len()
                > MAX_NATIVE_PAYLOAD_BYTES as usize
            {
                return Err(UsageError::new(
                    "encoded agent hook payload cannot exceed 1048576 bytes",
                ));
            }
            let mut fields = map_with(
                "event",
                serde_json::to_value(ingress).map_err(|error| {
                    UsageError::new(format!("encode agent hook request: {error}"))
                })?,
            );
            fields.extend(live);
            request(ResourceOperation::SessionJournalAppend, &selectors, flags, fields)
        }
        ["report"] => {
            let terminal = flags.required("terminal")?;
            validate_prefixed_id("terminal", "term", &terminal)?;
            let state = flags.required("state")?;
            validate_one_of(
                "--state",
                &state,
                &["working", "blocked", "idle", "ended", "done", "unknown"],
            )?;
            // The CLI says `ended` for a session that ended; the daemon's
            // word for it is `done` (`--state done` stays as an old alias).
            let state = if state == "ended" { "done".to_owned() } else { state };
            let source = flags.required("source")?;
            validate_one_of("--source", &source, &["hook", "socket"])?;
            let mut params = Map::new();
            params.insert("terminal_id".into(), json!(terminal));
            params.insert("state".into(), json!(state));
            params.insert("source".into(), json!(source));
            insert_optional_string(&mut params, flags, "source-session", "source_session");
            Ok(request(ResourceOperation::AgentReport, &selectors, flags, params)?.agent_report())
        }
        other => agent_focus::parse(other, flags),
    }
}

fn parse_sidebar(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    match strs(words).as_slice() {
        ["view", "show"] => {
            insert_selector_or_current(selectors, flags, "view", "sidebar_view", "sidebar_view")?;
            request(ResourceOperation::SidebarViewGet, selectors, flags, Map::new())
        }
        ["view", "ensure"] => {
            let mut params = Map::new();
            add_required_size(&mut params, flags)?;
            if flags.boolean("relaunch") {
                params.insert("relaunch".into(), Value::Bool(true));
            }
            request(ResourceOperation::SidebarViewEnsure, selectors, flags, params)
        }
        ["view", "attach"] => {
            insert_selector_or_current(selectors, flags, "view", "sidebar_view", "sidebar_view")?;
            let mut params = Map::new();
            add_stream_id(&mut params, flags)?;
            request(ResourceOperation::SidebarViewAttach, selectors, flags, params)
        }
        ["view", "input"] => {
            insert_selector_or_current(selectors, flags, "view", "sidebar_view", "sidebar_view")?;
            let encoded = match (flags.take("text"), flags.take("data-base64")) {
                (Some(text), None) => BASE64.encode(text),
                (None, Some(encoded)) => {
                    validate_base64("--data-base64", &encoded)?;
                    encoded
                }
                (None, None) => {
                    return Err(UsageError::new(
                        "sidebar view input needs --text or --data-base64",
                    ));
                }
                (Some(_), Some(_)) => {
                    return Err(UsageError::new("--text and --data-base64 are mutually exclusive"));
                }
            };
            request(
                ResourceOperation::SidebarViewInput,
                selectors,
                flags,
                map_with("data_base64", Value::String(encoded)),
            )
        }
        ["view", "resize"] => {
            insert_selector_or_current(selectors, flags, "view", "sidebar_view", "sidebar_view")?;
            let mut params = Map::new();
            add_required_size(&mut params, flags)?;
            request(ResourceOperation::SidebarViewResize, selectors, flags, params)
        }
        ["view", "reload"] => {
            insert_selector_or_current(selectors, flags, "view", "sidebar_view", "sidebar_view")?;
            request(ResourceOperation::SidebarViewReload, selectors, flags, Map::new())
        }
        ["plugin", tail @ ..] => {
            parse_plugin(tail, flags, crate::plugin_manager::PluginKind::Sidebar)
        }
        ["section-scroll", section, scroll] => {
            sidebar_doc::section_scroll(section, scroll, selectors, flags)
        }
        ["section-max-rows", section, rows] => {
            sidebar_doc::section_max_rows(section, rows, selectors, flags)
        }
        _ => usage("sidebar action"),
    }
}

fn parse_plugin(
    words: &[&str],
    flags: &mut Flags,
    kind: crate::plugin_manager::PluginKind,
) -> Result<CommandPlan, UsageError> {
    let mut positionals = vec![];
    let mut builtin = false;
    match words {
        ["list"] => positionals.push("list".into()),
        ["install", url] => {
            positionals.push("install".into());
            positionals.push((*url).into());
        }
        ["use", name] => {
            positionals.push("use".into());
            positionals.push((*name).into());
        }
        ["use"] if flags.boolean("builtin") => {
            positionals.push("use".into());
            builtin = true;
        }
        ["update", name] => {
            positionals.push("update".into());
            positionals.push((*name).into());
        }
        ["remove", name] => {
            positionals.push("remove".into());
            positionals.push((*name).into());
        }
        _ => return usage("plugin action"),
    }
    let plan = PluginPlan {
        positionals,
        name: flags.take("name"),
        force: flags.boolean("force"),
        builtin,
        kind,
    };
    Ok(CommandPlan::Plugin(plan))
}

fn parse_pairing(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    match strs(words).as_slice() {
        ["request", "list"] => {
            request(ResourceOperation::PairingRequestList, selectors, flags, Map::new())
        }
        ["request", selector, "respond", decision] => {
            selectors.insert("pairing_request", "pairing", selector)?;
            if !matches!(*decision, "accept" | "reject") {
                return Err(UsageError::new("pairing response must be accept or reject"));
            }
            request(
                ResourceOperation::PairingRequestResolve,
                selectors,
                flags,
                map_with("decision", Value::String((*decision).into())),
            )
        }
        _ => usage("pairing request action"),
    }
}

fn parse_projection(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    match strs(words).as_slice() {
        ["show"] => {
            insert_selector_or_current(
                selectors,
                flags,
                "projection-id",
                "frontend_projection",
                "projection",
            )?;
            request(ResourceOperation::FrontendProjectionGet, selectors, flags, Map::new())
        }
        [selector, "show"] => {
            selectors.insert("frontend_projection", "projection", selector)?;
            request(ResourceOperation::FrontendProjectionGet, selectors, flags, Map::new())
        }
        ["put"] => {
            insert_selector_or_current(
                selectors,
                flags,
                "projection-id",
                "frontend_projection",
                "projection",
            )?;
            let params = projection_put_fields(flags)?;
            request(ResourceOperation::FrontendProjectionPut, selectors, flags, params)
        }
        [selector, "put"] => {
            selectors.insert("frontend_projection", "projection", selector)?;
            let params = projection_put_fields(flags)?;
            request(ResourceOperation::FrontendProjectionPut, selectors, flags, params)
        }
        _ => usage("projection action"),
    }
}

fn projection_put_fields(flags: &mut Flags) -> Result<Map<String, Value>, UsageError> {
    let mut params = Map::new();
    params.insert("projection".into(), parse_json_flag(flags, "projection")?);
    for (flag, field) in
        [("frontend-id", "frontend_id"), ("window-id", "window_id"), ("generation", "generation")]
    {
        let value = flags.required(flag)?;
        validate_bounded_text(&format!("--{flag}"), &value)?;
        params.insert(field.into(), Value::String(value));
    }
    if let Some(revision) = flags.take("expected-projection-revision") {
        validate_decimal("--expected-projection-revision", &revision)?;
        params.insert("expected_projection_revision".into(), Value::String(revision));
    }
    Ok(params)
}

fn parse_provider(
    words: &[String],
    _selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    match strs(words).as_slice() {
        ["authority", "install"] => {
            let generation = flags.required("generation")?;
            validate_decimal("--generation", &generation)?;
            if generation == "0" {
                return Err(UsageError::new("--generation must be positive"));
            }
            Ok(CommandPlan::ProviderAuthority(ProviderAuthorityPlan {
                generation,
                authority_file: flags.required("authority-file")?,
            }))
        }
        _ => usage("provider action"),
    }
}

/// A numeric id stays a number; anything else (such as `tab_...`) is sent
/// as a string for the daemon to resolve.
fn group_id_value(value: &str) -> Value {
    value.parse::<u64>().map(Value::from).unwrap_or_else(|_| Value::String(value.to_string()))
}

fn group_number(flags: &mut Flags, name: &str) -> Result<Option<Value>, UsageError> {
    flags
        .take(name)
        .map(|value| {
            value
                .parse::<u64>()
                .map(Value::from)
                .map_err(|_| UsageError::new(format!("--{name} must be a non-negative integer")))
        })
        .transpose()
}

fn group_float(flags: &mut Flags, name: &str) -> Result<Option<Value>, UsageError> {
    flags
        .take(name)
        .map(|value| {
            value
                .parse::<f64>()
                .ok()
                .filter(|value| value.is_finite())
                .map(Value::from)
                .ok_or_else(|| UsageError::new(format!("--{name} must be a number")))
        })
        .transpose()
}

fn group_collapse(flags: &mut Flags, request: &mut Map<String, Value>) -> Result<(), UsageError> {
    match (flags.boolean("collapse"), flags.boolean("expand")) {
        (true, true) => Err(UsageError::new("--collapse and --expand are mutually exclusive")),
        (true, false) => {
            request.insert("collapsed".into(), Value::Bool(true));
            Ok(())
        }
        (false, true) => {
            request.insert("collapsed".into(), Value::Bool(false));
            Ok(())
        }
        (false, false) => Ok(()),
    }
}

/// Group commands use the private control protocol, like `raw command`, so
/// they work against a headless daemon with no app running.
fn group_raw_plan(command: &str, mut request: Map<String, Value>) -> CommandPlan {
    request.insert("id".into(), Value::from(1));
    request.insert("cmd".into(), Value::String(command.to_string()));
    CommandPlan::RawCommand(super::raw::RawCommandPlan {
        request: Value::Object(request),
        stream: false,
    })
}

/// Tab group moves with no `cmux.protocol/2` operation yet use the private
/// control protocol, like `raw command`, so they work against a headless
/// daemon with no app running. Every other tab group verb is a v2 operation
/// (`state.rs`).
fn parse_tab_group_private(
    group: &str,
    action: &str,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let mut request = Map::new();
    insert_optional_string(&mut request, flags, "transaction", "transaction");
    request.insert("group".into(), Value::String(group.to_string()));
    let command = match action {
        "split" => {
            request.insert("pane".into(), group_id_value(&flags.required("pane")?));
            request.insert("edge".into(), Value::String(flags.required("edge")?));
            if let Some(ratio) = group_float(flags, "ratio")? {
                request.insert("ratio".into(), ratio);
            }
            "move-tab-group-to-split"
        }
        "column" => {
            if let Some(pane) = flags.take("pane") {
                request.insert("pane".into(), group_id_value(&pane));
            }
            if let Some(screen) = group_number(flags, "screen")? {
                request.insert("screen".into(), screen);
            }
            if let Some(column) = group_number(flags, "after-column")? {
                request.insert("after_column".into(), column);
            }
            if let Some(width) = group_float(flags, "width")? {
                request.insert("width".into(), width);
            }
            "move-tab-group-to-column"
        }
        "new-workspace" => {
            insert_optional_string(&mut request, flags, "workspace-group", "workspace_group");
            if let Some(index) = group_number(flags, "index")? {
                request.insert("index".into(), index);
            }
            "move-tab-group-to-new-workspace"
        }
        "unsave" => "unsave-tab-group",
        _ => return usage("tab group action"),
    };
    Ok(group_raw_plan(command, request))
}

fn parse_raw(words: &[String], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let refs = strs(words);
    if refs.as_slice() == ["command"] {
        let request = parse_json_flag(flags, "request-json")?;
        if !request.is_object() {
            return Err(UsageError::new("--request-json must be a JSON object"));
        }
        return Ok(CommandPlan::RawCommand(super::raw::RawCommandPlan {
            request,
            stream: flags.boolean("stream"),
        }));
    }
    let operation = match refs.as_slice() {
        ["operation", operation] => *operation,
        _ => return usage("raw action"),
    };
    validate_operation_name(operation)?;
    let typed = serde_json::from_value::<ResourceOperation>(Value::String(operation.into())).ok();
    let requested_mutation = flags.boolean("mutation");
    let requested_stream = flags.boolean("stream");
    if requested_mutation && requested_stream {
        return Err(UsageError::new("--mutation and --stream are mutually exclusive"));
    }
    let wire_operation = match typed {
        Some(operation) => {
            if requested_mutation && operation.class() != OperationClass::Mutation {
                return Err(UsageError::new(
                    "--mutation disagrees with the typed operation catalog",
                ));
            }
            if requested_stream && operation.class() != OperationClass::StreamOpen {
                return Err(UsageError::new("--stream disagrees with the typed operation catalog"));
            }
            WireOperation::Typed(operation)
        }
        None => WireOperation::Raw {
            name: operation.into(),
            class: if requested_mutation {
                OperationClass::Mutation
            } else if requested_stream {
                OperationClass::StreamOpen
            } else {
                OperationClass::Read
            },
        },
    };
    let params = match flags.take("params-json") {
        Some(value) => serde_json::from_str::<Value>(&value)
            .map_err(|error| UsageError::new(format!("invalid --params-json JSON: {error}")))?,
        None => json!({}),
    };
    if !params.is_object() {
        return Err(UsageError::new("--params-json must be a JSON object"));
    }
    finalize_request(wire_operation, params, flags)
}

fn request(
    operation: ResourceOperation,
    selectors: &Selectors,
    flags: &mut Flags,
    mut params: Map<String, Value>,
) -> Result<CommandPlan, UsageError> {
    params.extend(selectors.params());
    add_routing_defaults(operation, &mut params);
    if correlated_creation(operation)
        && let Some(correlation_key) = flags.take("correlation-key")
    {
        validate_correlation_key(&correlation_key)?;
        params.insert("correlation_key".into(), Value::String(correlation_key));
    }
    if supports_expected_revision(operation)
        && let Some(revision) = flags.take("expected-revision")
    {
        validate_decimal("--expected-revision", &revision)?;
        params.insert("expected_revision".into(), Value::String(revision));
    }
    finalize_request(WireOperation::Typed(operation), Value::Object(params), flags)
        .map(|plan| plan::with_caller_lookup(plan, &selectors.values))
}

const fn correlated_creation(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::WorkspaceCreate
            | ResourceOperation::WorkspaceRun
            | ResourceOperation::ScreenCreate
            | ResourceOperation::PaneCreate
            | ResourceOperation::PaneSplit
            | ResourceOperation::PaneRun
            | ResourceOperation::TabCreateTerminal
            | ResourceOperation::TabCreateBrowser
    )
}

fn validate_correlation_key(value: &str) -> Result<(), UsageError> {
    if value.is_empty() {
        Err(UsageError::new("correlation key cannot be empty"))
    } else if value.len() > 128 {
        Err(UsageError::new("correlation key cannot exceed 128 UTF-8 bytes"))
    } else {
        Ok(())
    }
}

fn validate_bounded_text(flag: &str, value: &str) -> Result<(), UsageError> {
    if value.is_empty() || value.len() > 128 {
        Err(UsageError::new(format!("{flag} must contain 1 to 128 UTF-8 bytes")))
    } else {
        Ok(())
    }
}

fn finalize_request(
    operation: WireOperation,
    params: Value,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let class = operation.class();
    let explicit_key = flags.take("idempotency-key");
    if let Some(key) = explicit_key.as_deref() {
        validate_idempotency_key(key).map_err(|error| UsageError::new(error.message))?;
    }
    if explicit_key.is_some() && class != OperationClass::Mutation {
        return Err(UsageError::new("--idempotency-key is accepted only for mutations"));
    }
    Ok(CommandPlan::Protocol(Box::new(RequestPlan {
        stream: class == OperationClass::StreamOpen,
        operation,
        params,
        idempotency_key: explicit_key,
        resolve: Vec::new(),
        view: ResponseView::Full,
        filter: Default::default(),
    })))
}

fn structural_ancestors(scope: &str) -> &'static [&'static str] {
    match scope {
        "screen" => &["workspace"],
        "pane" => &["workspace", "screen"],
        "tab" => &["workspace", "screen", "pane"],
        "terminal" | "browser" => &["workspace", "screen", "pane", "tab"],
        _ => &[],
    }
}

fn add_routing_defaults(operation: ResourceOperation, params: &mut Map<String, Value>) {
    if operation != ResourceOperation::MachineList {
        params.entry("machine").or_insert_with(|| Value::String("current".into()));
    }
    if requires_session_route(operation) {
        params.entry("session").or_insert_with(|| Value::String("current".into()));
    }
}

fn requires_session_route(operation: ResourceOperation) -> bool {
    !matches!(
        operation,
        ResourceOperation::MachineList
            | ResourceOperation::MachineGet
            | ResourceOperation::SessionList
    )
}

fn supports_expected_revision(operation: ResourceOperation) -> bool {
    operation.class() == OperationClass::Mutation
        && !matches!(
            operation,
            ResourceOperation::FrontendProjectionPut
                | ResourceOperation::SessionJournalAppend
                | ResourceOperation::SessionJournalCheckpointCreate
                | ResourceOperation::SessionJournalHookPut
                | ResourceOperation::SessionJournalProducerPut
                | ResourceOperation::SessionJournalSegmentSeal
                | ResourceOperation::LayoutBulk
        )
}

fn insert_selector_or_current(
    selectors: &mut Selectors,
    flags: &mut Flags,
    flag: &str,
    field: &'static str,
    prefix: &'static str,
) -> Result<(), UsageError> {
    let value = flags.take(flag).unwrap_or_else(|| "current".into());
    selectors.insert(field, prefix, &value)
}

fn add_optional_parent_selectors(
    selectors: &mut Selectors,
    flags: &mut Flags,
    scopes: &[&str],
) -> Result<(), UsageError> {
    for scope in scopes {
        let Some(value) = flags.take(scope) else {
            continue;
        };
        let (field, prefix) = match *scope {
            "workspace" => ("workspace", "ws"),
            "screen" => ("screen", "screen"),
            "pane" => ("pane", "pane"),
            "tab" => ("tab", "tab"),
            _ => return Err(UsageError::new(format!("unsupported parent selector --{scope}"))),
        };
        selectors.insert(field, prefix, &value)?;
    }
    Ok(())
}

fn take_direction_switch(flags: &mut Flags) -> Result<Option<String>, UsageError> {
    let selected = ["left", "right", "up", "down"]
        .into_iter()
        .filter(|name| flags.boolean(name))
        .collect::<Vec<_>>();
    match selected.as_slice() {
        [] => Ok(None),
        [direction] => Ok(Some((*direction).into())),
        _ => Err(UsageError::new("--left, --right, --up, and --down are mutually exclusive")),
    }
}

fn destination_params(flags: &mut Flags) -> Result<Map<String, Value>, UsageError> {
    let workspace = flags.required("workspace")?;
    let screen = flags.required("screen")?;
    let pane = flags.required("pane")?;
    validate_selector("workspace", "ws", &workspace)?;
    validate_selector("screen", "screen", &screen)?;
    validate_selector("pane", "pane", &pane)?;
    let mut params = Map::new();
    params.insert("destination_workspace".into(), Value::String(workspace));
    params.insert("destination_screen".into(), Value::String(screen));
    params.insert("destination_pane".into(), Value::String(pane));
    insert_u32(&mut params, "index", "--index", flags.required("index")?)?;
    Ok(params)
}

fn request_with_required_name(
    operation: ResourceOperation,
    selectors: &Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let params = name_flags::rename_params(operation, flags)?;
    request(operation, selectors, flags, params)
}

fn run_params(
    tail: &[&str],
    argv: Option<Vec<String>>,
    flags: &mut Flags,
) -> Result<Map<String, Value>, UsageError> {
    let mut params = Map::new();
    match (tail, argv, flags.take("shell")) {
        ([], Some(argv), None) if argv.first().is_some_and(|argument| !argument.is_empty()) => {
            params.insert("argv".into(), json!(argv));
        }
        (["shell", script], None, None) if !script.is_empty() => {
            params.insert("shell".into(), Value::String((*script).into()));
        }
        ([], None, Some(script)) if !script.is_empty() => {
            params.insert("shell".into(), Value::String(script));
        }
        _ => {
            return Err(UsageError::new(
                "run needs exact argv after -- or an explicit shell script",
            ));
        }
    }
    if let Some(cwd) = flags.take("cwd") {
        params.insert("cwd".into(), Value::String(cwd));
    }
    if let Some(name) = flags.take("name") {
        params.insert("name".into(), Value::String(name));
    }
    if let Some(policy) = flags.take("on-exit") {
        match policy.as_str() {
            "close" | "keep" | "shell" => {
                params.insert("on_exit".into(), Value::String(policy));
            }
            _ => {
                return Err(UsageError::new("--on-exit must be close, keep or shell"));
            }
        }
    }
    Ok(params)
}

fn add_stream_id(params: &mut Map<String, Value>, flags: &mut Flags) -> Result<(), UsageError> {
    let id = match flags.take("stream-id") {
        Some(id) => {
            validate_prefixed_id("stream", "stream", &id)?;
            id
        }
        None => random_prefixed("stream")?,
    };
    params.insert("stream_id".into(), Value::String(id));
    Ok(())
}

fn add_optional_cursor(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
) -> Result<(), UsageError> {
    let generation = flags.take("generation");
    let revision = flags.take("revision");
    match (generation, revision) {
        (None, None) => Ok(()),
        (Some(generation), Some(revision)) => {
            if generation.is_empty() || generation.len() > 128 {
                return Err(UsageError::new("--generation must contain 1 to 128 UTF-8 bytes"));
            }
            validate_decimal("--revision", &revision)?;
            params.insert("cursor".into(), json!({"generation": generation, "revision": revision}));
            Ok(())
        }
        _ => Err(UsageError::new("--generation and --revision must be supplied together")),
    }
}

fn map_with(name: &str, value: Value) -> Map<String, Value> {
    let mut map = Map::new();
    map.insert(name.into(), value);
    map
}

pub(super) fn random_prefixed(prefix: &str) -> Result<String, UsageError> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes)
        .map_err(|error| UsageError::new(format!("cannot allocate {prefix} identity: {error}")))?;
    let mut value = String::with_capacity(prefix.len() + 33);
    value.push_str(prefix);
    value.push('_');
    const HEX: &[u8; 16] = b"0123456789abcdef";
    for byte in bytes {
        value.push(char::from(HEX[usize::from(byte >> 4)]));
        value.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    Ok(value)
}

fn strs(values: &[String]) -> Vec<&str> {
    values.iter().map(String::as_str).collect()
}

pub(super) fn run_plugin(global: GlobalArgs, plan: PluginPlan) -> i32 {
    match crate::plugin_manager::execute(
        &plan.positionals,
        crate::plugin_manager::CliOptions {
            name: plan.name,
            force: plan.force,
            builtin: plan.builtin,
        },
        plan.kind,
    ) {
        Ok(result) if global.output == super::OutputMode::Human && result == json!([]) => {
            // An empty list printed nothing at all (bench round 3).
            println!("{}", no_plugins_line(plan.kind));
            0
        }
        Ok(result) => super::wire::print_local_success(&result, global.output),
        Err(error) => {
            let value = json!({
                "code": error.code(),
                "message": error.to_string(),
                "details": error.details(),
                "retryable": false
            });
            super::wire::print_local_error(&value, global.output, error.exit_code())
        }
    }
}

pub(super) fn run_agent_hooks(global: GlobalArgs, plan: crate::agent_hook_install::Plan) -> i32 {
    #[cfg_attr(not(unix), allow(unused_mut))]
    let mut result = crate::agent_hook_install::run(&plan);
    #[cfg(unix)]
    if plan.action == crate::agent_hook_install::Action::Status {
        result.value =
            agent_hook_status::with_pane_helper(result.value, agent_hook_status::pane_helper());
    }
    if result.failed {
        let error = json!({
            "code": "local.agent_hooks",
            "message": agent_hooks_failure_message(&result.value),
            "details": result.value,
            "retryable": false,
        });
        super::wire::print_local_error(&error, global.output, 1)
    } else {
        super::wire::print_local_success(&result.value, global.output)
    }
}

/// What `cmux agent|sidebar plugin list` prints when no plugin is installed.
fn no_plugins_line(kind: crate::plugin_manager::PluginKind) -> String {
    format!("No plugins are installed. {} install <git-url> installs one.", kind.command_prefix())
}

/// The message of a failed `agent hook install|uninstall|status`: the
/// operations' own errors (`<provider>: <cause>`), which text output shows
/// only in the message.
fn agent_hooks_failure_message(value: &Value) -> String {
    let errors: Vec<&str> =
        value["errors"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    if errors.is_empty() {
        return "one or more coding-agent hook operations failed".to_owned();
    }
    format!("coding-agent hook operations failed: {}", errors.join("; "))
}

pub(super) fn run_provider_authority(global: GlobalArgs, plan: ProviderAuthorityPlan) -> i32 {
    let output = global.output;
    let Some(socket) = global.socket else {
        eprintln!("cmux: provider authority install requires --socket");
        return 2;
    };
    #[cfg(target_os = "linux")]
    {
        let output_generation = plan.generation.clone();
        let args = vec![
            "__provider-authority".into(),
            "install".into(),
            "--socket".into(),
            socket.display().to_string(),
            "--generation".into(),
            plan.generation,
            "--authority-file".into(),
            plan.authority_file,
        ];
        match crate::provider_authority::try_run(&args) {
            Some(0) => super::wire::print_local_success(
                &json!({"installed": true, "generation": output_generation}),
                output,
            ),
            Some(_) | None => 1,
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (socket, plan);
        super::wire::print_local_error(
            &json!({
                "code": "local.unsupported",
                "message": "provider authority installation is available only on Linux hosts",
                "details": {},
                "retryable": false,
            }),
            output,
            1,
        )
    }
}

#[cfg(test)]
mod tests;
