use super::*;

fn params(notice: Value) -> Value {
    json!({"_meta": {"acpmux": {"notice": notice}}})
}

fn fire() -> Value {
    json!({"sender": "base-red-watch", "host": "ci-mini-3", "severity": "fire",
               "title": "cmux-next fast tier failed on 3 PRs",
               "links": [{"url": "https://github.com/manaflow-ai/cmux/pull/32827", "label": "#32827"}]})
}

fn field_of(e: &RpcError) -> (&Value, &Value) {
    let data = e.data.as_ref().expect("refusal data");
    (&data["reason"], &data["field"])
}

#[test]
fn a_notice_is_checked_and_keeps_only_its_known_fields() {
    let mut sent = fire();
    sent["extra"] = json!("dropped");
    sent["links"][0]["extra"] = json!(1);
    let checked = notice_of(&params(sent)).unwrap().unwrap();
    assert_eq!(checked, fire());
    // Only the required fields.
    let bare = json!({"sender": "next-autoland", "severity": "info", "title": "LANDED #1"});
    assert_eq!(notice_of(&params(bare.clone())).unwrap(), Some(bare));
    assert_eq!(notice_of(&json!({})).unwrap(), None);
    assert_eq!(notice_of(&params(Value::Null)).unwrap(), None);
}

#[test]
fn a_bad_notice_field_refuses_the_prompt_naming_the_field() {
    let with = |key: &str, value: Value| {
        let mut n = fire();
        n[key] = value;
        n
    };
    let without = |key: &str| {
        let mut n = fire();
        n.as_object_mut().unwrap().remove(key);
        n
    };
    let link = |l: Value| with("links", json!([l]));
    let cases = [
        (json!("text"), "notice"),
        (without("sender"), "sender"),
        (with("sender", json!("a\nb")), "sender"),
        (with("sender", json!("s".repeat(65))), "sender"),
        (with("sender", json!("x\u{202E}y")), "sender"),
        (with("host", json!("cosmic gray")), "host"),
        (with("host", json!("h".repeat(65))), "host"),
        (without("severity"), "severity"),
        (with("severity", json!("critical")), "severity"),
        (without("title"), "title"),
        (with("title", json!("   ")), "title"),
        (with("title", json!("t".repeat(201))), "title"),
        (with("title", json!("one\ntwo")), "title"),
        (with("links", json!("https://x")), "links"),
        (with("links", json!(vec![json!({"url": "https://x.dev"}); 17])), "links"),
        (link(json!({"url": "http://x.dev"})), "links.url"),
        (link(json!({"url": "javascript:alert(1)"})), "links.url"),
        (link(json!({"url": "https://"})), "links.url"),
        (link(json!({"url": "https://x.dev/a b"})), "links.url"),
        (link(json!({"label": "#1"})), "links.url"),
        (link(json!({"url": "https://x.dev", "label": "l".repeat(65)})), "links.label"),
        (link(json!({"url": "https://x.dev", "label": 7})), "links.label"),
    ];
    for (notice, field) in cases {
        let e = notice_of(&params(notice.clone())).unwrap_err();
        assert_eq!(field_of(&e), (&json!("notice.value_refused"), &json!(field)), "{notice}");
    }
    // At the bounds: accepted.
    let longest = with("title", json!("t".repeat(200)));
    assert!(notice_of(&params(longest)).is_ok());
    let sixteen = with("links", json!(vec![json!({"url": "https://x.dev"}); 16]));
    assert!(notice_of(&params(sixteen)).is_ok());
}

#[test]
fn a_notice_is_stamped_as_a_named_senders_message_that_carries_it() {
    let checked = notice_of(&params(fire())).unwrap().unwrap();
    let stamped = notice(&checked, "s-1");
    assert_eq!(
        stamped,
        json!({"kind": "notice", "from": "fromAgent", "fromName": "base-red-watch", "to": "s-1",
                   "notice": fire()})
    );
    assert!(is_notice(Some(&stamped)));
    assert!(!is_notice(Some(&named_sender("x", "s-1"))));
    // It survives a record: marked and read back whole.
    let record = marked(json!({"promptId": "p"}), Some(&stamped));
    assert_eq!(recorded(&record), Some(stamped));
}

#[test]
fn a_notice_renders_its_text_for_the_model_and_old_pages() {
    let checked = notice_of(&params(fire())).unwrap().unwrap();
    assert_eq!(
        notice_text(&checked, "fast tier red on #32827, #32830, #32831\n"),
        "[notice from base-red-watch on ci-mini-3 · FIRE] cmux-next fast tier failed on 3 PRs\n\
             fast tier red on #32827, #32830, #32831\n\
             Links: https://github.com/manaflow-ai/cmux/pull/32827 (#32827)"
    );
    let warn = json!({"sender": "s", "severity": "warn", "title": "T",
                          "links": [{"url": "https://a.dev"}, {"url": "https://b.dev", "label": "b"}]});
    assert_eq!(
        notice_text(&warn, ""),
        "[notice from s · WARN] T\nLinks: https://a.dev, https://b.dev (b)"
    );
    let info = json!({"sender": "s", "severity": "info", "title": "T"});
    assert_eq!(notice_text(&info, "body"), "[notice from s] T\nbody");
}

