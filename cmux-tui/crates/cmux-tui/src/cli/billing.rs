//! `cmux billing checkout|status|portal`: start a paid plan, read it, and
//! manage it (plans/cmux-next/paid-product-DESIGN.md).
//!
//! The cmux app holds the Stack session. Each verb is one app method
//! (`billing.checkout`, `billing.status`, `billing.portal`): the app asks
//! cmux.com for a Stripe Checkout session bound to the signed-in account,
//! then opens it in a cmux browser tab when that browser is signed in to
//! Stripe Link, else in the default browser (`--open` overrides). No card
//! data passes through cmux, and nothing is charged until the person pays on
//! the Stripe page, so an agent (a Chief) may start a checkout.

use std::io::Write;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode, UsageError};
use crate::localization::BillingMessages;

/// The app bounds the cmux.com call at 20 s; the CLI waits a little longer
/// so the app's own timeout error reaches it.
const BILLING_TIMEOUT: Duration = Duration::from_secs(25);

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Invocation {
    Help,
    Owned(Verb),
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Verb {
    Checkout { plan: Plan, team: Option<String>, open: OpenMode },
    Status { team: Option<String> },
    Portal { team: Option<String>, open: OpenMode },
}

/// The plans cmux-next sells, the same Stripe products classic sells.
/// Plus keeps web billing's historical plan id `go`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Plan {
    Plus,
    Pro,
    Max,
    Team,
}

impl Plan {
    fn id(self) -> &'static str {
        match self {
            Plan::Plus => "go",
            Plan::Pro => "pro",
            Plan::Max => "max",
            Plan::Team => "team",
        }
    }
}

/// Where the app opens the page. `Auto`: the cmux browser when it is signed
/// in to Stripe Link, else the default browser.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum OpenMode {
    Auto,
    Cmux,
    Default,
    None,
}

impl OpenMode {
    fn id(self) -> &'static str {
        match self {
            OpenMode::Auto => "auto",
            OpenMode::Cmux => "cmux",
            OpenMode::Default => "default",
            OpenMode::None => "none",
        }
    }
}

/// `cmux billing …`. `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let rest = split(&command_args)?;
    Some(match parse(rest) {
        Ok(invocation) => run(&global, invocation),
        Err(error) => {
            super::app::failure("usage.invalid", &format!("cmux: {error}"), global.output, 2)
        }
    })
}

/// `Some(args after "billing")` when `args` (after the global options) start
/// with `billing`.
pub(super) fn split(command_args: &[String]) -> Option<&[String]> {
    let (first, rest) = command_args.split_first()?;
    (first == "billing").then_some(rest)
}

pub(super) fn parse(rest: &[String]) -> Result<Invocation, UsageError> {
    let messages = &crate::localization::catalog().billing;
    if rest.iter().take_while(|arg| *arg != "--").any(|arg| arg == "--help" || arg == "-h") {
        return Ok(Invocation::Help);
    }
    let (verb, tail) = match rest.split_first() {
        Some((verb, tail)) if !verb.starts_with('-') => (verb.as_str(), tail),
        _ => ("checkout", rest),
    };
    let verb = match verb {
        "help" => return Ok(Invocation::Help),
        "checkout" | "upgrade" | "subscribe" => {
            let options = Options::parse(tail)?;
            options.no_positionals("billing checkout")?;
            let plan = match options.plan.as_deref().unwrap_or("pro") {
                "plus" | "go" => Plan::Plus,
                "pro" => Plan::Pro,
                "max" => Plan::Max,
                "team" => Plan::Team,
                other => {
                    return Err(UsageError::new(messages.unknown_plan.replace("{plan}", other)));
                }
            };
            if plan == Plan::Team && options.team.is_none() {
                return Err(UsageError::new(messages.plan_required_team));
            }
            Verb::Checkout { plan, team: options.team, open: options.open }
        }
        "status" | "plan" => {
            let options = Options::parse(tail)?;
            options.no_positionals("billing status")?;
            Verb::Status { team: options.team }
        }
        "portal" | "manage" => {
            let options = Options::parse(tail)?;
            options.no_positionals("billing portal")?;
            Verb::Portal { team: options.team, open: options.open }
        }
        other => return Err(UsageError::new(messages.unknown_verb.replace("{verb}", other))),
    };
    Ok(Invocation::Owned(verb))
}

