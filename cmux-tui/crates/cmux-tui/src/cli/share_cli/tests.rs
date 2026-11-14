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
    let command = super::super::app::run_action(&name, &args, super::super::app::ActionName::Cli)
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
        "share revoke s1 --arg shareId=s2",
        "share revoke s1 --arg=shareId=s2",
        "share revoke s1 --shareId=s2",
        "share kick s1 g1 --guest_id g2",
        "share revoke --share-id s1 --shareId s2",
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
fn invite_and_uninvite_name_the_account_wherever_it_stands() {
    assert_eq!(
        action(&words("share invite leo@cmux.com --role view --json")),
        Some(Ok(("share invite".to_owned(), words("--account=leo@cmux.com --role view --json"))))
    );
    assert_eq!(
        action(&words("share invite --surface 3 @theo --role talk")),
        Some(Ok(("share invite".to_owned(), words("--account=@theo --surface 3 --role talk"))))
    );
    assert_eq!(
        action(&words("share uninvite @theo --surface=3")),
        Some(Ok(("share uninvite".to_owned(), words("--account=@theo --surface=3"))))
    );
    // No positional account: the flags go on as typed, and the app asks for one.
    assert_eq!(
        action(&words("share invite --account leo@cmux.com")),
        Some(Ok(("share invite".to_owned(), words("--account leo@cmux.com"))))
    );
    assert_eq!(action(&words("share invite")), Some(Ok(("share invite".to_owned(), vec![]))));
    // The action parser's valueless switches take no value: the account after one is still it.
    assert_eq!(
        action(&words("share invite --wait @theo")),
        Some(Ok(("share invite".to_owned(), words("--account=@theo --wait"))))
    );
    assert_eq!(
        action(&words("share uninvite --focus --no-wait @theo")),
        Some(Ok(("share uninvite".to_owned(), words("--account=@theo --focus --no-wait"))))
    );
}

#[test]
fn an_invite_names_one_account() {
    for text in [
        "share invite a@cmux.com b@cmux.com",
        "share invite a@cmux.com --account b@cmux.com",
        "share uninvite a@cmux.com --arg account=b@cmux.com",
    ] {
        assert!(matches!(action(&words(text)), Some(Err(_))), "{text}");
    }
}

/// The rewritten words go through the action parser, and the account and role arrive whole.
#[test]
fn the_action_parser_reads_the_invite() {
    let Some(Ok((name, args))) = action(&words("share invite --role view leo@cmux.com --ttl 7d"))
    else {
        panic!("share invite names its account")
    };
    let command = super::super::app::run_action(&name, &args, super::super::app::ActionName::Cli)
        .expect("the rewritten flags parse");
    let super::super::app::AppCommand::Call { params, timeout, .. } = command else {
        panic!("share invite is an action call")
    };
    assert_eq!(params["action"], "share invite", "{params}");
    let expected = json!({"account": "leo@cmux.com", "role": "view", "ttl": "7d"});
    assert_eq!(params["args"], expected, "{params}");
    // An agent's or script's invite waits for the owner's Allow in the app (#30263).
    assert_eq!(timeout, Some(super::super::app::PERSON_RUN_TIMEOUT));
}

#[test]
fn an_invite_prints_one_line_for_a_person() {
    let params = json!({"action": "share invite"});
    let result = json!({"ran": true, "result": {"share_id": "s1", "account": "leo@cmux.com", "role": "view", "state": "invited"}});
    assert_eq!(human_line(&params, &result).as_deref(), Some("Invited leo@cmux.com (can view)\n"));
    let talk = json!({"ran": true, "result": {"share_id": "s1", "account": "@theo", "role": "talk", "state": "invited"}});
    assert_eq!(human_line(&params, &talk).as_deref(), Some("Invited @theo (can talk)\n"));
    let removed = json!({"ran": true, "result": {"account": "@theo", "state": "removed", "share_ids": ["s1"]}});
    assert_eq!(
        human_line(&json!({"action": "share uninvite"}), &removed).as_deref(),
        Some("Removed @theo\n")
    );
}

/// With a room, an invite's line is followed by the link the owner sends the invitee.
#[test]
fn an_invite_prints_the_invite_link() {
    let params = json!({"action": "share invite"});
    let result = json!({"ran": true, "result": {"share_id": "s1", "account": "leo@cmux.com",
            "role": "talk", "state": "invited", "invite_url": "https://room.example/i/s1"}});
    assert_eq!(
        human_line(&params, &result).as_deref(),
        Some("Invited leo@cmux.com (can talk)\nInvite link: https://room.example/i/s1\n")
    );
    let roomless = json!({"ran": true, "result": {"share_id": "s1", "account": "leo@cmux.com",
            "role": "talk", "state": "invited", "invite_url": null}});
    assert_eq!(
        human_line(&params, &roomless).as_deref(),
        Some("Invited leo@cmux.com (can talk)\n")
    );
}

/// `share chat --view-only` asks for a link where nobody sends; the action parser reads it as
/// `role: "view"` and `signedInRole: "view"`.
#[test]
fn share_chat_view_only_names_the_view_role() {
    assert_eq!(
        action(&words("share chat --surface 3 --view-only --json")),
        Some(Ok((
            "share chat".to_owned(),
            words("--surface 3 --role=view --signed-in-role=view --json")
        )))
    );
    let Some(Ok((name, args))) = action(&words("share chat --view-only --ttl 1h")) else {
        panic!("share chat --view-only is rewritten")
    };
    let command = super::super::app::run_action(&name, &args, super::super::app::ActionName::Cli)
        .expect("the rewritten flags parse");
    let super::super::app::AppCommand::Call { params, .. } = command else {
        panic!("share chat is an action call")
    };
    assert_eq!(params["args"]["role"], "view", "{params}");
    assert_eq!(params["args"]["signedInRole"], "view", "{params}");
    for text in [
        "share chat --view-only --role talk",
        "share chat --view-only --role=view",
        "share chat --view-only --signed-in-role talk",
        "share chat --view-only --arg signedInRole=view",
        "share chat --view-only --view-only",
    ] {
        assert!(matches!(action(&words(text)), Some(Err(_))), "{text}");
    }
    assert_eq!(action(&words("share chat --role view")), None, "--role goes on as typed");
}

#[test]
fn share_chat_prints_only_the_link() {
    let params = json!({"action": "share chat", "cli": true});
    let result =
        json!({"ran": true, "result": {"share_id": "s1", "url": "https://room.example/g/s1#k"}});
    assert_eq!(human_line(&params, &result).as_deref(), Some("https://room.example/g/s1#k\n"));
    let roomless = json!({"ran": true, "result": {"share_id": "s1", "url": null}});
    assert_eq!(human_line(&params, &roomless), None);
    assert_eq!(human_line(&json!({"action": "share list"}), &result), None);
}
