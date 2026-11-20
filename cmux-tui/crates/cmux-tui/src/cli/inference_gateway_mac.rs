//! `cmux inference gateway --personal --mac-logins --supervised`: the person's own Mac as their
//! gateway, started and kept running by the cmux app (CmuxNextCloud `PersonalGateway`), answering
//! their Cloud machines' model calls from the logins already on the Mac. Nothing to set up.
//!
//! The Mac's local CodeRouter (`cmux-coderouter`) cannot be the upstream: it forwards only to the
//! hosted cmux router with the cmux sign-in or the free-tier token, and answers `/v1/responses`
//! with 501. So the gateway reads the agents' own logins:
//!
//! - Claude (`/v1/messages`, `/v1/messages/count_tokens`): Claude Code's sign-in, BORROWED. Its
//!   access token is read from `<CLAUDE_CONFIG_DIR or ~/.claude>/.credentials.json`, else (macOS)
//!   the keychain item Claude Code keeps, and read again when it nears its expiry or the provider
//!   answers 401. The gateway never refreshes it: Claude Code rotates its refresh token, and a
//!   second refresher would race the person's own Claude Code (`refresh_token_reused`, which
//!   signs one of them out). An expired borrow fails the call with `inference.gateway_login`.
//! - Codex (`/v1/responses`, `/v1/responses/compact`, `/v1/models`): `<CODEX_HOME or ~/.codex>/auth.json`,
//!   the one file the Codex CLI itself holds, through the gateway's `--codex-auth` path: it reads
//!   the file again before any refresh and takes a newer login another holder wrote, and writes a
//!   rotated token back to that same file. No token is copied to a second holder.
//!
//! `--supervised` (the app's child): one JSON line per state change on stdout (`online`,
//! `offline` with a reason, `stopped` with a reason), and the process exits when its stdin closes,
//! so the app's quit (or crash) ends it. `--enable-once FILE` turns the person's own gateway mode
//! on the first time only (FILE records that it did), so a person who turns it off later stays off.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::Mutex;

use super::inference_gateway::TokenSource;
use super::inference_gateway_admin::{Common, Verb};

/// The provider's API origin for a borrowed Claude Code login.
pub(super) const CLAUDE_BACKEND: &str = "https://api.anthropic.com";
/// The beta a Claude Code OAuth access token needs on the Messages API.
const CLAUDE_OAUTH_BETA: &str = "oauth-2025-04-20";
/// A borrowed token this close to its expiry (ms) is read again before a call.
const BORROW_SKEW_MS: u64 = 60_000;
/// The keychain item Claude Code keeps its sign-in in (macOS).
const CLAUDE_KEYCHAIN_SERVICE: &str = "Claude Code-credentials";

type CallError = (&'static str, String);

/// Where the Mac's logins are: Claude Code's home and the Codex login file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct MacLogins {
    pub claude_home: PathBuf,
    pub codex_auth: PathBuf,
    /// Read the macOS keychain item too (off in tests and off macOS).
    pub keychain: bool,
    /// The Messages API origin (a test's fake; else [`CLAUDE_BACKEND`]).
    pub claude_base: String,
}

impl MacLogins {
    /// The default places, the way Claude Code and the Codex CLI find them.
    pub(super) fn from_env(env: &dyn Fn(&str) -> Option<String>) -> Result<Self, String> {
        let home = env("HOME").map(PathBuf::from);
        let claude_home = env("CLAUDE_CONFIG_DIR")
            .map(PathBuf::from)
            .or_else(|| home.as_ref().map(|h| h.join(".claude")))
            .ok_or("no home directory to find the agents' logins in")?;
        let codex_auth = env("CODEX_HOME")
            .map(PathBuf::from)
            .or_else(|| home.as_ref().map(|h| h.join(".codex")))
            .ok_or("no home directory to find the agents' logins in")?
            .join("auth.json");
        Ok(Self {
            claude_home,
            codex_auth,
            keychain: cfg!(target_os = "macos"),
            claude_base: CLAUDE_BACKEND.to_owned(),
        })
    }
}

/// Which login answers a call's path.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Login {
    Claude(String),
    Codex,
}

