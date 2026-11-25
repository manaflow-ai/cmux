//! `github_status`, a tool of the `acpmux` MCP server every harness gets (`agent_tools.rs`): which
//! GitHub account the person connected, so a chat with no project or repository can answer "can
//! you see my GitHub?" with the login and how cmux knows it.
//!
//! It answers `{connected, login, name?, htmlUrl?, accountType?, source, via: "cmux", accounts}`
//! and never a token: `accounts` is every connected account the sources below name, each with
//! its `source`, and the top-level fields are the first. The sources:
//!
//! 1. On a cmux Cloud machine (`cloud_repo_mcp::is_cloud_machine`), the machine's Cloud agent
//!    (root) over its socket: `{"github_status": {}}`, which it turns into `GET /v1/me/github` on
//!    cmux-platform with the machine's own bearer (`cmux_host::cloud::github_status`). This
//!    process never holds that bearer.
//! 2. With a cmux sign-in on this daemon (`meshRelay` with a token command, the same sign-in the
//!    artifact tools use), `GET /v1/me/github` with it: the account the cmux team connected. The
//!    connection is the team's GitHub App installation, so its login may be an organization's
//!    (`accountType`), which the answer says rather than calling it the person.
//! 3. This machine's own `gh` login (the person's own; first on a machine that is not Cloud): `gh api user`, run here with every GitHub token removed from
//!    its env (`github_broker::login_env`), so `gh` reads only its own keyring or hosts file.
//!
//! Every answer goes through the same field check (`cmux_host::cloud::github_status::sanitize`):
//! a login, a display name and github.com URLs only, and nothing that looks like a credential.
//! The harness's own env never gets a GitHub token (`login_env.rs`); this changes nothing there.

use std::ffi::OsString;
use std::path::PathBuf;
use std::time::Duration;

use cmux_host::cloud::github_status::sanitize;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use zeroize::Zeroizing;

/// The tool's name in the `acpmux` server (folded behind `cmux`: `acpmux_github_status`).
pub const TOOL: &str = "github_status";

/// What a chat with the tool is told, in the server's instructions and `cmux_exec`'s description.
pub const STEER: &str = "When the person asks about their GitHub (can you see my GitHub, which \
account, is it connected), call github_status first, instead of running gh (`gh auth status`, \
`gh api user`) or reading git config: it also covers cmux Cloud machines and the GitHub account \
their cmux team connected, which gh may not see with no repository picked. It lists the GitHub \
accounts cmux can see for this chat and how cmux checked each, with no token. Answer with those \
logins and say they are connected through cmux; an organization account is the one their cmux \
team connected, not the person.";

/// The Cloud agent's socket (`cmux_host::cloud::wire::AGENT_SOCKET`).
pub const CLOUD_AGENT_SOCKET: &str = "/run/cmux-vm-agent/agent.sock";
/// The cmux-platform route.
pub const STATUS_PATH: &str = cmux_host::cloud::github_status::STATUS_PATH;

/// Each source's bound: together well under the shortest harness MCP timeout (Codex: 60 s).
const CLOUD_WAIT: Duration = Duration::from_secs(15);
const PLATFORM_WAIT: Duration = Duration::from_secs(8);
const GH_WAIT: Duration = Duration::from_secs(8);
const REPLY_MAX: usize = 64 * 1024;

pub fn definition() -> Value {
    json!({
        "name": TOOL,
        "description": "Which GitHub account the person connected to cmux, if any: the login, name and profile URL, and how cmux knows it (the cmux GitHub App, cmux's GitHub sign-in, or this machine's GitHub CLI login). Call it when the person asks whether you can see their GitHub or which account is connected. It never returns a token, and works with no project or repository.",
        "inputSchema": {"type": "object", "properties": {}}
    })
}

/// A cmux sign-in for the platform read: its origin and how to get the bearer.
pub struct Platform {
    pub origin: String,
    pub bearer: Bearer,
}

pub enum Bearer {
    /// The relay's sign-in, minted by its token command (`mesh_http::HttpHub`).
    Hub(Box<crate::mesh_http::HttpHub>),
    #[cfg(test)]
    Fixed(String),
}

impl Bearer {
    async fn get(&self) -> Option<std::sync::Arc<Zeroizing<String>>> {
        match self {
            Self::Hub(hub) => hub.token(false).await.ok(),
            #[cfg(test)]
            Self::Fixed(token) => Some(std::sync::Arc::new(Zeroizing::new(token.clone()))),
        }
    }
}

/// Where this machine looks, in order.
#[derive(Default)]
pub struct Sources {
    pub cloud_socket: Option<PathBuf>,
    pub platform: Option<Platform>,
    /// The `gh` program to run; `None` skips it.
    pub gh: Option<OsString>,
}

