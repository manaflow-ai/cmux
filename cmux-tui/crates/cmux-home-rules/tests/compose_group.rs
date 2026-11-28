//! Parity with `HomeGroupActionsTests`, `HomeDirectoryTests`, `HomeTeamSeatImpactTests` and
//! `HomeTeamInviteRunTests`.

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("compose.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

fn book() -> Value {
    json!({
        "me": "me",
        "contacts": [{"id": "ada", "name": "Ada Lovelace", "source": "team"}],
        "rows": [
            {"id": "g", "kind": "group", "title": "Launch", "summaryTitle": "conv_abc", "owner": "cloud",
             "participants": [
                {"id": "ada", "displayName": "Ada Lovelace"},
                {"id": "me", "displayName": "Me"},
                {"id": "c", "kind": "agent", "agentClass": "chief", "displayName": "Chief", "ownerUser": "me"},
             ]},
            {"id": "d", "kind": "direct", "participants": [{"id": "me"}, {"id": "bob", "displayName": "Bob"}]},
        ],
    })
}

fn with(mut base: Value, extra: Value) -> Value {
    for (k, v) in extra.as_object().unwrap() {
        base[k] = v.clone();
    }
    base
}

#[test]
fn names_split_on_commas() {
    assert_eq!(op("group.names", json!({"list": " ada, ,bob ,"})), json!(["ada", "bob"]));
}

#[test]
fn contact_finds_known_people_across_groups() {
    assert_eq!(op("group.contact", with(book(), json!({"text": "bob"}))), "bob");
    assert_eq!(op("group.contact", with(book(), json!({"text": "ADA LOVELACE"}))), "ada");
    assert_eq!(op("group.contact", with(book(), json!({"text": "me"}))), Value::Null);
}

#[test]
fn info_puts_me_first_and_hides_internal_titles() {
    let info = op("group.info", with(book(), json!({"conversation": "g", "canMute": true})));
    assert_eq!(info["members"][0]["id"], "me");
    assert_eq!(info["title"], "");
    assert_eq!(info["displayTitle"], "Launch");
    assert_eq!(info["chiefReplies"], "auto");
    assert_eq!(info["canRename"], true);
}

#[test]
fn named_people_asks_for_an_email_lookup() {
    let req = with(book(), json!({"list": "ada, x@y.com", "conversation": "g", "purpose": "add"}));
    assert_eq!(op("group.namedPeople", req.clone()), json!({"kind": "lookup", "email": "x@y.com"}));
    let answered = with(req.clone(), json!({"lookups": {"x@y.com": "user_x"}}));
    assert_eq!(op("group.namedPeople", answered)["people"], json!(["ada", "user_x"]));
    let missing = with(req, json!({"lookups": {"x@y.com": null}}));
    assert_eq!(
        op("group.namedPeople", missing)["outcome"],
        json!({"kind": "notReachable", "name": "x@y.com"})
    );
    let nobody = with(book(), json!({"list": "zed", "purpose": "create"}));
    assert_eq!(op("group.namedPeople", nobody)["outcome"]["kind"], "unknownPerson");
}

#[test]
fn outcomes_from_rejections() {
    let o = |rej: Value, removing: bool| {
        op("group.outcome", json!({"rejection": rej, "naming": "Ada", "removing": removing}))["outcome"].clone()
    };
    assert_eq!(o(json!({"kind": "ownerUnreachable"}), false), json!({"kind": "offline"}));
    assert_eq!(o(json!({"kind": "notAuthorized"}), true), json!({"kind": "ownerOnly"}));
    assert_eq!(o(json!({"kind": "notAuthorized"}), false), json!({"kind": "forbidden"}));
    assert_eq!(
        o(json!({"kind": "invalid", "reason": "not_participant"}), false),
        json!({"kind": "notAMember", "name": "Ada"})
    );
    assert_eq!(
        o(json!({"kind": "invalid", "reason": "weird"}), false),
        json!({"kind": "refused", "reason": "weird"})
    );
}

#[test]
fn gates_check_before_the_owner() {
    let g = |extra: Value| op("group.gate", with(book(), extra));
    assert_eq!(
        g(json!({"change": "send", "conversation": "g", "text": "  "}))["outcome"]["kind"],
        "emptyText"
    );
    assert_eq!(g(json!({"change": "send", "conversation": "g", "text": " hi "}))["text"], "hi");
    assert_eq!(g(json!({"change": "rename", "conversation": "d"}))["outcome"]["kind"], "notAGroup");
    assert_eq!(
        g(json!({"change": "rename", "conversation": "zz"}))["outcome"]["kind"],
        "unknownConversation"
    );
    assert_eq!(g(json!({"change": "remove", "conversation": "g", "person": "me"}))["leave"], true);
    assert_eq!(
        op("group.settle", json!({"change": "send", "outcome": {"kind": "offline"}})),
        json!({"kind": "queued"})
    );
}

#[test]
fn chief_named_by_id_or_name() {
    let chiefs =
        json!([{"id": "agent_muse", "name": "Muse"}, {"id": "agent_b", "name": "Bo  Peep"}]);
    assert_eq!(op("directory.chiefNamed", json!({"chiefs": chiefs, "text": "muse"})), "agent_muse");
    assert_eq!(op("directory.chiefNamed", json!({"chiefs": chiefs, "text": "bo peep"})), "agent_b");
    assert_eq!(op("directory.chiefNamed", json!({"chiefs": chiefs, "text": "x"})), Value::Null);
}

#[test]
fn members_skip_me_and_sort() {
    let value = json!({"members": [{"user": "z", "display_name": "Zed"}, {"user": "me"}, {"user": "a"}, {"user": ""}]});
    let out = op("directory.members", json!({"value": value, "me": "me"}));
    assert_eq!(out, json!([{"id": "user_a", "name": "a"}, {"id": "user_z", "name": "Zed"}]));
}

#[test]
fn rename_and_archive_failures() {
    let f = |code: &str| json!({"error": {"kind": "owner", "code": code, "message": ""}});
    assert_eq!(op("directory.renameFailure", f("revision.conflict"))["kind"], "changedElsewhere");
    assert_eq!(
        op("directory.renameFailure", f("x.y")),
        json!({"kind": "refused", "reason": "x.y"})
    );
    assert_eq!(op("directory.archiveOutcome", f("chief_is_default"))["kind"], "isDefault");
    assert_eq!(
        op("directory.archiveOutcome", json!({"error": {"kind": "other"}}))["kind"],
        "unreachable"
    );
}

#[test]
fn channel_plan_checks_title_and_lists_ops() {
    let people = json!([{"email": "a@b.co"}, {"account": "user_x"}]);
    let plan = op(
        "directory.channelPlan",
        json!({"title": " T ", "people": people, "key": "k", "conversation": "c"}),
    );
    assert_eq!(plan["params"]["title"], "T");
    assert_eq!(plan["ops"][0]["idempotency_key"], "k:invite:0");
    assert_eq!(plan["ops"][0]["params"]["display_name"], "a");
    assert_eq!(plan["ops"][1]["op"], "participants.add");
    let bad = op("directory.channelPlan", json!({"title": " ", "key": "k", "conversation": "c"}));
    assert_eq!(bad["error"]["field"], "title");
}

#[test]
fn seat_impact() {
    let s = |r: Value| op("team.seatImpact", r);
    assert_eq!(s(json!({"canInvite": false}))["allowsSending"], false);
    let capped = s(json!({"canInvite": true, "memberCount": 2, "memberLimit": 3}));
    assert_eq!(capped["impact"], json!({"kind": "capped", "members": 2, "limit": 3}));
    let paid =
        s(json!({"canInvite": true, "hasSubscription": true, "planID": "Team", "memberCount": 4}));
    assert_eq!(paid["impact"]["kind"], "paidSeat");
    assert_eq!(s(json!({"canInvite": true, "hasSubscription": true}))["impact"]["kind"], "unknown");
    assert_eq!(s(json!({"canInvite": true, "memberCount": 1}))["impact"]["kind"], "free");
}

#[test]
fn invite_email_refuses_non_emails() {
    assert_eq!(op("team.inviteEmail", json!({"text": "bob"}))["refused"]["kind"], "invalidAddress");
    assert_eq!(op("team.inviteEmail", json!({"text": " a@b.co "}))["prefill"], "a@b.co");
}
