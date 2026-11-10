//! The text form of each answer. It reads only the answer `ops` built (the public view), so it
//! cannot print what that view left out.

use std::fmt::Write as _;

use serde_json::Value;

use super::Command;

fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or("")
}

fn items<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value.get(key).and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default()
}

pub(super) fn human(command: &Command, answer: &Value) -> String {
    match command {
        Command::Help => String::new(),
        Command::List => list(answer),
        Command::Default { .. } => default(answer),
        Command::Logs { .. } => logs(answer),
        _ => environment(answer),
    }
}

/// `repo@ref`, `repo`, or empty.
fn repository(value: &Value) -> String {
    match (text(value, "repo"), text(value, "ref")) {
        ("", _) => String::new(),
        (repo, "") => repo.to_owned(),
        (repo, git_ref) => format!("{repo}@{git_ref}"),
    }
}

fn list(answer: &Value) -> String {
    let rows = items(answer, "environments");
    let width = rows.iter().map(|row| text(row, "name").chars().count()).max().unwrap_or(0).max(4);
    let mut out = format!("{:30}  {:width$}  {:8}  REPOSITORY\n", "ID", "NAME", "SCOPE");
    for row in rows {
        let name = if row.get("is_default") == Some(&Value::Bool(true)) {
            format!("{} *", text(row, "name"))
        } else {
            text(row, "name").to_owned()
        };
        let _ = writeln!(
            out,
            "{:30}  {name:width$}  {:8}  {}",
            text(row, "id"),
            text(row, "scope"),
            repository(row)
        );
    }
    out
}

fn environment(view: &Value) -> String {
    let mut out =
        format!("{} ({}, {})\n", text(view, "name"), text(view, "id"), text(view, "scope"));
    let line = |out: &mut String, label: &str, value: &str| {
        if !value.is_empty() {
            let _ = writeln!(out, "  {label:12}{value}");
        }
    };
    line(&mut out, "repository", &repository(view));
    line(&mut out, "image", text(view, "image"));
    if let Some(network) = view.get("network").filter(|n| n.is_object()) {
        let mut mode = text(network, "mode").to_owned();
        if mode == "limited" {
            let on = network.get("package_managers") == Some(&Value::Bool(true));
            let domains: Vec<&str> =
                items(network, "domains").iter().filter_map(Value::as_str).collect();
            let _ = write!(mode, " (package managers {}", if on { "on" } else { "off" });
            if !domains.is_empty() {
                let _ = write!(mode, "; {}", domains.join(", "));
            }
            mode.push(')');
        }
        line(&mut out, "network", &mode);
    }
    for (label, key) in [("setup", "setup_script"), ("maintenance", "maintenance_script")] {
        let script = text(view, key);
        if !script.is_empty() {
            let _ = writeln!(out, "  {label}:");
            for row in script.lines() {
                let _ = writeln!(out, "    {row}");
            }
        }
    }
    let vars = items(view, "env_vars");
    if !vars.is_empty() {
        out.push_str("  variables:\n");
        for var in vars {
            let _ = writeln!(out, "    {}={}", text(var, "name"), text(var, "value"));
        }
    }
    let secrets = items(view, "secrets");
    if !secrets.is_empty() {
        out.push_str("  secrets (values are never shown):\n");
        for secret in secrets {
            let hosts: Vec<&str> =
                items(secret, "hosts").iter().filter_map(Value::as_str).collect();
            let _ = writeln!(out, "    {} -> {}", text(secret, "name"), hosts.join(", "));
        }
    }
    let files = items(view, "files");
    if !files.is_empty() {
        out.push_str("  files:\n");
        for file in files {
            match file.get("bytes").and_then(Value::as_u64) {
                Some(bytes) => {
                    let _ = writeln!(out, "    {} ({bytes} bytes)", text(file, "path"));
                }
                None => {
                    let _ = writeln!(out, "    {}", text(file, "path"));
                }
            }
        }
    }
    out
}

fn default(answer: &Value) -> String {
    let repo = text(answer, "repo");
    match answer.get("environment").filter(|e| e.is_object()) {
        Some(env) if !text(env, "name").is_empty() => {
            format!("{repo}: {} ({})\n", text(env, "name"), text(env, "id"))
        }
        Some(env) => format!("{repo}: {}\n", text(env, "id")),
        None => format!("{repo}: no default environment (your Default is used)\n"),
    }
}

fn logs(answer: &Value) -> String {
    let env = answer.get("environment").unwrap_or(&Value::Null);
    let mut out = format!(
        "{} for {}: {}\n",
        text(env, "name"),
        text(answer, "repo"),
        answer.get("status").and_then(Value::as_str).unwrap_or("unknown")
    );
    for step in items(answer, "steps") {
        let detail = text(step, "detail");
        let _ = writeln!(out, "  {:9}{:8}{detail}", text(step, "id"), text(step, "state"));
    }
    if let Some(error) = answer.get("error").filter(|e| e.is_object()) {
        let _ = writeln!(out, "error: {} ({})", text(error, "message"), text(error, "code"));
    }
    let tail = text(answer, "log_tail");
    if !tail.is_empty() {
        out.push_str("\n--- last output ---\n");
        out.push_str(tail);
        if !tail.ends_with('\n') {
            out.push('\n');
        }
    }
    out
}
