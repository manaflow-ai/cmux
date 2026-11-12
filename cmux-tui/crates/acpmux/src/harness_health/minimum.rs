//! The oldest agent CLI version acpmux supports, per harness (cmux#42212).
//!
//! The model pickers offer a curated model only when the harness's own CLI
//! lists it (`hub/models_view.rs`, `offered`): the CLI decides what it runs.
//! An older CLI does not know newer models, so they are missing from the
//! picker. Claude Code lists the models of its own release. Codex's server
//! gates each model on the client's version. Below the minimum, the health
//! row says `unsupported` and the pane offers a one-click update.
//!
//! Each minimum is the first release whose own list, as measured, has every
//! current model in the bundled catalog (`catalog/models-v1.json`). The
//! measurement used acpmux's live probes (`live_models`), 2026-11-12:
//! - Claude Code `list_models`: 2.1.278 lists Opus 5 and no 5.5 models;
//!   2.1.292 has Opus and Sonnet 5.5 but Haiku 4.5; 2.1.293 has Opus,
//!   Sonnet and Haiku 5.5.
//! - Codex `model/list`: 0.147.0 gets GPT-5.6 Sol, Terra and Luna only;
//!   0.148.0 gets GPT-6.1 Sol, GPT-6 Astra, Sol and Luna.
//!
//! Raise a minimum when a catalog update adds a model that only a newer CLI
//! lists.

use super::probe::compare_versions;
use std::cmp::Ordering;
use std::path::Path;

/// One harness's minimum: its acpmux family, the program the version is read
/// from (the configured command's file name), and the oldest supported version.
struct Minimum {
    family: &'static str,
    program: &'static str,
    version: &'static str,
}

const MINIMUMS: &[Minimum] = &[
    Minimum { family: "claude", program: "claude", version: "2.1.293" },
    Minimum { family: "codex", program: "codex", version: "0.148.0" },
];

/// The oldest version acpmux supports for a harness of `family` whose command
/// is `program`. None when acpmux names no minimum, or when the program is not
/// the CLI itself (an adapter such as `codex-acp` or a wrapper such as
/// `claude-sr2` reports its own version, not the CLI's).
pub fn minimum(family: &str, program: &str) -> Option<&'static str> {
    let name = Path::new(program).file_name()?.to_str()?;
    let name = name.strip_suffix(".exe").unwrap_or(name);
    MINIMUMS.iter().find(|m| m.family == family && m.program == name).map(|m| m.version)
}

/// Whether `installed` is older than `minimum`. A version that does not parse,
/// or a source build's `0.0.0`, is never called unsupported.
pub fn below(installed: &str, minimum: &str) -> bool {
    let source_build = installed
        .trim()
        .trim_start_matches('v')
        .split(['-', '+', ' '])
        .next()
        .is_some_and(|core| core.split('.').all(|part| part == "0"));
    !source_build && compare_versions(installed, minimum) == Some(Ordering::Less)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_and_codex_have_minimums_by_their_own_program() {
        assert_eq!(minimum("claude", "/opt/homebrew/bin/claude"), Some("2.1.293"));
        assert_eq!(minimum("claude", "claude"), Some("2.1.293"));
        assert_eq!(minimum("codex", "/Users/me/.local/bin/codex"), Some("0.148.0"));
        // An adapter or wrapper reports its own version.
        assert_eq!(minimum("codex", "codex-acp"), None);
        assert_eq!(minimum("claude", "/Users/me/.local/bin/claude-sr2"), None);
        assert_eq!(minimum("opencode", "opencode"), None);
        // Windows names the program with its extension.
        assert_eq!(minimum("claude", "/Users/me/.local/bin/claude.exe"), Some("2.1.293"));
        assert_eq!(minimum("codex", "codex.exe"), Some("0.148.0"));
    }

    #[test]
    fn below_compares_numerically_and_spares_source_builds() {
        assert!(below("2.1.292", "2.1.293"));
        assert!(below("2.1.99", "2.1.293"));
        assert!(!below("2.1.293", "2.1.293"));
        assert!(!below("2.1.322", "2.1.293"));
        assert!(below("0.147.0", "0.148.0"));
        assert!(!below("0.0.0", "0.148.0"));
        assert!(!below("unknown", "0.148.0"));
    }
}