/// The app method and params of a verb.
pub(super) fn request(verb: &Verb) -> (&'static str, Map<String, Value>) {
    let mut params = Map::new();
    let team = match verb {
        Verb::Checkout { team, .. } | Verb::Status { team } | Verb::Portal { team, .. } => team,
    };
    match verb {
        Verb::Checkout { plan, open, .. } => {
            params.insert("plan".into(), json!(plan.id()));
            params.insert("open".into(), json!(open.id()));
        }
        Verb::Portal { open, .. } => {
            params.insert("open".into(), json!(open.id()));
        }
        Verb::Status { .. } => {}
    }
    if let Some(team) = team {
        params.insert("teamId".into(), json!(team));
    }
    let method = match verb {
        Verb::Checkout { .. } => "billing.checkout",
        Verb::Status { .. } => "billing.status",
        Verb::Portal { .. } => "billing.portal",
    };
    (method, params)
}

pub(super) fn run(global: &GlobalArgs, invocation: Invocation) -> i32 {
    let messages = &crate::localization::catalog().billing;
    let verb = match invocation {
        Invocation::Help => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(messages.usage.as_bytes());
            let _ = stdout.flush();
            return 0;
        }
        Invocation::Owned(verb) => verb,
    };
    let mut stream = match super::app::connect_command(global) {
        Ok(stream) => stream,
        Err(error) => return super::wire::print_local_error(&error, global.output, 3),
    };
    let (method, params) = request(&verb);
    match super::app::request(&mut stream, method, Value::Object(params), BILLING_TIMEOUT) {
        Ok(Ok(value)) => {
            let shown = match (global.output, &verb) {
                (OutputMode::Human, Verb::Checkout { .. }) => {
                    json!(checkout_text(&value, messages))
                }
                (OutputMode::Human, Verb::Portal { .. }) => json!(portal_text(&value, messages)),
                (OutputMode::Human, Verb::Status { .. }) => json!(status_text(&value, messages)),
                _ => value,
            };
            super::wire::print_local_success(&shown, global.output)
        }
        Ok(Err(error)) => {
            let exit_code = match error.get("code").and_then(Value::as_str) {
                Some("not_signed_in") => 3,
                Some("method_not_found") => 5,
                _ => 1,
            };
            super::wire::print_local_error(&error, global.output, exit_code)
        }
        Err(message) => super::app::failure("app.transport", &message, global.output, 3),
    }
}

fn plan_name(id: &str) -> String {
    match id {
        "pro" => "Pro".into(),
        "max" => "Max".into(),
        "team" => "Team".into(),
        "go" | "plus" => "Plus".into(),
        other => other.to_owned(),
    }
}

/// The text form of a checkout result: where the page opened and why, then
/// the URL. It never says anything was bought.
pub(super) fn checkout_text(value: &Value, messages: &BillingMessages) -> String {
    let field = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or_default();
    let url = field("url");
    let plan = plan_name(field("plan"));
    let link = value.get("link_session").and_then(Value::as_bool).unwrap_or(false);
    let headline = match (field("flow"), field("opened_in")) {
        ("already_active", _) => messages.already_active.to_owned(),
        (_, "none") => return url.to_owned(),
        ("portal", "cmux") | ("portal", "default") => messages.opened_switch.to_owned(),
        (_, "cmux") if link => messages.opened_cmux_link.to_owned(),
        (_, "cmux") => messages.opened_cmux.to_owned(),
        _ => messages.opened_default.to_owned(),
    };
    let mut text = headline.replace("{plan}", &plan);
    if field("mode") == "test" {
        text.push(' ');
        text.push_str(messages.test_mode);
    }
    format!("{text}\n{url}")
}

