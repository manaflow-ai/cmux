//! `cmux apps list [--installed] [--query TEXT]` and `cmux apps info <app>`:
//! the App Store read from the CLI, answered by the session daemon's app
//! supervisor (`apps-store`, cmux-tui-core apps/store.rs). They need no Mac
//! app, so a self-hosted Linux host reads its store the same way
//! (docs/app-store-platonic-ideal.md 8a). Installs and removals are the app
//! actions `cmux apps install|remove`, which show the person a consent card.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

const USAGE: &str = "usage: cmux apps list [--installed] [--query TEXT] [--json]\n       cmux apps info <app> [--json]\n\n  list: every app in the App Store with its tier and install state.\n  info: one app's listing, the machines a deployed app runs on, and the scopes it asks for, with their risk class.\n  Install and remove with `cmux apps install <app>` and `cmux apps remove <app>`:\n  cmux shows you a consent card and changes nothing until you confirm.";

/// What the user asked for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Request {
    List { installed: bool, query: Option<String> },
    Info { app: String },
}

/// Parses the words after `apps`; `None` when they are not `list` or `info`
/// (other verbs are app actions or `apps run`).
pub(super) fn parse(args: &[String]) -> Option<Result<Request, String>> {
    let (verb, rest) = args.split_first()?;
    match verb.as_str() {
        "list" => {
            let mut installed = false;
            let mut query = None;
            let mut words = rest.iter();
            while let Some(word) = words.next() {
                match word.as_str() {
                    "--installed" => installed = true,
                    "--query" => match words.next() {
                        Some(text) => query = Some(text.clone()),
                        None => return Some(Err(USAGE.to_string())),
                    },
                    _ => return Some(Err(USAGE.to_string())),
                }
            }
            Some(Ok(Request::List { installed, query }))
        }
        "info" => match rest {
            [app] if !app.starts_with('-') => Some(Ok(Request::Info { app: app.clone() })),
            _ => Some(Err(USAGE.to_string())),
        },
        _ => None,
    }
}

/// One row of `apps list`: the catalog listing joined with its install state.
pub(super) fn rows(catalog: &Value, installed_only: bool) -> Vec<Value> {
    catalog["listings"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|listing| {
            let install = &listing["install"];
            json!({
                "app": listing["app"],
                "name": listing["name"],
                "tier": listing["tier"],
                "version": listing["version"],
                "installed": install["installed"].as_bool().unwrap_or(false),
                "hidden": install["hidden"].as_bool().unwrap_or(false),
                "enabled": install["enabled"].as_bool().unwrap_or(false),
                "summary": listing["summary"],
            })
        })
        .filter(|row| !installed_only || row["installed"] == true)
        .collect()
}

/// The human table: id, name, tier, state.
pub(super) fn table(rows: &[Value]) -> String {
    let state = |row: &Value| {
        if row["installed"] != true {
            "available"
        } else if row["hidden"] == true {
            "installed, hidden"
        } else if row["enabled"] != true {
            "installed, off"
        } else {
            "installed"
        }
    };
    let width =
        rows.iter().map(|r| r["app"].as_str().unwrap_or("").len()).max().unwrap_or(3).max(3);
    let name_width = rows
        .iter()
        .map(|r| r["name"].as_str().unwrap_or("").chars().count())
        .max()
        .unwrap_or(4)
        .max(4);
    let mut out = format!("{:width$}  {:name_width$}  {:12}  STATE\n", "APP", "NAME", "TIER");
    for row in rows {
        out.push_str(&format!(
            "{:width$}  {:name_width$}  {:12}  {}\n",
            row["app"].as_str().unwrap_or(""),
            row["name"].as_str().unwrap_or(""),
            row["tier"].as_str().unwrap_or(""),
            state(row),
        ));
    }
    out
}

