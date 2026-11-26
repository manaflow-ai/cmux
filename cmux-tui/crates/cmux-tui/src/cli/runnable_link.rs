//! `cmux link mint` and `cmux link open`: runnable links (hq#23807). A runnable link is a URL that opens a working
//! copy of a live project: the person who clicks it gets a fork of a snapshot of the creator's Cloud machine, opened as
//! a workspace in their cmux, with the agent sessions the link names attached.
//!
//! The cmux platform (`/v1/runnable-links`, cmux-platform) mints, reads and forks links; this CLI asks, waits and opens.
//! It reuses the Cloud CLI's credential and origin (`autocloud.rs`: `--token-file`, `--token-command`,
//! `CMUX_CLOUD_ACCESS_TOKEN`, else the app's sign-in; `--platform`, `CMUX_PLATFORM_URL`, else the platform of that
//! sign-in) and the app's own Cloud verbs (`cloud new-terminal-on-machine`, `agent open`) to show the copy, so it adds
//! no auth and no new app path.
//!
//! What a link carries is the platform's decision and is shown before anything runs: reading a link
//! (`GET /v1/runnable-links/:id`) allocates nothing; only the confirmed fork does. A fork never gets the creator's
//! tokens, memory image, private transcripts, network grants or untracked files, and the platform checks the
//! recipient's team, the expiry and revocation again at fork time. No credential is printed, logged or put in a URL.
//!
//! Off by default: `cloud.runnableLinks: true` in cmux-next.json (a hidden key, like `cloud.autoCloud` was before
//! it had a switch) or `CMUX_RUNNABLE_LINKS=1` turns it on.

use std::future::Future;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::hub::{error_json, platform_for};
use super::inference_gateway::{TokenSource, backend_credential};

pub(crate) const HELP: &str = "\
cmux link mint | open: runnable links, a URL that opens a working copy of a Cloud machine (off by default).

Usage:
  cmux link mint <machine-id> [--ttl 7d] [--note TEXT] [--yes] [--json]
      Snapshots the machine (your team can see it) and prints the link. Shows what the link gives
      away and asks first; --yes skips the question.
  cmux link open <url-or-id> [--yes] [--no-app] [--json]
      Shows the link (version, creator, expiry; no machine starts), then on yes forks it, waits for
      the copy to run, opens it as a workspace in the running cmux app and attaches the agent
      sessions the link names. --json prints each phase's time in ms.

A link is https://cmux.com/run/<id>, cmux://run/<id>, or the bare id.
Turn it on with \"cloud\": {\"runnableLinks\": true} in cmux-next.json, or CMUX_RUNNABLE_LINKS=1.
Both verbs take --platform URL, --team TEAM, --token-file PATH | --token-command CMD.
";

/// The hidden settings key that turns runnable links on.
pub(super) const SETTING: &str = "runnableLinks";
pub(super) const ENV: &str = "CMUX_RUNNABLE_LINKS";

/// Whether runnable links are on: the env says so (`1`, `true`, `on`, `yes`), or else cmux-next.json's
/// `cloud.runnableLinks` is JSON `true`. Anything else, an absent key included, is off.
pub(super) fn enabled(env: Option<&str>, settings: Option<&Value>) -> bool {
    match env.map(str::trim) {
        Some("1" | "true" | "on" | "yes") => return true,
        Some("0" | "false" | "off" | "no") => return false,
        _ => {}
    }
    settings.and_then(|s| s.get("cloud")).and_then(|c| c.get(SETTING)) == Some(&Value::Bool(true))
}

