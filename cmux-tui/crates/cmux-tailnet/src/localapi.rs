//! The node's LocalAPI, served by tsnet on a loopback port that only this
//! process knows the password for (`tailscale_loopback`).

use std::io::{BufRead, BufReader, Read};
use std::sync::OnceLock;
use std::sync::mpsc::{self, Sender};
use std::thread;
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
    agent: ClientOwner,
}

/// `reqwest::blocking::Client` owns a Tokio runtime. Dropping it on a Tokio
/// worker panics, so all final clients go through one ordinary thread.
struct ClientOwner {
    client: Option<reqwest::blocking::Client>,
    drop_tx: Sender<reqwest::blocking::Client>,
}

impl ClientOwner {
    fn client(&self) -> Result<&reqwest::blocking::Client> {
        self.client.as_ref().ok_or_else(|| Error("LocalAPI client is unavailable".into()))
    }
}

impl Drop for ClientOwner {
    fn drop(&mut self) {
        let Some(client) = self.client.take() else { return };
        if let Err(error) = self.drop_tx.send(client) {
            // The process-global worker only exits at process teardown. If it
            // is unavailable during teardown, keep the client from dropping
            // on the caller's runtime thread rather than panic there.
            let _ = thread::Builder::new()
                .name("cmux-tailnet-client-drop".into())
                .spawn(move || drop(error.0));
        }
    }
}

fn drop_sender() -> Result<Sender<reqwest::blocking::Client>> {
    if let Some(sender) = CLIENT_DROP_SENDER.get() {
        return Ok(sender.clone());
    }
    let (sender, receiver) = mpsc::channel();
    thread::Builder::new()
        .name("cmux-tailnet-client-drop".into())
        .spawn(move || {
            while let Ok(client) = receiver.recv() {
                drop(client);
            }
        })
        .map_err(|_| Error("could not start LocalAPI client cleanup".into()))?;
    match CLIENT_DROP_SENDER.set(sender.clone()) {
        Ok(()) => Ok(sender),
        Err(_) => CLIENT_DROP_SENDER
            .get()
            .cloned()
            .ok_or_else(|| Error("LocalAPI cleanup worker unavailable".into())),
    }
}

static CLIENT_DROP_SENDER: OnceLock<Sender<reqwest::blocking::Client>> = OnceLock::new();

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
        Ok(Self {
            base: format!("http://{addr}"),
            authorization: format!("Basic {token}"),
            agent: ClientOwner { client: Some(agent), drop_tx: drop_sender()? },
        })
    }

    fn request(
        &self,
        method: reqwest::Method,
        path: &str,
        watch: bool,
    ) -> Result<reqwest::blocking::Response> {
        let mut request = self
            .agent
            .client()?
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
