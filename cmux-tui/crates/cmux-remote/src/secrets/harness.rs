//! Harness logins (`claude`, `codex`) installed where the harness reads
//! them, at the paths the app's login copy wrote before `secrets-v1`.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use zeroize::Zeroizing;

/// The largest login the app sends: 12 000 bytes.
pub const MAX_LOGIN_BYTES: usize = 12_000;

/// Keys and endpoints that must never receive a copied subscription login.
const CONFLICTS: &[&str] = &[
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "CLAUDE_CONFIG_DIR",
    "OPENAI_BASE_URL",
    "CODEX_HOME",
    "CODEX_API_KEY",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HarnessLogin {
    Claude,
    Codex,
}

/// Why a login was refused. Carries no value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoginRefusal {
    UnknownHarness,
    InvalidCredential,
    /// The guest has no kind record yet: its bind agent writes
    /// `/etc/cmux/vm-kind` once it binds, which can land after the daemon
    /// starts. Retryable.
    NotReady,
    /// The guest is not an owner guest, or the image has no `agent-auth.sh`.
    NotOwnerGuest,
    /// A custom endpoint or key would receive the login.
    Conflict,
    Write,
}

impl LoginRefusal {
    pub fn code(self) -> &'static str {
        match self {
            Self::UnknownHarness => "bad-name",
            Self::InvalidCredential => "invalid-credential",
            Self::NotReady => "not-ready",
            Self::NotOwnerGuest => "not-owner-guest",
            Self::Conflict => "conflict",
            Self::Write => "write",
        }
    }
}

impl HarnessLogin {
    pub const ALL: [Self; 2] = [Self::Claude, Self::Codex];

    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "claude" => Some(Self::Claude),
            "codex" => Some(Self::Codex),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }

    /// Every file this login writes under `home`.
    pub fn paths(self, home: &Path) -> Vec<PathBuf> {
        let marker = home.join(".config/cmux/agent-auth").join(self.name());
        match self {
            Self::Claude => vec![
                home.join(".claude/settings.json"),
                home.join(".claude/.credentials.json"),
                marker,
            ],
            Self::Codex => vec![home.join(".codex/auth.json"), marker],
        }
    }

    /// The shape the provider's own login has: a Claude OAuth token, or a
    /// Codex `auth.json` with tokens and no API key.
    pub fn validate(self, value: &[u8]) -> Result<(), LoginRefusal> {
        if value.len() > MAX_LOGIN_BYTES {
            return Err(LoginRefusal::InvalidCredential);
        }
        let valid = match self {
            Self::Claude => {
                value.starts_with(b"sk-ant-oat01-")
                    && value.len() >= 32
                    && value.iter().all(|byte| *byte > 32 && *byte < 127)
            }
            Self::Codex => serde_json::from_slice::<serde_json::Value>(value).is_ok_and(|auth| {
                auth.get("OPENAI_API_KEY").is_none_or(serde_json::Value::is_null)
                    && auth.get("tokens").is_some_and(|tokens| {
                        ["access_token", "refresh_token", "id_token"].iter().all(|key| {
                            tokens.get(key).and_then(|v| v.as_str()).is_some_and(|v| !v.is_empty())
                        })
                    })
            }),
        };
        if valid { Ok(()) } else { Err(LoginRefusal::InvalidCredential) }
    }
}

/// The guest's policy, read from its `/etc/cmux` folder: an owner guest,
/// with the image's `agent-auth.sh`,
/// whose launch environment names no conflicting key or endpoint and doesn't
/// pin this harness to the team's login.
pub fn check_guest(etc: &Path, login: HarnessLogin) -> Result<(), LoginRefusal> {
    let kind = std::fs::read_to_string(etc.join("vm-kind")).unwrap_or_default();
    let kind = kind.trim();
    if kind.is_empty() {
        return Err(LoginRefusal::NotReady);
    }
    let agent_auth = etc.join("agent-auth.sh");
    if kind != "owner" || !agent_auth.is_file() {
        return Err(LoginRefusal::NotOwnerGuest);
    }
    // The launcher's own normalization (it drops cmux's model-plane values),
    // then the names only: no value is read into this process.
    let script = r#"set -e
. "$1"
cmux_agent_drop_model_plane_env
shift
auth="$1"
shift
for key in "$@"; do eval "value=\${$key:-}"; [ -z "$value" ] || exit 3; done
eval "value=\${$auth:-}"
[ "$value" != team ] || exit 4"#;
    let status = Command::new("/bin/sh")
        .arg("-c")
        .arg(script)
        .arg("sh")
        .arg(&agent_auth)
        .arg(format!("CMUX_{}_AUTH", login.name().to_ascii_uppercase()))
        .args(CONFLICTS)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|_| LoginRefusal::NotOwnerGuest)?;
    if status.success() { Ok(()) } else { Err(LoginRefusal::Conflict) }
}

