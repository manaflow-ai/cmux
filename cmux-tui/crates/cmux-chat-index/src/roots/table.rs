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
    let _ = (windows, Platform::MacOs);
    match kind {
        AdapterKind::ClaudeCode => {
            add(sub(b.var("CLAUDE_CONFIG_DIR"), "projects"), Env);
            add(Some(b.home(".claude/projects")), Default);
        }
        AdapterKind::Codex => {
            add(b.var("CODEX_HOME"), Env);
            add(Some(b.home(".codex")), Default);
        }
        AdapterKind::OpenCode => {
            add(sub(b.var("XDG_DATA_HOME"), "opencode"), Env);
            add(Some(b.home(".local/share/opencode")), Default);
        }
        AdapterKind::Pi => {
            add(b.var("PI_CODING_AGENT_SESSION_DIR"), Env);
            add(sub(b.var("PI_CODING_AGENT_DIR"), "sessions"), Env);
            add(Some(b.home(".pi/agent/sessions")), Default);
        }
        AdapterKind::Gemini => {
            add(sub(b.var("GEMINI_CLI_HOME"), ".gemini"), Env);
            add(Some(b.home(".gemini")), Default);
        }
        AdapterKind::CursorAgent => add(Some(b.home(".cursor/chats")), Default),
        AdapterKind::Amp => {
            add(sub(b.var("XDG_DATA_HOME"), "amp/threads"), Env);
            add(Some(b.home(".local/share/amp/threads")), Default);
            add(Some(b.home("Library/Application Support/amp/threads")), Default);
        }
        _ => {}
    }
}

#[allow(dead_code)]
/// VS Code-family editors whose extensions keep chat tasks in globalStorage.
const VSCODE_APPS: [&str; 6] =
    ["Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium", "Code - OSS"];

/// `<user data>/User/globalStorage/<extension id>` for each editor:
/// `~/Library/Application Support/<App>`, `$XDG_CONFIG_HOME/<App>`,
/// `%APPDATA%\<App>`.
#[allow(dead_code)]
fn vscode_global_storage(b: &Bases<'_>, extension: &str) -> Vec<PathBuf> {
    let base = b.os_config();
    VSCODE_APPS
        .iter()
        .map(|app| join(&base, app).join("User").join("globalStorage").join(extension))
        .collect()
}
