//! `cmux machine NAME doctor`: reach another of your Macs over the cmux link
//! (docs/multi-machine-sessions.md).
//!
//! The app's hostd keeps the warm signaling socket; it serves a local socket
//! beside the app's daemon socket (`<session>.link.sock`, this user only).
//! This command asks it for your Macs, picks NAME (its name, device id or
//! machine id; one match or an error listing them), opens the `machine`
//! service there, and prints how long the link took and what that Mac says:
//! its OS, whether someone is logged in at its desktop, and what it allows
//! this Mac to do. The first time, that Mac asks its person (and their phone)
//! to allow this one; the command says so while it waits.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

const USAGE: &str = "usage: cmux machine NAME doctor
  reach another of your Macs over the cmux link: how long it took and what it allows this Mac
  NAME is the Mac's name, device id or machine id (`cmux machine NAME doctor` lists them when none matches)";

/// Words after `machine` this module answers (selector first, so a machine's
/// name never collides with the Cloud verbs).
const VERBS: &[&str] = &["doctor"];

const TRAFFIC_USAGE: &str = "usage: cmux device traffic [--json]
  this Mac's bytes in and out per service through its iPhone and machine link host (cmux-mobile-host):
  totals since it started, and per second over the last 10 s and 60 s";

const SELF_CHECK_USAGE: &str =
    "usage: cmux device self-check [--phone ID] [--rows 1,...,9] [--out DIR] [--json]
  hidden debug: the iPhone draws each lean terminal case beside its PTY one and pixel-diffs them;
  the images and report.json go to DIR (default ./cmux-self-check-<UTC YYYYMMDD-HHMMSS>).
  Exits 0 when every row passes, 1 otherwise";

/// `Some(exit code)` when `args` is `machine NAME doctor`, `device traffic` or
/// `device self-check`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    if let [noun, verb, rest @ ..] = words.as_slice()
        && noun == "device"
        && verb == "self-check"
    {
        return Some(match SelfCheckArgs::parse(rest) {
            Ok(parsed) => self_check(&global, &parsed),
            Err(message) => super::app::failure(
                "usage.invalid",
                &format!("cmux: {message}\n{SELF_CHECK_USAGE}"),
                global.output,
                2,
            ),
        });
    }
    if let [noun, verb, rest @ ..] = words.as_slice()
        && matches!(noun.as_str(), "device" | "machine")
        && verb == "traffic"
    {
        if !rest.is_empty() {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {TRAFFIC_USAGE}"),
                global.output,
                2,
            ));
        }
        return Some(traffic(&global));
    }
    let [noun, name, verb, rest @ ..] = words.as_slice() else { return None };
    if noun != "machine"
        || !VERBS.contains(&verb.as_str())
        || name.starts_with('-')
        || name == "doctor"
    {
        return None;
    }
    if !rest.is_empty() {
        return Some(super::app::failure(
            "usage.invalid",
            &format!("cmux: {USAGE}"),
            global.output,
            2,
        ));
    }
    Some(doctor(&global, name))
}

fn link_socket(daemon: &Path) -> PathBuf {
    let stem = daemon.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    daemon.with_file_name(format!("{stem}.link.sock"))
}

/// One request line, then one answer line (or `pending` lines first).
struct Conversation {
    reader: BufReader<UnixStream>,
}

impl Conversation {
    fn start(socket: &Path, request: &Value) -> Result<Self, (String, String)> {
        let mut stream = UnixStream::connect(socket).map_err(|error| {
            (
                "machine.link_unavailable".to_owned(),
                format!(
                    "cannot reach this Mac's cmux link at {} ({error}); is the cmux app running and signed in, \
                     with Let My Other Devices Use This Mac on?",
                    socket.display()
                ),
            )
        })?;
        stream.set_read_timeout(Some(Duration::from_secs(180))).ok();
        let mut line = request.to_string().into_bytes();
        line.push(b'\n');
        stream
            .write_all(&line)
            .map_err(|e| ("machine.link_unavailable".to_owned(), e.to_string()))?;
        Ok(Self { reader: BufReader::new(stream) })
    }

