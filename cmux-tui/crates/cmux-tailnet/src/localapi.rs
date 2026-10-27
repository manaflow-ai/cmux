//! The node's LocalAPI, served by tsnet on a loopback port that only this
//! process knows the password for (`tailscale_loopback`).

use std::io::{BufRead, BufReader, Read};

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
    pub(crate) fn new(addr: &str, cred: &str) -> Self {
        let token = base64::engine::general_purpose::STANDARD.encode(format!(":{cred}"));
        // Requests stay on loopback: never through a proxy from the
        // environment (it would receive the LocalAPI password). The watch
        // stream must not time out.
        let agent =
            reqwest::blocking::Client::builder().no_proxy().build().expect("LocalAPI client");
        Self { base: format!("http://{addr}"), authorization: format!("Basic {token}"), agent }
    }

    fn get(&self, path: &str) -> Result<reqwest::blocking::Response> {
        let response = self
            .agent
            .get(format!("{}{path}", self.base))
            .header("Sec-Tailscale", "localapi")
            .header("Authorization", &self.authorization)
            .send()
            .map_err(|error| Error(format!("LocalAPI {path}: {error}")))?;
        if response.status() != reqwest::StatusCode::OK {
            let status = response.status();
            let body = response.text().unwrap_or_default();
            return Err(Error(format!("LocalAPI {path}: HTTP {status}: {}", body.trim())));
        }
        Ok(response)
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
            .read_to_end(&mut body)
            .map_err(|error| Error(format!("LocalAPI certificate: {error}")))?;
        Ok(body)
    }

    pub(crate) fn watch(&self) -> Result<Watch> {
        let mask = NOTIFY_INITIAL_STATE | NOTIFY_NO_PRIVATE_KEYS;
        let response = self.get(&format!("/localapi/v0/watch-ipn-bus?mask={mask}"))?;
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