/// The human form of `apps info`.
pub(super) fn info_text(detail: &Value) -> String {
    let mut out = format!(
        "{} ({}) {}\n{}\ntier: {}\n",
        detail["name"].as_str().unwrap_or(""),
        detail["app"].as_str().unwrap_or(""),
        detail["version"].as_str().unwrap_or(""),
        detail["summary"].as_str().unwrap_or(""),
        detail["tier"].as_str().unwrap_or(""),
    );
    let targets: Vec<&str> = detail
        .get("deploy")
        .and_then(|deploy| deploy.get("targets"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    if !targets.is_empty() {
        out.push_str(&format!("runs on: {}\n", targets.join(", ")));
    }
    let scopes = detail["scopes"].as_array().cloned().unwrap_or_default();
    if scopes.is_empty() {
        out.push_str("asks for: nothing\n");
    } else {
        out.push_str("asks for:\n");
        for scope in scopes {
            out.push_str(&format!(
                "  {} ({}{}): {}\n",
                scope.get("scope").and_then(Value::as_str).unwrap_or(""),
                scope.get("risk").and_then(Value::as_str).unwrap_or(""),
                if scope.get("optional").and_then(Value::as_bool) == Some(true) {
                    ", optional"
                } else {
                    ""
                },
                scope.get("reason").and_then(Value::as_str).unwrap_or(""),
            ));
        }
    }
    out
}

/// `cmux [global options] apps list|info ...` when `args` names it.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let rest = command_args.strip_prefix(&["apps".to_string()][..])?;
    if matches!(rest, [verb, flag] if (verb == "list" || verb == "info") && matches!(flag.as_str(), "-h" | "--help"))
    {
        println!("{USAGE}");
        return Some(0);
    }
    // `--json` / `--quiet` after the verb, as every scope's own flags (`cmux apps list --json`).
    let mut global = global;
    let rest: Vec<String> = rest
        .iter()
        .filter(|word| match word.as_str() {
            "--json" => {
                global.output = OutputMode::Json;
                false
            }
            "--quiet" => {
                global.output = OutputMode::Quiet;
                false
            }
            _ => true,
        })
        .cloned()
        .collect();
    let request = match parse(&rest)? {
        Ok(request) => request,
        Err(usage) => {
            eprintln!("{usage}");
            return Some(2);
        }
    };
    Some(run(&global, &request))
}

fn run(global: &GlobalArgs, request: &Request) -> i32 {
    let socket = match super::wire::resolve_socket_or_report(global) {
        Ok((socket, _)) => socket,
        Err(code) => return code,
    };
    let answer = |op: &str, args: Value| -> Result<Value, String> {
        let stream = UnixStream::connect(&socket).map_err(|error| {
            format!("cannot connect to the session socket {}: {error}", socket.display())
        })?;
        stream.set_read_timeout(Some(Duration::from_secs(15))).map_err(|e| e.to_string())?;
        let mut reader = BufReader::new(stream);
        let line =
            json!({"id": "apps-list-1", "cmd": "apps-store", "op": op, "args": args}).to_string();
        writeln!(reader.get_mut(), "{line}").map_err(|e| e.to_string())?;
        loop {
            let mut reply = String::new();
            if reader.read_line(&mut reply).map_err(|e| e.to_string())? == 0 {
                return Err("the daemon closed the connection".into());
            }
            let Ok(value) = serde_json::from_str::<Value>(&reply) else { continue };
            if value.get("id").and_then(Value::as_str) != Some("apps-list-1") {
                continue;
            }
            if value.get("ok").and_then(Value::as_bool) == Some(true) {
                return Ok(value.get("data").cloned().unwrap_or(Value::Null));
            }
            return Err(format!(
                "{}: {}",
                value.get("error_code").and_then(Value::as_str).unwrap_or("error"),
                value.get("error").and_then(Value::as_str).unwrap_or("")
            ));
        }
    };
    let json_out = matches!(global.output, OutputMode::Json | OutputMode::JsonLines);
    let result = match request {
        Request::List { installed, query } => {
            let mut args = json!({"limit": 200});
            if let Some(query) = query {
                args.set("query", json!(query));
            }
            answer("cmux.apps.catalog.list", args).map(|catalog| {
                let rows = rows(&catalog, *installed);
                if json_out { json!({"apps": rows}).to_string() } else { table(&rows) }
            })
        }
        Request::Info { app } => answer("cmux.apps.catalog.get", json!({"app": app}))
            .map(|detail| if json_out { detail.to_string() } else { info_text(&detail) }),
    };
    match result {
        Ok(text) => {
            if global.output != OutputMode::Quiet {
                print!("{}", if text.ends_with('\n') { text } else { format!("{text}\n") });
            }
            0
        }
        Err(message) => {
            eprintln!("cmux: {message}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_string).collect()
    }

    #[test]
    fn parses_list_and_info_and_leaves_other_verbs() {
        assert_eq!(
            parse(&words("list")),
            Some(Ok(Request::List { installed: false, query: None }))
        );
        assert_eq!(
            parse(&words("list --installed --query notes")),
            Some(Ok(Request::List { installed: true, query: Some("notes".into()) }))
        );
        assert_eq!(parse(&words("info acme/x")), Some(Ok(Request::Info { app: "acme/x".into() })));
        assert!(matches!(parse(&words("info")), Some(Err(_))));
        assert!(matches!(parse(&words("list --bogus")), Some(Err(_))));
        assert_eq!(parse(&words("install acme/x")), None, "install is the app action");
        assert_eq!(parse(&words("run acme/x op")), None, "run is apps_run");
    }

    #[test]
    fn rows_join_install_state_and_filter_installed() {
        let catalog = json!({"listings": [
            {"app": "a/one", "name": "One", "tier": "unverified", "version": "1", "install": null},
            {"app": "a/two", "name": "Two", "tier": "first-party", "version": "1",
             "install": {"installed": true, "hidden": true, "enabled": true}},
        ]});
        let all = rows(&catalog, false);
        assert_eq!(all.len(), 2);
        assert_eq!(all[0]["installed"], false);
        let installed = rows(&catalog, true);
        assert_eq!(installed.len(), 1);
        assert_eq!(installed[0]["app"], "a/two");
        let text = table(&all);
        assert!(text.contains("a/one") && text.contains("available"), "{text}");
        assert!(text.contains("installed, hidden"), "{text}");
    }
}
