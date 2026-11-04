//! The MCP connections the person approved (plans/cmux-next/mcp-connect-DESIGN.md section 2), and
//! the audit log of what happened to them (T16).
//!
//! - `<home>/mcp/connections.json` (0600 in a 0700 folder) holds each [`Connection`]: the server,
//!   who gets it (the scope the person picked), the pinned tools and each tool's policy, and the
//!   state. Never a secret: a key or token lives in `mcp_secrets.rs`, named by the record's id.
//! - `<home>/mcp/audit.jsonl` is hash-chained: each line has the sha256 of the line before, so a
//!   removed or edited line shows. A line holds names and digests, never an argument, a result,
//!   a key or a token.
//! - A daemon whose store is in memory (tests) keeps both in memory.
//! - Every change bumps a version that `mcp-proxy` watches (`_acpmux/mcp_watch`), so a running
//!   agent's tool list changes in the same chat (MCP `notifications/tools/list_changed`).

use super::mcp_secrets::McpSecrets;
use crate::no_panic::{JsonExt as _, JsonField as _};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Mutex as StdMutex;

/// The most connections a daemon keeps.
pub(crate) const MAX_CONNECTIONS: usize = 200;
/// Audit lines a memory daemon keeps.
const MEMORY_AUDIT_LINES: usize = 1000;

/// One approved server. Field names are the wire's (`_acpmux/mcp_connections`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Connection {
    /// `mcp_` and 16 hex digits.
    pub id: String,
    /// `[a-z0-9-]`: the prefix of its tools for the agent (`linear__create_issue`).
    pub name: String,
    pub title: String,
    pub publisher: String,
    pub verified: bool,
    pub url: String,
    /// `none`, `key`, `oauth` or `discover` (a custom server's sign-in, learned at connect).
    pub auth: String,
    /// The header a key goes in (`key` auth).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_name: Option<String>,
    /// Whether the secret store holds a key or tokens for it (never the value).
    #[serde(default)]
    pub has_secret: bool,
    /// `chat`, `chief`, `allChiefs`, `agents` or `everywhere`: the person's pick on the card.
    pub scope: String,
    /// The chat (`chat`) or the first chat of its tree (`chief`) the scope names; empty when wider.
    #[serde(default)]
    pub owner: String,
    /// Each approved tool's sha256 (`cmux_mcp_connect::pin`), by name.
    #[serde(default)]
    pub tool_pin: BTreeMap<String, String>,
    /// `always`, `ask` or `never`, by tool name.
    #[serde(default)]
    pub tool_policy: BTreeMap<String, String>,
    /// The approved tools as the server listed them (name, description, inputSchema, annotations).
    #[serde(default)]
    pub tools: Vec<Value>,
    /// `connected`, `needsSignIn`, `needsKey`, `failed` or `revoked`.
    pub state: String,
    /// The server's RFC 9728 metadata URL, from its 401 (`oauth`/`discover`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource_metadata: Option<String>,
    #[serde(default)]
    pub challenge_scopes: Vec<String>,
    /// The OAuth client and endpoints the sign-in used (never a token).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oauth: Option<OauthClient>,
    pub added_at: u64,
    /// The chat whose agent asked.
    #[serde(default)]
    pub asked_by: String,
}

/// What a sign-in learned about the server's authorization server (public facts only).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OauthClient {
    pub issuer: String,
    pub token_endpoint: String,
    pub client_id: String,
    /// The RFC 8707 resource every token request names.
    pub resource: String,
    #[serde(default)]
    pub scopes: Vec<String>,
}

impl Connection {
    /// Whether the chat `session`, the first chat of its tree `root`, sees this connection.
    pub(crate) fn visible_to(&self, session: &str, root: &str) -> bool {
        match self.scope.as_str() {
            "chat" => self.owner == session,
            "chief" => self.owner == root,
            "allChiefs" | "agents" | "everywhere" => true,
            _ => false,
        }
    }

