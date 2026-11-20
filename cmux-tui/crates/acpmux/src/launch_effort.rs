//! The reasoning effort an agent was launched at, read from its launch inputs: the argv its
//! agent starts with and the env it inherits. A session's summary `effort` is the harness's own
//! report (its `effort` or `reasoning_effort` option) once it makes one; a session whose harness
//! reports none (an adapter without the option, a chat not started since this daemon began)
//! falls back to this, so `acpmux ls --json` says what it runs at (Leo, 2026-11-20: "We need to
//! absolutely f***ing not wait on efficiency"; the models rule "Opus always runs at medium" was
//! uncheckable for most sessions).
//!
//! Read in this order, the first found wins:
//! 1. the argv: Claude Code `--effort X` or `--effort=X`; Codex `-c model_reasoning_effort=X`
//!    or `--config model_reasoning_effort=X` (the last one given, as the CLIs take it);
//! 2. the env, the profile's first, then its defaults', then the daemon's own and the imported
//!    login env: `CLAUDE_CODE_EFFORT_LEVEL`, `CLAUDE_EFFORT`, `CODEX_REASONING_EFFORT`.
//!
//! Only a Claude or Codex family reads its own keys; another family's agent reads nothing from
//! the env, so a Claude key the daemon exports never labels an OpenCode chat.

use std::collections::BTreeMap;

/// The longest effort value kept; anything longer is no effort name.
const MAX_LEN: usize = 32;

/// Env keys a Claude Code agent reads its effort from, in order.
const CLAUDE_ENV: [&str; 2] = ["CLAUDE_CODE_EFFORT_LEVEL", "CLAUDE_EFFORT"];
/// Env keys a Codex agent reads its effort from.
const CODEX_ENV: [&str; 1] = ["CODEX_REASONING_EFFORT"];

/// A value as an effort name: trimmed, unquoted, lowercase, short, letters, digits, `-` or `_`.
fn clean(value: &str) -> Option<String> {
    let v = value.trim().trim_matches(|c| c == '"' || c == '\'').trim().to_ascii_lowercase();
    (!v.is_empty()
        && v.len() <= MAX_LEN
        && v.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'))
    .then_some(v)
}

/// The effort `argv` names, the last one given.
pub fn from_argv(argv: &[String]) -> Option<String> {
    let mut found = None;
    let mut words = argv.iter().peekable();
    while let Some(word) = words.next() {
        let value = if word == "--effort" {
            words.peek().map(|v| v.as_str())
        } else if let Some(v) = word.strip_prefix("--effort=") {
            Some(v)
        } else if word == "-c" || word == "--config" {
            words.peek().and_then(|v| config_effort(v))
        } else if let Some(v) = word.strip_prefix("--config=") {
            config_effort(v)
        } else {
            None
        };
        if let Some(e) = value.and_then(clean) {
            found = Some(e);
        }
    }
    found
}

/// `model_reasoning_effort=X` (spaces around `=` allowed) as `X`.
fn config_effort(pair: &str) -> Option<&str> {
    let (key, value) = pair.split_once('=')?;
    (key.trim() == "model_reasoning_effort").then_some(value)
}

/// The env keys `family`'s agent reads its effort from; none for another family.
fn env_keys(family: Option<&str>) -> &'static [&'static str] {
    match family {
        Some(f) if f.starts_with("claude") => &CLAUDE_ENV,
        Some(f) if f.starts_with("codex") => &CODEX_ENV,
        _ => &[],
    }
}

/// The effort the first of `envs` with one of `family`'s keys names.
pub fn from_envs(family: Option<&str>, envs: &[&BTreeMap<String, String>]) -> Option<String> {
    let keys = env_keys(family);
    envs.iter().find_map(|env| keys.iter().find_map(|k| env.get(*k).and_then(|v| clean(v))))
}

/// The effort an agent of `family` launched with `argv` and the profile `envs` runs at: the
/// argv, then those envs, then the daemon's own env and the imported login env.
pub fn of_launch(
    family: Option<&str>,
    argv: &[String],
    envs: &[&BTreeMap<String, String>],
) -> Option<String> {
    from_argv(argv).or_else(|| from_envs(family, envs)).or_else(|| {
        env_keys(family).iter().find_map(|k| {
            std::env::var(k).ok().or_else(|| crate::login_env::var(k)).and_then(|v| clean(&v))
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(words: &[&str]) -> Vec<String> {
        words.iter().map(|w| (*w).to_owned()).collect()
    }

    fn env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
    }

    #[test]
    fn claude_effort_flag_both_forms() {
        assert_eq!(from_argv(&argv(&["claude", "--effort", "medium"])).as_deref(), Some("medium"));
        assert_eq!(from_argv(&argv(&["claude", "--effort=High"])).as_deref(), Some("high"));
    }

    #[test]
    fn codex_config_effort_and_last_wins() {
        let a = argv(&[
            "codex",
            "-c",
            "model_reasoning_effort=\"low\"",
            "--config",
            "model_reasoning_effort = xhigh",
        ]);
        assert_eq!(from_argv(&a).as_deref(), Some("xhigh"));
        assert_eq!(
            from_argv(&argv(&["codex", "--config=model_reasoning_effort=medium"])).as_deref(),
            Some("medium")
        );
    }

    #[test]
    fn other_config_and_junk_are_no_effort() {
        assert_eq!(from_argv(&argv(&["codex", "-c", "model=gpt-6"])), None);
        assert_eq!(from_argv(&argv(&["claude", "--effort"])), None);
        assert_eq!(from_argv(&argv(&["claude", "--effort", "$(rm -rf)"])), None);
        assert_eq!(from_argv(&argv(&["claude", "--effort", ""])), None);
    }

    #[test]
    fn env_by_family_profile_first() {
        let profile = env(&[("CLAUDE_EFFORT", "medium")]);
        let defaults = env(&[("CLAUDE_EFFORT", "high"), ("CODEX_REASONING_EFFORT", "low")]);
        assert_eq!(from_envs(Some("claude"), &[&profile, &defaults]).as_deref(), Some("medium"));
        assert_eq!(from_envs(Some("codex"), &[&profile, &defaults]).as_deref(), Some("low"));
        assert_eq!(from_envs(Some("opencode"), &[&profile, &defaults]), None);
        assert_eq!(from_envs(None, &[&profile]), None);
    }

    #[test]
    fn claude_code_key_wins_over_short_key() {
        let e = env(&[("CLAUDE_EFFORT", "high"), ("CLAUDE_CODE_EFFORT_LEVEL", "medium")]);
        assert_eq!(from_envs(Some("claude"), &[&e]).as_deref(), Some("medium"));
    }

    #[test]
    fn argv_wins_over_env() {
        let e = env(&[("CLAUDE_EFFORT", "high")]);
        let a = argv(&["claude", "--effort", "medium"]);
        assert_eq!(of_launch(Some("claude"), &a, &[&e]).as_deref(), Some("medium"));
    }
}
