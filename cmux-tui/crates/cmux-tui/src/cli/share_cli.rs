//! `cmux share chat|list|revoke|kick`: guest links to an agent chat (design chat-multiplayer.md 6).
//! The app's `agent.share` family runs them (CLI names `share chat`, `share list`, `share revoke`,
//! `share kick`), because the app holds the owner's cmux sign-in that a link's room needs. This
//! only turns the positional ids of `share revoke ID` and `share kick ID GUEST` into the actions'
//! `--share-id` and `--guest-id`, and prints `share chat`'s link alone for a person.

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
        _ => return None,
    };
    let positional = rest.iter().take(names.len()).take_while(|arg| !is_flag(arg)).count();
    let all_positional = positional == names.len();
    let flags = if all_positional { &rest[positional..] } else { rest };
    for name in names {
        let given = flags.iter().filter(|flag| flag_name(flag) == *name).count()
            + usize::from(all_positional);
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
        names.iter().zip(&rest[..positional]).map(|(name, id)| format!("{name}={id}")).collect();
    args.extend(flags.iter().cloned());
    Some(Ok((format!("share {verb}"), args)))
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

/// The flags `share revoke` and `share kick` take; any other word, `-x…` ids included, is an id.
const FLAGS: &[&str] = &["--share-id", "--guest-id", "--json", "--help", "-h", "--"];

fn is_flag(arg: &str) -> bool {
    FLAGS.contains(&flag_name(arg))
}

fn flag_name(arg: &str) -> &str {
    arg.split_once('=').map_or(arg, |(name, _)| name)
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
            Some(Ok(("share revoke".to_owned(), words("--share-id=s1 --json"))))
        );
        assert_eq!(
            action(&words("share kick s1 g2")),
            Some(Ok(("share kick".to_owned(), words("--share-id=s1 --guest-id=g2"))))
        );
    }

    #[test]
    fn an_id_may_start_with_a_dash() {
        assert_eq!(
            action(&words("share revoke -Xk3_aQ9 --json")),
            Some(Ok(("share revoke".to_owned(), words("--share-id=-Xk3_aQ9 --json"))))
        );
        assert_eq!(
            action(&words("share kick --a1b2 -g2")),
            Some(Ok(("share kick".to_owned(), words("--share-id=--a1b2 --guest-id=-g2"))))
        );
    }

    /// The rewritten words go through the action parser the CLI uses, and the ids arrive whole.
    #[test]
    fn the_action_parser_reads_dash_led_ids_as_values() {
        let Some(Ok((name, args))) = action(&words("share kick --a1b2 -g2")) else {
            panic!("share kick names its ids")
        };
        let command =
            super::super::app::run_action(&name, &args, super::super::app::ActionName::Cli)
                .expect("the rewritten flags parse");
        let super::super::app::AppCommand::Call { params, .. } = command else {
            panic!("share kick is an action call")
        };
        assert_eq!(params["args"]["shareId"], "--a1b2", "{params}");
        assert_eq!(params["args"]["guestId"], "-g2", "{params}");
    }

    #[test]
    fn an_id_given_twice_is_refused() {
        for text in [
            "share revoke s1 --share-id s2",
            "share kick s1 g1 --guest-id=g2",
            "share revoke --share-id=s1 --share-id=s2",
            "share kick --share-id s1 --guest-id g1 --guest-id g2",
        ] {
            assert!(matches!(action(&words(text)), Some(Err(_))), "{text}");
        }
        assert_eq!(action(&words("share revoke --share-id=s1")), None, "one flag goes on as typed");
    }

    #[test]
    fn an_output_switch_after_a_dash_led_id_reaches_the_output_mode() {
        let Some(Ok((_, mut args))) = action(&words("share revoke --a1b2 --json")) else {
            panic!("share revoke names its id")
        };
        assert_eq!(take_output_switches(&mut args), words("--json"));
        assert_eq!(args, words("--share-id=--a1b2"));
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
