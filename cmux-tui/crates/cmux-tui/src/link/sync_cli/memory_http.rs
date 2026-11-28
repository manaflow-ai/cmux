//! The head as the cmux-platform `AgentHome` service (`/v1/agent-home`):
//! `--head https://HOST` (or `http://127.0.0.1:PORT` in tests).
//!
//! - Auth: the person's bearer token (`CMUX_AGENT_HOME_TOKEN`, else the
//!   signed-in cmux login). A machine also shows its memory capability
//!   (`CMUX_AGENT_HOME_CAPABILITY`, `ahc_…`) as `X-Agent-Home-Capability`.
//! - Blobs are read through a short-lived read grant (`POST grants`, then
//!   `X-Agent-Home-Grant`); `put_blob` only keeps the bytes here, and the
//!   proposal carries them inline (base64).
//! - Home paths map to the service's `(project, path)`: `.claude/CLAUDE.md`
//!   is `("", "claude/CLAUDE.md")`, and the same for `.codex/`, `.gemini/`,
//!   agents, commands, skills and prompts. A Claude project's memory
//!   (`.claude/projects/<slug>/memory/**`) is `("local:<slug>",
//!   "claude/memory/**")` for now; mapping a slug to the project's git id is
//!   a later step.
//! - The service keeps no permissions: every file it holds reads `0o644`, and
//!   this head says so ([`Head::keeps_modes`]), so a file's mode alone is
//!   never a change.
//! - The person's own device accepts its own proposal ([`Head::accept_own`]):
//!   acceptance, then accept at the revision it was based on. A machine never
//!   accepts; the service refuses it (`agent_home.person_only`) anyway.

use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::Duration;

use anyhow::{Context as _, bail};
use base64::Engine as _;
use reqwest::{Method, StatusCode};
use serde::Deserialize;
use serde_json::{Value, json};

use super::{Accepted, Head, HeadRead, Item, Manifest, Proposal, carried, sha256_hex};

const ROOT: &str = "/v1/agent-home";

/// Whether `head` names the service rather than a folder.
pub(crate) fn is_url(head: &str) -> bool {
    head.starts_with("https://") || head.starts_with("http://")
}

/// The service origin `head` names: `https://HOST[:PORT]`, or plain HTTP to
/// loopback only (a test's fake service).
pub(crate) fn origin_of(head: &str) -> anyhow::Result<String> {
    let url = url::Url::parse(head).with_context(|| format!("--head {head}: not a URL"))?;
    let host = url.host_str().unwrap_or_default();
    let loopback = matches!(host, "127.0.0.1" | "localhost" | "[::1]" | "::1");
    if url.scheme() != "https" && !(url.scheme() == "http" && loopback) {
        bail!("--head {head}: the AgentHome service is https:// (plain http only to 127.0.0.1)");
    }
    if host.is_empty() || !url.username().is_empty() || url.password().is_some() {
        bail!("--head {head}: name only the origin");
    }
    if !matches!(url.path(), "" | "/") || url.query().is_some() || url.fragment().is_some() {
        bail!("--head {head}: name only the origin (https://HOST)");
    }
    Ok(url.origin().ascii_serialization())
}

/// The service's `(project, path)` for a home path, when it carries it.
pub(super) fn to_service(key: &str) -> Option<(String, String)> {
    let (project, path) = if let Some(rest) = key.strip_prefix(".claude/projects/") {
        let (slug, rest) = rest.split_once('/')?;
        let rest = rest.strip_prefix("memory/")?;
        let slug_ok = (8..=64).contains(&slug.len())
            && slug.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
        if !slug_ok {
            return None;
        }
        (format!("local:{slug}"), format!("claude/memory/{rest}"))
    } else if let Some(rest) = key.strip_prefix(".claude/") {
        (String::new(), format!("claude/{rest}"))
    } else if let Some(rest) = key.strip_prefix(".codex/") {
        (String::new(), format!("codex/{rest}"))
    } else if let Some(rest) = key.strip_prefix(".gemini/") {
        (String::new(), format!("gemini/{rest}"))
    } else {
        return None;
    };
    service_takes(&project, &path).then_some((project, path))
}

/// The home path for a service entry; `None` for one this side never
/// carries (another project id form, `cmux/context.md`, a refused name).
pub(super) fn from_service(project: &str, path: &str) -> Option<String> {
    if !service_takes(project, path) {
        return None;
    }
    let key = if project.is_empty() {
        let (tool, rest) = path.split_once('/')?;
        if !matches!(tool, "claude" | "codex" | "gemini") {
            return None;
        }
        format!(".{tool}/{rest}")
    } else {
        let slug = project.strip_prefix("local:")?;
        let rest = path.strip_prefix("claude/memory/")?;
        format!(".claude/projects/{slug}/memory/{rest}")
    };
    (carried(&key)
        && to_service(&key).as_ref().map(|(p, q)| (p.as_str(), q.as_str()))
            == Some((project, path)))
    .then_some(key)
}

