//! The Chief view gallery's reads: the Fleet page's `data.json`, the Landing page's GitHub searches
//! (`ChiefViewsFeeds`) and the Agents page's rows (`ChiefViewsAgent`). Swift fetches; these shape.

use super::text::{trim, utc_day};
use crate::ops::{OpError, parse, reply};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;

pub const REPO: &str = "manaflow-ai/cmux";
pub const BASE: &str = "feat-cmux-next";
pub const PAGE_SIZE: usize = 60;
pub const LOCAL_MACHINE: &str = "local";

/// The parts of a URL these rules read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Url<'a> {
    pub scheme: &'a str,
    pub user: Option<&'a str>,
    pub password: Option<&'a str>,
    pub host: &'a str,
    pub path: &'a str,
    pub rest: &'a str,
}

/// A small RFC 3986 split, about what `URL(string:)` accepts for an absolute URL: no spaces or controls,
/// a scheme, and an authority after `//`.
pub fn parse_url(text: &str) -> Option<Url<'_>> {
    if text.is_empty()
        || text.chars().any(|c| {
            c.is_whitespace()
                || c.is_control()
                || matches!(c, '"' | '<' | '>' | '\\' | '^' | '`' | '{' | '|' | '}')
        })
    {
        return None;
    }
    let (scheme, after) = text.split_once(':')?;
    let mut sc = scheme.chars();
    if !sc.next()?.is_ascii_alphabetic()
        || !sc.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    {
        return None;
    }
    let Some(after) = after.strip_prefix("//") else {
        return Some(Url { scheme, user: None, password: None, host: "", path: after, rest: "" });
    };
    let end = after.find(['/', '?', '#']).unwrap_or(after.len());
    let (authority, tail) = after.split_at(end);
    let (userinfo, hostport) = match authority.rfind('@') {
        Some(at) => (Some(&authority[..at]), &authority[at + 1..]),
        None => (None, authority),
    };
    let (user, password) = match userinfo {
        None => (None, None),
        Some(info) => match info.split_once(':') {
            Some((u, p)) => (Some(u), Some(p)),
            None => (Some(info), None),
        },
    };
    let host = if let Some(inner) = hostport.strip_prefix('[') {
        let close = inner.find(']')?;
        let port = &inner[close + 1..];
        if !port.is_empty() && !port.starts_with(':') {
            return None;
        }
        &inner[..close]
    } else {
        let host = hostport.split(':').next().unwrap_or("");
        if let Some((_, port)) = hostport.split_once(':') {
            if !port.chars().all(|c| c.is_ascii_digit()) {
                return None;
            }
        }
        host
    };
    let path_end = tail.find(['?', '#']).unwrap_or(tail.len());
    let (path, rest) = tail.split_at(path_end);
    Some(Url { scheme, user, password, host, path, rest })
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = &bytes[i + 1..i + 3];
            if let Some(v) = std::str::from_utf8(hex)
                .ok()
                .filter(|h| h.bytes().all(|b| b.is_ascii_hexdigit()))
                .and_then(|h| u8::from_str_radix(h, 16).ok())
            {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// `ChiefViewsFeeds.fleetDataURL`: the fleet page's `data.json` under the link the person gave.
pub fn fleet_data_url(base: &str) -> String {
    let cut = base.find(['?', '#']).unwrap_or(base.len());
    let (head, rest) = base.split_at(cut);
    let last = head.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    if last == "data.json" {
        return base.to_string();
    }
    let joiner = if head.ends_with('/') { "" } else { "/" };
    format!("{head}{joiner}data.json{rest}")
}

/// `ChiefViewsFeeds.validFleetURL`: https anywhere, plain http only on this machine or a tailnet.
pub fn valid_fleet_url(text: &str) -> Option<String> {
    let trimmed = trim(text);
    let url = parse_url(trimmed)?;
    let scheme = url.scheme.to_ascii_lowercase();
    let host = url.host.to_ascii_lowercase();
    if host.is_empty() || url.user.is_some() || url.password.is_some() {
        return None;
    }
    let private =
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host.ends_with(".ts.net");
    (scheme == "https" || (scheme == "http" && private)).then(|| trimmed.to_string())
}

/// Swift `JSONValue.intValue`: a whole number below 1e15.
fn int_value(v: Option<&Value>) -> Option<i64> {
    let n = v?.as_f64()?;
    (n.round() == n && n.abs() < 1e15).then_some(n as i64)
}

fn number(v: Option<&Value>) -> Value {
    v.and_then(Value::as_f64).map_or(Value::Null, |n| json!(n))
}

fn string(v: Option<&Value>) -> Value {
    v.and_then(Value::as_str).map_or(Value::Null, |s| json!(s))
}

/// `ChiefViewsFeeds.fleetReply`: the Fleet page's machines, queue and recent PRs.
pub fn fleet_reply(root: &Value) -> Option<Value> {
    let minis = root.get("minis")?.as_array()?;
    let mut runners: HashMap<&str, (i64, i64)> = HashMap::new();
    for runner in root.get("runners").and_then(Value::as_array).into_iter().flatten() {
        let Some(host) = runner.get("host").and_then(Value::as_str) else { continue };
        let count = runners.entry(host).or_default();
        if runner.get("status").and_then(Value::as_str) == Some("online") {
            count.1 += 1;
            if runner.get("busy").and_then(Value::as_bool) == Some(true) {
                count.0 += 1;
            }
        }
    }
    let machines: Vec<Value> = minis
        .iter()
        .filter_map(|mini| {
            let host = mini.get("host")?.as_str()?;
            let (busy, online) = runners.get(host).copied().unwrap_or_default();
            let load = mini.get("load");
            let load = load.and_then(Value::as_array).map_or(load, |a| a.first());
            Some(json!({
                "host": host,
                "load": number(load),
                "ncpu": number(mini.get("ncpu")),
                "cpuPct": number(mini.get("cpu_pct")),
                "memFreePct": number(mini.get("mem_free_pct")),
                "runnersBusy": busy,
                "runnersOnline": online,
                "error": string(mini.get("error")),
            }))
        })
        .collect();
    let prs: Vec<Value> = root
        .get("recent_prs")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|run| {
            let number = int_value(run.get("pr"))?;
            Some(json!({
                "number": number,
                "title": run.get("title").and_then(Value::as_str).unwrap_or(""),
                "branch": string(run.get("branch")),
                "status": run.get("status").and_then(Value::as_str).unwrap_or(""),
            }))
        })
        .collect();
    let queued = root.get("queued");
    let queued = queued
        .and_then(Value::as_array)
        .map(|a| a.len() as i64)
        .or_else(|| int_value(queued))
        .unwrap_or(0);
    Some(json!({
        "updated": string(root.get("updated")),
        "machines": machines,
        "queued": queued,
        "prs": prs,
    }))
}

