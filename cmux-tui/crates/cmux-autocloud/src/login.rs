//! `cmux-autocloud login`: sign in from a box with no browser and no Mac app.
//!
//! Stack's CLI login, the same one `cmux-cloud-config::cli_sign_in` describes for the app: mint a
//! login code, print cmux.com's confirm link (open it on any device, a phone works), poll until it
//! is confirmed, then trade the refresh token for an access token. The session is saved owner-only
//! at `~/.config/cmux/autocloud/session.json`; `CMUX_CLOUD_ACCESS_TOKEN` overrides it.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use cmux_cloud_config::cli_sign_in::{self, HttpCall, Polled, Project, Started, Tokens};
use serde::{Deserialize, Serialize};

pub const DEFAULT_CONFIG_URL: &str = "https://cmux.com/api/cli/config";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CliConfig {
    auth: CliAuth,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CliAuth {
    api_url: String,
    project_id: String,
    publishable_client_key: String,
    confirm_url: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Session {
    pub access_token: String,
    pub refresh_token: String,
}

pub fn session_path() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("cmux").join("autocloud").join("session.json")
}

/// The saved session, or the env override. None when signed out.
pub fn load() -> Option<Session> {
    if let Ok(token) = std::env::var("CMUX_CLOUD_ACCESS_TOKEN")
        && !token.trim().is_empty()
    {
        return Some(Session {
            access_token: token.trim().to_owned(),
            refresh_token: String::new(),
        });
    }
    let raw = std::fs::read_to_string(session_path()).ok()?;
    serde_json::from_str(&raw).ok()
}

fn save(session: &Session) -> Result<PathBuf> {
    let path = session_path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    let body = serde_json::to_vec_pretty(session)?;
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&path)
            .with_context(|| format!("write {}", path.display()))?;
        f.write_all(&body)?;
    }
    #[cfg(not(unix))]
    std::fs::write(&path, &body)?;
    Ok(path)
}

fn client() -> Result<reqwest::Client> {
    crate::install_tls();
    Ok(cmux_egress::client_builder("cmux_autocloud::login")
        .timeout(Duration::from_secs(20))
        .build()?)
}

async fn send(client: &reqwest::Client, call: &HttpCall) -> Result<(u16, String)> {
    let method = reqwest::Method::from_bytes(call.method.as_bytes())?;
    let mut req = client.request(method, &call.url).body(call.body.clone());
    for (k, v) in &call.headers {
        req = req.header(k, v);
    }
    let resp = req.send().await.with_context(|| format!("{} {}", call.method, call.url))?;
    let status = resp.status().as_u16();
    Ok((status, resp.text().await.unwrap_or_default()))
}

fn origin(url: &str) -> String {
    // "https://cmux.com/handler/..." -> "https://cmux.com"
    let Some((scheme, rest)) = url.split_once("://") else { return url.to_owned() };
    match rest.split_once('/') {
        Some((host, _)) => format!("{scheme}://{host}"),
        None => url.to_owned(),
    }
}

pub async fn run(config_url: &str) -> Result<()> {
    if config_url != DEFAULT_CONFIG_URL {
        // `--config-url`: a server the person named.
        cmux_egress::allow_named(config_url);
    }
    let client = client()?;
    let config: CliConfig = client
        .get(config_url)
        .send()
        .await
        .with_context(|| format!("GET {config_url}"))?
        .error_for_status()?
        .json()
        .await
        .context("read the CLI config")?;
    let project = Project {
        stack_base_url: config.auth.api_url,
        project_id: config.auth.project_id,
        publishable_client_key: config.auth.publishable_client_key,
    };
    let web = origin(&config.auth.confirm_url);

    let (status, body) = send(&client, &cli_sign_in::start_request(&project)).await?;
    let (polling_code, confirm_url) = match cli_sign_in::read_start(status, &body, &web) {
        Started::Started { polling_code, confirm_url, .. } => (polling_code, confirm_url),
        Started::Refused { reason } => bail!("sign-in refused: {reason}"),
    };
    eprintln!("Open this link on any device and confirm:\n\n  {confirm_url}\n\nWaiting...");

    let refresh = loop {
        tokio::time::sleep(Duration::from_millis(cli_sign_in::POLL_INTERVAL_MS)).await;
        let (status, body) =
            match send(&client, &cli_sign_in::poll_request(&project, &polling_code)).await {
                Ok(r) => r,
                Err(_) => continue, // a bad link: keep polling until the code expires
            };
        match cli_sign_in::read_poll(status, &body) {
            Polled::Waiting | Polled::Retry { .. } => {}
            Polled::SignedIn { refresh_token } => break refresh_token,
            Polled::Ended { reason } => bail!("sign-in ended: {reason}"),
        }
    };
    let (status, body) = send(&client, &cli_sign_in::token_request(&project, &refresh)).await?;
    let session = match cli_sign_in::read_token(status, &body, &refresh) {
        Tokens::Tokens { access_token, refresh_token } => Session { access_token, refresh_token },
        Tokens::Refused { reason } => return Err(anyhow!("token refused: {reason}")),
    };
    let path = save(&session)?;
    eprintln!("Signed in. Saved to {}", path.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn origin_is_scheme_and_host() {
        assert_eq!(super::origin("https://cmux.com/handler/cli-auth-confirm"), "https://cmux.com");
        assert_eq!(super::origin("http://localhost:3000"), "http://localhost:3000");
    }
}