/// The login for a path: a Messages path goes to Claude (with its URL), a Responses path to Codex,
/// anything else is not served (the Worker refuses other paths already; checked again here).
pub(super) fn login_for(base: &str, path: &str) -> Option<Login> {
    let route = path.split_once('?').map_or(path, |(route, _)| route);
    match route {
        "/v1/messages" | "/v1/messages/count_tokens" => {
            Some(Login::Claude(format!("{base}{path}")))
        }
        "/v1/responses" | "/v1/responses/compact" | "/v1/models" => Some(Login::Codex),
        _ => None,
    }
}

/// The `anthropic-beta` value a borrowed OAuth call sends: the caller's betas plus the OAuth one, once.
pub(super) fn oauth_beta(headers: &[(String, String)]) -> String {
    let mut betas: Vec<String> = headers
        .iter()
        .filter(|(k, _)| k == "anthropic-beta")
        .flat_map(|(_, v)| v.split(','))
        .map(|b| b.trim().to_owned())
        .filter(|b| !b.is_empty())
        .collect();
    if !betas.iter().any(|b| b == CLAUDE_OAUTH_BETA) {
        betas.push(CLAUDE_OAUTH_BETA.to_owned());
    }
    betas.join(",")
}

/// A Claude Code credentials document (`.credentials.json` or the keychain item's password):
/// its OAuth access token and expiry (unix ms, when it names one).
pub(super) fn parse_claude_credentials(text: &str) -> Result<(String, Option<u64>), String> {
    let doc: Value =
        serde_json::from_str(text).map_err(|_| "the Claude sign-in is not JSON".to_owned())?;
    let token = doc
        .pointer("/claudeAiOauth/accessToken")
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty() && !t.contains(char::is_whitespace))
        .ok_or("the Claude sign-in has no access token")?;
    Ok((token.to_owned(), doc.pointer("/claudeAiOauth/expiresAt").and_then(Value::as_u64)))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

const NO_CLAUDE: &str =
    "the Mac has no agent sign-in for this model; sign in to the agent on your Mac";
const CLAUDE_EXPIRED: &str = "the agent's sign-in on your Mac expired; use the agent on your Mac once so it renews its sign-in";

/// Claude Code's sign-in, borrowed: read, never refreshed (module doc).
pub(super) struct ClaudeBorrow {
    logins: MacLogins,
    cached: Mutex<Option<(String, Option<u64>)>>,
}

impl ClaudeBorrow {
    pub(super) fn new(logins: MacLogins) -> Self {
        Self { logins, cached: Mutex::new(None) }
    }

    /// Whether a sign-in is there now (for the start's one log line; never fails the start).
    pub(super) async fn present(&self) -> bool {
        !self.read_all().await.is_empty()
    }

    /// The access token for a call: the cached one while it is fresh, else read again. `stale` is
    /// the token a 401 refused: a read that finds only that one again fails the call.
    pub(super) async fn token(&self, stale: Option<&str>) -> Result<String, CallError> {
        let mut slot = self.cached.lock().await;
        let fresh =
            |(_, exp): &(String, Option<u64>)| exp.is_none_or(|ms| ms > now_ms() + BORROW_SKEW_MS);
        if stale.is_none()
            && let Some(cached) = slot.as_ref().filter(|&c| fresh(c))
        {
            return Ok(cached.0.clone());
        }
        // Read again from here on: a refused or stale token is never served from the cache.
        *slot = None;
        let found = self.read(stale).await.map_err(|e| ("inference.gateway_login", e))?;
        if !fresh(&found) {
            return Err(("inference.gateway_login", CLAUDE_EXPIRED.into()));
        }
        *slot = Some(found.clone());
        Ok(found.0)
    }

    /// Every sign-in Claude Code keeps here: its credentials file and (macOS) its keychain item. Claude
    /// Code on macOS keeps its live sign-in in the keychain, so a leftover file must not hide it.
    async fn read_all(&self) -> Vec<(String, Option<u64>)> {
        let mut found = Vec::new();
        let file = self.logins.claude_home.join(".credentials.json");
        if let Ok(text) = tokio::fs::read_to_string(&file).await
            && let Ok(login) = parse_claude_credentials(&text)
        {
            found.push(login);
        }
        if self.logins.keychain
            // The item Claude Code writes through /usr/bin/security; bounded, so a keychain that asks
            // to unlock never holds a call. The password is the credentials document; it never
            // leaves this process.
            && let Ok(text) = super::inference_gateway::command_output_within(
                "/usr/bin/security",
                &["find-generic-password", "-s", CLAUDE_KEYCHAIN_SERVICE, "-w"],
                Duration::from_secs(5),
            )
            .await
            && let Ok(login) = parse_claude_credentials(text.trim())
        {
            found.push(login);
        }
        found
    }

