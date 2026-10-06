//! `optchat-chief cloud pair`: the brain host pairs like a cmux server
//! (plans/cmux-next/server.md 6.2), so no session token ever reaches it.
//!
//! 1. `POST /v1/pair/begin` (no account): the install key's proof of
//!    possession over `cmux-pair-begin\n<env>\n<thumbprint>\n<wg key>\n<issued_at>`
//!    returns a code and a collect secret (never printed).
//! 2. The user enters the code in the app ("Server > Add Server…"), checks
//!    the four fingerprint words and approves: `server.pair.approve` registers
//!    this install key under the user (a `daemon` install) and adds the host
//!    to the team.
//! 3. `GET /v1/pair/wait` (WebSocket, subprotocols `cmux.pair.v1,
//!    collect.<secret>`) pushes `{t:"paired", host, team, user, install}`.
//! 4. The app places a chief on this install (`brain_place: {host, install}`);
//!    the brain finds it with `chief.list` under its install token. Only the
//!    chief placed on this install gets the rights a brain needs.

use std::io::Write;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tungstenite::client::IntoClientRequest as _;
use tungstenite::http::HeaderValue;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket};

use super::auth::{self, Http, InstallFile, InstallTokens, Lease, TokenSource};

/// What `cloud pair` was asked for.
#[derive(Clone, Debug)]
pub struct PairOptions {
    /// The server name the approver sees (default: the short host name).
    pub name: Option<String>,
    /// `--chief default`: answer as the active default chief when no chief
    /// is placed on this install within `wait_chief`.
    pub default_fallback: bool,
    /// How long to look for the placed chief after pairing.
    pub wait_chief: Duration,
    /// The first delay between `chief.list` reads (it doubles, up to 8x).
    pub poll: Duration,
}

impl Default for PairOptions {
    fn default() -> PairOptions {
        PairOptions {
            name: None,
            default_fallback: false,
            wait_chief: Duration::from_secs(300),
            poll: Duration::from_secs(2),
        }
    }
}

/// The pairing a wait socket pushed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Paired {
    pub host: String,
    pub team: String,
    pub user: String,
    pub install: String,
}

/// How a wait ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Waited {
    Paired(Paired),
    /// The approver may not add servers, or the code was spent (close 4403).
    Refused,
    /// The code ran out before anyone approved it.
    Expired,
}

/// RFC 7638 SHA-256 thumbprint of a P-256 public JWK (base64url, no padding).
pub fn jwk_thumbprint(jwk: &Value) -> Result<String, String> {
    let member = |k: &str| {
        jwk.get(k)
            .and_then(Value::as_str)
            .ok_or_else(|| format!("public JWK without {k}"))
    };
    // Lexicographic member order, no whitespace; the values are base64url, so no escaping.
    let canonical = format!(
        r#"{{"crv":"{}","kty":"{}","x":"{}","y":"{}"}}"#,
        member("crv")?,
        member("kty")?,
        member("x")?,
        member("y")?
    );
    Ok(B64.encode(Sha256::digest(canonical.as_bytes())))
}

/// What the install key signs for `POST /v1/pair/begin`.
pub fn begin_proof(environment: &str, thumbprint: &str, wg_public: &str, issued_at: u64) -> String {
    format!("cmux-pair-begin\n{environment}\n{thumbprint}\n{wg_public}\n{issued_at}")
}

/// The four words the app shows for this thumbprint (the swap check).
pub fn fingerprint_words(thumbprint: &str) -> Option<[&'static str; 4]> {
    let bytes = B64.decode(thumbprint).ok()?;
    (bytes.len() == 32).then(|| cmux_server_core::pairing::fingerprint_words(&bytes))
}

/// `wss://…/v1/pair/wait?code=…` for an `https` API (`ws` for loopback `http`).
pub fn wait_url(api: &str, code: &str) -> Result<String, String> {
    let api = api.trim_end_matches('/');
    let base = if let Some(rest) = api.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = api.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        return Err(format!("{api}: not an http(s) API origin"));
    };
    Ok(format!("{base}/v1/pair/wait?code={code}"))
}

