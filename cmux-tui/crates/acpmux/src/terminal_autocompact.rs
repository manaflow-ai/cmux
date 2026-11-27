//! The autocompact a `claude` started in a cmux terminal gets: the one an agent chat of the
//! person's default Claude harness starts with (Leo, 2026-11-25: "for claude code cli sessions
//! e.g. kumquat do our fixes get in? for efficiency. i hope it does. it's still at 400k it seems
//! like").
//!
//! An agent chat starts with its profile's command line, so a profile that names
//! `--autocompact N` (157125 on Leo's machines) compacts there; one that names none gets
//! acpmux's window ([`crate::harness_limits::CLAUDE_AUTOCOMPACT_WINDOW`]). A terminal's `claude`
//! read neither: it got the window only, and under `sr2 claude` not even that, because sr2
//! prepends its own `--autocompact`, drawn from 380k-420k per launch, and the window yields to
//! any `--autocompact`. Such a session then re-read about 250k tokens a turn and
//! compacted only near 386k.
//!
//! The terminal now takes the chat profile's value, read by the same loader acpmux uses
//! ([`crate::config::profiles::load`] over [`ProfileSources::current`], then `config.json`). A
//! launcher's draw ([`launcher_draw`]) is not the person's choice and yields to it; an
//! `--autocompact` the person typed, their `CLAUDE_CODE_AUTO_COMPACT_WINDOW` or
//! `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`, or `autoCompactWindow` in their settings, still wins
//! ([`crate::usage_stats::claude_autocompact_unset`]).

use std::path::Path;

use serde_json::Value;

use crate::config::{HarnessKind, ProfileSources};

/// The `--autocompact` a new agent chat of the person's default Claude harness starts with (the
/// last one in its command line), from acpmux's own config and profile sources.
pub fn chat_claude_autocompact() -> Option<String> {
    chat_claude_autocompact_from(&crate::config::Config::path(), &ProfileSources::current())
}

/// [`chat_claude_autocompact`] for one `config.json` and set of profile sources. The harness is
/// `defaultHarness`, else `claude` (the automatic default when Claude Code is installed). None
/// when that harness is not Claude Code or its command line names no `--autocompact`.
pub fn chat_claude_autocompact_from(config: &Path, sources: &ProfileSources) -> Option<String> {
    let config = std::fs::read(config)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .unwrap_or(Value::Null);
    let id = config.get("defaultHarness").and_then(Value::as_str).unwrap_or("claude");
    // A profile file wins over config.json's entry of the same id (`Config::join_profiles`).
    let argv = match crate::config::profiles::load(sources).profiles.remove(id) {
        Some((profile, _)) => (profile.kind == HarnessKind::ClaudeStdio).then_some(profile.argv)?,
        None => {
            let entry = config.get("harnesses")?.get(id)?;
            (entry.get("kind").and_then(Value::as_str) == Some("claude-stdio")).then_some(())?;
            let argv = entry.get("argv")?.as_array()?;
            argv.iter().filter_map(Value::as_str).map(str::to_owned).collect()
        }
    };
    last_autocompact(&argv)
}

/// The last `--autocompact` value in `argv` (Claude Code reads the last one).
fn last_autocompact(argv: &[String]) -> Option<String> {
    let mut found = None;
    for (i, arg) in argv.iter().enumerate() {
        if arg == "--autocompact" {
            found = argv.get(i + 1).cloned();
        } else if let Some(value) = arg.strip_prefix("--autocompact=") {
            found = Some(value.to_owned());
        }
    }
    found
}

/// Where in a terminal launch's arguments a launcher, not the person, put an `--autocompact`
/// value: `sr2 claude` starts Claude with `[--session-id ID] --autocompact N --settings
/// DIR/settings.json ARGS`, where `DIR` also holds the hook socket it names in
/// `SR2_CLAUDE2_HOOK_SOCKET`. The index is the value's.
pub fn launcher_draw(args: &[String], getenv: impl Fn(&str) -> Option<String>) -> Option<usize> {
    let socket = getenv("SR2_CLAUDE2_HOOK_SOCKET")?;
    let dir = Path::new(&socket).parent()?;
    let start = if args.first().is_some_and(|a| a == "--session-id") { 2 } else { 0 };
    let shape = args.get(start).is_some_and(|a| a == "--autocompact")
        && args.get(start + 2).is_some_and(|a| a == "--settings")
        && args.get(start + 3).is_some_and(|p| Path::new(p).parent() == Some(dir));
    shape.then_some(start + 1)
}

/// What a terminal launch does with its `--autocompact`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AutocompactEdit {
    /// Its arguments stay as given.
    Keep,
    /// The chat's value goes first.
    Prepend(String),
    /// A launcher's draw at this index becomes the chat's value.
    Replace(usize, String),
}

/// How a terminal launch's `--autocompact` changes so it compacts where the person's agent chats
/// do: `chat` (the chat profile's value, [`chat_claude_autocompact`]) replaces a launcher's draw
/// or goes first, unless the person's own arguments, env or settings chose one.
pub fn terminal_autocompact(
    args: &[String],
    cwd: &Path,
    getenv: impl Fn(&str) -> Option<String>,
    chat: Option<&str>,
) -> AutocompactEdit {
    let Some(chat) = chat else { return AutocompactEdit::Keep };
    let draw = launcher_draw(args, &getenv);
    let own: Vec<String> = match draw {
        Some(i) => args[..i - 1].iter().chain(&args[i + 1..]).cloned().collect(),
        None => args.to_vec(),
    };
    if !crate::harness_limits::claude_choice_unset(&own, cwd, &getenv) {
        return AutocompactEdit::Keep;
    }
    match draw {
        Some(i) => AutocompactEdit::Replace(i, chat.to_owned()),
        None => AutocompactEdit::Prepend(chat.to_owned()),
    }
}

#[cfg(test)]
#[path = "terminal_autocompact_tests.rs"]
mod tests;
