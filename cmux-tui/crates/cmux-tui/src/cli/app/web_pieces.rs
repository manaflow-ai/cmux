//! `cmux app web-pieces check|refused|status`: the I/O around the per-piece switch file of
//! cmux's web updates (`cmux-web-pieces`, cmuxterm-hq docs/design/ship-without-update.md).
//!
//! The Mac app runs `check` as a child process and reads the one JSON line it prints: what each
//! web piece (agent pane, pages, viewers, ...) serves, the live update, the last good one or the
//! bundle. This file fetches the signed switch file, keeps what `cmux_web_pieces::evaluate`
//! says to keep between reads (the serial, the last switches taken, the ETag) in
//! `<state>/web-pieces.json`, and keeps a short log in `<state>/web-pieces.log.jsonl`. Every
//! decision is the crate's: nothing here reads a field of the file before its signature is
//! checked there.
//!
//! `refused` asks, offline and with no write, whether the file last taken refuses an update: the
//! app's web updater asks it before it makes a downloaded update active, so a refused update is
//! never served, not even until the next `check` rolls it back.
//!
//! A read that fails, a file that is not published (404) and a refused file all plan from the
//! switches last taken, so a blocked network or a forged file never switches a piece back in.

use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{AppCommand, GlobalArgs, Options, UsageError};

/// Where the switch files are published; `ota/pieces-<channel>.json` under it.
pub(super) const DEFAULT_BASE: &str = "https://files.cmux.com/cmux-next-web/";
/// The channels that have a switch file. A `drill-` channel is the rehearsal of the one it names:
/// the same key and route, and no app reads it unless told to (`updates.web.pieces.check` with
/// `drill`), so a switch can be tried on one Mac before every app takes it.
pub(super) const CHANNELS: &[&str] =
    &["every-merge", "nightly", "drill-every-merge", "drill-nightly"];
/// The state file in `--state`: `{"channel", "floor", "last", "etag", "checked_at"}`.
pub(super) const STATE_FILE: &str = "web-pieces.json";
/// The log in `--state`: one `log` object of a reply per line.
pub(super) const LOG_FILE: &str = "web-pieces.log.jsonl";
/// The log is cut to the newest half of its lines once it passes this.
pub(super) const LOG_MAX_BYTES: u64 = 256 * 1024;
/// How many log lines `status` prints.
pub(super) const STATUS_LINES: usize = 20;
/// The whole GET, connect to last byte: the app waits on this child.
const FETCH_TIMEOUT: Duration = Duration::from_secs(10);
/// An ETag longer than this is not kept (a header the next request must carry).
const ETAG_MAX: usize = 256;

/// English like the JSON it documents: the app, not a person, runs this.
pub(in crate::cli) const USAGE: &str = "usage: cmux app web-pieces check --state <dir> --channel <every-merge|nightly|drill-every-merge|drill-nightly> [--base <url>] [--active <key>] [--kept <key>]... [--offline]\n       cmux app web-pieces refused --state <dir> --channel <channel> --key <key>\n       cmux app web-pieces status --state <dir>\ncheck reads the signed switch file of cmux's web updates (<base>ota/pieces-<channel>.json; base\ndefaults to https://files.cmux.com/cmux-next-web/) and prints one JSON line: what each web piece serves\n(the live update, the last good one or the app's bundle). --active is the key of the web update served now,\n--kept the keys of the older ones on disk, newest first; --offline plans from the kept state with no\nnetwork. It keeps web-pieces.json and web-pieces.log.jsonl in --state. refused prints {\"refused\": bool, \"serial\": n}:\nwhether the switch file last taken in --state refuses the update --key; no network, no write. On a drill-\nchannel refused and refused_active are always false (a drill never rolls back a real update); the\nfile's refusal is reported as drill_refused / drill_refused_active. status prints\nthe state and the log; no network.";

#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) enum Command {
    Check(Check),
    /// Whether the switch file last taken refuses the update `key`.
    Refused {
        state: PathBuf,
        channel: String,
        key: String,
    },
    /// The state file and the last log lines of this folder.
    Status {
        state: PathBuf,
    },
}