/// `URLQueryItem` value encoding: what `URLComponents` leaves alone in a query, minus `&`, `=` and `+`.
fn query_encode(value: &str) -> String {
    let mut out = String::new();
    for b in value.bytes() {
        let keep = b.is_ascii_alphanumeric()
            || matches!(
                b,
                b'-' | b'.'
                    | b'_'
                    | b'~'
                    | b'!'
                    | b'$'
                    | b'\''
                    | b'('
                    | b')'
                    | b'*'
                    | b','
                    | b';'
                    | b':'
                    | b'@'
                    | b'/'
                    | b'?'
            );
        if keep {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn search_url(query: &str) -> String {
    format!(
        "https://api.github.com/search/issues?q={}&sort=updated&order=desc&per_page={PAGE_SIZE}",
        query_encode(query)
    )
}

/// `ChiefViewsFeeds.landingSearchURLs(mergedSince:)`.
pub fn landing_search_urls(day: &str) -> (String, String) {
    let scope = format!("repo:{REPO} is:pr base:{BASE}");
    (
        search_url(&format!("{scope} is:open")),
        search_url(&format!("{scope} is:merged merged:>={day}")),
    )
}

/// `ChiefViewsFeeds.searchDay`: yesterday's UTC date.
pub fn search_day(now_seconds: f64) -> String {
    utc_day(now_seconds - 86_400.0)
}

/// `ChiefViewsFeeds.landingPRs`.
pub fn landing_prs(root: &Value) -> Option<Vec<Value>> {
    let items = root.get("items")?.as_array()?;
    Some(
        items
            .iter()
            .filter_map(|item| {
                let number = int_value(item.get("number"))?;
                let title = item.get("title")?.as_str()?;
                let url = item.get("html_url")?.as_str()?;
                if !url.starts_with("https://github.com/") {
                    return None;
                }
                let labels: Vec<&str> = item
                    .get("labels")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|l| l.get("name").and_then(Value::as_str))
                    .collect();
                Some(json!({
                    "number": number,
                    "title": title,
                    "url": url,
                    "author": string(item.get("user").and_then(|u| u.get("login"))),
                    "labels": labels,
                    "draft": item.get("draft").and_then(Value::as_bool).unwrap_or(false),
                    "createdAt": string(item.get("created_at")),
                    "mergedAt": string(item.get("pull_request").and_then(|p| p.get("merged_at"))),
                }))
            })
            .collect(),
    )
}

/// `URL.standardized.path`: `.` and `..` segments resolved.
fn standardized(path: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    let segments: Vec<&str> = path.split('/').collect();
    for (i, seg) in segments.iter().enumerate() {
        match *seg {
            "." => {
                if i == segments.len() - 1 {
                    out.push("");
                }
            }
            ".." => {
                if out.len() > 1 {
                    out.pop();
                }
            }
            s => out.push(s),
        }
    }
    out.join("/")
}

/// `ChiefViewsFeeds.validPullRequestURL`: only this repo's pages on github.com.
pub fn valid_pull_request_url(text: &str) -> Option<String> {
    let url = parse_url(text)?;
    if url.scheme != "https" || url.host != "github.com" || url.user.is_some() {
        return None;
    }
    let decoded = percent_decode(url.path);
    if decoded.split('/').any(|c| c == "..") {
        return None;
    }
    standardized(&decoded).starts_with(&format!("/{REPO}/")).then(|| text.to_string())
}

// MARK: Agents

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Lane {
    pub id: String,
    pub name: String,
    pub title: String,
    pub peer: Option<String>,
    pub cwd: Option<String>,
    /// `working`, `input`, `idle`, `failed` or `lost`.
    pub state: String,
    pub step: Option<String>,
    pub error: Option<String>,
    pub updated_at: Option<f64>,
    pub since: Option<f64>,
    pub created_at: Option<f64>,
    pub harness: Option<String>,
    pub parent: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AgentStatus {
    /// `working`, `blocked`, `idle`, `done` or `unknown`.
    pub state: String,
    pub updated_at_ms: i64,
    pub since_ms: Option<i64>,
    pub agent: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Tab {
    pub id: String,
    /// `TabItemMapping`'s title (Swift fills the untitled fallback).
    pub title: String,
    pub has_agent_session: bool,
    pub dead: bool,
    pub agent: Option<AgentStatus>,
    pub cwd: Option<String>,
    pub git_branch: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Workspace {
    pub is_local: bool,
    pub machine_name: Option<String>,
    #[serde(alias = "machineID")]
    pub machine_id: String,
    pub tabs: Vec<Tab>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Agent {
    pub id: String,
    pub kind: &'static str,
    pub name: String,
    pub title: String,
    pub machine: String,
    pub machine_name: Option<String>,
    pub folder: Option<String>,
    pub state: &'static str,
    pub task: Option<String>,
    pub error: Option<String>,
    pub last_output_at: Option<f64>,
    pub since: Option<f64>,
    pub created_at: Option<f64>,
    pub harness: Option<String>,
    pub branch: Option<String>,
    pub parent: Option<String>,
}

fn lane_state(state: &str) -> &'static str {
    match state {
        "working" => "working",
        "input" => "waiting",
        "failed" | "lost" => "failed",
        _ => "idle",
    }
}

fn terminal_state(state: &str) -> &'static str {
    match state {
        "working" => "working",
        "blocked" => "waiting",
        _ => "idle",
    }
}

/// `ChiefViewsAgent.init(lane:)`.
pub fn lane_row(lane: &Lane) -> Agent {
    Agent {
        id: lane.id.clone(),
        kind: "chat",
        name: lane.name.clone(),
        title: lane.title.clone(),
        machine: lane.peer.clone().unwrap_or_else(|| LOCAL_MACHINE.into()),
        machine_name: lane.peer.clone(),
        folder: lane.cwd.clone(),
        state: lane_state(&lane.state),
        task: lane.step.clone(),
        error: lane.error.clone(),
        last_output_at: lane.updated_at,
        since: lane.since,
        created_at: lane.created_at,
        harness: lane.harness.clone(),
        branch: None,
        parent: lane.parent.clone(),
    }
}

/// `ChiefViewsAgent.current`: chats sorted by id, then each workspace's live agent terminals.
pub fn agent_rows(lanes: &[Lane], workspaces: &[Workspace]) -> Vec<Agent> {
    let mut sorted: Vec<&Lane> = lanes.iter().collect();
    sorted.sort_by(|a, b| a.id.cmp(&b.id));
    let mut rows: Vec<Agent> = sorted.into_iter().map(lane_row).collect();
    for ws in workspaces {
        let name = if ws.is_local { None } else { ws.machine_name.clone() };
        let machine = if ws.is_local {
            LOCAL_MACHINE.to_string()
        } else {
            name.clone().unwrap_or_else(|| ws.machine_id.clone())
        };
        for tab in &ws.tabs {
            let Some(status) = tab.agent.as_ref().filter(|_| !tab.has_agent_session && !tab.dead)
            else {
                continue;
            };
            rows.push(Agent {
                id: tab.id.clone(),
                kind: "terminal",
                name: tab.title.clone(),
                title: tab.title.clone(),
                machine: machine.clone(),
                machine_name: name.clone(),
                folder: tab.cwd.clone(),
                state: terminal_state(&status.state),
                task: None,
                error: None,
                last_output_at: (status.updated_at_ms > 0)
                    .then(|| status.updated_at_ms as f64 / 1000.0),
                since: status.since_ms.map(|ms| ms as f64 / 1000.0),
                created_at: None,
                harness: status.agent.clone(),
                branch: tab.git_branch.clone(),
                parent: None,
            });
        }
    }
    rows
}

#[derive(Deserialize)]
struct TextRequest {
    text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DataRequest {
    /// The fetched body, parsed.
    #[serde(default)]
    data: Option<Value>,
    /// Or the body as text.
    #[serde(default)]
    body: Option<String>,
}

impl DataRequest {
    fn root(self) -> Option<Value> {
        match (self.data, self.body) {
            (Some(v), _) => Some(v),
            (None, Some(b)) => serde_json::from_str(&b).ok(),
            _ => None,
        }
    }
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct AgentsRequest {
    lanes: Vec<Lane>,
    workspaces: Vec<Workspace>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LandingReplyRequest {
    #[serde(default)]
    open: Vec<Value>,
    #[serde(default)]
    merged: Vec<Value>,
}

pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "fleetDataUrl" => {
            let req: TextRequest = parse(request)?;
            reply(&json!({"url": fleet_data_url(&req.text)}))
        }
        "validFleetUrl" => {
            let req: TextRequest = parse(request)?;
            reply(&json!({"url": valid_fleet_url(&req.text)}))
        }
        "fleetReply" => {
            let req: DataRequest = parse(request)?;
            reply(&json!({"reply": req.root().as_ref().and_then(fleet_reply)}))
        }
        "landingSearchUrls" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Req {
                #[serde(default)]
                day: Option<String>,
                #[serde(default)]
                now: Option<f64>,
            }
            let req: Req = parse(request)?;
            let day = match (req.day, req.now) {
                (Some(d), _) => d,
                (None, Some(now)) => search_day(now),
                _ => return Err(OpError::Invalid("day or now".into())),
            };
            let (open, merged) = landing_search_urls(&day);
            reply(&json!({"open": open, "merged": merged, "day": day}))
        }
        "searchDay" => {
            #[derive(Deserialize)]
            struct Req {
                now: f64,
            }
            let req: Req = parse(request)?;
            reply(&json!({"day": search_day(req.now)}))
        }
        "landingPrs" => {
            let req: DataRequest = parse(request)?;
            reply(&json!({"prs": req.root().as_ref().and_then(landing_prs)}))
        }
        "landingReply" => {
            let req: LandingReplyRequest = parse(request)?;
            reply(&json!({"repo": REPO, "base": BASE, "open": req.open, "merged": req.merged}))
        }
        "validPullRequestUrl" => {
            let req: TextRequest = parse(request)?;
            reply(&json!({"url": valid_pull_request_url(&req.text)}))
        }
        "agentRows" => {
            let req: AgentsRequest = parse(request)?;
            reply(&json!({"agents": agent_rows(&req.lanes, &req.workspaces)}))
        }
        _ => Err(OpError::Unknown),
    }
}
