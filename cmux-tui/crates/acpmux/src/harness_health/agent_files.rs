//! Sign-in evidence for the agent CLIs past Claude Code and Codex, from
//! the files and environment each one reads its login from (Leo,
//! 2026-11-05: "i meant can you do all of htem", the accounts row of
//! leo-workspace research/2026-11-05-where-we-stand.md: "Cursor, Grok,
//! OpenCode, Pi: found on PATH or by harness profile; no sign-in check";
//! Muse's check "tests the install, not the sign-in").
//!
//! Presence only, as `claude_auth` does: a variable is set, a login file is
//! there, a JSON file has an entry. No value is kept, logged or answered,
//! nothing runs, and nothing reads the login keychain (cx-hh0vu): a CLI
//! that keeps its login there (Cursor and Copilot on macOS, Gemini with
//! `GEMINI_FORCE_ENCRYPTED_FILE_STORAGE`) and has no file says nothing, so
//! its sign-in stays unknown. A missing file is never signed out either
//! (the module docs of `harness_health`): the CLI may sign in another way.
//!
//! Where each CLI keeps its login:
//! - Gemini CLI: `GEMINI_API_KEY` or `GOOGLE_API_KEY`; else
//!   `<GEMINI_CLI_HOME or ~>/.gemini/oauth_creds.json`, or its encrypted
//!   file store `gemini-credentials.json` (gemini-cli `config/storage.ts`,
//!   `services/keychainService.ts`).
//! - OpenCode: `OPENCODE_AUTH_CONTENT`, else
//!   `<XDG_DATA_HOME or ~/.local/share>/opencode/auth.json`, one entry per
//!   provider (`opencode auth list` reads the same file; `auth/index.ts`).
//! - Pi: `<PI_CODING_AGENT_DIR or ~/.pi/agent>/auth.json`, one entry per
//!   provider (`core/auth-storage.ts`).
//! - Cursor CLI: `CURSOR_API_KEY` or `CURSOR_AUTH_TOKEN`; else
//!   `<XDG_CONFIG_HOME or ~/.config>/cursor/auth.json` (Linux) or
//!   `~/.cursor/auth.json` (where macOS keeps one outside the keychain).
//! - Copilot CLI: `COPILOT_GITHUB_TOKEN`, `GH_TOKEN` or `GITHUB_TOKEN`; else
//!   a signed-in user in `<COPILOT_HOME or ~/.copilot>/config.json`
//!   (`lastLoggedInUser`, `loggedInUsers`; the token itself is in the
//!   keychain or that file).
//! - Grok CLI (xAI's Grok Build): `GROK_API_KEY` or `XAI_API_KEY`; else the
//!   `grok login` session in `<GROK_HOME or ~/.grok>/auth.json` (a SuperGrok
//!   or X Premium+ sign-in; xai-org/grok-build `02-authentication.md`), or
//!   the older CLI's `~/.grok/user-settings.json` `apiKey`.
//! - Antigravity: `GEMINI_API_KEY` (the ACP server takes it); else the ACP
//!   server's own `<GEMINI_HOME or ~/.gemini>/antigravity-acp/acp_token.json`
//!   or the `agy` CLI's `~/.gemini/antigravity-cli/antigravity-oauth-token`.
//!   Both keep the login in the keychain when one works (macOS "Antigravity
//!   Safe Storage", a Linux secret service) and write the file only without
//!   one, so a keychain sign-in stays unknown; the two logins are separate.
//! - Muse Code: `META_API_KEY` (Muse's docs name no login file, so a
//!   browser sign-in stays unknown).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::Auth;