#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) struct Check {
    /// The folder of the state file and the log; created (0700) when missing.
    pub state: PathBuf,
    pub channel: String,
    /// Ends with `/`; https, or http to this machine (the tests).
    pub base: String,
    /// The key of the update the app serves; none: its bundle.
    pub active: Option<String>,
    /// The keys of the older updates the app holds, newest first.
    pub kept: Vec<String>,
    /// No network: plan from the kept state.
    pub offline: bool,
}

/// One answer to the GET of the switch file.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Fetched {
    /// 200: the envelope's text and its ETag.
    Body(String, Option<String>),
    /// 304: the file whose ETag the state holds is still the one published.
    NotModified,
    /// 404: no file is published. Not "switch everything back in": the last switches stay.
    Missing,
    /// Any other status, or no answer.
    Failed(String),
}

/// What is kept between checks.
#[derive(Debug, Default, PartialEq, Serialize, Deserialize)]
struct State {
    #[serde(default)]
    channel: String,
    /// The serial of the last file taken: no older file is taken after it.
    #[serde(default)]
    floor: u64,
    /// The `switches` of the reply that took it.
    #[serde(default)]
    last: Option<Value>,
    /// The ETag of the last file taken, never of a refused one: a refused file is fetched and
    /// judged again on the next check.
    #[serde(default)]
    etag: Option<String>,
    /// When the server last answered (unix seconds).
    #[serde(default)]
    checked_at: u64,
}

impl State {
    /// The state file as it is; `None` when missing or unparsable.
    fn read(dir: &Path) -> Option<State> {
        serde_json::from_slice(&read_capped(&dir.join(STATE_FILE))?).ok()
    }

    /// `channel`'s state: another channel's serial and switches say nothing about this one.
    fn of(dir: &Path, channel: &str) -> State {
        State::read(dir).filter(|state| state.channel == channel).unwrap_or_default()
    }
}

/// `rest` starts with `web-pieces`.
pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let usage = || UsageError::new(USAGE);
    let options = |valued: &[&str], flags: &[&str]| {
        Options::parse(rest.get(2..).unwrap_or_default(), valued, flags).map_err(|_| usage())
    };
    let command = match rest.get(1).map(String::as_str) {
        Some("status") => {
            let options = options(&["state"], &[])?;
            Command::Status { state: state_dir(options.value("state")).ok_or_else(usage)? }
        }
        Some("refused") => {
            let options = options(&["state", "channel", "key"], &[])?;
            Command::Refused {
                state: state_dir(options.value("state")).ok_or_else(usage)?,
                channel: channel_of(options.value("channel")).ok_or_else(usage)?.to_owned(),
                key: key_arg(options.value("key").ok_or_else(usage)?)?,
            }
        }
        Some("check") => {
            let options = options(&["state", "channel", "base", "active", "kept"], &["offline"])?;
            let channel = channel_of(options.value("channel")).ok_or_else(usage)?;
            Command::Check(Check {
                state: state_dir(options.value("state")).ok_or_else(usage)?,
                channel: channel.to_owned(),
                base: base_url(options.value("base").unwrap_or(DEFAULT_BASE))
                    .map_err(UsageError::new)?,
                active: options.value("active").map(key_arg).transpose()?,
                kept: options.values("kept").into_iter().map(key_arg).collect::<Result<_, _>>()?,
                offline: options.flag("offline"),
            })
        }
        _ => return Err(usage()),
    };
    Ok(AppCommand::WebPieces(command))
}

fn channel_of(value: Option<&str>) -> Option<&str> {
    value.filter(|channel| CHANNELS.contains(channel))
}

fn key_arg(text: &str) -> Result<String, UsageError> {
    if is_key(text) {
        Ok(text.to_owned())
    } else {
        Err(UsageError::new(format!(
            "cmux app web-pieces: {text:?} is not an update key (64 lowercase hex digits)"
        )))
    }
}

fn state_dir(value: Option<&str>) -> Option<PathBuf> {
    value.filter(|dir| !dir.is_empty()).map(PathBuf::from)
}

