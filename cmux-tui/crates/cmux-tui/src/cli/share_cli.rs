//! `cmux share chat|list|revoke|kick|invite|uninvite`: guest links to an agent chat and the cmux
//! accounts invited to it (design chat-multiplayer.md 6). The app's `agent.share` family runs them
//! (CLI names `share chat`, `share list`, `share revoke`, `share kick`, `share invite`, `share
//! uninvite`), because the app holds the owner's cmux sign-in that a link's room needs. This only
//! turns the positional words of `share revoke ID`, `share kick ID GUEST`, `share invite ACCOUNT`
//! and `share uninvite ACCOUNT` into the actions' `--share-id`, `--guest-id` and `--account`, and
//! prints `share chat`'s link (and an invite's one line) for a person.

use serde_json::Value;

/// The app action and its arguments for `share revoke|kick <ids…> [flags]`, or None for other words.
/// The ids are the words right after the verb. They are base64url and may start with `-`, so a word
/// counts as a flag only when it names one of these commands' own flags. An id given more than once,
/// in any form (`share revoke s1 --share-id s2`, `--share-id=s1 --share-id=s2`), is refused rather
/// than one of them silently winning.
pub(super) fn action(command_args: &[String]) -> Option<Result<(String, Vec<String>), String>> {
    let [scope, verb, rest @ ..] = command_args else { return None };
    if scope != "share" {
        return None;
    }
    let names: &[&str] = match verb.as_str() {
        "revoke" => &["--share-id"],
        "kick" => &["--share-id", "--guest-id"],
        "invite" | "uninvite" => return Some(account_action(verb, rest)),
        "chat" => return chat_action(rest),
        _ => return None,
    };
    let positional = rest.iter().take(names.len()).take_while(|arg| !is_flag(arg)).count();
    let all_positional = positional == names.len();
    let (ids, after) = rest.split_at(positional);
    let flags = if all_positional { after } else { rest };
    let keys = argument_keys(flags);
    for name in names {
        let key = argument_key(name);
        let given = keys
            .iter()
            .filter(|given| **given == key)
            .count()
            .saturating_add(usize::from(all_positional));
        if given > 1 {
            return Some(Err(format!("share {verb}: {name} is given more than once")));
        }
    }
    if !all_positional {
        return None;
    }
    // `--share-id=ID`, not `--share-id ID`: the action parser reads a following word that starts
    // with `--` as the next flag, and an id may.
    let mut args: Vec<String> =
        names.iter().zip(ids).map(|(name, id)| format!("{name}={id}")).collect();
    args.extend(flags.iter().cloned());
    Some(Ok((format!("share {verb}"), args)))
}

/// `share chat --view-only [flags]`: a link where nobody sends, as `--role=view
/// --signed-in-role=view` (the daemon's `agent-session-share-create {role: "view",
/// signed_in_role: "view"}`: anonymous link guests always watch, and signed-in ones watch too).
/// `--view-only` with a `--role` or `--signed-in-role` is refused; without `--view-only` the words
/// go on as typed (`--role view` and `--signed-in-role view` reach the action as they are).
fn chat_action(rest: &[String]) -> Option<Result<(String, Vec<String>), String>> {
    let view_only = rest.iter().filter(|word| *word == "--view-only").count();
    if view_only == 0 {
        return None;
    }
    if view_only > 1 || argument_keys(rest).iter().any(|key| key == "role" || key == "signedInRole")
    {
        return Some(Err(
            "share chat: give --view-only, or --role and --signed-in-role, once".to_owned()
        ));
    }
    let args = rest
        .iter()
        .flat_map(|word| {
            if word == "--view-only" {
                vec!["--role=view".to_owned(), "--signed-in-role=view".to_owned()]
            } else {
                vec![word.clone()]
            }
        })
        .collect();
    Some(Ok(("share chat".to_owned(), args)))
}

/// `share invite|uninvite <account> [flags]`: the account (an email or `@handle`, never dash-led) is
/// the one word that is neither a flag nor a flag's value, wherever it stands, so `share invite
/// --surface 3 leo@cmux.com --role view` and `share invite leo@cmux.com --surface 3` agree. An
/// account given twice (`share invite a@x.com --account b@x.com`) is refused; with none the words
/// go on as typed, and the app answers that the account is missing.
fn account_action(verb: &str, rest: &[String]) -> Result<(String, Vec<String>), String> {
    let mut accounts = Vec::new();
    let mut flags = Vec::new();
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        if word == "--" {
            accounts.extend(words.by_ref().cloned());
            break;
        }
        if !word.starts_with('-') {
            accounts.push(word.clone());
            continue;
        }
        flags.push(word.clone());
        // `--name value`: the next word is the flag's, not the account (switches take none).
        if !SWITCHES.contains(&word.as_str())
            && !ACTION_SWITCHES.contains(&word.as_str())
            && !word.contains('=')
            && let Some(value) = words.next()
        {
            flags.push(value.clone());
        }
    }
    let named = argument_keys(&flags).iter().filter(|key| *key == "account").count();
    if accounts.len() + named > 1 {
        return Err(format!("share {verb}: name one account (an email or @handle)"));
    }
    let mut args: Vec<String> =
        accounts.iter().map(|account| format!("--account={account}")).collect();
    args.extend(flags);
    Ok((format!("share {verb}"), args))
}

