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
//! - Grok CLI: `GROK_API_KEY`, else `~/.grok/user-settings.json` `apiKey`.
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
    // Only for the agent itself, not a wrapper that runs it elsewhere.
    let names: &[&str] = match family {
        "gemini" => &["gemini"],
        "opencode" => &["opencode"],
        "pi" => &["pi"],
        "cursor" => &["cursor", "agent"],
        "copilot" => &["copilot"],
        "grok" => &["grok"],
        "muse" => &["muse"],
        _ => return None,
    };
    if !names.iter().any(|name| program.contains(name)) {
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
        "grok" => set(&["GROK_API_KEY"]).or_else(|| {
            let file = home.join(".grok/user-settings.json");
            let key = read_json(&file)?
                .get("apiKey")
                .and_then(Value::as_str)
                .is_some_and(|k| !k.trim().is_empty());
            key.then(|| signed_in(format!("{} holds an API key", file.display())))
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
mod tests {
    use super::*;

    fn home(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("acpmux-agent-files-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn env(home: &Path, extra: &[(&str, &str)]) -> BTreeMap<String, String> {
        let mut env = BTreeMap::from([("HOME".to_owned(), home.display().to_string())]);
        env.extend(extra.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())));
        env
    }

    fn write(path: &Path, body: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, body).unwrap();
    }

    fn auth(family: &str, program: &str, env: &BTreeMap<String, String>) -> Option<Auth> {
        file_auth(family, program, env).map(|(auth, _)| auth)
    }

    #[test]
    fn nothing_found_is_unknown_not_signed_out() {
        let dir = home("none");
        let env = env(&dir, &[]);
        for (family, program) in [
            ("gemini", "gemini"),
            ("opencode", "opencode"),
            ("pi", "pi-acp"),
            ("cursor", "cursor-agent"),
            ("copilot", "copilot"),
            ("grok", "grok"),
            ("muse", "muse-acp"),
        ] {
            assert_eq!(auth(family, program, &env), None, "{family}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_key_in_the_environment_is_a_sign_in_and_its_value_is_never_answered() {
        let dir = home("env");
        for (family, program, key) in [
            ("gemini", "gemini", "GEMINI_API_KEY"),
            ("cursor", "cursor-agent", "CURSOR_API_KEY"),
            ("copilot", "copilot", "COPILOT_GITHUB_TOKEN"),
            ("grok", "grok", "GROK_API_KEY"),
            ("muse", "muse-acp", "META_API_KEY"),
            ("opencode", "opencode", "OPENCODE_AUTH_CONTENT"),
        ] {
            let found = file_auth(family, program, &env(&dir, &[(key, "sk-secret-value")]));
            let (auth, detail) = found.unwrap_or_else(|| panic!("{family}"));
            assert_eq!(auth, Auth::SignedIn, "{family}");
            assert!(!detail.unwrap_or_default().contains("sk-secret"), "{family}");
        }
        assert_eq!(auth("muse", "muse-acp", &env(&dir, &[("META_API_KEY", "  ")])), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn login_files_prove_a_sign_in() {
        let dir = home("files");
        let env = env(&dir, &[]);
        write(&dir.join(".gemini/oauth_creds.json"), r#"{"refresh_token":"x"}"#);
        assert_eq!(auth("gemini", "gemini", &env), Some(Auth::SignedIn));
        write(&dir.join(".local/share/opencode/auth.json"), r#"{"anthropic":{"type":"oauth"}}"#);
        assert_eq!(auth("opencode", "opencode", &env), Some(Auth::SignedIn));
        write(&dir.join(".pi/agent/auth.json"), "{}");
        assert_eq!(auth("pi", "pi-acp", &env), None, "no provider is no sign-in proven");
        write(
            &dir.join(".pi/agent/auth.json"),
            r#"{"anthropic":{"type":"api_key"},"openai":{"type":"oauth"}}"#,
        );
        let (_, detail) = file_auth("pi", "pi-acp", &env).unwrap();
        assert!(detail.unwrap().ends_with("signs in 2 providers"));
        write(&dir.join(".config/cursor/auth.json"), r#"{"accessToken":"x"}"#);
        assert_eq!(auth("cursor", "cursor-agent", &env), Some(Auth::SignedIn));
        write(&dir.join(".copilot/config.json"), "// comment\n{\"loggedInUsers\": []}");
        assert_eq!(auth("copilot", "copilot", &env), None);
        write(
            &dir.join(".copilot/config.json"),
            "// comment\n{\"lastLoggedInUser\": {\"host\": \"https://github.com\", \"login\": \"a\"}}",
        );
        assert_eq!(auth("copilot", "copilot", &env), Some(Auth::SignedIn));
        write(&dir.join(".grok/user-settings.json"), r#"{"apiKey":""}"#);
        assert_eq!(auth("grok", "grok", &env), None);
        write(&dir.join(".grok/user-settings.json"), r#"{"apiKey":"xai-1"}"#);
        assert_eq!(auth("grok", "grok", &env), Some(Auth::SignedIn));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn folder_variables_move_the_login_files() {
        let dir = home("vars");
        let elsewhere = dir.join("elsewhere");
        write(&elsewhere.join(".gemini/oauth_creds.json"), r#"{"refresh_token":"x"}"#);
        write(&elsewhere.join("auth.json"), r#"{"anthropic":{"type":"oauth"}}"#);
        let moved = elsewhere.display().to_string();
        assert_eq!(auth("gemini", "gemini", &env(&dir, &[])), None);
        assert_eq!(
            auth("gemini", "gemini", &env(&dir, &[("GEMINI_CLI_HOME", &moved)])),
            Some(Auth::SignedIn)
        );
        assert_eq!(
            auth("pi", "pi-acp", &env(&dir, &[("PI_CODING_AGENT_DIR", &moved)])),
            Some(Auth::SignedIn)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_wrapper_or_another_family_gets_no_answer() {
        let dir = home("wrapper");
        let env = env(&dir, &[("GEMINI_API_KEY", "k")]);
        assert_eq!(auth("gemini", "ssh", &env), None);
        assert_eq!(auth("aider", "aider", &env), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
