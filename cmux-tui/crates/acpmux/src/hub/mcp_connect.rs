//! An agent asks to connect an MCP server (plans/cmux-next/mcp-connect-DESIGN.md).
//!
//! The agent's `mcp_connect` tool calls `_acpmux/mcp_connect_request {sessionId, server, scope,
//! reason}`, which waits. The daemon resolves and checks the server first (`cmux-mcp-connect`: the
//! registry, the URL rules, the command rules); a refused or unknown input answers at once with
//! no card. Otherwise the chat shows a card from the `mcp_connect_request` record: the exact URL or
//! command, the publisher, Verified or not, the sign-in and its scopes, the proposed scope. The
//! person answers with `_acpmux/mcp_connect_answer`, accepted only from the person's connection
//! (`hub/person.rs`), so an agent, and so a prompt-injected "connect to X", can never approve its
//! own card (threat model T1, T2).
//!
//! - The scope is the person's choice; the agent's is only the proposal (T7).
//! - A chat has at most one open connect card: a new ask replaces it and the old asker gets
//!   `cancelled` (T18). A chat a remote device started asks for none (T17).
//! - A card nobody answers is cancelled after [`ASK_TTL`], and with the turn
//!   (`cancel_pending_mcp_connects`).
//! - No record holds a secret. A key comes only with the person's answer (the card's secure
//!   field), lives in memory for the first connect, and goes only into the server's own header.
//! - After an approval the daemon connects once (`mcp_probe`): the tools, screened and classed, or
//!   `signInNeeded` with the server's RFC 9728 metadata URL, go on the card and to the agent.

use super::{Hub, Session, SessionStatus};
use crate::rpc::RpcError;
use cmux_json::JsonSet as _;
use cmux_mcp_connect::registry::{AuthKind, Registry};
use cmux_mcp_connect::resolve::{Resolved, resolve};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Mutex as StdMutex;
use std::sync::atomic::Ordering;
use std::time::Duration;
use tokio::sync::oneshot;
use zeroize::Zeroizing;

pub(super) const ASK_TTL: Duration = Duration::from_secs(15 * 60);
const MAX_REASON_CHARS: usize = 300;
const MAX_INPUT_CHARS: usize = 2048;
/// The scopes a card offers, narrowest first (design section 2b).
pub const SCOPES: [&str; 5] = ["chat", "chief", "allChiefs", "agents", "everywhere"];

#[derive(Default)]
pub(crate) struct McpConnects {
    pending: StdMutex<HashMap<String, Pending>>,
}

struct Pending {
    session: String,
    reply: oneshot::Sender<Answer>,
}

/// The person's answer. `key` is what the person typed into the card's secure field: it goes
/// only into the server's own header, never a record, a reply or a log.
struct Answer {
    approve: bool,
    scope: String,
    key: Option<Zeroizing<String>>,
}

/// The longest key accepted, in characters.
const MAX_KEY_CHARS: usize = 4096;

/// `value[key]` without an index: `Null` for a missing key or a value that is not an object.
fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
    value.get(key).unwrap_or(&Value::Null)
}

fn auth_word(kind: AuthKind) -> &'static str {
    match kind {
        AuthKind::None => "none",
        AuthKind::Oauth => "oauth",
        AuthKind::Device => "device",
        AuthKind::Key => "key",
    }
}

/// The card's facts for a resolved server (never a secret).
fn card_of(resolved: &Resolved) -> Option<Value> {
    Some(match resolved {
        Resolved::Known { entry, target } => json!({
            "name": entry.name, "title": entry.title, "publisher": entry.publisher,
            "verified": resolved.verified(), "idn": target.idn,
            "transport": "remote", "url": target.url,
            "auth": auth_word(entry.auth), "scopes": entry.scopes,
            "keyName": entry.key_header, "keyOptional": entry.key_optional,
        }),
        Resolved::Remote { target } => json!({
            "name": target.host, "title": target.host, "publisher": target.publisher,
            "verified": false, "idn": target.idn, "loopback": target.loopback,
            "transport": "remote", "url": target.url,
            // A custom server's sign-in is learned from its metadata after the person approves,
            // so nothing is fetched from an unapproved host (T4).
            "auth": "discover", "scopes": [],
        }),
        Resolved::Local { command } => json!({
            "name": command.argv.first().map(|p| p.rsplit('/').next().unwrap_or(p)).unwrap_or_default(),
            "title": command.argv.first().cloned().unwrap_or_default(),
            "publisher": "this Mac", "verified": false, "idn": false,
            "transport": "local", "argv": command.argv, "fetchesCode": command.fetches_code,
            "auth": "none", "scopes": [],
        }),
        Resolved::Unknown { .. } => return None,
    })
}