/// A link id the platform minted: 1 to 128 of `[A-Za-z0-9_-]`, safe as a path segment.
pub(super) fn valid_id(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// The link id `text` names: `https://cmux.com/run/<id>` (or `www.`, an optional locale `/ja` or `/zh-CN`, a trailing
/// slash, a query or fragment, which are ignored), `cmux://run/<id>` in any build's scheme (`cmux`, `cmux-next`,
/// `cmux-dev`, ...), or the bare id. None for anything else, another host or path included.
pub(super) fn parse_link(text: &str) -> Option<String> {
    let text = text.trim();
    let rest = if let Some(rest) = text.strip_prefix("https://") {
        let rest = rest.strip_prefix("www.").unwrap_or(rest);
        let path = rest.strip_prefix("cmux.com/")?;
        let path = match path.split_once('/') {
            Some((locale, tail)) if is_locale(locale) => tail,
            _ => path,
        };
        path.strip_prefix("run/")?
    } else if let Some((scheme, rest)) = text.split_once("://") {
        let build = scheme.strip_prefix("cmux")?;
        if !(build.is_empty()
            || build.strip_prefix('-').is_some_and(|b| {
                !b.is_empty() && b.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
            }))
        {
            return None;
        }
        rest.strip_prefix("run/")?
    } else {
        return valid_id(text).then(|| text.to_owned());
    };
    let id = rest.split(['?', '#']).next().unwrap_or_default();
    let id = id.strip_suffix('/').unwrap_or(id);
    valid_id(id).then(|| id.to_owned())
}

fn is_locale(s: &str) -> bool {
    match *s.as_bytes() {
        [a, b] => a.is_ascii_lowercase() && b.is_ascii_lowercase(),
        [a, b, b'-', c, d] => {
            a.is_ascii_lowercase()
                && b.is_ascii_lowercase()
                && c.is_ascii_uppercase()
                && d.is_ascii_uppercase()
        }
        _ => false,
    }
}

/// `7d`, `12h`, `30m`, `90s` or plain seconds, as seconds; between 60 s and 30 days.
pub(super) fn parse_ttl(text: &str) -> Result<u64, String> {
    let text = text.trim();
    let (digits, unit) = match text.char_indices().find(|(_, c)| !c.is_ascii_digit()) {
        Some((i, _)) => text.split_at(i),
        None => (text, "s"),
    };
    let n: u64 =
        digits.parse().map_err(|_| format!("--ttl {text}: not a duration (7d, 12h, 30m)"))?;
    let secs = match unit {
        "s" => n,
        "m" => n.saturating_mul(60),
        "h" => n.saturating_mul(3600),
        "d" => n.saturating_mul(86_400),
        _ => return Err(format!("--ttl {text}: not a duration (7d, 12h, 30m)")),
    };
    if !(60..=30 * 86_400).contains(&secs) {
        return Err(format!("--ttl {text}: between 1 minute and 30 days"));
    }
    Ok(secs)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Common {
    pub platform: Option<String>,
    pub team: Option<String>,
    pub token: TokenSource,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Verb {
    Mint { machine: String, ttl_seconds: Option<u64>, note: Option<String> },
    Open { id: String, no_app: bool },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Parsed {
    pub common: Common,
    pub verb: Verb,
    pub yes: bool,
    pub json: bool,
}

/// Parses `mint ...` or `open ...` (the words after `link`).
pub(super) fn parse(
    words: &[String],
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<Parsed, String> {
    let (action, rest) = words.split_first().ok_or("say mint or open")?;
    let (mut platform, mut team, mut token) = (None, None, None);
    let (mut yes, mut json, mut no_app) = (false, false, false);
    let (mut ttl, mut note) = (None, None);
    let mut positional = vec![];
    let mut i = 0;
    while let Some(word) = rest.get(i) {
        let word = word.as_str();
        let mut value = || {
            i += 1;
            rest.get(i).cloned().ok_or_else(|| format!("{word} needs a value"))
        };
        match word {
            "--platform" => platform = Some(value()?),
            "--team" => team = Some(value()?),
            "--token-file" => token = Some(TokenSource::File(value()?.into())),
            "--token-command" => token = Some(TokenSource::Command(value()?)),
            "--ttl" if action == "mint" => ttl = Some(parse_ttl(&value()?)?),
            "--note" if action == "mint" => note = Some(value()?),
            "--no-app" if action == "open" => no_app = true,
            "--yes" | "-y" => yes = true,
            "--json" => json = true,
            w if w.starts_with('-') => return Err(format!("{w}: not an option of link {action}")),
            w => positional.push(w.to_owned()),
        }
        i += 1;
    }
    if let Some(n) = &note
        && n.chars().count() > 500
    {
        return Err("--note: at most 500 characters".into());
    }
    let platform = match platform.or_else(|| env("CMUX_PLATFORM_URL")) {
        Some(p) => Some(super::cloud_client_session::secure_origin(p.trim())?),
        None => None,
    };
    let token = token.unwrap_or(if env("CMUX_CLOUD_ACCESS_TOKEN").is_some() {
        TokenSource::Env
    } else {
        TokenSource::App
    });
    let common = Common { platform, team, token };
    let [target] = positional.as_slice() else {
        return Err(format!(
            "link {action} takes exactly one {}",
            if action == "mint" { "machine id" } else { "link" }
        ));
    };
    let verb = match action.as_str() {
        "mint" => {
            if !valid_id(target) {
                return Err(format!("{target}: not a machine id"));
            }
            Verb::Mint { machine: target.clone(), ttl_seconds: ttl, note }
        }
        "open" => match parse_link(target) {
            Some(id) => Verb::Open { id, no_app },
            None => {
                return Err(format!("{target}: not a runnable link (https://cmux.com/run/<id>)"));
            }
        },
        other => return Err(format!("{other}: say mint or open")),
    };
    Ok(Parsed { common, verb, yes, json })
}

/// The platform, as this flow calls it: one JSON request under the platform origin.
pub(super) trait Platform {
    fn call(
        &mut self,
        method: &'static str,
        path: &str,
        body: Option<Value>,
    ) -> impl Future<Output = Result<(u16, Value), String>>;
}

/// The running cmux app, as this flow calls it: its Cloud verbs (`--json` steps).
pub(super) trait App {
    fn present(&mut self) -> bool;
    fn step(&mut self, args: &[String]) -> Result<Value, Value>;
}

/// How long the flow waits, and how often it looks.
#[derive(Debug, Clone, Copy)]
pub(super) struct Waits {
    pub poll: Duration,
    pub running: Duration,
    pub acpmux: Duration,
    pub app_list: Duration,
}

impl Default for Waits {
    fn default() -> Self {
        Waits {
            poll: Duration::from_secs(1),
            running: Duration::from_secs(300),
            acpmux: Duration::from_secs(120),
            app_list: Duration::from_secs(60),
        }
    }
}

/// The value of a platform answer: its `value` envelope when it has one, else the body.
fn value_of(body: &Value) -> &Value {
    body.get("value").filter(|v| v.is_object()).unwrap_or(body)
}

fn refused(status: u16, body: &Value, what: &str) -> Value {
    let v = value_of(body);
    let code = v
        .pointer("/error/code")
        .or_else(|| body.pointer("/error/code"))
        .or_else(|| v.get("code"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| match status {
            401 => "auth.unauthenticated".into(),
            403 => "auth.forbidden".into(),
            404 => "link.not_found".into(),
            410 => "link.expired".into(),
            _ => "api.refused".into(),
        });
    let message = v
        .pointer("/error/message")
        .or_else(|| body.pointer("/error/message"))
        .or_else(|| v.get("message"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| format!("{what}: the cmux platform answered HTTP {status}"));
    error_json(&code, &message)
}

fn ms(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// The text shown before a fork: what the link is and what opening it does and does not carry.
pub(super) fn open_disclosure(link: &Value) -> Vec<String> {
    let s = |p: &str| link.pointer(p).and_then(Value::as_str).unwrap_or("?").to_owned();
    let mut lines = vec![
        format!("Runnable link {}", s("/id")),
        format!("  version:  snapshot {}", s("/snapshotId")),
        format!(
            "  made by:  {}",
            link.pointer("/manifest/createdBy")
                .and_then(Value::as_str)
                .or_else(|| link.get("createdBy").and_then(Value::as_str))
                .unwrap_or("?")
        ),
        format!("  expires:  {}", when(link.get("expiresAt"))),
    ];
    if let Some(repo) = link.pointer("/manifest/repo").and_then(Value::as_str) {
        let head = link.pointer("/manifest/head").and_then(Value::as_str).unwrap_or("");
        lines.push(format!("  project:  {repo} {head}").trim_end().to_owned());
    }
    let sessions = manifest_sessions(link);
    if !sessions.is_empty() {
        lines.push(format!("  agents:   {}", sessions.join(", ")));
    }
    if let Some(note) = link.get("note").and_then(Value::as_str).filter(|n| !n.is_empty()) {
        lines.push(format!("  note:     {note}"));
    }
    lines.push(
        "Opening it starts a new Cloud machine on your team from that snapshot. You get its files and agent \
         sessions as they were; never the creator's tokens, network grants, private transcripts or memory."
            .into(),
    );
    lines
}

/// The text shown before a mint: what the link gives away.
pub(super) fn mint_disclosure(machine: &str, ttl_seconds: Option<u64>) -> Vec<String> {
    let ttl = ttl_seconds.map_or_else(|| "the platform's default".to_owned(), human_seconds);
    vec![
        format!("Mint a runnable link to {machine}:"),
        "  It snapshots the machine now; your team can see the snapshot.".into(),
        "  Anyone on your team with the link gets a copy of that snapshot's files and agent sessions,".into(),
        "  never your tokens, network grants, private transcripts or memory.".into(),
        format!("  It expires after {ttl}; the platform can revoke it sooner."),
    ]
}

fn human_seconds(s: u64) -> String {
    match s {
        s if s % 86_400 == 0 => format!("{} days", s / 86_400),
        s if s % 3600 == 0 => format!("{} hours", s / 3600),
        s if s % 60 == 0 => format!("{} minutes", s / 60),
        s => format!("{s} seconds"),
    }
}

fn when(v: Option<&Value>) -> String {
    match v {
        Some(Value::Number(n)) => {
            n.as_i64().map_or_else(|| n.to_string(), |at| relative(at, now_ms()))
        }
        Some(Value::String(s)) => s.clone(),
        _ => "never".into(),
    }
}

/// `at` (ms since the epoch) from `now`: "in 6 days", "in 3 hours", "expired".
pub(super) fn relative(at: i64, now: i64) -> String {
    let left = (at - now) / 1000;
    match left {
        l if l <= 0 => "expired".into(),
        l if l >= 86_400 => format!("in {} days", l / 86_400),
        l if l >= 3600 => format!("in {} hours", l / 3600),
        l => format!("in {} minutes", (l / 60).max(1)),
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

fn manifest_sessions(link: &Value) -> Vec<String> {
    link.pointer("/manifest/sessions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|s| s.as_str().or_else(|| s.get("name").and_then(Value::as_str)))
        .map(str::to_owned)
        .collect()
}

/// A fresh client key, so a retried fork or mint does not run twice.
fn client_key() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// `cmux link mint`: shows what the link gives away, asks, mints, prints the URL.
pub(super) async fn mint<P: Platform>(
    platform: &mut P,
    machine: &str,
    ttl_seconds: Option<u64>,
    note: Option<&str>,
    confirm: &mut dyn FnMut(&[String]) -> bool,
) -> Value {
    if !confirm(&mint_disclosure(machine, ttl_seconds)) {
        return error_json("link.declined", "not minted");
    }
    let mut body = json!({"machine": machine, "clientKey": client_key()});
    if let Some(ttl) = ttl_seconds {
        put(&mut body, "ttlSeconds", json!(ttl));
    }
    if let Some(n) = note {
        put(&mut body, "note", json!(n));
    }
    let (status, answer) = match platform.call("POST", "/v1/runnable-links", Some(body)).await {
        Ok(a) => a,
        Err(e) => return error_json("api.unreachable", &e),
    };
    if !(200..300).contains(&status) {
        return refused(status, &answer, "mint");
    }
    let v = value_of(&answer);
    let id = v.get("id").and_then(Value::as_str).unwrap_or_default();
    let url = v
        .get("url")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| format!("https://cmux.com/run/{id}"));
    json!({
        "ok": true,
        "id": id,
        "url": url,
        "snapshotId": v.get("snapshotId"),
        "expiresAt": v.get("expiresAt"),
        "manifest": v.get("manifest"),
    })
}

/// `cmux link open`: resolve (no compute), confirm, fork, wait running, first exec, list acpmux sessions, open the
/// workspace in the app and attach the sessions the link names. Every phase's ms is in `timings`.
pub(super) async fn open<P: Platform, A: App>(
    platform: &mut P,
    app: Option<&mut A>,
    id: &str,
    waits: Waits,
    confirm: &mut dyn FnMut(&[String]) -> bool,
) -> Value {
    let start = Instant::now();
    let mut timings = serde_json::Map::new();
    let phase = |name: &str, t: Instant, timings: &mut serde_json::Map<String, Value>| {
        timings.insert(format!("{name}_ms"), json!(ms(t)));
    };

    // resolve: a read, no compute.
    let t = Instant::now();
    let (status, body) = match platform.call("GET", &format!("/v1/runnable-links/{id}"), None).await
    {
        Ok(a) => a,
        Err(e) => return error_json("api.unreachable", &e),
    };
    if !(200..300).contains(&status) {
        return refused(status, &body, "resolve");
    }
    let link = value_of(&body).clone();
    phase("resolve", t, &mut timings);
    if link.get("revokedAt").is_some_and(|r| !r.is_null()) {
        return error_json("link.revoked", "this link was revoked");
    }
    if !confirm(&open_disclosure(&link)) {
        return json!({"ok": false, "error": {"code": "link.declined", "message": "not opened; nothing started"}, "link": link, "timings": timings});
    }
    // The person's yes is not the flow's time.
    let after_confirm = Instant::now();

    // fork: the platform checks team, expiry and revocation again.
    let t = Instant::now();
    let (status, body) = match platform
        .call(
            "POST",
            &format!("/v1/runnable-links/{id}/fork"),
            Some(json!({"clientKey": client_key()})),
        )
        .await
    {
        Ok(a) => a,
        Err(e) => return error_json("api.unreachable", &e),
    };
    if !(200..300).contains(&status) {
        return refused(status, &body, "fork");
    }
    let forked = value_of(&body).clone();
    let machine_view = forked.get("machine").filter(|m| m.is_object()).unwrap_or(&forked).clone();
    let Some(machine) = machine_view.get("id").and_then(Value::as_str).map(str::to_owned) else {
        return error_json("api.bad_answer", "the fork named no machine");
    };
    phase("fork", t, &mut timings);
    let manifest = forked
        .get("manifest")
        .cloned()
        .or_else(|| link.get("manifest").cloned())
        .unwrap_or(Value::Null);

    // running.
    let t = Instant::now();
    let mut state =
        machine_view.get("state").and_then(Value::as_str).unwrap_or("starting").to_owned();
    while state != "running" {
        if matches!(state.as_str(), "failed" | "gone" | "stopped") {
            return json!({"ok": false, "error": {"code": "machine.failed", "message": format!("the copy is {state}")}, "machine": machine, "timings": timings});
        }
        if t.elapsed() > waits.running {
            return json!({"ok": false, "error": {"code": "machine.timeout", "message": format!("the copy was still {state} after {} s", waits.running.as_secs())}, "machine": machine, "timings": timings});
        }
        tokio::time::sleep(waits.poll).await;
        if let Ok((200..=299, body)) =
            platform.call("GET", &format!("/v1/machines/{machine}"), None).await
        {
            state =
                value_of(&body).get("state").and_then(Value::as_str).unwrap_or(&state).to_owned();
        }
    }
    phase("running", t, &mut timings);

    // first exec, then acpmux's sessions on the copy.
    let t = Instant::now();
    let exec_path = format!("/v1/cloud/machines/{machine}/exec");
    let mut gaps: Vec<String> = vec![];
    match exec(platform, &exec_path, "true").await {
        Ok((0, _)) => phase("first_exec", t, &mut timings),
        Ok((code, _)) => gaps.push(format!("first exec exited {code}")),
        Err(e) => gaps.push(format!("first exec: {e}")),
    }
    let t = Instant::now();
    let mut sessions = Value::Null;
    loop {
        match exec(platform, &exec_path, "acpmux ls --json 2>/dev/null").await {
            Ok((0, out)) => {
                sessions = serde_json::from_str(&out).unwrap_or(Value::Null);
                phase("acpmux_sessions_listed", t, &mut timings);
                break;
            }
            _ if t.elapsed() > waits.acpmux => {
                gaps.push(format!("acpmux did not answer in {} s", waits.acpmux.as_secs()));
                break;
            }
            _ => tokio::time::sleep(waits.poll).await,
        }
    }
    let listed = session_rows(&sessions);
    let wanted = manifest_sessions(&json!({"manifest": manifest}));

    // workspace open: the app's own Cloud verbs.
    let mut attached = vec![];
    let mut workspace = Value::Null;
    let app = app.and_then(|a| if a.present() { Some(a) } else { None });
    match app {
        Some(app) => {
            let t = Instant::now();
            let target = format!("machine:{machine}");
            // The app learns of the new machine from its Cloud list; wait until it shows there.
            let mut seen = false;
            while t.elapsed() <= waits.app_list {
                if let Ok(list) = app.step(&words(&["cloud", "list-machines"]))
                    && list.to_string().contains(&machine)
                {
                    seen = true;
                    break;
                }
                tokio::time::sleep(waits.poll).await;
            }
            if !seen {
                gaps.push("the app's machine list did not show the copy; opening it anyway".into());
            }
            match app.step(&words(&[
                "cloud",
                "new-terminal-on-machine",
                "--target",
                &target,
                "--focus",
            ])) {
                Ok(v) => {
                    workspace = v;
                    phase("workspace_open", t, &mut timings);
                }
                Err(e) => gaps.push(format!("workspace open: {}", short_error(&e))),
            }
            for name in &wanted {
                let Some(row) = listed.iter().find(|r| r.0 == *name || r.1 == *name) else {
                    gaps.push(format!("agent session {name}: not on the copy"));
                    continue;
                };
                match app
                    .step(&words(&["agent", "open", &row.1, "--host", &machine, "--name", &row.0]))
                {
                    Ok(_) => attached.push(json!(row.0)),
                    Err(e) => gaps.push(format!("agent session {name}: {}", short_error(&e))),
                }
            }
        }
        _ => gaps
            .push("no running cmux app: the copy is running but not opened as a workspace".into()),
    }
    timings.insert("total_ms".into(), json!(ms(start)));
    timings.insert("after_confirm_ms".into(), json!(ms(after_confirm)));
    json!({
        "ok": true,
        "id": id,
        "machine": machine,
        "target": format!("machine:{machine}"),
        "snapshotId": link.get("snapshotId"),
        "manifest": manifest,
        "sessions": listed.iter().map(|r| json!({"name": r.0, "id": r.1})).collect::<Vec<_>>(),
        "attached": attached,
        "workspace": workspace,
        "timings": timings,
        "gaps": gaps,
    })
}

fn words(w: &[&str]) -> Vec<String> {
    w.iter().map(|s| (*s).to_owned()).collect()
}

fn short_error(e: &Value) -> String {
    e.pointer("/error/message")
        .or_else(|| e.get("message"))
        .and_then(Value::as_str)
        .map_or_else(|| e.to_string(), str::to_owned)
}

/// (name, id) of every session `acpmux ls --json` printed: an array, or `{sessions: [...]}`.
fn session_rows(v: &Value) -> Vec<(String, String)> {
    let rows = v.as_array().or_else(|| v.get("sessions").and_then(Value::as_array));
    rows.into_iter()
        .flatten()
        .filter_map(|r| {
            let name = r.get("name").and_then(Value::as_str)?;
            let id =
                r.get("id").or_else(|| r.get("sessionId")).and_then(Value::as_str).unwrap_or(name);
            Some((name.to_owned(), id.to_owned()))
        })
        .collect()
}

/// One command on the copy through the platform's machine exec: (exit code, stdout).
async fn exec<P: Platform>(
    platform: &mut P,
    path: &str,
    command: &str,
) -> Result<(i64, String), String> {
    let (status, body) =
        platform.call("POST", path, Some(json!({"command": command, "timeoutMs": 30_000}))).await?;
    let v = value_of(&body);
    if !(200..300).contains(&status) || v.get("ok") == Some(&Value::Bool(false)) {
        return Err(format!("HTTP {status}"));
    }
    let code =
        v.get("exitCode").or_else(|| v.get("exit_code")).and_then(Value::as_i64).unwrap_or(1);
    Ok((code, v.get("stdout").and_then(Value::as_str).unwrap_or_default().to_owned()))
}

/// The platform over HTTP, with the Cloud CLI's credential.
struct Http {
    client: reqwest::Client,
    origin: String,
    team: Option<String>,
    token: Zeroizing<String>,
}

impl Platform for Http {
    async fn call(
        &mut self,
        method: &'static str,
        path: &str,
        body: Option<Value>,
    ) -> Result<(u16, Value), String> {
        let mut url = format!("{}{path}", self.origin);
        if let Some(team) = &self.team {
            url.push_str(if url.contains('?') { "&team=" } else { "?team=" });
            url.push_str(&super::autocloud::percent(team));
        }
        let mut builder = match method {
            "POST" => self.client.post(url),
            "DELETE" => self.client.delete(url),
            _ => self.client.get(url),
        }
        .bearer_auth(self.token.as_str())
        .header("accept", "application/json");
        if let Some(b) = body {
            builder = builder.header("content-type", "application/json").body(b.to_string());
        }
        let response =
            builder.send().await.map_err(|_| "the cmux platform did not answer".to_owned())?;
        let status = response.status().as_u16();
        let bytes = response
            .bytes()
            .await
            .map_err(|_| "the cmux platform's answer was cut off".to_owned())?;
        Ok((status, serde_json::from_slice(&bytes).unwrap_or(Value::Null)))
    }
}

/// The running app through this binary's own app steps.
struct RunningApp(super::GlobalArgs);

impl App for RunningApp {
    fn present(&mut self) -> bool {
        let global = &self.0;
        super::vm::app_present(
            global.app_socket.is_some(),
            global.socket.is_some(),
            || super::app::connect_command(global).is_ok(),
            super::cloud_machines::app_found,
        )
    }
    fn step(&mut self, args: &[String]) -> Result<Value, Value> {
        super::cloud_start_chat::app_step(&self.0, args)
    }
}

fn ask(lines: &[String], yes: bool) -> bool {
    for line in lines {
        eprintln!("{line}");
    }
    if yes {
        return true;
    }
    use std::io::IsTerminal;
    if !std::io::stdin().is_terminal() {
        eprintln!("(not a terminal: pass --yes to go ahead)");
        return false;
    }
    eprint!("Go ahead? [y/N] ");
    let mut answer = String::new();
    std::io::stdin().read_line(&mut answer).is_ok() && matches!(answer.trim(), "y" | "Y" | "yes")
}

fn print(answer: &Value, json_out: bool) {
    if json_out {
        println!("{answer}");
        return;
    }
    if answer.get("ok").and_then(Value::as_bool) != Some(true) {
        let code = answer.pointer("/error/code").and_then(Value::as_str).unwrap_or("error");
        let message = answer.pointer("/error/message").and_then(Value::as_str).unwrap_or_default();
        eprintln!("cmux link: {code}: {message}");
        return;
    }
    if let Some(url) = answer.get("url").and_then(Value::as_str) {
        println!("{url}");
        return;
    }
    println!(
        "opened {} ({} agent session(s) attached)",
        answer["target"].as_str().unwrap_or_default(),
        answer["attached"].as_array().map_or(0, Vec::len)
    );
    if let Some(t) = answer["timings"].as_object() {
        let line: Vec<String> =
            t.iter().map(|(k, v)| format!("{}={v}", k.trim_end_matches("_ms"))).collect();
        println!("ms: {}", line.join(" "));
    }
    for gap in answer["gaps"].as_array().into_iter().flatten() {
        eprintln!("note: {}", gap.as_str().unwrap_or_default());
    }
}

/// `cmux link mint|open ...` (the words after `link`). Exit 0 ok, 1 refused or failed, 2 bad arguments or off.
pub(crate) fn run(words: &[String], json_flag: bool) -> i32 {
    if words.iter().skip(1).any(|w| w == "--help" || w == "-h") {
        print!("{HELP}");
        return 0;
    }
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
    let mut parsed = match parse(words, &env) {
        Ok(p) => p,
        Err(e) => {
            print(&error_json("cli.invalid_args", &e), json_flag);
            return 2;
        }
    };
    parsed.json |= json_flag;
    if !enabled(env(ENV).as_deref(), crate::feature_flags::settings().as_ref()) {
        print(
            &error_json(
                "link.disabled",
                "runnable links are off: set \"cloud\": {\"runnableLinks\": true} in cmux-next.json or CMUX_RUNNABLE_LINKS=1",
            ),
            parsed.json,
        );
        return 2;
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(r) => r,
        Err(e) => {
            print(&error_json("cli.runtime", &e.to_string()), parsed.json);
            return 1;
        }
    };
    let answer = runtime.block_on(async {
        let common = &parsed.common;
        let (token, issued_by) =
            match backend_credential(&common.token, common.team.as_deref()).await {
                Ok(t) => t,
                Err(e) => return error_json("auth.no_token", &e),
            };
        let origin = match platform_for(common.platform.as_deref(), issued_by.as_deref()) {
            Ok(p) => p,
            Err(e) => return error_json("cli.invalid_args", &e),
        };
        if common.platform.is_some() {
            // --platform (or CMUX_PLATFORM_URL) names the origin; the deployment's own origins are listed.
            cmux_egress::allow_named(&origin);
        }
        let client = match cmux_egress::client_builder("cmux_tui::cli::runnable_link")
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
            .timeout(Duration::from_secs(60))
            .build()
        {
            Ok(c) => c,
            Err(e) => return error_json("cli.http_client", &e.to_string()),
        };
        let mut http =
            Http { client, origin, team: common.team.clone(), token: Zeroizing::new(token) };
        let yes = parsed.yes;
        let mut confirm = |lines: &[String]| ask(lines, yes);
        match &parsed.verb {
            Verb::Mint { machine, ttl_seconds, note } => {
                mint(&mut http, machine, *ttl_seconds, note.as_deref(), &mut confirm).await
            }
            Verb::Open { id, no_app } => {
                let mut app = match super::parse_action_globals(&[]) {
                    Ok((global, _)) if !no_app => Some(RunningApp(global)),
                    _ => None,
                };
                open(&mut http, app.as_mut(), id, Waits::default(), &mut confirm).await
            }
        }
    });
    print(&answer, parsed.json);
    if answer.get("ok").and_then(Value::as_bool) == Some(true) { 0 } else { 1 }
}

/// Sets `key` on a JSON object (a no-op on anything else).
fn put(v: &mut Value, key: &str, value: Value) {
    if let Some(map) = v.as_object_mut() {
        map.insert(key.to_owned(), value);
    }
}

#[cfg(test)]
#[path = "runnable_link_tests.rs"]
mod tests;
