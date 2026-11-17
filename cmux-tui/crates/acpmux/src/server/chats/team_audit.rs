//! `_acpmux/team_audit {since?, until?, groupBy?, format?}`: the team's agent spend (History > Team
//! in the app, behind the webviews `team-audit` experiment), from cmux-platform's
//! `GET /v1/usage/audit` over the turns teammates share with their team. Read with this daemon's
//! cmux sign-in (`meshRelay.tokenCommand`, the team-install token the artifact tools use too),
//! which goes only to the relay's own origin: the cmux-platform the person already signs in to.
//! Spend is the person's data, like `_acpmux/ledger`: the local unix socket and the app's own pane
//! (LocalApp) get it; a Web or Peer origin gets "Method not found".
//!
//! Answers `{status}`: `ok` with the platform's `audit`; `saved` with the `path` a CSV was written
//! to (format csv, the Downloads folder); `signedOut` (no sign-in, or a joined machine's
//! credential the route refuses); `off` (404: the audit is off there); `notShared` (403: not in
//! a sharing team); `failed` with a `message`.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

use super::super::Origin;
use crate::mesh_http::{HttpHub, MeshRelayConfig};
use crate::rpc::{RpcError, method};

pub(super) const GROUPS: [&str; 6] = ["person", "repo", "model", "harness", "machine", "day"];
const CALL_TIMEOUT: Duration = Duration::from_secs(30);
/// The largest answer read (JSON or CSV).
const MAX_ANSWER_BYTES: usize = 4 << 20;
const DEFAULT_CSV_NAME: &str = "cmux-agent-spend.csv";

#[derive(Debug, PartialEq)]
pub(super) struct AuditQuery {
    since: Option<String>,
    until: Option<String>,
    group_by: &'static str,
    csv: bool,
}

/// A UTC day as the platform takes it: `YYYY-MM-DD`.
fn is_day(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() == 10
        && bytes
            .iter()
            .enumerate()
            .all(|(i, b)| if i == 4 || i == 7 { *b == b'-' } else { b.is_ascii_digit() })
}

impl AuditQuery {
    pub(super) fn from_params(params: &Value) -> Result<Self, String> {
        let day = |key: &str| -> Result<Option<String>, String> {
            match params.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(text)) if is_day(text) => Ok(Some(text.clone())),
                Some(_) => Err(format!("{key} must be a UTC day, YYYY-MM-DD")),
            }
        };
        let group_by = match params.get("groupBy") {
            None | Some(Value::Null) => "person",
            Some(Value::String(text)) => GROUPS
                .iter()
                .copied()
                .find(|g| g == text)
                .ok_or_else(|| format!("unknown groupBy {text:?}"))?,
            Some(_) => return Err("groupBy must be a string".into()),
        };
        let csv = match params.get("format").and_then(Value::as_str) {
            None | Some("json") => false,
            Some("csv") => true,
            Some(other) => return Err(format!("unknown format {other:?}")),
        };
        Ok(Self { since: day("since")?, until: day("until")?, group_by, csv })
    }
}

pub(super) async fn handle(origin: Origin, params: &Value) -> Result<Value, RpcError> {
    if !matches!(origin, Origin::Local | Origin::LocalApp) {
        return Err(RpcError::method_not_found(method::MUX_TEAM_AUDIT));
    }
    let query = AuditQuery::from_params(params).map_err(RpcError::invalid_params)?;
    let Some(client) = client() else {
        return Ok(json!({"status": "signedOut"}));
    };
    Ok(client.read(&query).await)
}

struct Client {
    origin: String,
    hub: HttpHub,
    http: reqwest::Client,
}

/// The client for config.json's `meshRelay`, kept while that stays the same (the hub holds the
/// token it minted until it expires). None without a person's sign-in.
fn client() -> Option<Arc<Client>> {
    static HELD: Mutex<Option<(MeshRelayConfig, Arc<Client>)>> = Mutex::new(None);
    let text = std::fs::read_to_string(crate::config::Config::path()).unwrap_or_default();
    let (_, relay) = crate::acpmux_mcp::artifacts::settings_from(&text);
    let relay = relay.filter(|r| r.credential.as_deref() != Some("join"))?;
    relay.origin().ok()?;
    let mut held = HELD.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some((config, client)) = held.as_ref()
        && *config == relay
    {
        return Some(Arc::clone(client));
    }
    let origin = reqwest::Url::parse(relay.url.trim()).ok()?.origin().ascii_serialization();
    let hub = HttpHub::new(&relay).ok()?;
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION")))
        .build()
        .ok()?;
    let client = Arc::new(Client { origin, hub, http });
    *held = Some((relay, Arc::clone(&client)));
    Some(client)
}

fn failed(message: impl Into<String>) -> Value {
    json!({"status": "failed", "message": message.into()})
}

