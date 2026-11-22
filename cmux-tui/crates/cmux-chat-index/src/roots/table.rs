//! The store-root table: for each harness, the env overrides and default
//! dirs on macOS, Linux and Windows, in priority order. Evidence for every
//! row is in plans/cmux-next/chat-index-formats.md.

use std::path::PathBuf;

use super::RootSource::{self, Default, Env};
use super::platform::{Bases, Platform, join};
use crate::entry::AdapterKind;

pub(super) fn roots(
    kind: AdapterKind,
    b: &Bases<'_>,
    add: &mut dyn FnMut(Option<PathBuf>, RootSource),
) {
    let windows = b.platform == Platform::Windows;
    let sub = |base: Option<PathBuf>, rel: &str| base.map(|base| join(&base, rel));
    match kind {
        AdapterKind::ClaudeCode => {
            add(sub(b.var("CLAUDE_CONFIG_DIR"), "projects"), Env);
            // Claude Code 1.0.28-1.0.31 used $XDG_CONFIG_HOME/claude when set.
            add(sub(b.var("XDG_CONFIG_HOME"), "claude/projects"), Env);
            add(Some(b.home(".claude/projects")), Default);
            if !windows {
                add(Some(b.home(".config/claude/projects")), Default);
            }
        }
        AdapterKind::Codex => {
            add(b.var("CODEX_HOME"), Env);
            add(Some(b.home(".codex")), Default);
        }
        AdapterKind::OpenCode => {
            // xdg-basedir on every platform: ~/.local/share/opencode, also on
            // macOS and Windows. v0.0.53-0.0.55 used env-paths.
            add(sub(b.var("XDG_DATA_HOME"), "opencode"), Env);
            add(Some(b.home(".local/share/opencode")), Default);
            add(
                Some(match b.platform {
                    Platform::MacOs => b.home("Library/Application Support/opencode"),
                    Platform::Linux => b.home(".local/share/opencode"),
                    Platform::Windows => join(&b.local_appdata(), "opencode/Data"),
                }),
                Default,
            );
        }
        AdapterKind::Pi => {
            add(b.var("PI_CODING_AGENT_SESSION_DIR"), Env);
            let agent_dir = b.var("PI_CODING_AGENT_DIR");
            add(
                b.pi_settings_session_dir(agent_dir.clone().unwrap_or_else(|| b.home(".pi/agent"))),
                Env,
            );
            add(sub(agent_dir, "sessions"), Env);
            add(Some(b.home(".pi/agent/sessions")), Default);
            // v0.0.x-v0.7.x: ~/.coding-agent with CODING_AGENT_DIR.
            add(sub(b.var("CODING_AGENT_DIR"), "sessions"), Env);
            add(Some(b.home(".coding-agent/sessions")), Default);
        }
        AdapterKind::Gemini => {
            add(sub(b.var("GEMINI_CLI_HOME"), ".gemini"), Env);
            add(Some(b.home(".gemini")), Default);
            if b.platform == Platform::MacOs {
                // Seatbelt sandbox runs (SANDBOX=sandbox-exec, v0.61.0+).
                add(Some(b.home(".cache/.gemini")), Default);
            }
        }
        AdapterKind::CursorAgent => {
            add(sub(b.var("CURSOR_DATA_DIR"), "chats"), Env);
            add(sub(b.var("CURSOR_CONFIG_DIR"), "chats"), Env);
            add(sub(b.var("XDG_CONFIG_HOME"), "cursor/chats"), Env);
            add(Some(b.home(".cursor/chats")), Default);
        }
        AdapterKind::Amp => {
            // The last Amp build with a local thread store (2026-03) used
            // the XDG data dir on every platform.
            add(sub(b.var("XDG_DATA_HOME"), "amp/threads"), Env);
            add(Some(b.home(".local/share/amp/threads")), Default);
        }
        AdapterKind::QwenCode => {
            add(b.var("QWEN_RUNTIME_DIR"), Env);
            add(b.var("QWEN_HOME"), Env);
            add(Some(b.home(".qwen")), Default);
        }
        AdapterKind::CopilotCli => {
            add(b.var("COPILOT_HOME"), Env);
            // Builds before the XDG migration used $XDG_STATE_HOME/.copilot.
            add(sub(b.var("XDG_STATE_HOME"), ".copilot"), Env);
            add(Some(b.home(".copilot")), Default);
        }
        AdapterKind::Grok => {
            add(sub(b.var("GROK_HOME"), "sessions"), Env);
            add(Some(b.home(".grok/sessions")), Default);
        }
        AdapterKind::GrokCli => add(Some(b.home(".grok")), Default),
        AdapterKind::KimiCli => {
            add(b.var("KIMI_SHARE_DIR"), Env);
            add(Some(b.home(".kimi")), Default);
            // v0.32-v0.33.
            add(Some(join(&b.xdg_data(), "kimi")), Default);
        }
        AdapterKind::KimiCode => {
            add(b.var("KIMI_CODE_HOME"), Env);
            add(Some(b.home(".kimi-code")), Default);
        }
        AdapterKind::Goose => {
            add(sub(b.var("GOOSE_PATH_ROOT"), "data/sessions"), Env);
            add(
                Some(match b.platform {
                    // etcetera's Xdg strategy on macOS too (not ~/Library).
                    Platform::MacOs | Platform::Linux => join(&b.xdg_data(), "goose/sessions"),
                    Platform::Windows => join(&b.appdata(), "Block/goose/data/sessions"),
                }),
                Default,
            );
        }
        AdapterKind::Droid => {
            add(sub(b.var("FACTORY_HOME_OVERRIDE"), ".factory/sessions"), Env);
            add(Some(b.home(".factory/sessions")), Default);
        }
        AdapterKind::Cline => {
            add(b.var("CLINE_DATA_DIR"), Env);
            add(sub(b.var("CLINE_DIR"), "data"), Env);
            add(Some(b.home(".cline/data")), Default);
            for dir in vscode_global_storage(b, "saoudrizwan.claude-dev") {
                add(Some(dir), Default);
            }
        }
        AdapterKind::RooCode => {
            for dir in vscode_global_storage(b, "rooveterinaryinc.roo-cline") {
                add(Some(dir), Default);
            }
        }
        AdapterKind::KiloCode => {
            for dir in vscode_global_storage(b, "kilocode.kilo-code") {
                add(Some(dir), Default);
            }
            add(Some(b.home(".kilocode/cli/global")), Default);
        }
        AdapterKind::Kilo => {
            add(sub(b.var("XDG_DATA_HOME"), "kilo"), Env);
            add(Some(b.home(".local/share/kilo")), Default);
        }
        AdapterKind::Crush => {
            // One root per project data dir that Crush's global index lists.
            let globals = [
                (b.var("CRUSH_GLOBAL_DATA"), Env),
                (sub(b.var("XDG_DATA_HOME"), "crush"), Env),
                (windows.then(|| join(&b.local_appdata(), "crush")), Default),
                (Some(b.home(".local/share/crush")), Default),
            ];
            for (global, source) in globals {
                let Some(global) = global.filter(|global| b.readable(global)) else { continue };
                for dir in crate::adapters::crush_project_dirs(&global.join("projects.json")) {
                    add(Some(dir), source);
                }
            }
        }
        AdapterKind::Auggie => add(Some(b.home(".augment/sessions")), Default),
        AdapterKind::Continue => {
            add(sub(b.var("CONTINUE_GLOBAL_DIR"), "sessions"), Env);
            add(Some(b.home(".continue/sessions")), Default);
        }
        AdapterKind::OpenHands => {
            add(b.var("OPENHANDS_CONVERSATIONS_DIR"), Env);
            add(sub(b.var("OPENHANDS_PERSISTENCE_DIR"), "conversations"), Env);
            add(Some(b.home(".openhands/conversations")), Default);
        }
    }
}

/// VS Code-family editors whose extensions keep chat tasks in globalStorage.
const VSCODE_APPS: [&str; 6] =
    ["Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium", "Code - OSS"];

/// `<user data>/User/globalStorage/<extension id>` for each editor:
/// `~/Library/Application Support/<App>`, `$XDG_CONFIG_HOME/<App>`,
/// `%APPDATA%\<App>`.
fn vscode_global_storage(b: &Bases<'_>, extension: &str) -> Vec<PathBuf> {
    let base = b.os_config();
    VSCODE_APPS
        .iter()
        .map(|app| join(&base, app).join("User").join("globalStorage").join(extension))
        .collect()
}