#[test]
fn a_link_argument_splits_its_label_off_and_keeps_a_querys_equals() {
    let pr = "https://github.com/manaflow-ai/cmux/pull/32827";
    assert_eq!(notice_link(pr), json!({"url": pr}));
    assert_eq!(notice_link(&format!("{pr}=#32827")), json!({"url": pr, "label": "#32827"}));
    assert_eq!(notice_link(&format!("{pr}=")), json!({"url": pr}));
    let run = "https://x.dev/run?id=5&attempt=2";
    assert_eq!(notice_link(run), json!({"url": run}));
    assert_eq!(notice_link(&format!("{run}=run 5")), json!({"url": run, "label": "run 5"}));
}

#[test]
fn a_notice_beside_a_callers_provenance_is_refused() {
    let mut both = params(fire());
    both["_meta"]["acpmux"]["provenance"] = json!({"kind": "agent_message"});
    let e = notice_checked(&both).unwrap_err();
    assert_eq!(field_of(&e), (&json!("notice.value_refused"), &json!("provenance")));
    assert!(notice_checked(&params(fire())).unwrap().is_some());
}

#[test]
fn only_the_unix_socket_or_a_peer_may_send_a_notice() {
    let e = notice_origin_refused();
    assert_eq!(e.data.as_ref().unwrap()["reason"], "notice.origin_refused");
    assert!(notice_present(&params(fire())));
    assert!(!notice_present(&params(Value::Null)));
}

#[test]
fn a_record_with_no_provenance_says_it_is_the_proven_persons_and_one_with_keeps_its_own() {
    let own = marked(json!({"promptId": "p", "_meta": {"x": 1}}), None);
    assert_eq!(own["_meta"]["origin"], json!({"actor": "person", "verified": true}));
    assert_eq!(own["_meta"]["x"], 1, "the rest of its _meta stays");
    let theirs = marked(json!({"promptId": "p"}), Some(&named_sender("lane-a", "s")));
    assert!(theirs["_meta"].get("origin").is_none(), "{theirs}");
    assert_eq!(theirs["_meta"]["provenance"]["verified"], false);
}

#[test]
fn an_unverified_prompt_names_no_one_and_keeps_its_claims_apart() {
    let mut claimed = Map::new();
    claimed.insert("cliHost".into(), json!("workstation"));
    let p = unverified("s", "unix", claimed);
    assert_eq!(
        p,
        json!({"kind": "unverified", "to": "s", "transport": "unix", "verified": false,
                   "claimed": {"cliHost": "workstation"}})
    );
    assert!(p.get("fromName").is_none());
    assert!(unverified("s", "unix", Map::new()).get("claimed").is_none());
}

#[test]
fn observed_never_raises_what_the_daemon_set() {
    let session = observed(session_message("a", "lane-a", "b"), "unix");
    assert_eq!(session["verified"], true);
    assert_eq!(session["transport"], "unix");
    let named = observed(named_sender("lane-a", "b"), "peer");
    assert_eq!(named["verified"], false);
    assert_eq!(named["transport"], "peer");
}

#[test]
fn an_edit_and_a_forward_are_named_beside_the_sender_not_in_its_place() {
    let p = named_sender("lane-a", "s");
    let owner = edited_by(p.clone(), Some(None));
    assert_eq!(owner["fromName"], "lane-a");
    assert_eq!(owner["editedBy"], json!({"actor": "owner"}));
    let guest = edited_by(p.clone(), Some(Some("guest:ana")));
    assert_eq!(guest["editedBy"], json!({"actor": "person", "id": "guest:ana"}));
    assert_eq!(edited_by(p.clone(), None), p);
    let forwarded = forwarded_by_peer(p, Some("device"));
    assert_eq!(forwarded["fromName"], "lane-a");
    assert_eq!(forwarded["forwardedBy"], json!({"actor": "peer", "via": "device"}));
}

#[test]
fn a_client_cannot_send_verified_or_an_editor_or_a_forwarder() {
    let params = json!({"_meta": {"acpmux": {"provenance": {
            "kind": "agent_message", "from": "acp:x", "to": "acp:y", "msgId": "m", "threadId": "t",
            "verified": true, "editedBy": {"actor": "owner"}, "forwardedBy": {"actor": "peer"}}}}});
    let p = of(&params, Sender::Local).unwrap().unwrap();
    assert!(p.get("verified").is_none(), "{p}");
    assert!(p.get("editedBy").is_none(), "{p}");
    assert!(p.get("forwardedBy").is_none(), "{p}");
    let unverified = json!({"_meta": {"acpmux": {"provenance": {"kind": "unverified"}}}});
    assert!(of(&unverified, Sender::Local).is_err());
}
