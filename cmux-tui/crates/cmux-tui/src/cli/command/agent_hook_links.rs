//! `agent hook status|install|uninstall link-<app>`: the cmux MCP server in Claude desktop,
//! Claude Code and the Codex desktop app and CLI (`acpmux desktop link`), as rows beside the
//! coding-agent hooks. Settings > Agents > Agent integrations reads `agent hook status` and runs
//! `agent hook install|uninstall <id>`, so these rows get Connect and Disconnect there with no
//! host code of their own.
//!
//! Leo, 2026-11-09: even someone who keeps using another desktop app should still want cmux
//! NEXT running, as "a good transport between everybody". Opt-in: a status lists the apps that
//! are here, and only an install that names a `link-` id writes anything; `agent hook install`
//! with no ids installs hooks only.

use std::path::PathBuf;

use acpmux::desktop_link::{self, App, Env, State};
use serde_json::{Value, json};

/// The id prefix of a link row (`link-claude-desktop`, `link-claude-code`, `link-codex`).
pub(super) const PREFIX: &str = "link-";

/// `ids` split into the link apps they name, the hook providers, and `<id>: <cause>` errors
/// for a `link-` id that names no app.
pub(super) fn split(ids: &[String]) -> (Vec<App>, Vec<String>, Vec<String>) {
    let mut apps = Vec::new();
    let mut hooks = Vec::new();
    let mut errors = Vec::new();
    for id in ids {
        match id.strip_prefix(PREFIX) {
            Some(name) => match App::parse(name) {
                Some(app) if !apps.contains(&app) => apps.push(app),
                Some(_) => {}
                None => errors.push(format!(
                    "{id}: not an app cmux links (link-claude-desktop, link-claude-code, link-codex)"
                )),
            },
            None => hooks.push(id.clone()),
        }
    }
    (apps, hooks, errors)
}

/// The id of `app`'s row.
pub(super) fn id(app: App) -> String {
    format!("{PREFIX}{}", app.id())
}

/// The environment the entry is written for: this cmux binary under its `acp` prefix (the app
/// bundle's own CLI when Settings runs it) and this build's acpmux home, so a DEV build's entry
/// reaches the DEV daemon.
pub(super) fn env() -> anyhow::Result<Env> {
    let exe = std::env::current_exe()?;
    let me = acpmux::self_command::SelfCommand::new(exe, vec!["acp".into()]);
    let home = std::env::var_os("HOME").map(PathBuf::from);
    Env::with(me, home.and_then(|home| crate::acp::build_home(&home)))
}

/// `row` as an `agent hook status` provider row, in the states the Settings card reads. An app
/// that is not here has no row.
pub(super) fn status_row(row: &desktop_link::Row, changed: bool) -> Option<Value> {
    let (state, reason) = match row.state {
        State::NotInstalled => return None,
        State::NotLinked => ("absent", None),
        State::Linked => ("installed", None),
        // An entry of ours for another cmux binary: Reconnect points it at this one.
        State::Stale => ("partial", None),
        // An entry named `cmux` that cmux did not write: never replaced or removed.
        State::Foreign => ("conflict", Some("not_owned")),
    };
    Some(json!({
        "provider": id(row.app),
        "path": row.config,
        "state": state,
        "reason": reason,
        "detail": row.note,
        "changed": changed,
    }))
}

/// A status row: a config that could not be read is `unavailable`, with the cause, as the
/// hook rows show one.
fn read_row(row: &desktop_link::Row) -> Option<Value> {
    if row.state == State::NotLinked
        && let Some(cause) = &row.note
    {
        return Some(json!({
            "provider": id(row.app),
            "path": row.config,
            "state": "unavailable",
            "reason": "unreadable",
            "detail": cause,
            "changed": false,
        }));
    }
    status_row(row, false)
}

/// What a link install or uninstall did, as `(provider row, error)`.
fn outcome(row: desktop_link::Row, want: State) -> (Option<Value>, Option<String>) {
    let ok = row.state == want;
    let error = (!ok).then(|| {
        let why = match row.state {
            State::NotInstalled => format!("{} is not installed here", row.app.label()),
            State::Foreign => format!(
                "{} already has an MCP server named cmux that cmux did not write; it was left alone",
                row.config.display()
            ),
            _ => row.note.clone().unwrap_or_else(|| "it did not finish".to_owned()),
        };
        format!("{}: {why}", id(row.app))
    });
    (status_row(&row, ok), error)
}

/// The link rows and errors of `action` over `apps`; a status with no ids lists every app.
pub(super) fn run(
    action: crate::agent_hook_install::Action,
    apps: &[App],
    all: bool,
) -> (Vec<Value>, Vec<String>) {
    let env = match env() {
        Ok(env) => env,
        Err(error) => {
            let errors = apps.iter().map(|app| format!("{}: {error:#}", id(*app))).collect();
            return (Vec::new(), errors);
        }
    };
    run_in(&env, action, if all { &App::ALL } else { apps })
}

/// [`run`] over `env`.
pub(super) fn run_in(
    env: &Env,
    action: crate::agent_hook_install::Action,
    apps: &[App],
) -> (Vec<Value>, Vec<String>) {
    use crate::agent_hook_install::Action;
    let mut rows = Vec::new();
    let mut errors = Vec::new();
    for &app in apps {
        let (row, error) = match action {
            Action::Status => (read_row(&desktop_link::status(env, app)), None),
            Action::Install => outcome(desktop_link::link(env, app, false), State::Linked),
            Action::Uninstall => outcome(desktop_link::unlink(env, app, false), State::NotLinked),
        };
        rows.extend(row);
        errors.extend(error);
    }
    (rows, errors)
}

/// `value` (a hook run's answer) with the link `rows` and `errors` added.
pub(super) fn merge(mut value: Value, rows: Vec<Value>, errors: Vec<String>) -> Value {
    if !value.is_object() {
        value = json!({});
    }
    for (key, items) in
        [("providers", rows), ("errors", errors.into_iter().map(Value::from).collect())]
    {
        let slot =
            value.as_object_mut().expect("an object").entry(key).or_insert_with(|| json!([]));
        if let Some(list) = slot.as_array_mut() {
            list.extend(items);
        }
    }
    value
}

#[cfg(test)]
#[path = "agent_hook_links_tests.rs"]
mod tests;