    fn next(&mut self) -> Result<Value, (String, String)> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) => Err(("machine.closed".to_owned(), "the link closed".to_owned())),
            Ok(_) => serde_json::from_str(&line)
                .map_err(|_| ("machine.bad_reply".to_owned(), line.clone())),
            Err(error) => Err(("machine.timeout".to_owned(), error.to_string())),
        }
    }
}

fn refused(answer: &Value) -> Option<(String, String)> {
    let code = answer.get("error").and_then(Value::as_str)?;
    let message = answer.get("message").and_then(Value::as_str).unwrap_or_default();
    let text = match code {
        "denied" => "that Mac's person did not allow this Mac".to_owned(),
        "offline" => "that Mac is offline (asleep, or cmux is not running there)".to_owned(),
        "timeout" => {
            "nobody answered on that Mac; allow this Mac there or on your phone, then try again"
                .to_owned()
        }
        _ => message.to_owned(),
    };
    Some((format!("machine.{code}"), text))
}

/// The one Mac `name` picks from the hostd list, or why not.
fn pick<'a>(machines: &'a [Value], name: &str) -> Result<&'a Value, String> {
    let text =
        |m: &Value, key: &str| m.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
    // Not this Mac: neither this build nor another build of the same computer.
    let mine: Vec<String> = machines
        .iter()
        .filter(|m| m.get("this").and_then(Value::as_bool) == Some(true))
        .map(|m| text(m, "machine_id"))
        .filter(|id| !id.is_empty())
        .collect();
    let others: Vec<&Value> = machines
        .iter()
        .filter(|m| {
            m.get("this").and_then(Value::as_bool) != Some(true)
                && !mine.contains(&text(m, "machine_id"))
        })
        .collect();
    let wanted = name.to_lowercase();
    let exact: Vec<&Value> = others
        .iter()
        .copied()
        .filter(|m| {
            text(m, "name").to_lowercase() == wanted
                || text(m, "device_id").to_lowercase() == wanted
                || (!wanted.is_empty() && text(m, "machine_id").starts_with(&wanted))
        })
        .collect();
    // Several builds of one computer share its machine id: prefer the online one.
    let online: Vec<&Value> = exact
        .iter()
        .copied()
        .filter(|m| m.get("online").and_then(Value::as_bool) == Some(true))
        .collect();
    match (exact.as_slice(), online.as_slice()) {
        ([one], _) | (_, [one]) => Ok(*one),
        ([], _) => {
            let names: Vec<String> = others.iter().map(|m| text(m, "name")).collect();
            Err(format!("no Mac named {name}; your other Macs: {}", names.join(", ")))
        }
        (many, _) => {
            let ids: Vec<String> = many
                .iter()
                .map(|m| format!("{} ({})", text(m, "name"), text(m, "device_id")))
                .collect();
            Err(format!("{name} names several Macs: {}; use a device id", ids.join(", ")))
        }
    }
}

/// `cmux device traffic`: the link host's `{"op":"traffic"}` answer, as JSON or a table.
fn traffic(global: &GlobalArgs) -> i32 {
    let output = global.output;
    let fail = |(code, message): (String, String)| {
        super::app::failure(&code, &format!("cmux: {message}"), output, 1)
    };
    let daemon = match super::wire::resolve_socket_or_report(global) {
        Ok((socket, _)) => socket,
        Err(code) => return code,
    };
    let answer = Conversation::start(&link_socket(&daemon), &json!({"op": "traffic"}))
        .and_then(|mut c| c.next());
    let answer = match answer {
        Ok(answer) => answer,
        Err(error) => return fail(error),
    };
    if let Some(error) = refused(&answer) {
        return fail(error);
    }
    match output {
        OutputMode::Human => print!("{}", traffic_table(&answer)),
        OutputMode::Json | OutputMode::JsonLines => println!("{answer}"),
        OutputMode::Quiet => {}
    }
    0
}