impl Client {
    async fn read(&self, query: &AuditQuery) -> Value {
        let Ok(mut url) = reqwest::Url::parse(&format!("{}/v1/usage/audit", self.origin)) else {
            return failed("the cmux sign-in names no usable origin");
        };
        {
            let mut pairs = url.query_pairs_mut();
            if let Some(since) = &query.since {
                pairs.append_pair("since", since);
            }
            if let Some(until) = &query.until {
                pairs.append_pair("until", until);
            }
            pairs.append_pair("groupBy", query.group_by);
            pairs.append_pair("format", if query.csv { "csv" } else { "json" });
        }
        let mut fresh = false;
        loop {
            let Ok(token) = self.hub.token(fresh).await else {
                return json!({"status": "signedOut"});
            };
            let sent = self
                .http
                .get(url.clone())
                .bearer_auth(token.as_str())
                .timeout(CALL_TIMEOUT)
                .send()
                .await;
            let response = match sent {
                Ok(response) => response,
                Err(e) => {
                    return failed(format!("cmux-platform did not answer: {}", e.without_url()));
                }
            };
            let status = response.status().as_u16();
            // A token the platform no longer takes: one more try with a new one.
            if status == 401 && !fresh {
                fresh = true;
                continue;
            }
            let disposition = response
                .headers()
                .get(reqwest::header::CONTENT_DISPOSITION)
                .and_then(|v| v.to_str().ok())
                .map(str::to_owned);
            let body = match read_capped(response).await {
                Ok(body) => body,
                Err(message) => return failed(message),
            };
            return match status {
                200 if query.csv => save_csv(&body, disposition.as_deref()).await,
                200 => match serde_json::from_slice::<Value>(&body) {
                    Ok(audit) => json!({"status": "ok", "audit": audit}),
                    Err(_) => failed("cmux-platform's answer is not JSON"),
                },
                401 => json!({"status": "signedOut"}),
                403 => json!({"status": "notShared"}),
                404 => json!({"status": "off"}),
                _ => failed(refusal(status, &body)),
            };
        }
    }
}

/// The refusal's code when the platform sent one, else the status.
fn refusal(status: u16, body: &[u8]) -> String {
    let code = serde_json::from_slice::<Value>(body)
        .ok()
        .and_then(|v| v.get("code").and_then(Value::as_str).map(str::to_owned))
        .filter(|code| {
            code.len() <= 64
                && code.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_')
        });
    match code {
        Some(code) => format!("cmux-platform refused ({status} {code})"),
        None => format!("cmux-platform refused ({status})"),
    }
}

async fn read_capped(mut response: reqwest::Response) -> Result<Vec<u8>, String> {
    let mut body = Vec::new();
    loop {
        match response.chunk().await {
            Ok(Some(chunk)) => {
                if body.len() + chunk.len() > MAX_ANSWER_BYTES {
                    return Err("cmux-platform's answer is too large".into());
                }
                body.extend_from_slice(&chunk);
            }
            Ok(None) => return Ok(body),
            Err(e) => return Err(format!("cmux-platform's answer broke off: {}", e.without_url())),
        }
    }
}

/// The file name the platform suggests (`attachment; filename="..."`), when it is a plain CSV name.
fn suggested_name(disposition: Option<&str>) -> String {
    disposition
        .and_then(|d| d.split("filename=").nth(1))
        .map(|name| name.trim().trim_matches('"'))
        .filter(|name| {
            name.len() <= 120
                && name.ends_with(".csv")
                && !name.starts_with('.')
                && name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        })
        .map_or_else(|| DEFAULT_CSV_NAME.to_owned(), str::to_owned)
}

/// How many names one download tries: `name`, then `name 2` to `name 999`.
const CSV_NAMES: usize = 999;

/// `name` in `dir`, then `name` with ` 2`, ` 3`, ... before `.csv`, `limit` names in all.
fn candidates(dir: &Path, name: &str, limit: usize) -> impl Iterator<Item = PathBuf> {
    let stem = name.strip_suffix(".csv").unwrap_or(name).to_owned();
    let dir = dir.to_owned();
    let first = dir.join(name);
    std::iter::once(first)
        .chain((2..).map(move |n| dir.join(format!("{stem} {n}.csv"))))
        .take(limit)
}