/// The service's allowlist (cmux-platform `agent-home/Rules.ts`): the
/// user-wide instruction files, and a project's memory. One path it refuses
/// refuses the whole proposal, so none is ever sent.
fn service_takes(project: &str, path: &str) -> bool {
    let base = path.rsplit('/').next().unwrap_or_default().to_ascii_lowercase();
    if [".pfx", ".jks", ".keystore", ".pem", ".key", ".p12"].iter().any(|end| base.ends_with(end)) {
        return false;
    }
    let under = |prefix: &str| path.strip_prefix(prefix).is_some_and(|rest| !rest.is_empty());
    if project.is_empty() {
        return matches!(path, "claude/CLAUDE.md" | "codex/AGENTS.md" | "gemini/GEMINI.md")
            || path.strip_prefix("claude/agents/").is_some_and(|name| {
                name.len() > 3 && !name.contains('/') && name.ends_with(".md")
            })
            || under("claude/commands/")
            || under("claude/skills/")
            || under("codex/prompts/");
    }
    under("claude/memory/")
}

#[derive(Deserialize)]
struct WireHead {
    #[serde(default = "on")]
    follow: bool,
    #[serde(default)]
    generation: u64,
    #[serde(default)]
    revision: u64,
    #[serde(default)]
    entries: Vec<WireEntry>,
}

fn on() -> bool {
    true
}

#[derive(Deserialize)]
struct WireEntry {
    #[serde(default)]
    project: String,
    path: String,
    sha256: String,
}

/// The `AgentHome` service as a [`Head`].
pub(crate) struct HttpHead {
    origin: String,
    token: String,
    capability: Option<String>,
    http: reqwest::Client,
    runtime: tokio::runtime::Runtime,
    /// `put_blob`'s bytes by hash, sent inline with the proposal.
    pending: Mutex<BTreeMap<String, Vec<u8>>>,
    grant: Mutex<Option<String>>,
}

impl HttpHead {
    /// `origin` from [`origin_of`]; `capability` makes this a machine.
    pub(crate) fn new(origin: &str, token: &str, capability: Option<&str>) -> anyhow::Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
        let http = cmux_egress::client_builder("cmux_tui::link::sync_cli::memory_http")
            .default_headers(cmux_build_space::headers()?)
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
            .timeout(Duration::from_secs(60))
            .build()?;
        if let Some(capability) = capability
            && !capability.starts_with("ahc_")
        {
            bail!("CMUX_AGENT_HOME_CAPABILITY is a memory capability (ahc_…)");
        }
        Ok(Self {
            origin: origin.trim_end_matches('/').to_string(),
            token: token.to_string(),
            capability: capability.map(str::to_string),
            http,
            runtime,
            pending: Mutex::default(),
            grant: Mutex::default(),
        })
    }

    fn machine(&self) -> bool {
        self.capability.is_some()
    }

    /// One request: its status and body.
    fn send(
        &self,
        method: Method,
        path: &str,
        body: Option<&Value>,
        grant: Option<&str>,
    ) -> anyhow::Result<(StatusCode, Vec<u8>)> {
        let mut request = self
            .http
            .request(method.clone(), format!("{}{ROOT}{path}", self.origin))
            .bearer_auth(&self.token);
        if let Some(capability) = &self.capability {
            request = request.header("x-agent-home-capability", capability);
        }
        if let Some(grant) = grant {
            request = request.header("x-agent-home-grant", grant);
        }
        if let Some(body) = body {
            request = request.json(body);
        }
        self.runtime.block_on(async {
            let response =
                request.send().await.with_context(|| format!("{method} {ROOT}{path}"))?;
            let status = response.status();
            let bytes = response.bytes().await.with_context(|| format!("{method} {ROOT}{path}"))?;
            Ok((status, bytes.to_vec()))
        })
    }

    /// A JSON request; a refusal is an error naming the service's code.
    fn call(&self, method: Method, path: &str, body: Option<&Value>) -> anyhow::Result<Value> {
        let (status, bytes) = self.send(method.clone(), path, body, None)?;
        let value: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        if !status.is_success() {
            bail!("{method} {ROOT}{path}: {}", refusal(status, &value));
        }
        Ok(value)
    }

    fn fresh_grant(&self) -> anyhow::Result<String> {
        let issued = self.call(Method::POST, "/grants", Some(&json!({})))?;
        let token = issued["token"].as_str().context("the grant answer has no token")?.to_string();
        *self.grant.lock().unwrap_or_else(|poison| poison.into_inner()) = Some(token.clone());
        Ok(token)
    }

    /// The person accepts proposal `id` at head `revision`: an acceptance
    /// token, then accept. The new head revision. A machine is refused
    /// (`agent_home.person_only`); [`Head::accept_own`] never asks it to.
    pub(crate) fn accept(&self, id: &str, revision: u64) -> anyhow::Result<u64> {
        if id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
            bail!("not a proposal id: {id}");
        }
        let issued =
            self.call(Method::POST, &format!("/proposals/{id}/acceptance"), Some(&json!({})))?;
        let token = issued["token"].as_str().context("the acceptance answer has no token")?;
        let done = self.call(
            Method::POST,
            "/accept",
            Some(&json!({"proposal": id, "token": token, "revision": revision})),
        )?;
        done["revision"].as_u64().context("the accept answer has no revision")
    }
}