impl Hub {
    /// The agent's ask: resolves `input`, shows the card, waits for the person. Returns
    /// `{status: approved, name, scope}`, `{status: declined|cancelled, name}`, or
    /// `{status: unknown, near}` with no card.
    pub async fn request_mcp_connect(
        &self,
        session: &Session,
        input: &str,
        proposed_scope: &str,
        reason: &str,
    ) -> Result<Value, RpcError> {
        if session.meta().remote_origin {
            return Err(RpcError::invalid_params(
                "a chat a remote device started connects no MCP servers",
            ));
        }
        if input.chars().count() > MAX_INPUT_CHARS {
            return Err(RpcError::invalid_params("the server input is too long"));
        }
        let resolved = resolve(input, &Registry::builtin())
            .map_err(|refusal| RpcError::invalid_params(refusal.0))?;
        let Some(mut card) = card_of(&resolved) else {
            let near = match resolved {
                Resolved::Unknown { near } => near,
                _ => Vec::new(),
            };
            return Ok(json!({"status": "unknown", "near": near}));
        };
        let name = field(&card, "name").as_str().unwrap_or_default().to_owned();
        let proposed = if SCOPES.contains(&proposed_scope) { proposed_scope } else { "chat" };
        let reason: String = reason.chars().take(MAX_REASON_CHARS).collect();
        let request_id = super::person::new_nonce();
        card.set("requestId", json!(request_id));
        card.set("reason", json!(reason));
        card.set("proposedScope", json!(proposed));
        card.set("scopesOffered", json!(SCOPES));
        let (tx, rx) = oneshot::channel();
        {
            let mut pending = self.mcp_connects.pending.lock().unwrap_or_else(|e| e.into_inner());
            // Dropping the old card's reply answers its asker `cancelled`.
            pending.retain(|_, p| p.session != session.id);
            pending.insert(request_id.clone(), Pending { session: session.id.clone(), reply: tx });
        }
        if session.closing.load(Ordering::SeqCst) || session.status() == SessionStatus::Closed {
            self.mcp_connects.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&request_id);
            return Ok(json!({"status": "cancelled", "name": name}));
        }
        self.append(session, "mux", "mcp_connect_request", card.clone());
        let prev = session.status();
        self.set_status(session, SessionStatus::Waiting);
        let mut answer = tokio::time::timeout(ASK_TTL, rx).await.ok().and_then(Result::ok);
        self.mcp_connects.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&request_id);
        let key = answer.as_mut().and_then(|a| a.key.take());
        let (status, scope) = match &answer {
            Some(Answer { approve: true, scope, .. }) => ("approved", Some(scope.clone())),
            Some(Answer { approve: false, .. }) => ("declined", None),
            None => ("cancelled", None),
        };
        self.append(
            session,
            "mux",
            "mcp_connect_decision",
            json!({"requestId": request_id, "name": name, "outcome": status, "scope": scope}),
        );
        if session.status() == SessionStatus::Waiting
            && session.permissions.lock().unwrap_or_else(|e| e.into_inner()).pending.is_empty()
            && !self.secrets.waiting_in(&session.id)
            && !self.mcp_connects.waiting_in(&session.id)
        {
            self.set_status(session, super::permissions::status_after_ask(session, prev));
        }
        let Some(scope) = scope else {
            return Ok(json!({"status": status, "name": name}));
        };
        let connected = self
            .first_connect(session, &request_id, &card, key.as_deref().map(String::as_str))
            .await;
        let store = self.mcp_store_dir().await;
        let kept = self.keep_in_shared_store(
            &store,
            session,
            &card,
            &scope,
            &connected,
            key.as_deref().map(String::as_str),
        );
        let mut reply = json!({"status": status, "name": name, "scope": scope});
        if let Some(kept) = kept {
            reply.set("kept", json!(kept));
        }
        if let (Value::Object(extra), Some(out)) = (connected, reply.as_object_mut()) {
            out.extend(extra);
        }
        Ok(reply)
    }

    /// After the person approves: connects once and lists the tools (`mcp_probe`), records the
    /// result on the card (`mcp_connect_result`) and answers the agent with names and policies.
    /// A server that wants a sign-in answers `connect: signInNeeded`; the sign-in runs on the
    /// person's side (Chief's `escalate_auth`), never with a token in the chat.
    async fn first_connect(
        &self,
        session: &Session,
        request_id: &str,
        card: &Value,
        key: Option<&str>,
    ) -> Value {
        let result = match field(card, "transport").as_str() {
            Some("remote") => {
                let url = field(card, "url").as_str().unwrap_or_default();
                let key_header =
                    match (field(card, "auth").as_str(), field(card, "keyName").as_str(), key) {
                        (Some("key"), Some(name), Some(value)) => {
                            Some(super::mcp_probe::KeyHeader { name, value })
                        }
                        _ => None,
                    };
                if *field(card, "auth") == "key"
                    && *field(card, "keyOptional") != json!(true)
                    && key_header.is_none()
                {
                    json!({"connect": "keyNeeded", "keyName": field(card, "keyName")})
                } else {
                    let keyed = key_header.is_some();
                    match super::mcp_probe::probe(url, key_header).await {
                        super::mcp_probe::Probe::Tools { tools, server } => {
                            let report = cmux_mcp_connect::wire::tool_report(&tools);
                            let pin = cmux_mcp_connect::pin::ToolPin::of(&tools);
                            json!({
                                "connect": "connected",
                                "server": server.get("name").cloned().unwrap_or(Value::Null),
                                "tools": report,
                                "pinned": pin.tools.len(),
                                "withKey": keyed,
                            })
                        }
                        super::mcp_probe::Probe::SignIn { resource_metadata, scopes } => json!({
                            "connect": "signInNeeded",
                            "auth": field(card, "auth"),
                            "resourceMetadata": resource_metadata,
                            "challengeScopes": scopes,
                        }),
                        super::mcp_probe::Probe::Failed(why) => {
                            json!({"connect": "failed", "why": why})
                        }
                    }
                }
            }
            // A local command runs only in the sandbox (design step 2b); it is not started here.
            _ => json!({"connect": "notStarted", "why": "local servers start in the sandbox step"}),
        };
        let mut record = result.clone();
        record.set("requestId", json!(request_id));
        record.set("name", field(card, "name").clone());
        self.append(session, "mux", "mcp_connect_result", record);
        result
    }

    /// The machine's store of MCP connections (cmux-mcp-connect `shared`), the one every Chief
    /// reads: config `mcpStore`, else `$CMUX_MCP_HOME`, else `<acpmux home>/mcp`.
    pub async fn mcp_store_dir(&self) -> std::path::PathBuf {
        let configured = self.config.read().await.mcp_store.clone();
        configured.unwrap_or_else(|| {
            cmux_mcp_connect::shared::dir(&crate::config::home(), &|k| std::env::var(k).ok())
        })
    }

    /// Keeps an approved remote server in the machine's store with the scope the person picked
    /// (`chat` for this chat, `chief` for the Chief it works for, ...), so the agents that scope
    /// names have it through `cmux mcp serve`'s `mcp_servers` tool, and a Chief's `mcp` finishes
    /// a sign-in it needs. Who sees it is `shared::visible`. A key the person typed goes to the
    /// 0600 secrets file only. A server of that name already there with another URL is left
    /// alone; one with this URL this chat already sees is kept as it is (it may be wider than
    /// this card); one it does not see takes this card's scope (the person's latest choice).
    /// Returns the store's name for it, or None when nothing was kept.
    fn keep_in_shared_store(
        &self,
        dir: &std::path::Path,
        session: &Session,
        card: &Value,
        scope: &str,
        connected: &Value,
        key: Option<&str>,
    ) -> Option<String> {
        use cmux_mcp_connect::shared;
        if field(card, "transport").as_str() != Some("remote") {
            return None;
        }
        let chief = shared::chief_of_session(&session.meta().name).map(str::to_owned);
        let viewer = shared::Viewer::Agent { session: session.id.clone(), chief: chief.clone() };
        // "This Chief" from a chat no Chief runs is this chat (fail closed, never every Chief).
        let (scope, owner) = match (scope, chief) {
            ("chat", _) | ("chief", None) => ("chat", Some(session.id.clone())),
            ("chief", Some(home)) => ("chief", Some(home)),
            (other, _) => (other, None),
        };
        let state = match field(connected, "connect").as_str() {
            Some("connected") => "connected",
            Some("signInNeeded") => "needs sign-in",
            _ => return None,
        };
        let url = field(card, "url").as_str()?;
        let name = shared::clean_name(field(card, "name").as_str()?);
        let path = shared::server_path(dir, &name);
        if let Some(old) =
            std::fs::read(&path).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        {
            if old.pointer("/transport/url").and_then(Value::as_str) != Some(url) {
                return None;
            }
            let sees = shared::visible(
                field(&old, "scope").as_str(),
                field(&old, "owner").as_str(),
                &viewer,
            );
            // Signed in already (by a Chief or an earlier card) and this chat has it.
            if sees && *field(&old, "state") == "connected" && state != "connected" {
                return Some(name);
            }
        }
        let secret_names: Vec<String> = match (key, field(card, "keyName").as_str()) {
            (Some(_), Some(header)) => vec![header.to_owned()],
            _ => Vec::new(),
        };
        let added_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX));
        let record = shared::Remote {
            name: &name,
            url,
            publisher: field(card, "publisher").as_str().unwrap_or_default(),
            verified: *field(card, "verified") == json!(true),
            added_by: "a cmux chat (connect card)",
            added_ms,
            state,
            scope: Some(scope),
            owner: owner.as_deref(),
            secret_names: &secret_names,
        }
        .record();
        if let (Some(value), Some(header)) = (key, field(card, "keyName").as_str()) {
            let secrets = shared::key_secrets(header, value);
            // The crate's private writer: a 0600 file in a 0700 folder, on Windows each with an
            // owner-only access list.
            crate::agent_tools::write_private(
                &shared::secrets_path(dir, &name),
                secrets.to_string().as_bytes(),
            )
            .ok()?;
        }
        let text = serde_json::to_vec_pretty(&record).ok()?;
        write_file(&path, &text, 0o644).ok()?;
        Some(name)
    }

    /// The person's answer to a connect card. `scope` is theirs (the card's menu); it must be one
    /// of [`SCOPES`].
    pub fn answer_mcp_connect(
        &self,
        session: &Session,
        request_id: &str,
        approve: bool,
        scope: Option<&str>,
        key: Option<Zeroizing<String>>,
    ) -> Result<(), RpcError> {
        if key
            .as_ref()
            .is_some_and(|k| k.chars().count() > MAX_KEY_CHARS || k.chars().any(char::is_control))
        {
            return Err(RpcError::invalid_params(
                "the key is too long or holds control characters",
            ));
        }
        let key = if approve { key } else { None };
        let scope = match (approve, scope) {
            (true, Some(s)) if SCOPES.contains(&s) => s.to_owned(),
            (true, _) => {
                return Err(RpcError::invalid_params(format!(
                    "an approval names its scope: one of {}",
                    SCOPES.join(", ")
                )));
            }
            (false, _) => String::new(),
        };
        let pending = {
            let mut map = self.mcp_connects.pending.lock().unwrap_or_else(|e| e.into_inner());
            match map.get(request_id) {
                Some(p) if p.session == session.id => map.remove(request_id),
                _ => None,
            }
        };
        let pending = pending.ok_or_else(|| {
            RpcError::invalid_params("no MCP connect card with that id in this chat")
        })?;
        pending
            .reply
            .send(Answer { approve, scope, key })
            .map_err(|_| RpcError::invalid_params("the agent stopped waiting for this card"))
    }

    /// Closes the session's open connect card with its turn: the asker gets `cancelled`.
    pub(super) fn cancel_pending_mcp_connects(&self, session: &Session) {
        self.mcp_connects
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|_, p| p.session != session.id);
    }
}

