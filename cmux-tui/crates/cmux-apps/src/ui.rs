//! What the app draws for the Apps tier (RFD 0003 step 4: entry E-A, the browser pane's
//! **Publish** button and its popover, and E-C, the sidebar's **Apps** section), as pure rules
//! over JSON. The app (Swift) only draws these answers and runs the command they name; no rule
//! about which page is publishable, what the app is called, who sees it or what a publish
//! answered lives in the app. All of it shows only with `experiments.appsTier` on, which the app
//! reads; these rules never see the flag.
//!
//! - [`target`]: whether the page in a browser pane is a Cloud preview this person opened, and
//!   which `{machine, port}` it is. Only those pages get the button (E-A: "The pane showing a
//!   Cloud preview gets a **Publish** button").
//! - [`popover`]: the popover's name, slug, audience and inferred start command, and the exact
//!   `cmux app publish` argv the Publish press runs on that machine (`cloud exec`).
//! - [`outcome`]: what that run printed (`cmux app publish --json`), as the popover's result.
//! - [`section`]: the Apps section's rows from `cmux app ls` (the account relay's `{items}`):
//!   pinned first, a status dot each, then the **+ Publish preview…** row.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::slug::slugify;

/// One preview this app opened (`cloud open-browser`, the preview picker): its machine, the port
/// and the origin the platform gave it (`CloudMachinePreview.origin`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KnownPreview {
    pub machine: String,
    #[serde(default)]
    pub machine_name: String,
    pub port: u16,
    pub origin: String,
}

/// The page in a browser pane and the previews it could be.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Page {
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub previews: Vec<KnownPreview>,
}

/// The Cloud preview a pane shows: what a publish names.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    pub machine: String,
    pub machine_name: String,
    pub port: u16,
    pub origin: String,
    /// The name the popover starts with: the page's title, else `App on port P`.
    pub suggested_name: String,
}

/// `scheme://host[:port]` of `url`, lower-cased, with the scheme's default port dropped; `None`
/// for anything that is not `http` or `https` with a host.
pub fn origin_of(url: &str) -> Option<String> {
    let (scheme, rest) = url.split_once("://")?;
    let scheme = scheme.to_ascii_lowercase();
    if scheme != "http" && scheme != "https" {
        return None;
    }
    let authority = rest.split(['/', '?', '#']).next()?;
    // Userinfo never names the origin.
    let host_port = authority.rsplit('@').next()?.to_ascii_lowercase();
    if host_port.is_empty() {
        return None;
    }
    let default = if scheme == "https" { ":443" } else { ":80" };
    let host_port = host_port.strip_suffix(default).unwrap_or(&host_port);
    if host_port.is_empty() || host_port.starts_with(':') {
        return None;
    }
    Some(format!("{scheme}://{host_port}"))
}

/// The title the name starts from: trimmed, with no `localhost:3000`-style or URL-like title,
/// which says nothing a person would call the app.
fn title_name(title: Option<&str>) -> Option<String> {
    let title = title?.trim();
    if title.is_empty() || title.contains("://") || title.starts_with("localhost") {
        return None;
    }
    let first: String = title.chars().take(60).collect();
    slugify(&first).map(|_| first)
}

/// The Cloud preview `page` shows, or `None` when it is not one of `page.previews` (any other
/// page, a sign-in redirect off the preview origin, a preview of another person's machine).
pub fn target(page: &Page) -> Option<Target> {
    let origin = origin_of(&page.url)?;
    let preview =
        page.previews.iter().find(|p| origin_of(&p.origin).as_deref() == Some(&origin))?;
    let suggested_name = title_name(page.title.as_deref())
        .unwrap_or_else(|| format!("App on port {}", preview.port));
    Some(Target {
        machine: preview.machine.clone(),
        machine_name: if preview.machine_name.is_empty() {
            preview.machine.clone()
        } else {
            preview.machine_name.clone()
        },
        port: preview.port,
        origin: preview.origin.clone(),
        suggested_name,
    })
}

/// Who sees the app. `Private` is the RFD's default (G3, "Private by default, shared on
/// purpose"); `Team` adds the team grant (`--share team`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Audience {
    #[default]
    Private,
    Team,
}

/// What the person typed and picked in the popover; an absent name keeps the suggestion.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Draft {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub audience: Audience,
}

