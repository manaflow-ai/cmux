use std::collections::BTreeMap;
use std::io::{self, Read};
use std::path::PathBuf;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use cmux_tui_core::resource::{
    OperationClass, ResourceOperation, Selector, validate_idempotency_key,
};
use serde_json::{Map, Number, Value, json};

use super::{GlobalArgs, UsageError};

pub(super) enum ParsedCommand {
    Help(Option<String>),
    Command { global: GlobalArgs, plan: CommandPlan },
}

pub(super) enum CommandPlan {
    Server(super::lifecycle::ServerPlan),
    AgentHooks(crate::agent_hook_install::Plan),
    Protocol(RequestPlan),
    SessionResetState(SessionResetStatePlan),
    Plugin(PluginPlan),
    ProviderAuthority(ProviderAuthorityPlan),
    RawCommand(super::raw::RawCommandPlan),
}

#[derive(Clone, Debug)]
pub(super) struct RequestPlan {
    pub operation: WireOperation,
    pub params: Value,
    pub idempotency_key: Option<String>,
    pub stream: bool,
}

#[derive(Clone, Debug)]
pub(super) enum WireOperation {
    Typed(ResourceOperation),
    Raw { name: String, class: OperationClass },
}

impl WireOperation {
    pub fn class(&self) -> OperationClass {
        match self {
            Self::Typed(operation) => operation.class(),
            Self::Raw { class, .. } => *class,
        }
    }

    pub fn name(&self) -> Result<String, UsageError> {
        match self {
            Self::Typed(operation) => serde_json::to_value(operation)
                .map_err(|error| UsageError::new(format!("cannot encode operation: {error}")))?
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| UsageError::new("operation did not encode as a string")),
            Self::Raw { name, .. } => Ok(name.clone()),
        }
    }
}