impl McpConnects {
    /// Whether `session` has an open connect card (the Waiting status stays for it).
    pub(super) fn waiting_in(&self, session: &str) -> bool {
        self.pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .any(|p| p.session == session)
    }
}

/// Writes `bytes` to `path` through a temporary file and a rename, with `mode` (the Unix file
/// mode; Windows has none). The home is checked first, as the secret's writer checks it: a home
/// that is gone gets no record. Each step then goes through the folder this daemon holds
/// (`home_fs`): a home replaced after that check never gets the file.
fn write_file(path: &std::path::Path, bytes: &[u8], mode: u32) -> std::io::Result<()> {
    use std::io::Write as _;
    crate::config::refuse_lost_home(path).map_err(std::io::Error::other)?;
    let dir = path.parent().ok_or_else(|| std::io::Error::other("no folder"))?;
    crate::home_fs::create_dirs(dir)?;
    let tmp = dir.join(format!(
        ".{}.acpmux.{}.tmp",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("f"),
        std::process::id()
    ));
    let mut f = crate::home_fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(mode)
        .open(&tmp)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    crate::home_fs::rename(&tmp, path)
}

#[cfg(all(test, unix))]
mod tests {
    use super::{Hub, write_file};
    use crate::agent_tools::write_private;
    use serde_json::{Value, json};
    use std::os::unix::fs::PermissionsExt as _;

