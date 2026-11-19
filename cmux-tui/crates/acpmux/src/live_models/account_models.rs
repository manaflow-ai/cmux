//! The models a ChatGPT sign-in's Codex backend serves, for a Codex whose config.toml names a
//! model catalog of its own (`model_catalog_json`). Codex then answers `model/list` with that
//! catalog whatever its sign-in, so the picker offered, and a new chat started on, models the
//! ChatGPT Codex backend refuses at the first prompt: HTTP 400 `model_not_found`, "The
//! 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account". Without such a
//! catalog Codex lists the backend's own answer, and nothing here runs.
//!
//! The served list is the backend's answer to `GET {BASE_URL}/models?client_version=...`, the
//! request Codex itself makes for a ChatGPT sign-in, sent with the login's access token
//! (`codex_login_access`: read only, never refreshed, never logged); else Codex's own last copy of
//! that answer (`models_cache.json` in its home). A listed model the account is not served is
//! marked unavailable ([`mark`]): `_acpmux/models` says so, pickers leave it out, and a new chat
//! never starts on it (`hub/start_defaults.rs`).

use super::LiveModel;
use crate::codex_login_access::{ACCOUNT_HEADER, Access, BASE_URL};
use anyhow::{Result, anyhow, bail};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Why a marked model is unavailable (`_acpmux/models` `unavailable`).
pub const UNAVAILABLE: &str = "This model isn't available with this ChatGPT sign-in.";
/// The backend's whole answer, start to end.
const FETCH_TIMEOUT: Duration = Duration::from_secs(5);
/// Codex's copy of the backend's answer, in its home.
const CACHE_FILE: &str = "models_cache.json";
/// The oldest copy of it trusted: Codex rewrites it whenever it lists models.
const CACHE_MAX_AGE: Duration = Duration::from_secs(7 * 24 * 60 * 60);
/// The largest config, sign-in or cache file read (Codex's cache is about 150 KiB).
const READ_LIMIT: u64 = 4 * 1024 * 1024;