fn portal_text(value: &Value, messages: &BillingMessages) -> String {
    let url = value.get("url").and_then(Value::as_str).unwrap_or_default();
    match value.get("opened_in").and_then(Value::as_str) {
        Some("cmux") | Some("default") => format!("{}\n{url}", messages.opened_portal),
        _ => url.to_owned(),
    }
}

/// `GET /api/billing/plan` as one line per fact the person needs.
fn status_text(value: &Value, messages: &BillingMessages) -> String {
    if value.get("authenticated").and_then(Value::as_bool) == Some(false) {
        return messages.status_signed_out.to_owned();
    }
    let field = |key: &str| value.get(key).and_then(Value::as_str);
    let plan = field("planId").unwrap_or("free");
    let mut text = messages.status_plan.replace("{plan}", &plan_name(plan));
    if let Some(source) = field("billingSource").filter(|source| *source != "none") {
        text.push_str(&messages.status_source.replace("{source}", source));
    }
    if let Some(team) = field("teamPlanId").filter(|team| *team != "free") {
        text.push('\n');
        text.push_str(&messages.status_team.replace("{plan}", &plan_name(team)));
    }
    text
}

/// `--plan`, `--team`, `--open` (`--name value` or `--name=value`) and
/// `--no-open`.
struct Options {
    plan: Option<String>,
    team: Option<String>,
    open: OpenMode,
    positionals: Vec<String>,
}

impl Options {
    fn parse(args: &[String]) -> Result<Self, UsageError> {
        let app = &crate::localization::catalog().app_control;
        let messages = &crate::localization::catalog().billing;
        let mut options =
            Self { plan: None, team: None, open: OpenMode::Auto, positionals: Vec::new() };
        let mut index = 0;
        while index < args.len() {
            let arg = &args[index];
            index += 1;
            if arg == "--no-open" {
                options.open = OpenMode::None;
                continue;
            }
            let Some(flag) = arg.strip_prefix("--") else {
                if arg.starts_with('-') && arg != "-" {
                    return Err(UsageError::new(app.unexpected_argument.replace("{value}", arg)));
                }
                options.positionals.push(arg.clone());
                continue;
            };
            let (name, inline) = match flag.split_once('=') {
                Some((name, value)) => (name, Some(value.to_owned())),
                None => (flag, None),
            };
            if !matches!(name, "plan" | "team" | "open") {
                return Err(UsageError::new(app.unexpected_argument.replace("{value}", arg)));
            }
            let value = match inline {
                Some(value) => value,
                None => {
                    let value = args
                        .get(index)
                        .ok_or_else(|| UsageError::new(app.missing_value.replace("{flag}", arg)))?;
                    index += 1;
                    value.clone()
                }
            };
            match name {
                "plan" => options.plan = Some(value.trim().to_ascii_lowercase()),
                "team" => {
                    options.team = Some(value.trim().to_owned()).filter(|team| !team.is_empty());
                }
                _ => {
                    options.open = match value.trim() {
                        "auto" => OpenMode::Auto,
                        "cmux" => OpenMode::Cmux,
                        "default" | "system" => OpenMode::Default,
                        "none" | "no" => OpenMode::None,
                        other => {
                            return Err(UsageError::new(
                                messages.unknown_open.replace("{value}", other),
                            ));
                        }
                    }
                }
            }
        }
        Ok(options)
    }

    fn no_positionals(&self, command: &str) -> Result<(), UsageError> {
        match self.positionals.first() {
            None => Ok(()),
            Some(extra) => Err(UsageError::new(
                crate::localization::catalog()
                    .billing
                    .unexpected_argument
                    .replace("{command}", command)
                    .replace("{value}", extra),
            )),
        }
    }
}

#[cfg(test)]
mod tests;