/// Bytes as B, KB, MB or GB (powers of 1000, one decimal past B).
fn human_bytes(bytes: u64) -> String {
    let units = ["KB", "MB", "GB", "TB"];
    if bytes < 1000 {
        return format!("{bytes} B");
    }
    let mut value = bytes as f64 / 1000.0;
    let mut unit = 0;
    while value >= 1000.0 && unit + 1 < units.len() {
        value /= 1000.0;
        unit += 1;
    }
    format!("{value:.1} {}", units.get(unit).copied().unwrap_or("TB"))
}

/// One row per service that moved a byte, busiest first, then the total.
fn traffic_table(answer: &Value) -> String {
    let number = |row: &Value, key: &str| row.get(key).and_then(Value::as_u64).unwrap_or(0);
    let mut rows: Vec<&Value> = answer
        .get("services")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter().filter(|r| number(r, "in_bytes") + number(r, "out_bytes") > 0).collect()
        })
        .unwrap_or_default();
    rows.sort_by_key(|r| std::cmp::Reverse(number(r, "in_per_s_60s") + number(r, "out_per_s_60s")));
    let mut text = format!(
        "{:<16} {:>10} {:>10} {:>10} {:>10} {:>10} {:>10}\n",
        "service", "in/s 10s", "out/s 10s", "in/s 60s", "out/s 60s", "in total", "out total"
    );
    let total = answer.get("total").cloned().unwrap_or(Value::Null);
    for row in rows.into_iter().chain(std::iter::once(&total)) {
        let rate = |key: &str| format!("{}/s", human_bytes(number(row, key)));
        text.push_str(&format!(
            "{:<16} {:>10} {:>10} {:>10} {:>10} {:>10} {:>10}\n",
            row.get("service").and_then(Value::as_str).unwrap_or("?"),
            rate("in_per_s_10s"),
            rate("out_per_s_10s"),
            rate("in_per_s_60s"),
            rate("out_per_s_60s"),
            human_bytes(number(row, "in_bytes")),
            human_bytes(number(row, "out_bytes")),
        ));
    }
    let uptime = answer.get("uptime_s").and_then(Value::as_u64).unwrap_or(0);
    text.push_str(&format!(
        "since the host started {uptime} s ago; payload bytes, without link framing or encryption\n"
    ));
    text
}

/// `cmux device self-check`'s options.
#[derive(Debug, Default, PartialEq)]
struct SelfCheckArgs {
    phone: Option<String>,
    /// Empty: every row.
    rows: Vec<u64>,
    out: Option<PathBuf>,
}

impl SelfCheckArgs {
    fn parse(words: &[String]) -> Result<Self, String> {
        let mut parsed = Self::default();
        let mut words = words.iter();
        while let Some(word) = words.next() {
            let (key, inline) = match word.split_once('=') {
                Some((key, value)) if key.starts_with("--") => (key, Some(value.to_owned())),
                _ => (word.as_str(), None),
            };
            let mut value = || {
                inline
                    .clone()
                    .or_else(|| words.next().cloned())
                    .ok_or(format!("{key} needs a value"))
            };
            match key {
                "--phone" => parsed.phone = Some(value()?),
                "--rows" => parsed.rows = self_check_rows(&value()?)?,
                "--out" => parsed.out = Some(PathBuf::from(value()?)),
                other => return Err(format!("unknown argument {other}")),
            }
        }
        Ok(parsed)
    }
}

/// `1,2,9` as rows 1 to 9, each once, in order.
fn self_check_rows(text: &str) -> Result<Vec<u64>, String> {
    let mut rows = Vec::new();
    for part in text.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        match part.parse::<u64>() {
            Ok(row) if (1..=9).contains(&row) => rows.push(row),
            _ => return Err(format!("rows are numbers 1 to 9, not {part}")),
        }
    }
    rows.sort_unstable();
    rows.dedup();
    Ok(rows)
}

