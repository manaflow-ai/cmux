//! `cmux share info|requests|approve|decline`: the owner's side of "request access" to a shared agent
//! chat. A signed-in account opens a link it cannot use and asks; the owner lists the asks,
//! approves one with a role (default `view`) or declines it.
//!
//! ```text
//! cmux share requests [SHARE_ID]
//! cmux share approve SHARE_ID ACCOUNT [--role view|talk]
//! cmux share decline SHARE_ID ACCOUNT
//! cmux share info [SHARE_ID] [--surface N]
//! ```
//!
//! The logic is the daemon's (`agent-session-share-list`, `-request-approve`, `-request-decline`);
//! this only words the arguments and the answers. They run on this machine's daemon, so they need
//! no owner sign-in.

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, wire};

const INFO_HELP: &str = "Usage: cmux share info [SHARE_ID] [--surface N] [--json]\n\nReads the local owner's share registry, including team access, role, and invite address.\n";

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
    if command.first().map(String::as_str) == Some("share")
        && command.get(1).map(String::as_str) == Some("info")
        && super::has_help_option(&command)
    {
        if global.output != OutputMode::Quiet {
            print!("{INFO_HELP}");
        }
        return Some(0);
    }
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
    if scope != "share" || !matches!(verb.as_str(), "info" | "requests" | "approve" | "decline") {
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
    /// Read the owner's daemon registry, including team access and its invite address.
    Info {
        share: Option<String>,
        surface: Option<u64>,
    },
    List {
        share: Option<String>,
    },
    Approve {
        share: String,
        account: String,
        role: Option<String>,
    },
    Decline {
        share: String,
        account: String,
    },
}

