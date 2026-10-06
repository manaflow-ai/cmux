//! The modes a remote (Web) connection may use: the reviewed per-harness
//! table, what config.json adds, and the modes that never ask
//! (plans/cmux-next/acp-remote-guard.md). One table serves the remote guard
//! (what a Web request may set or start from) and the hub (Web control of a
//! session ends when its mode leaves the table).

use crate::store::SessionMeta;
use serde_json::Value;
use std::collections::BTreeMap;

/// Per harness family, the exact mode ids that ask before they act; the
/// first is the asking default a new Web session is moved to. An unknown
/// family, or a mode its row does not list, is refused for the Web.
pub(crate) const ASKING_MODES: &[(&str, &[&str])] = &[
    // Claude (claude-agent-acp 0.74.0, dist/permissions/modes.js, and
    // acpmux's own backend, claude_stdio/mod.rs `MODES`): "default" "prompts
    // for permission on first use of each tool" and "plan" "can analyze but
    // not modify files or execute commands"
    // (https://docs.anthropic.com/en/docs/claude-code/iam#permission-modes).
    ("claude", &["default", "plan"]),
    // Codex (codex-acp 1.10.0, dist/index.js `_AgentMode`): "read-only" is
    // "Ask for approval" ("Always ask to edit external files and use the
    // internet"; approval on-request, reviewer user).
    ("codex", &["read-only"]),
    // opencode: the "plan" agent sets file edits and bash to "ask"
    // (https://opencode.ai/docs/agents/#plan).
    ("opencode", &["plan"]),
];

/// Modes the reviewed sources name as NOT asking. A config.json
/// (`webAskingModes`) entry naming one is ignored with a warning, so a local
/// typo cannot open a permissive mode to the Web.
pub(crate) const NON_ASKING_MODES: &[(&str, &[&str])] = &[
    // Claude (claude-agent-acp 0.74.0, dist/permissions/modes.js): edits,
    // everything, a classifier, or no check at all, without asking.
    ("claude", &["acceptEdits", "dontAsk", "auto", "bypassPermissions"]),
    // Codex (codex-acp 1.10.0, dist/index.js `_AgentMode`): "agent" ("Approve
    // for me", auto_review, its default) and "agent-full-access".
    ("codex", &["agent", "agent-full-access"]),
    // opencode: "build", its default, follows the default permissions, which
    // allow without asking (https://opencode.ai/docs/permissions/).
    ("opencode", &["build"]),
];

/// Fields a Web request may not carry: they could set a mode or a sandbox
/// that acpmux does not check.
pub(crate) const MODE_FIELDS: &[&str] = &[
    "modeId",
    "mode",
    "permissionMode",
    "permission_mode",
    "approvalPolicy",
    "approval_policy",
    "sandbox",
    "sandboxMode",
    "sandbox_mode",
];

/// Config options a Web connection may set to any value: they choose a model
/// or how hard it thinks, never what runs without asking.
pub(crate) const FREE_CONFIG_IDS: &[&str] =
    &["model", "effort", "reasoning_effort", "thought_level", "thinking"];

fn non_asking(mode: &str) -> bool {
    NON_ASKING_MODES.iter().any(|(_, modes)| modes.contains(&mode))
}

/// The merged table: the reviewed rows, then config.json's additions minus
/// any mode the reviewed sources name as non-asking.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WebModeTable {
    by_family: BTreeMap<String, Vec<String>>,
}

impl WebModeTable {
    /// Build from config.json's `webAskingModes`; also returns one warning
    /// per ignored entry.
    pub fn build(extra: &BTreeMap<String, Vec<String>>) -> (Self, Vec<String>) {
        let mut by_family: BTreeMap<String, Vec<String>> = ASKING_MODES
            .iter()
            .map(|(f, m)| (f.to_string(), m.iter().map(|s| s.to_string()).collect()))
            .collect();
        let mut warnings = Vec::new();
        for (family, modes) in extra {
            for mode in modes {
                if non_asking(mode) {
                    warnings.push(format!(
                        "webAskingModes: ignoring {mode:?} for {family:?}: the reviewed table names it a mode that does not ask"
                    ));
                    continue;
                }
                let row = by_family.entry(family.clone()).or_default();
                if !row.contains(mode) {
                    row.push(mode.clone());
                }
            }
        }
        (Self { by_family }, warnings)
    }