    /// The best sign-in now: one not `stale`, the latest expiry first (no expiry counts as latest).
    async fn read(&self, stale: Option<&str>) -> Result<(String, Option<u64>), String> {
        let found = self.read_all().await;
        if found.is_empty() {
            return Err(NO_CLAUDE.into());
        }
        best(found, stale).ok_or_else(|| CLAUDE_EXPIRED.into())
    }
}

/// The sign-in to use among `found`: never the refused `stale` one, else the latest expiry.
pub(super) fn best(
    found: Vec<(String, Option<u64>)>,
    stale: Option<&str>,
) -> Option<(String, Option<u64>)> {
    found
        .into_iter()
        .filter(|(token, _)| stale != Some(token.as_str()))
        .max_by_key(|(_, exp)| exp.unwrap_or(u64::MAX))
}

/// One `--supervised` state line on stdout (`{"event": "online"}`); the app reads nothing else there.
pub(super) fn event(kind: &str, reason: Option<&str>) {
    use std::io::Write as _;
    let line = match reason {
        Some(reason) => json!({"event": kind, "reason": reason}),
        None => json!({"event": kind}),
    };
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

/// `--supervised`: resolves when stdin closes (the app quit or crashed), which ends the gateway.
pub(super) async fn stdin_closed() {
    use tokio::io::AsyncReadExt as _;
    let mut stdin = tokio::io::stdin();
    let mut sink = [0u8; 256];
    while let Ok(n) = stdin.read(&mut sink).await {
        if n == 0 {
            return;
        }
    }
}

/// `--enable-once FILE`: turns the person's own gateway mode on unless FILE says it already did.
/// A refused PUT (an older backend, a token without the grant) is logged and tried again at the
/// next start; the gateway serves either way.
pub(super) async fn enable_once(
    api: &str,
    token: &TokenSource,
    marker: &Path,
) -> Result<bool, String> {
    if tokio::fs::try_exists(marker).await.unwrap_or(false) {
        return Ok(false);
    }
    let common = Common { api: api.to_owned(), team: None, token: token.clone() };
    let verb = Verb::Mode { personal: true, mode: "gateway".into(), machine: None };
    let (answer, code) = super::inference_gateway_admin::run(&common, &verb).await;
    if code != 0 {
        let reason = answer.pointer("/error/code").and_then(Value::as_str).unwrap_or("refused");
        return Err(format!("could not turn your own gateway on ({reason})"));
    }
    if let Some(dir) = marker.parent() {
        tokio::fs::create_dir_all(dir).await.map_err(|e| e.to_string())?;
    }
    tokio::fs::write(marker, b"on\n").await.map_err(|e| e.to_string())?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn logins(dir: &Path) -> MacLogins {
        MacLogins {
            claude_home: dir.to_owned(),
            codex_auth: dir.join("auth.json"),
            keychain: false,
            claude_base: "http://127.0.0.1:1".into(),
        }
    }

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cmux-gw-mac-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn routes_messages_to_claude_and_responses_to_codex() {
        let base = "https://api.anthropic.com";
        assert_eq!(
            login_for(base, "/v1/messages"),
            Some(Login::Claude("https://api.anthropic.com/v1/messages".into()))
        );
        assert_eq!(
            login_for(base, "/v1/messages/count_tokens?beta=true"),
            Some(Login::Claude(
                "https://api.anthropic.com/v1/messages/count_tokens?beta=true".into()
            ))
        );
        assert_eq!(login_for(base, "/v1/responses"), Some(Login::Codex));
        assert_eq!(login_for(base, "/v1/models?client_version=1"), Some(Login::Codex));
        assert_eq!(login_for(base, "/v1/chat/completions"), None);
        assert_eq!(login_for(base, "@evil.example/v1/messages"), None);
    }

    #[test]
    fn the_oauth_beta_joins_the_callers_betas_once() {
        let h = |v: &str| vec![("anthropic-beta".to_owned(), v.to_owned())];
        assert_eq!(oauth_beta(&[]), "oauth-2025-04-20");
        assert_eq!(oauth_beta(&h("a, b")), "a,b,oauth-2025-04-20");
        assert_eq!(oauth_beta(&h("oauth-2025-04-20,a")), "oauth-2025-04-20,a");
    }

    #[test]
    fn the_default_places_follow_the_agents_own_variables() {
        let env = |k: &str| match k {
            "HOME" => Some("/Users/p".to_owned()),
            "CODEX_HOME" => Some("/Users/p/cx".to_owned()),
            _ => None,
        };
        let found = MacLogins::from_env(&env).unwrap();
        assert_eq!(found.claude_home, PathBuf::from("/Users/p/.claude"));
        assert_eq!(found.codex_auth, PathBuf::from("/Users/p/cx/auth.json"));
        assert_eq!(found.claude_base, CLAUDE_BACKEND);
    }

    #[tokio::test]
    async fn a_borrowed_claude_token_is_read_again_and_never_refreshed() {
        let dir = temp("borrow");
        let write = |token: &str, exp: u64| {
            std::fs::write(
                dir.join(".credentials.json"),
                json!({"claudeAiOauth": {"accessToken": token, "refreshToken": "r", "expiresAt": exp}})
                    .to_string(),
            )
            .unwrap();
        };
        let borrow = ClaudeBorrow::new(logins(&dir));
        write("t1", now_ms() + 3_600_000);
        assert_eq!(borrow.token(None).await.unwrap(), "t1");
        // Claude Code refreshed the file: a 401 on t1 reads again and takes t2.
        write("t2", now_ms() + 3_600_000);
        assert_eq!(borrow.token(None).await.unwrap(), "t1", "a fresh cached token is reused");
        assert_eq!(borrow.token(Some("t1")).await.unwrap(), "t2");
        // A 401 on the only token there is fails the call: nothing here refreshes it.
        let refused = borrow.token(Some("t2")).await.unwrap_err();
        assert_eq!(refused.0, "inference.gateway_login");
        // Expired on disk: the call fails with the login code, and the file is left as it was.
        write("t3", now_ms().saturating_sub(1));
        let expired = borrow.token(None).await.unwrap_err();
        assert_eq!(expired.0, "inference.gateway_login");
        let left = std::fs::read_to_string(dir.join(".credentials.json")).unwrap();
        assert!(left.contains("\"refreshToken\":\"r\"") && left.contains("t3"), "{left}");
    }

    #[tokio::test]
    async fn no_claude_sign_in_is_a_login_error_not_a_crash() {
        let dir = temp("none");
        let borrow = ClaudeBorrow::new(logins(&dir));
        assert!(!borrow.present().await);
        assert_eq!(borrow.token(None).await.unwrap_err().0, "inference.gateway_login");
    }

    #[test]
    fn the_freshest_sign_in_wins_and_a_refused_one_never_does() {
        let file = ("old".to_owned(), Some(1_000));
        let keychain = ("live".to_owned(), Some(9_000));
        assert_eq!(best(vec![file.clone(), keychain.clone()], None), Some(keychain.clone()));
        assert_eq!(best(vec![keychain.clone(), file.clone()], Some("live")), Some(file));
        assert_eq!(best(vec![keychain], Some("live")), None);
    }

    #[test]
    fn parses_the_credentials_document() {
        let (t, exp) = parse_claude_credentials(
            r#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","expiresAt":1700000000000}}"#,
        )
        .unwrap();
        assert_eq!((t.as_str(), exp), ("sk-ant-oat01-x", Some(1_700_000_000_000)));
        assert!(parse_claude_credentials(r#"{"claudeAiOauth":{}}"#).is_err());
        assert!(parse_claude_credentials("not json").is_err());
    }

    #[tokio::test]
    async fn enable_once_does_nothing_when_its_marker_is_there() {
        let dir = temp("once");
        let marker = dir.join("personal-mode-on");
        std::fs::write(&marker, "on\n").unwrap();
        // No API call is made: the API origin is unroutable and the token source fails if read.
        let token = TokenSource::File(dir.join("missing-token"));
        assert_eq!(enable_once("https://127.0.0.1:1", &token, &marker).await, Ok(false));
    }
}
