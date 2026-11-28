//! `cmux share requests|approve|decline`: the owner's side of "request access" to a shared agent
//! chat. A signed-in account opens a link it cannot use and asks; the owner lists the asks,
//! approves one with a role (default `view`) or declines it.
//!
//! ```text
//! cmux share requests [SHARE_ID]
//! cmux share approve SHARE_ID ACCOUNT [--role view|talk]
//! cmux share decline SHARE_ID ACCOUNT
//! ```
//!
//! The logic is the daemon's (`agent-session-share-list`, `-request-approve`, `-request-decline`);
//! this only words the arguments and the answers. They run on this machine's daemon, so they need
//! no owner sign-in.

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, wire};

pub(super) const HELP: &str = "Usage: cmux share <requests|approve|decline>\n\n\
Owner-side access requests for a shared agent chat. `requests` lists pending asks;\n\
`approve` grants access (view by default, or talk with `--role talk`); `decline`\n\
refuses an ask without telling the requester. Run these on the machine that owns\n\
the shared chat.\n\n\
  cmux share requests [SHARE_ID]\n\
  cmux share approve SHARE_ID ACCOUNT [--role view|talk]\n\
  cmux share decline SHARE_ID ACCOUNT\n";

/// `share requests|approve|decline …` from the full argv; None for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command) = super::parse_globals(args).ok()?;
    let is_share_request = command.first().is_some_and(|scope| scope == "share")
        && command
            .get(1)
            .is_none_or(|verb| matches!(verb.as_str(), "requests" | "approve" | "decline"));
    if is_share_request && super::has_help_option(&command) {
        print!("{HELP}");
        return Some(0);
    }
    if super::has_help_option(&command) {
        return None;
    }
    let [scope, verb, rest @ ..] = command.as_slice() else { return None };
    if scope != "share" || !matches!(verb.as_str(), "requests" | "approve" | "decline") {
        return None;
    }
    let ask = match parse(verb, rest) {
        Ok(ask) => ask,
        Err(message) => {
            return Some(wire::print_local_error(
                &json!({"code": "usage.invalid", "message": message}),
                global.output,
                2,
            ));
        }
    };
    Some(run(&global, &ask))
}

#[derive(Debug, PartialEq, Eq)]
enum Ask {
    List { share: Option<String> },
    Approve { share: String, account: String, role: Option<String> },
    Decline { share: String, account: String },
}

fn parse(verb: &str, words: &[String]) -> Result<Ask, String> {
    let mut positional = Vec::new();
    let mut role = None;
    let mut words = words.iter();
    while let Some(word) = words.next() {
        if word == "--role" {
            role = Some(words.next().ok_or("--role takes view or talk")?.clone());
        } else if let Some(value) = word.strip_prefix("--role=") {
            role = Some(value.to_owned());
        } else if word.starts_with("--") {
            return Err(format!("share {verb} does not take {word}"));
        } else {
            positional.push(word.clone());
        }
    }
    if role.is_some() && verb != "approve" {
        return Err(format!("share {verb} does not take --role"));
    }
    if let Some(role) = &role
        && !matches!(role.as_str(), "view" | "talk")
    {
        return Err(format!("--role is view or talk, not {role}"));
    }
    let mut positional = positional.into_iter();
    let first = positional.next();
    let second = positional.next();
    if positional.next().is_some() {
        return Err(format!("share {verb} takes too many words"));
    }
    match (verb, first, second) {
        ("requests", share, None) => Ok(Ask::List { share }),
        ("requests", _, Some(_)) => Err("share requests takes at most a SHARE_ID".into()),
        ("approve", Some(share), Some(account)) => Ok(Ask::Approve { share, account, role }),
        ("decline", Some(share), Some(account)) => Ok(Ask::Decline { share, account }),
        _ => Err(format!("share {verb} takes SHARE_ID ACCOUNT (cmux share requests lists them)")),
    }
}