/// The sign-in evidence for harness `family` whose program is `program`, in
/// the environment `env` it starts with. None: no evidence either way.
pub(super) fn file_auth(
    family: &str,
    program: &str,
    env: &BTreeMap<String, String>,
) -> Option<(Auth, Option<String>)> {
    // Only for the agent itself (or its ACP adapter), by its exact program
    // name: a wrapper (`my-gemini-wrapper`, `ssh`) may run it elsewhere.
    let names: &[&str] = match family {
        "gemini" => &["gemini"],
        "opencode" => &["opencode"],
        "pi" => &["pi", "pi-acp"],
        "cursor" => &["cursor-agent", "agent"],
        "copilot" => &["copilot"],
        "grok" => &["grok"],
        "muse" => &["muse", "muse-acp"],
        "antigravity" => &["agy", "agy_acp_server.par"],
        _ => return None,
    };
    // Windows names them `gemini.exe`, `opencode.cmd` (an npm shim).
    let program = [".exe", ".cmd", ".bat"]
        .iter()
        .find_map(|suffix| program.strip_suffix(suffix))
        .unwrap_or(program);
    if !names.contains(&program) {
        return None;
    }
    let var = |key: &str| env.get(key).is_some_and(|v| !v.trim().is_empty());
    let set =
        |keys: &[&str]| keys.iter().find(|k| var(k)).map(|k| signed_in(format!("{k} is set")));
    let home =
        env.get("HOME").filter(|h| !h.is_empty()).map(PathBuf::from).or_else(dirs::home_dir)?;
    let dir = |key: &str, fallback: PathBuf| {
        env.get(key).filter(|v| !v.is_empty()).map(PathBuf::from).unwrap_or(fallback)
    };
    match family {
        "gemini" => set(&["GEMINI_API_KEY", "GOOGLE_API_KEY"]).or_else(|| {
            let folder = dir("GEMINI_CLI_HOME", home.clone()).join(".gemini");
            ["oauth_creds.json", "gemini-credentials.json"]
                .iter()
                .map(|name| folder.join(name))
                .find(|file| non_empty(file))
                .map(holds)
        }),
        "opencode" => set(&["OPENCODE_AUTH_CONTENT"]).or_else(|| {
            let file = dir("XDG_DATA_HOME", home.join(".local/share")).join("opencode/auth.json");
            providers(&file)
        }),
        "pi" => providers(&dir("PI_CODING_AGENT_DIR", home.join(".pi/agent")).join("auth.json")),
        "cursor" => set(&["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"]).or_else(|| {
            [
                dir("XDG_CONFIG_HOME", home.join(".config")).join("cursor/auth.json"),
                home.join(".cursor/auth.json"),
            ]
            .into_iter()
            .find(|file| non_empty(file))
            .map(holds)
        }),
        "copilot" => set(&["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"]).or_else(|| {
            let file = dir("COPILOT_HOME", home.join(".copilot")).join("config.json");
            let config = read_json(&file)?;
            let user = config.get("lastLoggedInUser").is_some_and(|u| u.is_object())
                || config
                    .get("loggedInUsers")
                    .and_then(Value::as_array)
                    .is_some_and(|users| !users.is_empty());
            user.then(|| signed_in(format!("{} names a signed-in user", file.display())))
        }),
        "grok" => set(&["GROK_API_KEY", "XAI_API_KEY"]).or_else(|| {
            let session = dir("GROK_HOME", home.join(".grok")).join("auth.json");
            if non_empty(&session) {
                return Some(holds(session));
            }
            let file = home.join(".grok/user-settings.json");
            let key = read_json(&file)?
                .get("apiKey")
                .and_then(Value::as_str)
                .is_some_and(|k| !k.trim().is_empty());
            key.then(|| signed_in(format!("{} holds an API key", file.display())))
        }),
        "antigravity" => set(&["GEMINI_API_KEY"]).or_else(|| {
            [
                dir("GEMINI_HOME", home.join(".gemini")).join("antigravity-acp/acp_token.json"),
                home.join(".gemini/antigravity-cli/antigravity-oauth-token"),
            ]
            .into_iter()
            .find(|file| non_empty(file))
            .map(holds)
        }),
        _ => set(&["META_API_KEY"]),
    }
}

fn signed_in(detail: String) -> (Auth, Option<String>) {
    (Auth::SignedIn, Some(detail))
}

fn holds(file: PathBuf) -> (Auth, Option<String>) {
    signed_in(format!("{} holds a sign-in", file.display()))
}

fn non_empty(file: &Path) -> bool {
    std::fs::metadata(file).is_ok_and(|m| m.is_file() && m.len() > 2)
}

/// The most of a login file read: these are a few hundred bytes.
const JSON_CAP: u64 = 256 * 1024;

fn read_json(file: &Path) -> Option<Value> {
    let meta = std::fs::metadata(file).ok()?;
    if !meta.is_file() || meta.len() > JSON_CAP {
        return None;
    }
    // Copilot's config is JSONC; its comments are whole lines.
    let text = std::fs::read_to_string(file).ok()?;
    let body: String = text
        .lines()
        .filter(|line| !line.trim_start().starts_with("//"))
        .collect::<Vec<_>>()
        .join("\n");
    serde_json::from_str(&body).ok()
}

/// A login file keyed by provider id (OpenCode, Pi): signed in with at
/// least one provider entry. Only the keys are counted.
fn providers(file: &Path) -> Option<(Auth, Option<String>)> {
    let count = read_json(file)?.as_object()?.values().filter(|v| v.is_object()).count();
    (count > 0).then(|| {
        let what = if count == 1 { "1 provider".to_owned() } else { format!("{count} providers") };
        signed_in(format!("{} signs in {what}", file.display()))
    })
}

#[cfg(test)]
mod tests;