    /// The tools the agent may see: pinned, unchanged, and not `never`.
    pub(crate) fn listed_tools(&self) -> Vec<&Value> {
        let pin = cmux_mcp_connect::pin::ToolPin { tools: self.tool_pin.clone() };
        pin.approved(&self.tools)
            .into_iter()
            .filter(|t| {
                let name = t.field("name").as_str().unwrap_or_default();
                self.tool_policy.get(name).map(String::as_str).unwrap_or("ask") != "never"
            })
            .collect()
    }

    /// The tools listed now whose pin is missing or differs (new or changed after a key or a
    /// sign-in): held from the agent until the person approves them (`mcp_approve_tools`).
    pub(crate) fn held_tools(&self) -> Vec<String> {
        let diff =
            cmux_mcp_connect::pin::ToolPin { tools: self.tool_pin.clone() }.diff(&self.tools);
        diff.added.into_iter().chain(diff.changed).collect()
    }

    /// The row Settings and `mcp_list` show: no secret, no tool text. `held` names the tools that
    /// wait for the person's approval (`held_tools`).
    pub(crate) fn row(&self) -> Value {
        json!({
            "id": self.id, "name": self.name, "title": self.title, "publisher": self.publisher,
            "verified": self.verified, "url": self.url, "auth": self.auth, "scope": self.scope,
            "state": self.state, "hasSecret": self.has_secret, "addedAt": self.added_at,
            "tools": self.tools.iter().map(|t| {
                let name = t.field("name").as_str().unwrap_or_default();
                json!({
                    "name": name,
                    "policy": self.tool_policy.get(name).map(String::as_str).unwrap_or("ask"),
                })
            }).collect::<Vec<_>>(),
            "held": self.held_tools(),
        })
    }
}

/// A name an agent's tool can carry: lowercase `[a-z0-9-]`, at most 32 characters.
pub(crate) fn tool_prefix(name: &str) -> String {
    let mut out: String = name
        .to_ascii_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    out = out.trim_matches('-').to_owned();
    out.truncate(32);
    if out.is_empty() { "server".to_owned() } else { out }
}

pub(crate) fn new_id() -> String {
    // The first 64 bits of a connection nonce (the OS random generator; no randomness, no daemon).
    let nonce: String = super::person::new_nonce().chars().take(16).collect();
    format!("mcp_{nonce}")
}

struct Audit {
    file: Option<PathBuf>,
    seq: u64,
    prev: String,
    memory: Vec<Value>,
}

pub(crate) struct McpStore {
    dir: Option<PathBuf>,
    connections: StdMutex<Vec<Connection>>,
    pub(crate) secrets: McpSecrets,
    audit: StdMutex<Audit>,
    version: tokio::sync::watch::Sender<u64>,
    /// Each remote's MCP session id (`Mcp-Session-Id`), by connection id.
    pub(crate) remote_sessions: StdMutex<HashMap<String, String>>,
}

impl McpStore {
    /// A store under `<home>/mcp`, or in memory with `home` None.
    pub(crate) fn open(home: Option<&Path>) -> Self {
        let dir = home.map(|h| h.join("mcp"));
        let connections = dir
            .as_ref()
            .and_then(|d| std::fs::read(d.join("connections.json")).ok())
            .and_then(|bytes| serde_json::from_slice::<Vec<Connection>>(&bytes).ok())
            .unwrap_or_default();
        let (seq, prev) = dir
            .as_ref()
            .and_then(|d| std::fs::read_to_string(d.join("audit.jsonl")).ok())
            .and_then(|text| {
                let last: Value = serde_json::from_str(text.lines().last()?).ok()?;
                Some((last.field("seq").as_u64()?, last.field("hash").as_str()?.to_owned()))
            })
            .unwrap_or((0, String::new()));
        let secrets = match home {
            Some(h) => McpSecrets::for_home(h),
            None => McpSecrets::memory(),
        };
        Self {
            audit: StdMutex::new(Audit {
                file: dir.as_ref().map(|d| d.join("audit.jsonl")),
                seq,
                prev,
                memory: Vec::new(),
            }),
            dir,
            connections: StdMutex::new(connections),
            secrets,
            version: tokio::sync::watch::channel(0).0,
            remote_sessions: StdMutex::new(HashMap::new()),
        }
    }

