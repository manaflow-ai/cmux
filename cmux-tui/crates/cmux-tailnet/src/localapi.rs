//! The node's LocalAPI, served by tsnet on a loopback port that only this
//! process knows the password for (`tailscale_loopback`).

use std::io::{BufRead, BufReader, Read};
use std::time::Duration;

use base64::Engine;

use crate::{Error, Notify, Result, WhoIs};

/// ipn.NotifyInitialState: the first message carries the current state and sign-in URL.
const NOTIFY_INITIAL_STATE: u64 = 1 << 1;
/// ipn.NotifyNoPrivateKeys.
const NOTIFY_NO_PRIVATE_KEYS: u64 = 1 << 4;

pub(crate) struct LocalApi {
    base: String,
    authorization: String,
    agent: reqwest::blocking::Client,
}

impl LocalApi {
    pub(crate) fn new(addr: &str, cred: &str) -> Result<Self> {
        // reqwest's rustls-no-provider feature requires explicit initialization.
        let _ = rustls::crypto::ring::default_provider().install_default();
        let token = base64::engine::general_purpose::STANDARD.encode(format!(":{cred}"));
        // This client carries the private LocalAPI password. Never use proxies or redirects.
        let agent = reqwest::blocking::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(10))
            .build()
            .map_err(|_| Error("could not create LocalAPI client".into()))?;
        Ok(Self { base: format!("http://{addr}"), authorization: format!("Basic {token}"), agent })
    }

    fn request(
        &self,
        method: reqwest::Method,
        path: &str,
        watch: bool,
    ) -> Result<reqwest::blocking::Response> {
        let mut request = self
            .agent
            .request(method, format!("{}{path}", self.base))
            .header("Sec-Tailscale", "localapi")
            .header("Authorization", &self.authorization);
        if !watch {
            request = request.timeout(Duration::from_secs(30));
        }
        let response = request.send().map_err(|_| Error("LocalAPI request failed".into()))?;
        if !response.status().is_success() {
            // Error bodies may contain sign-in links or key material.
            return Err(Error(format!("LocalAPI: HTTP {}", response.status())));
        }
        Ok(response)
    }

    fn get(&self, path: &str) -> Result<reqwest::blocking::Response> {
        self.request(reqwest::Method::GET, path, false)
    }

    pub(crate) fn logout(&self) -> Result<()> {
        self.request(reqwest::Method::POST, "/localapi/v0/logout", false).map(|_| ())
    }

    pub(crate) fn login_interactive(&self) -> Result<()> {
        self.request(reqwest::Method::POST, "/localapi/v0/login-interactive", false).map(|_| ())
    }

    pub(crate) fn whois(&self, addr: &str) -> Result<WhoIs> {
        let path = format!("/localapi/v0/whois?addr={}", encode_query(addr));
        let response = self.get(&path)?;
        serde_json::from_reader(response).map_err(|error| Error(format!("whois: {error}")))
    }

    /// Returns the node's Tailscale-issued certificate and private key PEM for
    /// `domain`. The key is held by the caller only in memory; this endpoint
    /// never writes it to the daemon log or state directory.
    pub(crate) fn certificate_pair(&self, domain: &str) -> Result<Vec<u8>> {
        if domain.is_empty()
            || domain.len() > 253
            || domain
                .bytes()
                .any(|byte| !(byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-')))
        {
            return Err(Error("certificate domain is invalid".into()));
        }
        let response = self.get(&format!("/localapi/v0/cert/{domain}?type=pair"))?;
        let mut body = Vec::new();
        response
            .take(65537)
            .read_to_end(&mut body)
            .map_err(|error| Error(format!("LocalAPI certificate: {error}")))?;
        if body.len() > 65536 {
            return Err(Error("LocalAPI certificate exceeds PEM limit".into()));
        }
        Ok(body)
    }

    pub(crate) fn watch(&self) -> Result<Watch> {
        let mask = NOTIFY_INITIAL_STATE | NOTIFY_NO_PRIVATE_KEYS;
        let response = self.request(
            reqwest::Method::GET,
            &format!("/localapi/v0/watch-ipn-bus?mask={mask}"),
            true,
        )?;
        Ok(Watch { lines: BufReader::new(Box::new(response)) })
    }
}

/// The node's IPN bus: each `next()` blocks until the node reports a change.
/// Ends when the node closes.
pub struct Watch {
    lines: BufReader<Box<dyn Read + Send>>,
}

impl Iterator for Watch {
    type Item = Notify;

    fn next(&mut self) -> Option<Notify> {
        let mut line = String::new();
        loop {
            line.clear();
            if self.lines.read_line(&mut line).ok()? == 0 {
                return None;
            }
            if let Ok(notify) = serde_json::from_str::<Notify>(line.trim()) {
                return Some(notify);
            }
        }
    }
}

fn encode_query(value: &str) -> String {
    value
        .bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'.' | b'-' | b'_' => {
                (byte as char).to_string()
            }
            _ => format!("%{byte:02X}"),
        })
        .collect()
}