/// An update's key: 64 lowercase hex digits (`cmux_web_pieces` reads no other).
fn is_key(text: &str) -> bool {
    text.len() == 64 && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// `text` as the base the switch file is fetched under, ending with `/`. https only, so the
/// request and its ETag cannot be read or answered on the way; plain http only to this machine,
/// which the tests serve from. No credentials, query or fragment: the URL carries no secret.
pub(super) fn base_url(text: &str) -> Result<String, String> {
    let refuse = |why: &str| format!("cmux app web-pieces: --base {text:?} {why}");
    let url = url::Url::parse(text).map_err(|error| refuse(&format!("is not a URL ({error})")))?;
    let local = matches!(url.host_str(), Some("127.0.0.1" | "localhost"));
    match url.scheme() {
        "https" if url.host_str().is_some() => {}
        "http" if local => {}
        _ => return Err(refuse("must be https (http only to 127.0.0.1 or localhost)")),
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(refuse("must not carry credentials"));
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err(refuse("must not carry a query or a fragment"));
    }
    let mut base = url.to_string();
    if !base.ends_with('/') {
        base.push('/');
    }
    Ok(base)
}

/// Where `channel`'s switch file is under `base` ([`base_url`]).
pub(super) fn file_url(base: &str, channel: &str) -> String {
    format!("{base}ota/pieces-{channel}.json")
}

pub(super) fn run(_global: &GlobalArgs, command: &Command) -> i32 {
    let reply = match command {
        Command::Status { state } => Ok(status(state)),
        Command::Refused { state, channel, key } => Ok(refused(state, channel, key)),
        Command::Check(check) => {
            let fetched = (!check.offline).then(|| {
                let etag = State::of(&check.state, &check.channel).etag;
                fetch(&file_url(&check.base, &check.channel), etag.as_deref())
            });
            apply(check, fetched, &cmux_web_pieces::trusted_keys(), now())
        }
    };
    match reply {
        Ok(reply) => {
            // One line whatever the output mode: the app parses it. A closed stdout is the
            // reader's choice, not a failure of the check.
            let _ = writeln!(std::io::stdout().lock(), "{reply}");
            0
        }
        Err(error) => {
            eprintln!("cmux app web-pieces: {error}");
            3
        }
    }
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_secs())
}

/// One check with the GET already answered (`None`: `--offline`, none was made): the reply of
/// `cmux_web_pieces::evaluate_with` against `keys`, plus `fetch` and `state`. Writes the state
/// and the log; `Err` only when the state folder cannot be written.
pub(super) fn apply(
    command: &Check,
    fetched: Option<Fetched>,
    keys: &[(String, [u8; 32])],
    now: u64,
) -> Result<Value, String> {
    let dir = command.state.as_path();
    create_dir(dir)?;
    let on_disk = State::read(dir);
    // A state of another channel is left alone until this channel takes a file.
    let ours = on_disk.as_ref().is_none_or(|state| state.channel == command.channel);
    let mut state = on_disk.filter(|state| state.channel == command.channel).unwrap_or_default();
    let (envelope, etag, answered, fetch) = match fetched {
        None => (None, None, false, json!({"result": "offline"})),
        Some(Fetched::Body(text, etag)) => (Some(text), etag, true, json!({"result": "fetched"})),
        Some(Fetched::NotModified) => (None, None, true, json!({"result": "not_modified"})),
        Some(Fetched::Missing) => (None, None, true, json!({"result": "missing"})),
        Some(Fetched::Failed(error)) => {
            (None, None, false, json!({"result": "failed", "error": error}))
        }
    };
    let mut input = json!({
        "envelope": envelope, "channel": command.channel, "floor": state.floor,
        "active": command.active, "kept": command.kept, "now": now,
    });
    if let (Some(last), Some(input)) = (&state.last, input.as_object_mut()) {
        input.insert("last".to_owned(), last.clone());
    }
    let mut reply = cmux_web_pieces::evaluate_with(&input, keys);
    report_only(&command.channel, &mut reply);
    let taken = reply.get("taken").and_then(Value::as_bool).unwrap_or(false);
    if taken {
        state = State {
            channel: command.channel.clone(),
            floor: reply.get("serial").and_then(Value::as_u64).unwrap_or(state.floor),
            last: reply.get("switches").filter(|switches| !switches.is_null()).cloned(),
            etag: etag.filter(|etag| keeps_etag(etag)),
            checked_at: now,
        };
        write_state(dir, &state)?;
    } else if answered && ours {
        // Not taken: the floor, the switches and the ETag of the last file taken stay.
        state.channel.clone_from(&command.channel);
        state.checked_at = now;
        write_state(dir, &state)?;
    }
    if let Some(line) = reply.get("log") {
        let refused = reply.get("refusal").is_some_and(|refusal| !refusal.is_null());
        log(&dir.join(LOG_FILE), line, refused, LOG_MAX_BYTES)?;
    }
    if let Some(reply) = reply.as_object_mut() {
        reply.insert("fetch".to_owned(), fetch);
        reply.insert("state".to_owned(), json!(dir.display().to_string()));
    }
    Ok(reply)
}

