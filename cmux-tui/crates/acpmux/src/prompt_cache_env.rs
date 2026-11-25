//! How long Claude Code keeps a chat's prompt cached, set in the env acpmux
//! starts it with (`hub/spawn.rs`). Claude Code picks the TTL itself: one
//! hour on a Claude subscription, five minutes on an API key, a custom
//! `ANTHROPIC_BASE_URL`, Bedrock, Vertex or Foundry, and five minutes for
//! subagents everywhere. A pause longer than five minutes then writes the
//! whole prompt again. acpmux starts every Claude Code chat on the one-hour
//! cache unless the cmux setting `agents.promptCache` says `5m`.
//!
//! Claude Code's own order (2.1.310): `FORCE_PROMPT_CACHING_5M`, then
//! `CLAUDE_CODE_PROMPT_CACHE_TTL`, then the `promptCacheTtl` setting, then
//! `ENABLE_PROMPT_CACHING_1H`; subagents read
//! `CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL`. A profile, route or person that
//! names any of these keeps its value, in its env or its login shell: acpmux
//! only fills what is unset, and sets nothing when `FORCE_PROMPT_CACHING_5M`
//! or `DISABLE_PROMPT_CACHING` is on. Its settings files'
//! `env` still win over the process env, as for every Claude Code variable.
//!
//! The same start also keeps Claude Code's per-turn context in the user turn
//! ([`keep_turn_context_in_user_turn`]). Claude Code 2.1.331 sends hook
//! context and its `# Environment` block as `role:"system"` messages after the
//! user's message and puts the turn's cache breakpoint on that system
//! message. The next request carries more turns after it, and the cache read
//! stops before it: every turn wrote the system message and everything after
//! it again (2,300 to 2,900 tokens per user turn on a bare `claude -p`, 4,900
//! in a cmux chat; cmuxterm-hq docs/findings/gui-chat-harness-bench-2026-11-25.md).
//! With the capability off, that context rides in the user turn as before
//! and the next turn reads the whole prompt (turn 2 writes 19 tokens).

use std::collections::BTreeMap;

/// The cmux setting: `1h` (the default) or `5m`.
pub const SETTING: &str = "agents.promptCache";

/// The main conversation's TTL.
pub const TTL_ENV: &str = "CLAUDE_CODE_PROMPT_CACHE_TTL";
/// Subagents' TTL.
pub const SUBAGENT_TTL_ENV: &str = "CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL";
/// The older one-hour switch, for Claude Code builds without the two above.
pub const ONE_HOUR_ENV: &str = "ENABLE_PROMPT_CACHING_1H";
/// Claude Code's switch that forces five minutes over everything else.
pub const FORCE_5M_ENV: &str = "FORCE_PROMPT_CACHING_5M";

/// `agents.promptCache`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PromptCache {
    /// One hour for the chat and its subagents (the default).
    OneHour,
    /// Five minutes for the chat and its subagents.
    FiveMinutes,
}

impl PromptCache {
    /// The setting's value; anything but `5m` is the default, one hour.
    pub fn parse(value: Option<&str>) -> Self {
        match value.map(str::trim) {
            Some("5m") => Self::FiveMinutes,
            _ => Self::OneHour,
        }
    }

    /// The setting as the settings file holds it now (read at each start,
    /// so a change applies to the next chat). No file, no key or a file
    /// that does not parse is one hour: the setting widens nothing.
    pub fn current() -> Self {
        match crate::user_settings::read() {
            crate::user_settings::Settings::Parsed(doc) => Self::parse(
                crate::user_settings::value(&doc, SETTING).as_ref().and_then(|v| v.as_str()),
            ),
            crate::user_settings::Settings::Missing
            | crate::user_settings::Settings::Unreadable(_) => Self::OneHour,
        }
    }
}