/// Picks the chief this install answers as: the active chief placed on
/// `install`, else (with `default_fallback`) the active default chief.
pub fn placed_chief(list: &Value, install: &str, default_fallback: bool) -> Option<Value> {
    let active: Vec<&Value> = list
        .get("chiefs")
        .and_then(Value::as_array)?
        .iter()
        .filter(|c| c.get("archived_at").is_none_or(Value::is_null))
        .collect();
    active
        .iter()
        .find(|c| c.pointer("/brain_place/install").and_then(Value::as_str) == Some(install))
        .or_else(|| {
            default_fallback
                .then(|| {
                    active
                        .iter()
                        .find(|c| c.get("is_default") == Some(&Value::Bool(true)))
                })
                .flatten()
        })
        .map(|c| (*c).clone())
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// Waits for the approval of `code` until `deadline_ms`. A socket that ends
/// without a result is reopened (the PairingDO answers a reconnect with the
/// current state); five failed connects in a row are an error.
pub fn wait(api: &str, code: &str, secret: &str, deadline_ms: u64) -> Result<Waited, String> {
    let url = wait_url(api, code)?;
    let mut failures = 0;
    loop {
        if now_ms() >= deadline_ms {
            return Ok(Waited::Expired);
        }
        match wait_once(&url, secret, deadline_ms) {
            Ok(Some(done)) => return Ok(done),
            Ok(None) => failures = 0,
            Err(e) => {
                failures += 1;
                if failures >= 5 {
                    return Err(e);
                }
            }
        }
        let left = deadline_ms.saturating_sub(now_ms());
        std::thread::sleep(Duration::from_millis(left.min(2_000)));
    }
}

fn set_read_timeout(ws: &WebSocket<MaybeTlsStream<std::net::TcpStream>>, t: Duration) {
    let _ = match ws.get_ref() {
        MaybeTlsStream::Plain(s) => s.set_read_timeout(Some(t)),
        MaybeTlsStream::Rustls(s) => s.sock.set_read_timeout(Some(t)),
        _ => Ok(()),
    };
}

/// One wait socket: `Some` when it ended the wait, `None` when it closed without a result.
fn wait_once(url: &str, secret: &str, deadline_ms: u64) -> Result<Option<Waited>, String> {
    let mut request = url
        .into_client_request()
        .map_err(|e| format!("pair wait: {e}"))?;
    let protocols = HeaderValue::from_str(&format!("cmux.pair.v1, collect.{secret}"))
        .map_err(|_| "pair wait: the collect secret is not a header value".to_owned())?;
    request
        .headers_mut()
        .insert("Sec-WebSocket-Protocol", protocols);
    // The error never carries the request, so the secret stays out of logs.
    let (mut ws, _) = tungstenite::connect(request).map_err(|e| format!("pair wait: {e}"))?;
    set_read_timeout(&ws, Duration::from_millis(500));
    loop {
        if now_ms() >= deadline_ms {
            let _ = ws.close(None);
            return Ok(Some(Waited::Expired));
        }
        match ws.read() {
            Ok(Message::Text(text)) => {
                let frame: Value = serde_json::from_str(text.as_str())
                    .map_err(|e| format!("pair wait: bad frame: {e}"))?;
                match frame.get("t").and_then(Value::as_str) {
                    Some("paired") => {
                        let field = |k: &str| {
                            frame
                                .get(k)
                                .and_then(Value::as_str)
                                .map(str::to_owned)
                                .ok_or_else(|| format!("pair wait: paired frame without {k}"))
                        };
                        let paired = Paired {
                            host: field("host")?,
                            team: field("team")?,
                            user: field("user")?,
                            install: field("install")?,
                        };
                        let _ = ws.close(None);
                        return Ok(Some(Waited::Paired(paired)));
                    }
                    Some("refused") => return Ok(Some(Waited::Refused)),
                    _ => {}
                }
            }
            Ok(Message::Close(frame)) => {
                if frame.is_some_and(|f| u16::from(f.code) == 4403) {
                    return Ok(Some(Waited::Refused));
                }
                return Ok(None);
            }
            Ok(_) => {}
            Err(tungstenite::Error::Io(e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => {
                return Ok(None);
            }
            Err(e) => return Err(format!("pair wait: {e}")),
        }
    }
}

fn host_name() -> String {
    std::process::Command::new("/bin/hostname")
        .arg("-s")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "brain".into())
}

fn os_version() -> String {
    let (cmd, args): (&str, &[&str]) = if cfg!(target_os = "macos") {
        ("/usr/bin/sw_vers", &["-productVersion"])
    } else {
        ("/bin/uname", &["-r"])
    };
    std::process::Command::new(cmd)
        .args(args)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".into())
        .chars()
        .take(80)
        .collect()
}

fn pairing_info(name: Option<&str>) -> Value {
    let name: String = name
        .map(str::to_owned)
        .unwrap_or_else(host_name)
        .chars()
        .take(80)
        .collect();
    json!({
        "name": name,
        "platform": if cfg!(target_os = "macos") { "macos" } else { "linux" },
        "os_version": os_version(),
        "arch": if cfg!(target_arch = "aarch64") { "aarch64" } else { "x86_64" },
        "cmux_version": format!("optchat-chief/{}", env!("CARGO_PKG_VERSION")),
    })
}

/// `POST /v1/pair/begin` with the install key's proof; returns the reply.
fn begin(http: &dyn Http, file: &InstallFile, info: Value) -> Result<Value, String> {
    let api = &file.api_base_url;
    let health = http.get(&format!("{api}/v1/health"))?;
    let environment = health
        .get("environment")
        .and_then(Value::as_str)
        .ok_or("health reply without an environment")?;
    let thumbprint = jwk_thumbprint(&file.public_jwk)?;
    let wg = file
        .wg_public()
        .ok_or("the install file has no WireGuard key")?;
    let issued_at = now_ms();
    let signature = file.sign(&begin_proof(environment, &thumbprint, &wg, issued_at))?;
    http.post(
        &format!("{api}/v1/pair/begin"),
        &json!({"public_jwk": file.public_jwk, "wg_public_key": wg, "info": info,
                "issued_at": issued_at, "signature": signature}),
        None,
    )
}

/// The whole `cloud pair` flow; progress goes to `out`, the summary is returned.
/// A file that is paired but has no chief resumes at the chief step.
pub fn pair(
    http: Arc<dyn Http>,
    path: &Path,
    api: &str,
    opts: &PairOptions,
    out: &mut dyn Write,
) -> Result<String, String> {
    let mut file = if path.exists() {
        InstallFile::load(path)?
    } else {
        if !(api.starts_with("https://")
            || api.starts_with("http://127.0.0.1")
            || api.starts_with("http://localhost"))
        {
            return Err(format!(
                "--api-base {api}: an https origin (http only on loopback)"
            ));
        }
        InstallFile::generate(api)?
    };
    if let (Some(install), Some(chief)) = (&file.install, &file.chief) {
        return Err(format!(
            "{} is paired already (install {install}, chief {chief})",
            path.display()
        ));
    }
    file.ensure_wg();
    file.save(path)?;

    if file.install.is_none() {
        let reply = begin(&*http, &file, pairing_info(opts.name.as_deref()))?;
        let text = |k: &str| reply.get(k).and_then(Value::as_str).unwrap_or("");
        let (code, secret) = (text("code"), text("collect_secret"));
        if code.is_empty() || secret.is_empty() {
            return Err(format!(
                "pair begin: {}",
                reply.get("error").cloned().unwrap_or(Value::Null)
            ));
        }
        let expires_at = reply.get("expires_at").and_then(Value::as_u64).unwrap_or(0);
        let minutes = expires_at.saturating_sub(now_ms()).div_ceil(60_000);
        let _ = writeln!(
            out,
            "pairing code: {} (expires in {minutes} min)",
            text("display")
        );
        if let Some(words) = fingerprint_words(text("thumbprint")) {
            let _ = writeln!(out, "check words:  {}", words.join(" "));
        }
        let _ = writeln!(
            out,
            "In the cmux app: Server > Add Server…, enter the code and check the words."
        );
        let _ = out.flush();
        match wait(&file.api_base_url, code, secret, expires_at)? {
            Waited::Paired(p) => {
                file.install = Some(p.install);
                file.user = Some(p.user);
                file.host = Some(p.host);
                file.team = Some(p.team);
                file.save(path)?;
                let _ = writeln!(
                    out,
                    "paired: host {} (install {})",
                    file.host.as_deref().unwrap_or("-"),
                    file.install.as_deref().unwrap_or("-")
                );
            }
            Waited::Refused => return Err("the pairing was refused".into()),
            Waited::Expired => {
                return Err(
                    "the code expired before it was approved; run `cloud pair` again".into(),
                );
            }
        }
    }

    let install = file.install.clone().unwrap_or_default();
    let _ = writeln!(out, "waiting for the app to place a chief on this server…");
    let chief = find_chief(http, &file, &install, opts)?;
    let id = chief
        .get("id")
        .and_then(Value::as_str)
        .ok_or("chief without an id")?;
    let main = chief
        .get("main_conversation")
        .and_then(Value::as_str)
        .ok_or("chief without a main conversation")?;
    file.chief = Some(id.to_owned());
    file.conversation = Some(main.to_owned());
    file.save(path)?;
    Ok(format!(
        "paired host {} (install {install}, team {}); chief {id}, main conversation {main}",
        file.host.as_deref().unwrap_or("-"),
        file.team.as_deref().unwrap_or("-"),
    ))
}

/// Reads `chief.list` with the install token (re-minted near expiry) with a
/// doubling delay until a chief is placed on `install`; at the deadline the
/// default chief counts when asked.
fn find_chief(
    http: Arc<dyn Http>,
    file: &InstallFile,
    install: &str,
    opts: &PairOptions,
) -> Result<Value, String> {
    let tokens = InstallTokens::new(file.clone(), http.clone());
    let started = Instant::now();
    let mut lease: Option<Lease> = None;
    let mut delay = opts.poll;
    loop {
        if lease
            .as_ref()
            .is_none_or(|l| l.expires_at <= now_ms() + 60_000)
        {
            lease = Some(tokens.mint(None)?);
        }
        let token = &lease.as_ref().expect("minted above").access_token;
        let list = auth::read(&*http, &file.api_base_url, token, "chief.list", json!({}))?;
        if let Some(chief) = placed_chief(&list, install, false) {
            return Ok(chief);
        }
        if started.elapsed() >= opts.wait_chief {
            return placed_chief(&list, install, opts.default_fallback).ok_or_else(|| {
                format!(
                    "no chief is placed on install {install} yet: place one in the app \
                     (Server > Add Server…), then run `cloud pair` again (or pass --chief default)"
                )
            });
        }
        std::thread::sleep(delay.min(opts.wait_chief.saturating_sub(started.elapsed())));
        delay = (delay * 2).min(opts.poll * 8);
    }
}