/// Why Publish is not pressable, as a key into the app's strings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Problem {
    /// The name has no letter or digit, so it makes no slug.
    NameEmpty,
}

/// The popover, as drawn: name, the slug and URL label it makes, the audience picker, the start
/// command line, and the publish run.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Popover {
    pub name: String,
    pub slug: Option<String>,
    /// The hostname label the platform gives the app (`a-<slug>--<team8>`); the team part is the
    /// platform's, so the popover shows `a-<slug>--…`.
    pub host_label: Option<String>,
    pub audience: Audience,
    /// The start command row: inferred on the machine from the process listening on the port
    /// (RFD "Publish" step 1), so the popover names the port and the machine, never a guess.
    pub start_from: String,
    pub machine: String,
    pub machine_name: String,
    pub port: u16,
    /// What Publish runs on `machine` (`cloud exec`): `cmux app publish SLUG --port P [--share
    /// team] --json`, as argv and as one shell-quoted line.
    pub argv: Vec<String>,
    pub command: String,
    pub can_publish: bool,
    pub problem: Option<Problem>,
}

/// The `cmux app publish` argv for `slug` on `port`.
pub fn publish_argv(slug: &str, port: u16, audience: Audience) -> Vec<String> {
    let mut argv: Vec<String> =
        ["cmux", "app", "publish", slug, "--port", &port.to_string()].map(str::to_owned).to_vec();
    if audience == Audience::Team {
        argv.extend(["--share".to_owned(), "team".to_owned()]);
    }
    argv.push("--json".to_owned());
    argv
}

/// `argv` as one POSIX shell line: each word that is not plain is single-quoted.
pub fn shell_line(argv: &[String]) -> String {
    let plain = |w: &str| {
        !w.is_empty() && w.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_./:=@%+,".contains(&b))
    };
    argv.iter()
        .map(|w| if plain(w) { w.clone() } else { format!("'{}'", w.replace('\'', r"'\''")) })
        .collect::<Vec<_>>()
        .join(" ")
}

/// The popover for `target` with what the person has typed.
pub fn popover(target: &Target, draft: &Draft) -> Popover {
    let name = draft.name.clone().unwrap_or_else(|| target.suggested_name.clone());
    let slug = slugify(&name);
    let argv =
        slug.as_deref().map(|s| publish_argv(s, target.port, draft.audience)).unwrap_or_default();
    Popover {
        host_label: slug.as_ref().map(|s| format!("a-{s}--…")),
        start_from: format!("Inferred from port {} on {}", target.port, target.machine_name),
        machine: target.machine.clone(),
        machine_name: target.machine_name.clone(),
        port: target.port,
        command: shell_line(&argv),
        can_publish: slug.is_some(),
        problem: slug.is_none().then_some(Problem::NameEmpty),
        argv,
        slug,
        name,
        audience: draft.audience,
    }
}

/// What a publish run answered, as the popover shows it after the press.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Outcome {
    /// The new version is live at `url`.
    Published { slug: String, version: Option<u64>, url: Option<String>, warnings: Vec<String> },
    /// The publish refused or the version failed its probe; `live` stayed (G2).
    Failed { code: String, message: String, version: Option<u64> },
}

/// The outcome of a `cmux app publish --json` run from its stdout and exit status: the last JSON
/// line it printed, else a failure naming the exit and the output's tail.
pub fn outcome(stdout: &str, stderr: &str, exit: i32) -> Outcome {
    let reply = stdout
        .lines()
        .rev()
        .find_map(|l| serde_json::from_str::<Value>(l.trim()).ok().filter(Value::is_object));
    let text = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
    let number = |v: &Value| match v {
        Value::Number(n) => n.as_u64(),
        Value::Object(o) => o.get("n").and_then(Value::as_u64),
        _ => None,
    };
    if let Some(reply) = reply {
        if let Some(error) = reply.get("error") {
            return Outcome::Failed {
                code: text(error, "code").unwrap_or_else(|| "cloud.app.failed".into()),
                message: text(error, "message").unwrap_or_default(),
                version: reply.get("version").and_then(number),
            };
        }
        if exit == 0 {
            let app = reply.get("app");
            let slug = app
                .and_then(|a| match a {
                    Value::String(s) => Some(s.clone()),
                    other => text(other, "slug"),
                })
                .unwrap_or_default();
            let warnings = reply
                .get("warnings")
                .and_then(Value::as_array)
                .map(|w| w.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                .unwrap_or_default();
            return Outcome::Published {
                slug,
                version: reply.get("version").and_then(number),
                url: text(&reply, "url"),
                warnings,
            };
        }
    }
    let tail: String = {
        let all = if stderr.trim().is_empty() { stdout } else { stderr };
        let lines: Vec<&str> = all.trim().lines().collect();
        lines[lines.len().saturating_sub(4)..].join("\n")
    };
    Outcome::Failed {
        code: format!("exit_{exit}"),
        message: if tail.is_empty() { format!("cmux app publish exited {exit}") } else { tail },
        version: None,
    }
}

/// An Apps section row's status dot.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Dot {
    /// A version is live.
    Live,
    /// No version is live yet (none published, or every one failed).
    Off,
}

