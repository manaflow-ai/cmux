//! `cmux share chat|list|revoke|kick`: guest links to an agent chat (design chat-multiplayer.md 6).
//! The app's `agent.share` family runs them (CLI names `share chat`, `share list`, `share revoke`,
//! `share kick`), because the app holds the owner's cmux sign-in that a link's room needs. This
//! only turns the positional ids of `share revoke ID` and `share kick ID GUEST` into the actions'
//! `--share-id` and `--guest-id`, and prints `share chat`'s link alone for a person.

use serde_json::Value;

/// The app action and its arguments for `share revoke|kick <ids…> [flags]`, or None for other words.
pub(super) fn action(command_args: &[String]) -> Option<(String, Vec<String>)> {
    let [scope, verb, rest @ ..] = command_args else { return None };
    if scope != "share" {
        return None;
    }
    let positional = rest.iter().take_while(|arg| !arg.starts_with('-')).count();
    let (ids, flags) = rest.split_at(positional);
    let names: &[&str] = match (verb.as_str(), ids.len()) {
        ("revoke", 1) => &["--share-id"],
        ("kick", 2) => &["--share-id", "--guest-id"],
        _ => return None,
    };
    let mut args = Vec::new();
    for (name, id) in names.iter().zip(ids) {
        args.push((*name).to_owned());
        args.push(id.clone());
    }
    args.extend(flags.iter().cloned());
    Some((format!("share {verb}"), args))
}

/// What a person sees for `share chat`: the link alone, so `cmux share chat | pbcopy` works.
/// None for every other run (and a link-less share, whose fields print as a table).
pub(super) fn human_line(params: &Value, result: &Value) -> Option<String> {
    let action = params.get("action")?.as_str()?;
    if action != "share chat" && action != "agent.share" {
        return None;
    }
    result.get("result")?.get("url")?.as_str().map(|url| format!("{url}\n"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn revoke_and_kick_name_their_ids() {
        assert_eq!(
            action(&words("share revoke s1 --json")),
            Some(("share revoke".to_owned(), words("--share-id s1 --json")))
        );
        assert_eq!(
            action(&words("share kick s1 g2")),
            Some(("share kick".to_owned(), words("--share-id s1 --guest-id g2")))
        );
    }

    #[test]
    fn other_words_go_on_as_typed() {
        for text in [
            "share chat --surface 3",
            "share list",
            "share revoke",
            "share kick s1",
            "host share 3 leo",
            "share revoke --share-id s1",
        ] {
            assert_eq!(action(&words(text)), None, "{text}");
        }
    }

    #[test]
    fn share_chat_prints_only_the_link() {
        let params = json!({"action": "share chat", "cli": true});
        let result = json!({"ran": true, "result": {"share_id": "s1", "url": "https://room.example/g/s1#k"}});
        assert_eq!(human_line(&params, &result).as_deref(), Some("https://room.example/g/s1#k\n"));
        let roomless = json!({"ran": true, "result": {"share_id": "s1", "url": null}});
        assert_eq!(human_line(&params, &roomless), None);
        assert_eq!(human_line(&json!({"action": "share list"}), &result), None);
    }
}