/// `cmux device self-check`: the link host relays the ask to the iPhone, which draws
/// each lean terminal case beside its PTY one and pixel-diffs them; the host judges
/// the counts. Progress per case on stderr, then one line per row; the images and
/// `report.json` go to the out folder.
fn self_check(global: &GlobalArgs, args: &SelfCheckArgs) -> i32 {
    let output = global.output;
    let fail = |(code, message): (String, String)| {
        super::app::failure(&code, &format!("cmux: {message}"), output, 1)
    };
    let daemon = match super::wire::resolve_socket_or_report(global) {
        Ok((socket, _)) => socket,
        Err(code) => return code,
    };
    let dir = args.out.clone().unwrap_or_else(|| {
        PathBuf::from(format!("cmux-self-check-{}", utc_stamp(std::time::SystemTime::now())))
    });
    let dir = std::path::absolute(&dir).unwrap_or(dir);
    if let Err(error) = std::fs::create_dir_all(&dir) {
        let message = format!("cannot create {}: {error}", dir.display());
        return fail(("self_check.out".to_owned(), message));
    }
    let mut request = json!({"op": "self-check"});
    if let Some(fields) = request.as_object_mut() {
        if let Some(phone) = &args.phone {
            fields.insert("phone".into(), json!(phone));
        }
        if !args.rows.is_empty() {
            fields.insert("rows".into(), json!(args.rows));
        }
    }
    let mut conversation = match Conversation::start(&link_socket(&daemon), &request) {
        Ok(conversation) => conversation,
        Err(error) => return fail(error),
    };
    let answer = loop {
        match conversation.next() {
            Ok(line) => match line.get("progress") {
                Some(progress) => {
                    if output == OutputMode::Human {
                        eprintln!("{}", self_check_progress(progress));
                    }
                }
                None => break line,
            },
            Err(error) => return fail(error),
        }
    };
    if let Some(error) = self_check_refused(&answer) {
        return fail(error);
    }
    let report = match save_self_check(&answer, &dir) {
        Ok(report) => report,
        Err(error) => {
            let message = format!("cannot write to {}: {error}", dir.display());
            return fail(("self_check.out".to_owned(), message));
        }
    };
    match output {
        OutputMode::Human => print!("{}", self_check_summary(&report, &dir)),
        OutputMode::Json | OutputMode::JsonLines => println!("{report}"),
        OutputMode::Quiet => {}
    }
    if report.get("pass").and_then(Value::as_bool) == Some(true) { 0 } else { 1 }
}

/// The host's error answer, if it is one (`no_phone`, `several_phones`, `busy`,
/// `timeout`, `closed`, `phone_error`, ...).
fn self_check_refused(answer: &Value) -> Option<(String, String)> {
    let code = answer.get("error").and_then(Value::as_str)?;
    let mut message = answer.get("message").and_then(Value::as_str).unwrap_or(code).to_owned();
    let phones: Vec<String> = answer
        .get("phones")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|phone| {
            let id = phone.get("device_id").and_then(Value::as_str).unwrap_or("?");
            match phone.get("device").and_then(|d| d.get("model")).and_then(Value::as_str) {
                Some(model) => format!("{id} ({model})"),
                None => id.to_owned(),
            }
        })
        .collect();
    if !phones.is_empty() {
        message.push_str(&format!(": {}", phones.join(", ")));
    }
    Some((format!("self_check.{code}"), message))
}

/// `row 1 row1-claude-code-2.1.310-1234ms pass` for one progress line.
fn self_check_progress(progress: &Value) -> String {
    let row = progress.get("row").and_then(Value::as_u64).unwrap_or(0);
    let id = progress.get("id").and_then(Value::as_str).unwrap_or("?");
    let pass = progress.get("pass").and_then(Value::as_bool) == Some(true);
    format!("row {row} {id} {}", if pass { "pass" } else { "FAIL" })
}

/// A case id as a file name: `[A-Za-z0-9._-]` kept, anything else `_`.
fn sanitize_case_id(id: &str) -> String {
    let name: String = id
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') { c } else { '_' })
        .collect();
    if name.is_empty() || name.chars().all(|c| c == '.') { "case".to_owned() } else { name }
}