fn parse(verb: &str, words: &[String]) -> Result<Ask, String> {
    let mut positional = Vec::new();
    let mut role = None;
    let mut surface = None;
    let mut words = words.iter();
    while let Some(word) = words.next() {
        if word == "--role" {
            role = Some(words.next().ok_or("--role takes view or talk")?.clone());
        } else if let Some(value) = word.strip_prefix("--role=") {
            role = Some(value.to_owned());
        } else if word == "--surface" {
            let value = words.next().ok_or("--surface takes a number")?;
            surface = Some(value.parse().map_err(|_| "--surface takes a number")?);
        } else if let Some(value) = word.strip_prefix("--surface=") {
            surface = Some(value.parse().map_err(|_| "--surface takes a number")?);
        } else if word.starts_with("--") {
            return Err(format!("share {verb} does not take {word}"));
        } else {
            positional.push(word.clone());
        }
    }
    if role.is_some() && verb != "approve" {
        return Err(format!("share {verb} does not take --role"));
    }
    if surface.is_some() && verb != "info" {
        return Err(format!("share {verb} does not take --surface"));
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
        ("info", share, None) => Ok(Ask::Info { share, surface }),
        ("info", _, Some(_)) => Err("share info takes at most a SHARE_ID".into()),
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
        Ask::Info { surface: Some(surface), .. } => {
            json!({"cmd": "agent-session-share-list", "surface": surface})
        }
        Ask::Info { surface: None, .. } => json!({"cmd": "agent-session-share-list"}),
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
        Ask::Info { share, .. } => {
            let listed = share_rows(&data, share.as_deref());
            if global.output == OutputMode::Human {
                print!("{}", shares_text(&listed));
                return 0;
            }
            wire::print_local_success(&json!({"shares": listed}), global.output)
        }
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

/// Every share row as returned by the daemon, optionally narrowed to one id.
fn share_rows(list: &Value, only: Option<&str>) -> Vec<Value> {
    list.get("shares")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|share| {
            only.is_none_or(|only| share.get("share_id").and_then(Value::as_str) == Some(only))
        })
        .cloned()
        .collect()
}

fn shares_text(rows: &[Value]) -> String {
    if rows.is_empty() {
        return "no shares\n".to_owned();
    }
    let mut out = String::new();
    for row in rows {
        let text = |key: &str| row.get(key).and_then(Value::as_str).unwrap_or("");
        let access = if let Some(team) = row.get("team_id").and_then(Value::as_str) {
            match text("role") {
                "" => format!("anyone on {team}"),
                role => format!("anyone on {team} ({role})"),
            }
        } else if let Some(role) = row.get("role").and_then(Value::as_str) {
            format!("anyone with the link ({role})")
        } else if row
            .get("invitees")
            .and_then(Value::as_array)
            .is_some_and(|invitees| !invitees.is_empty())
        {
            "named invitations".to_owned()
        } else {
            "access unspecified".to_owned()
        };
        let address = row.get("invite_url").and_then(Value::as_str).unwrap_or("");
        out.push_str(&format!("{}: {access}", text("share_id")));
        if !address.is_empty() {
            out.push_str(&format!(" {address}"));
        }
        out.push('\n');
    }
    out
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
mod tests {
    use super::*;

    fn words(list: &[&str]) -> Vec<String> {
        list.iter().map(|word| (*word).to_owned()).collect()
    }

    #[test]
    fn approve_takes_a_role_and_defaults_to_the_daemons() {
        assert_eq!(
            parse("approve", &words(&["s1", "a@b.c", "--role", "talk"])),
            Ok(Ask::Approve {
                share: "s1".into(),
                account: "a@b.c".into(),
                role: Some("talk".into())
            })
        );
        assert_eq!(
            parse("approve", &words(&["s1", "a@b.c"])),
            Ok(Ask::Approve { share: "s1".into(), account: "a@b.c".into(), role: None })
        );
    }

    #[test]
    fn info_reads_team_access_without_changing_share_chat() {
        assert_eq!(
            parse("info", &words(&["s1", "--surface=7"])),
            Ok(Ask::Info { share: Some("s1".into()), surface: Some(7) })
        );
        assert_eq!(parse("info", &[]), Ok(Ask::Info { share: None, surface: None }));
        assert!(parse("requests", &words(&["--surface", "7"])).is_err());
    }

    #[test]
    fn info_text_names_team_role_and_invite_address() {
        let rows = share_rows(
            &json!({"shares":[
                {"share_id":"s1", "team_id":"team_0123456789abcdef0123", "role":"talk",
                 "invite_url":"https://room.example/i/s1"},
                {"share_id":"s2", "role":"view"},
                {"share_id":"s3", "invitees":[{"account":"a@b.c"}]},
                {"share_id":"s4"}
            ]}),
            None,
        );
        assert_eq!(
            shares_text(&rows),
            "s1: anyone on team_0123456789abcdef0123 (talk) https://room.example/i/s1\n".to_owned()
                + "s2: anyone with the link (view)\n"
                + "s3: named invitations\n"
                + "s4: access unspecified\n"
        );
    }

    #[test]
    fn bad_words_are_refused_with_a_sentence() {
        assert!(parse("approve", &words(&["s1"])).is_err());
        assert!(parse("approve", &words(&["s1", "a", "--role", "owner"])).is_err());
        assert!(parse("decline", &words(&["s1", "a", "--role", "view"])).is_err());
        assert!(parse("requests", &words(&["a", "b"])).is_err());
    }

    #[test]
    fn the_list_flattens_pending_requests_with_their_share() {
        let list = json!({"shares":[
            {"share_id":"s1","session":"x","requests":[{"account":"a@b.c","name":"Sam","state":"pending"}]},
            {"share_id":"s2","requests":[]}]});
        let rows = pending_requests(&list, None);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["share_id"], "s1");
        assert!(pending_requests(&list, Some("s2")).is_empty());
        assert!(requests_text(&rows).contains("cmux share approve s1 a@b.c"));
    }

    #[test]
    fn a_refusal_says_what_to_do_next() {
        assert!(refusal_sentence("share.unknown", "no request").contains("cmux share requests"));
        assert_eq!(refusal_sentence("share.other", "plain"), "plain");
    }

    #[test]
    fn help_lists_every_access_request_command() {
        assert!(HELP.contains("cmux share requests [SHARE_ID]"));
        assert!(HELP.contains("cmux share approve SHARE_ID ACCOUNT [--role view|talk]"));
        assert!(HELP.contains("cmux share decline SHARE_ID ACCOUNT"));
    }
}
