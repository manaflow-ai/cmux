use super::*;

fn phone(id: &str, name: &str) -> Linked {
    Linked { device_id: id.into(), name: name.into() }
}

#[test]
fn a_phone_tab_address_names_the_tab_and_the_device() {
    assert_eq!(
        Address::parse("tab_ab12@phone"),
        Some(Address { tab: "tab_ab12".into(), device: None })
    );
    assert_eq!(
        Address::parse("tab_ab12@5F2C-11"),
        Some(Address { tab: "tab_ab12".into(), device: Some("5F2C-11".into()) })
    );
    // A plain tab stays the Mac's; anything else is not a phone tab.
    for target in [
        "tab_ab12",
        "page",
        "tab_@phone",
        "ws_1@phone",
        "tab_a@",
        "tab_a@my phone",
        "tab_a b@phone",
    ] {
        assert_eq!(Address::parse(target), None, "{target}");
    }
}

#[test]
fn the_one_linked_phone_answers_at_phone_and_none_is_refused_not_queued() {
    assert_eq!(pick(&[], None).unwrap_err().code, NOT_LINKED);
    assert_eq!(pick(&[], Some("dev-1")).unwrap_err().code, NOT_LINKED);
    let one = [phone("dev-1", "Leo's iPhone")];
    assert_eq!(pick(&one, None).unwrap().device_id, "dev-1");
    assert_eq!(pick(&one, Some("dev-1")).unwrap().device_id, "dev-1");
    assert_eq!(pick(&one, Some("leo's iphone")).unwrap().device_id, "dev-1");
    assert_eq!(pick(&one, Some("dev-2")).unwrap_err().code, NOT_LINKED);
}

#[test]
fn several_phones_need_a_name_and_a_shared_name_needs_an_id() {
    let two = [phone("dev-1", "iPhone"), phone("dev-2", "iPhone")];
    let refusal = pick(&two, None).unwrap_err();
    assert_eq!(refusal.code, AMBIGUOUS);
    assert!(refusal.message.contains("dev-1") && refusal.message.contains("dev-2"));
    assert_eq!(pick(&two, Some("iphone")).unwrap_err().code, AMBIGUOUS);
    assert_eq!(pick(&two, Some("dev-2")).unwrap().device_id, "dev-2");
}

#[test]
fn only_the_shared_verbs_go_to_a_phone_with_their_tab() {
    let params = json!({"tab": "tab_1", "script": "1+1"});
    assert!(check("browser.page.eval", &params).is_ok());
    let refusal = check("browser.page.cookies.get", &params).unwrap_err();
    assert_eq!(refusal.code, UNSUPPORTED);
    assert!(refusal.message.contains("eval") && refusal.message.contains("screenshot"));
    assert_eq!(check("browser.page.eval", &json!({"script": "1"})).unwrap_err().code, BAD_REQUEST);
    assert_eq!(check("browser.page.eval", &json!("x")).unwrap_err().code, BAD_REQUEST);
}

#[test]
fn a_request_round_trips_and_its_answer_matches_by_id() {
    let params =
        check("browser.page.navigate", &json!({"tab": "tab_9", "url": "http://localhost:3000/"}))
            .unwrap();
    let line = request_line(7, "browser.page.navigate", &params);
    assert_eq!(line.last(), Some(&b'\n'));
    let request = parse_request(&line[..line.len() - 1]).unwrap();
    assert_eq!(
        (request.id, request.method.as_str(), request.tab.as_str()),
        (7, "browser.page.navigate", "tab_9")
    );
    assert_eq!(request.params["url"], "http://localhost:3000/");

    let ok = answer_line(7, Ok(json!({"value": 2})));
    assert_eq!(parse_answer(&ok), Some((7, Ok(json!({"value": 2})))));
    let refused = answer_line(8, Err((NOT_ON_PHONE, "mirrored")));
    assert_eq!(
        parse_answer(&refused),
        Some((8, Err(json!({"code": NOT_ON_PHONE, "message": "mirrored"}))))
    );
    assert_eq!(parse_answer(b"{\"ok\":true}"), None);
    assert_eq!(parse_answer(b"not json"), None);
}

#[test]
fn a_bad_request_is_answered_with_its_id_when_it_has_one() {
    for params in [json!({}), json!({"tab": null}), json!({"tab": 7})] {
        let line = serde_json::to_vec(&json!({
            "id": 9, "method": "browser.page.state", "params": params,
        }))
        .unwrap();
        let (id, refusal) = parse_request(&line).unwrap_err();
        assert_eq!((id, refusal.code), (Some(9), BAD_REQUEST));
    }
    let (id, refusal) =
        parse_request(br#"{"id":3,"method":"browser.page.upload","params":{"tab":"tab_1"}}"#)
            .unwrap_err();
    assert_eq!((id, refusal.code), (Some(3), UNSUPPORTED));
    let (id, refusal) = parse_request(b"{}").unwrap_err();
    assert_eq!((id, refusal.code), (None, BAD_REQUEST));
}

#[test]
fn every_verb_has_a_bounded_wait() {
    for verb in VERBS {
        let wait = timeout(verb);
        assert!(wait >= Duration::from_secs(15) && wait <= Duration::from_secs(35), "{verb}");
    }
}
