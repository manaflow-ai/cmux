//! `cmux debug perf`: the live perf commentator of the acpmux the cmux app's chats use
//! (`acpmux/src/perf_watch.rs`), so an agent sees what the chat Inspector's Perf tab shows,
//! with no screenshot: spans with their parts, plain-language notes when something is higher
//! than expected, and the data meter's hot zones.
//!
//! Off by default; `on` and `off` switch it for the daemon. `--follow` turns it on when it is
//! off (it says so) and prints each event as it comes (`--json`: one JSON object a line), until
//! interrupted. `snapshot` is the last minute in one JSON object (the Inspector's "Copy
//! diagnosis"). The daemon also appends every event to `$ACPMUX_HOME/perf-watch.jsonl` while on.
//!
//! `frames` is apart from the commentator and always on: the visible chat's frame times over the
//! last 5 minutes (acpmux `frame_tally.rs`), read without changing anything.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, parse_globals};

const HELP: &str = "Usage: cmux debug perf [status|on|off|--follow [--json]|snapshot|budgets|frames]\n\nThe live perf commentator of the app's acpmux (off by default): how long new chats, workspace switches and page loads take, part by part; what is higher than expected; and which channels move the most bytes.\n\n  cmux debug perf                  On or off, and its tail file\n  cmux debug perf on|off           Turn it on or off\n  cmux debug perf --follow         Print each span, note and meter summary as it comes (turns it on)\n  cmux debug perf --follow --json  The same, one JSON object a line\n  cmux debug perf snapshot         The last minute as one JSON object (for a bug report)\n  cmux debug perf budgets          What each span and check is expected to stay under\n  cmux debug perf frames           The visible chat's frame times over the last 5 minutes (always on; reads only)\n";

/// How long one follow read waits on the daemon for a new event.
const FOLLOW_WAIT_MS: u64 = 25_000;

/// Handles `cmux debug perf` before the app scope (`debug ...` app actions).
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = parse_globals(args).ok()?;
    match command_args.as_slice() {
        [debug, perf, rest @ ..] if debug == "debug" && perf == "perf" => Some(run(&global, rest)),
        _ => None,
    }
}

fn run(global: &GlobalArgs, rest: &[String]) -> i32 {
    let words: Vec<&str> = rest.iter().map(String::as_str).filter(|w| *w != "--json").collect();
    let json_out = global.output != OutputMode::Human || rest.iter().any(|w| w == "--json");
    let socket = super::agents::chat::app_acpmux(global);
    let socket = socket.as_deref();
    let result = match words.as_slice() {
        [] | ["status"] => {
            call(socket, json!({"op": "status"})).map(|v| print(&v, json_out, status_text))
        }
        ["on"] => call(socket, json!({"op": "on"})).map(|v| print(&v, json_out, status_text)),
        ["off"] => call(socket, json!({"op": "off"})).map(|v| print(&v, json_out, status_text)),
        ["snapshot"] => {
            call(socket, json!({"op": "snapshot"})).map(|v| print(&v, true, |_| String::new()))
        }
        // The always-on frame tally (acpmux `frame_tally.rs`): a line, or JSON with `--json`.
        ["frames"] => {
            call(socket, json!({"op": "frames"})).map(|v| print(&v, json_out, frames_text))
        }
        ["budgets"] => {
            call(socket, json!({"op": "budgets"})).map(|v| print(&v, json_out, budgets_text))
        }
        ["--follow" | "-f"] | ["follow"] => follow(socket, json_out),
        ["-h" | "--help" | "help"] => {
            print!("{HELP}");
            Ok(())
        }
        _ => {
            eprint!("{HELP}");
            return 2;
        }
    };
    match result {
        Ok(()) => 0,
        Err(error) => {
            if json_out {
                println!(
                    "{}",
                    json!({"ok": false, "error": {"code": "perf.unreachable", "message": error}})
                );
            } else {
                eprintln!("cmux debug perf: {error}");
            }
            3
        }
    }
}

fn runtime() -> Result<tokio::runtime::Runtime, String> {
    crate::acp::configure_home();
    tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())
}

async fn client(socket: Option<&Path>) -> anyhow::Result<Arc<acpmux::client::Client>> {
    match socket {
        Some(path) => acpmux::client::Client::connect(path).await,
        None => acpmux::deliver::connect().await,
    }
}