/// Whether a config.toml names a model catalog of its own (at the top level or in the profile
/// its `profile` key selects) while its turns go to OpenAI: a `model_provider` of its own
/// (another backend, or a proxy) is served by a list this sign-in's backend does not keep.
pub fn custom_catalog(config_toml: &str) -> bool {
    let Ok(table) = config_toml.parse::<toml::Table>() else { return false };
    let profile = table
        .get("profile")
        .and_then(toml::Value::as_str)
        .and_then(|name| table.get("profiles")?.get(name)?.as_table());
    // The active profile's setting, else the top level's: Codex's own order.
    let setting = |key: &str| {
        profile
            .and_then(|p| p.get(key))
            .or_else(|| table.get(key))
            .and_then(toml::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
    };
    setting("model_catalog_json").is_some()
        && setting("model_provider").is_none_or(|provider| provider == "openai")
}

/// Whether an `auth.json` is a ChatGPT sign-in: `auth_mode` "chatgpt" (or, as an older Codex
/// wrote it, no mode and tokens), and no API key. Only those fields are read.
pub fn chatgpt_sign_in(auth_json: &[u8]) -> bool {
    let Ok(root) = serde_json::from_slice::<Value>(auth_json) else { return false };
    if root.get("OPENAI_API_KEY").and_then(Value::as_str).is_some_and(|key| !key.is_empty()) {
        return false;
    }
    match root.get("auth_mode").and_then(Value::as_str) {
        Some(mode) => mode == "chatgpt",
        None => root.get("tokens").is_some_and(Value::is_object),
    }
}

/// The model slugs of a `/models` answer (`{"models": [{"slug": ...}]}`), which
/// `models_cache.json` keeps as well; None when it names none.
pub fn served(body: &Value) -> Option<Vec<String>> {
    let slugs: Vec<String> = body
        .get("models")?
        .as_array()?
        .iter()
        .filter_map(|m| m.get("slug").and_then(Value::as_str))
        .map(str::trim)
        .filter(|slug| !slug.is_empty())
        .map(str::to_owned)
        .collect();
    (!slugs.is_empty()).then_some(slugs)
}

/// Codex's copy of the answer in its home `home`: the slugs and the client version it asked with.
/// None once it is older than [`CACHE_MAX_AGE`]: the account's plan may have changed since.
pub fn cached(home: &Path) -> Option<(Vec<String>, Option<String>)> {
    let path = home.join(CACHE_FILE);
    let age = std::fs::metadata(&path).ok()?.modified().ok()?.elapsed().unwrap_or_default();
    if age > CACHE_MAX_AGE {
        return None;
    }
    let body: Value = serde_json::from_slice(&read_limited(&path)?).ok()?;
    let version = body.get("client_version").and_then(Value::as_str).and_then(version_text);
    Some((served(&body)?, version))
}

/// The Codex version in its `initialize` answer's `userAgent` ("codex_cli_rs/0.147.0 (Mac OS
/// 26.6.0; arm64) ..."); None for a source build's 0.0.0, which the backend serves differently.
pub fn client_version(user_agent: &str) -> Option<String> {
    version_text(user_agent.split_whitespace().next()?.split_once('/')?.1)
}

/// `version` when it is a plain release version (digits, dots, letters, dashes), never 0.0.0.
fn version_text(version: &str) -> Option<String> {
    let plain = !version.is_empty()
        && version.len() <= 64
        && version.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-');
    (plain && version != "0.0.0").then(|| version.to_owned())
}

/// The slugs the backend at `base` serves the account `access` acts for, asked as Codex
/// `version` asks.
pub async fn fetch(base: &str, access: &Access, version: &str) -> Result<Vec<String>> {
    let account = crate::codex_login_access::account_id(&access.token)
        .ok_or_else(|| anyhow!("the sign-in names no account"))?;
    let version = version_text(version).ok_or_else(|| anyhow!("no client version to ask with"))?;
    // reqwest is built without a rustls provider: the workspace's ring one (as `byo_endpoint.rs`).
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = reqwest::Client::builder().timeout(FETCH_TIMEOUT).build()?;
    let url = format!("{}/models?client_version={version}", base.trim_end_matches('/'));
    let response = client
        .get(url)
        .bearer_auth(&access.token)
        .header(ACCOUNT_HEADER, account)
        .header("originator", "codex_cli_rs")
        .send()
        .await
        .map_err(|e| anyhow!("the model list request failed: {}", e.without_url()))?;
    let status = response.status();
    if !status.is_success() {
        bail!("the backend answered {status}");
    }
    let body = response.bytes().await.map_err(|e| anyhow!("{}", e.without_url()))?;
    let body: Value = serde_json::from_slice(&body)?;
    served(&body).ok_or_else(|| anyhow!("the backend listed no models"))
}

/// What a Codex home holds for [`served_for`], read in one blocking step.
struct Home {
    access: Option<Access>,
    cached: Option<(Vec<String>, Option<String>)>,
}

/// The models the ChatGPT sign-in in Codex home `home` is served (module docs): None unless its
/// config.toml names a catalog of its own and it is signed in with ChatGPT, or when neither the
/// backend nor Codex's copy answers. `version`: the running Codex's own ([`client_version`]).
pub async fn served_for(home: PathBuf, version: Option<String>) -> Option<Vec<String>> {
    let read = tokio::task::spawn_blocking(move || {
        let config = read_limited(&home.join("config.toml"))?;
        if !custom_catalog(std::str::from_utf8(&config).ok()?) {
            return None;
        }
        if !chatgpt_sign_in(&read_limited(&home.join("auth.json"))?) {
            return None;
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX));
        Some(Home { access: crate::codex_login_access::read(&home, now), cached: cached(&home) })
    })
    .await
    .ok()??;
    let asked = version.or_else(|| read.cached.as_ref().and_then(|(_, v)| v.clone()));
    if let (Some(access), Some(version)) = (&read.access, &asked) {
        match fetch(BASE_URL, access, version).await {
            Ok(slugs) => return Some(slugs),
            Err(e) => {
                tracing::info!(error = %format!("{e:#}"), "ChatGPT model list not read; using Codex's copy")
            }
        }
    }
    read.cached.map(|(slugs, _)| slugs)
}