/// The action argument each of `args` sets, in every spelling the action parser takes:
/// `--share-id X`, `--share-id=X`, `--shareId X`, `--share_id X`, `--arg shareId=X`, `--arg=shareId=X`.
fn argument_keys(args: &[String]) -> Vec<String> {
    let mut keys = Vec::new();
    let mut words = args.iter();
    while let Some(word) = words.next() {
        let Some(flag) = word.strip_prefix("--") else { continue };
        let (name, value) = flag.split_once('=').map_or((flag, None), |(n, v)| (n, Some(v)));
        if name == "arg" {
            let pair =
                value.map(str::to_owned).or_else(|| words.next().cloned()).unwrap_or_default();
            keys.push(pair.split_once('=').map_or(pair.as_str(), |(key, _)| key).to_owned());
        } else if !name.is_empty() {
            keys.push(argument_key(name));
        }
    }
    keys
}

/// A flag's action argument name, as the action parser derives it: `share-id` and `share_id` are
/// `shareId`.
fn argument_key(flag: &str) -> String {
    let mut key = String::with_capacity(flag.len());
    let mut upper = false;
    for character in flag.trim_start_matches('-').chars() {
        if character == '-' || character == '_' {
            upper = true;
        } else if upper {
            key.extend(character.to_uppercase());
            upper = false;
        } else {
            key.push(character);
        }
    }
    key
}

/// The output switches (`--json`, `--jsonl`, `--quiet`) among `args`, taken out. The global
/// scan reads a dash-led id as an option and its next word as that option's value, so a switch
/// after such an id reaches the action's arguments instead of the CLI's output mode.
pub(super) fn take_output_switches(args: &mut Vec<String>) -> Vec<String> {
    let mut taken = Vec::new();
    args.retain(|arg| {
        let switch = matches!(arg.as_str(), "--json" | "--jsonl" | "--quiet");
        if switch {
            taken.push(arg.clone());
        }
        !switch
    });
    taken
}

/// The action parser's own valueless switches (`app::run_action`): never followed by a value.
const ACTION_SWITCHES: &[&str] = &["--wait", "--no-wait", "--interactive", "--focus"];

/// The switches `share revoke` and `share kick` take besides their ids.
const SWITCHES: &[&str] = &["--json", "--jsonl", "--quiet", "--help", "-h", "--"];

/// Whether `arg` is a flag, not an id. Ids are base64url (`A-Z a-z 0-9 - _`), so they may start
/// with `-` but never hold `=`: a `--name=value` word is a flag, as is every spelling of the id
/// flags and `--arg`.
fn is_flag(arg: &str) -> bool {
    SWITCHES.contains(&arg)
        || (arg.starts_with("--")
            && (arg.contains('=')
                || matches!(argument_key(arg).as_str(), "shareId" | "guestId" | "arg")))
}

/// What a person sees for `share chat`: the link alone, so `cmux share chat | pbcopy` works; for
/// `share invite` and `share uninvite`, one line naming the account (an invite's followed by its
/// invite link, when the share has a room). None for every other run (and
/// a link-less share, whose fields print as a table).
pub(super) fn human_line(params: &Value, result: &Value) -> Option<String> {
    let action = params.get("action")?.as_str()?;
    let result = result.get("result")?;
    match action {
        "share chat" | "agent.share" => result.get("url")?.as_str().map(|url| format!("{url}\n")),
        "share invite" | "agent.share.invite" => {
            let account = result.get("account")?.as_str()?;
            let can = if result.get("role")?.as_str()? == "view" { "view" } else { "talk" };
            let mut line = format!("Invited {account} (can {can})\n");
            // The link the owner sends the invitee (none without a room).
            if let Some(link) = result.get("invite_url").and_then(Value::as_str) {
                line.push_str(&format!("Invite link: {link}\n"));
            }
            Some(line)
        }
        "share uninvite" | "agent.share.uninvite" => {
            Some(format!("Removed {}\n", result.get("account")?.as_str()?))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests;