/// Writes every case image to `dir/<case id>-<kind>.png` and `dir/report.json`: the
/// answer with each case's `images` as the files' absolute paths. Returns that report.
fn save_self_check(answer: &Value, dir: &Path) -> std::io::Result<Value> {
    use base64::Engine as _;
    let mut report = answer.clone();
    for row in report.get_mut("rows").and_then(Value::as_array_mut).into_iter().flatten() {
        let number = row.get("row").and_then(Value::as_u64).unwrap_or(0);
        let cases = row.get_mut("cases").and_then(Value::as_array_mut);
        for (index, case) in cases.into_iter().flatten().enumerate() {
            let id = case
                .get("id")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .unwrap_or_else(|| format!("row{number}-case{index}"));
            let Some(images) = case.get_mut("images").and_then(Value::as_object_mut) else {
                continue;
            };
            let mut paths = serde_json::Map::new();
            for (kind, data) in images.iter() {
                let Some(bytes) = data
                    .as_str()
                    .and_then(|data| base64::engine::general_purpose::STANDARD.decode(data).ok())
                else {
                    continue;
                };
                let path =
                    dir.join(format!("{}-{}.png", sanitize_case_id(&id), sanitize_case_id(kind)));
                std::fs::write(&path, bytes)?;
                paths.insert(kind.clone(), json!(path.to_string_lossy()));
            }
            *images = paths;
        }
    }
    let mut text = serde_json::to_vec_pretty(&report).map_err(std::io::Error::other)?;
    text.push(b'\n');
    std::fs::write(dir.join("report.json"), text)?;
    Ok(report)
}

/// One line per row (`row 1 headers PASS (2/2)`), a failing row's first reason
/// under it, then where the files are.
fn self_check_summary(report: &Value, dir: &Path) -> String {
    let mut text = String::new();
    for row in report.get("rows").and_then(Value::as_array).into_iter().flatten() {
        let cases = row.get("cases").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]);
        let passed =
            cases.iter().filter(|c| c.get("pass").and_then(Value::as_bool) == Some(true)).count();
        let pass = row.get("pass").and_then(Value::as_bool) == Some(true);
        text.push_str(&format!(
            "row {} {} {} ({passed}/{})\n",
            row.get("row").and_then(Value::as_u64).unwrap_or(0),
            row.get("name").and_then(Value::as_str).unwrap_or("?"),
            if pass { "PASS" } else { "FAIL" },
            cases.len(),
        ));
        let first_why = row
            .get("why")
            .and_then(Value::as_array)
            .and_then(|why| why.first())
            .and_then(Value::as_str);
        if let (false, Some(why)) = (pass, first_why) {
            text.push_str(&format!("  {why}\n"));
        }
    }
    text.push_str(&format!("images and report in {}\n", dir.display()));
    text
}

/// `YYYYMMDD-HHMMSS` in UTC.
fn utc_stamp(at: std::time::SystemTime) -> String {
    let secs = at.duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let (days, of_day) = (secs / 86_400, secs % 86_400);
    // Days since 1970-01-01 as a proleptic Gregorian date (H. Hinnant's algorithm).
    let z = i64::try_from(days).unwrap_or(0) + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}{month:02}{day:02}-{:02}{:02}{:02}",
        of_day / 3600,
        (of_day / 60) % 60,
        of_day % 60
    )
}