fn run(global: &GlobalArgs, ask: &Ask) -> i32 {
    let request = match ask {
        Ask::List { .. } => json!({"cmd": "agent-session-share-list"}),
        Ask::Approve { share, account, role } => {
            let mut request = json!({
                "cmd": "agent-session-share-request-approve",
                "share_id": share,
                "account": account,
            });
            if let (Some(role), Some(fields)) = (role, request.as_object_mut()) {
                fields.insert("role".into(), json!(role));
            }
            request
        }
        Ask::Decline { share, account } => json!({
            "cmd": "agent-session-share-request-decline",
            "share_id": share,
            "account": account,
        }),
    };
    let data = match super::ext::daemon_call(global, request) {
        Ok(Ok(data)) => data,
        Ok(Err(refusal)) => {
            let (code, message) = refusal.split_once(": ").unwrap_or(("error", &refusal));
            return wire::print_local_error(
                &json!({"code": code, "message": refusal_sentence(code, message)}),
                global.output,
                1,
            );
        }
        Err(message) => {
            return wire::print_local_error(
                &json!({"code": "daemon.unavailable", "message": message}),
                global.output,
                3,
            );
        }
    };
    match ask {
        Ask::List { share } => {
            let pending = pending_requests(&data, share.as_deref());
            if global.output == OutputMode::Human {
                print!("{}", requests_text(&pending));
                return 0;
            }
            wire::print_local_success(&json!({"requests": pending}), global.output)
        }
        _ => {
            if global.output == OutputMode::Human {
                println!("{}", done_line(ask, &data));
                return 0;
            }
            wire::print_local_success(&data, global.output)
        }
    }
}

/// Every pending request as `{share_id, session, account, name, requested_at}`.
fn pending_requests(list: &Value, only: Option<&str>) -> Vec<Value> {
    let shares = list.get("shares").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut rows = Vec::new();
    for share in &shares {
        let id = share.get("share_id").and_then(Value::as_str).unwrap_or("");
        if only.is_some_and(|only| only != id) {
            continue;
        }
        for request in share.get("requests").and_then(Value::as_array).into_iter().flatten() {
            // A request that is not an object has no account to answer: skip it.
            let Some(mut row) = request.as_object().cloned() else { continue };
            row.insert("share_id".into(), json!(id));
            if let Some(session) = share.get("session") {
                row.insert("session".into(), session.clone());
            }
            rows.push(Value::Object(row));
        }
    }
    rows
}

fn requests_text(rows: &[Value]) -> String {
    if rows.is_empty() {
        return "no one is asking for access\n".to_owned();
    }
    let mut out = String::new();
    for row in rows {
        let text = |key: &str| row.get(key).and_then(Value::as_str).unwrap_or("");
        let account = text("account");
        let share = text("share_id");
        let name = text("name");
        let who = if name.is_empty() || name == account {
            account.to_owned()
        } else {
            format!("{name} <{account}>")
        };
        out.push_str(&format!(
            "{who} asks for access: cmux share approve {share} {account}  or  cmux share decline {share} {account}\n"
        ));
    }
    out
}

fn done_line(ask: &Ask, data: &Value) -> String {
    let text = |key: &str| data.get(key).and_then(Value::as_str).unwrap_or("");
    match ask {
        Ask::Approve { .. } => {
            let role = if text("role") == "talk" { "can talk" } else { "can view" };
            format!("Approved {} ({role}); their page opens now", text("account"))
        }
        _ => format!("Declined {}; they are not told", text("account")),
    }
}

/// What a refusal means and what to do next.
fn refusal_sentence(code: &str, message: &str) -> String {
    let next = match code {
        "share.unknown" => {
            "there is no such pending request; cmux share requests lists what is waiting"
        }
        "share.not_trusted" => "run this on the machine that owns the chat",
        "share.bad_request" => "check the share id and the account (an email address)",
        "share.limit" => "too many invitations or requests; decline or remove some, then retry",
        _ => return message.to_owned(),
    };
    if message.is_empty() { next.to_owned() } else { format!("{message}; {next}") }
}

#[cfg(test)]
#[path = "share_requests_tests.rs"]
mod tests;