    pub(crate) fn all(&self) -> Vec<Connection> {
        self.connections.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub(crate) fn get(&self, id: &str) -> Option<Connection> {
        self.connections
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .find(|c| c.id == id)
            .cloned()
    }

    /// The connections the chat `session` (first chat of its tree `root`) sees.
    pub(crate) fn visible(&self, session: &str, root: &str) -> Vec<Connection> {
        self.all().into_iter().filter(|c| c.visible_to(session, root)).collect()
    }

    pub(crate) fn version(&self) -> u64 {
        *self.version.borrow()
    }

    pub(crate) fn watch(&self) -> tokio::sync::watch::Receiver<u64> {
        self.version.subscribe()
    }

    /// Adds `conn`, replacing one with the same URL and the same scope owner (a second approval
    /// of one server is the newer word), then saves. Returns the id of a replaced record.
    pub(crate) fn add(&self, conn: Connection) -> Result<Option<String>, &'static str> {
        let replaced = {
            let mut list = self.connections.lock().unwrap_or_else(|e| e.into_inner());
            let old = list
                .iter()
                .position(|c| c.url == conn.url && c.scope == conn.scope && c.owner == conn.owner)
                .map(|i| list.remove(i).id);
            if list.len() >= MAX_CONNECTIONS {
                return Err("mcp.too_many_connections");
            }
            // One name per agent: a clash with another server gets a number.
            let base = conn.name.clone();
            let mut conn = conn;
            let mut n = 2;
            while list.iter().any(|c| c.name == conn.name) {
                conn.name = format!("{base}-{n}");
                n += 1;
            }
            list.push(conn);
            old
        };
        if let Some(old) = &replaced {
            let _ = self.secrets.delete(old);
            self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner()).remove(old);
        }
        self.save();
        Ok(replaced)
    }

    /// Changes the record `id` with `edit` and saves; false when there is none.
    pub(crate) fn update(&self, id: &str, edit: impl FnOnce(&mut Connection)) -> bool {
        let found = {
            let mut list = self.connections.lock().unwrap_or_else(|e| e.into_inner());
            match list.iter_mut().find(|c| c.id == id) {
                Some(c) => {
                    edit(c);
                    true
                }
                None => false,
            }
        };
        if found {
            self.save();
        }
        found
    }

    /// Removes `id` and its secret.
    pub(crate) fn remove(&self, id: &str) -> Option<Connection> {
        let gone = {
            let mut list = self.connections.lock().unwrap_or_else(|e| e.into_inner());
            list.iter().position(|c| c.id == id).map(|i| list.remove(i))
        };
        if gone.is_some() {
            let _ = self.secrets.delete(id);
            self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
            self.save();
        }
        gone
    }

    /// Writes the records (when on disk) and tells every watcher.
    fn save(&self) {
        if let Some(dir) = &self.dir {
            let list = self.all();
            if let Ok(bytes) = serde_json::to_vec_pretty(&list) {
                let _ = write_private(dir, "connections.json", &bytes);
            }
        }
        self.version.send_modify(|v| *v += 1);
    }

    /// Appends `event` to the audit log with its sequence number, time and hash chain.
    pub(crate) fn audit(&self, mut event: Value) {
        let mut audit = self.audit.lock().unwrap_or_else(|e| e.into_inner());
        audit.seq += 1;
        event.set("seq", json!(audit.seq));
        event.set("at", json!(crate::store::now_ms()));
        event.set("prev", json!(audit.prev));
        let hash = hex_sha256(event.to_string().as_bytes());
        event.set("hash", json!(hash));
        audit.prev = hash;
        match (&audit.file, &self.dir) {
            (Some(file), Some(dir)) => {
                let _ = append_private(dir, file, &event);
            }
            _ => {
                audit.memory.push(event);
                if audit.memory.len() > MEMORY_AUDIT_LINES {
                    audit.memory.remove(0);
                }
            }
        }
    }

    /// The newest `limit` audit lines, oldest first.
    pub(crate) fn audit_tail(&self, limit: usize) -> Vec<Value> {
        let audit = self.audit.lock().unwrap_or_else(|e| e.into_inner());
        let lines: Vec<Value> = match &audit.file {
            Some(file) => std::fs::read_to_string(file)
                .unwrap_or_default()
                .lines()
                .filter_map(|l| serde_json::from_str(l).ok())
                .collect(),
            None => audit.memory.clone(),
        };
        let skip = lines.len().saturating_sub(limit);
        lines.into_iter().skip(skip).collect()
    }
}