    fn mode(path: &std::path::Path) -> std::io::Result<u32> {
        Ok(std::fs::metadata(path)?.permissions().mode() & 0o777)
    }

    #[test]
    fn mcp_connect_a_secret_is_a_0600_file_in_a_0700_folder() -> anyhow::Result<()> {
        let tmp = tempfile::tempdir()?;
        let secrets = tmp.path().join("secrets");
        let secret = secrets.join("a.json");
        // The store writes a secret with the crate's private writer (`keep_in_shared_store`).
        write_private(&secret, b"one")?;
        // A second write replaces the file and leaves no temporary file beside it.
        write_private(&secret, b"two")?;
        assert_eq!(std::fs::read(&secret)?, b"two");
        assert_eq!(mode(&secret)?, 0o600);
        assert_eq!(mode(&secrets)?, 0o700);
        assert_eq!(std::fs::read_dir(&secrets)?.count(), 1);
        // A record is not a secret. The process's umask can take bits from 0644, never add any.
        let servers = tmp.path().join("servers");
        let record = servers.join("a.json");
        write_file(&record, b"{}", 0o644)?;
        write_file(&record, b"[]", 0o644)?;
        assert_eq!(std::fs::read(&record)?, b"[]");
        assert_eq!(mode(&record)? & !0o644, 0);
        assert_eq!(mode(&record)? & 0o600, 0o600);
        assert_eq!(std::fs::read_dir(&servers)?.count(), 1);
        Ok(())
    }