/// `{"refused": bool, "serial": n}`: whether the switch file last taken for `channel` in `dir`
/// refuses the update `key` (the crate's plan with `key` as the active update and no file
/// read), and that file's serial (0: none taken). No network and no write: the updater asks
/// it before it makes a downloaded update active.
pub(super) fn refused(dir: &Path, channel: &str, key: &str) -> Value {
    let state = State::of(dir, channel);
    let mut input = json!({
        "envelope": null, "channel": channel, "floor": state.floor,
        "active": key, "kept": [], "now": 0,
    });
    if let (Some(last), Some(input)) = (&state.last, input.as_object_mut()) {
        input.insert("last".to_owned(), last.clone());
    }
    // No envelope is opened, so no key is needed.
    let mut reply = cmux_web_pieces::evaluate_with(&input, &[]);
    report_only(channel, &mut reply);
    let flag = |name: &str| reply.get(name).and_then(Value::as_bool).unwrap_or(false);
    let mut out = json!({
        "refused": flag("refused_active"),
        "serial": reply.get("serial").cloned().unwrap_or(Value::Null),
    });
    if is_drill(channel)
        && let Some(out) = out.as_object_mut()
    {
        out.insert("drill_refused".to_owned(), json!(flag("drill_refused_active")));
    }
    out
}

fn is_drill(channel: &str) -> bool {
    channel.starts_with("drill-")
}

/// A drill rehearses a switch on this Mac only, so it never rolls back or blocks a real update:
/// on a `drill-` channel the file's refusal of the active update moves from `refused_active`
/// (the app rolls back on it) to `drill_refused_active`, which is only reported. The pieces are
/// still served as the file says: that switch is what a drill tries.
fn report_only(channel: &str, reply: &mut Value) {
    if !is_drill(channel) {
        return;
    }
    if let Some(reply) = reply.as_object_mut() {
        let refused = reply.get("refused_active").and_then(Value::as_bool).unwrap_or(false);
        reply.insert("refused_active".to_owned(), json!(false));
        reply.insert("drill_refused_active".to_owned(), json!(refused));
    }
}

/// `{"state": the state file, "log": its last lines}`; an empty object and no lines for a
/// folder no check has written.
pub(super) fn status(dir: &Path) -> Value {
    let state = read_capped(&dir.join(STATE_FILE))
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}));
    let mut lines = log_lines(&dir.join(LOG_FILE));
    let skip = lines.len().saturating_sub(STATUS_LINES);
    lines.drain(..skip);
    json!({"state": state, "log": lines})
}

/// An ETag the next request can carry as `If-None-Match`.
fn keeps_etag(etag: &str) -> bool {
    !etag.is_empty() && etag.len() <= ETAG_MAX && etag.bytes().all(|b| (0x21..0x7f).contains(&b))
}

/// At most a state file's or a log's worth of `path`; `None` when it cannot be read.
fn read_capped(path: &Path) -> Option<Vec<u8>> {
    let mut bytes = Vec::new();
    std::fs::File::open(path).ok()?.take(4 * LOG_MAX_BYTES).read_to_end(&mut bytes).ok()?;
    Some(bytes)
}

/// The log's lines that parse, oldest first.
fn log_lines(path: &Path) -> Vec<Value> {
    let bytes = read_capped(path).unwrap_or_default();
    String::from_utf8_lossy(&bytes)
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(Value::is_object)
        .collect()
}

fn create_dir(dir: &Path) -> Result<(), String> {
    use std::os::unix::fs::DirBuilderExt as _;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|error| format!("{}: {error}", dir.display()))
}

/// `bytes` as `path`, whole or not at all: a temp file beside it, renamed over it.
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let failed = |error: std::io::Error| format!("{}: {error}", path.display());
    let dir = path.parent().unwrap_or(Path::new("."));
    let mut temp = tempfile::NamedTempFile::new_in(dir).map_err(failed)?;
    temp.write_all(bytes).map_err(failed)?;
    temp.persist(path).map(|_| ()).map_err(|error| failed(error.error))
}

