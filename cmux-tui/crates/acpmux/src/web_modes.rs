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
/// none). opencode starts every agent from `"*": "allow"` and merges the
/// user's rules last, which acpmux cannot see. Re-checked against opencode
/// v1.19.0 (2026-10-15, cnx-ios parity round 3): acpmux cannot force asking
/// from outside either. `packages/opencode/src/config/config.ts`
/// (`loadInstanceState`) merges, later winning, the global config, then
/// `OPENCODE_CONFIG`, project files, every config directory (with its agent
/// files, plugins and custom tools), `OPENCODE_CONFIG_CONTENT`, the account's
/// org config, the managed directory and the macOS MDM plist (which "overrides
/// everything"), and `OPENCODE_PERMISSION` only into the top-level list;
/// `src/agent/agent.ts` appends each agent's own `permission` after that, and
/// `src/permission/index.ts` `evaluate` takes the last matching rule. So an
/// agent file or a later key such as `"b*": "allow"` beats anything a
/// launcher sets, and custom tools, plugins, MCP tools (default allow) and
/// `!` command templates run without the edit/bash/webfetch asks.
/// `OPENCODE_DISABLE_PROJECT_CONFIG` and `--pure` leave the global config,
/// org config, managed config and custom tools in place. acpmux still asks
/// OpenCode to ask for a chat whose permission policy is narrower than
/// approve-all (`opencode_ask.rs`): `OPENCODE_CONFIG_CONTENT` with
/// `"permission": {"*": "ask"}`, which holds unless something above comes
/// after it, so that chat logs `policy_unenforced` and the Web refusal stays.
/// No config entry, preset or default adds them back; a harness that gains a
/// verifiable mode that asks before each change goes back into `ASKING_MODES`
/// after a review (plans/cmux-next/acp-remote-guard.md).
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

/// The Codex bridge's (`codex app-server` through cmux-codex-acp, profile
/// `codex`) modes that ask before every change, the start mode first.
/// cmux-codex-acp c30e6489 `config.rs` `MODES`: "ask" runs Codex with
/// approval policy `untrusted` and a workspace-write sandbox, so Codex asks
/// before every command that is not a known-safe read and before every file
/// change (and MCP tool call), and acpmux's `ask` policy hands each question
/// to the person. "read-only", "agent" and "agent-full-access" use
/// `on-request` or `never`, where Codex decides when to ask. A remote (Web)
/// connection may later pick any bridge mode (`any_mode_for_web`), but a
/// session it STARTS begins here (`remote_guard::settle_web_session_mode`).
pub(crate) const BRIDGE_ASKING_MODES: &[&str] = &["ask"];

/// Why a refused family cannot start from a remote device (shown on the phone).
pub(crate) const NO_ASKING_MODE: &str = "this agent has no mode that asks before each change";
/// opencode can ask, and acpmux asks it to for a narrower policy
/// (`opencode_ask.rs`), but its own config on the Mac (an agent file, a global
/// or managed config) can turn the asks off after anything acpmux sets
/// (`REFUSED_FAMILIES`).
pub(crate) const OPENCODE_REFUSAL: &str =
    "opencode's own settings on this Mac can let it edit and run commands without asking";

/// What a remote (Web) connection may start with `profile` (the
/// `_acpmux/harnesses` row's `remote`): the modes a session it starts runs
/// in (the start mode first), or why it may not start one. The same rules as
/// `remote_guard`: the Codex bridge starts in `BRIDGE_ASKING_MODES`; a
/// refused family never starts; another family starts in its reviewed asking
/// modes, and one with none is refused.
pub fn remote_start(
    table: &WebModeTable,
    name: &str,
    profile: &HarnessProfile,
) -> Result<Vec<String>, String> {
    if crate::codex_app_server::is_profile_launch(&profile.argv) {
        return Ok(BRIDGE_ASKING_MODES.iter().map(|m| m.to_string()).collect());
    }
    let family = crate::config::derive_family(name, profile);
    let unnamed = HarnessProfile { family: None, ..profile.clone() };
    let runs_refused =
        REFUSED_FAMILIES.contains(&crate::config::derive_family(name, &unnamed).as_str());
    if table.refused().contains(&family) || runs_refused {
        let runs_opencode =
            family == "opencode" || crate::config::derive_family(name, &unnamed) == "opencode";
        return Err(if runs_opencode { OPENCODE_REFUSAL } else { NO_ASKING_MODE }.into());
    }
    let modes = table.modes(&family);
    if modes.is_empty() {
        return Err("this agent has no reviewed mode that asks before each change".into());
    }
    Ok(modes.to_vec())
}