/// Whether `lines` form an unbroken chain: each `prev` is the hash of the line before, and each
/// `hash` is the sha256 of its line without the hash.
pub(crate) fn audit_chain_ok(lines: &[Value]) -> bool {
    let mut prev =
        lines.first().and_then(|l| l.field("prev").as_str()).unwrap_or_default().to_owned();
    for line in lines {
        if line.field("prev").as_str() != Some(prev.as_str()) {
            return false;
        }
        let mut body = line.clone();
        let Some(hash) = body.as_object_mut().and_then(|o| o.remove("hash")) else { return false };
        if hash.as_str() != Some(hex_sha256(body.to_string().as_bytes()).as_str()) {
            return false;
        }
        prev = hash.as_str().unwrap_or_default().to_owned();
    }
    true
}

pub(crate) fn hex_sha256(bytes: &[u8]) -> String {
    cmux_local_auth::frontend_proof::hex(&Sha256::digest(bytes))
}

#[cfg(unix)]
fn private_dir(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt as _, PermissionsExt as _};
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}

#[cfg(not(unix))]
fn private_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)
}

fn private_options() -> std::fs::OpenOptions {
    let mut options = std::fs::OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    options
}

/// `<dir>/<name>` written whole through a temporary file, 0600.
fn write_private(dir: &Path, name: &str, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    private_dir(dir)?;
    let tmp = dir.join(format!("{name}.tmp"));
    let _ = std::fs::remove_file(&tmp);
    let mut file = private_options().write(true).create_new(true).open(&tmp)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    std::fs::rename(&tmp, dir.join(name))
}