/// Fills Claude Code's cache TTL variables in `env` for `cache`, keeping
/// every one already set there or in `login` (the login shell's value the
/// agent gets, applied after `env` is built: `agent/command.rs`). Nothing
/// when either turns caching off (`DISABLE_PROMPT_CACHING*`) or forces
/// five minutes (`FORCE_PROMPT_CACHING_5M`).
pub fn apply(
    env: &mut BTreeMap<String, String>,
    cache: PromptCache,
    login: &dyn Fn(&str) -> Option<String>,
) {
    let on = |v: &str| !v.trim().is_empty() && v.trim() != "0";
    let set = |key: &str| env.get(key).cloned().or_else(|| login(key));
    if set(FORCE_5M_ENV).is_some_and(|v| on(&v)) {
        return;
    }
    let disabled = ["DISABLE_PROMPT_CACHING", "DISABLE_PROMPT_CACHING_OPUS"];
    if disabled.iter().any(|key| set(key).is_some_and(|v| on(&v)))
        || env.iter().any(|(k, v)| k.starts_with("DISABLE_PROMPT_CACHING") && on(v))
    {
        return;
    }
    let wanted: &[(&str, &str)] = match cache {
        PromptCache::OneHour => &[(TTL_ENV, "1h"), (SUBAGENT_TTL_ENV, "1h"), (ONE_HOUR_ENV, "1")],
        PromptCache::FiveMinutes => &[(TTL_ENV, "5m"), (SUBAGENT_TTL_ENV, "5m")],
    };
    let missing: Vec<(&str, &str)> =
        wanted.iter().copied().filter(|(key, _)| set(key).is_none()).collect();
    for (key, value) in missing {
        env.insert(key.to_owned(), value.to_owned());
    }
}

/// Claude Code's per-model capability overrides: `;`-separated entries,
/// `MODEL=cap,-cap` or, with no `MODEL=`, for every model; `-cap` turns one off.
pub const MODEL_CAPABILITIES_ENV: &str = "CLAUDE_CODE_MODEL_CAPABILITIES";
/// The capability that sends per-turn context as mid-conversation
/// `role:"system"` messages.
pub const MID_CONV_SYSTEM: &str = "mid_conv_system";
/// Claude Code's switch that forces mid-conversation system messages on.
pub const FORCE_MID_CONV_SYSTEM_ENV: &str = "CLAUDE_CODE_FORCE_MID_CONVERSATION_SYSTEM";

/// Turns `mid_conv_system` off in `env` for every model, so a chat's
/// per-turn context stays in the user turn and the next turn reads it from
/// the cache. A value in `env` that names the capability, a login-shell
/// value (applied after `env`) or the force switch is kept as it is; a value
/// in `env` that does not name it gets the entry appended.
pub fn keep_turn_context_in_user_turn(
    env: &mut BTreeMap<String, String>,
    login: &dyn Fn(&str) -> Option<String>,
) {
    let set = |key: &str| env.get(key).cloned().or_else(|| login(key));
    if set(FORCE_MID_CONV_SYSTEM_ENV).is_some_and(|v| !v.trim().is_empty() && v.trim() != "0") {
        return;
    }
    let off = format!("-{MID_CONV_SYSTEM}");
    match env.get(MODEL_CAPABILITIES_ENV) {
        Some(value) if names_capability(value, MID_CONV_SYSTEM) => {}
        Some(value) => {
            let joined = if value.trim().is_empty() { off } else { format!("{value};{off}") };
            env.insert(MODEL_CAPABILITIES_ENV.to_owned(), joined);
        }
        None if login(MODEL_CAPABILITIES_ENV).is_some() => {}
        None => {
            env.insert(MODEL_CAPABILITIES_ENV.to_owned(), off);
        }
    }
}

/// Whether a `CLAUDE_CODE_MODEL_CAPABILITIES` value turns `cap` on or off
/// for any model.
fn names_capability(value: &str, cap: &str) -> bool {
    value.split(';').any(|entry| {
        let caps = entry.split_once('=').map_or(entry, |(_, caps)| caps);
        caps.split(',').any(|c| c.trim().trim_start_matches('-') == cap)
    })
}

#[cfg(test)]
#[path = "prompt_cache_env_tests.rs"]
mod tests;