    /// The store's own choice of writer for a card with a key (`keep_in_shared_store`): the key
    /// goes to the 0600 secrets file in the 0700 folder only, and the record names the key's
    /// header, never its value.
    #[tokio::test]
    async fn mcp_connect_a_key_card_keeps_its_key_in_a_0600_file_and_its_name_in_the_record()
    -> anyhow::Result<()> {
        use cmux_mcp_connect::shared;
        let mut config = crate::config::Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent"))?;
        let hub = Hub::new(config, store);
        let session = hub.insert_test_session(serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "chat", "name": "worker", "harness": "fake",
            "cwd": "/tmp", "status": "waiting", "createdAt": 1, "updatedAt": 1
        }))?);
        let tmp = tempfile::tempdir()?;
        let card = json!({
            "transport": "remote", "name": "keyed", "url": "https://mcp.example/mcp",
            "publisher": "example", "verified": false, "keyName": "x-api-key"
        });
        let connected = json!({"connect": "connected"});
        let kept = hub.keep_in_shared_store(
            tmp.path(),
            &session,
            &card,
            "agents",
            &connected,
            Some("k-1"),
        );
        assert_eq!(kept.as_deref(), Some("keyed"));
        let secret = shared::secrets_path(tmp.path(), "keyed");
        assert_eq!(mode(&secret)?, 0o600);
        assert_eq!(mode(&tmp.path().join("secrets"))?, 0o700);
        let secrets: Value = serde_json::from_slice(&std::fs::read(&secret)?)?;
        assert_eq!(secrets, json!({"headers": {"x-api-key": "k-1"}}));
        let record = std::fs::read_to_string(shared::server_path(tmp.path(), "keyed"))?;
        let saved: Value = serde_json::from_str(&record)?;
        assert_eq!(saved["secret_names"], json!(["x-api-key"]), "{saved}");
        assert!(!record.contains("k-1"), "the record holds the key's value: {record}");
        Ok(())
    }

    /// A record held at the end of its home check while the home is replaced: the write lands in
    /// the folder this daemon holds, and the new home gets nothing.
    #[test]
    fn mcp_connect_a_record_held_past_its_home_check_stays_out_of_a_replaced_home() {
        use crate::lost_home_race_tests::{forced, isolated, nothing};
        isolated(
            module_path!(),
            "mcp_connect_a_record_held_past_its_home_check_stays_out_of_a_replaced_home",
            |home| {
                let path = home.join("mcp").join("servers").join("a.json");
                forced(home, path.clone(), nothing, Some("mcp/servers/a.json"), move || {
                    let _ = write_file(&path, b"{}", 0o644);
                });
            },
            |_, _| {},
        );
    }
}