fn doctor(global: &GlobalArgs, name: &str) -> i32 {
    let output = global.output;
    let fail = |(code, message): (String, String)| {
        super::app::failure(&code, &format!("cmux: {message}"), output, 1)
    };
    let daemon = match super::wire::resolve_socket_or_report(global) {
        Ok((socket, _)) => socket,
        Err(code) => return code,
    };
    let socket = link_socket(&daemon);
    let listed =
        Conversation::start(&socket, &json!({"op": "machines"})).and_then(|mut c| c.next());
    let listed = match listed {
        Ok(answer) => answer,
        Err(error) => return fail(error),
    };
    if let Some(error) = refused(&listed) {
        return fail(error);
    }
    let machines = listed.get("machines").and_then(Value::as_array).cloned().unwrap_or_default();
    let machine = match pick(&machines, name) {
        Ok(machine) => machine.clone(),
        Err(message) => return fail(("machine.not_found".to_owned(), message)),
    };
    let device_id = machine.get("device_id").and_then(Value::as_str).unwrap_or_default().to_owned();
    let label = machine.get("name").and_then(Value::as_str).unwrap_or(name).to_owned();
    let started = Instant::now();
    let request = json!({"op": "open", "peer": device_id, "service": "machine", "args": {}});
    let mut conversation = match Conversation::start(&socket, &request) {
        Ok(conversation) => conversation,
        Err(error) => return fail(error),
    };
    let mut asked = false;
    let opened = loop {
        match conversation.next() {
            Ok(answer) if answer.get("pending").and_then(Value::as_bool) == Some(true) => {
                if !asked && output == OutputMode::Human {
                    eprintln!(
                        "{label} is asking its person to allow this Mac (on that Mac, or on your phone)…"
                    );
                }
                asked = true;
            }
            Ok(answer) => break answer,
            Err(error) => return fail(error),
        }
    };
    if let Some(error) = refused(&opened) {
        return fail(error);
    }
    let link_ms = started.elapsed().as_millis() as u64;
    let described = match conversation.next() {
        Ok(described) => described,
        Err(error) => return fail(error),
    };
    let report = json!({
        "machine": label,
        "device_id": device_id,
        "link_ms": link_ms,
        "asked": asked,
        "described": described,
    });
    match output {
        OutputMode::Human => {
            let grants: Vec<&str> = described
                .get("grants")
                .and_then(Value::as_array)
                .map(|g| g.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            let field = |key: &str| described.get(key).and_then(Value::as_str).unwrap_or("?");
            println!("{label}: reached in {link_ms} ms over the cmux link");
            println!("  {} {}, cmux link {}", field("os"), field("arch"), field("hostd"));
            println!(
                "  desktop: {}",
                match field("desktop") {
                    "logged_in" => "someone is logged in",
                    "not_logged_in" => "nobody is logged in (apps open at the next login)",
                    _ => "unknown",
                }
            );
            println!(
                "  allows this Mac: {}",
                if grants.is_empty() { "nothing yet".to_owned() } else { grants.join(", ") }
            );
        }
        OutputMode::Json | OutputMode::JsonLines => println!("{report}"),
        OutputMode::Quiet => {}
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mac(name: &str, id: &str, machine: &str, online: bool, this: bool) -> Value {
        json!({"name": name, "device_id": id, "machine_id": machine, "online": online, "this": this})
    }

    /// A host answer as `{"op":"self-check","rows":[1,2,3]}` gives it: row 1 passes,
    /// row 2 has a shifted case, row 3 ran nothing.
    fn self_check_answer() -> Value {
        // "\x89PNG" in base64, and one that is not base64 at all.
        let png = "iVBORw==";
        json!({
            "ok": true, "phone": "PHONE-1", "device": {"model": "iPhone17,1"}, "pass": false,
            "thresholds": {"grid": 0.0005, "band": 0.001},
            "rows": [
                {"row": 1, "name": "headers", "pass": true, "why": [], "cases": [
                    {"row": 1, "id": "row1-claude-code-2.1.310-1234ms", "pass": true, "why": [],
                     "images": {"pty": png, "lean": png, "diff": png}},
                ]},
                {"row": 2, "name": "first-and-last-columns", "pass": false,
                 "why": ["row2/a b: grid pixels: 4.0000% differ", "row2/a b: band firstColumn: 60.0000% differ"],
                 "cases": [
                    {"row": 2, "id": "row2/a b", "pass": false, "why": ["grid pixels: 4.0000% differ"],
                     "images": {"pty": png, "lean": "not base64!"}},
                    {"row": 2, "id": "row2-ok", "pass": true, "why": [], "images": {}},
                ]},
                {"row": 3, "name": "wrapped-lines", "pass": false, "why": ["no case ran"], "cases": []},
            ],
        })
    }

    #[test]
    fn self_check_saves_each_image_under_its_sanitized_case_id() {
        assert_eq!(
            sanitize_case_id("row1-claude-code-2.1.310-1234ms"),
            "row1-claude-code-2.1.310-1234ms"
        );
        assert_eq!(sanitize_case_id("row2/a b"), "row2_a_b");
        assert_eq!(sanitize_case_id("../../etc"), ".._.._etc");
        assert_eq!(sanitize_case_id(".."), "case");
        assert_eq!(sanitize_case_id(""), "case");
        assert_eq!(sanitize_case_id("中文"), "__");

        let dir = tempfile::tempdir().unwrap();
        let report = save_self_check(&self_check_answer(), dir.path()).unwrap();
        let pty = dir.path().join("row1-claude-code-2.1.310-1234ms-pty.png");
        assert_eq!(std::fs::read(&pty).unwrap(), b"\x89PNG");
        assert!(dir.path().join("row1-claude-code-2.1.310-1234ms-diff.png").exists());
        assert!(dir.path().join("row2_a_b-pty.png").exists());
        assert!(!dir.path().join("row2_a_b-lean.png").exists(), "not base64: no file");
        let images = &report["rows"][0]["cases"][0]["images"];
        assert_eq!(images["pty"], json!(pty.to_string_lossy()));
        assert_eq!(
            report["rows"][1]["cases"][0]["images"],
            json!({"pty": dir.path().join("row2_a_b-pty.png").to_string_lossy()})
        );
        // Everything else as the host answered it.
        assert_eq!(report["device"], json!({"model": "iPhone17,1"}));
        assert_eq!(report["rows"][1]["why"], self_check_answer()["rows"][1]["why"]);
        let on_disk: Value =
            serde_json::from_slice(&std::fs::read(dir.path().join("report.json")).unwrap())
                .unwrap();
        assert_eq!(on_disk, report);
    }

    #[test]
    fn self_check_prints_one_line_per_row_and_a_failing_rows_first_reason() {
        let text = self_check_summary(&self_check_answer(), Path::new("/tmp/sc"));
        assert_eq!(
            text,
            "row 1 headers PASS (1/1)\n\
             row 2 first-and-last-columns FAIL (1/2)\n  \
             row2/a b: grid pixels: 4.0000% differ\n\
             row 3 wrapped-lines FAIL (0/0)\n  \
             no case ran\n\
             images and report in /tmp/sc\n"
        );
        assert_eq!(
            self_check_progress(&json!({"row": 2, "id": "row2/a b", "pass": false})),
            "row 2 row2/a b FAIL"
        );
        assert_eq!(
            self_check_progress(&json!({"row": 1, "id": "x", "pass": true})),
            "row 1 x pass"
        );
    }

    #[test]
    fn self_check_reads_its_options_and_the_hosts_errors() {
        let words = |w: &[&str]| w.iter().map(|s| (*s).to_owned()).collect::<Vec<String>>();
        assert_eq!(SelfCheckArgs::parse(&[]).unwrap(), SelfCheckArgs::default());
        let parsed =
            SelfCheckArgs::parse(&words(&["--phone", "ABC", "--rows=3,1,3", "--out", "x"]))
                .unwrap();
        assert_eq!(
            parsed,
            SelfCheckArgs { phone: Some("ABC".into()), rows: vec![1, 3], out: Some("x".into()) }
        );
        assert!(SelfCheckArgs::parse(&words(&["--rows", "0"])).is_err());
        assert!(SelfCheckArgs::parse(&words(&["--rows", "10"])).is_err());
        assert!(SelfCheckArgs::parse(&words(&["--phone"])).is_err());
        assert!(SelfCheckArgs::parse(&words(&["--bogus"])).is_err());

        let several = json!({"error": "several_phones", "message": "several iPhones",
            "phones": [{"device_id": "A", "device": {"model": "iPhone17,1"}}, {"device_id": "B", "device": {}}]});
        assert_eq!(
            self_check_refused(&several),
            Some(("self_check.several_phones".into(), "several iPhones: A (iPhone17,1), B".into()))
        );
        assert_eq!(self_check_refused(&self_check_answer()), None);
        // 2026-11-17 09:05:03 UTC.
        let at = std::time::UNIX_EPOCH + Duration::from_secs(1_794_906_303);
        assert_eq!(utc_stamp(at), "20261117-090503");
    }

    #[test]
    fn traffic_lists_busy_services_first_and_the_total() {
        let answer = json!({
            "ok": true, "uptime_s": 42,
            "total": {"service": "total", "in_bytes": 1_260_000, "out_bytes": 5_000,
                      "in_per_s_10s": 126_000, "out_per_s_10s": 500, "in_per_s_60s": 21_000, "out_per_s_60s": 83},
            "services": [
                {"service": "terminal", "in_bytes": 0, "out_bytes": 5_000,
                 "in_per_s_10s": 0, "out_per_s_10s": 500, "in_per_s_60s": 0, "out_per_s_60s": 83},
                {"service": "chat", "in_bytes": 0, "out_bytes": 0,
                 "in_per_s_10s": 0, "out_per_s_10s": 0, "in_per_s_60s": 0, "out_per_s_60s": 0},
                {"service": "remote", "in_bytes": 1_260_000, "out_bytes": 0,
                 "in_per_s_10s": 126_000, "out_per_s_10s": 0, "in_per_s_60s": 21_000, "out_per_s_60s": 0},
            ],
        });
        let table = traffic_table(&answer);
        let lines: Vec<&str> = table.lines().collect();
        assert!(lines.first().is_some_and(|l| l.starts_with("service")), "{table}");
        assert!(
            lines.get(1).is_some_and(|l| l.starts_with("remote") && l.contains("126.0 KB/s")),
            "{table}"
        );
        assert!(lines.get(2).is_some_and(|l| l.starts_with("terminal")), "{table}");
        assert!(
            lines.get(3).is_some_and(|l| l.starts_with("total") && l.contains("1.3 MB")),
            "{table}"
        );
        assert!(!table.contains("chat"), "{table}");
        assert_eq!(human_bytes(999), "999 B");
        assert_eq!(human_bytes(1_500_000_000), "1.5 GB");
    }

    #[test]
    fn a_name_picks_one_mac_and_never_this_one() {
        let list = vec![
            mac("Studio", "11111111-1111-1111-1111-111111111111", "aa", true, true),
            mac("MacBook", "22222222-2222-2222-2222-222222222222", "bb", true, false),
            mac("MacBook", "33333333-3333-3333-3333-333333333333", "bb", false, false),
        ];
        // Two builds of one computer: the online one.
        assert_eq!(
            pick(&list, "macbook").unwrap()["device_id"],
            "22222222-2222-2222-2222-222222222222"
        );
        assert_eq!(pick(&list, "33333333-3333-3333-3333-333333333333").unwrap()["online"], false);
        // This Mac is never a target.
        assert!(pick(&list, "Studio").unwrap_err().contains("no Mac named Studio"));
        // Nor is another build of this same computer (same machine id).
        let mut with_sibling = list.clone();
        with_sibling.push(mac(
            "Studio DEV",
            "44444444-4444-4444-4444-444444444444",
            "aa",
            true,
            false,
        ));
        assert!(pick(&with_sibling, "Studio DEV").is_err());
        assert!(!pick(&with_sibling, "nope").unwrap_err().contains("Studio DEV"));
        assert!(pick(&list, "nope").unwrap_err().contains("MacBook"));
    }

    #[test]
    fn only_selector_first_doctor_is_ours() {
        let words = |w: &[&str]| w.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        // The joined-machine doctor keeps `machine doctor [MACHINE]`.
        assert_eq!(run_if_requested(&words(&["machine", "doctor"])), None);
        assert_eq!(run_if_requested(&words(&["machine", "doctor", "x"])), None);
        assert_eq!(run_if_requested(&words(&["machine", "x", "show"])), None);
        assert_eq!(link_socket(Path::new("/t/main.sock")), PathBuf::from("/t/main.link.sock"));
    }
}
