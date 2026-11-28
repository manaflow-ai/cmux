//! `cmux-window-rules`' browser tab rules over the JSON channel (ops
//! `browser_tabs_*`): the engine a new tab gets, whether a Chromium page moves
//! to WebKit for its site rule, where a machine's new tab goes, which live tab
//! a page-requested tab reuses, the machine browser record and whether a tab
//! may open while the cmux browser is off. Pure; one call per decision.

use crate::ERR_INVALID;
use cmux_window_rules::browser::tabs::{self, Candidate, PageMemory, Resolve, SiteEngineMove};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"browser_tabs_")
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Commit {
    #[serde(default)]
    memory: PageMemory,
    url: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RouteAsk {
    is_local: bool,
    connected: bool,
    serves_tabs: bool,
    #[serde(default)]
    requested: Option<String>,
    #[serde(default)]
    needs_chromium: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MatchAsk {
    #[serde(default)]
    candidates: Vec<Candidate>,
    url: String,
    engine: String,
    #[serde(default)]
    profile: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SamePage {
    a: String,
    b: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecordAsk {
    text: Option<String>,
    #[serde(default)]
    machine: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AllowsAsk {
    enabled: bool,
    #[serde(default)]
    address: Option<String>,
}

fn parse<T: DeserializeOwned>(request: &[u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer: Value = match operation {
        b"browser_tabs_resolve" => json!(tabs::resolve(&parse::<Resolve>(request)?)),
        b"browser_tabs_reopens_in_webkit" => {
            json!(parse::<SiteEngineMove>(request)?.reopens_in_webkit())
        }
        b"browser_tabs_committed" => {
            let ask: Commit = parse(request)?;
            json!(tabs::committed(&ask.memory, &ask.url))
        }
        b"browser_tabs_route" => {
            let ask: RouteAsk = parse(request)?;
            json!({
                "route": tabs::route(ask.is_local, ask.connected, ask.serves_tabs),
                "allowsSessionLocalTab":
                    tabs::allows_session_local_tab(ask.requested.as_deref(), ask.needs_chromium),
            })
        }
        b"browser_tabs_match" => {
            let ask: MatchAsk = parse(request)?;
            let first =
                tabs::first_match(&ask.candidates, &ask.url, &ask.engine, ask.profile.as_deref());
            json!({
                "first": first.map(|tab| tab.id.as_str()),
                "navigates": first.map(|tab| tabs::navigates(tab.shown.as_deref(), &ask.url)),
            })
        }
        b"browser_tabs_same_page" => {
            let ask: SamePage = parse(request)?;
            json!(tabs::same_page(&ask.a, &ask.b))
        }
        b"browser_tabs_machine_record" => {
            let ask: RecordAsk = parse(request)?;
            match ask.machine {
                Some(machine) => json!(tabs::owned_record(ask.text.as_deref(), &machine)),
                None => json!(ask.text.as_deref().and_then(tabs::machine_record)),
            }
        }
        b"browser_tabs_allows" => {
            let ask: AllowsAsk = parse(request)?;
            json!({
                "allows": tabs::allows(ask.enabled, ask.address.as_deref()),
                "isCmuxPage": ask.address.as_deref().is_some_and(tabs::is_cmux_page),
            })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
