//! One name per agent harness and per record source in what the CLI prints.
//!
//! The same Claude Code agent used to show as `claude-code` from its OSC 7501
//! program status and as `claude` from its hooks; the screen-detection
//! plugin's records said `detected` in older journals and `plugin` now.
//! Output always uses the canonical words below. The old words stay accepted
//! as input (`--harness claude-code`, a record that still says `detected`).
//!
//! | canonical | accepted aliases |
//! | --- | --- |
//! | `claude` | `claude-code`, `claude_code`, `claudecode`, `Claude Code` |
//! | `codex` | `codex-cli`, `codex_cli`, `openai-codex` |
//! | `opencode` | `open-code`, `open_code` |
//! | `gemini` | `gemini-cli`, `gemini_cli` |
//! | `amp` | `ampcode`, `amp-code` |
//!
//! Sources: `hook`, `plugin` (alias `detected`), `socket` and
//! `program_status` (OSC 7501; alias `status`, `osc7501`).

/// The canonical harness name for `raw` (any case, any alias above);
/// unknown harnesses keep their own name, in lower case.
pub(in crate::cli) fn harness_name(raw: &str) -> String {
    let lower = raw.trim().to_ascii_lowercase();
    let canonical = match lower.as_str() {
        "claude" | "claude-code" | "claude_code" | "claudecode" | "claude code" => "claude",
        "codex" | "codex-cli" | "codex_cli" | "openai-codex" => "codex",
        "opencode" | "open-code" | "open_code" => "opencode",
        "gemini" | "gemini-cli" | "gemini_cli" => "gemini",
        "amp" | "ampcode" | "amp-code" => "amp",
        _ => return lower,
    };
    canonical.to_owned()
}

/// The canonical source name for `raw`: `detected` is the plugin's old
/// word, `status`/`osc7501` the program status's.
pub(in crate::cli) fn source_name(raw: &str) -> String {
    match raw.trim().to_ascii_lowercase().as_str() {
        "detected" | "plugin" => "plugin".to_owned(),
        "status" | "osc7501" | "program_status" | "program-status" => "program_status".to_owned(),
        other => other.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::{harness_name, source_name};

    #[test]
    fn w3h_vocabulary_has_one_name_per_harness_and_source() {
        for alias in ["claude", "claude-code", "claude_code", "Claude Code", "CLAUDE-CODE"] {
            assert_eq!(harness_name(alias), "claude", "{alias}");
        }
        for alias in ["codex", "codex-cli", "openai-codex"] {
            assert_eq!(harness_name(alias), "codex", "{alias}");
        }
        assert_eq!(harness_name("open-code"), "opencode");
        assert_eq!(harness_name("gemini-cli"), "gemini");
        assert_eq!(harness_name("ampcode"), "amp");
        assert_eq!(harness_name("Pi"), "pi");
        assert_eq!(source_name("detected"), "plugin");
        assert_eq!(source_name("plugin"), "plugin");
        assert_eq!(source_name("hook"), "hook");
        assert_eq!(source_name("osc7501"), "program_status");
        assert_eq!(source_name("program_status"), "program_status");
        assert_eq!(source_name("socket"), "socket");
    }
}