    /// The asking modes of `family`, the asking default first.
    pub fn modes(&self, family: &str) -> &[String] {
        self.by_family.get(family).map(Vec::as_slice).unwrap_or(&[])
    }

    /// Whether a session's mode asks: none reported, or listed for its family.
    pub fn session_asks(&self, m: &SessionMeta) -> bool {
        match mode_of(m) {
            None => true,
            Some(mode) => self.modes(&family_of(m)).contains(&mode),
        }
    }

    /// Every family's asking modes, the asking default first.
    pub fn families(&self) -> &BTreeMap<String, Vec<String>> {
        &self.by_family
    }

    /// Whether setting a session of `family` to `value` keeps it asking, as
    /// the remote guard decides a Web set: `config_id` None is
    /// `session/set_mode`; a free config id asks for any value; the `mode`
    /// option and set_mode ask only with a listed mode; any other id never.
    pub fn config_value_asks(
        &self,
        family: &str,
        config_id: Option<&str>,
        value: Option<&str>,
    ) -> bool {
        if config_id.is_some_and(|i| FREE_CONFIG_IDS.contains(&i)) {
            return true;
        }
        let mode = match config_id {
            None | Some("mode") => value,
            Some(_) => None,
        };
        mode.is_some_and(|v| self.modes(family).iter().any(|a| a == v))
    }

    /// One line for the log: `claude=[default,plan] codex=[read-only] ...`.
    pub fn summary(&self) -> String {
        self.by_family
            .iter()
            .map(|(f, m)| format!("{f}=[{}]", m.join(",")))
            .collect::<Vec<_>>()
            .join(" ")
    }
}

pub(crate) fn family_of(m: &SessionMeta) -> String {
    m.family.clone().unwrap_or_else(|| m.harness.clone())
}

/// A session's current mode: its ACP mode, else its `mode` config option.
pub(crate) fn mode_of(m: &SessionMeta) -> Option<String> {
    let from_modes = m.modes.as_ref().and_then(|v| v.get("currentModeId")).and_then(Value::as_str);
    let from_option = || {
        m.config_options.as_ref().and_then(Value::as_array).and_then(|a| {
            a.iter()
                .find(|o| o.get("id").and_then(Value::as_str) == Some("mode"))
                .and_then(|o| o.get("currentValue"))
                .and_then(Value::as_str)
        })
    };
    from_modes.or_else(from_option).map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_config_entry_naming_a_non_asking_mode_is_ignored_with_a_warning() {
        let extra = BTreeMap::from([
            ("codex".to_owned(), vec!["agent".to_owned()]),
            ("myharness".to_owned(), vec!["ask".to_owned(), "bypassPermissions".to_owned()]),
        ]);
        let (table, warnings) = WebModeTable::build(&extra);
        assert_eq!(table.modes("codex"), ["read-only"]);
        assert_eq!(table.modes("myharness"), ["ask"]);
        assert_eq!(warnings.len(), 2, "{warnings:?}");
        assert!(warnings[0].contains("\"agent\""), "{warnings:?}");
        assert!(table.summary().contains("codex=[read-only]"), "{}", table.summary());
    }

    // D10: no config entry opens Codex or opencode to the Web.
    #[test]
    fn a_config_entry_for_codex_or_opencode_is_ignored_with_a_warning() {
        let extra = BTreeMap::from([
            ("codex".to_owned(), vec!["read-only".to_owned(), "agent".to_owned()]),
            ("opencode".to_owned(), vec!["plan".to_owned(), "build".to_owned()]),
            ("mine".to_owned(), vec!["careful".to_owned()]),
        ]);
        let (table, warnings) = WebModeTable::build(&extra);
        assert!(table.modes("codex").is_empty(), "{:?}", table.modes("codex"));
        assert!(table.modes("opencode").is_empty(), "{:?}", table.modes("opencode"));
        assert_eq!(table.modes("mine"), ["careful"]);
        assert_eq!(warnings.len(), 4, "{warnings:?}");
        assert!(!table.summary().contains("codex="), "{}", table.summary());
        assert!(!table.summary().contains("opencode="), "{}", table.summary());
    }

    #[test]
    fn every_reviewed_row_is_disjoint_from_the_non_asking_list() {
        for (family, modes) in ASKING_MODES {
            for mode in *modes {
                assert!(!non_asking(mode), "{family}: {mode} is in both lists");
            }
        }
    }
}
