//! `acpmux hand pair <code>`: make the hand's key, register it with the
//! single-use code, and write hand.json.
//!
//! The key never leaves this machine except in the Authorization header of
//! the hand's own socket; pairing sends only its SHA-256.

use super::config::{self, HandConfig, Profile};
use super::fsops::sha256_hex;
use anyhow::{Context, Result, bail};
use base64::Engine;
use serde_json::{Value, json};
use std::path::PathBuf;
use std::time::Duration;

/// `https://`, or `http://` to a loopback host (local development only).
pub fn check_api(api: &str) -> Result<String> {
    let api = api.trim_end_matches('/').to_owned();
    let url = reqwest::Url::parse(&api).with_context(|| format!("bad API origin {api}"))?;
    let loopback = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
    match url.scheme() {
        "https" => Ok(api),
        "http" if loopback => Ok(api),
        _ => bail!("the API origin must be https:// (http:// only for a loopback host)"),
    }
}

pub fn hostname() -> String {
    let mut buf = [0u8; 256];
    #[cfg(unix)]
    {
        // SAFETY: `buf` is a writable buffer of the length passed; gethostname
        // writes at most that many bytes.
        if unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0 {
            let name = buf.split(|&b| b == 0).next().unwrap_or_default();
            return String::from_utf8_lossy(name).into_owned();
        }
    }
    let _ = &mut buf;
    std::env::var("HOSTNAME").unwrap_or_else(|_| "hand".into())
}

pub async fn pair(
    code: &str,
    api: &str,
    profile: &str,
    roots: Vec<PathBuf>,
    agent_policy: Option<String>,
    name: Option<String>,
) -> Result<HandConfig> {
    let api = check_api(api)?;
    let profile = Profile::parse(profile)?;
    let roots = match (profile, roots.is_empty()) {
        (Profile::Sandbox, true) => vec![PathBuf::from("/")],
        // Broad by default (#13742): the person's home; the classifier and the hard denies guard it.
        (Profile::Mac, true) => vec![dirs::home_dir().context("no home folder")?],
        (_, false) => {
            let mut canonical = Vec::with_capacity(roots.len());
            for r in roots {
                let root = tokio::fs::canonicalize(&r)
                    .await
                    .with_context(|| format!("root {}", r.display()))?;
                canonical.push(root);
            }
            canonical
        }
    };
    let agent_policy = agent_policy.unwrap_or_else(|| match profile {
        Profile::Sandbox => "approve-edits".into(),
        Profile::Mac => "ask".into(),
    });
    let mut raw = [0u8; 32];
    getrandom::fill(&mut raw).map_err(|e| anyhow::anyhow!("the OS random generator: {e}"))?;
    let key = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(raw);
    let name = name.unwrap_or_else(hostname);
    let body = json!({
        "code": code.trim(),
        "key_sha256": sha256_hex(key.as_bytes()),
        "name": name,
        "profile": profile,
        "roots": roots,
        "agent_policy": agent_policy,
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "version": crate::hub::VERSION,
    });
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(30))
        .user_agent(concat!("cmux-hand/", env!("CARGO_PKG_VERSION")))
        .build()?;
    let res = client
        .post(format!("{api}/v1/hands/pair"))
        .json(&body)
        .send()
        .await
        .context("pairing request")?;
    let status = res.status();
    let answer: Value = res.json().await.unwrap_or(Value::Null);
    if !status.is_success() || answer.get("ok") != Some(&Value::Bool(true)) {
        let msg = answer.pointer("/error/message").and_then(Value::as_str).unwrap_or("no answer");
        bail!("pairing refused ({status}): {msg}");
    }
    let hand = answer
        .pointer("/value/hand")
        .and_then(Value::as_str)
        .context("pairing answer has no hand id")?
        .to_owned();
    let cfg = HandConfig { api, hand, key, profile, roots, allow: Vec::new(), agent_policy };
    let path = config::save(&cfg)?;
    eprintln!("wrote {}", path.display());
    Ok(cfg)
}