impl Sources {
    /// This machine's sources: the Cloud agent on a Cloud machine, the daemon's cmux sign-in
    /// when it has one, and `gh` on the PATH.
    pub fn current() -> Self {
        let cloud = crate::cloud_repo_mcp::is_cloud_machine();
        Self {
            cloud_socket: cloud.then(|| PathBuf::from(CLOUD_AGENT_SOCKET)),
            platform: if cloud { None } else { platform_from_config() },
            gh: Some(OsString::from("gh")),
        }
    }
}

/// The daemon's cmux sign-in, as the artifact tools find it, without their on/off setting.
fn platform_from_config() -> Option<Platform> {
    let text = std::fs::read_to_string(crate::config::Config::path()).ok()?;
    let (config, relay) = crate::acpmux_mcp::artifacts::settings_from(&text);
    let relay = relay?;
    let signed_in = relay.credential.as_deref() != Some("join")
        && relay.token_command.first().is_some_and(|p| !p.trim().is_empty())
        && relay.origin().is_ok();
    if !signed_in {
        return None;
    }
    let hub = crate::mesh_http::HttpHub::new(&relay).ok()?;
    let env = std::env::var(crate::acpmux_mcp::artifacts::API_ENV).ok();
    let origin = crate::acpmux_mcp::artifacts::base_url(env.as_deref(), &config, Some(&relay));
    Some(Platform { origin, bearer: Bearer::Hub(Box::new(hub)) })
}

/// The tool's answer: every connected account the sources name, each labelled by its source,
/// in this machine's order (the Cloud agent first on a Cloud machine; `gh`, the person's own
/// login, first elsewhere), the first one also at the top level; else not connected.
pub async fn resolve(sources: &Sources) -> Value {
    let cloud = async {
        match &sources.cloud_socket {
            Some(socket) => from_cloud(socket).await,
            None => None,
        }
    };
    let platform = async {
        match &sources.platform {
            Some(platform) => from_platform(platform).await,
            None => None,
        }
    };
    let gh = async {
        match &sources.gh {
            Some(gh) => from_gh(gh).await,
            None => None,
        }
    };
    let (cloud, platform, gh) = tokio::join!(cloud, platform, gh);
    // A cmux source that was asked and gave no answer (unreachable, refused, timed out) is not
    // "not connected": with no account found, the answer says the check failed.
    let unavailable = (sources.cloud_socket.is_some() && cloud.is_none())
        || (sources.platform.is_some() && platform.is_none());
    let cmux_first = sources.cloud_socket.is_some();
    let ordered = if cmux_first { [cloud, gh, platform] } else { [gh, cloud, platform] };
    let accounts: Vec<Value> =
        ordered.into_iter().flatten().filter(connected).map(account).collect();
    let mut seen = std::collections::BTreeSet::new();
    let accounts: Vec<Value> = accounts
        .into_iter()
        .filter(|a| seen.insert((field(a, "login").to_string(), field(a, "source").to_string())))
        .collect();
    let Some(first) = accounts.first() else {
        let mut out = json!({"connected": false, "source": "none", "via": "cmux", "accounts": []});
        if unavailable {
            out.set("unavailable", json!(true));
        }
        return out;
    };
    let mut out = first.clone();
    out.set("connected", json!(true));
    out.set("via", json!("cmux"));
    out.set("accounts", Value::Array(accounts));
    out
}

/// `value[key]` without an index: `Null` for a missing key or a value that is not an object.
fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
    value.get(key).unwrap_or(&Value::Null)
}

fn connected(status: &Value) -> bool {
    status.get("connected").and_then(Value::as_bool) == Some(true)
}

/// One account: only the checked fields and its source (a cmux connection unless it says
/// otherwise; `from_gh` labels its own).
fn account(status: Value) -> Value {
    let mut out = json!({});
    for key in ["login", "name", "htmlUrl", "accountType"] {
        if let Some(v) = status.get(key).filter(|v| v.is_string()) {
            out.set(key, v.clone());
        }
    }
    out.set("source", status.get("source").cloned().unwrap_or_else(|| json!("github-app")));
    out
}

/// How one account reads to the model.
fn describe(account: &Value) -> String {
    let login = field(account, "login").as_str().unwrap_or_default();
    let who = match field(account, "name").as_str() {
        Some(name) => format!("{login} ({name})"),
        None => login.to_owned(),
    };
    match (field(account, "source").as_str(), field(account, "accountType").as_str()) {
        (Some("gh-cli"), _) => {
            format!("{who}, the person's own GitHub CLI login on this machine, read by cmux")
        }
        (_, Some("organization")) => format!(
            "{who}, a GitHub organization the person's cmux team connected through the cmux              GitHub App (the organization, not the person's own account)"
        ),
        (Some("oauth"), _) => format!("{who}, connected to cmux through GitHub sign-in"),
        _ => format!("{who}, connected to cmux through the cmux GitHub App"),
    }
}

