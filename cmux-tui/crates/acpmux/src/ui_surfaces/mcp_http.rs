//! The MCP Apps host fetch: a streamable-HTTP MCP client (initialize, tools/list,
//! resources/read, tools/call) for the servers a chat's agent config names, with a per-server
//! cache of its tools and `ui://` resources. stdio servers are not fetched (design, "Not in the
//! prototype"). Everything here runs on the runtime, never on the tap.

use cmux_ui_surfaces::mcp_apps::{self, ResourceView, ToolInfo};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_secs(10);
/// A server whose fetch failed is not tried again for this long.
const RETRY_MS: u64 = 60_000;
const PROTOCOL: &str = "2025-06-18";

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ServerConf {
    pub url: String,
    pub headers: Vec<(String, String)>,
}

/// An HTTP server from its config entry (`{type: "http"|"streamable-http"|"sse", url, headers}`
/// or Codex's `{url, http_headers}`); None for stdio or anything else.
pub(crate) fn server_conf(entry: &Value) -> Option<ServerConf> {
    let ty = entry.get("type").and_then(Value::as_str).unwrap_or("");
    if entry.get("command").is_some()
        || !matches!(ty, "" | "http" | "streamable-http" | "streamableHttp")
    {
        return None;
    }
    let url = entry.get("url").and_then(Value::as_str)?;
    if !(url.starts_with("https://")
        || url.starts_with("http://127.0.0.1")
        || url.starts_with("http://localhost"))
    {
        return None;
    }
    let headers = entry
        .get("headers")
        .or_else(|| entry.get("http_headers"))
        .and_then(Value::as_object)
        .map(|h| h.iter().filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string()))).collect())
        .unwrap_or_default();
    Some(ServerConf { url: url.to_string(), headers })
}

#[derive(Default)]
struct Cached {
    conf: Option<ServerConf>,
    tools: Option<Vec<ToolInfo>>,
    resources: HashMap<String, ResourceView>,
    inflight: bool,
    failed_at: u64,
}

fn cache() -> &'static Mutex<HashMap<String, Cached>> {
    static C: OnceLock<Mutex<HashMap<String, Cached>>> = OnceLock::new();
    C.get_or_init(Default::default)
}

fn key(harness: &str, cwd: &Path, server: &str) -> String {
    format!("{harness}\u{0}{}\u{0}{server}", cwd.display())
}

/// Servers a test names, read before the agent's config.
#[cfg(test)]
pub(crate) static TEST_CONF: Mutex<Vec<(String, ServerConf)>> = Mutex::new(Vec::new());

fn find_conf(harness: &str, cwd: &Path, server: &str) -> Option<ServerConf> {
    #[cfg(test)]
    if let Some((_, conf)) =
        TEST_CONF.lock().unwrap_or_else(|e| e.into_inner()).iter().find(|(s, _)| s == server)
    {
        return Some(conf.clone());
    }
    let env = crate::desktop_link::Env::current().ok()?;
    server_conf(&crate::desktop_link::read_mcp_server(&env, harness, cwd, server)?)
}

/// The cached view for `tool` on `server`: its resource URI, the view, and the server's tools
/// (for the bridge's visibility check). None when not cached yet.
pub(crate) fn cached_view(
    harness: &str,
    cwd: &Path,
    server: &str,
    tool: &str,
) -> Option<(String, ResourceView, Vec<ToolInfo>)> {
    let c = cache().lock().unwrap_or_else(|e| e.into_inner());
    let entry = c.get(&key(harness, cwd, server))?;
    let tools = entry.tools.as_ref()?;
    let ui = tools.iter().find(|t| t.name == tool)?.ui.as_ref()?;
    let view = entry.resources.get(&ui.resource_uri)?;
    Some((ui.resource_uri.clone(), view.clone(), tools.clone()))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// Start fetching `server`'s tools and every `ui://` resource they name, unless that is cached,
/// running, or failed in the last minute. Returns at once: the fetch runs on `spawn`'s owner
/// (the hub's scope), and a fetch its owner drops before it ends leaves the server unfetched.
pub(crate) fn prefetch(harness: &str, cwd: &Path, server: &str, spawn: &super::Spawn) {
    let k = key(harness, cwd, server);
    {
        let mut c = cache().lock().unwrap_or_else(|e| e.into_inner());
        let e = c.entry(k.clone()).or_default();
        if e.inflight || e.tools.is_some() || now_ms().saturating_sub(e.failed_at) < RETRY_MS {
            return;
        }
        e.inflight = true;
    }
    /// Clears the server's `inflight` however its fetch ends, a drop included.
    struct Inflight(String);
    impl Drop for Inflight {
        fn drop(&mut self) {
            if let Some(e) = cache().lock().unwrap_or_else(|e| e.into_inner()).get_mut(&self.0) {
                e.inflight = false;
            }
        }
    }
    let inflight = Inflight(k.clone());
    let (harness, cwd, server) = (harness.to_string(), cwd.to_path_buf(), server.to_string());
    spawn(Box::pin(async move {
        let _inflight = inflight;
        let fetched = fetch_all(&harness, &cwd, &server).await;
        let ok = {
            let mut c = cache().lock().unwrap_or_else(|e| e.into_inner());
            let e = c.entry(k).or_default();
            e.inflight = false;
            match fetched {
                Ok((conf, tools, resources)) => {
                    e.conf = Some(conf);
                    e.tools = Some(tools);
                    e.resources = resources;
                    true
                }
                Err(err) => {
                    tracing::info!(server, err, "ui surface: MCP App fetch failed");
                    e.failed_at = now_ms();
                    false
                }
            }
        };
        if ok {
            // The calls that waited for this server's views draw now (a late surface).
            super::late_views();
        }
    }));
}

type Fetched = (ServerConf, Vec<ToolInfo>, HashMap<String, ResourceView>);

async fn fetch_all(harness: &str, cwd: &Path, server: &str) -> Result<Fetched, String> {
    let conf = find_conf(harness, cwd, server)
        .ok_or_else(|| format!("{server} is not an HTTP MCP server in the agent's config"))?;
    let mut client = Client::connect(&conf).await?;
    let tools = mcp_apps::tools_from_list(&client.request("tools/list", json!({})).await?);
    let mut resources = HashMap::new();
    for uri in tools.iter().filter_map(|t| t.ui.as_ref()).map(|u| u.resource_uri.clone()) {
        if resources.contains_key(&uri) || resources.len() >= 16 {
            continue;
        }
        let read = client.request("resources/read", json!({"uri": uri})).await?;
        match mcp_apps::resource_view(&read, None) {
            Ok(view) => {
                resources.insert(uri, view);
            }
            Err(e) => tracing::info!(server, uri, "ui surface: resource refused: {e}"),
        }
    }
    Ok((conf, tools, resources))
}

fn conf_for(harness: &str, cwd: &Path, server: &str) -> Result<ServerConf, String> {
    let cached = cache()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&key(harness, cwd, server))
        .and_then(|e| e.conf.clone());
    cached
        .or_else(|| find_conf(harness, cwd, server))
        .ok_or_else(|| format!("{server} is not an HTTP MCP server in the agent's config"))
}

