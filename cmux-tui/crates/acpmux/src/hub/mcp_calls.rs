//! An approved MCP connection at work (plans/cmux-next/mcp-connect-DESIGN.md sections 5 and 6):
//! the record the person's approval keeps, the tools a chat sees, and each tool call, which the
//! daemon makes itself so no key or token leaves it.
//!
//! - `acpmux mcp-proxy` (`mcp_proxy.rs`) is the agent's one MCP server for connections. It proves
//!   its chat with the caller token (`hub/person.rs` (a)) and asks the daemon for the chat's tools
//!   (`_acpmux/mcp_tools`), calls them (`_acpmux/mcp_call`), and waits for a change
//!   (`_acpmux/mcp_watch`) to tell the agent its list changed.
//! - A chat sees a connection only in the scope the person picked (T7): `chat` is that chat,
//!   `chief` the chats of its tree, wider scopes every local chat. A chat a remote device started
//!   sees none (T17).
//! - Only pinned, unchanged tools are listed or called (T10); a `never` tool is neither. An `ask`
//!   tool shows the person a card (`mcp_call_request`) that only the person answers, once or
//!   always (T11).
//! - The daemon adds the key or token to its own request (T5); the agent gets the server's result.
//! - Each add, call, policy change and removal goes to the audit log with digests only (T16).

use super::mcp_connect::{Answer, Pending};
use super::mcp_probe::{Called, KeyHeader, call_tool};
use super::mcp_store::{Connection, hex_sha256, new_id, tool_prefix};
use super::{Hub, Session, SessionStatus};
use crate::no_panic::{JsonExt as _, JsonField as _};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use tokio::sync::oneshot;
use zeroize::Zeroizing;

/// The longest tool name an agent takes (Claude Code's limit, its prefix included).
const MAX_TOOL_NAME: usize = 64;
/// The longest tool description passed on.
const MAX_DESCRIPTION_CHARS: usize = 2000;
/// The arguments a call card shows, at most.
const MAX_CARD_ARGUMENT_CHARS: usize = 2000;

fn error_result(text: impl Into<String>) -> Value {
    json!({"content": [{"type": "text", "text": text.into()}], "isError": true})
}