/// Write `value` (already validated) where `login`'s harness reads it and
/// mark the harness as using its own login, as one change: every file or
/// none.
pub fn install(home: &Path, login: HarnessLogin, value: &[u8]) -> Result<(), LoginRefusal> {
    let marker = home.join(".config/cmux/agent-auth").join(login.name());
    match login {
        HarnessLogin::Claude => {
            let token = std::str::from_utf8(value).map_err(|_| LoginRefusal::InvalidCredential)?;
            let settings_path = home.join(".claude/settings.json");
            let mut settings = read_json_object(&settings_path)?;
            if settings.contains_key("apiKeyHelper") {
                return Err(LoginRefusal::Conflict);
            }
            let env = settings
                .entry("env")
                .or_insert_with(|| serde_json::Value::Object(serde_json::Map::new()));
            let env = env.as_object_mut().ok_or(LoginRefusal::Conflict)?;
            if CONFLICTS.iter().any(|key| env.get(*key).is_some_and(is_truthy)) {
                return Err(LoginRefusal::Conflict);
            }
            env.insert("CLAUDE_CODE_OAUTH_TOKEN".into(), token.into());
            let settings =
                Zeroizing::new(serde_json::to_vec(&settings).map_err(|_| LoginRefusal::Write)?);
            let credentials = Zeroizing::new(
                serde_json::to_vec(
                    &serde_json::json!({ "claudeAiOauth": { "accessToken": token } }),
                )
                .map_err(|_| LoginRefusal::Write)?,
            );
            let credentials_path = home.join(".claude/.credentials.json");
            write(
                home,
                &[
                    (settings_path.as_path(), settings.as_slice()),
                    (credentials_path.as_path(), credentials.as_slice()),
                    (marker.as_path(), b"own\n".as_slice()),
                ],
            )
        }
        HarnessLogin::Codex => {
            check_codex_config(&home.join(".codex/config.toml"))?;
            let auth: serde_json::Value =
                serde_json::from_slice(value).map_err(|_| LoginRefusal::InvalidCredential)?;
            let auth = Zeroizing::new(serde_json::to_vec(&auth).map_err(|_| LoginRefusal::Write)?);
            let auth_path = home.join(".codex/auth.json");
            write(
                home,
                &[(auth_path.as_path(), auth.as_slice()), (marker.as_path(), b"own\n".as_slice())],
            )
        }
    }
}

/// All of them or none, only to paths [`HarnessLogin::paths`] lists.
fn write(home: &Path, writes: &[(&Path, &[u8])]) -> Result<(), LoginRefusal> {
    super::files::write_all_allowed(home, writes).map_err(|_| LoginRefusal::Write)
}

fn is_truthy(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::Null => false,
        serde_json::Value::Bool(flag) => *flag,
        serde_json::Value::String(text) => !text.is_empty(),
        serde_json::Value::Array(items) => !items.is_empty(),
        serde_json::Value::Object(map) => !map.is_empty(),
        serde_json::Value::Number(_) => true,
    }
}

/// `path` as a JSON object; an empty one when there is no file. A symlink,
/// or a file that isn't a JSON object, is refused (never overwritten).
fn read_json_object(
    path: &Path,
) -> Result<serde_json::Map<String, serde_json::Value>, LoginRefusal> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.file_type().is_file() => return Err(LoginRefusal::Conflict),
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(serde_json::Map::new());
        }
        Err(_) => return Err(LoginRefusal::Write),
    }
    let bytes = Zeroizing::new(std::fs::read(path).map_err(|_| LoginRefusal::Write)?);
    match serde_json::from_slice(&bytes) {
        Ok(serde_json::Value::Object(map)) => Ok(map),
        _ => Err(LoginRefusal::Conflict),
    }
}

/// Codex's own config must keep every way to pick a provider on the OpenAI
/// (or cmux) provider with a file login, or a copied login would go unused or
/// reach another endpoint: the top level and every profile (a launch can pick
/// any with `--profile`) name only `openai` or `cmux` and store logins in a
/// file, no base URL is overridden, and no `model_providers` entry redefines
/// `openai` or asks for the OpenAI login (`requires_openai_auth`).
fn check_codex_config(path: &Path) -> Result<(), LoginRefusal> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.file_type().is_file() => return Err(LoginRefusal::Conflict),
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err(LoginRefusal::Write),
    }
    let text = std::fs::read_to_string(path).map_err(|_| LoginRefusal::Conflict)?;
    let config: toml::Table = text.parse().map_err(|_| LoginRefusal::Conflict)?;
    let profiles = match config.get("profiles") {
        None => toml::Table::new(),
        Some(toml::Value::Table(profiles)) => profiles.clone(),
        Some(_) => return Err(LoginRefusal::Conflict),
    };
    let mut scopes = vec![&config];
    for profile in profiles.values() {
        scopes.push(profile.as_table().ok_or(LoginRefusal::Conflict)?);
    }
    if !scopes.into_iter().all(codex_scope_is_plain) {
        return Err(LoginRefusal::Conflict);
    }
    if let Some(profile) = config.get("profile") {
        let name = profile.as_str().ok_or(LoginRefusal::Conflict)?;
        if !profiles.contains_key(name) {
            return Err(LoginRefusal::Conflict);
        }
    }
    match config.get("model_providers") {
        None => Ok(()),
        Some(toml::Value::Table(providers)) => {
            // The image's own `cmux` provider (agent-config.sh, agent-auth.sh) says
            // `requires_openai_auth = false`: the login never reaches it.
            let plain = providers.iter().all(|(name, provider)| {
                name != "openai"
                    && provider
                        .get("requires_openai_auth")
                        .is_none_or(|value| value.as_bool() == Some(false))
            });
            if plain { Ok(()) } else { Err(LoginRefusal::Conflict) }
        }
        Some(_) => Err(LoginRefusal::Conflict),
    }
}

/// One scope of a Codex config (the top level or a profile) leaves the
/// provider, its endpoint and the login store alone.
fn codex_scope_is_plain(scope: &toml::Table) -> bool {
    let text_is = |key: &str, allowed: &[&str]| {
        scope.get(key).is_none_or(|value| value.as_str().is_some_and(|v| allowed.contains(&v)))
    };
    text_is("model_provider", &["openai", "cmux"])
        && text_is("cli_auth_credentials_store", &["file", "auto"])
        && !scope.contains_key("openai_base_url")
        && !scope.contains_key("chatgpt_base_url")
}