/// `remote_start` against one immutable configuration snapshot. The session
/// owner uses this while resolving the exact profile it will spawn, so a
/// request-layer preflight is never the authority boundary.
pub(crate) fn remote_start_for_config(
    cfg: &Config,
    name: &str,
    profile: &HarnessProfile,
) -> Result<Vec<String>, String> {
    let (table, _) = WebModeTable::build_refusing(&cfg.web_asking_modes, &refused_families(cfg));
    remote_start(&table, name, profile)
}

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

/// Config options a Web connection may set to any value: they choose a model,
/// how hard it thinks or how fast it answers, never what runs without asking.
/// Claude's `ultracode` is its top effort (its subagents still ask as the
/// chat's mode says) and `fast-mode` its output speed (`claude_stdio`).
pub(crate) const FREE_CONFIG_IDS: &[&str] = &[
    "model",
    "effort",
    "reasoning_effort",
    "thought_level",
    "thinking",
    crate::claude_stdio::ULTRACODE_OPTION,
    "fast-mode",
];

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

/// Whether a Web connection may run a session in ANY mode: Codex through
/// `codex app-server`, bridged in process (`codex_app_server.rs`), both as
/// recorded at its creation (`harness_argv`) and as its harness name runs
/// now (`now`: the profile the next spawn uses; a failover or a changed PATH
/// that points the name elsewhere ends it).
/// Lawrence, 2026-10-13: "remote connection must be authed, and should be
/// able to pretty much use yolo mode". A Web control request reaches the
/// mode checks only from an authenticated connection (`server/conn_auth.rs`:
/// `ConnAuth::None` is refused at its first request, and the remote guard
/// refuses it again), so these sessions take every mode of the bridge,
/// agent-full-access included. The codex-acp adapter stays refused
/// (`REFUSED_FAMILIES`): it is being replaced.
pub(crate) fn any_mode_for_web(
    m: &SessionMeta,
    now: Option<&crate::config::HarnessProfile>,
) -> bool {
    crate::codex_app_server::is_profile_launch(&m.harness_argv)
        && now.is_some_and(|p| crate::codex_app_server::is_profile_launch(&p.argv))
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
mod remote_start_tests {
    use super::*;

    fn profile(value: serde_json::Value) -> HarnessProfile {
        serde_json::from_value(value).unwrap()
    }

    /// opencode stays refused from a remote device, and the reason says why
    /// precisely (its own config can turn the asks off); the codex-acp adapter
    /// keeps the general reason, and Claude starts in its asking modes.
    #[test]
    fn opencode_is_refused_with_its_own_reason() {
        let table = WebModeTable::default();
        let opencode =
            profile(serde_json::json!({"argv": ["opencode", "acp"], "family": "opencode"}));
        assert_eq!(remote_start(&table, "opencode", &opencode), Err(OPENCODE_REFUSAL.to_string()));
        // opencode under another family name is still opencode.
        let renamed = profile(
            serde_json::json!({"argv": ["/opt/homebrew/bin/opencode", "acp"], "family": "claude"}),
        );
        assert_eq!(remote_start(&table, "mine", &renamed), Err(OPENCODE_REFUSAL.to_string()));
        let adapter = profile(serde_json::json!({"argv": ["codex-acp"], "family": "codex"}));
        assert_eq!(remote_start(&table, "codex-acp", &adapter), Err(NO_ASKING_MODE.to_string()));
        let claude = profile(serde_json::json!({"argv": ["claude"], "family": "claude"}));
        assert_eq!(
            remote_start(&table, "claude", &claude),
            Ok(vec!["default".to_string(), "plan".to_string()])
        );
    }
}