/// The `name` an agent sees for `tool` of the connection named `prefix`.
fn agent_tool_name(prefix: &str, tool: &str) -> Option<String> {
    let name = format!("{prefix}__{tool}");
    (name.len() <= MAX_TOOL_NAME
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-'))
    .then_some(name)
}

/// The header that carries a connection's secret, from its stored JSON.
fn auth_header(conn: &Connection, secret: &str) -> Option<(String, Zeroizing<String>)> {
    let value = super::mcp_secrets::StoredSecret::parse(secret);
    if let Some(token) = value.access_token.as_deref() {
        return Some(("authorization".to_owned(), Zeroizing::new(format!("Bearer {token}"))));
    }
    let key = value.key.as_deref()?;
    let name = conn.key_name.clone().unwrap_or_else(|| "authorization".to_owned());
    Some((name, Zeroizing::new(key.to_owned())))
}

impl Hub {
    /// The first chat of `session`'s tree: the scope `chief` names it.
    pub(super) fn mcp_root_of(&self, session: &Session) -> String {
        let mut id = session.id.clone();
        let mut parent = session.meta().parent_id;
        for _ in 0..32 {
            let Some(p) = parent else { break };
            match self.resolve(&p) {
                Ok(s) => {
                    id = s.id.clone();
                    parent = s.meta().parent_id;
                }
                Err(_) => {
                    id = p;
                    break;
                }
            }
        }
        id
    }

    /// Keeps what the person approved as a connection record (and the key in the secret store),
    /// from the first connect's `result`. Takes the tool definitions off `result`. Returns the
    /// record's id, or None for a server that is not kept (a failure, a local command).
    pub(super) fn keep_connection(
        &self,
        session: &Session,
        card: &Value,
        scope: &str,
        result: &mut Value,
        key: Option<&str>,
    ) -> Option<String> {
        let tools: Vec<Value> = result
            .as_object_mut()
            .and_then(|o| o.remove("_tools"))
            .and_then(|t| serde_json::from_value(t).ok())
            .unwrap_or_default();
        let state = match result.field("connect").as_str()? {
            "connected" => "connected",
            "signInNeeded" => "needsSignIn",
            "keyNeeded" => "needsKey",
            _ => return None,
        };
        let url = card.field("url").as_str()?.to_owned();
        let id = new_id();
        let report = cmux_mcp_connect::wire::tool_report(&tools);
        let tool_policy: BTreeMap<String, String> = report
            .iter()
            .filter_map(|t| {
                Some((t.field("name").as_str()?.to_owned(), t.field("policy").as_str()?.to_owned()))
            })
            .collect();
        let owner = match scope {
            "chat" => session.id.clone(),
            "chief" => self.mcp_root_of(session),
            _ => String::new(),
        };
        let has_secret = match key {
            Some(k) => {
                let secret = Zeroizing::new(json!({"key": k}).to_string());
                if self.mcp_store.secrets.put(&id, &secret).is_err() {
                    result.set("connect", json!("failed"));
                    result.set("why", json!("the key could not be saved in the keychain"));
                    return None;
                }
                true
            }
            None => false,
        };
        let conn = Connection {
            id: id.clone(),
            name: tool_prefix(card.field("name").as_str().unwrap_or("server")),
            title: card.field("title").as_str().unwrap_or_default().to_owned(),
            publisher: card.field("publisher").as_str().unwrap_or_default().to_owned(),
            verified: *card.field("verified") == true,
            url,
            auth: card.field("auth").as_str().unwrap_or("none").to_owned(),
            key_name: card.field("keyName").as_str().map(str::to_owned),
            has_secret,
            scope: scope.to_owned(),
            owner,
            tool_pin: cmux_mcp_connect::pin::ToolPin::of(&tools).tools,
            tool_policy,
            tools,
            state: state.to_owned(),
            resource_metadata: result.field("resourceMetadata").as_str().map(str::to_owned),
            challenge_scopes: result
                .field("challengeScopes")
                .as_array()
                .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                .unwrap_or_default(),
            oauth: None,
            added_at: crate::store::now_ms(),
            asked_by: session.id.clone(),
        };
        let name = conn.name.clone();
        if self.mcp_store.add(conn).is_err() {
            let _ = self.mcp_store.secrets.delete(&id);
            return None;
        }
        // The stored name may carry a number (two servers, one name).
        let name = self.mcp_store.get(&id).map(|c| c.name).unwrap_or(name);
        result.set("toolPrefix", json!(name));
        self.mcp_store.audit(json!({
            "event": "add", "id": id, "name": name, "url": card.field("url"), "scope": scope,
            "state": state, "session": session.id, "withKey": has_secret,
        }));
        Some(id)
    }

    /// `_acpmux/mcp_tools`: the tools `session` sees, named `<connection>__<tool>`, and the
    /// version to watch.
    pub(crate) fn mcp_tools(&self, session: &Session) -> Value {
        let version = self.mcp_store.version();
        if session.meta().remote_origin {
            return json!({"version": version, "tools": []});
        }
        let root = self.mcp_root_of(session);
        let mut tools = Vec::new();
        for conn in self.mcp_store.visible(&session.id, &root) {
            if conn.state != "connected" {
                continue;
            }
            for tool in conn.listed_tools() {
                let Some(name) =
                    agent_tool_name(&conn.name, tool.field("name").as_str().unwrap_or(""))
                else {
                    continue;
                };
                let description: String = tool
                    .field("description")
                    .as_str()
                    .unwrap_or_default()
                    .chars()
                    .take(MAX_DESCRIPTION_CHARS)
                    .collect();
                let mut out = json!({
                    "name": name,
                    "description": format!("[{} MCP server] {description}", conn.title),
                    "inputSchema": tool.get("inputSchema").filter(|s| s.is_object()).cloned()
                        .unwrap_or_else(|| json!({"type": "object"})),
                });
                if let Some(a) = tool.get("annotations").filter(|a| a.is_object()) {
                    out.set("annotations", a.clone());
                }
                tools.push(out);
            }
        }
        json!({"version": version, "tools": tools})
    }

    /// `_acpmux/mcp_connections` for an agent's chat: what it sees, without secrets or tool text.
    pub(crate) fn mcp_list_for(&self, session: &Session) -> Value {
        let root = self.mcp_root_of(session);
        let rows: Vec<Value> = if session.meta().remote_origin {
            Vec::new()
        } else {
            self.mcp_store.visible(&session.id, &root).iter().map(Connection::row).collect()
        };
        json!({"connections": rows})
    }

    /// `_acpmux/mcp_call`: runs the agent's tool `name` (`<connection>__<tool>`) and returns the
    /// MCP tool result, or an error result that says why it did not run.
    pub(crate) async fn mcp_call(
        self: &Arc<Self>,
        session: &Arc<Session>,
        name: &str,
        arguments: Value,
    ) -> Value {
        if session.meta().remote_origin {
            return error_result("a chat a remote device started has no MCP connections");
        }
        let Some((prefix, tool)) = name.split_once("__") else {
            return error_result(format!("no connected MCP tool is named {name}"));
        };
        let root = self.mcp_root_of(session);
        let Some(conn) =
            self.mcp_store.visible(&session.id, &root).into_iter().find(|c| c.name == prefix)
        else {
            return error_result(format!("no connected MCP server is named {prefix} in this chat"));
        };
        if conn.state != "connected" {
            return error_result(format!(
                "{} is not connected ({}): the person must sign in again in Settings > MCP Servers",
                conn.title, conn.state
            ));
        }
        if !conn.listed_tools().iter().any(|t| *t.field("name") == tool) {
            return error_result(format!(
                "{tool} of {} is not approved (new, changed or off); the person reviews it in \
                 Settings > MCP Servers",
                conn.title
            ));
        }
        let input = hex_sha256(arguments.to_string().as_bytes());
        let audit = |outcome: &str, output: Option<&Value>| {
            self.mcp_store.audit(json!({
                "event": "call", "id": conn.id, "name": conn.name, "tool": tool,
                "session": session.id, "input": input,
                "output": output.map(|o| hex_sha256(o.to_string().as_bytes())),
                "outcome": outcome,
            }));
        };
        if conn.tool_policy.get(tool).map(String::as_str).unwrap_or("ask") == "ask" {
            match self.ask_mcp_call(session, &conn, tool, &arguments).await {
                Some(true) => {}
                Some(false) => {
                    audit("declined", None);
                    return error_result("The user declined this tool call.");
                }
                None => {
                    audit("cancelled", None);
                    return error_result(
                        "The tool call card closed before the user answered (the turn stopped).",
                    );
                }
            }
        }
        let secret = if conn.has_secret {
            match self.mcp_secret_for_call(&conn).await {
                Ok(Some(s)) => Some(s),
                Ok(None) => {
                    audit("noSecret", None);
                    return error_result(format!(
                        "{}'s key or sign-in is gone from the keychain: the person must sign in again",
                        conn.title
                    ));
                }
                Err("mcp.sign_in_expired") => {
                    audit("signInNeeded", None);
                    return error_result(format!(
                        "{}'s sign-in expired. The person signs in again (Settings > MCP Servers); \
                         never ask for a token or code.",
                        conn.title
                    ));
                }
                Err(code) => {
                    audit("secretUnreadable", None);
                    return error_result(format!("the keychain did not answer ({code})"));
                }
            }
        } else {
            None
        };
        let header = secret.as_deref().and_then(|s| auth_header(&conn, s));
        let key = header.as_ref().map(|(n, v)| KeyHeader { name: n.as_str(), value: v.as_str() });
        let session_id = self
            .mcp_store
            .remote_sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&conn.id)
            .cloned();
        let (called, kept) = call_tool(&conn.url, key, session_id, tool, &arguments).await;
        {
            let mut sessions =
                self.mcp_store.remote_sessions.lock().unwrap_or_else(|e| e.into_inner());
            match kept {
                Some(s) => sessions.insert(conn.id.clone(), s),
                None => sessions.remove(&conn.id),
            };
        }
        match called {
            Called::Result(result) => {
                audit(
                    if *result.field("isError") == true { "toolError" } else { "ok" },
                    Some(&result),
                );
                result
            }
            Called::SignIn { resource_metadata, scopes } => {
                self.mcp_store.update(&conn.id, |c| {
                    c.state = "needsSignIn".to_owned();
                    if resource_metadata.is_some() {
                        c.resource_metadata = resource_metadata;
                    }
                    c.challenge_scopes = scopes;
                });
                audit("signInNeeded", None);
                error_result(format!(
                    "{} wants a new sign-in. The person signs in on their side (Settings > MCP \
                     Servers, or the card); never ask for a token or code.",
                    conn.title
                ))
            }
            Called::Failed(why) => {
                audit("failed", None);
                error_result(format!("{}: {why}", conn.title))
            }
        }
    }

    /// The card for an `ask` tool: Some(true) to run, Some(false) declined, None closed.
    async fn ask_mcp_call(
        &self,
        session: &Session,
        conn: &Connection,
        tool: &str,
        arguments: &Value,
    ) -> Option<bool> {
        let request_id = super::person::new_nonce();
        let (tx, rx) = oneshot::channel();
        self.mcp_connects.pending.lock().unwrap_or_else(|e| e.into_inner()).insert(
            request_id.clone(),
            Pending { session: session.id.clone(), reply: tx, call: true },
        );
        let mut shown = arguments.to_string();
        if shown.chars().count() > MAX_CARD_ARGUMENT_CHARS {
            shown = shown.chars().take(MAX_CARD_ARGUMENT_CHARS).collect::<String>() + "…";
        }
        let kind = cmux_mcp_connect::wire::tool_report(
            &conn.tools.iter().filter(|t| *t.field("name") == tool).cloned().collect::<Vec<_>>(),
        )
        .first()
        .map(|r| r.field("kind").clone())
        .unwrap_or(Value::Null);
        self.append(
            session,
            "mux",
            "mcp_call_request",
            json!({
                "requestId": request_id, "connectionId": conn.id, "name": conn.name,
                "title": conn.title, "publisher": conn.publisher, "verified": conn.verified,
                "tool": tool, "kind": kind, "arguments": shown,
            }),
        );
        let prev = session.status();
        self.set_status(session, SessionStatus::Waiting);
        let answer =
            tokio::time::timeout(super::mcp_connect::ASK_TTL, rx).await.ok().and_then(Result::ok);
        self.mcp_connects.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&request_id);
        let outcome = match &answer {
            Some(Answer { approve: true, scope, .. }) if scope == "always" => "always",
            Some(Answer { approve: true, .. }) => "once",
            Some(Answer { approve: false, .. }) => "declined",
            None => "cancelled",
        };
        if outcome == "always" {
            self.mcp_store.update(&conn.id, |c| {
                c.tool_policy.insert(tool.to_owned(), "always".to_owned());
            });
            self.mcp_store.audit(json!({
                "event": "policy", "id": conn.id, "tool": tool, "policy": "always", "by": "person",
            }));
        }
        self.append(
            session,
            "mux",
            "mcp_call_decision",
            json!({"requestId": request_id, "tool": tool, "outcome": outcome}),
        );
        if session.status() == SessionStatus::Waiting
            && session.permissions.lock().unwrap_or_else(|e| e.into_inner()).pending.is_empty()
            && !self.secrets.waiting_in(&session.id)
            && !self.mcp_connects.waiting_in(&session.id)
        {
            self.set_status(session, super::permissions::status_after_ask(session, prev));
        }
        answer.map(|a| a.approve)
    }

    /// The person's answer to a tool call card: run it `once`, run it `always` (the policy
    /// becomes `always`), or decline.
    pub fn answer_mcp_call(
        &self,
        session: &Session,
        request_id: &str,
        approve: bool,
        always: bool,
    ) -> Result<(), RpcError> {
        let pending = {
            let mut map = self.mcp_connects.pending.lock().unwrap_or_else(|e| e.into_inner());
            match map.get(request_id) {
                Some(p) if p.session == session.id && p.call => map.remove(request_id),
                _ => None,
            }
        };
        let pending = pending.ok_or_else(|| {
            RpcError::invalid_params("no MCP tool call card with that id in this chat")
        })?;
        let scope = if always { "always" } else { "once" }.to_owned();
        pending
            .reply
            .send(Answer { approve, scope, key: None })
            .map_err(|_| RpcError::invalid_params("the agent stopped waiting for this card"))
    }

    /// The person's list of every connection (Settings > MCP Servers).
    pub fn mcp_connections_all(&self) -> Value {
        json!({
            "connections": self.mcp_store.all().iter().map(Connection::row).collect::<Vec<_>>(),
            "secretStore": self.mcp_store.secrets.kind(),
        })
    }

    /// The person removes a connection and its secret.
    pub fn mcp_remove(&self, id: &str) -> Result<Value, RpcError> {
        let gone = self
            .mcp_store
            .remove(id)
            .ok_or_else(|| RpcError::invalid_params("no MCP connection with that id"))?;
        self.mcp_store
            .audit(json!({"event": "remove", "id": id, "name": gone.name, "by": "person"}));
        Ok(json!({"removed": id}))
    }

    /// The person sets one tool's policy: `always`, `ask` or `never`.
    pub fn mcp_set_policy(&self, id: &str, tool: &str, policy: &str) -> Result<Value, RpcError> {
        if !matches!(policy, "always" | "ask" | "never") {
            return Err(RpcError::invalid_params("policy is one of always, ask, never"));
        }
        let known = self
            .mcp_store
            .get(id)
            .is_some_and(|c| c.tools.iter().any(|t| *t.field("name") == tool));
        if !known {
            return Err(RpcError::invalid_params("no such tool on that MCP connection"));
        }
        self.mcp_store.update(id, |c| {
            c.tool_policy.insert(tool.to_owned(), policy.to_owned());
        });
        self.mcp_store.audit(json!({
            "event": "policy", "id": id, "tool": tool, "policy": policy, "by": "person",
        }));
        Ok(json!({}))
    }

    /// The person gives (or replaces) a key for a `key` connection: kept in the secret store,
    /// then the server is listed again with it.
    pub async fn mcp_set_key(&self, id: &str, key: Zeroizing<String>) -> Result<Value, RpcError> {
        let conn = self
            .mcp_store
            .get(id)
            .ok_or_else(|| RpcError::invalid_params("no MCP connection with that id"))?;
        if key.is_empty() || key.chars().count() > 4096 || key.chars().any(char::is_control) {
            return Err(RpcError::invalid_params(
                "the key is empty, too long or has control characters",
            ));
        }
        let name = conn.key_name.clone().unwrap_or_else(|| "authorization".to_owned());
        let probe = super::mcp_probe::probe(
            &conn.url,
            Some(KeyHeader { name: &name, value: key.as_str() }),
        )
        .await;
        let super::mcp_probe::Probe::Tools { tools, .. } = probe else {
            return Ok(json!({"connect": "failed", "why": "the server did not accept the key"}));
        };
        let secret = Zeroizing::new(json!({"key": key.as_str()}).to_string());
        self.mcp_store.secrets.put(id, &secret).map_err(|code| {
            RpcError::invalid_params(format!("the keychain refused the key ({code})"))
        })?;
        self.relist(id, tools);
        self.mcp_store.audit(json!({"event": "key", "id": id, "by": "person"}));
        Ok(json!({"connect": "connected", "id": id}))
    }

    /// Records a fresh tool list for `id` after the person signed in or gave a key: tools the
    /// pin does not know are pinned with their starting policy (the person just approved the
    /// server again); state `connected`.
    pub(super) fn relist(&self, id: &str, tools: Vec<Value>) {
        let report = cmux_mcp_connect::wire::tool_report(&tools);
        self.mcp_store.update(id, |c| {
            for t in &report {
                if let (Some(name), Some(policy)) =
                    (t.field("name").as_str(), t.field("policy").as_str())
                {
                    c.tool_policy.entry(name.to_owned()).or_insert_with(|| policy.to_owned());
                }
            }
            c.tool_pin = cmux_mcp_connect::pin::ToolPin::of(&tools).tools;
            c.tools = tools;
            c.has_secret = true;
            c.state = "connected".to_owned();
        });
    }

    /// The newest audit lines (the person's view).
    pub fn mcp_audit(&self, limit: usize) -> Value {
        json!({"lines": self.mcp_store.audit_tail(limit.clamp(1, 1000))})
    }
}
