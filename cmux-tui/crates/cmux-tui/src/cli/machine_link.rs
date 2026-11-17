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

/// `Some(exit code)` when `args` is `machine NAME doctor` or `device traffic`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
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