/// One row of the Apps section.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub slug: String,
    pub title: String,
    /// `v3`, or `not live`.
    pub detail: String,
    pub dot: Dot,
    pub pinned: bool,
    /// What a click opens; `None` keeps the row unclickable (no live version, no URL).
    pub url: Option<String>,
}

/// The Apps section, as drawn.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Section {
    pub rows: Vec<Row>,
    /// The `+ Publish preview…` row is always last (E-C).
    pub publish_row: bool,
    /// When the list could not be read: the relay's error message, drawn as the section's note
    /// instead of rows, so an error never looks like no apps.
    pub error: Option<String>,
}

/// The Apps section from the account relay's answer (`{ok, value: {items}}` or `{ok: false,
/// error}`; `cmux app ls --json`'s `{items}` reads the same): pinned apps first, then by title.
pub fn section(relayed: &Value) -> Section {
    if relayed.get("ok").and_then(Value::as_bool) == Some(false) {
        let message = relayed
            .pointer("/error/message")
            .and_then(Value::as_str)
            .unwrap_or("cmux Cloud did not answer")
            .to_owned();
        return Section { rows: Vec::new(), publish_row: true, error: Some(message) };
    }
    let items = relayed
        .pointer("/value/items")
        .or_else(|| relayed.get("items"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut rows: Vec<Row> = items
        .iter()
        .filter_map(|app| {
            let slug = app.get("slug").and_then(Value::as_str)?.to_owned();
            let title = app
                .get("name")
                .and_then(Value::as_str)
                .filter(|n| !n.trim().is_empty())
                .map_or_else(|| slug.clone(), str::to_owned);
            let live = app.get("live").and_then(Value::as_u64);
            let url = app.get("url").and_then(Value::as_str).filter(|u| !u.is_empty());
            Some(Row {
                detail: live.map_or_else(|| "not live".to_owned(), |n| format!("v{n}")),
                dot: if live.is_some() { Dot::Live } else { Dot::Off },
                pinned: app.get("pinned").and_then(Value::as_bool).unwrap_or(false),
                url: live.and(url).map(str::to_owned),
                slug,
                title,
            })
        })
        .collect();
    rows.sort_by(|a, b| {
        b.pinned
            .cmp(&a.pinned)
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
            .then_with(|| a.slug.cmp(&b.slug))
    });
    Section { rows, publish_row: true, error: None }
}

/// The JSON channel's ops (`apps_tier_*`, the app's FFI): each takes and answers JSON.
pub fn respond(op: &str, request: &Value) -> Option<Value> {
    let answer = match op {
        "apps_tier_target" => {
            let page: Page = serde_json::from_value(request.clone()).ok()?;
            serde_json::to_value(target(&page)).ok()?
        }
        "apps_tier_popover" => {
            let target: Target = serde_json::from_value(request.get("target")?.clone()).ok()?;
            let draft: Draft = request
                .get("draft")
                .cloned()
                .map(serde_json::from_value)
                .transpose()
                .ok()?
                .unwrap_or_default();
            serde_json::to_value(popover(&target, &draft)).ok()?
        }
        "apps_tier_outcome" => {
            let s = |k: &str| request.get(k).and_then(Value::as_str).unwrap_or_default();
            let exit = request.get("exit").and_then(Value::as_i64).unwrap_or(-1);
            serde_json::to_value(outcome(s("stdout"), s("stderr"), exit as i32)).ok()?
        }
        "apps_tier_section" => serde_json::to_value(section(request)).ok()?,
        _ => return None,
    };
    Some(answer)
}

#[cfg(test)]
#[path = "ui_tests.rs"]
mod tests;