fn call(socket: Option<&Path>, params: Value) -> Result<Value, String> {
    runtime()?
        .block_on(async {
            client(socket).await?.request(acpmux::rpc::method::MUX_PERF, params).await
        })
        .map_err(|error| format!("{error:#}"))
}

fn print(value: &Value, json_out: bool, text: fn(&Value) -> String) {
    if json_out {
        println!("{value}");
    } else {
        println!("{}", text(value));
    }
}

fn status_text(value: &Value) -> String {
    if at(value, "on").as_bool() == Some(true) {
        let file = at(value, "file").as_str().unwrap_or("(none)");
        format!("perf watch: on (events {}; tail {file})", at(value, "seq"))
    } else {
        "perf watch: off (cmux debug perf on)".to_owned()
    }
}

/// `visible chat: 1234 frames in 300 s, p50 8.35 ms, p95 16.65 ms, p99 33.45 ms (12 over 16.7 ms)`.
fn frames_text(value: &Value) -> String {
    let chat = at(value, "visible_chat");
    let frames = at(chat, "frames").as_u64().unwrap_or(0);
    let window = at(chat, "window_s").as_u64().unwrap_or(0);
    if frames == 0 {
        return format!("visible chat: no frames drawn in the last {window} s");
    }
    let p =
        |key: &str| at(chat, key).as_f64().map_or_else(|| "?".to_owned(), |v| format!("{v} ms"));
    format!(
        "visible chat: {frames} frames in {window} s, p50 {}, p95 {}, p99 {} ({} over {} ms)",
        p("p50_ms"),
        p("p95_ms"),
        p("p99_ms"),
        at(chat, "over_budget").as_u64().unwrap_or(0),
        at(chat, "budget_ms"),
    )
}

fn budgets_text(value: &Value) -> String {
    let mut out = String::new();
    for budget in value.as_array().into_iter().flatten() {
        out.push_str(&format!(
            "{:<28} {:>12} {:<8} {}  ({})\n",
            at(budget, "key").as_str().unwrap_or("?"),
            at(budget, "limit"),
            at(budget, "unit").as_str().unwrap_or(""),
            at(budget, "what").as_str().unwrap_or(""),
            at(budget, "source").as_str().unwrap_or(""),
        ));
    }
    out.trim_end().to_owned()
}