/// `resources/read` on `server` (the view's own `ui://` reads).
pub(crate) async fn read_resource(
    harness: &str,
    cwd: &Path,
    server: &str,
    uri: &str,
) -> Result<Value, String> {
    let conf = conf_for(harness, cwd, server)?;
    Client::connect(&conf).await?.request("resources/read", json!({"uri": uri})).await
}

/// `tools/call` on `server`, after the person confirmed it.
pub(crate) async fn call_tool(
    harness: &str,
    cwd: &Path,
    server: &str,
    tool: &str,
    arguments: Value,
) -> Result<Value, String> {
    let conf = conf_for(harness, cwd, server)?;
    Client::connect(&conf)
        .await?
        .request("tools/call", json!({"name": tool, "arguments": arguments}))
        .await
}

struct Client {
    http: reqwest::Client,
    conf: ServerConf,
    session: Option<String>,
    next_id: u64,
}

impl Client {
    async fn connect(conf: &ServerConf) -> Result<Client, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let http = reqwest::Client::builder()
            // timeout: one MCP request to a server the agent's config names, off the tap
            .timeout(TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|e| format!("cannot make the client: {e}"))?;
        let mut c = Client { http, conf: conf.clone(), session: None, next_id: 0 };
        c.request(
            "initialize",
            json!({"protocolVersion": PROTOCOL,
                   "capabilities": {"extensions": mcp_apps::client_extension()},
                   "clientInfo": {"name": "cmux", "version": crate::build_info::VERSION}}),
        )
        .await?;
        c.post(json!({"jsonrpc": "2.0", "method": "notifications/initialized"})).await?;
        Ok(c)
    }

    async fn post(&mut self, body: Value) -> Result<Option<Value>, String> {
        let mut req = self
            .http
            .post(&self.conf.url)
            .header("accept", "application/json, text/event-stream")
            .header("mcp-protocol-version", PROTOCOL)
            .json(&body);
        for (k, v) in &self.conf.headers {
            req = req.header(k.as_str(), v.as_str());
        }
        if let Some(s) = &self.session {
            req = req.header("mcp-session-id", s.as_str());
        }
        let resp = req.send().await.map_err(|e| format!("request failed: {e}"))?;
        if let Some(s) = resp.headers().get("mcp-session-id").and_then(|v| v.to_str().ok()) {
            self.session = Some(s.to_string());
        }
        let status = resp.status();
        let sse = resp
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|t| t.starts_with("text/event-stream"));
        let text = resp.text().await.map_err(|e| format!("reading the answer: {e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}"));
        }
        if text.trim().is_empty() {
            return Ok(None);
        }
        Ok(Some(parse_body(&text, sse, body.get("id"))?))
    }

    async fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        self.next_id += 1;
        let id = self.next_id;
        let answer = self
            .post(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}))
            .await?
            .ok_or_else(|| format!("{method}: no answer"))?;
        if let Some(err) = answer.get("error") {
            return Err(format!(
                "{method}: {}",
                err.get("message").and_then(Value::as_str).unwrap_or("error")
            ));
        }
        answer.get("result").cloned().ok_or_else(|| format!("{method}: no result"))
    }
}

/// The JSON-RPC answer in a body: plain JSON, or the SSE event whose data carries `id`.
pub(crate) fn parse_body(text: &str, sse: bool, id: Option<&Value>) -> Result<Value, String> {
    if !sse {
        return serde_json::from_str(text).map_err(|e| format!("not JSON: {e}"));
    }
    let mut data = String::new();
    let mut found = None;
    for line in text.lines().chain(std::iter::once("")) {
        if let Some(d) = line.strip_prefix("data:") {
            data.push_str(d.trim_start());
        } else if line.is_empty() && !data.is_empty() {
            if let Ok(v) = serde_json::from_str::<Value>(&data)
                && (id.is_none() || v.get("id") == id)
            {
                found = Some(v);
            }
            data.clear();
        }
    }
    found.ok_or_else(|| "no answer in the event stream".into())
}
