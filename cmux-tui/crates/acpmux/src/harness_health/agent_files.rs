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
            ("antigravity", "agy_acp_server.par"),
            ("antigravity", "agy"),
            ("deepseek", "dsh"),
            ("prime", "prime-agent"),
            ("hermes", "hermes"),
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
            ("grok", "grok", "XAI_API_KEY"),
            ("muse", "muse-acp", "META_API_KEY"),
            ("antigravity", "agy_acp_server.par", "GEMINI_API_KEY"),
            ("opencode", "opencode", "OPENCODE_AUTH_CONTENT"),
            ("deepseek", "dsh", "DEEPSEEK_API_KEY"),
            ("prime", "prime-agent", "PRIME_API_KEY"),
            ("hermes", "hermes", "OPENROUTER_API_KEY"),
            ("hermes", "hermes", "ANTHROPIC_TOKEN"),
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
    fn a_grok_login_session_is_a_sign_in() {
        let dir = home("grok-login");
        let env = env(&dir, &[]);
        write(&dir.join(".grok/auth.json"), "{}");
        assert_eq!(auth("grok", "grok", &env), None, "an empty file proves nothing");
        write(&dir.join(".grok/auth.json"), r#"{"access_token":"x","refresh_token":"y"}"#);
        let (auth, detail) = file_auth("grok", "grok", &env).unwrap();
        assert_eq!(auth, Auth::SignedIn);
        assert!(detail.unwrap().ends_with(".grok/auth.json holds a sign-in"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn antigravity_token_files_prove_a_sign_in() {
        let dir = home("antigravity");
        let acp = env(&dir, &[]);
        write(&dir.join(".gemini/antigravity-acp/acp_token.json"), r#"{"refresh_token":"x"}"#);
        assert_eq!(auth("antigravity", "agy_acp_server.par", &acp), Some(Auth::SignedIn));
        let _ = std::fs::remove_dir_all(&dir);
        let dir = home("agy-cli");
        let cli = env(&dir, &[]);
        write(&dir.join(".gemini/antigravity-cli/antigravity-oauth-token"), "ya29.token");
        assert_eq!(auth("antigravity", "agy", &cli), Some(Auth::SignedIn));
        assert_eq!(auth("antigravity", "agy-wrapper", &cli), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn folder_variables_move_the_login_files() {
        let dir = home("vars");
        let elsewhere = dir.join("elsewhere");
        write(&elsewhere.join(".gemini/oauth_creds.json"), r#"{"refresh_token":"x"}"#);
        write(&elsewhere.join("auth.json"), r#"{"anthropic":{"type":"oauth"}}"#);
        write(&elsewhere.join("antigravity-acp/acp_token.json"), r#"{"refresh_token":"x"}"#);
        write(&elsewhere.join(".env"), "DEEPSEEK_API_KEY=k\nANTHROPIC_API_KEY=k\n");
        let moved = elsewhere.display().to_string();
        assert_eq!(auth("deepseek", "dsh", &env(&dir, &[])), None);
        assert_eq!(
            auth("deepseek", "dsh", &env(&dir, &[("DSH_HOME", &moved)])),
            Some(Auth::SignedIn)
        );
        assert_eq!(
            auth("prime", "prime-agent", &env(&dir, &[("PRIME_AGENT_CODING_AGENT_DIR", &moved)])),
            Some(Auth::SignedIn)
        );
        assert_eq!(auth("hermes", "hermes", &env(&dir, &[])), None);
        assert_eq!(
            auth("hermes", "hermes", &env(&dir, &[("HERMES_HOME", &moved)])),
            Some(Auth::SignedIn)
        );
        assert_eq!(
            auth("hermes", "hermes", &env(&dir, &[("HERMES_HOME", "relative/home")])),
            None,
            "a relative home resolves from Hermes's own folder"
        );
        assert_eq!(auth("gemini", "gemini", &env(&dir, &[])), None);
        assert_eq!(
            auth("gemini", "gemini", &env(&dir, &[("GEMINI_CLI_HOME", &moved)])),
            Some(Auth::SignedIn)
        );
        assert_eq!(
            auth("pi", "pi-acp", &env(&dir, &[("PI_CODING_AGENT_DIR", &moved)])),
            Some(Auth::SignedIn)
        );
        assert_eq!(
            auth("grok", "grok", &env(&dir, &[("GROK_HOME", &moved)])),
            Some(Auth::SignedIn)
        );
        assert_eq!(
            auth("antigravity", "agy_acp_server.par", &env(&dir, &[("GEMINI_HOME", &moved)])),
            Some(Auth::SignedIn)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_home_env_file_key_is_a_sign_in() {
        let dir = home("dotenv");
        let env = env(&dir, &[]);
        write(&dir.join(".dsh/.env"), "# DEEPSEEK_API_KEY=sk-commented\nDEEPSEEK_API_KEY=\"\"\n");
        assert_eq!(auth("deepseek", "dsh", &env), None, "a comment or an empty value is no key");
        write(&dir.join(".dsh/.env"), "OTHER=1\nexport DEEPSEEK_API_KEY='sk-secret-value'\n");
        let (auth_found, detail) = file_auth("deepseek", "dsh", &env).unwrap();
        assert_eq!(auth_found, Auth::SignedIn);
        let detail = detail.unwrap();
        assert!(detail.ends_with(".dsh/.env sets DEEPSEEK_API_KEY"), "{detail}");
        assert!(!detail.contains("sk-secret"));
        write(&dir.join(".hermes/.env"), "OPENAI_BASE_URL=http://localhost:8000/v1\n");
        assert_eq!(auth("hermes", "hermes", &env), Some(Auth::SignedIn));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn prime_counts_only_model_providers() {
        let dir = home("prime");
        let env = env(&dir, &[]);
        let file = dir.join(".prime/agent/auth.json");
        write(&file, r#"{"serper":{"type":"api_key"},"mcp:linear":{"type":"oauth"}}"#);
        assert_eq!(auth("prime", "prime-agent", &env), None, "web search and MCP are no sign-in");
        write(&file, r#"{"serper":{"type":"api_key"},"prime-inference":{"type":"api_key"}}"#);
        let (_, detail) = file_auth("prime", "prime-agent", &env).unwrap();
        assert!(detail.unwrap().ends_with("signs in 1 provider"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn hermes_signs_in_by_its_active_provider() {
        let dir = home("hermes");
        let env = env(&dir, &[]);
        let file = dir.join(".hermes/auth.json");
        write(&file, r#"{"version":1,"providers":{},"active_provider":"nous"}"#);
        assert_eq!(auth("hermes", "hermes", &env), None, "an active provider with no entry");
        write(
            &file,
            r#"{"version":1,"providers":{"nous":{"access_token":"x"}},"active_provider":null}"#,
        );
        assert_eq!(auth("hermes", "hermes", &env), None, "an entry nothing selects");
        write(
            &file,
            r#"{"version":1,"providers":{"nous":{"access_token":"x"}},"active_provider":"nous"}"#,
        );
        assert_eq!(auth("hermes", "hermes", &env), Some(Auth::SignedIn));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_wrapper_or_another_family_gets_no_answer() {
        let dir = home("wrapper");
        let gemini = env(&dir, &[("GEMINI_API_KEY", "k")]);
        assert_eq!(auth("gemini", "ssh", &gemini), None);
        assert_eq!(auth("gemini", "my-gemini-wrapper", &gemini), None);
        let cursor = env(&dir, &[("CURSOR_API_KEY", "k")]);
        assert_eq!(auth("cursor", "agent-wrapper", &cursor), None);
        assert_eq!(auth("cursor", "agent", &cursor), Some(Auth::SignedIn));
        assert_eq!(auth("cursor", "cursor-agent.exe", &cursor), Some(Auth::SignedIn));
        assert_eq!(auth("gemini", "gemini.cmd", &gemini), Some(Auth::SignedIn));
        assert_eq!(auth("gemini", "gemini-wrapper.exe", &gemini), None);
        assert_eq!(auth("aider", "aider", &gemini), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