fn write_state(dir: &Path, state: &State) -> Result<(), String> {
    let mut bytes = serde_json::to_vec(state).map_err(|error| error.to_string())?;
    bytes.push(b'\n');
    write_atomic(&dir.join(STATE_FILE), &bytes)
}

/// Appends `line` (a reply's `log`) unless it says what the last line says: the same verdict,
/// serial, switched pieces and refused-active flag. A refusal (`refused`) is always written, once
/// per check. So a quiet check every minute adds nothing, and every change and every refused
/// file is on record. Past `max` bytes the log is cut to the newest half of its lines.
pub(super) fn log(path: &Path, line: &Value, refused: bool, max: u64) -> Result<(), String> {
    const SAME: &[&str] = &["verdict", "serial", "switched", "refused_active"];
    let failed = |error: std::io::Error| format!("{}: {error}", path.display());
    let before = read_capped(path).unwrap_or_default();
    let before = String::from_utf8_lossy(&before);
    let last = before.lines().rev().find_map(|line| serde_json::from_str::<Value>(line).ok());
    let same = last.is_some_and(|last| SAME.iter().all(|key| last.get(key) == line.get(key)));
    if same && !refused {
        return Ok(());
    }
    let text = format!("{line}\n");
    if (before.len() + text.len()) as u64 > max {
        let lines: Vec<&str> = before.lines().collect();
        let mut kept = lines.get(lines.len() / 2 + 1..).unwrap_or_default().join("\n");
        if !kept.is_empty() {
            kept.push('\n');
        }
        kept.push_str(&text);
        return write_atomic(path, kept.as_bytes());
    }
    use std::os::unix::fs::OpenOptionsExt as _;
    std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .open(path)
        .and_then(|mut file| file.write_all(text.as_bytes()))
        .map_err(failed)
}

/// GET of the switch file at `url`, with `If-None-Match: etag` when the state holds one. One
/// request: a redirect is not followed (the file is served where it is published, and no other
/// host gets the request), the whole exchange ends within [`FETCH_TIMEOUT`], and no more than
/// `cmux_web_pieces::MAX_BYTES` of a body are read. The client is the one `cmux customize use`
/// fetches its signed pointers with (cli/customize/pr.rs).
pub(super) fn fetch(url: &str, etag: Option<&str>) -> Fetched {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            return Fetched::Failed(format!("could not start a network runtime: {error}"));
        }
    };
    let client = cmux_egress::client_builder("cmux_tui::cli::app::web_pieces")
        .timeout(FETCH_TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!("cmux-web-pieces/", env!("CARGO_PKG_VERSION")))
        .build();
    let client = match client {
        Ok(client) => client,
        Err(error) => return Fetched::Failed(format!("could not start an HTTP client: {error}")),
    };
    let answer = runtime.block_on(async {
        let mut request = client.get(url).header(reqwest::header::ACCEPT, "application/json");
        if let Some(etag) = etag.filter(|etag| keeps_etag(etag)) {
            request = request.header(reqwest::header::IF_NONE_MATCH, etag);
        }
        let mut response = request.send().await.map_err(|error| format!("{url}: {error}"))?;
        match response.status() {
            reqwest::StatusCode::OK => {}
            reqwest::StatusCode::NOT_MODIFIED => return Ok(Fetched::NotModified),
            reqwest::StatusCode::NOT_FOUND => return Ok(Fetched::Missing),
            other => return Err(format!("{url}: HTTP {}", other.as_u16())),
        }
        let etag = response
            .headers()
            .get(reqwest::header::ETAG)
            .and_then(|etag| etag.to_str().ok())
            .map(str::to_owned);
        let limit = cmux_web_pieces::MAX_BYTES;
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|error| format!("{url}: {error}"))? {
            if body.len() + chunk.len() > limit {
                return Err(format!("{url}: larger than {limit} bytes"));
            }
            body.extend_from_slice(&chunk);
        }
        // Bytes that are not text are no envelope: the crate refuses them, on the log.
        Ok(Fetched::Body(String::from_utf8_lossy(&body).into_owned(), etag))
    });
    answer.unwrap_or_else(Fetched::Failed)
}

#[cfg(test)]
#[path = "web_pieces_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "web_pieces_seeded_tests.rs"]
mod seeded_tests;