/// `STATUS code: message` from a refusal's body.
fn refusal(status: StatusCode, value: &Value) -> String {
    let code = value
        .get("code")
        .or_else(|| value.pointer("/error/code"))
        .and_then(Value::as_str)
        .unwrap_or("no code");
    let message = value
        .get("message")
        .or_else(|| value.pointer("/error/message"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    format!("{} {code}: {message}", status.as_u16())
}

impl Head for HttpHead {
    fn read(&self) -> anyhow::Result<HeadRead> {
        let value = self.call(Method::GET, "", None)?;
        let wire: WireHead = serde_json::from_value(value).context("the head answer")?;
        if !wire.follow {
            return Ok(HeadRead { generation: wire.generation, head: None });
        }
        let mut manifest = Manifest::new();
        for entry in wire.entries {
            let hash_ok =
                entry.sha256.len() == 64 && entry.sha256.bytes().all(|b| b.is_ascii_hexdigit());
            if let Some(key) = from_service(&entry.project, &entry.path)
                && hash_ok
            {
                manifest
                    .insert(key, Item { sha256: entry.sha256.to_ascii_lowercase(), mode: 0o644 });
            }
        }
        Ok(HeadRead {
            generation: wire.generation,
            head: Some(Accepted { revision: wire.revision, manifest }),
        })
    }

    fn blob(&self, _generation: u64, sha256: &str) -> anyhow::Result<Option<Vec<u8>>> {
        if sha256.len() != 64 || !sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            bail!("not a blob hash: {sha256}");
        }
        let held = self.grant.lock().unwrap_or_else(|poison| poison.into_inner()).clone();
        let mut grant = match held {
            Some(grant) => grant,
            None => self.fresh_grant()?,
        };
        let path = format!("/blobs/{sha256}");
        for attempt in 0..2 {
            let (status, bytes) = self.send(Method::GET, &path, None, Some(&grant))?;
            match status {
                StatusCode::OK => return Ok((sha256_hex(&bytes) == sha256).then_some(bytes)),
                StatusCode::NOT_FOUND => return Ok(None),
                // The grant ran out: one more with a new one.
                StatusCode::FORBIDDEN if attempt == 0 => grant = self.fresh_grant()?,
                status => {
                    let value: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
                    bail!("GET {ROOT}{path}: {}", refusal(status, &value));
                }
            }
        }
        bail!("GET {ROOT}{path}: refused twice")
    }

    fn put_blob(&self, _generation: u64, bytes: &[u8]) -> anyhow::Result<String> {
        let sha256 = sha256_hex(bytes);
        self.pending
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .insert(sha256.clone(), bytes.to_vec());
        Ok(sha256)
    }

    fn propose(&self, proposal: &Proposal) -> anyhow::Result<String> {
        let pending = self.pending.lock().unwrap_or_else(|poison| poison.into_inner()).clone();
        let mut changes = Vec::new();
        for (key, item) in &proposal.patch {
            let (project, path) = to_service(key)
                .with_context(|| format!("{key}: the AgentHome service does not carry it"))?;
            match item {
                Some(item) => {
                    let bytes = pending
                        .get(&item.sha256)
                        .with_context(|| format!("{key}: its bytes were not kept"))?;
                    changes.push(json!({
                        "project": project,
                        "path": path,
                        "op": "put",
                        "bytes": base64::engine::general_purpose::STANDARD.encode(bytes),
                        "sha256": item.sha256,
                        "size": bytes.len(),
                    }));
                }
                None => changes.push(json!({"project": project, "path": path, "op": "delete"})),
            }
        }
        let body = json!({
            "generation": proposal.generation,
            "base": proposal.base_revision,
            "changes": changes,
        });
        let answer = self.call(Method::POST, "/proposals", Some(&body))?;
        let id = answer["id"].as_str().context("the proposal answer has no id")?;
        Ok(id.to_string())
    }

    fn keeps_modes(&self) -> bool {
        false
    }

    fn takes(&self, key: &str) -> bool {
        // A machine proposes memory only; an instruction file from it would
        // refuse the whole proposal (`agent_home.instructions_from_machine`).
        to_service(key).is_some_and(|(project, _)| !(self.machine() && project.is_empty()))
    }

    fn accept_own(&self, id: &str, base_revision: u64) -> anyhow::Result<Option<u64>> {
        if self.machine() {
            return Ok(None);
        }
        self.accept(id, base_revision)
            .with_context(|| format!("proposal {id} is waiting; accepting it here failed"))
            .map(Some)
    }
}

#[cfg(test)]
#[path = "memory_http_tests.rs"]
mod tests;