/// The MCP result: a sentence for the model and the object as `structuredContent`.
pub fn result(status: &Value) -> Value {
    let accounts = field(status, "accounts").as_array().cloned().unwrap_or_default();
    let text = if accounts.is_empty() && *field(status, "unavailable") == true {
        "cmux could not check the GitHub connection right now (its service did not answer), and \
         this machine has no GitHub CLI login. Say the connection could not be checked, not that \
         GitHub is disconnected, and suggest trying again."
            .to_owned()
    } else if accounts.is_empty() {
        "No GitHub account is connected to cmux for this chat, and this machine has no GitHub          CLI login. The person can connect GitHub in cmux Settings."
            .to_owned()
    } else {
        let lines: Vec<String> = accounts.iter().map(|a| format!("- {}", describe(a))).collect();
        format!(
            "GitHub accounts cmux can see for this chat:\n{}\ncmux checked each profile through              that connection; no token was shared with this chat.",
            lines.join("\n")
        )
    };
    json!({"content": [{"type": "text", "text": text}], "structuredContent": status, "isError": false})
}

/// The Cloud agent's answer (it already checked the fields; they are checked again here).
/// Cloud machines are Linux; elsewhere there is no agent socket.
#[cfg(not(unix))]
async fn from_cloud(_socket: &std::path::Path) -> Option<Value> {
    None
}

/// The Cloud agent's answer (it already checked the fields; they are checked again here).
#[cfg(unix)]
async fn from_cloud(socket: &std::path::Path) -> Option<Value> {
    use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};
    let ask = async {
        let mut stream = tokio::net::UnixStream::connect(socket).await.ok()?;
        let line = format!("{}\n", json!({cmux_host::cloud::github_status::REQUEST_KEY: {}}));
        stream.write_all(line.as_bytes()).await.ok()?;
        let mut reply = String::new();
        tokio::io::BufReader::new(stream)
            .take(REPLY_MAX as u64)
            .read_line(&mut reply)
            .await
            .ok()?;
        serde_json::from_str::<Value>(&reply).ok()
    };
    let reply = tokio::time::timeout(CLOUD_WAIT, ask).await.ok()??;
    (reply.get("ok").and_then(Value::as_bool) == Some(true)).then(|| sanitize(&reply))
}

/// `GET /v1/me/github` with the daemon's cmux sign-in. The bearer goes only to that origin.
async fn from_platform(platform: &Platform) -> Option<Value> {
    let read = async {
        let bearer = platform.bearer.get().await?;
        // reqwest is built without a default TLS provider (as `mesh_http::HttpHub::new` does).
        let _ = rustls::crypto::ring::default_provider().install_default();
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION")))
            .build()
            .ok()?;
        let res = http
            .get(format!("{}{STATUS_PATH}", platform.origin))
            .bearer_auth(bearer.as_str())
            .send()
            .await
            .ok()?;
        if !res.status().is_success() {
            return None;
        }
        let bytes = res.bytes().await.ok()?;
        if bytes.len() > REPLY_MAX {
            return None;
        }
        serde_json::from_slice::<Value>(&bytes).ok().filter(Value::is_object)
    };
    let body = tokio::time::timeout(PLATFORM_WAIT, read).await.ok()??;
    Some(sanitize(&body))
}

/// `gh api user`, with this machine's own login only.
async fn from_gh(gh: &OsString) -> Option<Value> {
    let mut command = std::process::Command::new(gh);
    command.args(["api", "user"]);
    crate::github_broker::login_env(&mut command, None);
    // The Cloud gh shim would answer from cmux's connection, which the Cloud source already
    // reports; this source is the person's own gh login only.
    command.env(cmux_host::cloud::github_status::GH_OWN_LOGIN_ONLY_ENV, "1");
    command
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null());
    let mut command = tokio::process::Command::from(command);
    command.kill_on_drop(true);
    let output = tokio::time::timeout(GH_WAIT, command.output()).await.ok()?.ok()?;
    if !output.status.success() || output.stdout.len() > REPLY_MAX {
        return None;
    }
    let user: Value = serde_json::from_slice(&output.stdout).ok()?;
    let login = user.get("login")?.clone();
    let body = json!({
        "connected": true,
        "login": login,
        "name": user.get("name").cloned().unwrap_or(Value::Null),
        "htmlUrl": user.get("html_url").cloned().unwrap_or(Value::Null),
    });
    let mut status = sanitize(&body);
    status.set("source", json!("gh-cli"));
    Some(status)
}

#[cfg(all(test, unix))]
#[path = "github_status_tests.rs"]
mod tests;
