//! The newest version a channel offers: the npm registry for npm, bun and the
//! native installers that publish there, the Homebrew API for formulae and
//! casks. A standalone binary has no source to ask.

use super::channel::{Channel, Install};
use serde_json::Value;

/// Where to ask. The daemon uses [`Sources::public`]; tests point both at a
/// loopback server (a debug build only, see [`fetch_json`]).
#[derive(Clone, Debug)]
pub struct Sources {
    /// The npm registry's base URL (`https://registry.npmjs.org`).
    pub npm: String,
    /// The Homebrew API's base URL (`https://formulae.brew.sh/api`).
    pub brew: String,
}

impl Sources {
    pub fn public() -> Self {
        Self {
            npm: "https://registry.npmjs.org".into(),
            brew: "https://formulae.brew.sh/api".into(),
        }
    }
}

const MAX_BODY_BYTES: usize = 2 << 20;

/// The URL that answers `install`'s newest version, if its channel has one.
pub fn url(install: &Install, sources: &Sources) -> Option<String> {
    let package = install.package.as_deref()?;
    match install.channel {
        Channel::Npm | Channel::Bun | Channel::Native => {
            Some(format!("{}/{}/latest", sources.npm, package.replace('/', "%2F")))
        }
        Channel::Brew => Some(format!("{}/formula/{package}.json", sources.brew)),
        Channel::BrewCask => Some(format!("{}/cask/{package}.json", sources.brew)),
        _ => None,
    }
}

/// The version in a source's answer for `channel`.
pub fn parse(channel: Channel, body: &Value) -> Option<String> {
    let text = match channel {
        Channel::Brew => body.pointer("/versions/stable"),
        // A cask's version may carry a build after a comma (`1.2.3,4567`).
        Channel::BrewCask => body.get("version"),
        _ => body.get("version"),
    }?;
    let text = text.as_str()?.split(',').next()?.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

/// GETs `url` as JSON. HTTPS only, no redirects, a short timeout and a body
/// cap. A debug build also takes a loopback `http://127.0.0.1` URL (tests).
pub async fn fetch_json(url: &str) -> Result<Value, String> {
    let loopback = cfg!(debug_assertions) && url.starts_with("http://127.0.0.1:");
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = reqwest::Client::builder()
        .https_only(!loopback)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(15))
        .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| e.to_string())?;
    let mut response = client
        .get(url)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("{url} answered {}", response.status()));
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
        crate::catalog::fetch::push_capped(&mut body, &chunk, MAX_BODY_BYTES)?;
    }
    serde_json::from_slice(&body).map_err(|e| e.to_string())
}