#[derive(Clone, Debug)]
pub(super) struct PluginPlan {
    pub positionals: Vec<String>,
    pub name: Option<String>,
    pub force: bool,
    pub builtin: bool,
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

pub(super) fn parse(args: &[String]) -> Result<CommandPlan, UsageError> {
    let mut tokens = tokenize(args)?;
    let scope = tokens
        .words
        .first()
        .map(String::as_str)
        .ok_or_else(|| UsageError::new("missing resource scope"))?;
    let mut selectors = Selectors::default();
    let plan = match scope {
        "server" => parse_server(&tokens.words[1..], &mut tokens.flags)?,
        "machine" => parse_machine(&tokens.words[1..], &mut selectors, &mut tokens.flags)?,
        "session" => parse_session(&tokens.words[1..], &mut selectors, &mut tokens.flags)?,
        "client" => parse_client(&tokens.words[1..], &mut selectors, &mut tokens.flags)?,
        "workspace" => {
            parse_workspace(&tokens.words[1..], &mut selectors, &mut tokens.flags, tokens.argv)?
        }
        "screen" => {
            parse_screen(&tokens.words[1..], &mut selectors, &mut tokens.flags, tokens.argv)?
        }
        "pane" => parse_pane(&tokens.words[1..], &mut selectors, &mut tokens.flags, tokens.argv)?,
        "tab" => parse_tab(&tokens.words[1..], &mut selectors, &mut tokens.flags)?,
        "terminal" => parse_terminal(&tokens.words[1..], &mut selectors, &mut tokens.flags)?,
        "browser" => parse_browser(&tokens.words[1..], &mut selectors, &mut tokens.flags)?,
        "notification" => parse_notification(&tokens.words[1..], &mut tokens.flags)?,
        "agent" => parse_agent(&tokens.words[1..], &mut tokens.flags)?,
        "sidebar" => parse_sidebar(&tokens.words[1..], &mut selectors, &mut tokens.flags)?,
        "pairing" => parse_pairing(&tokens.words[1..], &mut selectors, &mut tokens.flags)?,
        "projection" => parse_projection(&tokens.words[1..], &mut selectors, &mut tokens.flags)?,
        "provider" => parse_provider(&tokens.words[1..], &mut selectors, &mut tokens.flags)?,
        "raw" => parse_raw(&tokens.words[1..], &mut tokens.flags)?,
        value => return Err(super::unknown_scope(value)),
    };
    tokens.flags.reject_remaining()?;
    Ok(plan)
}

fn parse_server(words: &[String], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let action = match strs(words).as_slice() {
        ["status"] => super::lifecycle::ServerAction::Status,
        ["ensure"] => super::lifecycle::ServerAction::Ensure,
        ["stop"] => super::lifecycle::ServerAction::Stop { force: flags.boolean("force") },
        ["reload-config"] => super::lifecycle::ServerAction::ReloadConfig,
        ["start"] => {
            return Err(UsageError::new(
                crate::localization::catalog().local_server.start_options_after_action,
            ));
        }
        [action] => {
            let messages = &crate::localization::catalog().local_server;
            return Err(UsageError::new(messages.unknown_server_action(
                action,
                super::suggestion(action, &["start", "ensure", "status", "stop", "reload-config"]),
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
            let flag_value = if is_boolean_flag(name) {
                if inline.is_some() {
                    return Err(UsageError::new(format!("--{name} does not take a value")));
                }
                None
            } else if let Some(value) = inline {
                Some(value)
            } else {
                let value = args
                    .get(index + 1)
                    .cloned()
                    .ok_or_else(|| UsageError::new(format!("--{name} needs a value")))?;
                index += 1;
                Some(value)
            };
            if flags.values.insert(name.to_string(), flag_value).is_some() {
                return Err(UsageError::new(format!("duplicate flag --{name}")));
            }
        } else if value.starts_with('-') {
            return Err(UsageError::new(format!("unknown short flag {value:?}")));
        } else {
            words.push(value.clone());
        }
        index += 1;
    }
    Ok(Tokens { words, flags, argv })
}

/// Metadata for flags which consume no following token.
///
/// Keeping this as data makes the tokenizer's grammar auditable and leaves a
/// single place to extend when a command adds a boolean option. This is the
/// same distinction Clap models with `ArgAction::SetTrue`, while retaining
/// cmux's custom forwarding and error text.
const BOOLEAN_FLAGS: &[&str] = &[
    "empty",
    "left",
    "right",
    "up",
    "down",
    "force",
    "confirm-close",
    "complete",
    "clear-name",
    "clear-kind",
    "clear-foreground",
    "clear-background",
    "clear-cursor",
    "clear-selection-background",
    "clear-selection-foreground",
    "clear-cursor-style",
    "clear-cursor-blink",
    "clear-palette",
    "read-only",
    "relaunch",
    "styled",
    "builtin",
    "mutation",
    "stream",
    "ignore-case",
];

fn is_boolean_flag(name: &str) -> bool {
    BOOLEAN_FLAGS.contains(&name)
}

fn parse_machine(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    match strs(words).as_slice() {
        ["list"] => request(ResourceOperation::MachineList, selectors, flags, Map::new()),
        [selector, "show"] => {
            selectors.insert("machine", "machine", selector)?;
            request(ResourceOperation::MachineGet, selectors, flags, Map::new())
        }
        [machine, "session", "list"] => {
            selectors.insert("machine", "machine", machine)?;
            request(ResourceOperation::SessionList, selectors, flags, Map::new())
        }
        [machine, "session", session, "open"] => {
            selectors.insert("machine", "machine", machine)?;
            selectors.insert("session", "session", session)?;
            request(ResourceOperation::SessionOpen, selectors, flags, Map::new())
        }
        _ => usage("machine action"),
    }
}

fn parse_session(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    match strs(words).as_slice() {
        ["list"] => request(ResourceOperation::SessionList, selectors, flags, Map::new()),
        [selector, "show"] => {
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
                action: super::lifecycle::ServerAction::Stop { force: flags.boolean("force") },
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
    match strs(words).as_slice() {
        ["list"] => request(ResourceOperation::WorkspaceList, selectors, flags, Map::new()),
        ["create"] => {
            let mut params = Map::new();
            if let Some(name) = flags.take("name") {
                params.insert("name".into(), Value::String(name));
            }
            params.insert(
                "initial_content".into(),
                Value::String(if flags.boolean("empty") { "empty" } else { "terminal" }.into()),
            );
            request(ResourceOperation::WorkspaceCreate, selectors, flags, params)
        }
        [selector, "show"] => {
            selectors.insert("workspace", "ws", selector)?;
            request(ResourceOperation::WorkspaceGet, selectors, flags, Map::new())
        }
        [selector, "rename"] => {
            selectors.insert("workspace", "ws", selector)?;
            request_with_required_name(ResourceOperation::WorkspaceRename, selectors, flags)
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
        [selector, "close"] => {
            selectors.insert("workspace", "ws", selector)?;
            request(ResourceOperation::WorkspaceClose, selectors, flags, Map::new())
        }
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

fn parse_screen(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
    argv: Option<Vec<String>>,
) -> Result<CommandPlan, UsageError> {
    let refs = strs(words);
    parse_screen_strings(&refs, selectors, flags, argv)
}

fn parse_screen_strings(
    words: &[&str],
    selectors: &mut Selectors,
    flags: &mut Flags,
    argv: Option<Vec<String>>,
) -> Result<CommandPlan, UsageError> {
    match words {
        ["list"] => request(ResourceOperation::ScreenList, selectors, flags, Map::new()),
        ["create"] => {
            let mut params = Map::new();
            insert_optional_string(&mut params, flags, "name", "name");
            request(ResourceOperation::ScreenCreate, selectors, flags, params)
        }
        [selector, "show"] => {
            selectors.insert("screen", "screen", selector)?;
            request(ResourceOperation::ScreenGet, selectors, flags, Map::new())
        }
        [selector, "rename"] => {
            selectors.insert("screen", "screen", selector)?;
            request_with_required_name(ResourceOperation::ScreenRename, selectors, flags)
        }
        [selector, "focus"] => {
            selectors.insert("screen", "screen", selector)?;
            request(ResourceOperation::ScreenFocus, selectors, flags, Map::new())
        }
        [selector, "close"] => {
            selectors.insert("screen", "screen", selector)?;
            request(ResourceOperation::ScreenClose, selectors, flags, Map::new())
        }
        [selector, "layout", "export"] => {
            selectors.insert("screen", "screen", selector)?;
            request(ResourceOperation::ScreenLayoutExport, selectors, flags, Map::new())
        }
        [selector, "layout", "undo"] => {
            selectors.insert("screen", "screen", selector)?;
            let mut params = Map::new();
            if flags.boolean("confirm-close") {
                params.insert("confirm_close".into(), Value::Bool(true));
            }
            if let Some(token) = flags.take("confirmation-token") {
                validate_bounded_text("--confirmation-token", &token)?;
                params.insert("confirmation_token".into(), Value::String(token));
            }
            request(ResourceOperation::ScreenLayoutUndo, selectors, flags, params)
        }
        [selector, "pane", tail @ ..] => {
            selectors.insert("screen", "screen", selector)?;
            parse_pane_strings(tail, selectors, flags, argv)
        }
        _ => usage("screen action"),
    }
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
        ["list"] => request(ResourceOperation::PaneList, selectors, flags, Map::new()),
        ["create"] => {
            let mut params = Map::new();
            add_size(&mut params, flags)?;
            insert_optional_string(&mut params, flags, "cwd", "cwd");
            request(ResourceOperation::PaneCreate, selectors, flags, params)
        }
        [selector, "show"] => {
            selectors.insert("pane", "pane", selector)?;
            request(ResourceOperation::PaneGet, selectors, flags, Map::new())
        }
        [selector, "split"] => {
            selectors.insert("pane", "pane", selector)?;
            let mut params = Map::new();
            let direction = take_direction_switch(flags)?.unwrap_or_else(|| "right".into());
            params.insert("direction".into(), Value::String(direction.clone()));
            if let Some(ratio) = flags.take("ratio") {
                insert_ratio(&mut params, "ratio", "--ratio", ratio)?;
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
        [selector, "close"] => {
            selectors.insert("pane", "pane", selector)?;
            request(ResourceOperation::PaneClose, selectors, flags, Map::new())
        }
        [selector, "run", tail @ ..] => {
            selectors.insert("pane", "pane", selector)?;
            let mut params = run_params(tail, argv, flags)?;
            add_size(&mut params, flags)?;
            request(ResourceOperation::PaneRun, selectors, flags, params)
        }
        [selector, "tab", tail @ ..] => {
            selectors.insert("pane", "pane", selector)?;
            parse_tab_strings(tail, selectors, flags)
        }
        _ => usage("pane action"),
    }
}

fn parse_tab(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let refs = strs(words);
    parse_tab_strings(&refs, selectors, flags)
}

fn parse_tab_strings(
    words: &[&str],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    match words {
        ["list"] => request(ResourceOperation::TabList, selectors, flags, Map::new()),
        [selector, "show"] => {
            selectors.insert("tab", "tab", selector)?;
            request(ResourceOperation::TabGet, selectors, flags, Map::new())
        }
        ["create", "terminal"] => {
            let mut params = Map::new();
            insert_optional_string(&mut params, flags, "cwd", "cwd");
            insert_optional_string(&mut params, flags, "name", "name");
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
            add_optional_parent_selectors(selectors, flags, &["workspace", "screen", "pane"])?;
            add_pixel_size(&mut params, flags)?;
            request(ResourceOperation::TabCreateBrowser, selectors, flags, params)
        }
        [selector, "rename"] => {
            selectors.insert("tab", "tab", selector)?;
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
        [selector, "close"] => {
            selectors.insert("tab", "tab", selector)?;
            request(ResourceOperation::TabClose, selectors, flags, Map::new())
        }
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

fn parse_terminal(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    match strs(words).as_slice() {
        ["list"] => request(ResourceOperation::TerminalList, selectors, flags, Map::new()),
        [selector, "show"] => {
            selectors.insert("terminal", "term", selector)?;
            request(ResourceOperation::TerminalGet, selectors, flags, Map::new())
        }
        [selector, "write"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            match (flags.take("text"), flags.take("bytes-base64")) {
                (Some(text), None) => {
                    params.insert("text".into(), Value::String(text));
                }
                (None, Some(bytes)) => {
                    validate_base64("--bytes-base64", &bytes)?;
                    params.insert("bytes_base64".into(), Value::String(bytes));
                }
                (None, None) => {
                    let mut text = String::new();
                    io::stdin()
                        .read_to_string(&mut text)
                        .map_err(|error| UsageError::new(format!("cannot read stdin: {error}")))?;
                    params.insert("text".into(), Value::String(text));
                }
                (Some(_), Some(_)) => {
                    return Err(UsageError::new(
                        "--text and --bytes-base64 are mutually exclusive",
                    ));
                }
            }
            request(ResourceOperation::TerminalInputWrite, selectors, flags, params)
        }
        [selector, "keys", keys @ ..] if !keys.is_empty() => {
            selectors.insert("terminal", "term", selector)?;
            if keys.iter().any(|key| key.is_empty()) {
                return Err(UsageError::new("terminal key names cannot be empty"));
            }
            request(
                ResourceOperation::TerminalInputKeys,
                selectors,
                flags,
                map_with("keys", json!(keys)),
            )
        }
        [selector, "mouse", kind] => {
            selectors.insert("terminal", "term", selector)?;
            validate_one_of("--kind", kind, &["down", "up", "move", "wheel"])?;
            let mut params = Map::new();
            params.insert("kind".into(), Value::String((*kind).into()));
            insert_u16(&mut params, "row", "--row", flags.required("row")?)?;
            insert_u16(&mut params, "column", "--column", flags.required("column")?)?;
            let button = flags.take("button");
            let delta_rows = flags.take("delta-rows");
            match (*kind, button, delta_rows) {
                ("down" | "up", Some(button), None) => {
                    validate_one_of("--button", &button, &["left", "middle", "right"])?;
                    params.insert("button".into(), Value::String(button));
                }
                ("move", None, None) => {}
                ("wheel", None, Some(delta_rows)) => {
                    let delta_rows = delta_rows.parse::<i32>().map_err(|_| {
                        UsageError::new("--delta-rows must be a signed 32-bit integer")
                    })?;
                    if delta_rows == 0 {
                        return Err(UsageError::new("--delta-rows must be nonzero for wheel"));
                    }
                    params.insert("delta_rows".into(), json!(delta_rows));
                }
                ("down" | "up", None, _) => {
                    return Err(UsageError::new("--button is required for down and up"));
                }
                ("down" | "up", Some(_), Some(_)) => {
                    return Err(UsageError::new("--delta-rows is forbidden for down and up"));
                }
                ("move", Some(_), _) => {
                    return Err(UsageError::new("--button is forbidden for move"));
                }
                ("move", None, Some(_)) => {
                    return Err(UsageError::new("--delta-rows is forbidden for move"));
                }
                ("wheel", Some(_), _) => {
                    return Err(UsageError::new("--button is forbidden for wheel"));
                }
                ("wheel", None, None) => {
                    return Err(UsageError::new("--delta-rows is required for wheel"));
                }
                _ => unreachable!("kind validated above"),
            }
            insert_optional_enum_list(
                &mut params,
                flags,
                "modifiers",
                &["shift", "control", "alt", "meta"],
            )?;
            request(ResourceOperation::TerminalInputMouse, selectors, flags, params)
        }
        [selector, "focus", state] => {
            selectors.insert("terminal", "term", selector)?;
            if !matches!(*state, "in" | "out") {
                return Err(UsageError::new("terminal focus must be in or out"));
            }
            request(
                ResourceOperation::TerminalInputFocus,
                selectors,
                flags,
                map_with("focused", Value::Bool(*state == "in")),
            )
        }
        [selector, "read"] | [selector, "screen", "read"] => {
            selectors.insert("terminal", "term", selector)?;
            request(ResourceOperation::TerminalScreenRead, selectors, flags, Map::new())
        }
        [selector, "state", "read"] => {
            selectors.insert("terminal", "term", selector)?;
            request(ResourceOperation::TerminalStateRead, selectors, flags, Map::new())
        }
        [selector, "history", "read"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            if let Some(before) = flags.take("before") {
                validate_decimal("--before", &before)?;
                params.insert("before".into(), Value::String(before));
            }
            if let Some(limit) = flags.take("limit") {
                insert_bounded_u32(&mut params, "limit", "--limit", limit, 1, 10_000)?;
            }
            if flags.boolean("styled") {
                params.insert("styled".into(), Value::Bool(true));
            }
            request(ResourceOperation::TerminalHistoryRead, selectors, flags, params)
        }
        [selector, "history", "clear"] => {
            selectors.insert("terminal", "term", selector)?;
            request(ResourceOperation::TerminalHistoryClear, selectors, flags, Map::new())
        }
        [selector, "screen", "wait"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            let pattern = flags.required("pattern")?;
            if pattern.is_empty() {
                return Err(UsageError::new("--pattern cannot be empty"));
            }
            params.insert("pattern".into(), Value::String(pattern));
            if let Some(timeout) = flags.take("timeout-ms") {
                insert_decimal(&mut params, "timeout_ms", "--timeout-ms", timeout)?;
            }
            request(ResourceOperation::TerminalWait, selectors, flags, params)
        }
        [selector, "copy"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            if let Some(mode) = flags.take("mode") {
                validate_one_of("--mode", &mode, &["screen", "selection", "scrollback"])?;
                params.insert("mode".into(), Value::String(mode));
            }
            request(ResourceOperation::TerminalCopy, selectors, flags, params)
        }
        [selector, "process", "show"] => {
            selectors.insert("terminal", "term", selector)?;
            request(ResourceOperation::TerminalProcessGet, selectors, flags, Map::new())
        }
        [selector, "process", "wait"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            if let Some(timeout) = flags.take("timeout-ms") {
                insert_decimal(&mut params, "timeout_ms", "--timeout-ms", timeout)?;
            }
            request(ResourceOperation::TerminalWaitExit, selectors, flags, params)
        }
        [selector, "viewport", "scroll"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            insert_i32(&mut params, "delta_rows", "--delta-rows", flags.required("delta-rows")?)?;
            request(ResourceOperation::TerminalViewportScroll, selectors, flags, params)
        }
        [selector, "move"] => {
            selectors.insert("terminal", "term", selector)?;
            let params = destination_params(flags)?;
            request(ResourceOperation::TerminalMove, selectors, flags, params)
        }
        [selector, "project"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = destination_params(flags)?;
            if let Some(name) = flags.take("name") {
                params.insert("name".into(), Value::String(name));
            }
            request(ResourceOperation::TerminalProject, selectors, flags, params)
        }
        [selector, "attach"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            add_stream_id(&mut params, flags)?;
            add_size(&mut params, flags)?;
            if flags.boolean("read-only") {
                params.insert("read_only".into(), Value::Bool(true));
            }
            request(ResourceOperation::TerminalAttach, selectors, flags, params)
        }
        [selector, "close"] => {
            selectors.insert("terminal", "term", selector)?;
            request(ResourceOperation::TerminalClose, selectors, flags, Map::new())
        }
        _ => usage("terminal action"),
    }
}

fn parse_browser(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    match strs(words).as_slice() {
        ["list"] => request(ResourceOperation::BrowserList, selectors, flags, Map::new()),
        [selector, "show"] => {
            selectors.insert("browser", "browser", selector)?;
            request(ResourceOperation::BrowserGet, selectors, flags, Map::new())
        }
        [selector, "navigate"] => {
            selectors.insert("browser", "browser", selector)?;
            let url = flags.required("url")?;
            if url.is_empty() {
                return Err(UsageError::new("--url cannot be empty"));
            }
            request(
                ResourceOperation::BrowserNavigate,
                selectors,
                flags,
                map_with("url", Value::String(url)),
            )
        }
        [selector, "back"] => {
            browser_no_args(ResourceOperation::BrowserBack, selector, selectors, flags)
        }
        [selector, "forward"] => {
            browser_no_args(ResourceOperation::BrowserForward, selector, selectors, flags)
        }
        [selector, "reload"] => {
            browser_no_args(ResourceOperation::BrowserReload, selector, selectors, flags)
        }
        [selector, "activate"] => {
            browser_no_args(ResourceOperation::BrowserActivate, selector, selectors, flags)
        }
        [selector, "key"] => {
            selectors.insert("browser", "browser", selector)?;
            let mut params = Map::new();
            let key = flags.required("key")?;
            if key.is_empty() {
                return Err(UsageError::new("--key cannot be empty"));
            }
            params.insert("key".into(), Value::String(key));
            if let Some(kind) = flags.take("kind") {
                validate_one_of("--kind", &kind, &["down", "up", "press"])?;
                params.insert("kind".into(), Value::String(kind));
            }
            insert_optional_enum_list(
                &mut params,
                flags,
                "modifiers",
                &["shift", "control", "alt", "meta"],
            )?;
            request(ResourceOperation::BrowserInputKey, selectors, flags, params)
        }
        [selector, "text"] => {
            selectors.insert("browser", "browser", selector)?;
            let text = flags.required("text")?;
            request(
                ResourceOperation::BrowserInputText,
                selectors,
                flags,
                map_with("text", Value::String(text)),
            )
        }
        [selector, "mouse"] => {
            selectors.insert("browser", "browser", selector)?;
            let mut params = Map::new();
            let kind = flags.required("kind")?;
            validate_one_of("--kind", &kind, &["down", "up", "move"])?;
            params.insert("kind".into(), Value::String(kind.clone()));
            insert_float(&mut params, "x_px", "--x-px", flags.required("x-px")?)?;
            insert_float(&mut params, "y_px", "--y-px", flags.required("y-px")?)?;
            let pointer_frame_seq = flags.required("pointer-frame-seq")?;
            validate_decimal("--pointer-frame-seq", &pointer_frame_seq)?;
            params.insert("pointer_frame_seq".into(), Value::String(pointer_frame_seq));
            match (kind.as_str(), flags.take("button"), flags.take("click-count")) {
                ("down" | "up", Some(button), click_count) => {
                    validate_one_of(
                        "--button",
                        &button,
                        &["left", "middle", "right", "back", "forward"],
                    )?;
                    params.insert("button".into(), Value::String(button));
                    if let Some(click_count) = click_count {
                        insert_u32(&mut params, "click_count", "--click-count", click_count)?;
                    }
                }
                ("down" | "up", None, _) => {
                    return Err(UsageError::new("--button is required for down and up"));
                }
                ("move", None, None) => {}
                ("move", Some(_), _) => {
                    return Err(UsageError::new("--button is forbidden for move"));
                }
                ("move", None, Some(_)) => {
                    return Err(UsageError::new("--click-count is forbidden for move"));
                }
                _ => unreachable!("kind validated above"),
            }
            request(ResourceOperation::BrowserInputMouse, selectors, flags, params)
        }
        [selector, "wheel"] => {
            selectors.insert("browser", "browser", selector)?;
            let mut params = Map::new();
            insert_float(&mut params, "delta_x", "--delta-x", flags.required("delta-x")?)?;
            insert_float(&mut params, "delta_y", "--delta-y", flags.required("delta-y")?)?;
            insert_float(&mut params, "x_px", "--x-px", flags.required("x-px")?)?;
            insert_float(&mut params, "y_px", "--y-px", flags.required("y-px")?)?;
            let pointer_frame_seq = flags.required("pointer-frame-seq")?;
            validate_decimal("--pointer-frame-seq", &pointer_frame_seq)?;
            params.insert("pointer_frame_seq".into(), Value::String(pointer_frame_seq));
            request(ResourceOperation::BrowserInputWheel, selectors, flags, params)
        }
        [selector, "attach"] => {
            selectors.insert("browser", "browser", selector)?;
            let mut params = Map::new();
            add_stream_id(&mut params, flags)?;
            add_pixel_size(&mut params, flags)?;
            request(ResourceOperation::BrowserAttach, selectors, flags, params)
        }
        [selector, "close"] => {
            selectors.insert("browser", "browser", selector)?;
            request(ResourceOperation::BrowserClose, selectors, flags, Map::new())
        }
        _ => usage("browser action"),
    }
}

fn browser_no_args(
    operation: ResourceOperation,
    selector: &str,
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    selectors.insert("browser", "browser", selector)?;
    request(operation, selectors, flags, Map::new())
}

fn parse_notification(words: &[String], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let selectors = Selectors::default();
    match strs(words).as_slice() {
        ["list"] => {
            let mut params = Map::new();
            if let Some(limit) = flags.take("limit") {
                insert_bounded_u32(&mut params, "limit", "--limit", limit, 1, 1_000)?;
            }
            request(ResourceOperation::NotificationList, &selectors, flags, params)
        }
        ["create"] => {
            let mut params = Map::new();
            let title = flags.required("title")?;
            if title.is_empty() {
                return Err(UsageError::new("--title cannot be empty"));
            }
            params.insert("title".into(), Value::String(title));
            params.insert("body".into(), Value::String(flags.required("body")?));
            if let Some(level) = flags.take("level") {
                validate_one_of("--level", &level, &["info", "success", "warning", "error"])?;
                params.insert("level".into(), Value::String(level));
            }
            if let Some(terminal) = flags.take("terminal") {
                validate_prefixed_id("terminal", "term", &terminal)?;
                params.insert("terminal_id".into(), Value::String(terminal));
            }
            request(ResourceOperation::NotificationCreate, &selectors, flags, params)
        }
        _ => usage("notification action"),
    }
}

fn parse_agent(words: &[String], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let selectors = Selectors::default();
    match strs(words).as_slice() {
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
        ["list"] => {
            let mut params = Map::new();
            if let Some(terminal) = flags.take("terminal") {
                validate_prefixed_id("terminal", "term", &terminal)?;
                params.insert("terminal_id".into(), Value::String(terminal));
            }
            if let Some(state) = flags.take("state") {
                validate_one_of(
                    "--state",
                    &state,
                    &["working", "blocked", "idle", "done", "unknown"],
                )?;
                params.insert("state".into(), Value::String(state));
            }
            request(ResourceOperation::AgentList, &selectors, flags, params)
        }
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
            let ingress = cmux_tui_core::agent_hook_journal_ingress(
                &source,
                &native_event,
                terminal.as_deref(),
                native,
            )
            .map_err(|error| UsageError::new(error.to_string()))?;
            if serde_json::to_vec(&ingress.payload)
                .map_err(|error| UsageError::new(format!("encode agent hook: {error}")))?
                .len()
                > MAX_NATIVE_PAYLOAD_BYTES as usize
            {
                return Err(UsageError::new(
                    "encoded agent hook payload cannot exceed 1048576 bytes",
                ));
            }
            request(
                ResourceOperation::SessionJournalAppend,
                &selectors,
                flags,
                map_with(
                    "event",
                    serde_json::to_value(ingress).map_err(|error| {
                        UsageError::new(format!("encode agent hook request: {error}"))
                    })?,
                ),
            )
        }
        ["report"] => {
            let terminal = flags.required("terminal")?;
            validate_prefixed_id("terminal", "term", &terminal)?;
            let state = flags.required("state")?;
            validate_one_of("--state", &state, &["working", "blocked", "idle", "done", "unknown"])?;
            let source = flags.required("source")?;
            validate_one_of("--source", &source, &["hook", "socket"])?;
            let mut params = json!({
                "terminal_id": terminal,
                "state": state,
                "source": source,
            })
            .as_object()
            .cloned()
            .expect("literal object");
            insert_optional_string(&mut params, flags, "source-session", "source_session");
            request(ResourceOperation::AgentReport, &selectors, flags, params)
        }
        _ => usage("agent action"),
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
        ["plugin", tail @ ..] => parse_plugin(tail, flags),
        _ => usage("sidebar action"),
    }
}

fn parse_plugin(words: &[&str], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
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
        _ => return usage("sidebar plugin action"),
    }
    let plan = PluginPlan {
        positionals,
        name: flags.take("name"),
        force: flags.boolean("force"),
        builtin,
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

fn parse_raw(words: &[String], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let refs = strs(words);
    if refs.as_slice() == ["command"] {
        let request = parse_json_flag(flags, "request-json")?;
        if !request.is_object() {
            return Err(UsageError::new("--request-json must be a JSON object"));
        }
        return Ok(CommandPlan::RawCommand(super::raw::RawCommandPlan { request }));
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
    for (key, value) in selectors.params() {
        params.insert(key, value);
    }
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
    Ok(CommandPlan::Protocol(RequestPlan {
        stream: class == OperationClass::StreamOpen,
        operation,
        params,
        idempotency_key: explicit_key,
    }))
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
        )
}

fn validate_one_of(flag: &str, value: &str, allowed: &[&str]) -> Result<(), UsageError> {
    if allowed.contains(&value) {
        Ok(())
    } else {
        Err(UsageError::new(format!("{flag} must be one of {}", allowed.join(", "))))
    }
}

fn parse_bool(flag: &str, value: &str) -> Result<bool, UsageError> {
    match value {
        "true" => Ok(true),
        "false" => Ok(false),
        _ => Err(UsageError::new(format!("{flag} must be true or false"))),
    }
}

fn insert_optional_string(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
    flag: &str,
    field: &str,
) {
    if let Some(value) = flags.take(flag) {
        params.insert(field.into(), Value::String(value));
    }
}

fn insert_optional_clearable_string(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
    name: &str,
) -> Result<(), UsageError> {
    let value = flags.take(name);
    let clear = flags.boolean(&format!("clear-{name}"));
    match (value, clear) {
        (Some(_), true) => {
            Err(UsageError::new(format!("--{name} and --clear-{name} are mutually exclusive")))
        }
        (Some(value), false) => {
            params.insert(name.into(), Value::String(value));
            Ok(())
        }
        (None, true) => {
            params.insert(name.into(), Value::Null);
            Ok(())
        }
        (None, false) => Ok(()),
    }
}

fn insert_optional_nullable_string(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
    flag: &str,
) -> Result<(), UsageError> {
    let field = flag.replace('-', "_");
    let value = flags.take(flag);
    let clear_flag = format!("clear-{flag}");
    let clear = flags.boolean(&clear_flag);
    match (value, clear) {
        (Some(_), true) => {
            Err(UsageError::new(format!("--{flag} and --{clear_flag} are mutually exclusive")))
        }
        (Some(value), false) => {
            params.insert(field, Value::String(value));
            Ok(())
        }
        (None, true) => {
            params.insert(field, Value::Null);
            Ok(())
        }
        (None, false) => Ok(()),
    }
}

fn insert_optional_nullable_bool(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
    flag: &str,
) -> Result<(), UsageError> {
    let field = flag.replace('-', "_");
    let value = flags.take(flag);
    let clear_flag = format!("clear-{flag}");
    let clear = flags.boolean(&clear_flag);
    match (value, clear) {
        (Some(_), true) => {
            Err(UsageError::new(format!("--{flag} and --{clear_flag} are mutually exclusive")))
        }
        (Some(value), false) => {
            params.insert(field, Value::Bool(parse_bool(&format!("--{flag}"), &value)?));
            Ok(())
        }
        (None, true) => {
            params.insert(field, Value::Null);
            Ok(())
        }
        (None, false) => Ok(()),
    }
}

fn insert_optional_nullable_json_object(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
    flag: &str,
) -> Result<(), UsageError> {
    let field = flag.replace('-', "_");
    let value = flags.take(flag);
    let clear_flag = format!("clear-{flag}");
    let clear = flags.boolean(&clear_flag);
    match (value, clear) {
        (Some(_), true) => {
            Err(UsageError::new(format!("--{flag} and --{clear_flag} are mutually exclusive")))
        }
        (Some(value), false) => {
            let parsed = parse_json_object(&format!("--{flag}"), &value)?;
            params.insert(field, parsed);
            Ok(())
        }
        (None, true) => {
            params.insert(field, Value::Null);
            Ok(())
        }
        (None, false) => Ok(()),
    }
}

fn parse_json_object(flag: &str, value: &str) -> Result<Value, UsageError> {
    let value: Value = serde_json::from_str(value)
        .map_err(|error| UsageError::new(format!("invalid {flag} JSON: {error}")))?;
    if value.is_object() {
        Ok(value)
    } else {
        Err(UsageError::new(format!("{flag} must be a JSON object")))
    }
}

fn validate_base64(flag: &str, value: &str) -> Result<(), UsageError> {
    BASE64
        .decode(value)
        .map(|_| ())
        .map_err(|error| UsageError::new(format!("{flag} is not canonical base64: {error}")))
}

fn validate_terminal_defaults(params: &Map<String, Value>) -> Result<(), UsageError> {
    for field in
        ["foreground", "background", "cursor", "selection_background", "selection_foreground"]
    {
        if let Some(color) = params.get(field).and_then(Value::as_str) {
            validate_color(&format!("--{}", field.replace('_', "-")), color)?;
        }
    }
    if let Some(style) = params.get("cursor_style").and_then(Value::as_str) {
        validate_one_of("--cursor-style", style, &["block", "bar", "underline"])?;
    }
    if let Some(palette) = params.get("palette").and_then(Value::as_object) {
        for (index, color) in palette {
            let valid_index = index == "0"
                || (!index.starts_with('0')
                    && index.parse::<u16>().is_ok_and(|value| value <= 255));
            if !valid_index {
                return Err(UsageError::new(
                    "--palette keys must be canonical decimal indexes from 0 to 255",
                ));
            }
            let color = color
                .as_str()
                .ok_or_else(|| UsageError::new("--palette values must be color strings"))?;
            validate_color("--palette", color)?;
        }
    }
    Ok(())
}

fn validate_color(flag: &str, value: &str) -> Result<(), UsageError> {
    if value.len() == 7
        && value.starts_with('#')
        && value[1..].bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        Ok(())
    } else {
        Err(UsageError::new(format!("{flag} must use #rrggbb")))
    }
}

fn insert_optional_enum_list(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
    name: &str,
    allowed: &[&str],
) -> Result<(), UsageError> {
    let Some(value) = flags.take(name) else { return Ok(()) };
    let values = if value.is_empty() {
        Vec::new()
    } else {
        value.split(',').map(str::to_owned).collect::<Vec<_>>()
    };
    for value in &values {
        validate_one_of(&format!("--{name}"), value, allowed)?;
    }
    params.insert(name.replace('-', "_"), json!(values));
    Ok(())
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
    let mut params = Map::new();
    params.insert("name".into(), Value::String(flags.required("name")?));
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
    Ok(params)
}

fn add_size(params: &mut Map<String, Value>, flags: &mut Flags) -> Result<(), UsageError> {
    let cols = flags.take("cols");
    let rows = flags.take("rows");
    match (cols, rows) {
        (None, None) => Ok(()),
        (Some(cols), Some(rows)) => {
            insert_positive_u16(params, "cols", "--cols", cols)?;
            insert_positive_u16(params, "rows", "--rows", rows)
        }
        _ => Err(UsageError::new("--cols and --rows must be supplied together")),
    }
}

fn add_required_size(params: &mut Map<String, Value>, flags: &mut Flags) -> Result<(), UsageError> {
    insert_positive_u16(params, "cols", "--cols", flags.required("cols")?)?;
    insert_positive_u16(params, "rows", "--rows", flags.required("rows")?)
}

fn add_pixel_size(params: &mut Map<String, Value>, flags: &mut Flags) -> Result<(), UsageError> {
    let width = flags.take("width-px");
    let height = flags.take("height-px");
    match (width, height) {
        (None, None) => Ok(()),
        (Some(width), Some(height)) => {
            insert_positive_u32(params, "width_px", "--width-px", width)?;
            insert_positive_u32(params, "height_px", "--height-px", height)
        }
        _ => Err(UsageError::new("--width-px and --height-px must be supplied together")),
    }
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

fn add_journal_subscription(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
    default_start: Option<&str>,
    follow: bool,
) -> Result<(), UsageError> {
    let explicit_start = flags.take("from");
    if let Some(start) = explicit_start.as_deref() {
        validate_one_of("--from", start, &["tail", "beginning"])?;
    }
    let session_id = flags.take("cursor-session");
    let sequence = flags.take("sequence");
    match (session_id, sequence) {
        (None, None) => {
            if let Some(start) = explicit_start.or_else(|| default_start.map(str::to_owned)) {
                params.insert("start".into(), Value::String(start));
            }
        }
        (Some(session_id), Some(sequence)) if explicit_start.is_none() => {
            validate_prefixed_id("session", "session", &session_id)?;
            validate_decimal("--sequence", &sequence)?;
            params.insert("cursor".into(), json!({"generation":session_id,"revision":sequence}));
        }
        (Some(_), Some(_)) => {
            return Err(UsageError::new("--from cannot be combined with a journal cursor"));
        }
        _ => {
            return Err(UsageError::new(
                "--cursor-session and --sequence must be supplied together",
            ));
        }
    }
    if !follow {
        params.insert("follow".into(), Value::Bool(false));
    }

    let mut filter = Map::new();
    if let Some(kinds) = flags.take("kinds") {
        let kinds = comma_separated("--kinds", &kinds)?;
        for kind in &kinds {
            validate_cli_journal_kind(kind)?;
        }
        filter.insert("kinds".into(), Value::Array(kinds.into_iter().map(Value::String).collect()));
    }
    if let Some(classes) = flags.take("classes") {
        let classes = comma_separated("--classes", &classes)?;
        for class in &classes {
            validate_one_of("--classes", class, &["state", "observation", "effect", "checkpoint"])?;
        }
        filter.insert(
            "classes".into(),
            Value::Array(classes.into_iter().map(Value::String).collect()),
        );
    }
    if let Some(subjects) = flags.take("subjects") {
        let subjects = comma_separated("--subjects", &subjects)?
            .into_iter()
            .map(|subject| {
                let (kind, id) = subject
                    .split_once(':')
                    .ok_or_else(|| UsageError::new("--subjects entries must use <kind>:<id>"))?;
                if kind.is_empty()
                    || id.is_empty()
                    || !kind.bytes().all(|byte| {
                        byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_'
                    })
                {
                    return Err(UsageError::new(
                        "--subjects entries must use a lowercase <kind>:<id>",
                    ));
                }
                Ok(json!({"kind":kind,"id":id}))
            })
            .collect::<Result<Vec<_>, UsageError>>()?;
        filter.insert("subjects".into(), Value::Array(subjects));
    }
    if let Some(sensitivity) = flags.take("max-sensitivity") {
        validate_one_of("--max-sensitivity", &sensitivity, &["public", "metadata", "sensitive"])?;
        filter.insert("max_sensitivity".into(), Value::String(sensitivity));
    }
    let regex = flags.take("regex");
    let regex_field = flags.take("regex-field");
    let ignore_case = flags.boolean("ignore-case");
    match (regex, regex_field, ignore_case) {
        (Some(pattern), field, ignore_case) => {
            if pattern.is_empty() || pattern.len() > 1024 {
                return Err(UsageError::new("--regex must contain 1 to 1024 UTF-8 bytes"));
            }
            let field = field.unwrap_or_else(|| "record".into());
            validate_one_of(
                "--regex-field",
                &field,
                &["kind", "subjects", "payload", "record", "terminal_output"],
            )?;
            filter.insert(
                "regex".into(),
                json!({
                    "pattern":pattern,
                    "field":field,
                    "case_sensitive":!ignore_case,
                }),
            );
        }
        (None, Some(_), _) => {
            return Err(UsageError::new("--regex-field requires --regex"));
        }
        (None, None, true) => {
            return Err(UsageError::new("--ignore-case requires --regex"));
        }
        (None, None, false) => {}
    }
    if !filter.is_empty() {
        params.insert("filter".into(), Value::Object(filter));
    }
    Ok(())
}

fn comma_separated(flag: &str, value: &str) -> Result<Vec<String>, UsageError> {
    let values = value.split(',').map(str::to_string).collect::<Vec<_>>();
    if values.is_empty()
        || values.len() > 64
        || values.iter().any(|value| value.is_empty() || value.len() > 256)
    {
        return Err(UsageError::new(format!(
            "{flag} must contain 1 to 64 non-empty comma-separated values",
        )));
    }
    Ok(values)
}

fn validate_cli_journal_kind(kind: &str) -> Result<(), UsageError> {
    let base = kind.strip_suffix(".*").unwrap_or(kind);
    if base.is_empty()
        || kind.contains('*') != kind.ends_with(".*")
        || base.split('.').any(|part| {
            part.is_empty()
                || !part
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
        })
    {
        Err(UsageError::new("--kinds entries must be dotted names with an optional terminal .*"))
    } else {
        Ok(())
    }
}

fn parse_json_flag(flags: &mut Flags, name: &str) -> Result<Value, UsageError> {
    let value = flags.required(name)?;
    serde_json::from_str(&value)
        .map_err(|error| UsageError::new(format!("invalid --{name} JSON: {error}")))
}

fn apply_journal_hook_context(
    event: &mut Value,
    hook_id: Option<&str>,
    causation_id: Option<&str>,
    correlation_id: Option<&str>,
) -> Result<(), UsageError> {
    let hook_id = hook_id.filter(|value| !value.is_empty());
    let causation_id = causation_id.filter(|value| !value.is_empty());
    let correlation_id = correlation_id.filter(|value| !value.is_empty());
    if hook_id.is_none() && causation_id.is_none() && correlation_id.is_none() {
        return Ok(());
    }
    let object = event
        .as_object_mut()
        .ok_or_else(|| UsageError::new("--event-json must contain a JSON object"))?;
    if let Some(causation_id) = causation_id
        && object.get("causation_id").is_none_or(Value::is_null)
    {
        object.insert("causation_id".into(), Value::String(causation_id.into()));
    }
    if let Some(correlation_id) = correlation_id
        && object.get("correlation_id").is_none_or(Value::is_null)
    {
        object.insert("correlation_id".into(), Value::String(correlation_id.into()));
    }
    if let Some(hook_id) = hook_id {
        let subjects = object.entry("subjects").or_insert_with(|| Value::Array(Vec::new()));
        let subjects = subjects
            .as_array_mut()
            .ok_or_else(|| UsageError::new("--event-json subjects must contain a JSON array"))?;
        let already_present = subjects.iter().any(|subject| {
            subject.get("kind").and_then(Value::as_str) == Some("hook")
                && subject.get("id").and_then(Value::as_str) == Some(hook_id)
        });
        if !already_present {
            subjects.push(json!({"kind":"hook","id":hook_id}));
        }
    }
    Ok(())
}

fn insert_u16(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    let number = value
        .parse::<u16>()
        .map_err(|_| UsageError::new(format!("{flag} must be an unsigned 16-bit integer")))?;
    params.insert(field.into(), Value::Number(Number::from(number)));
    Ok(())
}

fn insert_positive_u16(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    let number = value
        .parse::<u16>()
        .ok()
        .filter(|number| *number > 0)
        .ok_or_else(|| UsageError::new(format!("{flag} must be an integer from 1 to 65535")))?;
    params.insert(field.into(), Value::Number(Number::from(number)));
    Ok(())
}

fn insert_u32(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    let number = value
        .parse::<u32>()
        .map_err(|_| UsageError::new(format!("{flag} must be an unsigned 32-bit integer")))?;
    params.insert(field.into(), Value::Number(Number::from(number)));
    Ok(())
}

fn insert_positive_u32(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    insert_bounded_u32(params, field, flag, value, 1, u32::MAX)
}

fn insert_bounded_u32(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
    minimum: u32,
    maximum: u32,
) -> Result<(), UsageError> {
    let number = value
        .parse::<u32>()
        .ok()
        .filter(|number| (minimum..=maximum).contains(number))
        .ok_or_else(|| {
            UsageError::new(format!("{flag} must be an integer from {minimum} to {maximum}"))
        })?;
    params.insert(field.into(), Value::Number(Number::from(number)));
    Ok(())
}

fn insert_i32(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    let number = value
        .parse::<i32>()
        .map_err(|_| UsageError::new(format!("{flag} must be a signed 32-bit integer")))?;
    params.insert(field.into(), Value::Number(Number::from(number)));
    Ok(())
}

fn insert_decimal(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    validate_decimal(flag, &value)?;
    params.insert(field.into(), Value::String(value));
    Ok(())
}

fn insert_float(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    let number = value
        .parse::<f64>()
        .ok()
        .filter(|number| number.is_finite())
        .and_then(Number::from_f64)
        .ok_or_else(|| UsageError::new(format!("{flag} must be a finite number")))?;
    params.insert(field.into(), Value::Number(number));
    Ok(())
}

fn insert_ratio(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    let number = value
        .parse::<f64>()
        .ok()
        .filter(|number| number.is_finite() && *number > 0.0 && *number < 1.0)
        .and_then(Number::from_f64)
        .ok_or_else(|| UsageError::new(format!("{flag} must be greater than 0 and less than 1")))?;
    params.insert(field.into(), Value::Number(number));
    Ok(())
}

fn insert_viewport_width(
    params: &mut Map<String, Value>,
    field: &str,
    flag: &str,
    value: String,
) -> Result<(), UsageError> {
    let number = value
        .parse::<f64>()
        .ok()
        .filter(|number| number.is_finite() && (0.1..=1.0).contains(number))
        .and_then(Number::from_f64)
        .ok_or_else(|| UsageError::new(format!("{flag} must be from 0.1 through 1")))?;
    params.insert(field.into(), Value::Number(number));
    Ok(())
}

fn map_with(name: &str, value: Value) -> Map<String, Value> {
    let mut map = Map::new();
    map.insert(name.into(), value);
    map
}

fn validate_selector(scope: &str, prefix: &str, value: &str) -> Result<(), UsageError> {
    let selector = Selector::parse(value).map_err(|error| UsageError::new(error.message))?;
    if matches!(selector, Selector::Id(_)) {
        validate_prefixed_id(scope, prefix, value)?;
    }
    Ok(())
}

fn validate_prefixed_id(scope: &str, prefix: &str, value: &str) -> Result<(), UsageError> {
    let Some(payload) = value.strip_prefix(&format!("{prefix}_")) else {
        return Err(UsageError::new(format!("{scope} ID must start with {prefix}_")));
    };
    if payload.len() != 32
        || !payload.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(UsageError::new(format!(
            "{scope} ID must contain exactly 32 lowercase hexadecimal digits"
        )));
    }
    Ok(())
}

fn validate_direction(value: &str) -> Result<(), UsageError> {
    if matches!(value, "left" | "right" | "up" | "down") {
        Ok(())
    } else {
        Err(UsageError::new("direction must be left, right, up, or down"))
    }
}

fn validate_decimal(flag: &str, value: &str) -> Result<(), UsageError> {
    if value == "0"
        || (!value.starts_with('0')
            && value.len() <= 20
            && value.bytes().all(|byte| byte.is_ascii_digit())
            && value.parse::<u64>().is_ok())
    {
        Ok(())
    } else {
        Err(UsageError::new(format!("{flag} must be a canonical unsigned decimal string")))
    }
}

fn validate_operation_name(value: &str) -> Result<(), UsageError> {
    let mut parts = value.split('.');
    let Some(first) = parts.next() else {
        return Err(UsageError::new("operation name is empty"));
    };
    let rest = parts.collect::<Vec<_>>();
    if rest.is_empty()
        || !std::iter::once(first).chain(rest).all(|part| {
            !part.is_empty()
                && part.as_bytes()[0].is_ascii_lowercase()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
        })
    {
        return Err(UsageError::new("operation must be a lowercase dotted name"));
    }
    Ok(())
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

fn usage<T>(what: &str) -> Result<T, UsageError> {
    Err(UsageError::new(format!("unknown or incomplete {what}; use --help")))
}

pub(super) fn run_plugin(global: GlobalArgs, plan: PluginPlan) -> i32 {
    match crate::plugin_manager::execute(
        &plan.positionals,
        crate::plugin_manager::CliOptions {
            name: plan.name,
            force: plan.force,
            builtin: plan.builtin,
        },
    ) {
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
    let result = crate::agent_hook_install::run(&plan);
    if result.failed {
        let error = json!({
            "code": "local.agent_hooks",
            "message": "one or more coding-agent hook operations failed",
            "details": result.value,
            "retryable": false,
        });
        super::wire::print_local_error(&error, global.output, 1)
    } else {
        super::wire::print_local_success(&result.value, global.output)
    }
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

pub(super) fn run_session_reset_state(global: GlobalArgs, plan: SessionResetStatePlan) -> i32 {
    let output = global.output;
    let messages = &crate::localization::catalog().session_reset;
    let routing_options = [
        global.socket.as_ref().map(|_| "--socket"),
        global.session.as_ref().map(|_| "--session"),
        global.machine.as_ref().map(|_| "--machine"),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>();
    if !routing_options.is_empty() {
        let options = routing_options.join(", ");
        return super::wire::print_local_error(
            &json!({
                "code": "session.reset_state.routing_options_unsupported",
                "message": messages.routing_options_unsupported(&options),
                "details": { "options": routing_options },
                "retryable": false,
            }),
            output,
            2,
        );
    }
    let state_root =
        match plan.state.map(PathBuf::from).or_else(cmux_tui_core::platform::workspace_state_dir) {
            Some(path) => path,
            None => {
                return super::wire::print_local_error(
                    &json!({
                        "code": "session.reset_state.no_state_root",
                        "message": messages.no_state_root,
                        "details": {},
                        "retryable": false,
                    }),
                    output,
                    1,
                );
            }
        };
    let resetter = cmux_tui_core::PersistentSessionStateResetter::new(state_root);
    if !plan.force {
        let preview = match resetter.preview(&plan.session) {
            Ok(preview) => preview,
            Err(error) => {
                let advice = reset_failure_advice(&error);
                return super::wire::print_local_error(
                    &json!({
                        "code": advice.code,
                        "message": format!("{}; {}", messages.reset_failed(&plan.session), advice.recovery),
                        "details": {
                            "session": &plan.session,
                            "reason": advice.reason,
                            "recovery": advice.recovery,
                        },
                        "retryable": false,
                    }),
                    output,
                    1,
                );
            }
        };
        return super::wire::print_local_success(
            &json!({
                "session": plan.session,
                "state_root": preview.state_root,
                "session_dir": preview.session_dir,
                "terminal_host_root": preview.terminal_host_root,
                "pending_reset_dirs": preview.pending_reset_dirs,
                "requires_force": preview.requires_force,
                "confirm_reset": preview.confirm_reset,
            }),
            output,
        );
    }
    match resetter.reset(&plan.session, plan.confirm_reset.as_deref()) {
        Ok(reset) => super::wire::print_local_success(
            &json!({
                "session": plan.session,
                "removed_session_state": reset.removed_session_state,
                "removed_terminal_hosts": reset.removed_terminal_hosts,
            }),
            output,
        ),
        Err(error) => {
            let advice = reset_failure_advice(&error);
            let message = if advice.code == "session.reset_state.confirmation_required" {
                format!("{}; {}", messages.confirmation_required, messages.confirmation_recovery)
            } else {
                format!("{}; {}", messages.reset_failed(&plan.session), advice.recovery)
            };
            super::wire::print_local_error(
                &json!({
                    "code": advice.code,
                    "message": message,
                    "details": {
                        "session": plan.session,
                        "reason": advice.reason,
                        "recovery": advice.recovery,
                    },
                    "retryable": false,
                }),
                output,
                1,
            )
        }
    }
}

struct ResetFailureAdvice {
    code: &'static str,
    reason: &'static str,
    recovery: &'static str,
}

fn reset_failure_advice(error: &anyhow::Error) -> ResetFailureAdvice {
    let messages = &crate::localization::catalog().session_reset;
    if reset_error_starts_with(error, &["reset confirmation is required"]) {
        ResetFailureAdvice {
            code: "session.reset_state.confirmation_required",
            reason: messages.confirmation_required,
            recovery: messages.confirmation_recovery,
        }
    } else if reset_error_starts_with(
        error,
        &["safe saved-state reset is not supported on this platform"],
    ) {
        ResetFailureAdvice {
            code: "session.reset_state.unsupported",
            reason: messages.reason_reset_unsupported,
            recovery: messages.recovery_reset_unsupported,
        }
    } else if reset_error_starts_with(
        error,
        &[
            "workspace state root is not a directory",
            "workspace session state path is not a directory",
            "terminal host state path is not a directory",
            "private reset path is not a directory",
            "session lock directory is not a directory",
            "not a directory:",
        ],
    ) {
        ResetFailureAdvice {
            code: "session.reset_state.invalid_state_path",
            reason: messages.reason_invalid_state_path,
            recovery: messages.recovery_invalid_state_path,
        }
    } else if reset_error_starts_with(
        error,
        &["workspace session is already owned by another daemon"],
    ) {
        ResetFailureAdvice {
            code: "session.reset_state.session_running",
            reason: messages.reason_session_running,
            recovery: messages.recovery_session_running,
        }
    } else if reset_error_starts_with(
        error,
        &[
            "terminal host state still has live or unverified hosts",
            "terminal host state has live or unverified hosts",
        ],
    ) {
        ResetFailureAdvice {
            code: "session.reset_state.terminal_hosts_live",
            reason: messages.reason_terminal_hosts_live,
            recovery: messages.recovery_terminal_hosts_live,
        }
    } else if reset_error_starts_with(
        error,
        &["terminal host liveness cannot be verified on this platform"],
    ) {
        ResetFailureAdvice {
            code: "session.reset_state.terminal_hosts_unsupported",
            reason: messages.reason_terminal_hosts_unsupported,
            recovery: messages.recovery_terminal_hosts_unsupported,
        }
    } else if reset_error_starts_with(
        error,
        &["reset path changed during reset", "reset path changed during fingerprint"],
    ) {
        ResetFailureAdvice {
            code: "session.reset_state.state_changed",
            reason: messages.reason_state_changed,
            recovery: messages.recovery_state_changed,
        }
    } else if reset_error_starts_with(error, &["reset confirmation scan exceeds"]) {
        ResetFailureAdvice {
            code: "session.reset_state.state_too_large",
            reason: messages.reason_state_too_large,
            recovery: messages.recovery_state_too_large,
        }
    } else {
        ResetFailureAdvice {
            code: "session.reset_state.filesystem",
            reason: messages.reason_filesystem,
            recovery: messages.recovery_filesystem,
        }
    }
}

fn reset_error_starts_with(error: &anyhow::Error, prefixes: &[&str]) -> bool {
    error.chain().any(|cause| {
        let cause = cause.to_string();
        prefixes.iter().any(|prefix| cause.starts_with(prefix))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_string()).collect()
    }

    #[test]
    fn boolean_flag_metadata_matches_tokenizer_contract() {
        for name in BOOLEAN_FLAGS {
            assert!(is_boolean_flag(name));
            let args = vec!["workspace".into(), "create".into(), format!("--{name}")];
            let tokens = tokenize(&args).expect("metadata flag must tokenize");
            assert!(tokens.flags.values.contains_key(*name));
            assert_eq!(tokens.flags.values[*name], None);
        }
    }

    #[test]
    fn non_boolean_flags_still_consume_the_next_token() {
        let tokens = tokenize(&strings(&["workspace", "create", "--name", "value"]))
            .expect("value flag must tokenize");
        assert_eq!(tokens.flags.values.get("name"), Some(&Some("value".to_string())));
    }

    #[test]
    fn bounded_text_validation_has_shared_limits() {
        assert!(validate_bounded_text("--name", "ok").is_ok());
        assert!(validate_bounded_text("--name", "").is_err());
        assert!(validate_bounded_text("--name", &"x".repeat(129)).is_err());
        assert!(validate_bounded_text("--name", &"x".repeat(128)).is_ok());
    }

    fn protocol(values: &[&str]) -> RequestPlan {
        match parse(&strings(values)).unwrap() {
            CommandPlan::Protocol(plan) => plan,
            _ => panic!("expected protocol plan"),
        }
    }

    #[test]
    fn coding_agent_hook_management_stays_local() {
        let CommandPlan::AgentHooks(plan) =
            parse(&strings(&["agent", "hook", "install", "codex", "claude-code"])).unwrap()
        else {
            panic!("expected local agent hook plan");
        };
        assert_eq!(plan.action, crate::agent_hook_install::Action::Install);
        assert_eq!(plan.providers, ["codex", "claude-code"]);
    }

    fn operation(plan: &RequestPlan) -> String {
        plan.operation.name().unwrap()
    }

    #[test]
    fn reset_failure_advice_classifies_fingerprint_race_as_state_changed() {
        let advice = reset_failure_advice(&anyhow::anyhow!(
            "reset path changed during fingerprint: /tmp/cmux-state/registry"
        ));
        assert_eq!(advice.code, "session.reset_state.state_changed");
        assert!(advice.recovery.contains("rerun the preview"), "{}", advice.recovery);
    }

    #[test]
    fn reset_failure_advice_classifies_confirmation_scan_limit() {
        let advice = reset_failure_advice(&anyhow::anyhow!(
            "reset confirmation scan exceeds 64 paths; scoped state is too large"
        ));
        assert_eq!(advice.code, "session.reset_state.state_too_large");
        assert!(advice.recovery.contains("reduce the scoped saved state"), "{}", advice.recovery);
    }

    #[test]
    fn reset_failure_advice_classifies_unsupported_checked_deletion() {
        let advice = reset_failure_advice(&anyhow::anyhow!(
            "safe saved-state reset is not supported on this platform because cmux cannot verify saved state during deletion"
        ));
        assert_eq!(advice.code, "session.reset_state.unsupported");
        assert!(advice.recovery.contains("supported platform build"), "{}", advice.recovery);
    }

    #[test]
    fn reset_failure_advice_ignores_marker_text_inside_paths() {
        let advice = reset_failure_advice(&anyhow::anyhow!(
            "workspace state root is not a directory: /tmp/already owned by another daemon"
        ));
        assert_eq!(advice.code, "session.reset_state.invalid_state_path");
    }

    fn operation_catalog() -> Value {
        serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../spec/resource-operations-v2.json"
        )))
        .expect("canonical operation catalog")
    }

    fn assert_plan_matches_catalog(plan: &RequestPlan, expected: &str, catalog: &Value) {
        let descriptor = &catalog["operations"][expected];
        assert!(descriptor.is_object(), "catalog omitted {expected}");
        let params = plan.params.as_object().expect("CLI params object");
        let selectors = descriptor["params"]["selectors"].as_object().expect("catalog selectors");
        let fields = descriptor["params"]["fields"].as_object().expect("catalog fields");

        for key in params.keys() {
            assert!(
                selectors.contains_key(key) || fields.contains_key(key),
                "{expected} emitted forbidden catalog parameter {key:?}: {params:?}"
            );
        }
        for (key, requiredness) in selectors {
            if requiredness == "required" {
                assert!(
                    params.contains_key(key),
                    "{expected} omitted required selector {key:?}: {params:?}"
                );
            }
        }
        for (key, field) in fields {
            if field["required"] == true {
                assert!(
                    params.contains_key(key),
                    "{expected} omitted required field {key:?}: {params:?}"
                );
            }
        }
        if let Some(alternatives) = descriptor["params"]["one_of"].as_array() {
            assert!(
                alternatives.iter().any(|alternative| {
                    alternative["required"].as_array().is_none_or(|required| {
                        required
                            .iter()
                            .filter_map(Value::as_str)
                            .all(|key| params.contains_key(key))
                    }) && alternative["forbidden"].as_array().is_none_or(|forbidden| {
                        forbidden
                            .iter()
                            .filter_map(Value::as_str)
                            .all(|key| !params.contains_key(key))
                    })
                }),
                "{expected} violates its catalog one_of: {params:?}"
            );
        }

        let class = match plan.operation.class() {
            OperationClass::Read => "read",
            OperationClass::Mutation => "mutation",
            OperationClass::StreamOpen => "stream_open",
            OperationClass::ConnectionControl => "connection_control",
            OperationClass::Local => "local",
        };
        assert_eq!(descriptor["class"], class, "{expected} class drift");
        assert_eq!(plan.stream, class == "stream_open", "{expected} stream drift");
    }

    #[test]
    fn direct_and_nested_paths_share_operations_and_flat_ancestors() {
        let direct = protocol(&["pane", "pane_33333333333333333333333333333333", "show"]);
        let nested = protocol(&[
            "workspace",
            "ws_11111111111111111111111111111111",
            "screen",
            "screen_22222222222222222222222222222222",
            "pane",
            "pane_33333333333333333333333333333333",
            "show",
        ]);
        assert_eq!(operation(&direct), "pane.get");
        assert_eq!(operation(&nested), "pane.get");
        assert_eq!(
            direct.params,
            json!({
                "machine":"current",
                "session":"current",
                "pane":"pane_33333333333333333333333333333333"
            })
        );
        assert_eq!(
            nested.params,
            json!({
                "machine":"current",
                "session":"current",
                "workspace":"ws_11111111111111111111111111111111",
                "screen":"screen_22222222222222222222222222222222",
                "pane":"pane_33333333333333333333333333333333"
            })
        );
    }

    #[test]
    fn name_and_current_targets_fill_a_contiguous_structural_context() {
        let named = protocol(&["terminal", "name:build", "show"]);
        assert_eq!(
            named.params,
            json!({
                "machine": "current",
                "session": "current",
                "workspace": "current",
                "screen": "current",
                "pane": "current",
                "tab": "current",
                "terminal": "name:build",
            })
        );
    }

    #[test]
    fn workspace_creation_has_explicit_initial_content() {
        let terminal = protocol(&["workspace", "create"]);
        assert_eq!(terminal.params["initial_content"], "terminal");
        let empty = protocol(&["workspace", "create", "--empty"]);
        assert_eq!(empty.params["initial_content"], "empty");
    }

    #[test]
    fn creation_correlation_is_bounded_and_scoped() {
        let correlated =
            protocol(&["workspace", "create", "--correlation-key", "creation-attempt-1"]);
        assert_eq!(correlated.params["correlation_key"], "creation-attempt-1");

        assert!(parse(&strings(&["workspace", "create", "--correlation-key="])).is_err());
        assert!(
            parse(&strings(&["workspace", "create", "--correlation-key", &"x".repeat(129),]))
                .is_err()
        );
        assert!(
            parse(&strings(&["workspace", "list", "--correlation-key", "creation-attempt-1",]))
                .is_err()
        );
        assert!(
            parse(&strings(&["session", "current", "creation", &"x".repeat(129), "resolve",]))
                .is_err()
        );
    }

    #[test]
    fn terminal_screen_and_process_wait_are_distinct_paths() {
        const TERMINAL: &str = "term_00000000000000000000000000000008";
        const BROWSER: &str = "browser_00000000000000000000000000000009";
        let screen = protocol(&[
            "terminal",
            TERMINAL,
            "screen",
            "wait",
            "--pattern",
            "ready",
            "--timeout-ms",
            "5000",
        ]);
        assert_eq!(operation(&screen), "terminal.wait");
        assert_eq!(screen.params["timeout_ms"], "5000");

        let process = protocol(&["terminal", TERMINAL, "process", "wait", "--timeout-ms", "5000"]);
        assert_eq!(operation(&process), "terminal.wait_exit");
        assert_eq!(process.params["timeout_ms"], "5000");

        for invalid in ["-1", "01", "18446744073709551616"] {
            assert!(
                parse(&strings(&[
                    "terminal",
                    TERMINAL,
                    "process",
                    "wait",
                    "--timeout-ms",
                    invalid,
                ]))
                .is_err(),
                "accepted noncanonical timeout {invalid:?}"
            );
        }

        assert!(parse(&strings(&["terminal", TERMINAL, "wait", "--pattern", "ready"])).is_err());
        for unreachable in [
            vec!["terminal", TERMINAL, "viewer", "resize", "--cols", "80", "--rows", "24"],
            vec!["terminal", TERMINAL, "viewer", "release"],
            vec!["browser", BROWSER, "viewer", "resize", "--width-px", "800", "--height-px", "600"],
            vec!["browser", BROWSER, "viewer", "release"],
            vec!["stream", "stream_0000000000000000000000000000000a", "cancel"],
        ] {
            assert!(parse(&strings(&unreachable)).is_err(), "{unreachable:?}");
        }
    }

    #[test]
    fn journal_subscribe_builds_replay_cursor_and_filter_contracts() {
        const SESSION: &str = "session_00000000000000000000000000000002";
        const WORKSPACE: &str = "ws_00000000000000000000000000000004";

        let replay = protocol(&[
            "session",
            SESSION,
            "journal",
            "subscribe",
            "--from",
            "beginning",
            "--kinds",
            "pane.*,tab.focus",
            "--classes",
            "state,effect",
            "--subjects",
            &format!("workspace:{WORKSPACE}"),
            "--max-sensitivity",
            "metadata",
            "--regex",
            "journal|resumed",
            "--regex-field",
            "payload",
            "--ignore-case",
        ]);
        assert_eq!(operation(&replay), "session.journal.subscribe");
        assert!(replay.stream);
        assert_eq!(replay.params["start"], "beginning");
        assert_eq!(replay.params["filter"]["kinds"], json!(["pane.*", "tab.focus"]));
        assert_eq!(replay.params["filter"]["classes"], json!(["state", "effect"]));
        assert_eq!(
            replay.params["filter"]["subjects"],
            json!([{"kind":"workspace","id":WORKSPACE}])
        );
        assert_eq!(replay.params["filter"]["max_sensitivity"], "metadata");
        assert_eq!(
            replay.params["filter"]["regex"],
            json!({
                "pattern":"journal|resumed",
                "field":"payload",
                "case_sensitive":false,
            })
        );

        let resumed = protocol(&[
            "session",
            SESSION,
            "journal",
            "subscribe",
            "--cursor-session",
            SESSION,
            "--sequence",
            "42",
        ]);
        assert_eq!(resumed.params["cursor"], json!({"generation":SESSION,"revision":"42"}));
        assert!(resumed.params.get("start").is_none());

        let read = protocol(&["session", SESSION, "journal", "read", "--kinds", "agent.*"]);
        assert_eq!(operation(&read), "session.journal.subscribe");
        assert_eq!(read.params["start"], "beginning");
        assert_eq!(read.params["follow"], false);
        assert_eq!(read.params["filter"]["kinds"], json!(["agent.*"]));

        let read_from_cursor = protocol(&[
            "session",
            SESSION,
            "journal",
            "read",
            "--cursor-session",
            SESSION,
            "--sequence",
            "42",
        ]);
        assert!(read_from_cursor.params.get("start").is_none());
        assert_eq!(read_from_cursor.params["follow"], false);

        for invalid in [
            vec!["--from", "beginning", "--cursor-session", SESSION, "--sequence", "1"],
            vec!["--cursor-session", SESSION],
            vec!["--kinds", "pane*"],
            vec!["--classes", "unknown"],
            vec!["--subjects", "workspace"],
            vec!["--max-sensitivity", "secret"],
            vec!["--regex-field", "payload"],
            vec!["--ignore-case"],
            vec!["--regex", "value", "--regex-field", "unknown"],
        ] {
            let mut args = vec!["session", SESSION, "journal", "subscribe"];
            args.extend(invalid);
            assert!(parse(&strings(&args)).is_err(), "accepted {args:?}");
        }

        let manifest = r#"{"producer_id":"demo","namespace":"plugin.demo"}"#;
        let producer = protocol(&[
            "session",
            SESSION,
            "journal",
            "producer",
            "put",
            "--manifest-json",
            manifest,
            "--idempotency-key",
            "producer-put-1",
        ]);
        assert_eq!(operation(&producer), "session.journal.producer.put");
        assert_eq!(producer.params["manifest"]["producer_id"], "demo");
        assert_eq!(producer.idempotency_key.as_deref(), Some("producer-put-1"));

        let append = protocol(&[
            "session",
            SESSION,
            "journal",
            "append",
            "--event-json",
            r#"{"producer_id":"demo","payload":{"ready":true}}"#,
            "--idempotency-key",
            "append-1",
        ]);
        assert_eq!(operation(&append), "session.journal.append");
        assert_eq!(append.params["event"]["payload"]["ready"], true);

        let hooks = protocol(&["session", SESSION, "journal", "hook", "list"]);
        assert_eq!(operation(&hooks), "session.journal.hook.list");

        let hook = protocol(&[
            "session",
            SESSION,
            "journal",
            "hook",
            "put",
            "--manifest-json",
            r#"{"hook_id":"demo_hook","manifest_version":1}"#,
            "--idempotency-key",
            "hook-put-1",
        ]);
        assert_eq!(operation(&hook), "session.journal.hook.put");
        assert_eq!(hook.params["manifest"]["hook_id"], "demo_hook");
        assert_eq!(hook.idempotency_key.as_deref(), Some("hook-put-1"));

        let checkpoint = protocol(&[
            "session",
            SESSION,
            "journal",
            "checkpoint",
            "create",
            "--idempotency-key",
            "checkpoint-1",
        ]);
        assert_eq!(operation(&checkpoint), "session.journal.checkpoint.create");
        let checkpoints = protocol(&["session", SESSION, "journal", "checkpoint", "list"]);
        assert_eq!(operation(&checkpoints), "session.journal.checkpoint.list");

        let restore = protocol(&[
            "session",
            SESSION,
            "journal",
            "restore",
            "preview",
            "--checkpoint",
            "latest",
        ]);
        assert_eq!(operation(&restore), "session.journal.restore.preview");
        assert_eq!(restore.params["checkpoint"], "latest");

        let segments = protocol(&["session", SESSION, "journal", "segment", "list"]);
        assert_eq!(operation(&segments), "session.journal.segment.list");
        let seal = protocol(&[
            "session",
            SESSION,
            "journal",
            "segment",
            "seal",
            "--through",
            "42",
            "--idempotency-key",
            "segment-1",
        ]);
        assert_eq!(operation(&seal), "session.journal.segment.seal");
        assert_eq!(seal.params["through_sequence"], "42");
    }

    #[test]
    fn agent_hook_emit_normalizes_and_preserves_the_native_payload() {
        const TERMINAL: &str = "term_00000000000000000000000000000008";
        let payload = r#"{"session_id":"native-session","message":"done","opaque":{"v":42}}"#;
        let first = protocol(&[
            "agent",
            "hook",
            "emit",
            "--source",
            "codex",
            "--event",
            "Stop",
            "--terminal",
            TERMINAL,
            "--payload-json",
            payload,
        ]);
        let second = protocol(&[
            "agent",
            "hook",
            "emit",
            "--source",
            "codex",
            "--event",
            "Stop",
            "--terminal",
            TERMINAL,
            "--payload-json",
            payload,
        ]);
        assert_eq!(operation(&first), "session.journal.append");
        assert_eq!(first.params["event"]["kind"], "agent.turn.completed");
        assert_eq!(first.params["event"]["payload"]["native"]["opaque"]["v"], 42);
        assert_eq!(
            first.params["event"]["payload"]["normalized"]["agent_session_id"],
            "native-session"
        );
        assert_eq!(first.params["event"]["subjects"][0]["id"], TERMINAL);
        assert_eq!(first.params["event"]["sensitivity"], "sensitive");
        for optional in ["occurred_at_ms", "causation_id", "correlation_id"] {
            assert!(
                first.params["event"].get(optional).is_none(),
                "absent optional field {optional} must not serialize as null"
            );
        }
        assert_eq!(first.idempotency_key, None);
        assert_eq!(second.idempotency_key, None);

        assert!(
            parse(&strings(&[
                "agent",
                "hook",
                "emit",
                "--source",
                "Invalid Source",
                "--event",
                "Stop",
                "--payload-json",
                "{}",
            ]))
            .is_err()
        );
    }

    #[test]
    fn journal_append_inherits_scoped_hook_causation() {
        let mut event = json!({
            "producer_id":"demo",
            "subjects":[{"kind":"workspace","id":"ws_test"}],
            "payload":{},
        });
        apply_journal_hook_context(
            &mut event,
            Some("demo_hook"),
            Some("event_hook_started"),
            Some("demo_hook:1:event_source"),
        )
        .unwrap();
        assert_eq!(event["causation_id"], "event_hook_started");
        assert_eq!(event["correlation_id"], "demo_hook:1:event_source");
        assert_eq!(
            event["subjects"],
            json!([
                {"kind":"workspace","id":"ws_test"},
                {"kind":"hook","id":"demo_hook"},
            ])
        );
    }

    #[test]
    fn run_never_infers_a_shell() {
        let direct = protocol(&["pane", "current", "run", "--", "printf", "%s", "a b"]);
        assert_eq!(direct.params["argv"], json!(["printf", "%s", "a b"]));
        assert!(direct.params.get("shell").is_none());

        let shell = protocol(&["pane", "current", "run", "shell", "printf 'ok'"]);
        assert_eq!(shell.params["shell"], "printf 'ok'");
        assert!(shell.params.get("argv").is_none());

        let empty_argument = protocol(&["pane", "current", "run", "--", "printf", ""]);
        assert_eq!(empty_argument.params["argv"], json!(["printf", ""]));
        assert!(parse(&strings(&["pane", "current", "run", "--", "", "argument"])).is_err());
        assert!(parse(&strings(&["pane", "current", "run", "echo ok"])).is_err());
    }

    #[test]
    fn input_commands_enforce_variant_constraints() {
        const TERMINAL: &str = "term_00000000000000000000000000000008";
        const BROWSER: &str = "browser_00000000000000000000000000000009";

        assert!(
            parse(&strings(&[
                "terminal", TERMINAL, "mouse", "down", "--row", "1", "--column", "1",
            ]))
            .is_err()
        );
        assert!(
            parse(&strings(&[
                "terminal",
                TERMINAL,
                "mouse",
                "wheel",
                "--row",
                "1",
                "--column",
                "1",
                "--delta-rows",
                "0",
            ]))
            .is_err()
        );
        assert!(
            parse(&strings(&[
                "terminal",
                TERMINAL,
                "mouse",
                "move",
                "--row",
                "1",
                "--column",
                "1",
                "--modifiers",
                "super",
            ]))
            .is_err()
        );
        let meta = protocol(&[
            "terminal",
            TERMINAL,
            "mouse",
            "move",
            "--row",
            "1",
            "--column",
            "1",
            "--modifiers",
            "meta",
        ]);
        assert_eq!(meta.params["modifiers"], json!(["meta"]));

        assert!(
            parse(&strings(&[
                "browser", BROWSER, "mouse", "--kind", "down", "--x-px", "1", "--y-px", "1",
            ]))
            .is_err()
        );
        assert!(
            parse(&strings(&[
                "browser", BROWSER, "mouse", "--kind", "move", "--x-px", "1", "--y-px", "1",
                "--button", "left",
            ]))
            .is_err()
        );
        assert!(
            parse(&strings(&[
                "browser",
                BROWSER,
                "wheel",
                "--delta-x",
                "0",
                "--delta-y",
                "1",
                "--x-px",
                "1",
            ]))
            .is_err()
        );
        assert!(
            parse(&strings(&[
                "browser", BROWSER, "mouse", "--kind", "move", "--x-px", "1", "--y-px", "1",
            ]))
            .is_err()
        );
        let guarded = protocol(&[
            "browser",
            BROWSER,
            "mouse",
            "--kind",
            "move",
            "--x-px",
            "1",
            "--y-px",
            "1",
            "--pointer-frame-seq",
            "18446744073709551615",
        ]);
        assert_eq!(guarded.params["pointer_frame_seq"], "18446744073709551615");
        assert!(
            parse(&strings(&[
                "browser",
                BROWSER,
                "wheel",
                "--delta-x",
                "0",
                "--delta-y",
                "1",
                "--x-px",
                "1",
                "--y-px",
                "1",
                "--pointer-frame-seq",
                "18446744073709551616",
            ]))
            .is_err()
        );
    }

    #[test]
    fn idempotency_is_only_for_mutations() {
        let mutation = protocol(&["workspace", "create"]);
        assert_eq!(mutation.operation.class(), OperationClass::Mutation);
        let read = parse(&strings(&["workspace", "list", "--idempotency-key", "no"]));
        assert!(read.is_err());
    }

    #[test]
    fn explicit_idempotency_keys_match_the_durable_identifier_contract() {
        for invalid in ["", " ", "\u{00a0}\u{3000}", "key\ncontrol", &"\u{00e9}".repeat(65)] {
            assert!(
                parse(&strings(&["workspace", "create", "--idempotency-key", invalid])).is_err(),
                "accepted invalid idempotency key {invalid:?}"
            );
        }
        for valid in [" key ", "\u{feff}", &"\u{00e9}".repeat(64)] {
            let plan = protocol(&["workspace", "create", "--idempotency-key", valid]);
            assert_eq!(plan.idempotency_key.as_deref(), Some(valid));
        }
    }

    #[test]
    fn nullable_fields_have_explicit_clear_flags() {
        const CLIENT: &str = "client_00000000000000000000000000000003";
        const SESSION: &str = "session_00000000000000000000000000000002";

        let client =
            protocol(&["client", CLIENT, "metadata", "set", "--clear-name", "--clear-kind"]);
        assert_eq!(client.params["name"], Value::Null);
        assert_eq!(client.params["kind"], Value::Null);

        let defaults = protocol(&[
            "session",
            SESSION,
            "terminal",
            "defaults",
            "set",
            "--clear-foreground",
            "--clear-cursor-blink",
            "--clear-palette",
        ]);
        assert_eq!(defaults.params["foreground"], Value::Null);
        assert_eq!(defaults.params["cursor_blink"], Value::Null);
        assert_eq!(defaults.params["palette"], Value::Null);

        assert!(
            parse(&strings(&[
                "client",
                CLIENT,
                "metadata",
                "set",
                "--name",
                "cli",
                "--clear-name",
            ]))
            .is_err()
        );
    }

    #[test]
    fn attach_allocates_a_typed_stream_id() {
        let attach = protocol(&["terminal", "term_55555555555555555555555555555555", "attach"]);
        assert!(
            attach.params["stream_id"].as_str().is_some_and(|value| value.starts_with("stream_"))
        );
        assert!(attach.stream);
    }

    #[test]
    fn wrong_resource_id_prefix_is_rejected_locally() {
        assert!(
            parse(&strings(&["workspace", "pane_33333333333333333333333333333333", "show",]))
                .is_err()
        );
    }

    #[test]
    fn agent_commands_use_canonical_public_states() {
        const TERMINAL: &str = "term_55555555555555555555555555555555";
        for state in ["working", "blocked", "idle", "done", "unknown"] {
            let list = protocol(&["agent", "list", "--terminal", TERMINAL, "--state", state]);
            assert_eq!(list.params["state"], state);
            let report = protocol(&[
                "agent",
                "report",
                "--terminal",
                TERMINAL,
                "--state",
                state,
                "--source",
                "socket",
            ]);
            assert_eq!(report.params["state"], state);
        }
        for noncanonical in ["running", "waiting", "error"] {
            assert!(
                parse(&strings(&[
                    "agent",
                    "report",
                    "--terminal",
                    TERMINAL,
                    "--state",
                    noncanonical,
                    "--source",
                    "socket",
                ]))
                .is_err(),
                "accepted noncanonical agent state {noncanonical:?}"
            );
        }
    }

    #[test]
    fn old_hyphenated_action_is_not_a_nested_selector() {
        assert!(
            parse(&strings(&[
                "terminal",
                "term_55555555555555555555555555555555",
                "history-clear",
            ]))
            .is_err()
        );
    }

    #[test]
    fn sensitive_renderer_grant_has_no_public_path() {
        for scope in ["terminal", "tab", "client"] {
            let args = strings(&[scope, "renderer", "grant", "create"]);
            assert!(parse(&args).is_err());
        }
        let raw = protocol(&[
            "raw",
            "operation",
            "terminal.renderer_grant.create",
            "--params-json",
            r#"{"machine":"current","session":"current","terminal":"term_00000000000000000000000000000001","ttl_ms":1000}"#,
        ]);
        assert_eq!(operation(&raw), "terminal.renderer_grant.create");
        assert_eq!(raw.operation.class(), OperationClass::ConnectionControl);
    }

    #[test]
    fn every_local_catalog_operation_has_a_socket_free_path() {
        let cases = [
            (
                vec![
                    "sidebar",
                    "plugin",
                    "install",
                    "https://example.com/plugin.git",
                    "--name",
                    "custom",
                    "--force",
                ],
                "sidebar_plugin.install",
            ),
            (vec!["sidebar", "plugin", "list"], "sidebar_plugin.list"),
            (vec!["sidebar", "plugin", "remove", "custom"], "sidebar_plugin.remove"),
            (vec!["sidebar", "plugin", "update", "custom"], "sidebar_plugin.update"),
            (vec!["sidebar", "plugin", "use", "custom"], "sidebar_plugin.use"),
            (vec!["sidebar", "plugin", "use", "--builtin"], "sidebar_plugin.use_builtin"),
        ];
        let mut seen = std::collections::BTreeSet::new();
        for (args, operation) in cases {
            let CommandPlan::Plugin(plan) = parse(&strings(&args)).unwrap() else {
                panic!("{operation} did not stay local");
            };
            assert!(!plan.positionals.is_empty());
            if operation == "sidebar_plugin.install" {
                assert_eq!(plan.name.as_deref(), Some("custom"));
                assert!(plan.force);
            }
            if operation == "sidebar_plugin.use_builtin" {
                assert!(plan.builtin);
            }
            seen.insert(operation);
        }
        let catalog = operation_catalog();
        let expected = catalog["local_operations"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(seen, expected);
    }

    #[test]
    fn every_safe_transport_operation_has_a_noun_first_path() {
        const MACHINE: &str = "machine_00000000000000000000000000000001";
        const SESSION: &str = "session_00000000000000000000000000000002";
        const CLIENT: &str = "client_00000000000000000000000000000003";
        const WORKSPACE: &str = "ws_00000000000000000000000000000004";
        const SCREEN: &str = "screen_00000000000000000000000000000005";
        const PANE: &str = "pane_00000000000000000000000000000006";
        const TAB: &str = "tab_00000000000000000000000000000007";
        const TERMINAL: &str = "term_00000000000000000000000000000008";
        const BROWSER: &str = "browser_00000000000000000000000000000009";
        const PAIRING: &str = "pairing_0000000000000000000000000000000b";
        const PROJECTION: &str = "projection_0000000000000000000000000000000c";
        const VIEW: &str = "sidebar_view_0000000000000000000000000000000d";

        let cases: Vec<(Vec<&str>, &str)> = vec![
            (vec!["machine", "list"], "machine.list"),
            (vec!["machine", MACHINE, "show"], "machine.get"),
            (vec!["machine", MACHINE, "session", "list"], "session.list"),
            (vec!["machine", MACHINE, "session", SESSION, "open"], "session.open"),
            (vec!["session", SESSION, "show"], "session.get"),
            (vec!["session", SESSION, "snapshot"], "session.snapshot"),
            (
                vec!["session", SESSION, "creation", "create-42", "resolve"],
                "session.creation.resolve",
            ),
            (
                vec!["session", SESSION, "events", "--generation", "g1", "--revision", "3"],
                "session.events",
            ),
            (
                vec![
                    "session",
                    SESSION,
                    "journal",
                    "read",
                    "--from",
                    "beginning",
                    "--kinds",
                    "pane.*,tab.focus",
                ],
                "session.journal.subscribe",
            ),
            (
                vec!["session", SESSION, "journal", "producer", "list"],
                "session.journal.producer.list",
            ),
            (
                vec![
                    "session",
                    SESSION,
                    "journal",
                    "producer",
                    "put",
                    "--manifest-json",
                    r#"{"producer_id":"demo","namespace":"plugin.demo"}"#,
                ],
                "session.journal.producer.put",
            ),
            (
                vec![
                    "session",
                    SESSION,
                    "journal",
                    "append",
                    "--event-json",
                    r#"{"producer_id":"demo","payload":{"ready":true}}"#,
                ],
                "session.journal.append",
            ),
            (vec!["session", SESSION, "journal", "hook", "list"], "session.journal.hook.list"),
            (
                vec![
                    "session",
                    SESSION,
                    "journal",
                    "hook",
                    "put",
                    "--manifest-json",
                    r#"{"hook_id":"demo_hook","manifest_version":1}"#,
                ],
                "session.journal.hook.put",
            ),
            (
                vec!["session", SESSION, "journal", "checkpoint", "create"],
                "session.journal.checkpoint.create",
            ),
            (
                vec!["session", SESSION, "journal", "checkpoint", "list"],
                "session.journal.checkpoint.list",
            ),
            (
                vec!["session", SESSION, "journal", "restore", "preview", "--checkpoint", "latest"],
                "session.journal.restore.preview",
            ),
            (
                vec!["session", SESSION, "journal", "segment", "list"],
                "session.journal.segment.list",
            ),
            (
                vec!["session", SESSION, "journal", "segment", "seal", "--through", "42"],
                "session.journal.segment.seal",
            ),
            (vec!["session", SESSION, "ping"], "session.ping"),
            (vec!["session", SESSION, "shutdown", "--force"], "session.shutdown"),
            (vec!["session", SESSION, "config", "reload"], "session.reload_config"),
            (
                vec![
                    "session",
                    SESSION,
                    "terminal",
                    "defaults",
                    "set",
                    "--foreground",
                    "#ffffff",
                    "--background",
                    "#000000",
                    "--cursor",
                    "#aaaaaa",
                    "--selection-background",
                    "#111111",
                    "--selection-foreground",
                    "#eeeeee",
                    "--cursor-style",
                    "bar",
                    "--cursor-blink",
                    "true",
                    "--palette",
                    "{\"0\":\"#000000\",\"255\":\"#ffffff\"}",
                    "--complete",
                ],
                "session.terminal_defaults.update",
            ),
            (vec!["client", "list"], "client.list"),
            (vec!["client", CLIENT, "show"], "client.get"),
            (
                vec!["client", CLIENT, "metadata", "set", "--name", "cli", "--kind", "automation"],
                "client.metadata.update",
            ),
            (
                vec![
                    "client",
                    CLIENT,
                    "sizing",
                    "set",
                    "--terminal",
                    TERMINAL,
                    "--enabled",
                    "true",
                    "--exclusive",
                    "true",
                ],
                "client.sizing.set",
            ),
            (
                vec!["client", CLIENT, "sizing", "release", "--terminal", TERMINAL],
                "client.sizing.release",
            ),
            (
                vec![
                    "client",
                    CLIENT,
                    "cell",
                    "pixels",
                    "set",
                    "--width-px",
                    "8",
                    "--height-px",
                    "16",
                ],
                "client.cell_pixels.set",
            ),
            (vec!["client", CLIENT, "detach"], "client.detach"),
            (
                vec!["session", SESSION, "window", "title", "set", "--title", "build"],
                "session.window.title.set",
            ),
            (vec!["session", SESSION, "window", "title", "clear"], "session.window.title.clear"),
            (vec!["pairing", "request", "list"], "pairing_request.list"),
            (vec!["pairing", "request", PAIRING, "respond", "accept"], "pairing_request.resolve"),
            (vec!["projection", PROJECTION, "show"], "frontend_projection.get"),
            (
                vec![
                    "projection",
                    PROJECTION,
                    "put",
                    "--projection",
                    "{\"sidebar\":\"compact\"}",
                    "--frontend-id",
                    "cmux-cli",
                    "--window-id",
                    "window-1",
                    "--generation",
                    "launch-1",
                    "--expected-projection-revision",
                    "7",
                ],
                "frontend_projection.put",
            ),
            (vec!["workspace", "list"], "workspace.list"),
            (vec!["workspace", WORKSPACE, "show"], "workspace.get"),
            (
                vec![
                    "workspace",
                    "create",
                    "--empty",
                    "--name",
                    "empty",
                    "--correlation-key",
                    "create-42",
                ],
                "workspace.create",
            ),
            (vec!["workspace", WORKSPACE, "rename", "--name", "api"], "workspace.rename"),
            (vec!["workspace", WORKSPACE, "move", "--index", "2"], "workspace.move"),
            (vec!["workspace", WORKSPACE, "focus"], "workspace.focus"),
            (vec!["workspace", WORKSPACE, "close"], "workspace.close"),
            (
                vec![
                    "workspace",
                    WORKSPACE,
                    "run",
                    "--cwd",
                    "/tmp",
                    "--name",
                    "tests",
                    "--cols",
                    "100",
                    "--rows",
                    "40",
                    "--correlation-key",
                    "create-42",
                    "--",
                    "cargo",
                    "test",
                ],
                "workspace.run",
            ),
            (
                vec!["workspace", WORKSPACE, "layout", "apply", "--layout", "{\"kind\":\"leaf\"}"],
                "workspace.layout.apply",
            ),
            (vec!["screen", "list"], "screen.list"),
            (vec!["screen", SCREEN, "show"], "screen.get"),
            (
                vec!["screen", "create", "--name", "build", "--correlation-key", "create-42"],
                "screen.create",
            ),
            (vec!["screen", SCREEN, "rename", "--name", "tests"], "screen.rename"),
            (vec!["screen", SCREEN, "focus"], "screen.focus"),
            (vec!["screen", SCREEN, "close"], "screen.close"),
            (vec!["screen", SCREEN, "layout", "export"], "screen.layout.export"),
            (
                vec![
                    "screen",
                    SCREEN,
                    "layout",
                    "undo",
                    "--confirm-close",
                    "--confirmation-token",
                    "layout-preview-token",
                ],
                "screen.layout.undo",
            ),
            (vec!["pane", "list"], "pane.list"),
            (vec!["pane", PANE, "show"], "pane.get"),
            (
                vec![
                    "pane",
                    "create",
                    "--cwd",
                    "/tmp",
                    "--cols",
                    "80",
                    "--rows",
                    "24",
                    "--correlation-key",
                    "create-42",
                ],
                "pane.create",
            ),
            (
                vec![
                    "pane",
                    PANE,
                    "split",
                    "--right",
                    "--ratio",
                    "0.5",
                    "--viewport-width",
                    "0.5",
                    "--cwd",
                    "/tmp",
                    "--cols",
                    "80",
                    "--rows",
                    "24",
                    "--correlation-key",
                    "create-42",
                ],
                "pane.split",
            ),
            (vec!["pane", PANE, "rename", "--name", "server"], "pane.rename"),
            (vec!["pane", PANE, "focus"], "pane.focus"),
            (vec!["pane", PANE, "focus", "direction", "right"], "pane.focus_direction"),
            (vec!["pane", PANE, "neighbor", "left"], "pane.neighbor.get"),
            (
                vec![
                    "pane",
                    PANE,
                    "swap",
                    "--other-workspace",
                    WORKSPACE,
                    "--other-screen",
                    SCREEN,
                    "--other-pane",
                    PANE,
                ],
                "pane.swap",
            ),
            (vec!["pane", PANE, "zoom", "--enabled", "true"], "pane.zoom"),
            (
                vec![
                    "pane",
                    PANE,
                    "split",
                    "ratio",
                    "set",
                    "--split",
                    "split_0000000000000000000000000000000f",
                    "--ratio",
                    "0.5",
                ],
                "pane.split_ratio.set",
            ),
            (
                vec!["pane", PANE, "viewport", "width", "set", "--columns", "80"],
                "pane.viewport_width.set",
            ),
            (vec!["pane", PANE, "close"], "pane.close"),
            (
                vec![
                    "pane",
                    PANE,
                    "run",
                    "--cwd",
                    "/tmp",
                    "--name",
                    "make",
                    "--cols",
                    "90",
                    "--rows",
                    "30",
                    "--correlation-key",
                    "create-42",
                    "--",
                    "make",
                    "test",
                ],
                "pane.run",
            ),
            (vec!["tab", "list"], "tab.list"),
            (vec!["tab", TAB, "show"], "tab.get"),
            (
                vec![
                    "tab",
                    "create",
                    "terminal",
                    "--cwd",
                    "/tmp",
                    "--name",
                    "shell",
                    "--cols",
                    "80",
                    "--rows",
                    "24",
                    "--correlation-key",
                    "create-42",
                ],
                "tab.create_terminal",
            ),
            (
                vec![
                    "tab",
                    "create",
                    "browser",
                    "--url",
                    "https://example.com",
                    "--name",
                    "docs",
                    "--width-px",
                    "1200",
                    "--height-px",
                    "800",
                    "--correlation-key",
                    "create-42",
                ],
                "tab.create_browser",
            ),
            (vec!["tab", TAB, "rename", "--name", "logs"], "tab.rename"),
            (
                vec![
                    "tab",
                    TAB,
                    "move",
                    "--workspace",
                    WORKSPACE,
                    "--screen",
                    SCREEN,
                    "--pane",
                    PANE,
                    "--index",
                    "0",
                ],
                "tab.move",
            ),
            (vec!["tab", TAB, "focus"], "tab.focus"),
            (vec!["tab", TAB, "close"], "tab.close"),
            (vec!["terminal", "list"], "terminal.list"),
            (vec!["terminal", TERMINAL, "show"], "terminal.get"),
            (vec!["terminal", TERMINAL, "write", "--text", "hello"], "terminal.input.write"),
            (vec!["terminal", TERMINAL, "keys", "ctrl-c"], "terminal.input.keys"),
            (
                vec![
                    "terminal",
                    TERMINAL,
                    "mouse",
                    "down",
                    "--row",
                    "4",
                    "--column",
                    "7",
                    "--button",
                    "left",
                    "--modifiers",
                    "shift,meta",
                ],
                "terminal.input.mouse",
            ),
            (vec!["terminal", TERMINAL, "focus", "in"], "terminal.input.focus"),
            (vec!["terminal", TERMINAL, "screen", "read"], "terminal.screen.read"),
            (vec!["terminal", TERMINAL, "state", "read"], "terminal.state.read"),
            (
                vec![
                    "terminal", TERMINAL, "history", "read", "--before", "0", "--limit", "100",
                    "--styled",
                ],
                "terminal.history.read",
            ),
            (vec!["terminal", TERMINAL, "history", "clear"], "terminal.history.clear"),
            (
                vec![
                    "terminal",
                    TERMINAL,
                    "screen",
                    "wait",
                    "--pattern",
                    "ready",
                    "--timeout-ms",
                    "5000",
                ],
                "terminal.wait",
            ),
            (vec!["terminal", TERMINAL, "copy", "--mode", "screen"], "terminal.copy"),
            (vec!["terminal", TERMINAL, "process", "show"], "terminal.process.get"),
            (
                vec!["terminal", TERMINAL, "process", "wait", "--timeout-ms", "5000"],
                "terminal.wait_exit",
            ),
            (
                vec!["terminal", TERMINAL, "viewport", "scroll", "--delta-rows", "-3"],
                "terminal.viewport.scroll",
            ),
            (
                vec![
                    "terminal",
                    TERMINAL,
                    "move",
                    "--workspace",
                    WORKSPACE,
                    "--screen",
                    SCREEN,
                    "--pane",
                    PANE,
                    "--index",
                    "1",
                ],
                "terminal.move",
            ),
            (
                vec![
                    "terminal",
                    TERMINAL,
                    "project",
                    "--workspace",
                    WORKSPACE,
                    "--screen",
                    SCREEN,
                    "--pane",
                    PANE,
                    "--index",
                    "1",
                    "--name",
                    "mirror",
                ],
                "terminal.project",
            ),
            (
                vec![
                    "terminal",
                    TERMINAL,
                    "attach",
                    "--cols",
                    "100",
                    "--rows",
                    "40",
                    "--read-only",
                ],
                "terminal.attach",
            ),
            (vec!["terminal", TERMINAL, "close"], "terminal.close"),
            (vec!["browser", "list"], "browser.list"),
            (vec!["browser", BROWSER, "show"], "browser.get"),
            (
                vec!["browser", BROWSER, "navigate", "--url", "https://example.com"],
                "browser.navigate",
            ),
            (vec!["browser", BROWSER, "back"], "browser.back"),
            (vec!["browser", BROWSER, "forward"], "browser.forward"),
            (vec!["browser", BROWSER, "reload"], "browser.reload"),
            (vec!["browser", BROWSER, "activate"], "browser.activate"),
            (
                vec![
                    "browser",
                    BROWSER,
                    "key",
                    "--key",
                    "Enter",
                    "--kind",
                    "press",
                    "--modifiers",
                    "shift,meta",
                ],
                "browser.input.key",
            ),
            (vec!["browser", BROWSER, "text", "--text", "hello"], "browser.input.text"),
            (
                vec![
                    "browser",
                    BROWSER,
                    "mouse",
                    "--kind",
                    "down",
                    "--x-px",
                    "10",
                    "--y-px",
                    "20",
                    "--button",
                    "left",
                    "--click-count",
                    "2",
                    "--pointer-frame-seq",
                    "42",
                ],
                "browser.input.mouse",
            ),
            (
                vec![
                    "browser",
                    BROWSER,
                    "wheel",
                    "--delta-x",
                    "1",
                    "--delta-y",
                    "120",
                    "--x-px",
                    "10",
                    "--y-px",
                    "20",
                    "--pointer-frame-seq",
                    "42",
                ],
                "browser.input.wheel",
            ),
            (
                vec!["browser", BROWSER, "attach", "--width-px", "1200", "--height-px", "800"],
                "browser.attach",
            ),
            (vec!["browser", BROWSER, "close"], "browser.close"),
            (vec!["notification", "list", "--limit", "100"], "notification.list"),
            (
                vec![
                    "notification",
                    "create",
                    "--title",
                    "done",
                    "--body",
                    "tests passed",
                    "--level",
                    "success",
                    "--terminal",
                    TERMINAL,
                ],
                "notification.create",
            ),
            (vec!["agent", "list", "--terminal", TERMINAL, "--state", "working"], "agent.list"),
            (
                vec![
                    "agent",
                    "report",
                    "--terminal",
                    TERMINAL,
                    "--state",
                    "working",
                    "--source",
                    "socket",
                    "--source-session",
                    "job-1",
                ],
                "agent.report",
            ),
            (vec!["sidebar", "view", "show", "--view", VIEW], "sidebar_view.get"),
            (
                vec!["sidebar", "view", "ensure", "--cols", "30", "--rows", "40", "--relaunch"],
                "sidebar_view.ensure",
            ),
            (vec!["sidebar", "view", "attach", "--view", VIEW], "sidebar_view.attach"),
            (vec!["sidebar", "view", "input", "--view", VIEW, "--text", "j"], "sidebar_view.input"),
            (
                vec!["sidebar", "view", "resize", "--view", VIEW, "--cols", "30", "--rows", "40"],
                "sidebar_view.resize",
            ),
            (vec!["sidebar", "view", "reload", "--view", VIEW], "sidebar_view.reload"),
        ];

        assert_eq!(cases.len(), 117);
        let catalog = operation_catalog();
        assert_eq!(catalog["operations"].as_object().unwrap().len(), 124);
        let mut seen = std::collections::BTreeSet::new();
        let mut covered_fields = BTreeMap::<&str, std::collections::BTreeSet<String>>::new();
        for (args, expected) in &cases {
            let plan = protocol(args);
            assert_eq!(operation(&plan), *expected, "{args:?}");
            assert_plan_matches_catalog(&plan, expected, &catalog);
            assert!(seen.insert(*expected), "duplicate operation case {expected}");
            record_covered_fields(&plan, expected, &catalog, &mut covered_fields);

            if catalog["operations"][expected]["params"]["fields"]["expected_revision"].is_object()
            {
                let mut with_revision = args.clone();
                let insert_at = with_revision
                    .iter()
                    .position(|value| *value == "--")
                    .unwrap_or(with_revision.len());
                with_revision.splice(insert_at..insert_at, ["--expected-revision", "7"]);
                let revised = protocol(&with_revision);
                assert_eq!(
                    revised.params["expected_revision"], "7",
                    "{expected} did not expose optimistic concurrency"
                );
                assert_plan_matches_catalog(&revised, expected, &catalog);
                record_covered_fields(&revised, expected, &catalog, &mut covered_fields);
            }
        }
        for (args, expected) in [
            (vec!["workspace", WORKSPACE, "run", "shell", "printf ok"], "workspace.run"),
            (vec!["pane", PANE, "run", "shell", "printf ok"], "pane.run"),
            (
                vec![
                    "session",
                    SESSION,
                    "journal",
                    "subscribe",
                    "--cursor-session",
                    SESSION,
                    "--sequence",
                    "42",
                ],
                "session.journal.subscribe",
            ),
            (vec!["terminal", TERMINAL, "write", "--bytes-base64", "AA=="], "terminal.input.write"),
            (
                vec![
                    "terminal",
                    TERMINAL,
                    "mouse",
                    "wheel",
                    "--row",
                    "4",
                    "--column",
                    "7",
                    "--delta-rows",
                    "-2",
                ],
                "terminal.input.mouse",
            ),
        ] {
            let plan = protocol(&args);
            record_covered_fields(&plan, expected, &catalog, &mut covered_fields);
        }
        let expected = catalog["operations"]
            .as_object()
            .unwrap()
            .keys()
            .filter(|name| {
                !matches!(
                    name.as_str(),
                    "browser.viewer.release"
                        | "browser.viewer.resize"
                        | "request.cancel"
                        | "stream.cancel"
                        | "terminal.renderer_grant.create"
                        | "terminal.viewer.release"
                        | "terminal.viewer.resize"
                )
            })
            .map(String::as_str)
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(seen, expected, "safe CLI operation coverage drifted from the catalog");
        for operation in &expected {
            let catalog_fields = catalog["operations"][operation]["params"]["fields"]
                .as_object()
                .unwrap()
                .keys()
                .cloned()
                .collect::<std::collections::BTreeSet<_>>();
            assert_eq!(
                covered_fields.get(operation).cloned().unwrap_or_default(),
                catalog_fields,
                "{operation} has catalog fields with no exercised CLI representation"
            );
        }
    }

    fn record_covered_fields<'a>(
        plan: &RequestPlan,
        operation: &'a str,
        catalog: &Value,
        covered: &mut BTreeMap<&'a str, std::collections::BTreeSet<String>>,
    ) {
        let catalog_fields =
            catalog["operations"][operation]["params"]["fields"].as_object().unwrap();
        let entry = covered.entry(operation).or_default();
        for key in plan.params.as_object().unwrap().keys() {
            if catalog_fields.contains_key(key) {
                entry.insert(key.clone());
            }
        }
    }
}