/// Reads the stream until interrupted or the daemon goes away.
fn follow(socket: Option<&Path>, json_out: bool) -> Result<(), String> {
    runtime()?.block_on(async {
        let client = client(socket).await.map_err(|e| format!("{e:#}"))?;
        let request = |params: Value| {
            let client = client.clone();
            async move {
                client
                    .request(acpmux::rpc::method::MUX_PERF, params)
                    .await
                    .map_err(|e| format!("{e:#}"))
            }
        };
        let status = request(json!({"op": "status"})).await?;
        let mut after = at(&status, "seq").as_u64().unwrap_or(0);
        if at(&status, "on").as_bool() != Some(true) {
            let turned = request(json!({"op": "on"})).await?;
            after = at(&turned, "seq").as_u64().unwrap_or(0);
            if !json_out {
                eprintln!("perf watch: turned on (cmux debug perf off to stop)");
            }
        }
        loop {
            let read =
                request(json!({"op": "read", "after": after, "waitMs": FOLLOW_WAIT_MS})).await?;
            if at(&read, "on").as_bool() != Some(true) {
                if !json_out {
                    eprintln!("perf watch: turned off");
                }
                return Ok(());
            }
            for event in at(&read, "events").as_array().into_iter().flatten() {
                after = after.max(at(event, "seq").as_u64().unwrap_or(after));
                if json_out {
                    println!("{event}");
                } else {
                    println!("{}", event_text(event));
                }
            }
            // A daemon restarted under us starts its seq again.
            let seq = at(&read, "seq").as_u64().unwrap_or(after);
            if seq < after {
                after = 0;
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    })
}

/// One event as one line for a person.
pub(super) fn event_text(event: &Value) -> String {
    let at_ms = at(event, "at").as_u64().unwrap_or(0);
    let clock = format!(
        "{:02}:{:02}:{:02}",
        at_ms / 3_600_000 % 24,
        at_ms / 60_000 % 60,
        at_ms / 1000 % 60
    );
    match at(event, "kind").as_str().unwrap_or("") {
        "note" => format!("{clock} note  {}", at(event, "text").as_str().unwrap_or("")),
        "span" => {
            let parts: Vec<String> = at(event, "parts")
                .as_array()
                .into_iter()
                .flatten()
                .map(|p| {
                    format!(
                        "{} {}",
                        at(p, "name").as_str().unwrap_or("?"),
                        ms(at(p, "ms").as_f64().unwrap_or(0.0))
                    )
                })
                .collect();
            let budget = match at(event, "budgetMs").as_f64() {
                Some(limit) if at(event, "over").as_bool() == Some(true) => {
                    format!(" (over {})", ms(limit))
                }
                Some(limit) => format!(" (under {})", ms(limit)),
                None => String::new(),
            };
            format!(
                "{clock} span  {} {}{budget}: {}",
                at(event, "name").as_str().unwrap_or("?"),
                ms(at(event, "ms").as_f64().unwrap_or(0.0)),
                parts.join(" | ")
            )
        }
        "meter" => {
            let top: Vec<String> = at(event, "top")
                .as_array()
                .into_iter()
                .flatten()
                .take(3)
                .map(|z| {
                    format!(
                        "{} [{}] {}/min",
                        at(z, "label").as_str().unwrap_or("?"),
                        at(z, "channel").as_str().unwrap_or("?"),
                        size(at(z, "bytesPerMinute").as_u64().unwrap_or(0))
                    )
                })
                .collect();
            format!("{clock} meter {}", top.join(", "))
        }
        other => format!("{clock} {other} {event}"),
    }
}

fn ms(value: f64) -> String {
    if value >= 1000.0 { format!("{:.1} s", value / 1000.0) } else { format!("{value:.0} ms") }
}

fn size(bytes: u64) -> String {
    let b = bytes as f64;
    if b >= 1024.0 * 1024.0 {
        format!("{:.1} MB", b / 1024.0 / 1024.0)
    } else if b >= 1024.0 {
        format!("{:.0} KB", b / 1024.0)
    } else {
        format!("{bytes} B")
    }
}

/// `value[key]` without the panicking `Index` (the panic ratchet counts it): `Null` when absent.
fn at<'a>(value: &'a Value, key: &str) -> &'a Value {
    static NULL: Value = Value::Null;
    value.get(key).unwrap_or(&NULL)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_followed_event_reads_as_one_line() {
        let span = json!({"kind": "span", "at": 3_723_000u64, "name": "new chat", "ms": 3400.0, "budgetMs": 3000.0,
            "over": true, "parts": [{"name": "agent start", "ms": 2900.0}, {"name": "first token", "ms": 380.0}]});
        assert_eq!(
            event_text(&span),
            "01:02:03 span  new chat 3.4 s (over 3.0 s): agent start 2.9 s | first token 380 ms"
        );
        let note =
            json!({"kind": "note", "at": 0, "text": "SessionList re-rendered 14 times in 200 ms"});
        assert_eq!(event_text(&note), "00:00:00 note  SessionList re-rendered 14 times in 200 ms");
        let meter = json!({"kind": "meter", "at": 0, "top": [{"label": "reply to _acpmux/sessions", "channel": "daemon-ipc", "bytesPerMinute": 41943040u64}]});
        assert_eq!(
            event_text(&meter),
            "00:00:00 meter reply to _acpmux/sessions [daemon-ipc] 40.0 MB/min"
        );
    }

    #[test]
    fn frames_read_as_one_line() {
        let read = json!({"visible_chat": {"frames": 1200, "window_s": 300, "p50_ms": 8.35,
            "p95_ms": 16.65, "p99_ms": 33.45, "over_budget": 14, "budget_ms": 16.7}});
        assert_eq!(
            frames_text(&read),
            "visible chat: 1200 frames in 300 s, p50 8.35 ms, p95 16.65 ms, p99 33.45 ms (14 over 16.7 ms)"
        );
        let empty = json!({"visible_chat": {"frames": 0, "window_s": 40}});
        assert_eq!(frames_text(&empty), "visible chat: no frames drawn in the last 40 s");
    }

    #[test]
    fn only_debug_perf_is_taken() {
        let words = |list: &[&str]| list.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>();
        assert!(run_if_requested(&words(&["debug", "open-settings"])).is_none());
        assert!(run_if_requested(&words(&["agents", "snapshot"])).is_none());
        assert_eq!(run_if_requested(&words(&["debug", "perf", "nonsense"])), Some(2));
    }
}