fn append_private(dir: &Path, file: &Path, line: &Value) -> std::io::Result<()> {
    use std::io::Write as _;
    private_dir(dir)?;
    let mut f = private_options().create(true).append(true).open(file)?;
    let mut text = line.to_string();
    text.push('\n');
    f.write_all(text.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn conn(url: &str, scope: &str, owner: &str) -> Connection {
        Connection {
            id: new_id(),
            name: "linear".into(),
            title: "Linear".into(),
            publisher: "linear.app".into(),
            verified: true,
            url: url.into(),
            auth: "oauth".into(),
            key_name: None,
            has_secret: false,
            scope: scope.into(),
            owner: owner.into(),
            tool_pin: BTreeMap::new(),
            tool_policy: BTreeMap::new(),
            tools: vec![],
            state: "connected".into(),
            resource_metadata: None,
            challenge_scopes: vec![],
            oauth: None,
            added_at: 1,
            asked_by: owner.into(),
        }
    }

    #[test]
    fn mcp_connect_scope_chat_is_one_chat_and_chief_is_its_tree() {
        let chat = conn("https://a/mcp", "chat", "s1");
        assert!(chat.visible_to("s1", "root"));
        assert!(!chat.visible_to("s2", "root"));
        let chief = conn("https://a/mcp", "chief", "root");
        assert!(chief.visible_to("s2", "root"));
        assert!(!chief.visible_to("s2", "other-root"));
        assert!(conn("https://a/mcp", "agents", "").visible_to("any", "any"));
        assert!(!conn("https://a/mcp", "bogus", "s1").visible_to("s1", "s1"));
    }

    #[test]
    fn mcp_connect_store_saves_no_secret_and_replaces_a_second_approval() {
        let home = std::env::temp_dir().join(format!("acpmux-mcp-store-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let store = McpStore::open(Some(&home));
        let first = conn("https://a/mcp", "chat", "s1");
        let first_id = first.id.clone();
        store.add(first).unwrap();
        store.secrets.put(&first_id, r#"{"key":"k-secret-value"}"#).unwrap();
        let v = store.version();
        let second = conn("https://a/mcp", "chat", "s1");
        assert_eq!(store.add(second).unwrap(), Some(first_id.clone()));
        assert!(store.version() > v, "a change bumps the version");
        assert!(store.secrets.get(&first_id).unwrap().is_none(), "the replaced key is deleted");
        let other = conn("https://b/mcp", "chat", "s1");
        store.add(other).unwrap();
        let names: Vec<String> = store.all().into_iter().map(|c| c.name).collect();
        assert_eq!(names, vec!["linear", "linear-2"]);
        let text = std::fs::read_to_string(home.join("mcp/connections.json")).unwrap();
        assert!(!text.contains("k-secret-value"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode =
                std::fs::metadata(home.join("mcp/connections.json")).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        assert_eq!(McpStore::open(Some(&home)).all().len(), 2, "records survive a restart");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn mcp_connect_audit_is_a_hash_chain_that_shows_an_edit() {
        let home = std::env::temp_dir().join(format!("acpmux-mcp-audit-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let store = McpStore::open(Some(&home));
        store.audit(json!({"event": "add", "id": "mcp_0123456789abcdef"}));
        store.audit(json!({"event": "call", "tool": "get_doc", "input": hex_sha256(b"{}")}));
        let reopened = McpStore::open(Some(&home));
        reopened.audit(json!({"event": "remove"}));
        let lines = reopened.audit_tail(10);
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[2]["seq"], 3);
        assert!(audit_chain_ok(&lines));
        let mut edited = lines.clone();
        edited[1]["tool"] = json!("delete_doc");
        assert!(!audit_chain_ok(&edited));
        let mut cut = lines.clone();
        cut.remove(1);
        assert!(!audit_chain_ok(&cut));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn mcp_connect_row_lists_new_and_changed_tools_as_held() {
        let tool = |name: &str, description: &str| json!({"name": name, "description": description, "inputSchema": {"type": "object"}});
        let mut c = conn("https://a/mcp", "chat", "s1");
        c.tools = vec![tool("get_doc", "Reads a doc"), tool("list_docs", "Lists docs")];
        c.tool_pin = cmux_mcp_connect::pin::ToolPin::of(&c.tools).tools;
        assert_eq!(c.row().get("held"), Some(&json!([])), "pinned tools are not held");
        c.tools = vec![
            tool("get_doc", "Reads a doc and sends it elsewhere"),
            tool("list_docs", "Lists docs"),
            tool("delete_doc", "Deletes a doc"),
        ];
        assert_eq!(
            c.row().get("held"),
            Some(&json!(["delete_doc", "get_doc"])),
            "added, then changed"
        );
        c.tool_pin = cmux_mcp_connect::pin::ToolPin::of(&c.tools).tools;
        assert_eq!(c.row().get("held"), Some(&json!([])), "approving pins the current text");
    }

    #[test]
    fn mcp_connect_tool_prefix_is_plain() {
        assert_eq!(tool_prefix("Linear"), "linear");
        assert_eq!(tool_prefix("127.0.0.1"), "127-0-0-1");
        assert_eq!(tool_prefix("__"), "server");
    }
}