/// Writes `body` to the first of `name`'s candidates in `dir` that does not exist yet. Each file
/// is opened with `create_new`, so the check and the create are one step: two downloads at once
/// get two files, and a download never replaces or truncates a file. When every name is taken it
/// fails and touches nothing.
async fn write_new(dir: &Path, name: &str, body: &[u8], limit: usize) -> Result<PathBuf, String> {
    use tokio::io::AsyncWriteExt;
    for path in candidates(dir, name, limit) {
        let opened = tokio::fs::OpenOptions::new().write(true).create_new(true).open(&path).await;
        let mut file = match opened {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(format!("could not write {}: {e}", path.display())),
        };
        let written = match file.write_all(body).await {
            Ok(()) => file.flush().await,
            Err(e) => Err(e),
        };
        return match written {
            Ok(()) => Ok(path),
            Err(e) => {
                // This download made the file, so a half-written one goes with it.
                drop(file);
                let _ = tokio::fs::remove_file(&path).await;
                Err(format!("could not write {}: {e}", path.display()))
            }
        };
    }
    Err(format!("{name} and {} numbered copies already exist in {}", limit - 1, dir.display()))
}

/// The CSV with every cell a spreadsheet would read as a formula made text: a cell starting with
/// `=`, `+`, `-`, `@` or a tab (a quoted one also with a carriage return) gets a leading `'`, the
/// usual CSV injection defence, so a session title or person name like `=HYPERLINK(...)` opens as
/// text in a spreadsheet app. A plain number (`-12.5`) stays a number. Quoting is RFC 4180's: a quoted cell may hold commas, line breaks and `""`.
fn defuse_formulas(body: &[u8]) -> Vec<u8> {
    fn is_number(cell: &[u8]) -> bool {
        let digits = cell.strip_prefix(b"-").or_else(|| cell.strip_prefix(b"+")).unwrap_or(cell);
        let mut parts = digits.splitn(2, |b| *b == b'.');
        let whole = parts.next().unwrap_or_default();
        let fraction = parts.next();
        !whole.is_empty()
            && whole.iter().all(u8::is_ascii_digit)
            && fraction.is_none_or(|f| !f.is_empty() && f.iter().all(u8::is_ascii_digit))
    }
    /// A cell that starts with `first` (its whole text `cell`) would be read as a formula.
    fn risky(first: u8, cell: &[u8], quoted: bool) -> bool {
        match first {
            b'=' | b'@' | b'\t' => true,
            b'\r' => quoted,
            b'+' | b'-' => !is_number(cell),
            _ => false,
        }
    }
    let mut out = Vec::with_capacity(body.len() + 64);
    let (mut at_start, mut quoted) = (true, false);
    let mut rest = body;
    while let Some((&byte, after)) = rest.split_first() {
        if at_start {
            at_start = false;
            if byte == b'"' {
                quoted = true;
                out.push(b'"');
                let end = after.iter().position(|b| *b == b'"').unwrap_or(after.len());
                let cell = after.get(..end).unwrap_or(after);
                if let Some(&first) = cell.first()
                    && risky(first, cell, true)
                {
                    out.push(b'\'');
                }
                rest = after;
                continue;
            }
            let end =
                rest.iter().position(|b| matches!(b, b',' | b'\r' | b'\n')).unwrap_or(rest.len());
            if risky(byte, rest.get(..end).unwrap_or(rest), false) {
                out.push(b'\'');
            }
        }
        if quoted {
            if byte == b'"' {
                if after.first() == Some(&b'"') {
                    out.extend_from_slice(b"\"\"");
                    rest = after.get(1..).unwrap_or_default();
                    continue;
                }
                quoted = false;
            }
        } else if matches!(byte, b',' | b'\r' | b'\n') {
            at_start = true;
        }
        out.push(byte);
        rest = after;
    }
    out
}

