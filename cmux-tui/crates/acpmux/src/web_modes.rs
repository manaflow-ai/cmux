//! The modes a remote (Web) connection may use: the reviewed per-harness
//! table, what config.json adds, and the modes that never ask
//! (plans/cmux-next/acp-remote-guard.md). One table serves the remote guard
//! (what a Web request may set or start from) and the hub (Web control of a
//! session ends when its mode leaves the table). Codex and opencode are
//! refused families: the Web never drives them, whatever config.json says.

use crate::config::{Config, HarnessProfile};
use crate::store::SessionMeta;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

/// Harness families a remote (Web) connection never drives (D10,
/// 2026-10-06): neither has a mode that asks before every edit and every
/// command. codex-acp 1.10.0 runs every mode with `on-request` approval,
/// where the model decides when to ask, and a workspace-write sandbox (or
/// none); opencode 1.18.33 starts every agent from `"*": "allow"` and merges
/// the user's rules last, which acpmux cannot see. No config entry, preset or
/// default adds them back; a harness that gains a verifiable mode that asks
/// before each change goes back into `ASKING_MODES` after a review
/// (plans/cmux-next/acp-remote-guard.md).
pub(crate) const REFUSED_FAMILIES: &[&str] = &["codex", "opencode"];

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
    // Codex and opencode have no row: `REFUSED_FAMILIES`.
];

/// Modes the reviewed sources name as NOT asking. A config.json
/// (`webAskingModes`) entry naming one is ignored with a warning, so a local
/// typo cannot open a permissive mode to the Web.
pub(crate) const NON_ASKING_MODES: &[(&str, &[&str])] = &[
    // Claude (claude-agent-acp 0.74.0, dist/permissions/modes.js): edits,
    // everything, a classifier, or no check at all, without asking.
    ("claude", &["acceptEdits", "dontAsk", "auto", "bypassPermissions"]),
    // Codex (codex-acp 1.10.0, dist/index.js `AgentMode`): "read-only" (on
    // request, workspace-write: edits and commands in the workspace without
    // asking), "agent" (the same, auto_review, its default) and
    // "agent-full-access".
    ("codex", &["read-only", "agent", "agent-full-access"]),
    // opencode 1.18.33: "build", its default, allows everything; "plan"
    // (allows bash) is not listed here because Claude's "plan" asks.
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

/// `REFUSED_FAMILIES` plus `extra` (families whose profile runs one).
pub(crate) fn refused_families_for(extra: impl IntoIterator<Item = String>) -> BTreeSet<String> {
    REFUSED_FAMILIES.iter().map(|f| f.to_string()).chain(extra).collect()
}

/// The refused families for `cfg`: `REFUSED_FAMILIES`, and the family of
/// every profile whose command line runs one of them, so an explicit
/// `family` (`{"argv": ["codex-acp"], "family": "mine"}`) cannot rename
/// Codex into a family that config.json opens.
pub(crate) fn refused_families(cfg: &Config) -> BTreeSet<String> {
    let runs_refused = |name: &str, p: &HarnessProfile| {
        let unnamed = HarnessProfile { family: None, ..p.clone() };
        REFUSED_FAMILIES.contains(&crate::config::derive_family(name, &unnamed).as_str())
    };
    refused_families_for(
        cfg.harnesses
            .iter()
            .filter(|(name, p)| runs_refused(name, p))
            .map(|(name, p)| crate::config::derive_family(name, p)),
    )
}

/// The merged table: the reviewed rows, then config.json's additions minus
/// any mode the reviewed sources name as non-asking and any refused family.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WebModeTable {
    by_family: BTreeMap<String, Vec<String>>,
    refused: BTreeSet<String>,
}

/// The reviewed rows alone, with `REFUSED_FAMILIES`: never a table that
/// forgets the refusal.
impl Default for WebModeTable {
    fn default() -> Self {
        Self::build(&BTreeMap::new()).0
    }
}

impl WebModeTable {
    /// Build from config.json's `webAskingModes`, refusing
    /// `REFUSED_FAMILIES`; also returns one warning per ignored entry.
    pub fn build(extra: &BTreeMap<String, Vec<String>>) -> (Self, Vec<String>) {
        Self::build_refusing(extra, &refused_families_for([]))
    }

    /// `build`, refusing `refused` (a superset of `REFUSED_FAMILIES`).
    pub fn build_refusing(
        extra: &BTreeMap<String, Vec<String>>,
        refused: &BTreeSet<String>,
    ) -> (Self, Vec<String>) {
        let refused = refused_families_for(refused.iter().cloned());
        let mut by_family: BTreeMap<String, Vec<String>> = ASKING_MODES
            .iter()
            .filter(|(f, _)| !refused.contains(*f))
            .map(|(f, m)| (f.to_string(), m.iter().map(|s| s.to_string()).collect()))
            .collect();
        let mut warnings = Vec::new();
        for (family, modes) in extra {
            for mode in modes {
                if refused.contains(family) {
                    warnings.push(format!(
                        "webAskingModes: ignoring {mode:?} for {family:?}: a remote connection never drives this harness (it has no mode that asks before each change)"
                    ));
                    continue;
                }
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
        (Self { by_family, refused }, warnings)
    }

    /// The asking modes of `family`, the asking default first; none for a
    /// refused family.
    pub fn modes(&self, family: &str) -> &[String] {
        if self.refused.contains(family) {
            return &[];
        }
        self.by_family.get(family).map(Vec::as_slice).unwrap_or(&[])
    }

    /// The families the Web never drives.
    pub fn refused(&self) -> &BTreeSet<String> {
        &self.refused
    }

    /// Whether a session's mode asks: never for a refused family; else none
    /// reported, or listed for its family.
    pub fn session_asks(&self, m: &SessionMeta) -> bool {
        if self.refused.contains(&family_of(m)) {
            return false;
        }
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
        if self.refused.contains(family) {
            return false;
        }
        if config_id.is_some_and(|i| FREE_CONFIG_IDS.contains(&i)) {
            return true;
        }
        let mode = match config_id {
            None | Some("mode") => value,
            Some(_) => None,
        };
        mode.is_some_and(|v| self.modes(family).iter().any(|a| a == v))
    }

    /// One line for the log: `claude=[default,plan] ... refused=[codex,opencode]`.
    pub fn summary(&self) -> String {
        self.by_family
            .iter()
            .map(|(f, m)| format!("{f}=[{}]", m.join(",")))
            .chain(std::iter::once(format!(
                "refused=[{}]",
                self.refused.iter().cloned().collect::<Vec<_>>().join(",")
            )))
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
        assert!(table.modes("codex").is_empty(), "{:?}", table.modes("codex"));
        assert_eq!(table.modes("myharness"), ["ask"]);
        assert_eq!(warnings.len(), 2, "{warnings:?}");
        assert!(warnings[0].contains("\"agent\""), "{warnings:?}");
        assert!(!table.summary().contains("codex="), "{}", table.summary());
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