/// Marks each of `models` that `served` lacks unavailable ([`UNAVAILABLE`]); the number marked.
/// Nothing is marked when `served` names none of them: that list is another backend's.
pub fn mark(models: &mut [LiveModel], served: &[String]) -> usize {
    let is_served = |id: &str| served.iter().any(|slug| slug == id);
    if !models.iter().any(|m| is_served(&m.id)) {
        return 0;
    }
    let mut marked = 0;
    for model in models.iter_mut().filter(|m| !is_served(&m.id)) {
        model.unavailable = Some(UNAVAILABLE.to_owned());
        marked += 1;
    }
    marked
}

/// A file's bytes, when it is a regular file within [`READ_LIMIT`].
fn read_limited(path: &Path) -> Option<Vec<u8>> {
    use std::io::Read as _;
    let file = std::fs::File::open(path).ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() > READ_LIMIT {
        return None;
    }
    let mut data = Vec::new();
    file.take(READ_LIMIT + 1).read_to_end(&mut data).ok()?;
    (data.len() as u64 <= READ_LIMIT).then_some(data)
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine as _;
    use serde_json::json;

    fn model(id: &str) -> LiveModel {
        serde_json::from_value(json!({"id": id, "name": id})).unwrap()
    }

    #[test]
    fn a_catalog_of_its_own_is_named_at_the_top_or_in_the_active_profile() {
        assert!(custom_catalog("model_catalog_json = \"/x/catalog.json\"\n"));
        assert!(custom_catalog(
            "profile = \"work\"\n[profiles.work]\nmodel_catalog_json = \"/x/catalog.json\"\n"
        ));
        assert!(!custom_catalog("model = \"gpt-6.1-sol\"\n"));
        assert!(!custom_catalog("[profiles.work]\nmodel_catalog_json = \"/x/catalog.json\"\n"));
        assert!(!custom_catalog("model_catalog_json = \"\"\n"));
        assert!(!custom_catalog("model_catalog_json = \"/x\n[[broken"));
    }

    #[test]
    fn a_catalog_for_another_provider_is_not_the_sign_ins() {
        let catalog = "model_catalog_json = \"/x/catalog.json\"\n";
        assert!(custom_catalog(&format!("model_provider = \"openai\"\n{catalog}")));
        assert!(!custom_catalog(&format!("model_provider = \"proxy\"\n{catalog}")));
        // The active profile's provider wins over the top level's.
        assert!(!custom_catalog(&format!(
            "{catalog}profile = \"work\"\n[profiles.work]\nmodel_provider = \"azure\"\n"
        )));
        assert!(custom_catalog(&format!(
            "model_provider = \"proxy\"\n{catalog}profile = \"work\"\n[profiles.work]\nmodel_provider = \"openai\"\n"
        )));
    }

    #[test]
    fn an_old_copy_of_the_list_is_not_trusted() {
        let home = tempfile::tempdir().unwrap();
        let path = home.path().join(CACHE_FILE);
        std::fs::write(&path, r#"{"client_version":"0.147.0","models":[{"slug":"gpt-5.6-sol"}]}"#)
            .unwrap();
        assert_eq!(
            cached(home.path()),
            Some((vec!["gpt-5.6-sol".to_owned()], Some("0.147.0".to_owned())))
        );
        let old = std::time::SystemTime::now() - CACHE_MAX_AGE - Duration::from_secs(60);
        std::fs::File::options().write(true).open(&path).unwrap().set_modified(old).unwrap();
        assert_eq!(cached(home.path()), None);
    }

    #[test]
    fn only_a_chatgpt_sign_in_counts() {
        assert!(chatgpt_sign_in(br#"{"auth_mode": "chatgpt", "tokens": {}}"#));
        assert!(chatgpt_sign_in(br#"{"OPENAI_API_KEY": null, "tokens": {}}"#));
        assert!(!chatgpt_sign_in(br#"{"auth_mode": "apikey", "OPENAI_API_KEY": "sk-x"}"#));
        assert!(!chatgpt_sign_in(br#"{"auth_mode": "chatgpt", "OPENAI_API_KEY": "sk-x"}"#));
        assert!(!chatgpt_sign_in(b"not json"));
    }

    #[test]
    fn the_served_slugs_and_codex_version_are_read() {
        let body = json!({"models": [{"slug": "gpt-5.6-sol"}, {"slug": " "}, {"id": "x"}, {"slug": "gpt-5.6-luna"}]});
        assert_eq!(served(&body), Some(vec!["gpt-5.6-sol".to_owned(), "gpt-5.6-luna".to_owned()]));
        assert_eq!(served(&json!({"models": []})), None);
        assert_eq!(served(&json!({"data": []})), None);
        assert_eq!(
            client_version("codex_cli_rs/0.147.0 (Mac OS 26.6.0; arm64) unknown").as_deref(),
            Some("0.147.0")
        );
        assert_eq!(client_version("acpmux/0.0.0 (Linux; x86_64)"), None, "a source build");
        assert_eq!(client_version("fake"), None);
        assert_eq!(client_version("codex/0.1?x=1 rest"), None);
    }

    /// The ChatGPT account serves gpt-5.6-*, the config's catalog lists gpt-6.1-sol too: only the
    /// served ones stay available. A served list sharing no model with the listed one marks none.
    #[test]
    fn models_the_account_is_not_served_are_marked() {
        let mut models: Vec<LiveModel> =
            ["gpt-6.1-sol", "gpt-6-astra", "gpt-5.6-sol"].into_iter().map(model).collect();
        let served = vec!["gpt-reserve".to_owned(), "gpt-5.6-sol".to_owned()];
        assert_eq!(mark(&mut models, &served), 2);
        let unavailable: Vec<_> = models.iter().map(|m| m.unavailable.is_some()).collect();
        assert_eq!(unavailable, [true, true, false]);
        let mut other: Vec<LiveModel> = ["gpt-6.1-sol"].into_iter().map(model).collect();
        assert_eq!(mark(&mut other, &served), 0);
        assert_eq!(other[0].unavailable, None);
    }

    fn jwt(claims: Value) -> String {
        let part = |v: &Value| {
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(serde_json::to_vec(v).unwrap())
        };
        format!("{}.{}.sig", part(&json!({"alg": "none"})), part(&claims))
    }

    /// The request Codex makes: `/models` with its client version, the token and the account id.
    #[tokio::test]
    async fn fetch_asks_the_backend_as_codex_does() {
        use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}/backend-api/codex", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let mut buf = [0u8; 4096];
            while !request.windows(4).any(|w| w == b"\r\n\r\n") {
                let n = socket.read(&mut buf).await.unwrap();
                if n == 0 {
                    break;
                }
                request.extend_from_slice(&buf[..n]);
            }
            let body = r#"{"models":[{"slug":"gpt-5.6-sol"},{"slug":"gpt-5.6-luna"}]}"#;
            let reply = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            );
            socket.write_all(reply.as_bytes()).await.unwrap();
            String::from_utf8_lossy(&request).into_owned()
        });
        let token = jwt(json!({"https://api.openai.com/auth": {"chatgpt_account_id": "acct-1"}}));
        let access = Access { token: token.clone(), expires_at: i64::MAX };
        let slugs = fetch(&base, &access, "0.147.0").await.unwrap();
        assert_eq!(slugs, ["gpt-5.6-sol", "gpt-5.6-luna"]);
        let request = server.await.unwrap().to_ascii_lowercase();
        assert!(
            request.starts_with("get /backend-api/codex/models?client_version=0.147.0 http/1.1"),
            "{request}"
        );
        assert!(request.contains(&format!("authorization: bearer {}", token.to_ascii_lowercase())));
        assert!(request.contains("chatgpt-account-id: acct-1"));
        assert!(request.contains("originator: codex_cli_rs"));
    }
}
