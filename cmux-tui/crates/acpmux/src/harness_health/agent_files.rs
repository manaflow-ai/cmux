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
//! - DeepSeek Harness (`dsh`): `DEEPSEEK_API_KEY`, set or assigned in
//!   `<DSH_HOME or ~/.dsh>/.env`, the Harness-home layer `dsh` loads at boot
//!   (deepseek-ai/deepseek-harness `packages/boot/app-boot` `loadLayeredEnv`,
//!   `packages/util/home-paths` `resolveDshHome`). A project `.env` also
//!   counts there; it depends on the chat's folder, so it is not read here.
//! - Prime Agent: `PRIME_API_KEY` (Prime Inference); else
//!   `<PRIME_AGENT_CODING_AGENT_DIR or ~/.prime/agent>/auth.json`, one entry
//!   per provider; the web-search (`serper`, `eco`) and `mcp:*` entries are
//!   not a model sign-in (prime-agent `pa-types/src/platform/dirs.rs`,
//!   `pa-core/src/auth/types.rs`, `pa-ai/src/env_api_keys.rs`).
//! - Hermes Agent: the provider keys its own setup check counts
//!   (`OPENROUTER_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
//!   `ANTHROPIC_TOKEN`, `OPENAI_BASE_URL`), set or assigned in
//!   `<HERMES_HOME or ~/.hermes>/.env`; else the active provider's entry in
//!   that home's `auth.json` (hermes-agent `hermes_cli/main.py`
//!   `_has_any_provider_configured`, `hermes_constants.py`). A relative
//!   `HERMES_HOME` gets no answer, as Hermes resolves it from its own folder.

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
        "deepseek" => &["dsh"],
        "prime" => &["prime-agent"],
        "hermes" => &["hermes"],
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
        "deepseek" => set(&["DEEPSEEK_API_KEY"]).or_else(|| {
            dotenv_sets(&dir("DSH_HOME", home.join(".dsh")).join(".env"), &["DEEPSEEK_API_KEY"])
        }),
        "prime" => set(&["PRIME_API_KEY"]).or_else(|| {
            let file =
                dir("PRIME_AGENT_CODING_AGENT_DIR", home.join(".prime/agent")).join("auth.json");
            // Web search and MCP servers keep their keys in the same file.
            providers_where(&file, |id| !matches!(id, "serper" | "eco") && !id.starts_with("mcp:"))
        }),
        "hermes" => {
            const KEYS: &[&str] = &[
                "OPENROUTER_API_KEY",
                "OPENAI_API_KEY",
                "ANTHROPIC_API_KEY",
                "ANTHROPIC_TOKEN",
                "OPENAI_BASE_URL",
            ];
            set(KEYS).or_else(|| {
                let suffix = env.get("HERMES_DATA_DIR_SUFFIX").map(String::as_str).unwrap_or("");
                let folder =
                    match env.get("HERMES_HOME").map(|v| v.trim()).filter(|v| !v.is_empty()) {
                        Some(named) => Some(PathBuf::from(named)).filter(|p| p.is_absolute())?,
                        None => home.join(format!(".hermes{suffix}")),
                    };
                dotenv_sets(&folder.join(".env"), KEYS).or_else(|| {
                    let file = folder.join("auth.json");
                    let store = read_json(&file)?;
                    let active = store.get("active_provider").and_then(Value::as_str)?.trim();
                    let entry = store.get("providers")?.get(active).is_some_and(Value::is_object);
                    (!active.is_empty() && entry).then(|| {
                        signed_in(format!("{} signs in its active provider", file.display()))
                    })
                })
            })
        }
        _ => set(&["META_API_KEY"]),
    }
}

/// A `.env` file that assigns one of `keys` a value (`KEY=v`, `export KEY="v"`;
/// `#` lines skipped), as `dsh` and Hermes read theirs. Only the name is kept.
fn dotenv_sets(file: &Path, keys: &[&str]) -> Option<(Auth, Option<String>)> {
    let meta = std::fs::metadata(file).ok()?;
    if !meta.is_file() || meta.len() > JSON_CAP {
        return None;
    }
    let text = std::fs::read_to_string(file).ok()?;
    let key = text.lines().find_map(|line| {
        let line = line.trim();
        let line = line.strip_prefix("export ").unwrap_or(line);
        let (key, value) = line.split_once('=').filter(|_| !line.starts_with('#'))?;
        let value = value.trim().trim_matches(|c| c == '\'' || c == '"');
        keys.iter().find(|k| **k == key.trim() && !value.is_empty())
    })?;
    Some(signed_in(format!("{} sets {key}", file.display())))
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
    providers_where(file, |_| true)
}

/// `providers`, counting only the entries whose id `counts`.
fn providers_where(file: &Path, counts: impl Fn(&str) -> bool) -> Option<(Auth, Option<String>)> {
    let count =
        read_json(file)?.as_object()?.iter().filter(|(id, v)| v.is_object() && counts(id)).count();
    (count > 0).then(|| {
        let what = if count == 1 { "1 provider".to_owned() } else { format!("{count} providers") };
        signed_in(format!("{} signs in {what}", file.display()))
    })
}

#[cfg(test)]
#[path = "agent_files_tests.rs"]
mod tests;