async fn save_csv(body: &[u8], disposition: Option<&str>) -> Value {
    let Some(dir) = dirs::download_dir().or_else(dirs::home_dir) else {
        return failed("no Downloads folder");
    };
    let body = defuse_formulas(body);
    match write_new(&dir, &suggested_name(disposition), &body, CSV_NAMES).await {
        Ok(path) => json!({"status": "saved", "path": path.to_string_lossy()}),
        Err(message) => failed(message),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_days_groupings_and_formats_and_refuses_anything_else() {
        assert_eq!(
            AuditQuery::from_params(&json!({})).unwrap(),
            AuditQuery { since: None, until: None, group_by: "person", csv: false }
        );
        assert_eq!(
            AuditQuery::from_params(
                &json!({"since": "2026-11-01", "until": "2026-11-09", "groupBy": "machine", "format": "csv"})
            )
            .unwrap(),
            AuditQuery {
                since: Some("2026-11-01".into()),
                until: Some("2026-11-09".into()),
                group_by: "machine",
                csv: true
            }
        );
        for bad in [
            json!({"since": "yesterday"}),
            json!({"until": 1762646400000u64}),
            json!({"since": "2026-11-1"}),
            json!({"groupBy": "team"}),
            json!({"groupBy": ["day"]}),
            json!({"format": "xml"}),
        ] {
            assert!(AuditQuery::from_params(&bad).is_err(), "{bad}");
        }
    }

    #[tokio::test]
    async fn only_the_local_socket_and_the_app_read_the_team_audit() {
        for origin in [Origin::Web, Origin::Peer] {
            let err = handle(origin, &json!({})).await.unwrap_err();
            assert!(format!("{err:?}").contains("_acpmux/team_audit"), "{err:?}");
        }
        assert!(handle(Origin::Local, &json!({"groupBy": "nope"})).await.is_err());
    }

    #[test]
    fn a_csv_keeps_a_plain_suggested_name() {
        assert_eq!(
            suggested_name(Some(
                r#"attachment; filename="cmux-agent-spend-2026-11-01-2026-11-09-model.csv""#
            )),
            "cmux-agent-spend-2026-11-01-2026-11-09-model.csv"
        );
        for odd in [
            None,
            Some("attachment"),
            Some(r#"attachment; filename="../x.csv""#),
            Some("filename=a.sh"),
        ] {
            assert_eq!(suggested_name(odd), DEFAULT_CSV_NAME, "{odd:?}");
        }
    }

    #[tokio::test]
    async fn a_csv_never_replaces_a_file_and_concurrent_downloads_get_their_own() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.csv"), "theirs").unwrap();
        let saved = write_new(dir.path(), "a.csv", b"mine", CSV_NAMES).await.unwrap();
        assert_eq!(saved, dir.path().join("a 2.csv"));
        assert_eq!(std::fs::read_to_string(dir.path().join("a.csv")).unwrap(), "theirs");
        assert_eq!(std::fs::read_to_string(&saved).unwrap(), "mine");

        let both = tempfile::tempdir().unwrap();
        let downloads = (0..16).map(|i| {
            let dir = both.path().to_owned();
            tokio::spawn(async move {
                let body = format!("download {i}");
                let path = write_new(&dir, "b.csv", body.as_bytes(), CSV_NAMES).await.unwrap();
                (path, body)
            })
        });
        let mut paths = std::collections::BTreeSet::new();
        for download in downloads.collect::<Vec<_>>() {
            let (path, body) = download.await.unwrap();
            assert_eq!(std::fs::read_to_string(&path).unwrap(), body);
            assert!(paths.insert(path));
        }
        assert_eq!(paths.len(), 16);
    }

    #[tokio::test]
    async fn a_csv_fails_when_every_name_is_taken_and_touches_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let taken: Vec<_> = candidates(dir.path(), "c.csv", 3).collect();
        assert_eq!(
            taken,
            ["c.csv", "c 2.csv", "c 3.csv"].map(|name| dir.path().join(name)).to_vec()
        );
        for path in &taken {
            std::fs::write(path, "theirs").unwrap();
        }
        let err = write_new(dir.path(), "c.csv", b"mine", 3).await.unwrap_err();
        assert!(err.contains("already exist"), "{err}");
        for path in &taken {
            assert_eq!(std::fs::read_to_string(path).unwrap(), "theirs");
        }
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 3);
    }

    /// CMUX-284: the platform's CSV went to Downloads as it came, so a cell a teammate controls (a
    /// session title, a name) starting with `=`, `+`, `-` or `@` ran as a formula when opened.
    #[test]
    fn a_saved_csv_opens_formulas_as_text() {
        let body = b"person,title,cost,note\r\n\
alice,=HYPERLINK(\"http://x\"),-12.5,ok\r\n\
bob,\"=1+1, \"\"quoted\"\"\",+3,@SUM(A1)\r\n\
carol,-2+3,\"\r=x\",\tlead\n\
dave,,\"plain, text\",+cmd|' /C calc'!A0\n\
eve,\"multi\nline\",7,";
        let want = b"person,title,cost,note\r\n\
alice,'=HYPERLINK(\"http://x\"),-12.5,ok\r\n\
bob,\"'=1+1, \"\"quoted\"\"\",+3,'@SUM(A1)\r\n\
carol,'-2+3,\"'\r=x\",'\tlead\n\
dave,,\"plain, text\",'+cmd|' /C calc'!A0\n\
eve,\"multi\nline\",7,";
        assert_eq!(String::from_utf8_lossy(&defuse_formulas(body)), String::from_utf8_lossy(want));
        // A CSV with nothing risky is the same bytes.
        let plain = b"a,b\n\"x, y\",-1\n";
        assert_eq!(defuse_formulas(plain), plain.to_vec());
    }

    #[test]
    fn a_refusal_names_only_a_plain_code() {
        assert_eq!(
            refusal(503, br#"{"code":"usage.unavailable"}"#),
            "cmux-platform refused (503 usage.unavailable)"
        );
        assert_eq!(refusal(500, b"<html>secret</html>"), "cmux-platform refused (500)");
        assert_eq!(refusal(400, br#"{"code":"has spaces in it"}"#), "cmux-platform refused (400)");
    }
}
