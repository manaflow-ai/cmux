//! Human output. `--json` bypasses all of this and prints the owner's reply.

use serde_json::Value;

fn s<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}

fn who(v: &Value) -> String {
    if let Some(agent) = v.get("delegate").filter(|d| !d.is_null()) {
        return format!("@{}", s(agent, "harness"));
    }
    match v.get("assignee").filter(|a| !a.is_null()) {
        Some(a) => s(a, "id").trim_start_matches("usr_").to_owned(),
        None => "-".to_owned(),
    }
}

fn priority(v: &Value) -> &'static str {
    match s(v, "priority") {
        "urgent" => "!!!",
        "high" => "!!",
        "medium" => "!",
        "low" => ".",
        _ => "",
    }
}

fn attention(v: &Value) -> &'static str {
    match s(v, "attention") {
        "needs_input" => " [needs input]",
        "failed" => " [failed]",
        "review" => " [review]",
        _ => "",
    }
}

pub fn task_list(tasks: &Value) -> String {
    let Some(rows) = tasks.as_array() else { return String::new() };
    if rows.is_empty() {
        return "No tasks.\n".to_owned();
    }
    let key_w = rows.iter().map(|r| s(r, "key").len()).max().unwrap_or(4);
    let status_w = rows.iter().map(|r| s(r, "status_name").len()).max().unwrap_or(6);
    let who_w = rows.iter().map(|r| who(r).len()).max().unwrap_or(1);
    let mut out = String::new();
    for r in rows {
        out.push_str(&format!(
            "{:key_w$}  {:status_w$}  {:3}  {:who_w$}  {}{}\n",
            s(r, "key"),
            s(r, "status_name"),
            priority(r),
            who(r),
            s(r, "title"),
            attention(r),
        ));
    }
    out
}

pub fn task_detail(detail: &Value) -> String {
    if detail.is_null() {
        return "Not found.\n".to_owned();
    }
    let mut out = format!("{}  {}\n", s(detail, "key"), s(detail, "title"));
    out.push_str(&format!("status {}  priority {}  assignee {}{}\n", s(detail, "status_name"), s(detail, "priority"), who(detail), attention(detail)));
    let text = detail.pointer("/description/text").and_then(Value::as_str).unwrap_or("");
    if !text.is_empty() {
        out.push('\n');
        out.push_str(text);
        out.push('\n');
    }
    for session in detail.get("sessions").and_then(Value::as_array).into_iter().flatten() {
        out.push_str(&format!("\nagent {} ({})  {}", s(session.get("agent").unwrap_or(&Value::Null), "harness"), s(session, "id"), s(session, "status")));
        if let Some(pr) = session.pointer("/links/pr").and_then(Value::as_str) {
            out.push_str(&format!("  {pr}"));
        }
        out.push('\n');
        for step in session.get("plan").and_then(Value::as_array).into_iter().flatten() {
            let mark = match s(step, "status") {
                "completed" => "x",
                "in_progress" => ">",
                _ => " ",
            };
            out.push_str(&format!("  [{mark}] {}\n", s(step, "content")));
        }
    }
    for comment in detail.get("comments").and_then(Value::as_array).into_iter().flatten() {
        let author = comment.get("author").map(|a| s(a, "id").to_owned()).unwrap_or_default();
        out.push_str(&format!("\n{author}: {}\n", s(comment, "body")));
    }
    out
}

/// One line for a committed mutation: the task key or entity id.
pub fn mutation(op: &str, reply: &Value) -> String {
    let result = reply.get("result").unwrap_or(&Value::Null);
    let subject = result.get("key").and_then(Value::as_str).or_else(|| result.get("id").and_then(Value::as_str)).unwrap_or("");
    let replay = if reply.get("replay").and_then(Value::as_bool) == Some(true) { " (already done)" } else { "" };
    let verb = match op.rsplit('.').next().unwrap_or(op) {
        "add" => "added",
        "remove" => "removed",
        "move" => "moved",
        "claim" => "claimed",
        "attach" => "attached",
        "cancel" => "canceled",
        other if other.ends_with('e') => return format!("{subject} {other}d{replay}\n"),
        other => return format!("{subject} {other}ed{replay}\n"),
    };
    format!("{subject} {verb}{replay}\n")
}
