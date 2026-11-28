//! A built-in provider's program, home folder, extra launch args and env, set in cmux Settings:
//! `agents.providers.<claude|codex>.{path,home,args,env}` in the settings file
//! (`user_settings.rs`), read at each start of that provider's chat (`hub/spawn.rs`), so a change
//! applies to the next new chat. Every key unset is today's launch.
//!
//! Only the built-in profiles discovery found (the `claude` Claude Code and the `codex` bridge on
//! `codex app-server`, with the names that stand in for them) take them. A harness profile of the
//! person's own (`~/.config/cmux/harnesses/<id>.toml`, `cmux harness add`) already names its
//! command, args and env, and a profile named `claude` or `codex` replaces the built-in one, so
//! these keys never reach it.
//!
//! - `path`: Claude Code's program in place of the `claude` found on PATH; Codex's `CODEX_PATH`,
//!   the binary the bridge runs (`agent/command.rs`).
//! - `home`: `CLAUDE_CONFIG_DIR` or `CODEX_HOME`. A bound account's own home still wins
//!   (`routes.rs`, applied after these).
//! - `args`: appended after the built-in argv, before a preset's args.
//! - `env`: over `defaults.<family>.env` of config.json; a preset's and the session's env still
//!   win. Secrets stay in `cmux harness secret` (the Keychain), never in this file.
//!
//! `~/`, `${home}`, `${cwd}` and `${model}` expand as in a profile.

use crate::config::{HarnessKind, HarnessProfile};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;

/// A built-in provider with launch settings.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    Claude,
    Codex,
}

impl Provider {
    /// The settings key's provider part: `agents.providers.<id>`.
    pub fn id(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }

    /// The variable that names the provider's home folder.
    pub fn home_env(self) -> &'static str {
        match self {
            Self::Claude => "CLAUDE_CONFIG_DIR",
            Self::Codex => "CODEX_HOME",
        }
    }

    /// The provider a built-in profile launches: Claude Code through acpmux's own adapter on a
    /// `claude` program, or Codex through the bridge.
    /// `None` for a profile of the person's own (`builtin` false) and every other harness.
    pub fn of_builtin(profile: &HarnessProfile, builtin: bool) -> Option<Self> {
        if !builtin {
            return None;
        }
        let program = profile.argv.first()?;
        let stem = Path::new(program).file_stem().and_then(|s| s.to_str()).unwrap_or("");
        if profile.kind == HarnessKind::ClaudeStdio && stem == "claude" {
            return Some(Self::Claude);
        }
        if crate::codex_app_server::is_launch(program, profile.argv.get(1..).unwrap_or_default()) {
            return Some(Self::Codex);
        }
        None
    }
}

/// One provider's launch settings; empty is today's launch.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Launch {
    pub path: Option<String>,
    pub home: Option<String>,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
}

impl Launch {
    /// The provider's keys in a settings document, either form the settings owner writes (nested
    /// or flat dotted keys). A value of the wrong type, an empty text or an invalid env name is
    /// left out: it is unset.
    pub fn read(doc: &Value, provider: Provider) -> Self {
        let key = |field: &str| {
            crate::user_settings::value(doc, &format!("agents.providers.{}.{field}", provider.id()))
        };
        let text = |field: &str| {
            key(field)
                .and_then(|v| v.as_str().map(str::trim).map(str::to_owned))
                .filter(|s| !s.is_empty())
        };
        let args = key("args")
            .and_then(|v| v.as_array().cloned())
            .unwrap_or_default()
            .into_iter()
            .filter_map(|a| a.as_str().map(str::to_owned))
            .filter(|a| !a.is_empty())
            .collect();
        let env = key("env")
            .and_then(|v| v.as_object().cloned())
            .unwrap_or_default()
            .into_iter()
            .filter(|(k, _)| crate::config::profiles::valid_env_key(k))
            .filter_map(|(k, v)| v.as_str().map(|v| (k, v.to_owned())))
            .collect();
        Self { path: text("path"), home: text("home"), args, env }
    }

    /// The provider's settings as the settings file holds them now. No file, or one that does
    /// not parse, is today's launch.
    pub fn current(provider: Provider) -> Self {
        match crate::user_settings::read() {
            crate::user_settings::Settings::Parsed(doc) => Self::read(&doc, provider),
            crate::user_settings::Settings::Missing
            | crate::user_settings::Settings::Unreadable(_) => Self::default(),
        }
    }

    /// Applies these settings to `profile`, the built-in launch of `provider` (with its family
    /// defaults' env already in it).
    pub fn apply(&self, profile: &mut HarnessProfile, provider: Provider) {
        if let Some(path) = &self.path {
            match provider {
                Provider::Claude => {
                    if let Some(program) = profile.argv.first_mut() {
                        *program = path.clone();
                    }
                }
                Provider::Codex => {
                    profile.env.insert("CODEX_PATH".to_owned(), path.clone());
                }
            }
        }
        if let Some(home) = &self.home {
            profile.env.insert(provider.home_env().to_owned(), home.clone());
        }
        profile.argv.extend(self.args.iter().cloned());
        for (k, v) in &self.env {
            profile.env.insert(k.clone(), v.clone());
        }
    }
}

#[cfg(test)]
#[path = "provider_settings_tests.rs"]
mod tests;
